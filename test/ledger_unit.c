/* test/ledger_unit.c -- unit test of src/fsql_ledger_store.h: the in-memory hash-chained ledger and its verifier, the code behind
 * fractal_ledger_verify(). The SQL gates can only reach it through the audit path of a real connection, where a chain cannot be
 * forged; here chains are built by hand and then damaged in every way the integrity check exists to notice.
 *
 * Groups: a sound chain; damage to a row (blob, hash, link, sequence number, deletion, reordering, a new first row); the limit of the
 * check (a chain re-hashed from the first edited row looks sound, which is what the anchor log is for); the anchor log (every head
 * published, with the right kind, row count and hash); the size cap (FSQL_DUCKDB_LEDGER_MAX_BYTES, read once); many chains and long
 * chains (the growth paths); and allocation failure.
 *
 * The size cap and the anchor mode are read once per process, so they are checked in their own invocations:
 *   ledger_unit            the default environment (no cap override, anchor log off)
 *   ledger_unit cap        run with FSQL_DUCKDB_LEDGER_MAX_BYTES=100
 *   ledger_unit nocap      run with FSQL_DUCKDB_LEDGER_MAX_BYTES=0 (unlimited)
 *   ledger_unit badcap     run with FSQL_DUCKDB_LEDGER_MAX_BYTES=abc (falls back to the default)
 *   ledger_unit anchor     run with FSQL_LEDGER_ANCHOR_LOG=stderr (the anchor log is captured and compared)
 * (test/ledger_run.sh runs them all; build_test.sh runs that script as a gate.)
 *
 * Build:  cc -std=c11 -Isrc test/ledger_unit.c -o ledger_unit */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#  include <io.h>
#  define dup    _dup
#  define dup2   _dup2
#  define lseek  _lseek
#  define read   _read
#  define close  _close
#  define fileno _fileno
#else
#  include <unistd.h>
#endif

/* allocation failure injection: the Nth allocation after g_alloc_left is armed returns NULL */
static long g_alloc_left = -1;
static void *t_malloc(size_t n)           { if (g_alloc_left == 0) { g_alloc_left = -1; return NULL; } if (g_alloc_left > 0) g_alloc_left--; return malloc(n); }
static void *t_realloc(void *p, size_t n) { if (g_alloc_left == 0) { g_alloc_left = -1; return NULL; } if (g_alloc_left > 0) g_alloc_left--; return realloc(p, n); }
#define malloc  t_malloc
#define realloc t_realloc
#include "fsql_ledger_store.h"
#undef malloc
#undef realloc

static int g_fail, g_pass;
#define CHECK(cond, what) do { if (cond) g_pass++; else { g_fail++; printf("  FAIL %s (line %d)\n", what, __LINE__); } } while (0)

static void verdict(const chain *c, char *json, size_t cap) { ledger_chain_verdict(c, json, cap); }
static int has(const char *json, const char *text) { return strstr(json, text) != NULL; }

static ledger_store *fresh(void) { return (ledger_store *)calloc(1, sizeof(ledger_store)); }
static void fill(ledger_store *s, int kind, int rows) {
    for (int i = 0; i < rows; i++) { char p[32]; int n = snprintf(p, sizeof p, "row-%d", i); (void)ledger_append(s, kind, p, (size_t)n); }
}
/* re-hash a chain from row `from` on, as someone who knows the scheme would after editing a row */
static void rehash_from(chain *c, size_t from) {
    for (size_t i = from; i < c->n; i++) {
        if (i) memcpy(c->e[i].prev_hash, c->e[i - 1].hash, 32); else memset(c->e[i].prev_hash, 0, 32);
        chain_hash(c->e[i].prev_hash, c->e[i].blob, c->e[i].len, c->e[i].hash);
    }
}

static void test_sound(void) {
    char j[256];
    verdict(NULL, j, sizeof j);
    CHECK(has(j, "\"ok\":true") && has(j, "\"rows_verified\":0"), "no such chain: ok, zero rows");
    ledger_store *s = fresh();
    chain *empty = store_get(s, 5);
    verdict(empty, j, sizeof j);
    CHECK(empty && has(j, "\"ok\":true") && has(j, "\"rows_verified\":0"), "an empty chain: ok, zero rows");
    fill(s, 1, 5);
    chain *c = store_find(s, 1);
    verdict(c, j, sizeof j);
    CHECK(c && c->n == 5 && has(j, "\"ok\":true") && has(j, "\"rows_verified\":5"), "a sound chain of five rows verifies");
    CHECK(c->e[0].id == 0 && c->e[4].id == 4, "sequence numbers run 0..n-1 within a chain");
    uint8_t zero[32] = {0};
    CHECK(memcmp(c->e[0].prev_hash, zero, 32) == 0 && memcmp(c->e[1].prev_hash, c->e[0].hash, 32) == 0, "the first row links to zeros, each later row to its predecessor");
    CHECK(store_find(s, 9) == NULL && store_find(s, 1) == c, "store_find: absent kind is NULL, present kind is the same chain");
    fill(s, 2, 2);
    verdict(store_find(s, 2), j, sizeof j);
    CHECK(has(j, "\"rows_verified\":2"), "chains are independent: a second kind verifies on its own");
    char tiny[12];
    verdict(c, tiny, sizeof tiny);
    CHECK(strlen(tiny) < sizeof tiny, "a too-small output buffer truncates and stays terminated");
    store_free(s);
    store_free(NULL);
    CHECK(1, "store_free(NULL) is a no-op");
}

static void test_damage(void) {
    char j[256];
    ledger_store *s;
    chain *c;

    s = fresh(); fill(s, 1, 6); c = store_find(s, 1);
    c->e[3].blob[0] ^= 0x01;
    verdict(c, j, sizeof j);
    CHECK(has(j, "\"ok\":false") && has(j, "\"first_failure_id\":3") && has(j, "entry_hash mismatch"), "an edited payload is found at that row");
    store_free(s);

    s = fresh(); fill(s, 1, 6); c = store_find(s, 1);
    c->e[2].hash[5] ^= 0x80;
    verdict(c, j, sizeof j);
    CHECK(has(j, "\"first_failure_id\":2") && has(j, "entry_hash mismatch"), "an edited row hash is found at that row");
    store_free(s);

    s = fresh(); fill(s, 1, 6); c = store_find(s, 1);
    c->e[4].prev_hash[0] ^= 0x01;
    verdict(c, j, sizeof j);
    CHECK(has(j, "\"first_failure_id\":4") && has(j, "chain-link break"), "an edited back-link is found at that row");
    store_free(s);

    s = fresh(); fill(s, 1, 6); c = store_find(s, 1);
    free(c->e[2].blob);
    memmove(&c->e[2], &c->e[3], (c->n - 3) * sizeof c->e[0]); c->n--;      /* a row deleted from the middle */
    verdict(c, j, sizeof j);
    CHECK(has(j, "\"ok\":false") && has(j, "sequence gap"), "a deleted middle row leaves a sequence gap");
    store_free(s);

    s = fresh(); fill(s, 1, 6); c = store_find(s, 1);
    free(c->e[0].blob);
    memmove(&c->e[0], &c->e[1], (c->n - 1) * sizeof c->e[0]); c->n--;      /* the first row deleted */
    verdict(c, j, sizeof j);
    CHECK(has(j, "\"ok\":false") && has(j, "chain-link break"), "a deleted first row breaks the link of the new first row");
    store_free(s);

    s = fresh(); fill(s, 1, 6); c = store_find(s, 1);
    free(c->e[c->n - 1].blob);
    c->n--;                                                                   /* the last row truncated */
    verdict(c, j, sizeof j);
    CHECK(has(j, "\"ok\":true") && has(j, "\"rows_verified\":5"), "a truncated tail is NOT detected by the chain alone (the anchor log records the head)");
    store_free(s);

    s = fresh(); fill(s, 1, 6); c = store_find(s, 1);
    { chain_entry t = c->e[2]; c->e[2] = c->e[3]; c->e[3] = t; }              /* two rows swapped */
    verdict(c, j, sizeof j);
    CHECK(has(j, "\"ok\":false") && (has(j, "sequence gap") || has(j, "chain-link break")), "two swapped rows are found");
    store_free(s);

    s = fresh(); fill(s, 1, 6); c = store_find(s, 1);
    c->e[1].id = 9;
    verdict(c, j, sizeof j);
    CHECK(has(j, "\"first_failure_id\":9") && has(j, "sequence gap"), "an edited sequence number is found");
    store_free(s);

    s = fresh(); fill(s, 1, 3); c = store_find(s, 1);
    free(c->e[0].blob); c->e[0].blob = (uint8_t *)malloc(1); c->e[0].len = 0;  /* payload emptied, hash left */
    verdict(c, j, sizeof j);
    CHECK(has(j, "\"first_failure_id\":0") && has(j, "entry_hash mismatch"), "an emptied payload is found at the first row");
    store_free(s);

    /* the limit of the check: edit a row, then re-hash from it on. The chain is internally consistent again, so verify says ok --
     * which is why each head is published (FSQL_LEDGER_ANCHOR_LOG) for comparison with an outside record */
    s = fresh(); fill(s, 1, 6); c = store_find(s, 1);
    uint8_t head_before[32]; memcpy(head_before, c->e[c->n - 1].hash, 32);
    c->e[2].blob[0] ^= 0x01;
    rehash_from(c, 2);
    verdict(c, j, sizeof j);
    CHECK(has(j, "\"ok\":true"), "a chain re-hashed from an edited row is internally consistent");
    CHECK(memcmp(head_before, c->e[c->n - 1].hash, 32) != 0, "...but its head differs from the one published before the edit");
    store_free(s);
}

static void test_growth(void) {
    char j[256];
    ledger_store *s = fresh();
    for (int k = 0; k < 40; k++) fill(s, k * 3 - 20, 2);                 /* 40 kinds, some negative: the chain table grows */
    CHECK(s->nchains == 40, "forty kinds make forty chains");
    int all = 1;
    for (int k = 0; k < 40; k++) { verdict(store_find(s, k * 3 - 20), j, sizeof j); if (!has(j, "\"rows_verified\":2")) all = 0; }
    CHECK(all, "every one of them verifies");
    fill(s, 7, 100);                                                       /* one long chain: the row array grows several times */
    verdict(store_find(s, 7), j, sizeof j);
    CHECK(has(j, "\"ok\":true") && (has(j, "\"rows_verified\":101") || has(j, "\"rows_verified\":102")), "a long chain verifies");
    size_t bytes_before = s->total_bytes;
    (void)ledger_append(s, 8, "", 0);
    CHECK(s->total_bytes == bytes_before && store_find(s, 8)->n == 1, "an empty payload is a row of zero bytes");
    store_free(s);
}

static void test_alloc_failure(void) {
    /* every allocation a first append makes, failed in turn: it must report failure and leave a store that still frees cleanly */
    int failed_any = 0;
    for (long n = 0; n < 8; n++) {
        ledger_store *s = fresh();
        g_alloc_left = n;
        int rc = ledger_append(s, 1, "abc", 3);
        g_alloc_left = -1;
        if (rc != 0) failed_any = 1;
        char j[256];
        verdict(store_find(s, 1), j, sizeof j);
        CHECK(has(j, "\"ok\":true"), "after an allocation failure the chain still verifies");
        store_free(s);
    }
    CHECK(failed_any, "an allocation failure is reported by ledger_append");
    ledger_store *s = fresh();
    fill(s, 1, 16);                                                        /* fill the row array exactly; the next append must grow it */
    g_alloc_left = 0;
    CHECK(ledger_append(s, 1, "x", 1) != 0, "growing the row array: failure reported");
    g_alloc_left = -1;
    CHECK(ledger_append(s, 1, "y", 1) == 0, "...and the next append succeeds");
    store_free(s);
}

static void test_cap(void) {
    ledger_store *s = fresh();
    char big[60]; memset(big, 'a', sizeof big);
    CHECK(ledger_append(s, 1, big, sizeof big) == 0, "the first 60 bytes fit under a 100-byte cap");
    CHECK(ledger_append(s, 1, big, sizeof big) != 0, "the next 60 do not: the append is refused");
    CHECK(s->total_bytes == sizeof big, "a refused append is not counted");
    int fit = 1;
    for (int i = 0; i < 4; i++) if (ledger_append(s, 1, "0123456789", 10) != 0) fit = 0;
    CHECK(fit && s->total_bytes == 100, "small rows still fit, right up to the cap (60 + 4 x 10 = 100)");
    CHECK(ledger_append(s, 1, "0123456789", 10) != 0, "...and not one byte past it");
    char j[256];
    verdict(store_find(s, 1), j, sizeof j);
    CHECK(has(j, "\"ok\":true"), "the chain that was kept still verifies");
    store_free(s);
}

static void test_nocap(void) {
    ledger_store *s = fresh();
    char big[4096]; memset(big, 'a', sizeof big);
    int ok = 1;
    for (int i = 0; i < 64; i++) if (ledger_append(s, 1, big, sizeof big) != 0) ok = 0;
    CHECK(ok && s->total_bytes == 64 * sizeof big, "with the cap off (0) nothing is refused");
    store_free(s);
}

static void test_badcap(void) {
    ledger_store *s = fresh();
    char big[4096]; memset(big, 'a', sizeof big);
    CHECK(ledger_append(s, 1, big, sizeof big) == 0, "an unparsable cap value falls back to the default (256 MiB)");
    store_free(s);
}

/* the anchor log, captured: fd 2 is pointed at a temporary file for the appends and read back */
static void test_anchor(void) {
    FILE *tf = tmpfile();
    int fd = tf ? fileno(tf) : -1;
    CHECK(fd >= 0, "a temporary file for the capture");
    if (fd < 0) return;
    fflush(stderr);
    int saved = dup(2);
    dup2(fd, 2);
    ledger_store *s = fresh();
    fill(s, 3, 2);
    fill(s, 4, 1);
    fflush(stderr);
    dup2(saved, 2); close(saved);
    char buf[2048] = {0};
    lseek(fd, 0, SEEK_SET);
    int got = (int)read(fd, buf, sizeof buf - 1);
    fclose(tf);
    CHECK(got > 0, "the anchor log wrote to stderr");
    int lines = 0; for (char *p = buf; (p = strchr(p, '\n')); p++) lines++;
    CHECK(lines == 3, "one line per append (three appends, three heads)");
    chain *c3 = store_find(s, 3), *c4 = store_find(s, 4);
    char want[256], hex[65];
    for (int i = 0; i < 32; i++) snprintf(hex + i * 2, 3, "%02x", c3->e[1].hash[i]);
    snprintf(want, sizeof want, "{\"event\":\"ledger_head\",\"kind\":3,\"rows\":2,\"hash\":\"%s\"}", hex);
    CHECK(strstr(buf, want) != NULL, "kind 3's second head: right kind, row count and hash");
    for (int i = 0; i < 32; i++) snprintf(hex + i * 2, 3, "%02x", c4->e[0].hash[i]);
    snprintf(want, sizeof want, "{\"event\":\"ledger_head\",\"kind\":4,\"rows\":1,\"hash\":\"%s\"}", hex);
    CHECK(strstr(buf, want) != NULL, "kind 4's head: right kind, row count and hash");
    store_free(s);
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "default";
    if (!strcmp(mode, "default")) {
        test_sound();
        test_damage();
        test_growth();
        test_alloc_failure();
    } else if (!strcmp(mode, "cap")) test_cap();
    else if (!strcmp(mode, "nocap")) test_nocap();
    else if (!strcmp(mode, "badcap")) test_badcap();
    else if (!strcmp(mode, "anchor")) test_anchor();
    else { fprintf(stderr, "usage: %s [default|cap|nocap|badcap|anchor]\n", argv[0]); return 2; }
    printf("ledger_unit %s: %d checks passed, %d failed\n", mode, g_pass, g_fail);
    return g_fail ? 1 : 0;
}
