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
/* true when the review reply is a pass: the word PASS (any case) at the front, not the letters of a longer word */
bool fsql_review_passed(const char *reply);

/* EXPLAIN (FORMAT json) names its operators as "name": "DELETE" ... */
bool fsql_plan_has_modifying_operator(const char *json);

/* Split text into chunks of at most `size` characters (code points) and write a malloc'd JSON array of {"no","start","end","text"} to *out
 * (free() it). mode: 0 fixed, 1 paragraph, 2 sentence. The same algorithm, with the same output, runs in every FractalSQL host. Returns 0,
 * or 1 when more than 100000 chunks would be produced, or -1 on out of memory. size must be 1..100000 and overlap 0..size-1 (the caller checks). */
#define FSQL_CHUNK_MAX_SIZE   100000
#define FSQL_CHUNK_MAX_CHUNKS 100000
int fsql_chunk_text(const unsigned char *t, size_t blen, long size, long overlap, int mode, char **out);

#ifdef __cplusplus
}
#endif

#endif
