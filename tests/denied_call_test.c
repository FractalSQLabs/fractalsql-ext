/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * fsql_denied_function_call: the calls a generated statement may not make, in every spelling the SQL parser accepts.
 * Built and run by build_test.sh's denied-call check:
 *   cc -std=c11 -Isrc tests/denied_call_test.c src/fsql_parse.c src/fsql_buf.c -o denied_call_test && ./denied_call_test
 */
#include "fsql_parse.h"

#include <stdio.h>

static int failures;

static void expect(const char *sql, int denied, const char *why) {
    const char *got = fsql_denied_function_call(sql);
    if ((got != NULL) != (denied != 0)) {
        printf("FAIL %s: %s -> %s\n", why, sql, got ? got : "(allowed)");
        failures++;
    }
}

int main(void) {
    /* the plain forms */
    expect("SELECT fractal_audit_log('x')", 1, "bare name");
    expect("SELECT FRACTAL_AUDIT_LOG ('x')", 1, "upper case, space before the parenthesis");
    expect("SELECT fractal_ledger_verify()", 1, "prefix match");
    expect("SELECT main.fractal_audit_log('x')", 1, "schema qualified");
    /* the spellings that used to get through */
    expect("SELECT fractal_audit_log/**/('x')", 1, "block comment before the parenthesis");
    expect("SELECT fractal_audit_log /* c */ ('x')", 1, "block comment with spaces");
    expect("SELECT fractal_audit_log -- c\n('x')", 1, "line comment before the parenthesis");
    expect("SELECT \"fractal_audit_log\"('x')", 1, "quoted identifier");
    expect("SELECT \"FRACTAL_AUDIT_LOG\" ('x')", 1, "quoted identifier, upper case, space");
    expect("SELECT \"fractal_audit_log\"/**/('x')", 1, "quoted identifier and a comment");
    expect("SELECT main.\"fractal_ledger_truth_count\"(1)", 1, "schema qualified quoted identifier");
    /* things that are not calls */
    expect("SELECT 1", 0, "no call");
    expect("SELECT 'fractal_audit_log(1)'", 0, "inside a string literal");
    expect("SELECT 1 -- fractal_audit_log('x')", 0, "inside a line comment");
    expect("SELECT 1 /* fractal_audit_log('x') */", 0, "inside a block comment");
    expect("SELECT fractal_audit_log FROM t", 0, "a column with that name, no parenthesis");
    expect("SELECT \"fractal_audit_log\" FROM t", 0, "a quoted column with that name");
    expect("SELECT \"a b\"(1)", 0, "a quoted name that is not denied");
    expect("SELECT fractal_vector_norm('[3,4]')", 0, "an allowed extension function");
    /* dollar-quoted strings (DuckDB reads $tag$ ... $tag$ as a string) */
    expect("SELECT $$ ' $$ , fractal_audit_log('x')", 1, "a lone quote inside a dollar-quoted string must not hide the call");
    expect("SELECT $tag$ ' $tag$ , fractal_audit_log('x')", 1, "a tagged dollar quote");
    expect("SELECT $a1$ $$ ' $a1$ , fractal_ledger_flush(1)", 1, "a different delimiter inside a tagged quote");
    expect("SELECT $$fractal_audit_log('x')$$", 0, "a call inside a dollar-quoted string is text");
    expect("SELECT $t$fractal_audit_log('x')$t$ AS s", 0, "a call inside a tagged dollar-quoted string is text");
    expect("SELECT a$b$ , fractal_audit_log('x')", 1, "a dollar sign inside an identifier is not a delimiter");
    expect("SELECT $1, fractal_audit_log('x')", 1, "a parameter is not a delimiter");
    expect("SELECT $$ never closed fractal_audit_log('x')", 0, "an unterminated dollar quote runs to the end");
    /* nested block comments (DuckDB nests them) are read as the scanner's first close: more text is visible, never less */
    expect("SELECT /* a /* b */ fractal_audit_log('x') */ 1", 1, "text after a nested comment's inner close is still scanned");
    /* unterminated forms must not crash or run past the end */
    expect("SELECT \"fractal_audit_log", 0, "unterminated quoted identifier");
    expect("SELECT fractal_audit_log /* never closed", 0, "unterminated comment");
    expect("SELECT fractal_audit_log --", 0, "comment to the end");
    /* the review verdict */
    {
        struct { const char *reply; int pass; const char *why; } v[] = {
            { "PASS", 1, "PASS" }, { "pass", 1, "lower case" }, { "Pass", 1, "mixed case" },
            { "  \n PASS", 1, "leading whitespace" }, { "PASS: matches the question", 1, "a reason" },
            { "PASS\nlooks right", 1, "a reason on the next line" }, { "PASS.", 1, "a full stop" },
            { "FAIL: wrong table", 0, "FAIL" }, { "The statement is fine. PASS", 0, "not at the front" },
            { "It selects the wrong column.", 0, "a critique" }, { "", 0, "empty" },
            { "Password column is missing", 0, "a word that starts with pass" },
            { "Passage of time is not modelled", 0, "another" }, { "PASS2 is not a verdict", 0, "a digit after PASS" },
            { "PASS_THROUGH", 0, "an underscore after PASS" }, { "PAS", 0, "too short" },
        };
        for (size_t i = 0; i < sizeof v / sizeof v[0]; i++)
            if (fsql_review_passed(v[i].reply) != v[i].pass) {
                printf("FAIL review verdict (%s): %s\n", v[i].why, v[i].reply);
                failures++;
            }
    }
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("denied_call_test: all cases pass\n");
    return 0;
}
