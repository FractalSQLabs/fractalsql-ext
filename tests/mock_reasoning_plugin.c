/* tests/mock_reasoning_plugin.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Deterministic, file-driven mock reasoning plugin for build_test.sh's
 * text-to-sql gate. Implements the reasoning ABI (fsql_reasoning_init)
 * and returns, as the "LLM response", whatever SQL the harness has
 * written to /tmp/fractalsql_bt_sql.txt (wrapped in a ```sql fence).
 * Falls back to "SELECT 1" if the file is absent.
 *
 * The EMBED tier is modelled too: when the extension dispatches with
 * FSQL_REASONING_HTTP_MODE=embedding (the mode the extension forces for
 * its embedding tier), the mock returns a deterministic numeric array of
 * FSQL_MOCK_EMBED_DIM floats (default 3) derived from a hash of the
 * prompt -- same prompt, same vector; different prompts, different
 * vectors. That lets the vectorizer and the embed-coupled agents run end
 * to end without a live embeddings endpoint. The chat/t2s/review tiers
 * are unaffected: they dispatch with MODE unset.
 *
 * A fixed path is used on purpose: the backend is forked from the
 * postmaster and does NOT inherit the harness's environment, so we
 * cannot pass the path via an env var -- the harness writes the file,
 * the plugin reads it. Test-harness use only; never shipped.
 *
 * Build: cc -shared -fPIC -std=c99 -Iinclude \
 *          tests/mock_reasoning_plugin.c -o <tmp>/mock_reasoning_plugin.so
 */
#define _POSIX_C_SOURCE 200809L

#include "fractalsql_sql.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#endif

#define MOCK_SQL_FILE "/tmp/fractalsql_bt_sql.txt"

/* Failure injection. When this file exists its first line selects a misbehaviour for
 * every dispatch (a missing file means normal operation):
 *   rc          generate() reports failure (-1)          -- any tier
 *   empty       generate() answers with an empty string  -- any tier
 *   garbage     generate() answers with non-SQL, non-JSON text
 *   embed-rc    only the embedding tier reports failure
 *   embed-empty only the embedding tier answers "[]"
 *   embed-bad   only the embedding tier answers a malformed array
 * It lets tests drive the extension's outage / bad-reply paths without a flaky network. */
#define MOCK_FAIL_FILE "/tmp/fractalsql_bt_fail.txt"

static int
mock_fail_mode(char *buf, size_t n)
{
    FILE *f = fopen(MOCK_FAIL_FILE, "r");
    if (f == NULL)
        return 0;
    size_t k = fread(buf, 1, n - 1, f);
    fclose(f);
    buf[k] = '\0';
    while (k > 0 && (buf[k - 1] == '\n' || buf[k - 1] == '\r'))
        buf[--k] = '\0';
    return k > 0;
}

static void
mock_free_text(void *p)
{
    free(p);
}

static int
mock_canned(const char *text, char **response_out, size_t *response_len_out,
            void (**response_free_fn_out)(void *))
{
    char *r = (char *) malloc(strlen(text) + 1);
    if (r == NULL)
        return -1;
    strcpy(r, text);
    *response_out = r;
    *response_len_out = strlen(r);
    *response_free_fn_out = mock_free_text;
    return 0;
}

/* The critique round's answer, and the prompt it was given. The
 * critique dispatch is the only one whose prompt starts with
 * "Original request: ", so the fixture can tell the two apart without
 * the engine having to tag the tier. When this file is absent the
 * critique falls back to the fenced GENERATE answer -- which can never
 * PASS, so the review round always exhausts its attempts, exactly as
 * it does upstream. */
#define MOCK_REVIEW_FILE      "/tmp/fractalsql_bt_review.txt"
#define MOCK_REVIEW_PROMPT    "/tmp/fractalsql_bt_review_prompt.txt"
#define REVIEW_PROMPT_PREFIX  "Original request: "

/* Dumped fresh on every generate() call so gate_28_review_isolation can
 * tell which tier's dispatch last ran: REVIEW runs after GENERATE within
 * one fractal_text_to_sql() call, so the file reflects REVIEW's env.
 * Two lines land in the file: RESPONSE_MODE records what the init saw
 * (dlopen caches the module, so this shared static holds the LAST tier's
 * re-init value), and LIVE_RESPONSE_MODE records what the env actually
 * says at this dispatch -- the chat-after-t2s isolation check reads the
 * live line, since the init-captured one is stale by then. */
#define MOCK_RESPONSE_MODE_DUMP_FILE "/tmp/fractalsql_bt_review_env_dump.txt"

/* Captured at init, not re-read live in mock_generate(): the real plugin
 * reads RESPONSE_MODE once at init and keeps it for the loaded instance's
 * lifetime; a live getenv() here would always read as unset since
 * ensure_attached() unsets it right after T2S's load. */
static char g_response_mode_at_init[64] = "(unset)";

/* This fixture is built with MinGW gcc but loaded into an MSVC-built
 * sqlite3.exe -- getenv() reads MinGW's own CRT-private environment view,
 * which misses updates the host made through its own CRT.
 * GetEnvironmentVariableA reads the shared OS-level block instead. */
static const char *mock_getenv_response_mode(void) {
#ifdef _WIN32
    static char buf[64];
    DWORD n = GetEnvironmentVariableA(
        "FSQL_REASONING_HTTP_RESPONSE_MODE", buf, sizeof buf);
    return (n > 0 && n < sizeof buf) ? buf : NULL;
#else
    return getenv("FSQL_REASONING_HTTP_RESPONSE_MODE");
#endif
}

/* Same OS-level read as above, for the embed tier's MODE marker and the
 * mock's own dimension knob. */
static const char *mock_getenv(const char *name) {
#ifdef _WIN32
    static char buf[64];
    DWORD n = GetEnvironmentVariableA(name, buf, sizeof buf);
    return (n > 0 && n < sizeof buf) ? buf : NULL;
#else
    return getenv(name);
#endif
}

/* Same, with room for a URL: the endpoint a tier was loaded with is
 * longer than the mode marker and the dimension knob. */
static const char *mock_getenv_url(void) {
#ifdef _WIN32
    static char buf[256];
    DWORD n = GetEnvironmentVariableA("FSQL_REASONING_HTTP_URL", buf, sizeof buf);
    return (n > 0 && n < sizeof buf) ? buf : NULL;
#else
    return getenv("FSQL_REASONING_HTTP_URL");
#endif
}

/* FNV-1a over the prompt: the seed of the mock embedding. */
static unsigned long long
mock_hash(const char *s, size_t n) {
    unsigned long long h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) {
        h ^= (unsigned char) s[i];
        h *= 1099511628211ULL;
    }
    return h;
}

/* The embed tier's answer: a bare JSON array of `dim` floats in [-1, 1),
 * derived deterministically from the prompt. Written into `buf`, which
 * must hold at least dim * 24 + 3 bytes. Returns the number of bytes
 * written, or 0 if the buffer is too small. */
static size_t
mock_embedding(const char *prompt, size_t prompt_len, int dim, char *buf,
               size_t buf_size) {
    size_t need = (size_t) dim * 24 + 3;
    if (dim <= 0 || buf_size < need)
        return 0;

    unsigned long long h = mock_hash(prompt, prompt_len);
    size_t n = 0;
    buf[n++] = '[';
    for (int i = 0; i < dim; i++) {
        /* one 64-bit LCG step per dimension, mapped into [-1, 1) */
        h = h * 6364136223846793005ULL + 1442695040888963407ULL;
        double v = (double) (h >> 11) / 9007199254740992.0 * 2.0 - 1.0;
        if (i > 0)
            buf[n++] = ',';
        n += (size_t) snprintf(buf + n, buf_size - n, "%.17g", v);
    }
    buf[n++] = ']';
    buf[n] = '\0';
    return n;
}

/* The embedding dimension the mock answers with. FSQL_MOCK_EMBED_DIM
 * overrides it; the default matches the fixed vector the embed-tier
 * fixture plugin uses. */
static int
mock_embed_dim(void) {
    const char *d = mock_getenv("FSQL_MOCK_EMBED_DIM");
    if (d == NULL || *d == '\0')
        return 3;
    int v = atoi(d);
    return (v > 0 && v <= 4096) ? v : 3;
}

/* The prompt the engine hands to generate(). Every other tier answers
 * with the canned file regardless of the prompt, so the fixture keeps
 * the historical one-byte placeholder for them -- EXCEPT for the
 * critique round, whose prompt is the only way to recognise a review
 * dispatch, so that one is passed through verbatim. */
static int
mock_format(void *u, const char *q, size_t ql, const char *c, size_t cl,
            const char **prompt_out, size_t *prompt_len_out)
{
    (void) u; (void) c; (void) cl;
    static char b[2] = { 'x', '\0' };
    static char review[65536];
    size_t prefix = sizeof(REVIEW_PROMPT_PREFIX) - 1;

    if (q != NULL && ql >= prefix &&
        strncmp(q, REVIEW_PROMPT_PREFIX, prefix) == 0) {
        size_t n = ql < sizeof(review) - 1 ? ql : sizeof(review) - 1;
        memcpy(review, q, n);
        review[n] = '\0';
        *prompt_out = review;
        *prompt_len_out = n;
        return 0;
    }
    (void) ql;
    *prompt_out = b;
    *prompt_len_out = 1;
    return 0;
}

static void
mock_free(void *opaque)
{
    fsql_ai_response_t *r = (fsql_ai_response_t *) opaque;
    if (r != NULL && r->summary != NULL)
        free(r->summary);
}

/* Per-load state. The engine loads one plugin instance per reasoning
 * tier (chat / t2s / review / embed), and each tier's environment is
 * applied at LOAD time only -- a later tier's load must not change what
 * an already-loaded tier answers. The real HTTP plugin keeps its config
 * per instance for the same reason; this mock keeps the tier marker and
 * the init-captured response mode here instead of in file-scope
 * statics, which a second tier's init would otherwise clobber. */
#define MOCK_STATE_MAGIC 0x4D4B5354u /* "MKST" */

typedef struct {
    unsigned int magic;
    int          embed_mode;   /* loaded with FSQL_REASONING_HTTP_MODE=embedding */
    int          dim;          /* embedding width this instance answers with */
    char         response_mode_at_init[64];
    char         url_at_init[256];   /* the endpoint this instance loaded with */
} mock_state_t;

/* The instance state behind a callback's `user` pointer, or NULL when
 * the engine did not hand the plugin's own user_ctx back (in which case
 * the caller falls back to the live environment). The magic check keeps
 * this safe if `user` is ever something else entirely. */
static mock_state_t *
mock_state(void *u)
{
    mock_state_t *st = (mock_state_t *) u;
    if (st == NULL || st->magic != MOCK_STATE_MAGIC)
        return NULL;
    return st;
}

static int
mock_generate(void *u, const char *p, size_t pl,
              char **response_out, size_t *response_len_out,
              void (**response_free_fn_out)(void *))
{
    mock_state_t *st = mock_state(u);

    /* EMBED tier: the extension forces FSQL_REASONING_HTTP_MODE=embedding
     * for its embedding dispatch and expects a bare numeric array back
     * (the shape the real HTTP plugin hands back after extracting
     * data[0].embedding). Everything else -- chat, t2s, review -- runs
     * with MODE unset and takes the file-driven path below. The tier is
     * read from THIS instance's load-time marker first (the engine
     * applies each tier's environment when it loads that tier, and
     * applies nothing afterwards), falling back to the live environment
     * when the engine did not hand the instance state back. */
    int embed_mode = 0;
    int dim = mock_embed_dim();
    if (st != NULL) {
        embed_mode = st->embed_mode;
        dim = st->dim;
    } else {
        const char *mode = mock_getenv("FSQL_REASONING_HTTP_MODE");
        embed_mode = mode != NULL && strcmp(mode, "embedding") == 0;
    }
    char fail[64];
    if (mock_fail_mode(fail, sizeof fail))
    {
        if (strcmp(fail, "rc") == 0 || (embed_mode && strcmp(fail, "embed-rc") == 0))
            return -1;
        if (strcmp(fail, "empty") == 0)
            return mock_canned("", response_out, response_len_out, response_free_fn_out);
        if (strcmp(fail, "garbage") == 0)
            return mock_canned("<<not sql, not json>> ???", response_out, response_len_out,
                               response_free_fn_out);
        if (embed_mode && strcmp(fail, "embed-empty") == 0)
            return mock_canned("[]", response_out, response_len_out, response_free_fn_out);
        if (embed_mode && strcmp(fail, "embed-bad") == 0)
            return mock_canned("[0.5, \"x\", ", response_out, response_len_out,
                               response_free_fn_out);
    }
    if (embed_mode)
    {
        size_t need = (size_t) dim * 24 + 3;
        char  *emb = (char *) malloc(need);
        if (emb == NULL)
            return -1;
        if (mock_embedding(p != NULL ? p : "", p != NULL ? pl : 0, dim, emb,
                           need) == 0)
        {
            free(emb);
            return -1;
        }
        *response_out          = emb;
        *response_len_out      = strlen(emb);
        *response_free_fn_out  = mock_free;
        return 0;
    }

    char  sql[8192] = "SELECT 1";
    FILE *f = fopen(MOCK_SQL_FILE, "r");
    if (f == NULL) {
        /* The reply file is missing. The harness writes it moments before the
         * call and removes it when the run ends, so a run that overlaps this
         * one can take it away. Say so on stderr: the default answer below is
         * a valid statement, and without this line a gate that sees it cannot
         * tell a missing reply file from a real reply. */
        fprintf(stderr, "mock_reasoning_plugin: the canned reply file %s could not be opened -- answering the default\n",
                MOCK_SQL_FILE);
    }
    if (f != NULL)
    {
        size_t n = fread(sql, 1, sizeof(sql) - 1, f);
        sql[n] = '\0';
        while (n > 0 && (sql[n - 1] == '\n' || sql[n - 1] == '\r'))
            sql[--n] = '\0';
        fclose(f);
    }

    /* fractal_text_to_sql()'s GENERATE step loads its own reasoning
     * context with FSQL_REASONING_HTTP_RESPONSE_MODE=code -- under
     * that mode a real fractalsql-reasoning-http plugin already
     * strips the fence itself before generate() returns (its own
     * tested extract-and-fail-on-2+-blocks logic), so this mock does
     * no fence-stripping of its own either (that used to be
     * find_sql_span()/extract_sql_from_response(), removed when this
     * mode switch landed). This mock must model that same contract or
     * every gate driving it through fractal_text_to_sql() would see
     * literal ```sql fences as part of the "SQL" and fail to parse --
     * matching real reasoning-http's behavior, not the pre-refactor
     * shape. fractal_reason()'s own bare calls (gate 05/07) never set
     * RESPONSE_MODE, so they still get the fenced form here, same as
     * a real chat-mode response would look before any extraction.
     *
     * The dump is written on EVERY dispatch, the critique round
     * included: a review dispatch runs with RESPONSE_MODE unset, and
     * that is what the dump is there to show. */
    const char *response_mode = mock_getenv_response_mode();
    int         code_mode = response_mode != NULL && strcmp(response_mode, "code") == 0;

    FILE *dump = fopen(MOCK_RESPONSE_MODE_DUMP_FILE, "w");
    if (dump != NULL)
    {
        fprintf(dump, "RESPONSE_MODE=%s\n",
                st != NULL ? st->response_mode_at_init : g_response_mode_at_init);
        fprintf(dump, "LIVE_RESPONSE_MODE=%s\n",
                response_mode != NULL ? response_mode : "(unset)");
        fprintf(dump, "URL=%s\n",
                st != NULL ? st->url_at_init : "(unknown)");
        fclose(dump);
    }

    /* The critique round: recognised by its prompt. When the harness
     * has written a critique file, that file IS the answer, verbatim
     * and unfenced -- a critique is plain prose, and the engine reads
     * a leading PASS/FAIL off the first line. With no critique file
     * the fixture falls back to the fenced GENERATE answer, which can
     * never PASS, so the review round always exhausts its attempts. */
    int is_review = 0;
    if (p != NULL && pl >= sizeof(REVIEW_PROMPT_PREFIX) - 1 &&
        strncmp(p, REVIEW_PROMPT_PREFIX, sizeof(REVIEW_PROMPT_PREFIX) - 1) == 0)
        is_review = 1;

    if (is_review)
    {
        FILE *pf = fopen(MOCK_REVIEW_PROMPT, "w");
        if (pf != NULL)
        {
            fwrite(p, 1, pl, pf);
            fclose(pf);
        }
        FILE *rf = fopen(MOCK_REVIEW_FILE, "r");
        if (rf != NULL)
        {
            char *resp = malloc(pl + sizeof(sql) + 16);
            if (resp != NULL)
            {
                size_t n = fread(resp, 1, sizeof(sql) - 1, rf);
                resp[n] = '\0';
                while (n > 0 && (resp[n - 1] == '\n' || resp[n - 1] == '\r'))
                    resp[--n] = '\0';
                fclose(rf);
                *response_out         = resp;
                *response_len_out     = strlen(resp);
                *response_free_fn_out = mock_free;
                return 0;
            }
            fclose(rf);
        }
    }

    char *resp = malloc(strlen(sql) + 16);
    if (resp == NULL)
        return -1;
    if (code_mode)
        strcpy(resp, sql);
    else if (strstr(sql, "```") != NULL)
    {
        /* The canned answer already carries its own fence: the model
         * replied with a fenced block (plus prose around it), and a
         * real plugin hands such a reply on as it stands. Wrapping it
         * again would nest two fences and hide the inner one, so the
         * answer is passed through verbatim. */
        strcpy(resp, sql);
    }
    else
        snprintf(resp, strlen(sql) + 16, "```sql\n%s\n```", sql);
    *response_out         = resp;
    *response_len_out     = strlen(resp);
    *response_free_fn_out = mock_free;
    return 0;
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    const char *rm = mock_getenv_response_mode();
    snprintf(g_response_mode_at_init, sizeof g_response_mode_at_init,
             "%s", rm != NULL ? rm : "(unset)");

    /* This load's own state: the tier marker the engine set for this
     * tier's environment, and the response mode this instance saw. */
    mock_state_t *st = (mock_state_t *) calloc(1, sizeof(mock_state_t));
    if (st == NULL)
        return -1;
    st->magic = MOCK_STATE_MAGIC;
    const char *mode = mock_getenv("FSQL_REASONING_HTTP_MODE");
    st->embed_mode = mode != NULL && strcmp(mode, "embedding") == 0;
    st->dim = mock_embed_dim();
    snprintf(st->response_mode_at_init, sizeof st->response_mode_at_init,
             "%s", rm != NULL ? rm : "(unset)");
    /* The endpoint this load was given. Each tier points the extension's
     * own configuration at its own endpoint before loading, so this is
     * how a test tells which endpoint a tier actually reached. */
    const char *url = mock_getenv_url();
    snprintf(st->url_at_init, sizeof st->url_at_init,
             "%s", url != NULL ? url : "(unset)");

    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = st;
    vfs->format_prompt = mock_format;
    vfs->generate      = mock_generate;
    return 0;
}
