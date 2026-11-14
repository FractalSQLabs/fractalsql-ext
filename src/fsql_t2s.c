/* src/fsql_t2s.c
 *
 * Schema introspection and text-to-SQL. This TU is being ported function by
 * function; what is here so far:
 *
 *   fractal_schema_context([table_names VARCHAR[] [, query_hint VARCHAR]]) -> VARCHAR
 *       A prompt-ready description of the visible schema: one block per table with its
 *       columns, types, PRIMARY KEY / NOT NULL markers, and a FOREIGN KEYS section. Pure
 *       catalog introspection -- no LLM call, no fsql_ctx. Runs against DuckDB's own
 *       information_schema.columns and duckdb_constraints() through the nested-query pool.
 *       query_hint is accepted for forward compatibility with table-subset ranking and is
 *       not used yet. Table/column COMMENT text is not included (DuckDB's introspection
 *       surface for it varies by version); PK and FK relationships are.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ctype.h>

#include "fsql_duckdb_internal.h"
#include "fsql_parse.h"
#include "fsql_port.h"

/* ------------------------------------------------------------------ */
/* Small helpers                                                        */
/* ------------------------------------------------------------------ */

/* SQL string literal: 'text' with embedded single quotes doubled. */
static void put_quoted(fsql_sb *b, const char *s, size_t n) {
    fsql_sb_putc(b, '\'');
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '\'') fsql_sb_putc(b, '\'');
        fsql_sb_putc(b, s[i]);
    }
    fsql_sb_putc(b, '\'');
}

/* A VARCHAR cell of chunk column `c` at `row`, as a malloc'd string ("" for NULL). */
static char *chunk_str(duckdb_data_chunk ch, idx_t c, idx_t row) {
    duckdb_vector v = duckdb_data_chunk_get_vector(ch, c);
    if (!fsql_valid(duckdb_vector_get_validity(v), row)) return fsql_xstrdup("");
    size_t n; const char *p = fsql_str_data(&((const duckdb_string_t *)duckdb_vector_get_data(v))[row], &n);
    return fsql_xstrndup(p, n);
}

/* The elements of a LIST(VARCHAR) cell, each malloc'd; *out is a malloc'd array of *n pointers. */
static bool chunk_str_list(duckdb_data_chunk ch, idx_t c, idx_t row, char ***out, size_t *n) {
    *out = NULL; *n = 0;
    duckdb_vector v = duckdb_data_chunk_get_vector(ch, c);
    if (!fsql_valid(duckdb_vector_get_validity(v), row)) return true;
    duckdb_list_entry e = ((const duckdb_list_entry *)duckdb_vector_get_data(v))[row];
    duckdb_vector child = duckdb_list_vector_get_child(v);
    const duckdb_string_t *cd = (const duckdb_string_t *)duckdb_vector_get_data(child);
    const uint64_t *cv = duckdb_vector_get_validity(child);
    if (e.offset > UINT64_MAX - e.length || e.offset + e.length > duckdb_list_vector_get_size(v)) return false;
    char **arr = (char **)fsql_xmalloc_array((size_t)e.length ? (size_t)e.length : 1, sizeof(char *));
    if (!arr) return false;
    for (idx_t k = 0; k < e.length; k++) {
        size_t ln = 0; const char *p = "";
        if (fsql_valid(cv, e.offset + k)) p = fsql_str_data(&cd[e.offset + k], &ln);
        arr[k] = fsql_xstrndup(p, ln);
        if (!arr[k]) { for (idx_t j = 0; j < k; j++) free(arr[j]); free(arr); return false; }
    }
    *out = arr; *n = (size_t)e.length;
    return true;
}

#define ERRBUF 4096

static void free_str_list(char **a, size_t n) {
    for (size_t i = 0; i < n; i++) free(a[i]);
    free(a);
}

/* (table, column) primary-key pairs. */
typedef struct { char *table, *col; } pk_pair;
typedef struct { pk_pair *p; size_t n, cap; } pk_list;

static bool pk_add(pk_list *l, const char *table, const char *col) {
    if (l->n == l->cap) {
        size_t nc = l->cap ? l->cap * 2 : 32;
        pk_pair *np = (pk_pair *)realloc(l->p, nc * sizeof *np);
        if (!np) return false;
        l->p = np; l->cap = nc;
    }
    l->p[l->n].table = fsql_xstrdup(table);
    l->p[l->n].col = fsql_xstrdup(col);
    if (!l->p[l->n].table || !l->p[l->n].col) return false;
    l->n++;
    return true;
}
static bool pk_has(const pk_list *l, const char *table, const char *col) {
    for (size_t i = 0; i < l->n; i++) if (!strcmp(l->p[i].table, table) && !strcmp(l->p[i].col, col)) return true;
    return false;
}
static void pk_free(pk_list *l) {
    for (size_t i = 0; i < l->n; i++) { free(l->p[i].table); free(l->p[i].col); }
    free(l->p);
}

/* ------------------------------------------------------------------ */
/* fractal_schema_context                                               */
/* ------------------------------------------------------------------ */

/* "true" for no filter (every table in the search path), else "table_name IN ('a', 'b')". */
static void table_filter(fsql_sb *b, char *const *names, size_t n) {
    if (n == 0) { fsql_sb_puts(b, "true"); return; }
    fsql_sb_puts(b, "table_name IN (");
    for (size_t i = 0; i < n; i++) { if (i) fsql_sb_puts(b, ", "); put_quoted(b, names[i], strlen(names[i])); }
    fsql_sb_putc(b, ')');
}

/* Builds the description. Returns a malloc'd string, or NULL with `err` set. */
static char *build_schema_context(fsql_instance *inst, char *const *names, size_t nnames, char *err, size_t errcap) {
    fsql_sb filter; fsql_sb_init(&filter);
    table_filter(&filter, names, nnames);
    fsql_sb q1, q2, q3; fsql_sb_init(&q1); fsql_sb_init(&q2); fsql_sb_init(&q3);
    fsql_sb_printf(&q1, "SELECT table_name, column_name, data_type, is_nullable FROM information_schema.columns WHERE %s "
                        "ORDER BY table_name, ordinal_position", fsql_sb_cstr(&filter));
    fsql_sb_printf(&q2, "SELECT table_name, constraint_column_names FROM duckdb_constraints() "
                        "WHERE constraint_type = 'PRIMARY KEY' AND %s", fsql_sb_cstr(&filter));
    fsql_sb_printf(&q3, "SELECT table_name, constraint_column_names, referenced_table, referenced_column_names "
                        "FROM duckdb_constraints() WHERE referenced_table IS NOT NULL AND %s", fsql_sb_cstr(&filter));

    fsql_qres cols = {0}, pks = {0}, fks = {0};
    pk_list pk = {0};
    fsql_sb out; fsql_sb_init(&out);
    char *result = NULL;
    duckdb_data_chunk ch;

    if (!fsql_sb_ok(&q1) || !fsql_sb_ok(&q2) || !fsql_sb_ok(&q3)) { snprintf(err, errcap, "fractalsql: out of memory"); goto done; }
    if (fsql_nested_query(inst, fsql_sb_cstr(&q1), &cols, err, errcap)) goto done;
    if (fsql_nested_query(inst, fsql_sb_cstr(&q2), &pks, err, errcap)) goto done;
    if (fsql_nested_query(inst, fsql_sb_cstr(&q3), &fks, err, errcap)) goto done;

    /* table -> primary-key columns, for the PRIMARY KEY / NOT NULL markers below */
    while ((ch = fsql_qres_next_chunk(&pks)) != NULL) {
        idx_t rows = duckdb_data_chunk_get_size(ch);
        for (idx_t i = 0; i < rows; i++) {
            char *t = chunk_str(ch, 0, i); char **cs; size_t cn;
            if (!chunk_str_list(ch, 1, i, &cs, &cn)) { free(t); duckdb_destroy_data_chunk(&ch); snprintf(err, errcap, "fractalsql: out of memory"); goto done; }
            for (size_t k = 0; k < cn; k++) if (!pk_add(&pk, t, cs[k])) { free_str_list(cs, cn); free(t); duckdb_destroy_data_chunk(&ch); snprintf(err, errcap, "fractalsql: out of memory"); goto done; }
            free_str_list(cs, cn); free(t);
        }
        duckdb_destroy_data_chunk(&ch);
    }

    char *current = NULL;
    while ((ch = fsql_qres_next_chunk(&cols)) != NULL) {
        idx_t rows = duckdb_data_chunk_get_size(ch);
        for (idx_t i = 0; i < rows; i++) {
            char *tname = chunk_str(ch, 0, i), *cname = chunk_str(ch, 1, i), *ctype = chunk_str(ch, 2, i), *isnull = chunk_str(ch, 3, i);
            if (!tname || !cname || !ctype || !isnull) { free(tname); free(cname); free(ctype); free(isnull); free(current); duckdb_destroy_data_chunk(&ch); snprintf(err, errcap, "fractalsql: out of memory"); goto done; }
            if (!current || strcmp(tname, current) != 0) {
                if (current) fsql_sb_putc(&out, '\n');
                fsql_sb_printf(&out, "TABLE %s:\n", tname);
                free(current); current = fsql_xstrdup(tname);
            }
            bool is_pk = pk_has(&pk, tname, cname);
            fsql_sb_printf(&out, "  %s %s", cname, ctype);
            if (is_pk) fsql_sb_puts(&out, " PRIMARY KEY");
            if (strcmp(isnull, "YES") != 0 && !is_pk) fsql_sb_puts(&out, " NOT NULL");
            fsql_sb_putc(&out, '\n');
            free(tname); free(cname); free(ctype); free(isnull);
            /* Abort mid-build once the description can no longer serve as a prompt component: do not
             * accumulate an unbounded buffer just to fail the final size check. */
            if (out.len > FSQL_MAX_INPUT_BYTES) {
                free(current); duckdb_destroy_data_chunk(&ch);
                snprintf(err, errcap, "fractal_schema_context: schema description exceeds the 4 MiB input cap -- scope the schema before calling");
                goto done;
            }
        }
        duckdb_destroy_data_chunk(&ch);
    }
    free(current);

    bool any_fk = false;
    while ((ch = fsql_qres_next_chunk(&fks)) != NULL) {
        idx_t rows = duckdb_data_chunk_get_size(ch);
        for (idx_t i = 0; i < rows; i++) {
            if (!any_fk) { fsql_sb_puts(&out, "\nFOREIGN KEYS:\n"); any_fk = true; }
            char *tname = chunk_str(ch, 0, i), *rtable = chunk_str(ch, 2, i);
            char **cs, **rcs; size_t cn, rn;
            if (!chunk_str_list(ch, 1, i, &cs, &cn) || !chunk_str_list(ch, 3, i, &rcs, &rn)) {
                free(tname); free(rtable); duckdb_destroy_data_chunk(&ch); snprintf(err, errcap, "fractalsql: out of memory"); goto done;
            }
            fsql_sb_printf(&out, "  %s(", tname);
            for (size_t j = 0; j < cn; j++) fsql_sb_printf(&out, "%s%s", j ? ", " : "", cs[j]);
            fsql_sb_printf(&out, ") -> %s(", rtable);
            for (size_t j = 0; j < rn; j++) fsql_sb_printf(&out, "%s%s", j ? ", " : "", rcs[j]);
            fsql_sb_puts(&out, ")\n");
            free_str_list(cs, cn); free_str_list(rcs, rn); free(tname); free(rtable);
        }
        duckdb_destroy_data_chunk(&ch);
    }

    /* A database with no visible tables (or a filter that names none) has no schema to describe: that is
     * an error, not an empty rendering, so a caller cannot mistake "no schema" for "no columns". */
    if (!fsql_sb_ok(&out)) { snprintf(err, errcap, "fractalsql: out of memory"); goto done; }
    if (out.len == 0) { snprintf(err, errcap, "fractal_schema_context: no visible tables found"); goto done; }
    if (out.len > FSQL_MAX_INPUT_BYTES) {
        snprintf(err, errcap, "fractal_schema_context: schema description exceeds the 4 MiB input cap -- scope the schema before calling");
        goto done;
    }
    result = fsql_sb_take(&out);
done:
    fsql_sb_free(&out);
    pk_free(&pk);
    fsql_qres_free(&cols); fsql_qres_free(&pks); fsql_qres_free(&fks);
    fsql_sb_free(&filter); fsql_sb_free(&q1); fsql_sb_free(&q2); fsql_sb_free(&q3);
    return result;
}

/* Each named table costs several catalog round-trips, so an enormous caller-supplied array is a cheap way
 * to fan out a lot of introspection work; 512 is far above any realistic hand-authored request. The
 * auto-discover path (no table list) is naturally bounded by what is in the catalog. */
static void schema_context_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    fsql_instance *inst = fsql_scalar_instance(info);
    idx_t n = duckdb_data_chunk_get_size(in);
    idx_t ncols = duckdb_data_chunk_get_column_count(in);
    for (idx_t i = 0; i < n; i++) {
        char **names = NULL; size_t nn = 0;
        if (ncols > 0 && !chunk_str_list(in, 0, i, &names, &nn)) { fsql_fn_error(info, "fractalsql: out of memory"); return; }
        if (nn > FSQL_T2S_MAX_TABLES) {
            size_t got = nn;
            free_str_list(names, nn);
            fsql_fn_error(info, "fractal_schema_context: %zu tables requested, exceeds the limit of %d -- pass a smaller "
                                "table_names[] scoped to the tables the question actually needs", got, FSQL_T2S_MAX_TABLES);
            return;
        }
        char err[2048];
        char *ctx = build_schema_context(inst, names, nn, err, sizeof err);
        free_str_list(names, nn);
        if (!ctx) { fsql_fn_error(info, "%s", err); return; }
        fsql_set_str(out, i, ctx, strlen(ctx));
        free(ctx);
    }
}


/* ------------------------------------------------------------------ */
/* Text-to-SQL                                                          */
/*                                                                      */
/*   fractal_text_to_sql(question VARCHAR [, table_names VARCHAR[]]) -> VARCHAR                       */
/*   fractal_sql_agent(question, table_names VARCHAR[], max_retries INTEGER, auto_execute BOOLEAN)    */
/*       -> TABLE(generated_sql, execution_status, retry_count, result_json)                          */
/*                                                                      */
/* The pipeline: describe the named tables to the T2S-tier plugin, take its reply, pull the SQL out   */
/* of it, vet it against the allowlist, EXPLAIN it, optionally have the REVIEW tier critique it, and  */
/* retry with the rejection reason threaded back. fractal_text_to_sql NEVER executes what it returns. */
/*                                                                      */
/* Allowlist: SELECT/WITH only (plus INSERT/UPDATE with                                               */
/* FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update); exactly one statement; no call to */
/* a state-changing fractal_* function; no data-modifying CTE. The C API has no parser, so statements */
/* are classified with duckdb_extract_statements + duckdb_prepared_statement_type, and a WITH is      */
/* additionally checked against EXPLAIN (FORMAT json) for DELETE/INSERT/UPDATE/MERGE operators --      */
/* DuckDB 2.0 reports a modifying CTE as a SELECT.                                                    */
/* ------------------------------------------------------------------ */

#define MAX_FEEDBACK_BYTES 8192

static void t2s_jstr(fsql_sb *b, const char *s) {
    if (!s) s = "";      /* a name whose copy failed (out of memory): the prompt is only descriptive, the pipeline stays safe */
    fsql_sb_putc(b, '"');
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"':  fsql_sb_puts(b, "\\\""); break;
        case '\\': fsql_sb_puts(b, "\\\\"); break;
        case '\n': fsql_sb_puts(b, "\\n"); break;
        case '\r': fsql_sb_puts(b, "\\r"); break;
        case '\t': fsql_sb_puts(b, "\\t"); break;
        default:
            if (*p < 0x20) fsql_sb_printf(b, "\\u%04x", *p);
            else fsql_sb_putc(b, (char)*p);
        }
    }
    fsql_sb_putc(b, '"');
}

/* Vets `sql`. Returns 0 = allowed, 1 = refused (reason in `why`), -1 = internal failure (err). */
static int check_statement_allowed(fsql_instance *inst, const char *sql, bool allow_write, char *why, size_t why_cap, char *err) {
    char word[64];
    fsql_first_keyword(sql, word, sizeof word);
    why[0] = 0;
    if (!word[0]) { snprintf(why, why_cap, "statement is empty or does not start with an SQL keyword"); return 1; }
    const char *policy = allow_write ? "select_insert_update" : "select";
#define REFUSED() do { snprintf(why, why_cap, "statement type \"%s\" is not permitted -- FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS is set to \"%s\"", word, policy); return 1; } while (0)
    bool is_select = !fsql_strcasecmp(word, "select"), is_with = !fsql_strcasecmp(word, "with");
    bool is_insert = !fsql_strcasecmp(word, "insert"), is_update = !fsql_strcasecmp(word, "update");
    bool kw_ok = is_select || is_with || (allow_write && (is_insert || is_update));
    if (!kw_ok) REFUSED();
    const char *denied = fsql_denied_function_call(sql);
    if (denied) {
        snprintf(why, why_cap, "statement calls %s...(), a function that changes state, which generated SQL may not do", denied);
        return 1;
    }
    int nst, type;
    char perr[1024];
    if (fsql_classify_sql(inst, sql, &nst, &type, perr, sizeof perr)) {
        snprintf(why, why_cap, "SQL does not parse or analyze: %s", perr);
        return 1;
    }
    if (nst != 1) {
        snprintf(why, why_cap, "expected exactly one SQL statement, found %d -- fractal_text_to_sql only returns a single statement", nst);
        return 1;
    }
    if (type == FSQL_STMT_UNKNOWN) {
        /* could not be prepared (it names something that does not exist yet): the first keyword decides
         * the cases it can, and the EXPLAIN step that follows reports the rest */
        type = is_select ? FSQL_STMT_SELECT : is_insert ? FSQL_STMT_INSERT : is_update ? FSQL_STMT_UPDATE : FSQL_STMT_UNKNOWN;
    }
    if (type != FSQL_STMT_UNKNOWN) {
        bool ok = type == FSQL_STMT_SELECT || (allow_write && (type == FSQL_STMT_INSERT || type == FSQL_STMT_UPDATE));
        if (!ok) REFUSED();
    }
    if (is_with && type == FSQL_STMT_SELECT) {
        fsql_sb ex; fsql_sb_init(&ex);
        fsql_sb_puts(&ex, "EXPLAIN (FORMAT json) "); fsql_sb_puts(&ex, sql);
        fsql_qres r; char e2[512];
        bool modifying = false, unverified = false;
        if (!fsql_nested_query(inst, fsql_sb_cstr(&ex), &r, e2, sizeof e2)) {
            for (duckdb_data_chunk ch = fsql_qres_next_chunk(&r); ch && !modifying; ch = fsql_qres_next_chunk(&r)) {
                idx_t rows = duckdb_data_chunk_get_size(ch);
                duckdb_vector v = duckdb_data_chunk_get_column_count(ch) > 1 ? duckdb_data_chunk_get_vector(ch, 1) : NULL;
                for (idx_t i = 0; v && i < rows && !modifying; i++) {
                    size_t l; const char *p = fsql_str_data(&((const duckdb_string_t *)duckdb_vector_get_data(v))[i], &l);
                    char *copy = fsql_xstrndup(p, l);
                    if (!copy) { unverified = modifying = true; break; }      /* cannot read the plan: refuse (fail closed) */
                    modifying = fsql_plan_has_modifying_operator(copy);
                    free(copy);
                }
                duckdb_destroy_data_chunk(&ch);
                if (modifying) break;
            }
            fsql_qres_free(&r);
        }
        fsql_sb_free(&ex);
        if (unverified) { snprintf(why, why_cap, "statement could not be verified (out of memory)"); return 1; }
        if (modifying) { snprintf(why, why_cap, "statement contains a data-modifying CTE, which is not permitted"); return 1; }
    }
    (void)err;
    return 0;
#undef REFUSED
}

typedef enum { T2S_OK, T2S_EMPTY, T2S_REJECTED, T2S_REVIEW_FAILED } t2s_kind;

typedef struct {
    char *final_sql;
    char *last_candidate;
    char *feedback;
    char *failure;           /* the terminal message when not a success */
    bool success;
    t2s_kind kind;
    int attempt;
} t2s_result;

static void t2s_result_free(t2s_result *r) { free(r->final_sql); free(r->last_candidate); free(r->feedback); free(r->failure); }
static void set_str(char **dst, const char *s, size_t n) { free(*dst); *dst = fsql_xstrndup(s, n); }
static void set_feedback(t2s_result *r, const char *s) { set_str(&r->feedback, s, strlen(s) > MAX_FEEDBACK_BYTES ? MAX_FEEDBACK_BYTES : strlen(s)); }

static bool env_on(const char *name) {
    const char *v = getenv(name);
    if (!v || !*v) return false;
    return !fsql_strcasecmp(v, "on") || !strcmp(v, "1") || !fsql_strcasecmp(v, "true") || !fsql_strcasecmp(v, "yes");
}

/* Runs the pipeline. 0 with *res filled (success or not); -1 with err for a hard failure (bad arguments,
 * input cap, a dispatch failure). */
static int generate_and_validate(fsql_instance *inst, const char *question, char **tables, size_t ntables, int max_retries,
                                 t2s_result *res, char *err, size_t errcap) {
    memset(res, 0, sizeof *res);
    if (max_retries <= 0 || max_retries > 20) { snprintf(err, errcap, "fractalsql: max_retries out of range [1, 20]"); return -1; }
    size_t qlen = strlen(question);
    if (qlen > FSQL_MAX_INPUT_BYTES) { snprintf(err, errcap, "fractalsql: fractal_text_to_sql: question exceeds the 4 MiB input cap"); return -1; }

    fsql_sb schema; fsql_sb_init(&schema);
    fsql_sb_puts(&schema, "{\"tables\":[");
    for (size_t t = 0; t < ntables; t++) {
        if (t) fsql_sb_putc(&schema, ',');
        fsql_sb_puts(&schema, "{\"name\":");
        t2s_jstr(&schema, tables[t]);
        fsql_sb_puts(&schema, ",\"columns\":[");
        fsql_sb q; fsql_sb_init(&q);
        fsql_sb_puts(&q, "SELECT name, type FROM pragma_table_info("); put_quoted(&q, tables[t], strlen(tables[t])); fsql_sb_putc(&q, ')');
        fsql_qres r; char e2[512];
        if (!fsql_nested_query(inst, fsql_sb_cstr(&q), &r, e2, sizeof e2)) {
            bool first = true;
            for (duckdb_data_chunk ch = fsql_qres_next_chunk(&r); ch; ch = fsql_qres_next_chunk(&r)) {
                idx_t rows = duckdb_data_chunk_get_size(ch);
                for (idx_t i = 0; i < rows; i++) {
                    if (!first) fsql_sb_putc(&schema, ',');
                    first = false;
                    char *nm = chunk_str(ch, 0, i), *ty = chunk_str(ch, 1, i);
                    fsql_sb_puts(&schema, "{\"name\":"); t2s_jstr(&schema, nm);
                    fsql_sb_puts(&schema, ",\"type\":"); t2s_jstr(&schema, ty);
                    fsql_sb_putc(&schema, '}');
                    free(nm); free(ty);
                }
                duckdb_destroy_data_chunk(&ch);
            }
            fsql_qres_free(&r);
        }   /* a missing/unreadable table leaves its columns empty */
        fsql_sb_free(&q);
        fsql_sb_puts(&schema, "]}");
    }
    fsql_sb_puts(&schema, "]}");
    if (!fsql_sb_ok(&schema)) { fsql_sb_free(&schema); snprintf(err, errcap, "fractalsql: out of memory"); return -1; }

    bool allow_write = false;
    { const char *m = getenv("FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS"); allow_write = m && !strcmp(m, "select_insert_update"); }
    bool use_review = env_on("FRACTALSQL_TEXT_TO_SQL_USE_REVIEW");
    int rc = -1;

    while (res->attempt < max_retries) {
        res->attempt++;
        fsql_sb ctx; fsql_sb_init(&ctx);
        fsql_sb_puts(&ctx, fsql_sb_cstr(&schema));
        if (res->feedback && *res->feedback) {
            /* splice ,"previous_error":"..." in before the closing brace */
            fsql_sb tmp; fsql_sb_init(&tmp);
            fsql_sb_puts(&tmp, ",\"previous_error\":"); t2s_jstr(&tmp, res->feedback);
            fsql_sb_clear(&ctx);
            size_t sl = strlen(fsql_sb_cstr(&schema));
            fsql_sb_putn(&ctx, fsql_sb_cstr(&schema), sl - 1);
            fsql_sb_puts(&ctx, fsql_sb_cstr(&tmp));
            fsql_sb_putc(&ctx, '}');
            fsql_sb_free(&tmp);
        }
        size_t clen = strlen(fsql_sb_cstr(&ctx));
        if (qlen + clen > FSQL_MAX_INPUT_BYTES) {
            fsql_sb_free(&ctx);
            snprintf(err, errcap, "fractalsql: fractal_text_to_sql: prompt exceeds the 4 MiB input cap");
            goto out;
        }
        char *raw = NULL;
        if (fsql_reasoning_generate(FSQL_REASONING_TIER_T2S, question, qlen, fsql_sb_cstr(&ctx), clen, &raw, err, errcap) != FSQL_REASONING_OK) {
            fsql_sb_free(&ctx);
            goto out;
        }
        fsql_sb_free(&ctx);
        free(res->final_sql);
        res->final_sql = fsql_extract_sql_candidate(raw);
        free(raw);
        if (!res->final_sql) { snprintf(err, errcap, "fractalsql: out of memory"); goto out; }
        if (!*res->final_sql) {
            set_feedback(res, "the model response contained no SQL (no ```sql fenced block and no bare statement)");
            res->kind = T2S_EMPTY;
            free(res->last_candidate); res->last_candidate = fsql_xstrdup("");
            continue;
        }
        set_str(&res->last_candidate, res->final_sql, strlen(res->final_sql));
        char why[2048];
        int chk = check_statement_allowed(inst, res->final_sql, allow_write, why, sizeof why, err);
        if (chk < 0) goto out;
        if (chk > 0) { set_feedback(res, why); res->kind = T2S_REJECTED; continue; }

        fsql_sb ex; fsql_sb_init(&ex);
        fsql_sb_puts(&ex, "EXPLAIN "); fsql_sb_puts(&ex, res->final_sql);
        fsql_qres er; char e3[ERRBUF];
        if (fsql_nested_query(inst, fsql_sb_cstr(&ex), &er, e3, sizeof e3)) {
            fsql_sb_free(&ex);
            char fb[ERRBUF + 64];
            snprintf(fb, sizeof fb, "SQL does not parse or analyze: %s", e3);
            set_feedback(res, fb);
            res->kind = T2S_REJECTED;
            continue;
        }
        fsql_qres_free(&er);
        fsql_sb_free(&ex);

        if (use_review) {
            fsql_sb rp; fsql_sb_init(&rp);
            fsql_sb_puts(&rp, "Original request: "); fsql_sb_puts(&rp, question);
            fsql_sb_puts(&rp, "\n\nCandidate SQL:\n"); fsql_sb_puts(&rp, res->final_sql);
            fsql_sb_puts(&rp, "\n\nDoes this candidate correctly and completely answer the request? Answer PASS or FAIL on the first line, then explain briefly.");
            char *critique = NULL;
            int g = fsql_reasoning_generate(FSQL_REASONING_TIER_REVIEW, fsql_sb_cstr(&rp), strlen(fsql_sb_cstr(&rp)), "{}", 2, &critique, err, errcap);
            fsql_sb_free(&rp);
            if (g != FSQL_REASONING_OK) goto out;
            size_t i = 0, cl = strlen(critique);
            while (i < cl && isspace((unsigned char)critique[i])) i++;
            bool pass = fsql_ieq_at(critique, cl, i, "PASS");
            if (!pass) { set_feedback(res, critique); res->kind = T2S_REVIEW_FAILED; free(critique); continue; }
            free(critique);
        }
        res->success = true;
        res->kind = T2S_OK;
        break;
    }
    if (!res->success) {
        fsql_sb m; fsql_sb_init(&m);
        fsql_sb_printf(&m, "fractal_text_to_sql: exhausted %d attempt(s), ", res->attempt);
        if (res->kind == T2S_REVIEW_FAILED) fsql_sb_printf(&m, "last review verdict: %s", res->feedback ? res->feedback : "");
        else {
            fsql_sb_printf(&m, "last rejection: %s", res->feedback ? res->feedback : "");
            if (res->kind == T2S_REJECTED && res->last_candidate && *res->last_candidate) {
                size_t lc = strlen(res->last_candidate);
                fsql_sb_puts(&m, " -- Last candidate SQL: ");
                fsql_sb_putn(&m, res->last_candidate, lc > 200 ? 200 : lc);
            }
        }
        res->failure = fsql_sb_take(&m);
    }
    rc = 0;
out:
    fsql_sb_free(&schema);
    return rc;
}

static void text_to_sql_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    fsql_instance *inst = fsql_scalar_instance(info);
    idx_t n = duckdb_data_chunk_get_size(in), ncols = duckdb_data_chunk_get_column_count(in);
    const duckdb_string_t *qd = (const duckdb_string_t *)fsql_col_data(in, 0);
    for (idx_t i = 0; i < n; i++) {
        size_t ql; const char *q = fsql_str_data(&qd[i], &ql);
        char *question = fsql_xstrndup(q, ql);
        char **names = NULL; size_t nn = 0;
        if (!question) { fsql_fn_error(info, "fractalsql: out of memory"); return; }
        if (ncols > 1 && !chunk_str_list(in, 1, i, &names, &nn)) { free(question); fsql_fn_error(info, "fractalsql: out of memory"); return; }
        t2s_result r; char err[4096];
        int rc = generate_and_validate(inst, question, names, nn, 3, &r, err, sizeof err);
        free(question); free_str_list(names, nn);
        if (rc) { duckdb_scalar_function_set_error(info, err); return; }
        if (!r.success) {
            char m[8192];
            snprintf(m, sizeof m, "fractalsql: %s", r.failure);
            duckdb_scalar_function_set_error(info, m);
            t2s_result_free(&r);
            return;
        }
        fsql_set_str(out, i, r.final_sql, strlen(r.final_sql));
        t2s_result_free(&r);
    }
}

static const char *const kSqlAgentCols[] = { "generated_sql", "execution_status", "retry_count", "result_json" };
static const fsql_rs_ty  kSqlAgentTys[]  = { FSQL_RS_VARCHAR, FSQL_RS_VARCHAR, FSQL_RS_INTEGER, FSQL_RS_VARCHAR };

static void sql_agent_bind(duckdb_bind_info info) {
    fsql_instance *inst = fsql_bind_instance(info);
    char err[4096];
    fsql_rowset *rs = NULL; t2s_result r; memset(&r, 0, sizeof r);
    char *question = NULL, **names = NULL; size_t nn = 0;
    bool oom = false;
    fsql_sb js; fsql_sb_init(&js);
    {
        duckdb_value v = duckdb_bind_get_parameter(info, 0);
        char *s = duckdb_is_null_value(v) ? NULL : duckdb_get_varchar(v);
        question = fsql_xstrdup(s ? s : "NULL");
        if (s) duckdb_free(s);
        duckdb_destroy_value(&v);
        v = duckdb_bind_get_parameter(info, 1);
        if (!duckdb_is_null_value(v)) {
            idx_t cnt = duckdb_get_list_size(v);
            names = (char **)calloc(cnt ? cnt : 1, sizeof(char *));
            if (!names) { duckdb_destroy_value(&v); snprintf(err, sizeof err, "fractalsql: out of memory"); goto fail; }
            for (idx_t i = 0; i < cnt; i++) {
                duckdb_value c = duckdb_get_list_child(v, i);
                char *cs = duckdb_is_null_value(c) ? NULL : duckdb_get_varchar(c);
                names[nn] = fsql_xstrdup(cs ? cs : "NULL");
                if (!names[nn]) oom = true;
                nn++;
                if (cs) duckdb_free(cs);
                duckdb_destroy_value(&c);
            }
        }
        duckdb_destroy_value(&v);
    }
    duckdb_value mv = duckdb_bind_get_parameter(info, 2), av = duckdb_bind_get_parameter(info, 3);
    bool null_arg = duckdb_is_null_value(mv) || duckdb_is_null_value(av);
    int32_t max_retries = null_arg ? 0 : (int32_t)duckdb_get_int64(mv);
    bool auto_execute = null_arg ? false : duckdb_get_bool(av);
    duckdb_destroy_value(&mv); duckdb_destroy_value(&av);
    if (!question || oom) { snprintf(err, sizeof err, "fractalsql: out of memory"); goto fail; }
    if (null_arg) { snprintf(err, sizeof err, "fractalsql: max_retries/auto_execute must not be NULL"); goto fail; }

    if (generate_and_validate(inst, question, names, nn, max_retries, &r, err, sizeof err)) goto fail;
    {
        const char *status = r.success ? "success" : "validation_failed";
        char *result_json = NULL;
        char numbuf[64];
        if (!r.success && r.failure && *r.failure) {
            fsql_sb_puts(&js, "{\"status\":\"validation_failed\",\"error\":"); t2s_jstr(&js, r.failure); fsql_sb_putc(&js, '}');
            result_json = fsql_sb_take(&js);
        } else if (auto_execute && r.success) {
            fsql_qres er; char e3[4096];
            if (!fsql_nested_query(inst, r.final_sql, &er, e3, sizeof e3)) {
                long long rows = 0;
                for (duckdb_data_chunk ch = fsql_qres_next_chunk(&er); ch; ch = fsql_qres_next_chunk(&er)) {
                    rows += (long long)duckdb_data_chunk_get_size(ch);
                    duckdb_destroy_data_chunk(&ch);
                }
                fsql_qres_free(&er);
                status = "executed";
                snprintf(numbuf, sizeof numbuf, "%lld", rows);
                fsql_sb_puts(&js, "{\"status\":\"executed\",\"rows\":"); fsql_sb_puts(&js, numbuf); fsql_sb_putc(&js, '}');
            } else {
                status = "execution_failed";
                fsql_sb_puts(&js, "{\"status\":\"execution_failed\",\"error\":"); t2s_jstr(&js, e3); fsql_sb_putc(&js, '}');
            }
            result_json = fsql_sb_take(&js);
        } else result_json = fsql_xstrdup("null");
        rs = fsql_rowset_new(4, kSqlAgentCols, kSqlAgentTys);
        bool ok = result_json && rs && fsql_rs_row(rs) && fsql_rs_str(rs, 0, r.final_sql ? r.final_sql : "", r.final_sql ? strlen(r.final_sql) : 0) &&
                  fsql_rs_str(rs, 1, status, strlen(status)) && fsql_rs_i64(rs, 2, r.attempt) &&
                  fsql_rs_str(rs, 3, result_json, strlen(result_json));
        free(result_json);
        if (!ok) { snprintf(err, sizeof err, "fractalsql: out of memory"); goto fail; }
    }
    fsql_rowset_bind(info, rs);
    rs = NULL;
    goto cleanup;
fail:
    duckdb_bind_set_error(info, err);
cleanup:
    fsql_rowset_free(rs);
    t2s_result_free(&r);
    free(question); free_str_list(names, nn); fsql_sb_free(&js);
}

/* SPECIAL null handling: a NULL table_names means "every table in the search path" and query_hint is unused,
 * so a NULL in either position must still run the introspection (under the default handling DuckDB would
 * fold the call into a NULL constant instead). */
static const fsql_scalar_def kT2sDefs[] = {
    { "fractal_schema_context", 0, { 0 },                                    FSQL_T_VARCHAR, schema_context_fn, NULL, FSQL_FN_SPECIAL_NULL },
    { "fractal_schema_context", 1, { FSQL_T_LIST_VARCHAR },                  FSQL_T_VARCHAR, schema_context_fn, NULL, FSQL_FN_SPECIAL_NULL },
    { "fractal_schema_context", 2, { FSQL_T_LIST_VARCHAR, FSQL_T_VARCHAR },  FSQL_T_VARCHAR, schema_context_fn, NULL, FSQL_FN_SPECIAL_NULL },
};

static const fsql_scalar_def kT2sTextDefs[] = {
    { "fractal_text_to_sql", 1, { FSQL_T_VARCHAR },                            FSQL_T_VARCHAR, text_to_sql_fn, NULL, 0 },
    { "fractal_text_to_sql", 2, { FSQL_T_VARCHAR, FSQL_T_LIST_VARCHAR },       FSQL_T_VARCHAR, text_to_sql_fn, NULL, 0 },
};
static const fsql_table_def kT2sTables[] = {
    { "fractal_sql_agent", 4, { FSQL_T_VARCHAR, FSQL_T_LIST_VARCHAR, FSQL_T_INTEGER, FSQL_T_BOOLEAN }, sql_agent_bind, fsql_rowset_init, fsql_rowset_scan },
};

bool fsql_t2s_register(duckdb_connection con, const char **err) {
    return fsql_register_scalars(con, kT2sDefs, (int)(sizeof kT2sDefs / sizeof kT2sDefs[0]), err) &&
           fsql_register_scalars(con, kT2sTextDefs, (int)(sizeof kT2sTextDefs / sizeof kT2sTextDefs[0]), err) &&
           fsql_register_tables(con, kT2sTables, (int)(sizeof kT2sTables / sizeof kT2sTables[0]), err);
}
