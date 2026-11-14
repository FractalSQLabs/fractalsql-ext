/* tests/fuzz/fuzz_t2s_parse.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * libFuzzer entry point for the text-to-SQL tier's reply parser: the
 * functions in src/fsql_parse.c, which turn a MODEL'S REPLY into the SQL
 * the extension is about to vet. The reply is untrusted input by
 * definition -- it is whatever a language model said, and a prompt-injected
 * model says whatever it likes -- so this is the extension's parser attack
 * surface, and it is worth a fuzzer.
 *
 * The input is one raw reply. The driver walks the same path the tier
 * takes: extract the candidate SQL, read its first keyword, look for a
 * call to a state-changing function, and read an EXPLAIN-shaped plan. Any
 * of them may return "not allowed" -- that is a refusal, not a finding.
 * A crash, a hang or a sanitizer report is the finding.
 *
 * Built and run by build_test.ps1's parse-fuzz gate (gate 47) and by
 * build_test.sh's (gate 47 there too). By hand:
 *   clang -O1 -g -fsanitize=fuzzer,address,undefined \
 *       -Isrc tests/fuzz/fuzz_t2s_parse.c src/fsql_parse.c src/fsql_buf.c \
 *       -o fuzz_t2s_parse
 */
#include "fsql_parse.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    /* The parsers work on NUL-terminated text, so a NUL inside the input
     * ends the reply: the tail is a second, shorter reply the parser never
     * sees. That is the shape the extension gets too (the reply arrives as
     * a C string). */
    char *reply = (char *)malloc(size + 1);
    if (reply == NULL) return 0;
    memcpy(reply, data, size);
    reply[size] = '\0';

    /* The candidate SQL the tier would vet. */
    char *sql = fsql_extract_sql_candidate(reply);
    if (sql != NULL) {
        char keyword[64];
        fsql_first_keyword(sql, keyword, sizeof keyword);
        (void)fsql_denied_function_call(sql);
        free(sql);
    }

    /* The same reads over the raw reply: the critique round compares the
     * model's verdict with a literal, and the plan check reads the EXPLAIN
     * output. */
    {
        char keyword[64];
        fsql_first_keyword(reply, keyword, sizeof keyword);
        (void)fsql_denied_function_call(reply);
        (void)fsql_plan_has_modifying_operator(reply);
        (void)fsql_ieq_at(reply, size, 0, "PASS");
    }

    free(reply);
    return 0;
}
