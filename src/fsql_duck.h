/* src/fsql_duck.h -- THE ADAPTER between the extension and DuckDB.
 *
 * This is the only header that includes duckdb_extension.h. Family files
 * (ext_*.c) include this and nothing from DuckDB, so a change in how DuckDB
 * spells its C API is a change to fsql_duck.[ch] and nowhere else.
 *
 * It uses only symbols present in BOTH header generations the project builds
 * against (v1.4.x unstable surface and v1.5.6 stable surface), plus the
 * conveniences below. Vectors reach a scalar callback flat (verified on 1.4.5,
 * 1.5.6 and 2.0.0: a constant argument over several chunks reads correctly by
 * row index), so these helpers index by row and need no selection vectors.
 *
 * See ~/github/duckdb-purec-ext-port.txt, section 5.
 */
#ifndef FSQL_DUCK_H
#define FSQL_DUCK_H

#include <stdarg.h>
#include <stdbool.h>

#include "duckdb_extension.h"
#include "fsql_port.h"

DUCKDB_EXTENSION_EXTERN

/* ------------------------------------------------------------- types */

typedef enum {
    FSQL_T_VARCHAR,
    FSQL_T_INTEGER,
    FSQL_T_BIGINT,
    FSQL_T_DOUBLE,
    FSQL_T_BOOLEAN,
    FSQL_T_FLOAT,
    FSQL_T_BLOB,
    FSQL_T_LIST_DOUBLE,
    FSQL_T_LIST_FLOAT,
    FSQL_T_LIST_VARCHAR,
    FSQL_T_LIST_LIST_DOUBLE,
    FSQL_T_LIST_BIGINT,
    FSQL_T_LIST_BLOB,
    FSQL_T_STRUCT_DRIFT,        /* STRUCT(drift, recent_alpha, baseline_alpha DOUBLE)            */
    FSQL_T_STRUCT_TDA,          /* STRUCT(h0_bars LIST(STRUCT(birth, death DOUBLE)), betti1 BIGINT) */
    FSQL_T_STRUCT_DOUBLES,      /* STRUCT of DOUBLE fields; names come from fsql_scalar_def.ret_fields */
    FSQL_T_STRUCT_DOUBLE_LIST,  /* STRUCT(<ret_fields[0]> DOUBLE, <ret_fields[1]> LIST(DOUBLE)) */
    FSQL_T_STRUCT_LOOP          /* STRUCT(agent_id VARCHAR, dfa_exponent DOUBLE, is_loop_detected BOOLEAN) */
} fsql_ty;

#define FSQL_MAX_ARGS 10

#define FSQL_POOL_SIZE          4        /* nested-query connections kept open per instance    */
#define FSQL_POOL_WAIT_MS       30000    /* how long a nested query waits for a free connection */
#define FSQL_CONN_IDLE_SECONDS  3600     /* idle per-connection state is evicted after this    */
#define FSQL_CONN_MAX_ENTRIES   4096

/* fsql_scalar_def.flags */
#define FSQL_FN_VOLATILE      1   /* not folded, re-evaluated per row (side effects, I/O)         */
#define FSQL_FN_SPECIAL_NULL  2   /* NULL arguments are PASSED to the function, not short-circuited */

typedef struct {
    const char                    *name;
    int                            nargs;
    fsql_ty                        args[FSQL_MAX_ARGS];
    fsql_ty                        ret;
    duckdb_scalar_function_t       fn;
    duckdb_scalar_function_bind_t  bind;     /* may be NULL */
    int                            flags;     /* FSQL_FN_* bits */
    /* ret == FSQL_T_STRUCT_DOUBLES only: the field names, NULL-terminated */
    const char *const             *ret_fields;
} fsql_scalar_def;

/* Registers `n` definitions. Consecutive entries with the same name are
 * registered as ONE overload set (SQL overloading by argument types). Returns
 * true on success; on failure `*err` points at a static message. */
bool fsql_register_scalars(duckdb_connection con, const fsql_scalar_def *defs, int n, const char **err);

/* Aggregates. Same grouping rule as scalars: consecutive entries with one name
 * form one overload set. `state_size` bytes of zeroed-by-init memory are allocated
 * per group by the engine; the callbacks are the engine's own typedefs. */
typedef struct {
    const char                   *name;
    int                           nargs;
    fsql_ty                       args[FSQL_MAX_ARGS];
    fsql_ty                       ret;
    duckdb_aggregate_state_size   state_size;
    duckdb_aggregate_init_t       init;
    duckdb_aggregate_update_t     update;
    duckdb_aggregate_combine_t    combine;
    duckdb_aggregate_finalize_t   finalize;
    duckdb_aggregate_destroy_t    destroy;     /* may be NULL */
} fsql_aggregate_def;

bool fsql_register_aggregates(duckdb_connection con, const fsql_aggregate_def *defs, int n, const char **err);

/* Table functions. The C API has NO way to overload a table function, on any supported
 * DuckDB line (1.4.x fails a second registration of a name; 1.5.x and 2.0.x silently keep
 * the first). List the entries of one name in increasing arity: only the LAST -- the full
 * form -- is registered, so the C++ build's optional trailing arguments are required here
 * (limitation L1). */
typedef struct {
    const char                   *name;
    int                           nargs;
    fsql_ty                       args[FSQL_MAX_ARGS];
    duckdb_table_function_bind_t  bind;
    duckdb_table_function_init_t  init;
    duckdb_table_function_t       fn;
    /* optional named parameters, terminated by a NULL name */
    struct { const char *name; fsql_ty type; } named[FSQL_MAX_ARGS];
} fsql_table_def;

/* A named parameter of a table function at bind time. NULL when the caller did not supply it (or
 * supplied NULL); otherwise a value the caller destroys with duckdb_destroy_value. */
duckdb_value fsql_bind_named(duckdb_bind_info info, const char *name);

bool fsql_register_tables(duckdb_connection con, const fsql_table_def *defs, int n, const char **err);

/* ------------------------------------------------------------ errors */

/* Fails the current scalar call with a formatted message. Callers return
 * straight after. */
void fsql_fn_error(duckdb_function_info info, const char *fmt, ...);

/* ----------------------------------------------------- scalar columns */

/* Row `i` of a column is valid (non-NULL). `validity` may be NULL = all valid. */
static inline bool fsql_valid(const uint64_t *validity, idx_t i) {
    return validity == NULL || ((validity[i / 64] >> (i % 64)) & 1ULL);
}

/* Raw access to argument column `c` of a chunk (flat). */
static inline const void *fsql_col_data(duckdb_data_chunk in, idx_t c) {
    return duckdb_vector_get_data(duckdb_data_chunk_get_vector(in, c));
}
static inline const uint64_t *fsql_col_validity(duckdb_data_chunk in, idx_t c) {
    return duckdb_vector_get_validity(duckdb_data_chunk_get_vector(in, c));
}

/* Marks row `i` of an output vector NULL. */
void fsql_set_null(duckdb_vector out, idx_t row);

/* ------------------------------------------------------- LIST(<scalar>) in */

/* A read-only view of a LIST column whose elements are fixed-width. */
typedef struct {
    const duckdb_list_entry *entries;
    const uint64_t          *validity;     /* of the LIST column */
    const void              *child;        /* element data (raw) */
    const uint64_t          *child_valid;
    idx_t                    child_size;
} fsql_list;

void fsql_list_open(fsql_list *l, duckdb_vector v);

/* 1  = ok: (*off, *len) locate the row's elements inside the child vector (no copy);
 * 0  = the row is NULL, or one of its elements is NULL;
 * -1 = malformed entry (offset/length outside the child); *err is a message. */
int fsql_list_range(const fsql_list *l, idx_t row, idx_t *off, size_t *len, const char **err);

/* Length of a non-NULL row's list WITHOUT checking element validity (for dims()).
 * Returns false if the row is NULL. */
bool fsql_list_length(const fsql_list *l, idx_t row, size_t *len);

/* Typed convenience: pointer into the child data plus length, as above. */
static inline int fsql_list_f64_get(const fsql_list *l, idx_t row, const double **out, size_t *len, const char **err) {
    idx_t off = 0; *out = NULL; *len = 0;
    int r = fsql_list_range(l, row, &off, len, err);
    if (r == 1) *out = (const double *)l->child + off;
    return r;
}
static inline int fsql_list_f32_get(const fsql_list *l, idx_t row, const float **out, size_t *len, const char **err) {
    idx_t off = 0; *out = NULL; *len = 0;
    int r = fsql_list_range(l, row, &off, len, err);
    if (r == 1) *out = (const float *)l->child + off;
    return r;
}
/* Kept as the names the first family used. */
typedef fsql_list fsql_list_f64;
#define fsql_list_f64_open fsql_list_open

/* ------------------------------------------------------ LIST(<scalar>) out */

typedef struct {
    duckdb_vector      vec;
    duckdb_list_entry *entries;
    idx_t              used;
} fsql_list_out;

void fsql_list_out_open(fsql_list_out *w, duckdb_vector v);
/* Appends `n` elements of `elem_size` bytes as row `row`'s list. false on OOM. */
bool fsql_list_out_put_raw(fsql_list_out *w, idx_t row, const void *v, size_t n, size_t elem_size);
static inline bool fsql_list_out_put(fsql_list_out *w, idx_t row, const double *v, size_t n) {
    return fsql_list_out_put_raw(w, row, v, n, sizeof(double));
}
static inline bool fsql_list_out_put_f32(fsql_list_out *w, idx_t row, const float *v, size_t n) {
    return fsql_list_out_put_raw(w, row, v, n, sizeof(float));
}
/* Row `row` is NULL (and its list empty). */
void fsql_list_out_put_null(fsql_list_out *w, idx_t row);
/* Must be called once after the last row. */
void fsql_list_out_close(fsql_list_out *w);

/* ------------------------------------------------ LIST(LIST(DOUBLE)) out */

/* Writes row `row` as a list of `nparticles` inner lists. The inner list k has
 * lens[k] doubles, laid out back to back in `flat`. Rows of one result vector may
 * be written across several calls (an aggregate's finalize is invoked per batch
 * with a growing offset), so the running totals start from the vector's current
 * list size. */
typedef struct {
    duckdb_vector      vec;
    duckdb_list_entry *entries;
    idx_t              used_outer;
    idx_t              used_inner;
} fsql_list2_out;

void fsql_list2_out_open(fsql_list2_out *w, duckdb_vector v);
bool fsql_list2_out_put(fsql_list2_out *w, idx_t row, const double *flat, const size_t *lens, size_t nparticles);
void fsql_list2_out_close(fsql_list2_out *w);

/* ------------------------------------------------------------- strings/blobs */

/* A VARCHAR or BLOB cell as pointer + length (no copy). */
static inline const char *fsql_str_data(const duckdb_string_t *s, size_t *len) {
    *len = (size_t)duckdb_string_t_length(*s);
    return duckdb_string_t_data((duckdb_string_t *)s);
}
/* Writes a VARCHAR/BLOB result of explicit length (binary-safe). */
static inline void fsql_set_str(duckdb_vector out, idx_t row, const char *p, size_t n) {
    duckdb_vector_assign_string_element_len(out, row, p, n);
}

/* ------------------------------------------------------ the instance */

/* One fsql_instance exists per LOAD of the extension, i.e. per DuckDB database instance in this
 * process. Everything that is per-database -- the nested-query pool, the per-connection state
 * registry and the destructive latch -- hangs off it, so two databases opened in one process (a
 * Python test, say) never share a ledger or run each other's nested queries. The stable C API
 * gives a connection id but no database identity, and connection ids are only unique within one
 * database; the instance supplies the missing half of the key.
 *
 * Every function the adapter registers carries its instance as the registration's "extra info",
 * so a callback reaches it with fsql_scalar_instance / fsql_bind_instance / fsql_table_instance.
 *
 * Lifetime. The nested-query connections (below) are opened at LOAD, because the stable C API only
 * lends the database handle while LOAD runs, and a live connection keeps the host's database instance
 * alive. While the pool is open the host cannot finish closing the database: no shutdown checkpoint,
 * the file stays open, the process-wide lock stays held. Two controls make that a choice rather than a
 * fact of life:
 *   FRACTALSQL_NESTED_QUERIES=off (read at LOAD)  opens no pool at all; the functions that run SQL on
 *                                                 the caller's database report that they are off.
 *   fractal_release()                             closes the pool on demand, irreversibly, so the
 *                                                 database can close cleanly. */
typedef struct fsql_instance fsql_instance;

/* Called from the entry point, before any registration. The database handle is only borrowed while
 * LOAD runs, so this is where the nested-query connections are opened. */
fsql_instance *fsql_instance_create(duckdb_database db, const char **err);

/* State of the nested-query pool. */
typedef enum { FSQL_POOL_ON = 0, FSQL_POOL_OFF = 1 /* never opened */, FSQL_POOL_RELEASED = 2,
               FSQL_POOL_FROZEN = 3 /* transient: a release is being verified; nested queries wait */ } fsql_pool_state;
fsql_pool_state fsql_instance_pool_state(const fsql_instance *inst);

/* Closes the pool so the host can release the database. Waits for nested queries in flight, then
 * disconnects. Idempotent. 0 on success; -1 with `err` set when it refuses (the destructive latch is
 * set, or the caller is itself inside a nested query). Nested queries after a release fail cleanly. */
int fsql_instance_release(fsql_instance *inst, char *err, size_t err_cap);

/* Ends the entry point's own claim on the instance (and clears the registering instance). Every registered
 * function holds one claim, released when the host destroys the function, as does the host-departure
 * monitor; the last one frees the instance. Call it once, when registration has finished, success or not. */
void fsql_instance_registration_done(fsql_instance *inst);

fsql_instance *fsql_scalar_instance(duckdb_function_info info);
fsql_instance *fsql_bind_instance(duckdb_bind_info info);          /* a table function's bind callback */
fsql_instance *fsql_table_instance(duckdb_function_info info);     /* a table function's execute callback */

/* The destructive latch is per DATABASE: once set, it cannot be cleared, so SQL run later on any
 * connection of this database (including SQL a reasoning agent generated) cannot undo it. */
void fsql_instance_latch(fsql_instance *inst);
bool fsql_instance_latched(const fsql_instance *inst);

/* ------------------------------------------------- nested queries (the pool) */

/* A nested query takes one of the instance's pooled connections, runs, and returns it -- the C
 * counterpart of the C++ build's short-lived `Connection side(*context.db)`. As there, it runs in
 * its OWN autocommit frame: data written in the caller's still-open transaction is NOT visible to
 * it, only what is committed.
 *
 * Re-entrancy: a thread that already holds a pool connection and finds the pool empty gets an
 * error rather than waiting for itself. */
typedef struct {
    duckdb_result res;
    bool          have;       /* res is live */
} fsql_qres;

/* Runs `sql`. 0 on success; -1 with a message in `err` (already in the C++ build's wording:
 * "fractalsql: internal query failed: <engine error>\nSQL: <sql>", with a leading
 * "fractalsql: " not doubled when the engine error already carries it). */
int    fsql_nested_query(fsql_instance *inst, const char *sql, fsql_qres *out, char *err, size_t err_cap);
void   fsql_qres_free(fsql_qres *q);
idx_t  fsql_qres_columns(const fsql_qres *q);
idx_t  fsql_qres_rows(const fsql_qres *q);
/* Next data chunk, or NULL when exhausted; the caller destroys it with duckdb_destroy_data_chunk. */
duckdb_data_chunk fsql_qres_next_chunk(fsql_qres *q);

/* --------------------------------------------- bind-time result sets */

/* Most table functions compute their whole (small) result at bind time and then stream it. A rowset
 * holds that result: declare the columns, add rows cell by cell, hand it to the bind info, and use
 * fsql_rowset_init / fsql_rowset_scan as the function's init and execute callbacks. */
typedef enum { FSQL_RS_VARCHAR, FSQL_RS_DOUBLE, FSQL_RS_BIGINT, FSQL_RS_INTEGER, FSQL_RS_BOOLEAN,
               FSQL_RS_LIST_DOUBLE, FSQL_RS_LIST_BIGINT } fsql_rs_ty;
typedef struct fsql_rowset fsql_rowset;

fsql_rowset *fsql_rowset_new(int ncols, const char *const *names, const fsql_rs_ty *types);   /* NULL on OOM */
void fsql_rowset_free(fsql_rowset *rs);
/* Starts a new (all-NULL) row; false on OOM. The cell setters below fill the LAST row. */
bool fsql_rs_row(fsql_rowset *rs);
bool fsql_rs_str(fsql_rowset *rs, int col, const char *s, size_t n);
bool fsql_rs_f64(fsql_rowset *rs, int col, double v);
bool fsql_rs_i64(fsql_rowset *rs, int col, int64_t v);        /* BIGINT and INTEGER columns */
bool fsql_rs_bool(fsql_rowset *rs, int col, bool v);
bool fsql_rs_list_f64(fsql_rowset *rs, int col, const double *v, size_t n);
bool fsql_rs_list_i64(fsql_rowset *rs, int col, const int64_t *v, size_t n);
/* Declares the result columns on `info` and attaches the rowset (ownership passes to DuckDB). */
void fsql_rowset_bind(duckdb_bind_info info, fsql_rowset *rs);
void fsql_rowset_init(duckdb_init_info info);
void fsql_rowset_scan(duckdb_function_info info, duckdb_data_chunk out);

/* ------------------------------------------------- per-instance singletons */

#define FSQL_SINGLETON_SLOTS 4
/* A zero-initialised object of `size` bytes owned by the instance (created, and `init`ed, on first use;
 * never freed -- the stable C API has no unload hook). NULL on out-of-memory or a bad slot. */
void *fsql_instance_singleton(fsql_instance *inst, int slot, size_t size, void (*init)(void *), void (*destroy)(void *));

/* ------------------------------------------------- statement classification */

/* The C API has no parser/AST, so a statement is classified with duckdb_extract_statements (parse only:
 * statement count, syntax errors) and, for a single statement, duckdb_prepared_statement_type. */
enum { FSQL_STMT_UNKNOWN = 0, FSQL_STMT_SELECT, FSQL_STMT_INSERT, FSQL_STMT_UPDATE, FSQL_STMT_OTHER };

/* 0 on success: *nstmts is the statement count and, when it is exactly one and preparing it succeeds,
 * *type its class (FSQL_STMT_UNKNOWN when it could not be prepared -- e.g. it names a missing table; the
 * caller's later EXPLAIN reports that). -1 with the parser's message in `err` when the text does not parse. */
int fsql_classify_sql(fsql_instance *inst, const char *sql, int *nstmts, int *type, char *err, size_t err_cap);

/* --------------------------------------------- per-connection state registry */

/* The stable C API has no connection-close hook, so state that belongs to one connection (the
 * ledger, the destructive flag, the diversify flag) lives in a registry keyed by (instance,
 * connection id), with idle-time and entry-count eviction. A scalar function that needs it
 * registers fsql_bind_capture_conn as its bind callback and calls fsql_exec_conn_id from its
 * execute callback: the client context -- and so the connection id -- is reachable only at bind
 * time. */
void  fsql_bind_capture_conn(duckdb_bind_info info);
idx_t fsql_exec_conn_id(duckdb_function_info info);

/* The state for connection `conn_id`: allocated zeroed (size bytes) and passed to init on first use.
 * `destroy` runs when the entry is evicted. NULL only on out-of-memory. The returned pointer stays
 * valid until the entry is evicted (>= FSQL_CONN_IDLE_SECONDS idle). */
typedef void (*fsql_conn_init_fn)(void *state);
typedef void (*fsql_conn_destroy_fn)(void *state);
void *fsql_conn_state(fsql_instance *inst, idx_t conn_id, size_t size, fsql_conn_init_fn init, fsql_conn_destroy_fn destroy);

/* ------------------------------------------------------------- version */

/* Parses "v1.5.6" / "v2.0.0" into numbers. false if it is not that shape. */
bool fsql_parse_version(const char *s, int *major, int *minor, int *patch);

#endif /* FSQL_DUCK_H */
