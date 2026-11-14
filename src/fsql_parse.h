/* src/fsql_parse.h -- the extension's parsers for UNTRUSTED text.
 *
 * The text-to-SQL tier takes a model's reply as its input: whatever the
 * model said is parsed here, and only what survives these functions is
 * ever handed to the allowlist. That makes this file the extension's
 * attack surface for a prompt-injected reply.
 *
 * They live in their own translation unit -- free of DuckDB -- for two
 * reasons: the module that uses them (src/fsql_t2s.c) is bound to DuckDB's
 * types, and a fuzzer (tests/fuzz/fuzz_t2s_parse.c) can only link a target
 * that has no engine in it. The libFuzzer gate (build_test.ps1 -Fuzz) drives
 * exactly these functions, so the surface the fuzzer covers is the surface
 * the extension actually parses.
 */
#ifndef FSQL_PARSE_H
#define FSQL_PARSE_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Case-insensitive compare of a literal at a position in a bounded text. */
bool fsql_ieq_at(const char *s, size_t slen, size_t pos, const char *lit);

/* The reply's SQL: the body of the first ```sql fence, else of the first
 * fence of any kind, else the whole text. The caller owns the result. */
char *fsql_extract_sql_candidate(const char *resp);

/* The first SQL keyword, skipping whitespace and comments; "" if none. */
void fsql_first_keyword(const char *sql, char *out, size_t cap);

/* A call to a state-changing extension function anywhere outside string
 * literals and comments, or NULL. */
const char *fsql_denied_function_call(const char *sql);

/* EXPLAIN (FORMAT json) names its operators as "name": "DELETE" ... */
bool fsql_plan_has_modifying_operator(const char *json);

#ifdef __cplusplus
}
#endif

#endif
