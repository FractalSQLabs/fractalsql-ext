/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * src/fsql_feature_store.c -- the named feature store: a per-doc_id vector store for custom metadata or flagged examples.
 *
 *   fractal_store_morphology(doc_id BIGINT, features VARCHAR)        -> VARCHAR 'ok'   (an upsert, last writer wins)
 *   fractal_mine_topology_negatives(surrogate VARCHAR, k INTEGER)    -> VARCHAR (JSON [{"doc_id":..,"distance":..}], nearest first)
 *
 * `features` and `surrogate` are a JSON array ('[1,2,3]') or a comma-separated list ('1,2,3'); a DOUBLE[] is accepted as is. The store is a plain table, fractalsql_feature_store, created on first use in the database the extension runs in. The
 * distance is the true Euclidean distance; a stored vector of another dimension is skipped.
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_duckdb_internal.h"

#define ERRCAP 512
#define FS_MAX_K 100000
#define FS_MAX_TEXT (4u * 1024u * 1024u)

static void fail(duckdb_function_info info, const char *msg) { duckdb_scalar_function_set_error(info, msg); }

static void put_lit(fsql_sb *b, const char *s, size_t n) {
    fsql_sb_putc(b, '\'');
    for (size_t i = 0; i < n; i++) { if (s[i] == '\'') fsql_sb_putc(b, '\''); fsql_sb_putc(b, s[i]); }
    fsql_sb_putc(b, '\'');
}

/* The SQL expression for a vector given as text: a JSON array casts to DOUBLE[]; a comma list is split and cast. */
static void put_vector_expr(fsql_sb *b, const char *s, size_t n) {
    size_t i = 0;
    while (i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
    if (i < n && s[i] == '[') {
        fsql_sb_puts(b, "CAST(");
        put_lit(b, s, n);
        fsql_sb_puts(b, " AS DOUBLE[])");
    } else {
        fsql_sb_puts(b, "list_transform(string_split(");
        put_lit(b, s, n);
        fsql_sb_puts(b, ", ','), lambda x: CAST(trim(x) AS DOUBLE))");
    }
}

static int ensure_table(fsql_instance *inst, char *err) {
    fsql_qres r;
    if (fsql_nested_query(inst,
            "CREATE TABLE IF NOT EXISTS fractalsql_feature_store ("
            "  doc_id BIGINT PRIMARY KEY,"
            "  features DOUBLE[] NOT NULL,"
            "  updated_at TIMESTAMP DEFAULT now())", &r, err, ERRCAP)) return -1;
    fsql_qres_free(&r);
    return 0;
}

/* One row: upsert `text` (a JSON array or a comma list) against doc_id. Returns 0, or -1 with err set. */
static int store_one(fsql_instance *inst, int64_t id, const char *p, size_t l, char *err) {
    if (id < 0) { snprintf(err, ERRCAP, "fractalsql: doc_id must be >= 0"); return -1; }
    if (l == 0 || l > FS_MAX_TEXT) { snprintf(err, ERRCAP, "fractalsql: invalid feature_array (expect a JSON array or a comma-separated list of numbers)"); return -1; }
    fsql_sb sql; fsql_sb_init(&sql);
    fsql_sb_printf(&sql, "INSERT OR REPLACE INTO fractalsql_feature_store(doc_id, features, updated_at) VALUES (%" PRId64 ", ", id);
    put_vector_expr(&sql, p, l);
    fsql_sb_puts(&sql, ", now())");
    fsql_qres r;
    int rc = fsql_sb_ok(&sql) ? fsql_nested_query(inst, fsql_sb_cstr(&sql), &r, err, ERRCAP) : -1;
    fsql_sb_free(&sql);
    if (rc) { if (!err[0]) snprintf(err, ERRCAP, "fractalsql: out of memory"); return -1; }
    fsql_qres_free(&r);
    return 0;
}

/* One row: the k stored vectors nearest `text`, as a malloc'd JSON array; NULL with err set on failure. */
static char *mine_one(fsql_instance *inst, const char *p, size_t l, int k_in, char *err) {
    if (k_in <= 0) { snprintf(err, ERRCAP, "fractalsql: k must be > 0"); return NULL; }
    long long k = k_in > FS_MAX_K ? FS_MAX_K : k_in;
    if (l == 0 || l > FS_MAX_TEXT) { snprintf(err, ERRCAP, "fractalsql: invalid surrogate_vector (expect a JSON array or a comma-separated list of numbers)"); return NULL; }
    fsql_sb sql; fsql_sb_init(&sql);
    fsql_sb_puts(&sql, "WITH q AS (SELECT ");
    put_vector_expr(&sql, p, l);
    fsql_sb_puts(&sql, " AS v) SELECT coalesce('[' || string_agg(CAST(json_object('doc_id', doc_id, 'distance', d) AS VARCHAR), ',' ORDER BY d, doc_id) || ']', '[]') FROM ("
                       "SELECT s.doc_id, sqrt(list_sum(list_transform(list_zip(s.features, q.v), lambda x: (x[1] - x[2]) * (x[1] - x[2])))) AS d "
                       "FROM fractalsql_feature_store s, q WHERE len(s.features) = len(q.v) ORDER BY d, s.doc_id ");
    fsql_sb_printf(&sql, "LIMIT %lld)", k);
    fsql_qres r;
    int rc = fsql_sb_ok(&sql) ? fsql_nested_query(inst, fsql_sb_cstr(&sql), &r, err, ERRCAP) : -1;
    fsql_sb_free(&sql);
    if (rc) { if (!err[0]) snprintf(err, ERRCAP, "fractalsql: out of memory"); return NULL; }
    duckdb_data_chunk ch = fsql_qres_next_chunk(&r);
    char *json = NULL;
    if (ch) {
        if (duckdb_data_chunk_get_size(ch) > 0) {
            duckdb_vector v = duckdb_data_chunk_get_vector(ch, 0);
            size_t jl; const char *jp = fsql_str_data(&((const duckdb_string_t *)duckdb_vector_get_data(v))[0], &jl);
            json = fsql_xstrndup(jp, jl);
        }
        duckdb_destroy_data_chunk(&ch);
    }
    fsql_qres_free(&r);
    if (!json) snprintf(err, ERRCAP, "fractalsql: out of memory");
    return json;
}

/* A DOUBLE[] row as the JSON array text the SQL expression reads; malloc'd, NULL on failure. */
static char *list_text(const double *v, size_t n, size_t *len) {
    fsql_sb sb; fsql_sb_init(&sb);
    fsql_sb_putc(&sb, '[');
    for (size_t i = 0; i < n; i++) fsql_sb_printf(&sb, "%s%.17g", i ? "," : "", v[i]);
    fsql_sb_putc(&sb, ']');
    if (!fsql_sb_ok(&sb)) { fsql_sb_free(&sb); return NULL; }
    char *s = fsql_sb_take(&sb);
    if (s) *len = strlen(s);
    return s;
}

/* store: column 1 is VARCHAR text, or a DOUBLE[] when `list` */
static void store_common(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out, bool list) {
    fsql_instance *inst = fsql_scalar_instance(info);
    idx_t n = duckdb_data_chunk_get_size(in);
    const int64_t *ids = (const int64_t *)fsql_col_data(in, 0);
    const uint64_t *idv = fsql_col_validity(in, 0), *fvv = fsql_col_validity(in, 1);
    const duckdb_string_t *fv = list ? NULL : (const duckdb_string_t *)fsql_col_data(in, 1);
    fsql_list fl; if (list) fsql_list_open(&fl, duckdb_data_chunk_get_vector(in, 1));
    char err[ERRCAP] = "";
    if (ensure_table(inst, err)) { fail(info, err); return; }
    for (idx_t i = 0; i < n; i++) {
        if (!fsql_valid(idv, i) || !fsql_valid(fvv, i)) { fsql_set_null(out, i); continue; }
        int rc;
        if (list) {
            const double *v; size_t vn; const char *lerr = NULL;
            { int lr = fsql_list_f64_get(&fl, i, &v, &vn, &lerr); if (lr != 1) { fail(info, lr < 0 && lerr ? lerr : "fractalsql: invalid feature_array (a NULL element)"); return; } }
            size_t tl; char *txt = list_text(v, vn, &tl);
            if (!txt) { fail(info, "fractalsql: out of memory"); return; }
            rc = store_one(inst, ids[i], txt, tl, err);
            free(txt);
        } else {
            size_t l; const char *p = fsql_str_data(&fv[i], &l);
            rc = store_one(inst, ids[i], p, l, err);
        }
        if (rc) { fail(info, err); return; }
        fsql_set_str(out, i, "ok", 2);
    }
}
static void store_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) { store_common(info, in, out, false); }
static void store_list_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) { store_common(info, in, out, true); }

static void mine_common(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out, bool list) {
    fsql_instance *inst = fsql_scalar_instance(info);
    idx_t n = duckdb_data_chunk_get_size(in);
    const int32_t *ks = (const int32_t *)fsql_col_data(in, 1);
    const uint64_t *svv = fsql_col_validity(in, 0), *kvv = fsql_col_validity(in, 1);
    const duckdb_string_t *sv = list ? NULL : (const duckdb_string_t *)fsql_col_data(in, 0);
    fsql_list fl; if (list) fsql_list_open(&fl, duckdb_data_chunk_get_vector(in, 0));
    char err[ERRCAP] = "";
    if (ensure_table(inst, err)) { fail(info, err); return; }
    for (idx_t i = 0; i < n; i++) {
        if (!fsql_valid(svv, i) || !fsql_valid(kvv, i)) { fsql_set_null(out, i); continue; }
        char *json;
        if (list) {
            const double *v; size_t vn; const char *lerr = NULL;
            { int lr = fsql_list_f64_get(&fl, i, &v, &vn, &lerr); if (lr != 1) { fail(info, lr < 0 && lerr ? lerr : "fractalsql: invalid surrogate_vector (a NULL element)"); return; } }
            size_t tl; char *txt = list_text(v, vn, &tl);
            if (!txt) { fail(info, "fractalsql: out of memory"); return; }
            json = mine_one(inst, txt, tl, ks[i], err);
            free(txt);
        } else {
            size_t l; const char *p = fsql_str_data(&sv[i], &l);
            json = mine_one(inst, p, l, ks[i], err);
        }
        if (!json) { fail(info, err); return; }
        fsql_set_str(out, i, json, strlen(json));
        free(json);
    }
}
static void mine_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) { mine_common(info, in, out, false); }
static void mine_list_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) { mine_common(info, in, out, true); }

#define V FSQL_T_VARCHAR
static const fsql_scalar_def kFeatureDefs[] = {
    { "fractal_store_morphology",         2, { FSQL_T_BIGINT, V },                 V, store_fn,      NULL, FSQL_FN_VOLATILE },
    { "fractal_store_morphology",         2, { FSQL_T_BIGINT, FSQL_T_LIST_DOUBLE }, V, store_list_fn, NULL, FSQL_FN_VOLATILE },
    { "fractal_mine_topology_negatives",  2, { V, FSQL_T_INTEGER },                V, mine_fn,       NULL, FSQL_FN_VOLATILE },
    { "fractal_mine_topology_negatives",  2, { FSQL_T_LIST_DOUBLE, FSQL_T_INTEGER }, V, mine_list_fn,  NULL, FSQL_FN_VOLATILE },
};

bool fsql_feature_store_register(duckdb_connection con, const char **err) {
    return fsql_register_scalars(con, kFeatureDefs, (int)(sizeof kFeatureDefs / sizeof kFeatureDefs[0]), err);
}
