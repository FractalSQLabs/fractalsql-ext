/* capi/spike/fsql_spike.c
 *
 * Throw-away proof of concept for the pure-C DuckDB extension port
 * (see duckdb-purec-ext-port.txt). It answers four questions before any of
 * the real extension is ported, using only what the C extension API offers
 * and no other DuckDB symbol:
 *
 *   Q1  can an extension keep a connection of its own and run SQL on it from
 *       inside a scalar function?                          fractal_spike_nested
 *   Q2  can a function learn which connection called it?   fractal_spike_conn
 *   Q3  can the statement allowlist be built on the C API (statement count and
 *       type) instead of duckdb::Parser?                   fractal_spike_stmt
 *   Q4  does one source compile against both header generations (1.4.4 and
 *       1.5.6) and load on 1.4.4, 1.5.6 and 2.0.0?
 *
 * Nothing here is shipped.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* A mutex that builds with both gcc/clang and MSVC (the real extension gets
 * this from include/fsql_port.h in phase 1). */
#ifdef _WIN32
#  include <windows.h>
typedef SRWLOCK fsql_mu_t;
#  define FSQL_MU_INIT SRWLOCK_INIT
#  define fsql_mu_lock(m) AcquireSRWLockExclusive(m)
#  define fsql_mu_unlock(m) ReleaseSRWLockExclusive(m)
#else
#  include <pthread.h>
typedef pthread_mutex_t fsql_mu_t;
#  define FSQL_MU_INIT PTHREAD_MUTEX_INITIALIZER
#  define fsql_mu_lock(m) pthread_mutex_lock(m)
#  define fsql_mu_unlock(m) pthread_mutex_unlock(m)
#endif

#define DUCKDB_EXTENSION_NAME fractalsql
#include "duckdb_extension.h"

DUCKDB_EXTENSION_EXTERN

static duckdb_connection g_side;                       /* the extension's own connection   */
static fsql_mu_t         g_side_mu = FSQL_MU_INIT;

/* ------------------------------------------------------------------ helpers */

static duckdb_string_t *str_data(duckdb_vector v) { return (duckdb_string_t *)duckdb_vector_get_data(v); }

/* A malloc'd, NUL-terminated copy of a duckdb_string_t. */
static char *dup_str(duckdb_string_t *s) {
    uint32_t n = duckdb_string_t_length(*s);
    const char *p = duckdb_string_t_data(s);
    char *out = (char *)malloc((size_t)n + 1);
    if (!out) return NULL;
    memcpy(out, p, n);
    out[n] = 0;
    return out;
}

static const char *stmt_type_name(duckdb_statement_type t) {
    switch (t) {
    case DUCKDB_STATEMENT_TYPE_SELECT: return "SELECT";
    case DUCKDB_STATEMENT_TYPE_INSERT: return "INSERT";
    case DUCKDB_STATEMENT_TYPE_UPDATE: return "UPDATE";
    case DUCKDB_STATEMENT_TYPE_EXPLAIN: return "EXPLAIN";
    case DUCKDB_STATEMENT_TYPE_DELETE: return "DELETE";
    case DUCKDB_STATEMENT_TYPE_CREATE: return "CREATE";
    case DUCKDB_STATEMENT_TYPE_DROP: return "DROP";
    case DUCKDB_STATEMENT_TYPE_COPY: return "COPY";
    case DUCKDB_STATEMENT_TYPE_PRAGMA: return "PRAGMA";
    case DUCKDB_STATEMENT_TYPE_CALL: return "CALL";
    case DUCKDB_STATEMENT_TYPE_SET: return "SET";
    default: return "OTHER";
    }
}

/* ------------------------------------------------- fractal_spike_version() */

static void version_exec(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    (void)info;
    idx_t n = duckdb_data_chunk_get_size(in);
    for (idx_t i = 0; i < n; i++) duckdb_vector_assign_string_element(out, i, duckdb_library_version());
}

/* ----------------------------------------------------- fractal_spike_conn()
 * The client context is reachable only in the BIND callback. The connection id
 * read there travels to execution through the bind data. */

static void conn_bind(duckdb_bind_info info) {
    duckdb_client_context ctx = NULL;
    duckdb_scalar_function_get_client_context(info, &ctx);
    idx_t *id = (idx_t *)malloc(sizeof *id);
    *id = ctx ? duckdb_client_context_get_connection_id(ctx) : 0;
    if (ctx) duckdb_destroy_client_context(&ctx);
    duckdb_scalar_function_set_bind_data(info, id, free);
}

static void conn_exec(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t id = *(idx_t *)duckdb_scalar_function_get_bind_data(info);
    idx_t n = duckdb_data_chunk_get_size(in);
    uint64_t *o = (uint64_t *)duckdb_vector_get_data(out);
    for (idx_t i = 0; i < n; i++) o[i] = (uint64_t)id;
}

/* ---------------------------------------------- fractal_spike_nested(sql)
 * Runs `sql` on the extension's own connection and returns the first cell as
 * text. This is the shape of RunQuery() in the C++ agents. */

static void nested_exec(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    duckdb_vector arg = duckdb_data_chunk_get_vector(in, 0);
    duckdb_string_t *sa = str_data(arg);
    for (idx_t i = 0; i < n; i++) {
        char *sql = dup_str(&sa[i]);
        char msg[512];
        duckdb_result res;
        fsql_mu_lock(&g_side_mu);
        duckdb_state st = duckdb_query(g_side, sql, &res);
        if (st == DuckDBError) {
            snprintf(msg, sizeof msg, "ERR: %s", duckdb_result_error(&res));
        } else {
            char *v = duckdb_value_varchar(&res, 0, 0);
            snprintf(msg, sizeof msg, "%s", v ? v : "(null)");
            if (v) duckdb_free(v);
        }
        duckdb_destroy_result(&res);
        fsql_mu_unlock(&g_side_mu);
        free(sql);
        duckdb_vector_assign_string_element(out, i, msg);
    }
    (void)info;
}

/* ----------------------------------------------- fractal_spike_stmt(sql)
 * "<count>:<TYPE>[,<TYPE>...]" using only extract_statements + prepare +
 * prepared_statement_type -- the C API replacement for duckdb::Parser. */

static void stmt_exec(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    duckdb_string_t *sa = str_data(duckdb_data_chunk_get_vector(in, 0));
    for (idx_t i = 0; i < n; i++) {
        char *sql = dup_str(&sa[i]);
        char msg[1024];
        size_t off = 0;
        duckdb_extracted_statements ex = NULL;
        fsql_mu_lock(&g_side_mu);
        idx_t cnt = duckdb_extract_statements(g_side, sql, &ex);
        if (cnt == 0) {
            const char *e = duckdb_extract_statements_error(ex);
            snprintf(msg, sizeof msg, "PARSE-ERR: %s", e ? e : "?");
        } else {
            off += (size_t)snprintf(msg + off, sizeof msg - off, "%llu:", (unsigned long long)cnt);
            for (idx_t k = 0; k < cnt && off < sizeof msg - 64; k++) {
                duckdb_prepared_statement prep = NULL;
                if (duckdb_prepare_extracted_statement(g_side, ex, k, &prep) == DuckDBError) {
                    const char *e = duckdb_prepare_error(prep);
                    off += (size_t)snprintf(msg + off, sizeof msg - off, "%sBIND-ERR(%s)", k ? "," : "", e ? e : "?");
                } else {
                    off += (size_t)snprintf(msg + off, sizeof msg - off, "%s%s", k ? "," : "",
                                            stmt_type_name(duckdb_prepared_statement_type(prep)));
                }
                duckdb_destroy_prepare(&prep);
            }
        }
        duckdb_destroy_extracted(&ex);
        fsql_mu_unlock(&g_side_mu);
        free(sql);
        for (char *p = msg; *p; p++) if (*p == '\n') *p = ' ';
        duckdb_vector_assign_string_element(out, i, msg);
    }
    (void)info;
}

/* --------------------------------------------------------------- register */

static void reg(duckdb_connection con, const char *name, duckdb_type *args, int nargs, duckdb_type ret,
                duckdb_scalar_function_t fn, duckdb_scalar_function_bind_t bind, int volatile_fn) {
    duckdb_scalar_function f = duckdb_create_scalar_function();
    duckdb_scalar_function_set_name(f, name);
    for (int i = 0; i < nargs; i++) {
        duckdb_logical_type t = duckdb_create_logical_type(args[i]);
        duckdb_scalar_function_add_parameter(f, t);
        duckdb_destroy_logical_type(&t);
    }
    duckdb_logical_type r = duckdb_create_logical_type(ret);
    duckdb_scalar_function_set_return_type(f, r);
    duckdb_destroy_logical_type(&r);
    if (bind) duckdb_scalar_function_set_bind(f, bind);
    if (volatile_fn) duckdb_scalar_function_set_volatile(f);
    duckdb_scalar_function_set_function(f, fn);
    duckdb_register_scalar_function(con, f);
    duckdb_destroy_scalar_function(&f);
}

DUCKDB_EXTENSION_ENTRYPOINT(duckdb_connection connection, duckdb_extension_info info,
                            struct duckdb_extension_access *access) {
    /* The database handle is only borrowed while the extension loads, so the
     * long-lived connection is opened here and kept. */
    duckdb_database *db = access->get_database(info);
    if (duckdb_connect(*db, &g_side) == DuckDBError) {
        access->set_error(info, "fractalsql: could not open the side connection");
        return false;
    }
    duckdb_type varchar = DUCKDB_TYPE_VARCHAR;
    reg(connection, "fractal_spike_version", NULL, 0, DUCKDB_TYPE_VARCHAR, version_exec, NULL, 0);
    reg(connection, "fractal_spike_conn", NULL, 0, DUCKDB_TYPE_UBIGINT, conn_exec, conn_bind, 1);
    reg(connection, "fractal_spike_nested", &varchar, 1, DUCKDB_TYPE_VARCHAR, nested_exec, NULL, 1);
    reg(connection, "fractal_spike_stmt", &varchar, 1, DUCKDB_TYPE_VARCHAR, stmt_exec, NULL, 1);
    return true;
}
