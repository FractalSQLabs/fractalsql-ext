/* src/fsql_parse.c -- the parsers for the text-to-SQL tier's untrusted input.
 *
 * See src/fsql_parse.h for why these live apart from the module that calls
 * them. Everything here is plain C11 with no DuckDB in it: the libFuzzer
 * gate links this file and src/fsql_buf.c, and nothing else.
 */
#include "fsql_parse.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_buf.h"

bool fsql_ieq_at(const char *s, size_t slen, size_t pos, const char *lit) {
    size_t n = strlen(lit);
    if (pos + n > slen) return false;
    for (size_t i = 0; i < n; i++) if (tolower((unsigned char)s[pos + i]) != tolower((unsigned char)lit[i])) return false;
    return true;
}

/* The reply's SQL: the body of the first ```sql fence, else of the first fence of any kind, else the whole text. */
char *fsql_extract_sql_candidate(const char *resp) {
    size_t n = strlen(resp), p = 0;
    const char *f;
    while ((f = strstr(resp + p, "```")) != NULL) {
        size_t body = (size_t)(f - resp) + 3;
        bool tagged = fsql_ieq_at(resp, n, body, "sql") && (body + 3 >= n || isspace((unsigned char)resp[body + 3]));
        if (tagged) {
            size_t start = body + 3;
            const char *e = strstr(resp + start, "```");
            size_t end = e ? (size_t)(e - resp) : n;
            size_t a = start, b = end;
            while (a < b && isspace((unsigned char)resp[a])) a++;
            while (b > a && isspace((unsigned char)resp[b - 1])) b--;
            return fsql_xstrndup(resp + a, b - a);
        }
        p = body;
    }
    f = strstr(resp, "```");
    size_t start, end;
    if (f) {
        size_t fence = (size_t)(f - resp);
        const char *nl = strchr(resp + fence + 3, '\n');
        start = nl ? (size_t)(nl - resp) + 1 : fence + 3;
        const char *e = strstr(resp + start, "```");
        end = e ? (size_t)(e - resp) : n;
    } else { start = 0; end = n; }
    while (start < end && isspace((unsigned char)resp[start])) start++;
    while (end > start && isspace((unsigned char)resp[end - 1])) end--;
    return fsql_xstrndup(resp + start, end - start);
}

/* The review verdict. The reply's first word, after leading whitespace, is PASS in any case: the end of the reply or a
 * non-identifier character comes right after it. "Password column is missing", "Passage of time ..." and "PASS2 ..."
 * begin with the same four letters and are critiques. A critique read as a pass lets a bad candidate through; a pass
 * read as a critique only costs a retry. */
bool fsql_review_passed(const char *reply) {
    size_t n = reply ? strlen(reply) : 0, i = 0;
    while (i < n && isspace((unsigned char)reply[i])) i++;
    if (!fsql_ieq_at(reply, n, i, "PASS")) return false;
    return i + 4 >= n || !(isalnum((unsigned char)reply[i + 4]) || reply[i + 4] == '_');
}

/* The first SQL keyword, skipping whitespace and comments; "" if none. */
void fsql_first_keyword(const char *sql, char *out, size_t cap) {
    size_t n = strlen(sql), i = 0;
    out[0] = 0;
    for (;;) {
        while (i < n && isspace((unsigned char)sql[i])) i++;
        if (i + 1 < n && sql[i] == '-' && sql[i + 1] == '-') {
            const char *eol = strchr(sql + i, '\n');
            if (!eol) return;
            i = (size_t)(eol - sql) + 1;
            continue;
        }
        if (i + 1 < n && sql[i] == '/' && sql[i + 1] == '*') {
            const char *c = strstr(sql + i + 2, "*/");
            if (!c) return;
            i = (size_t)(c - sql) + 2;
            continue;
        }
        break;
    }
    if (i >= n) return;
    if (!isalpha((unsigned char)sql[i]) && sql[i] != '_') return;
    size_t start = i;
    while (i < n && (isalnum((unsigned char)sql[i]) || sql[i] == '_')) i++;
    size_t l = i - start;
    if (cap == 0) return;
    if (l >= cap) l = cap - 1;
    memcpy(out, sql + start, l); out[l] = 0;
}

/* The position of the next byte at or after `i` that is not whitespace and not inside a comment. The SQL parser treats
 * a comment as whitespace, so a call may have a comment between the function's name and its opening parenthesis. */
static size_t skip_ws_comments(const char *sql, size_t n, size_t i) {
    for (;;) {
        while (i < n && isspace((unsigned char)sql[i])) i++;
        if (i + 1 < n && sql[i] == '-' && sql[i + 1] == '-') { while (i < n && sql[i] != '\n') i++; continue; }
        if (i + 1 < n && sql[i] == '/' && sql[i + 1] == '*') {
            const char *e = strstr(sql + i + 2, "*/");
            i = e ? (size_t)(e - sql) + 2 : n;
            continue;
        }
        return i;
    }
}

static const char *denied_prefix(const char *name) {
    static const char *const kDenied[] = {
        "fractal_audit_log", "fractal_ledger_", "fractal_lock_destructive", "fractal_vectorizer_", "fractal_diversify_",
        "fractal_feedback_report", "fractal_isolate_background", "fractal_sql_agent", "fractal_agent_", "fractal_store_",
        "fractal_config_set", NULL };
    for (int k = 0; kDenied[k]; k++)
        if (!strncmp(name, kDenied[k], strlen(kDenied[k]))) return kDenied[k];
    return NULL;
}

/* A call to a state-changing extension function anywhere outside string literals/comments, or NULL.
 * A function is called by a bare name or by a double-quoted identifier ("fractal_audit_log"(...)), and the opening
 * parenthesis may be separated from the name by whitespace or a comment: all of those are calls. */
const char *fsql_denied_function_call(const char *sql) {
    size_t n = strlen(sql), i = 0;
    while (i < n) {
        char c = sql[i];
        if (c == '\'') {
            i++;
            while (i < n) {
                if (sql[i] == '\'') { if (i + 1 < n && sql[i + 1] == '\'') { i += 2; continue; } break; }
                i++;
            }
            i++;
            continue;
        }
        if (c == '$' && (i == 0 || !(isalnum((unsigned char)sql[i - 1]) || sql[i - 1] == '_' || sql[i - 1] == '$'))) {
            /* A dollar-quoted string, $tag$ ... $tag$ (the tag may be empty): DuckDB reads everything between the two
             * delimiters as a string, so a quote or a call inside is text, and a quote INSIDE it does not open anything.
             * Without this a lone ' in the string would open a "string" here that ends at the next quote and hide the
             * call after it. A "$" inside an identifier (a$b$) is part of the identifier, not a delimiter; "$1" is a
             * parameter. */
            size_t j = i + 1;
            if (j < n && !isdigit((unsigned char)sql[j])) {
                while (j < n && (isalnum((unsigned char)sql[j]) || sql[j] == '_')) j++;
                if (j < n && sql[j] == '$') {
                    size_t taglen = j - i + 1;
                    char tag[130];
                    if (taglen < sizeof tag) {
                        memcpy(tag, sql + i, taglen); tag[taglen] = 0;
                        const char *e = strstr(sql + j + 1, tag);
                        i = e ? (size_t)(e - sql) + taglen : n;
                        continue;
                    }
                }
            }
        }
        if (c == '"') {
            /* a quoted identifier: read it (a doubled quote is a literal quote); if a parenthesis follows it, it is a call */
            char name[128];
            size_t l = 0;
            i++;
            while (i < n) {
                if (sql[i] == '"') { if (i + 1 < n && sql[i + 1] == '"') { if (l + 1 < sizeof name) name[l++] = '"'; i += 2; continue; } break; }
                if (l + 1 < sizeof name) name[l++] = (char)tolower((unsigned char)sql[i]);
                i++;
            }
            i++;
            name[l] = 0;
            size_t j = skip_ws_comments(sql, n, i);
            if (j < n && sql[j] == '(') { const char *d = denied_prefix(name); if (d) return d; }
            continue;
        }
        if (c == '-' && i + 1 < n && sql[i + 1] == '-') { while (i < n && sql[i] != '\n') i++; continue; }
        if (c == '/' && i + 1 < n && sql[i + 1] == '*') {
            const char *e = strstr(sql + i + 2, "*/");
            i = e ? (size_t)(e - sql) + 2 : n;
            continue;
        }
        if (isalpha((unsigned char)c) || c == '_') {
            size_t start = i;
            while (i < n && (isalnum((unsigned char)sql[i]) || sql[i] == '_')) i++;
            char name[128];
            size_t l = i - start;
            if (l >= sizeof name) l = sizeof name - 1;
            for (size_t k = 0; k < l; k++) name[k] = (char)tolower((unsigned char)sql[start + k]);
            name[l] = 0;
            size_t j = skip_ws_comments(sql, n, i);
            if (j < n && sql[j] == '(') { const char *d = denied_prefix(name); if (d) return d; }
            continue;
        }
        i++;
    }
    return NULL;
}

/* EXPLAIN (FORMAT json) names its operators as "name": "DELETE" ... */
bool fsql_plan_has_modifying_operator(const char *json) {
    static const char *const ops[] = { "DELETE", "INSERT", "UPDATE", "MERGE_INTO", "MERGE", NULL };
    const char *p = json;
    while ((p = strstr(p, "\"name\"")) != NULL) {
        p += 6;
        while (*p == ' ' || *p == ':') p++;
        if (*p != '"') continue;
        p++;
        for (int k = 0; ops[k]; k++) {
            size_t l = strlen(ops[k]);
            if (!strncmp(p, ops[k], l) && p[l] == '"') return true;
        }
    }
    return false;
}

/* ------------------------------------------------------------------ chunking */

/* the whole JSON result is capped: a 20 KB text with a large overlap would otherwise expand to gigabytes (size x chunks) */
#define FSQL_CHUNK_MAX_OUT ((size_t) 64 * 1024 * 1024)
typedef struct { char *b; size_t n, cap; int oom; int big; } ChunkBuf;

static void cb_put(ChunkBuf *o, const char *s, size_t len)
{
    if (o->oom || o->big) return;
    if (len > FSQL_CHUNK_MAX_OUT || o->n > FSQL_CHUNK_MAX_OUT - len) { o->big = 1; return; }
    if (o->n + len + 1 > o->cap) {
        size_t nc = o->cap ? o->cap : 256;
        char *nb;
        while (nc < o->n + len + 1) nc *= 2;
        nb = (char *) realloc(o->b, nc);
        if (!nb) { o->oom = 1; return; }
        o->b = nb; o->cap = nc;
    }
    memcpy(o->b + o->n, s, len); o->n += len; o->b[o->n] = '\0';
}

typedef struct { size_t *cp; size_t n; const unsigned char *t; size_t blen; } ChunkCps;

static int cps_build(ChunkCps *c, const unsigned char *t, size_t blen)
{
    size_t i = 0;
    c->t = t; c->blen = blen; c->n = 0;
    c->cp = (size_t *) malloc((blen + 1) * sizeof(size_t));
    if (!c->cp) return -1;
    while (i < blen) {
        unsigned char b = t[i];
        size_t len = b < 0x80 ? 1 : (b >= 0xF0 && b <= 0xF4) ? 4 : (b >= 0xE0) ? 3 : (b >= 0xC2) ? 2 : 1, k = 1;
        c->cp[c->n++] = i;
        if (b >= 0xF5) len = 1;
        while (k < len && i + k < blen && (t[i + k] & 0xC0) == 0x80) k++;
        i += (k == len) ? len : 1;       /* a truncated or invalid sequence is one character per byte */
    }
    c->cp[c->n] = blen;
    return 0;
}

static int chunk_is_ws(unsigned char b) { return b == ' ' || b == '\t' || b == '\r' || b == '\n'; }

/* the character at index i as a single byte when it is ASCII, else 0xFF */
static unsigned char cps_ascii(const ChunkCps *c, size_t i)
{
    size_t b = c->cp[i];
    return c->t[b] < 0x80 ? c->t[b] : 0xFF;
}

static void chunk_emit(ChunkBuf *o, const ChunkCps *c, size_t no, size_t a, size_t b)
{
    char tmp[96];
    int l = snprintf(tmp, sizeof tmp, "%s{\"no\":%lld,\"start\":%lld,\"end\":%lld,\"text\":\"", no ? "," : "", (long long) no, (long long) a, (long long) b);
    cb_put(o, tmp, (size_t) l);
    for (size_t i = c->cp[a]; i < c->cp[b]; i++) {
        unsigned char ch = c->t[i];
        if (ch >= 0x80) {
            /* a byte that does not belong to a well-formed UTF-8 character is written as U+FFFD, so the JSON stays valid UTF-8 */
            size_t need = ch >= 0xF0 ? 4 : ch >= 0xE0 ? 3 : 2, ln = 1;
            while (i + ln < c->cp[b] && (c->t[i + ln] & 0xC0) == 0x80 && ln < need) ln++;
            int okc = 0;
            if (ch >= 0xC2 && ch <= 0xDF) okc = ln == 2;
            else if (ch >= 0xE0 && ch <= 0xEF) okc = ln == 3 && !(ch == 0xE0 && c->t[i + 1] < 0xA0) && !(ch == 0xED && c->t[i + 1] >= 0xA0);
            else if (ch >= 0xF0 && ch <= 0xF4) okc = ln == 4 && !(ch == 0xF0 && c->t[i + 1] < 0x90) && !(ch == 0xF4 && c->t[i + 1] >= 0x90);
            if (!okc) { cb_put(o, "\\ufffd", 6); continue; }
            cb_put(o, (const char *) &c->t[i], ln);
            i += ln - 1;
            continue;
        }
        if (ch == '"') cb_put(o, "\\\"", 2);
        else if (ch == '\\') cb_put(o, "\\\\", 2);
        else if (ch == '\n') cb_put(o, "\\n", 2);
        else if (ch == '\r') cb_put(o, "\\r", 2);
        else if (ch == '\t') cb_put(o, "\\t", 2);
        else if (ch < 0x20) { l = snprintf(tmp, sizeof tmp, "\\u%04x", ch); cb_put(o, tmp, (size_t) l); }
        else cb_put(o, (const char *) &c->t[i], 1);   /* a raw byte: UTF-8 passes through unchanged */
    }
    cb_put(o, "\"}", 2);
}

/* the span [a,b) split into pieces of at most size characters, overlap shared; the new chunk count, or (size_t)-1 over the cap */
static size_t chunk_split(ChunkBuf *o, const ChunkCps *c, size_t no, size_t a, size_t b, size_t size, size_t overlap)
{
    size_t pos = a;
    for (;;) {
        size_t e = pos + size < b ? pos + size : b;
        if (no >= FSQL_CHUNK_MAX_CHUNKS || o->big) return (size_t) -1;
        chunk_emit(o, c, no++, pos, e);
        if (e >= b) break;
        pos = e - overlap;
    }
    return no;
}

int fsql_chunk_text(const unsigned char *t, size_t blen, long size, long overlap, int mode, char **out)
{
    ChunkCps c;
    ChunkBuf o = { NULL, 0, 0, 0, 0 };
    size_t no = 0, S = (size_t) size, V = (size_t) overlap, n;
    int over = 0;
    *out = NULL;
    if (cps_build(&c, t, blen) != 0) return -1;
    n = c.n;
    cb_put(&o, "[", 1);
    if (mode == 0) {
        if (n > 0) { no = chunk_split(&o, &c, 0, 0, n, S, V); over = no == (size_t) -1; }
    } else {
        size_t cur_a = 0, cur_b = 0, i = 0;
        int have = 0;
        while (i < n && !over) {
            size_t ua, ub;
            while (i < n && chunk_is_ws(cps_ascii(&c, i))) i++;
            if (i >= n) break;
            ua = i;
            for (;;) {                       /* extend to the end of the unit */
                unsigned char ch;
                if (i >= n) { ub = n; break; }
                ch = cps_ascii(&c, i);
                if (chunk_is_ws(ch)) {       /* whitespace: a paragraph break, or (sentence mode) just a separator? */
                    size_t j = i; int lf = 0;
                    while (j < n && chunk_is_ws(cps_ascii(&c, j))) { if (cps_ascii(&c, j) == '\n') lf++; j++; }
                    if (lf >= 2) { ub = i; i = j; break; }
                    i = j;
                    continue;
                }
                i++;
                if (mode == 2 && (ch == '.' || ch == '!' || ch == '?')) {
                    while (i < n && (cps_ascii(&c, i) == '.' || cps_ascii(&c, i) == '!' || cps_ascii(&c, i) == '?')) i++;
                    if (i >= n || chunk_is_ws(cps_ascii(&c, i))) { ub = i; break; }
                }
            }
            while (ub > ua && chunk_is_ws(cps_ascii(&c, ub - 1))) ub--;
            if (ub == ua) continue;
            if (ub - ua > S) {               /* longer than a chunk: flush, then split it */
                if (have) { chunk_emit(&o, &c, no++, cur_a, cur_b); have = 0; }
                no = chunk_split(&o, &c, no, ua, ub, S, V);
                if (no == (size_t) -1) over = 1;
            } else if (!have) { cur_a = ua; cur_b = ub; have = 1; }
            else if (ub - cur_a <= S) { cur_b = ub; }
            else { chunk_emit(&o, &c, no++, cur_a, cur_b); cur_a = ua; cur_b = ub; }
            if (!over && (no >= FSQL_CHUNK_MAX_CHUNKS || o.big)) over = 1;
        }
        if (have && !over) chunk_emit(&o, &c, no++, cur_a, cur_b);
    }
    free(c.cp);
    cb_put(&o, "]", 1);
    if (o.oom) { free(o.b); return -1; }
    if (over || o.big) { free(o.b); return 1; }
    *out = o.b;
    return 0;
}
