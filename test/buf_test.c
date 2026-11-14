/* test/buf_test.c -- unit + randomized tests for include/fsql_buf.h.
 * Built by `make unit` with ASan + UBSan; any sanitizer report aborts. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_buf.h"

static int fails = 0, checks = 0;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; printf("  FAIL %s (line %d)\n", msg, __LINE__); } } while (0)

static void test_basic(void) {
    fsql_sb b; fsql_sb_init(&b);
    CHECK(strcmp(fsql_sb_cstr(&b), "") == 0, "empty builder reads as empty string");
    fsql_sb_puts(&b, "abc"); fsql_sb_putc(&b, 'd'); fsql_sb_printf(&b, "%d-%s", 42, "x");
    CHECK(strcmp(fsql_sb_cstr(&b), "abcd42-x") == 0, "puts/putc/printf compose");
    CHECK(b.len == 8 && b.p[8] == 0, "NUL-terminated, len excludes NUL");
    fsql_sb_clear(&b);
    CHECK(strcmp(fsql_sb_cstr(&b), "") == 0 && fsql_sb_ok(&b), "clear keeps the buffer usable");
    fsql_sb_puts(&b, "again");
    char *t = fsql_sb_take(&b);
    CHECK(t && strcmp(t, "again") == 0 && b.p == NULL, "take hands over ownership and resets");
    free(t);
    fsql_sb_init(&b);
    t = fsql_sb_take(&b);
    CHECK(t && t[0] == 0, "take of an untouched builder is an empty string, not NULL");
    free(t);
    fsql_sb_puts(&b, NULL);
    CHECK(!fsql_sb_ok(&b), "appending a NULL string marks the builder bad");
    CHECK(fsql_sb_take(&b) == NULL, "take of a bad builder is NULL");
}

static void test_growth(void) {
    fsql_sb b; fsql_sb_init(&b);
    for (int i = 0; i < 100000; i++) fsql_sb_printf(&b, "%d,", i);
    CHECK(fsql_sb_ok(&b) && b.len > 500000, "100k appends grow without loss");
    CHECK(b.p[b.len] == 0, "still NUL-terminated after many growths");
    fsql_sb_free(&b);
    /* a single huge printf result */
    char *big = malloc(300001); memset(big, 'a', 300000); big[300000] = 0;
    fsql_sb_printf(&b, "%s|%s", big, big);
    CHECK(fsql_sb_ok(&b) && b.len == 600001, "a printf larger than the initial capacity");
    fsql_sb_free(&b); free(big);
}

static void test_cap(void) {
    fsql_sb b; fsql_sb_init(&b);
    fsql_sb_putn(&b, "x", 1);
    /* a length that would wrap size_t must be refused, not wrapped */
    fsql_sb_putn(&b, "x", SIZE_MAX);
    CHECK(!fsql_sb_ok(&b), "an append of SIZE_MAX is refused (no size_t wrap)");
    fsql_sb_putn(&b, "y", 1);
    CHECK(!fsql_sb_ok(&b) && strcmp(fsql_sb_cstr(&b), "") == 0, "a bad builder stays bad and reads empty");
    fsql_sb_free(&b);
    fsql_sb_init(&b);
    fsql_sb_putn(&b, "x", FSQL_BUF_MAX);
    CHECK(!fsql_sb_ok(&b), "an append at the hard cap is refused");
    fsql_sb_free(&b);
}

static void test_json(void) {
    fsql_sb b; fsql_sb_init(&b);
    const char in[] = "a\"b\\c\n\r\t\b\f\x01\x1f" "é/";
    fsql_sb_put_json_escaped(&b, in, sizeof in - 1);
    CHECK(strcmp(fsql_sb_cstr(&b), "a\\\"b\\\\c\\n\\r\\t\\b\\f\\u0001\\u001f" "é/") == 0, "JSON escaping of quotes, backslash, controls; UTF-8 passes");
    fsql_sb_clear(&b);
    fsql_sb_put_json_double(&b, 0.1); fsql_sb_putc(&b, ' ');
    fsql_sb_put_json_double(&b, NAN); fsql_sb_putc(&b, ' ');
    fsql_sb_put_json_double(&b, -INFINITY);
    CHECK(strcmp(fsql_sb_cstr(&b), "0.10000000000000001 null null") == 0, "doubles: %.17g, NaN/Inf -> null");
    fsql_sb_free(&b);
    /* an embedded NUL byte is escaped, not truncated */
    fsql_sb_init(&b);
    fsql_sb_put_json_escaped(&b, "a\0b", 3);
    CHECK(strcmp(fsql_sb_cstr(&b), "a\\u0000b") == 0, "embedded NUL is escaped");
    fsql_sb_free(&b);
}

static void test_vecd(void) {
    fsql_vecd v; fsql_vecd_init(&v);
    for (int i = 0; i < 100000; i++) fsql_vecd_push(&v, i * 0.5);
    CHECK(fsql_vecd_ok(&v) && v.len == 100000 && v.p[99999] == 49999.5, "push 100k doubles");
    CHECK(!fsql_vecd_reserve(&v, SIZE_MAX / 2), "an absurd reserve is refused");
    CHECK(!fsql_vecd_ok(&v), "and marks the array bad");
    fsql_vecd_free(&v);
    CHECK(fsql_xmalloc_array(SIZE_MAX, 8) == NULL, "xmalloc_array refuses n*size overflow");
    char *s = fsql_xstrndup("hello", 3);
    CHECK(s && strcmp(s, "hel") == 0, "xstrndup copies n bytes and terminates");
    free(s);
    CHECK(fsql_xstrdup(NULL) == NULL, "xstrdup(NULL) is NULL");
}

/* Randomized: build the same text through the builder and through a reference
 * buffer, in random chunk sizes, and require identical bytes. */
static void test_random(void) {
    srand(12345);
    for (int round = 0; round < 300; round++) {
        fsql_sb b; fsql_sb_init(&b);
        size_t cap = 1 << 16, n = 0;
        char *ref = malloc(cap);
        int parts = 1 + rand() % 200;
        for (int i = 0; i < parts; i++) {
            char chunk[300]; size_t cl = (size_t)(rand() % 250);
            for (size_t k = 0; k < cl; k++) chunk[k] = (char)(32 + rand() % 90);
            chunk[cl] = 0;
            if (n + cl + 1 >= cap) break;
            if (i % 3 == 0) fsql_sb_putn(&b, chunk, cl); else fsql_sb_printf(&b, "%s", chunk);
            memcpy(ref + n, chunk, cl); n += cl;
        }
        if (!(fsql_sb_ok(&b) && b.len == n && (n == 0 || memcmp(b.p, ref, n) == 0))) { CHECK(0, "random compose matches the reference"); }
        else checks++;
        free(ref); fsql_sb_free(&b);
    }
}

int main(void) {
    test_basic(); test_growth(); test_cap(); test_json(); test_vecd(); test_random();
    printf("buf_test: %d checks, %d failure(s)\n", checks, fails);
    return fails ? 1 : 0;
}
