/* src/fsql_parse.c -- the parsers for the text-to-SQL tier's untrusted input.
 *
 * See src/fsql_parse.h for why these live apart from the module that calls
 * them. Everything here is plain C11 with no DuckDB in it: the libFuzzer
 * gate links this file and src/fsql_buf.c, and nothing else.
 */
#include "fsql_parse.h"

#include <ctype.h>
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

/* A call to a state-changing extension function anywhere outside string literals/comments, or NULL. */
const char *fsql_denied_function_call(const char *sql) {
    static const char *const kDenied[] = {
        "fractal_audit_log", "fractal_ledger_", "fractal_lock_destructive", "fractal_vectorizer_", "fractal_diversify_",
        "fractal_feedback_report", "fractal_isolate_background", "fractal_sql_agent", "fractal_agent_", "fractal_store_",
        "fractal_config_set", NULL };
    size_t n = strlen(sql), i = 0;
    while (i < n) {
        char c = sql[i];
        if (c == '\'' || c == '"') {
            char q = c; i++;
            while (i < n) {
                if (sql[i] == q) { if (i + 1 < n && sql[i + 1] == q) { i += 2; continue; } break; }
                i++;
            }
            i++;
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
            size_t j = i;
            while (j < n && isspace((unsigned char)sql[j])) j++;
            if (j < n && sql[j] == '(')
                for (int k = 0; kDenied[k]; k++)
                    if (!strncmp(name, kDenied[k], strlen(kDenied[k]))) return kDenied[k];
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
