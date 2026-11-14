/* src/fsql_duck.c -- implementation of the adapter (see fsql_duck.h). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <limits.h>
#include "fsql_duck.h"

/* the instance whose functions are being registered (set by fsql_instance_create) */
static void inst_ref(fsql_instance *inst);
static void inst_unref_cb(void *p);
static FSQL_TLS fsql_instance *g_registering;   /* thread-local: two databases can LOAD at once */

/* --------------------------------------------------------- registration */

static duckdb_logical_type make_list(duckdb_type elem) {
    duckdb_logical_type d = duckdb_create_logical_type(elem);
    duckdb_logical_type l = duckdb_create_list_type(d);
    duckdb_destroy_logical_type(&d);
    return l;
}

static duckdb_logical_type make_struct_doubles(const char *const *names) {
    int n = 0;
    while (names && names[n]) n++;
    duckdb_logical_type *t = (duckdb_logical_type *)malloc((size_t)(n ? n : 1) * sizeof *t);
    if (!t) return NULL;
    for (int i = 0; i < n; i++) t[i] = duckdb_create_logical_type(DUCKDB_TYPE_DOUBLE);
    duckdb_logical_type st = duckdb_create_struct_type(t, (const char **)names, (idx_t)n);
    for (int i = 0; i < n; i++) duckdb_destroy_logical_type(&t[i]);
    free(t);
    return st;
}

static duckdb_logical_type make_struct_double_list(const char *const *names) {
    duckdb_logical_type t[2] = { duckdb_create_logical_type(DUCKDB_TYPE_DOUBLE), make_list(DUCKDB_TYPE_DOUBLE) };
    duckdb_logical_type st = duckdb_create_struct_type(t, (const char **)names, 2);
    duckdb_destroy_logical_type(&t[0]); duckdb_destroy_logical_type(&t[1]);
    return st;
}

static duckdb_logical_type make_type(fsql_ty t) {
    switch (t) {
    case FSQL_T_VARCHAR: return duckdb_create_logical_type(DUCKDB_TYPE_VARCHAR);
    case FSQL_T_INTEGER: return duckdb_create_logical_type(DUCKDB_TYPE_INTEGER);
    case FSQL_T_BIGINT:  return duckdb_create_logical_type(DUCKDB_TYPE_BIGINT);
    case FSQL_T_DOUBLE:  return duckdb_create_logical_type(DUCKDB_TYPE_DOUBLE);
    case FSQL_T_BOOLEAN: return duckdb_create_logical_type(DUCKDB_TYPE_BOOLEAN);
    case FSQL_T_FLOAT:   return duckdb_create_logical_type(DUCKDB_TYPE_FLOAT);
    case FSQL_T_BLOB:    return duckdb_create_logical_type(DUCKDB_TYPE_BLOB);
    case FSQL_T_LIST_DOUBLE:  return make_list(DUCKDB_TYPE_DOUBLE);
    case FSQL_T_LIST_FLOAT:   return make_list(DUCKDB_TYPE_FLOAT);
    case FSQL_T_LIST_VARCHAR: return make_list(DUCKDB_TYPE_VARCHAR);
    case FSQL_T_STRUCT_DOUBLES:      return NULL;   /* need field names: see build_one */
    case FSQL_T_STRUCT_DOUBLE_LIST:  return NULL;
    case FSQL_T_LIST_BIGINT:  return make_list(DUCKDB_TYPE_BIGINT);
    case FSQL_T_LIST_BLOB:    return make_list(DUCKDB_TYPE_BLOB);
    case FSQL_T_STRUCT_DRIFT: {
        duckdb_logical_type d[3] = { duckdb_create_logical_type(DUCKDB_TYPE_DOUBLE),
                                     duckdb_create_logical_type(DUCKDB_TYPE_DOUBLE),
                                     duckdb_create_logical_type(DUCKDB_TYPE_DOUBLE) };
        const char *names[3] = { "drift", "recent_alpha", "baseline_alpha" };
        duckdb_logical_type st = duckdb_create_struct_type(d, names, 3);
        for (int i = 0; i < 3; i++) duckdb_destroy_logical_type(&d[i]);
        return st;
    }
    case FSQL_T_STRUCT_LOOP: {
        duckdb_logical_type f[3] = { duckdb_create_logical_type(DUCKDB_TYPE_VARCHAR),
                                     duckdb_create_logical_type(DUCKDB_TYPE_DOUBLE),
                                     duckdb_create_logical_type(DUCKDB_TYPE_BOOLEAN) };
        const char *names[3] = { "agent_id", "dfa_exponent", "is_loop_detected" };
        duckdb_logical_type st = duckdb_create_struct_type(f, names, 3);
        for (int i = 0; i < 3; i++) duckdb_destroy_logical_type(&f[i]);
        return st;
    }
    case FSQL_T_STRUCT_TDA: {
        duckdb_logical_type bd[2] = { duckdb_create_logical_type(DUCKDB_TYPE_DOUBLE),
                                      duckdb_create_logical_type(DUCKDB_TYPE_DOUBLE) };
        const char *bnames[2] = { "birth", "death" };
        duckdb_logical_type bar = duckdb_create_struct_type(bd, bnames, 2);
        duckdb_logical_type bars = duckdb_create_list_type(bar);
        duckdb_logical_type f[2] = { bars, duckdb_create_logical_type(DUCKDB_TYPE_BIGINT) };
        const char *fnames[2] = { "h0_bars", "betti1" };
        duckdb_logical_type st = duckdb_create_struct_type(f, fnames, 2);
        duckdb_destroy_logical_type(&bd[0]); duckdb_destroy_logical_type(&bd[1]);
        duckdb_destroy_logical_type(&bar); duckdb_destroy_logical_type(&bars);
        duckdb_destroy_logical_type(&f[1]);
        return st;
    }
    case FSQL_T_LIST_LIST_DOUBLE: {
        duckdb_logical_type inner = make_list(DUCKDB_TYPE_DOUBLE);
        duckdb_logical_type outer = duckdb_create_list_type(inner);
        duckdb_destroy_logical_type(&inner);
        return outer;
    }
    }
    return NULL;
}

static duckdb_scalar_function build_one(const fsql_scalar_def *d) {
    duckdb_scalar_function f = duckdb_create_scalar_function();
    duckdb_scalar_function_set_name(f, d->name);
    for (int i = 0; i < d->nargs; i++) {
        duckdb_logical_type t = make_type(d->args[i]);
        duckdb_scalar_function_add_parameter(f, t);
        duckdb_destroy_logical_type(&t);
    }
    duckdb_logical_type r = d->ret == FSQL_T_STRUCT_DOUBLES ? make_struct_doubles(d->ret_fields)
                          : d->ret == FSQL_T_STRUCT_DOUBLE_LIST ? make_struct_double_list(d->ret_fields)
                          : make_type(d->ret);
    if (!r) { duckdb_destroy_scalar_function(&f); return NULL; }      /* out of memory building the return type */
    duckdb_scalar_function_set_return_type(f, r);
    duckdb_destroy_logical_type(&r);
    if (d->bind) duckdb_scalar_function_set_bind(f, d->bind);
    if (d->flags & FSQL_FN_VOLATILE) duckdb_scalar_function_set_volatile(f);
    if (d->flags & FSQL_FN_SPECIAL_NULL) duckdb_scalar_function_set_special_handling(f);
    duckdb_scalar_function_set_function(f, d->fn);
    if (g_registering) { inst_ref(g_registering); duckdb_scalar_function_set_extra_info(f, g_registering, inst_unref_cb); }   /* the instance */
    return f;
}

bool fsql_register_scalars(duckdb_connection con, const fsql_scalar_def *defs, int n, const char **err) {
    int i = 0;
    while (i < n) {
        int j = i;
        while (j < n && strcmp(defs[j].name, defs[i].name) == 0) j++;
        duckdb_scalar_function_set set = duckdb_create_scalar_function_set(defs[i].name);
        for (int k = i; k < j; k++) {
            duckdb_scalar_function f = build_one(&defs[k]);
            if (!f) {
                duckdb_destroy_scalar_function_set(&set);
                *err = "fractalsql: out of memory registering a scalar function";
                return false;
            }
            duckdb_state st = duckdb_add_scalar_function_to_set(set, f);
            duckdb_destroy_scalar_function(&f);
            if (st != DuckDBSuccess) {
                duckdb_destroy_scalar_function_set(&set);
                *err = "could not add a scalar function overload";
                return false;
            }
        }
        duckdb_state st = duckdb_register_scalar_function_set(con, set);
        duckdb_destroy_scalar_function_set(&set);
        if (st != DuckDBSuccess) { *err = "could not register a scalar function"; return false; }
        i = j;
    }
    return true;
}

/* --------------------------------------------------------- table functions */

bool fsql_register_tables(duckdb_connection con, const fsql_table_def *defs, int n, const char **err) {
    for (int i = 0; i < n; i++) {
        /* The C API cannot overload a table function on ANY supported line: 1.4.x fails a
         * second registration of a name and 1.5.x / 2.0.x silently keep the first. Entries
         * with one name are listed in increasing arity, so register only the last (the full
         * form); an optional trailing argument of the C++ build is REQUIRED here. Known
         * limitation L1 -- see the porting plan. */
        if (i + 1 < n && strcmp(defs[i].name, defs[i + 1].name) == 0) continue;
        duckdb_table_function f = duckdb_create_table_function();
        duckdb_table_function_set_name(f, defs[i].name);
        for (int k = 0; k < defs[i].nargs; k++) {
            duckdb_logical_type t = make_type(defs[i].args[k]);
            duckdb_table_function_add_parameter(f, t);
            duckdb_destroy_logical_type(&t);
        }
        for (int k = 0; k < FSQL_MAX_ARGS && defs[i].named[k].name; k++) {
            duckdb_logical_type t = make_type(defs[i].named[k].type);
            duckdb_table_function_add_named_parameter(f, defs[i].named[k].name, t);
            duckdb_destroy_logical_type(&t);
        }
        duckdb_table_function_set_bind(f, defs[i].bind);
        duckdb_table_function_set_init(f, defs[i].init);
        duckdb_table_function_set_function(f, defs[i].fn);
        if (g_registering) { inst_ref(g_registering); duckdb_table_function_set_extra_info(f, g_registering, inst_unref_cb); }   /* the instance */
        duckdb_state st = duckdb_register_table_function(con, f);
        duckdb_destroy_table_function(&f);
        if (st != DuckDBSuccess) { *err = "could not register a table function"; return false; }
    }
    return true;
}

duckdb_value fsql_bind_named(duckdb_bind_info info, const char *name) {
    duckdb_value v = duckdb_bind_get_named_parameter(info, name);
    if (!v) return NULL;
    if (duckdb_is_null_value(v)) { duckdb_destroy_value(&v); return NULL; }
    return v;
}

/* ------------------------------------------------------------- aggregates */

static duckdb_aggregate_function build_agg(const fsql_aggregate_def *d) {
    duckdb_aggregate_function f = duckdb_create_aggregate_function();
    duckdb_aggregate_function_set_name(f, d->name);
    for (int i = 0; i < d->nargs; i++) {
        duckdb_logical_type t = make_type(d->args[i]);
        duckdb_aggregate_function_add_parameter(f, t);
        duckdb_destroy_logical_type(&t);
    }
    duckdb_logical_type r = make_type(d->ret);
    duckdb_aggregate_function_set_return_type(f, r);
    duckdb_destroy_logical_type(&r);
    duckdb_aggregate_function_set_functions(f, d->state_size, d->init, d->update, d->combine, d->finalize);
    if (d->destroy) duckdb_aggregate_function_set_destructor(f, d->destroy);
    return f;
}

bool fsql_register_aggregates(duckdb_connection con, const fsql_aggregate_def *defs, int n, const char **err) {
    int i = 0;
    while (i < n) {
        int j = i;
        while (j < n && strcmp(defs[j].name, defs[i].name) == 0) j++;
        duckdb_aggregate_function_set set = duckdb_create_aggregate_function_set(defs[i].name);
        for (int k = i; k < j; k++) {
            duckdb_aggregate_function f = build_agg(&defs[k]);
            duckdb_state st = duckdb_add_aggregate_function_to_set(set, f);
            duckdb_destroy_aggregate_function(&f);
            if (st != DuckDBSuccess) {
                duckdb_destroy_aggregate_function_set(&set);
                *err = "could not add an aggregate function overload";
                return false;
            }
        }
        duckdb_state st = duckdb_register_aggregate_function_set(con, set);
        duckdb_destroy_aggregate_function_set(&set);
        if (st != DuckDBSuccess) { *err = "could not register an aggregate function"; return false; }
        i = j;
    }
    return true;
}

/* --------------------------------------------------------------- errors */

void fsql_fn_error(duckdb_function_info info, const char *fmt, ...) {
    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    duckdb_scalar_function_set_error(info, msg);
}

/* -------------------------------------------------------------- vectors */

void fsql_set_null(duckdb_vector out, idx_t row) {
    duckdb_vector_ensure_validity_writable(out);
    duckdb_validity_set_row_invalid(duckdb_vector_get_validity(out), row);
}

void fsql_list_open(fsql_list *l, duckdb_vector v) {
    duckdb_vector child = duckdb_list_vector_get_child(v);
    l->entries     = (const duckdb_list_entry *)duckdb_vector_get_data(v);
    l->validity    = duckdb_vector_get_validity(v);
    l->child       = duckdb_vector_get_data(child);
    l->child_valid = duckdb_vector_get_validity(child);
    l->child_size  = duckdb_list_vector_get_size(v);
}

int fsql_list_range(const fsql_list *l, idx_t row, idx_t *off, size_t *len, const char **err) {
    if (!fsql_valid(l->validity, row)) return 0;
    duckdb_list_entry e = l->entries[row];
    /* offset + length must neither wrap nor run past the child vector: refuse
     * a malformed entry at this boundary instead of reading outside it. */
    if (e.offset > UINT64_MAX - e.length || e.offset + e.length > l->child_size) {
        *err = "fractalsql: list vector entry has out-of-range offset/length";
        return -1;
    }
    for (idx_t j = 0; j < e.length; j++)
        if (!fsql_valid(l->child_valid, e.offset + j)) return 0;
    *off = e.offset;
    *len = (size_t)e.length;
    return 1;
}

bool fsql_list_length(const fsql_list *l, idx_t row, size_t *len) {
    if (!fsql_valid(l->validity, row)) return false;
    *len = (size_t)l->entries[row].length;
    return true;
}

void fsql_list_out_open(fsql_list_out *w, duckdb_vector v) {
    w->vec     = v;
    w->entries = (duckdb_list_entry *)duckdb_vector_get_data(v);
    /* continue from the current size: an aggregate's finalize writes one result
     * vector across several calls */
    w->used    = duckdb_list_vector_get_size(v);
}

bool fsql_list_out_put_raw(fsql_list_out *w, idx_t row, const void *v, size_t n, size_t elem_size) {
    if (duckdb_list_vector_reserve(w->vec, w->used + (idx_t)n) != DuckDBSuccess) return false;
    /* fetch the child AFTER reserving: reserve may move its storage */
    duckdb_vector child = duckdb_list_vector_get_child(w->vec);
    char *dst = (char *)duckdb_vector_get_data(child);
    if (n) memcpy(dst + (size_t)w->used * elem_size, v, n * elem_size);
    w->entries[row].offset = w->used;
    w->entries[row].length = (idx_t)n;
    w->used += (idx_t)n;
    return true;
}

void fsql_list_out_put_null(fsql_list_out *w, idx_t row) {
    fsql_set_null(w->vec, row);
    w->entries[row].offset = w->used;
    w->entries[row].length = 0;
}

void fsql_list_out_close(fsql_list_out *w) {
    duckdb_list_vector_set_size(w->vec, w->used);
}

void fsql_list2_out_open(fsql_list2_out *w, duckdb_vector v) {
    duckdb_vector child = duckdb_list_vector_get_child(v);
    w->vec        = v;
    w->entries    = (duckdb_list_entry *)duckdb_vector_get_data(v);
    w->used_outer = duckdb_list_vector_get_size(v);
    w->used_inner = duckdb_list_vector_get_size(child);
}

bool fsql_list2_out_put(fsql_list2_out *w, idx_t row, const double *flat, const size_t *lens, size_t nparticles) {
    size_t total = 0;
    for (size_t k = 0; k < nparticles; k++) total += lens[k];
    if (duckdb_list_vector_reserve(w->vec, w->used_outer + (idx_t)nparticles) != DuckDBSuccess) return false;
    duckdb_vector mid = duckdb_list_vector_get_child(w->vec);                 /* LIST(DOUBLE) */
    if (duckdb_list_vector_reserve(mid, w->used_inner + (idx_t)total) != DuckDBSuccess) return false;
    duckdb_vector leaf = duckdb_list_vector_get_child(mid);                   /* DOUBLE */
    duckdb_list_entry *inner = (duckdb_list_entry *)duckdb_vector_get_data(mid);
    double *dst = (double *)duckdb_vector_get_data(leaf);
    w->entries[row].offset = w->used_outer;
    w->entries[row].length = (idx_t)nparticles;
    size_t pos = 0;
    for (size_t k = 0; k < nparticles; k++) {
        inner[w->used_outer + k].offset = w->used_inner;
        inner[w->used_outer + k].length = (idx_t)lens[k];
        if (lens[k]) memcpy(dst + w->used_inner, flat + pos, lens[k] * sizeof(double));
        w->used_inner += (idx_t)lens[k];
        pos += lens[k];
    }
    w->used_outer += (idx_t)nparticles;
    return true;
}

void fsql_list2_out_close(fsql_list2_out *w) {
    duckdb_vector mid = duckdb_list_vector_get_child(w->vec);
    duckdb_list_vector_set_size(w->vec, w->used_outer);
    duckdb_list_vector_set_size(mid, w->used_inner);
}


/* ------------------------------------------------------ the instance */

typedef struct conn_entry {
    idx_t                 id;
    void                 *state;
    fsql_conn_destroy_fn  destroy;
    time_t                last_used;
    struct conn_entry    *next;
} conn_entry;

struct fsql_instance {
    idx_t             token;                       /* process-unique, for diagnostics */
    /* the nested-query pool */
    fsql_mu_t         pool_mu;
    fsql_cv_t         pool_cv;
    duckdb_connection pool[FSQL_POOL_SIZE];
    bool              busy[FSQL_POOL_SIZE];
    int               pool_n;                      /* connections available to new nested queries  */
    int               pool_cap;                    /* connections opened at LOAD (0 when OFF)       */
    fsql_pool_state   pool_state;
    uint64_t          acquire_seq;                 /* nested-query acquisitions so far (guarded by pool_mu): the monitor reads it as activity */
    /* the host-departure monitor (see "host departure" below) */
    fsql_mu_t         mon_mu;
    fsql_cv_t         mon_cv;
    fsql_thread_t     mon_thread;
    int               mon_state;                   /* MON_NONE / MON_RUNNING / MON_JOINING / MON_DETACHED */
    bool              mon_stop;
    int               mon_mode;                    /* HOST_CLOSE_* */
    unsigned          mon_poll_ms, mon_grace_ms, mon_hold_ms;   /* hold: test knob, widens the freeze window */
    /* the per-connection state registry */
    fsql_mu_t         conn_mu;
    conn_entry       *conn_head;
    size_t            conn_count;
    /* the database-level destructive latch */
    volatile int      latched;
    /* per-instance singletons (see fsql_instance_singleton) */
    fsql_mu_t         single_mu;
    void             *single[FSQL_SINGLETON_SLOTS];
    void            (*single_destroy[FSQL_SINGLETON_SLOTS])(void *);
    int               refs;                        /* see fsql_instance_registration_done; guarded by g_ref_mu */
};

static fsql_mu_t g_ref_mu = FSQL_MU_INIT;

static void conn_entry_drop(conn_entry *e);

static void inst_ref(fsql_instance *inst) {
    fsql_mu_lock(&g_ref_mu); inst->refs++; fsql_mu_unlock(&g_ref_mu);
}
static void inst_free(fsql_instance *inst) {
    while (inst->conn_head) { conn_entry *e = inst->conn_head; inst->conn_head = e->next; conn_entry_drop(e); }
    for (int i = 0; i < FSQL_SINGLETON_SLOTS; i++) {
        if (inst->single[i] && inst->single_destroy[i]) inst->single_destroy[i](inst->single[i]);
        free(inst->single[i]);
    }
    free(inst);
}
static void inst_unref(fsql_instance *inst) {
    fsql_mu_lock(&g_ref_mu);
    int left = --inst->refs;
    fsql_mu_unlock(&g_ref_mu);
    if (left == 0) inst_free(inst);
}
static void inst_unref_cb(void *p) { inst_unref((fsql_instance *)p); }

void fsql_instance_registration_done(fsql_instance *inst) {
    g_registering = NULL;
    inst_unref(inst);
}

static FSQL_TLS int t_pool_depth;           /* pool connections this thread currently holds */

/* FRACTALSQL_NESTED_QUERIES=off|0|false|no turns the pool off. Read once, at LOAD. */
static bool nested_queries_off(void) {
    const char *v = getenv("FRACTALSQL_NESTED_QUERIES");
    if (!v || !*v) return false;
    return !strcmp(v, "off") || !strcmp(v, "0") || !strcmp(v, "false") || !strcmp(v, "no");
}

static void monitor_policy(fsql_instance *inst);
static void monitor_start(fsql_instance *inst);
static void monitor_stop(fsql_instance *inst);

fsql_instance *fsql_instance_create(duckdb_database db, const char **err) {
    static idx_t next_token;
    static fsql_mu_t token_mu = FSQL_MU_INIT;
    fsql_instance *inst = (fsql_instance *)calloc(1, sizeof *inst);
    if (!inst) { *err = "fractalsql: out of memory"; return NULL; }
    fsql_mu_lock(&token_mu); inst->token = ++next_token; fsql_mu_unlock(&token_mu);
    inst->refs = 1;                                 /* the entry point's claim: fsql_instance_registration_done */
    fsql_mu_init(&inst->pool_mu); fsql_cv_init(&inst->pool_cv); fsql_mu_init(&inst->conn_mu); fsql_mu_init(&inst->single_mu);
    fsql_mu_init(&inst->mon_mu); fsql_cv_init(&inst->mon_cv);
    if (nested_queries_off()) {
        inst->pool_state = FSQL_POOL_OFF;           /* nothing is opened, so nothing pins the database */
    } else {
        for (int i = 0; i < FSQL_POOL_SIZE; i++) {
            if (duckdb_connect(db, &inst->pool[i]) != DuckDBSuccess) {
                for (int k = 0; k < i; k++) duckdb_disconnect(&inst->pool[k]);
                free(inst);
                *err = "fractalsql: could not open the nested-query connection pool";
                return NULL;
            }
        }
        inst->pool_n = inst->pool_cap = FSQL_POOL_SIZE;
        inst->pool_state = FSQL_POOL_ON;
        monitor_policy(inst);
        monitor_start(inst);
    }
    g_registering = inst;
    return inst;
}

fsql_pool_state fsql_instance_pool_state(const fsql_instance *inst) { return inst->pool_state; }

fsql_instance *fsql_scalar_instance(duckdb_function_info info) { return (fsql_instance *)duckdb_scalar_function_get_extra_info(info); }
fsql_instance *fsql_bind_instance(duckdb_bind_info info)       { return (fsql_instance *)duckdb_bind_get_extra_info(info); }
fsql_instance *fsql_table_instance(duckdb_function_info info)  { return (fsql_instance *)duckdb_function_get_extra_info(info); }

void fsql_instance_latch(fsql_instance *inst) { inst->latched = 1; }
bool fsql_instance_latched(const fsql_instance *inst) { return inst && inst->latched != 0; }

/* ------------------------------------------------- nested queries (the pool) */

/* Returns the pool index, or -1 with `err` set. */
static int pool_acquire(fsql_instance *inst, char *err, size_t cap) {
    fsql_mu_lock(&inst->pool_mu);
    for (;;) {
        if (inst->pool_state == FSQL_POOL_FROZEN) {    /* a release is being verified: wait for its outcome */
            if (fsql_cv_wait_ms(&inst->pool_cv, &inst->pool_mu, FSQL_POOL_WAIT_MS) != 0) {
                fsql_mu_unlock(&inst->pool_mu);
                snprintf(err, cap, "fractalsql: timed out waiting for the nested-query pool");
                return -1;
            }
            continue;
        }
        for (int i = 0; i < inst->pool_n; i++) {
            if (!inst->busy[i]) { inst->busy[i] = true; inst->acquire_seq++; t_pool_depth++; fsql_mu_unlock(&inst->pool_mu); return i; }
        }
        if (inst->pool_n == 0) {
            fsql_pool_state st = inst->pool_state;
            fsql_mu_unlock(&inst->pool_mu);
            snprintf(err, cap, "%s", st == FSQL_POOL_OFF
                ? "fractalsql: nested queries are off (FRACTALSQL_NESTED_QUERIES=off); this function needs them"
                : "fractalsql: nested queries were released by fractal_release() (or because every client connection had closed); this function needs them, and they cannot be reopened");
            return -1;
        }
        if (t_pool_depth > 0) {
            /* this thread holds connections itself: waiting for one would wait for ourselves */
            fsql_mu_unlock(&inst->pool_mu);
            snprintf(err, cap, "fractalsql: nested queries are nested too deeply (all %d pool connections are in use)", FSQL_POOL_SIZE);
            return -1;
        }
        if (fsql_cv_wait_ms(&inst->pool_cv, &inst->pool_mu, FSQL_POOL_WAIT_MS) != 0) {
            fsql_mu_unlock(&inst->pool_mu);
            snprintf(err, cap, "fractalsql: timed out waiting for a free nested-query connection");
            return -1;
        }
    }
}

static void pool_release(fsql_instance *inst, int idx) {
    fsql_mu_lock(&inst->pool_mu);
    inst->busy[idx] = false;
    t_pool_depth--;
    fsql_cv_broadcast(&inst->pool_cv);
    fsql_mu_unlock(&inst->pool_mu);
}

int fsql_instance_release(fsql_instance *inst, char *err, size_t err_cap) {
    /* The destructive latch is deliberately not consulted here. The latch refuses the destructive *ledger* actions
     * (flush, load, compact, reset, audit_log); it does not forbid the extension from closing the connections it
     * keeps for nested queries. A latched database still has to be releasable: a host that cannot release it has
     * no way to close the database cleanly, and the host-departure monitor's release then races the host's own
     * teardown (an access violation at process exit, which a release build masks and a sanitizer build names).
     * The release writes nothing: it closes the nested-query pool, and the engine's own shutdown checkpoint runs
     * when the host closes the database. */
    if (t_pool_depth > 0) { snprintf(err, err_cap, "fractalsql: fractal_release() cannot be called from inside a nested query"); return -1; }
    monitor_stop(inst);          /* joins the host-departure monitor: it can no longer race this release */
    fsql_mu_lock(&inst->pool_mu);
    if (inst->pool_state != FSQL_POOL_ON) { fsql_mu_unlock(&inst->pool_mu); return 0; }      /* off, or already released */
    inst->pool_n = 0;                                   /* no new nested query can start */
    inst->pool_state = FSQL_POOL_RELEASED;
    for (;;) {                                          /* wait for the ones in flight */
        bool any = false;
        for (int i = 0; i < inst->pool_cap; i++) if (inst->busy[i]) any = true;
        if (!any) break;
        if (fsql_cv_wait_ms(&inst->pool_cv, &inst->pool_mu, FSQL_POOL_WAIT_MS) != 0) {
            /* The pool stays released (no new nested query can start); the connections still in use are
             * not closed here, so the database stays pinned until those queries finish. */
            fsql_mu_unlock(&inst->pool_mu);
            snprintf(err, err_cap, "fractalsql: fractal_release(): timed out waiting for nested queries in flight");
            return -1;
        }
    }
    fsql_mu_unlock(&inst->pool_mu);
    for (int i = 0; i < inst->pool_cap; i++) duckdb_disconnect(&inst->pool[i]);
    inst->pool_cap = 0;
    return 0;
}

/* ------------------------------------------------------- host departure
 *
 * The C API lends the database handle only during LOAD, so the pool above has to be opened then, and a live
 * connection keeps the host's database instance alive: when the host closes its last connection and the
 * database, the shutdown checkpoint, the file descriptor and the file lock would all wait for process exit.
 * This monitor closes that gap with nothing but SQL and the pool's own connections:
 *
 *   every poll it reads duckdb_connection_count() (present on 1.4, 1.5 and 2.0) and subtracts the pool's own
 *   connections. Zero for a whole grace period means no client is left. Then:
 *
 *   release     (default)  two-phase: freeze the pool (new nested queries wait), wait for any in flight,
 *                          count again with a connection it holds, and only then commit: mark the pool
 *                          released and disconnect. The last disconnect lets the host's own teardown run
 *                          (checkpoint, close, unlock) on this thread. If a client turned up between the
 *                          two counts the pool thaws and nothing happened. Irreversible once committed,
 *                          like fractal_release(): later nested-query functions report it.
 *   checkpoint             CHECKPOINT once per idle spell and keep the pool: reversible, for hosts that
 *                          drop to zero connections and reconnect to the same database object.
 *   off                    no monitor: the pool stays until fractal_release() or process exit.
 *
 * What counts as a client: a connection in the count; a nested query in flight or run since the last poll; any
 * movement of the transaction counter beyond the monitor's own steps (a client that ran a statement touching a
 * table between two polls). A client that connects, does nothing the counter sees and leaves within one poll interval
 * is caught only by sampling, which is why polling speeds up while the grace period runs.
 * It fails safe: if the count or the counter cannot be read the monitor stops and never acts.
 *
 *   FRACTALSQL_HOST_CLOSE=release|checkpoint|off   FRACTALSQL_HOST_CLOSE_GRACE_MS (1000)
 *   FRACTALSQL_HOST_CLOSE_POLL_MS (50)             all read once, at LOAD. */
#define FSQL_MON_FAST_POLL_MS 2                          /* poll interval while a grace period is running */
enum { MON_NONE = 0, MON_RUNNING, MON_JOINING, MON_DETACHED };
enum { HOST_CLOSE_RELEASE = 0, HOST_CLOSE_CHECKPOINT, HOST_CLOSE_OFF };

static unsigned env_ms(const char *name, unsigned def, unsigned lo, unsigned hi) {
    const char *v = getenv(name);
    if (!v || !*v) return def;
    char *end = NULL;
    unsigned long n = strtoul(v, &end, 10);
    if (*end || n < lo) return def;
    return n > hi ? hi : (unsigned)n;
}

static void monitor_policy(fsql_instance *inst) {
    const char *v = getenv("FRACTALSQL_HOST_CLOSE");
    inst->mon_mode = HOST_CLOSE_RELEASE;
    if (v && *v) {
        if (!strcmp(v, "checkpoint")) inst->mon_mode = HOST_CLOSE_CHECKPOINT;
        else if (!strcmp(v, "off") || !strcmp(v, "0") || !strcmp(v, "false") || !strcmp(v, "no")) inst->mon_mode = HOST_CLOSE_OFF;
    }
    inst->mon_poll_ms  = env_ms("FRACTALSQL_HOST_CLOSE_POLL_MS", 50, 5, 5000);
    inst->mon_grace_ms = env_ms("FRACTALSQL_HOST_CLOSE_GRACE_MS", 1000, 0, 3600000);
    inst->mon_hold_ms  = env_ms("FRACTALSQL_HOST_CLOSE_TEST_FREEZE_MS", 0, 0, 60000);   /* tests only */
}

/* a pool connection for the monitor, without counting against the thread's nesting depth.
 * why: 0 got one, 1 all are in use (a client is running a nested query), 2 the pool is gone */
static int mon_take(fsql_instance *inst, int *why, uint64_t *seq) {
    fsql_mu_lock(&inst->pool_mu);
    if (inst->pool_state != FSQL_POOL_ON) { fsql_mu_unlock(&inst->pool_mu); *why = 2; return -1; }
    *seq = inst->acquire_seq;
    for (int i = 0; i < inst->pool_n; i++)
        if (!inst->busy[i]) { inst->busy[i] = true; fsql_mu_unlock(&inst->pool_mu); *why = 0; return i; }
    fsql_mu_unlock(&inst->pool_mu);
    *why = 1;
    return -1;
}
static void mon_put(fsql_instance *inst, int idx) {
    fsql_mu_lock(&inst->pool_mu);
    inst->busy[idx] = false;
    fsql_cv_broadcast(&inst->pool_cv);
    fsql_mu_unlock(&inst->pool_mu);
}

/* What one poll learns, in a single statement (so a single transaction): how many connections there are besides the
 * pool's, and the transaction counter. The count alone is a snapshot: a client that connects, runs something and
 * disconnects between two polls is never seen, so a host that is busy but quiet at every sampling instant would look
 * absent for the whole grace period. The transaction counter closes that gap: every statement any connection runs
 * advances it, so a jump larger than our own steps proves somebody did something since the last poll. Both are
 * present on DuckDB 1.4, 1.5 and 2.0. False when either cannot be read (the monitor then never acts). */
static bool mon_probe(fsql_instance *inst, int idx, long long *host, long long *txid) {
    duckdb_result r;
    memset(&r, 0, sizeof r);    /* duckdb_query may fail (an allocation failure) without writing r; destroy must then see an empty result */
    if (duckdb_query(inst->pool[idx], "SELECT (SELECT count FROM duckdb_connection_count())::BIGINT, txid_current()::BIGINT", &r) != DuckDBSuccess) {
        duckdb_destroy_result(&r);
        return false;
    }
    bool ok = false;
    duckdb_data_chunk ch = duckdb_fetch_chunk(r);
    if (ch) {
        if (duckdb_data_chunk_get_size(ch) > 0) {
            const int64_t *c0 = (const int64_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(ch, 0));
            const int64_t *c1 = (const int64_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(ch, 1));
            if (c0 && c1 && c0[0] >= 0) {
                long long n = (long long)c0[0] - inst->pool_cap;
                *host = n < 0 ? 0 : n;
                *txid = (long long)c1[0];
                ok = true;
            }
        }
        duckdb_destroy_data_chunk(&ch);
    }
    duckdb_destroy_result(&r);
    return ok;
}

/* Activity between polls. `step` is how far the transaction counter moves for one statement of ours (2 on DuckDB
 * 1.4/1.5, 1 on 2.0: not assumed, learned as the smallest gap ever seen between two of our own consecutive queries). */
typedef struct { long long last_txid, step; uint64_t last_seq; } mon_track;

static bool mon_changed(mon_track *t, long long txid, uint64_t seq) {
    bool act = false;
    if (t->last_txid >= 0) {
        long long d = txid - t->last_txid;
        if (d > 0 && d < t->step) t->step = d;
        if (d > t->step) act = true;                    /* someone else ran a statement in between */
    }
    if (seq != t->last_seq) act = true;                 /* a nested query ran (it implies a client) */
    t->last_txid = txid; t->last_seq = seq;
    return act;
}

/* Learns the step from a few back-to-back probes. False when the probe cannot run. */
static bool mon_calibrate(fsql_instance *inst, int idx, mon_track *t, uint64_t seq) {
    long long host, txid;
    for (int i = 0; i < 4; i++) {
        if (!mon_probe(inst, idx, &host, &txid)) return false;
        (void)mon_changed(t, txid, seq);
    }
    return t->step != LLONG_MAX && t->step > 0;
}

/* Two-phase release; `held` is the monitor's own connection. True when the pool was released (and every
 * connection, `held` included, disconnected). */
static bool mon_depart(fsql_instance *inst, int held, mon_track *trk) {
    fsql_mu_lock(&inst->pool_mu);
    if (inst->pool_state != FSQL_POOL_ON) { fsql_mu_unlock(&inst->pool_mu); return false; }
    inst->pool_state = FSQL_POOL_FROZEN;                /* phase 1: no new nested query starts */
    bool quiet = false;
    long long give_up = fsql_monotonic_ms() + 2000;
    for (;;) {
        bool others = false;
        for (int i = 0; i < inst->pool_cap; i++) if (i != held && inst->busy[i]) others = true;
        if (!others) { quiet = true; break; }
        if (fsql_monotonic_ms() >= give_up) break;
        fsql_cv_wait_ms(&inst->pool_cv, &inst->pool_mu, 50);
    }
    fsql_mu_unlock(&inst->pool_mu);
    if (inst->mon_hold_ms) {                            /* test knob: give a client time to arrive while frozen */
        const char *marker = getenv("FRACTALSQL_HOST_CLOSE_TEST_FROZEN_FILE");   /* tests only: "the freeze has begun" */
        if (marker && *marker) { FILE *mf = fopen(marker, "w"); if (mf) fclose(mf); }
        fsql_mu_lock(&inst->mon_mu);
        if (!inst->mon_stop) fsql_cv_wait_ms(&inst->mon_cv, &inst->mon_mu, inst->mon_hold_ms);
        fsql_mu_unlock(&inst->mon_mu);
    }
    /* phase 2: look again, frozen. Besides the count, any statement or nested query since the last poll thaws. */
    long long host = 1, txid = 0;
    if (quiet) {
        uint64_t seq;
        fsql_mu_lock(&inst->pool_mu); seq = inst->acquire_seq; fsql_mu_unlock(&inst->pool_mu);
        if (mon_probe(inst, held, &host, &txid) && mon_changed(trk, txid, seq)) host = 1;
    }
    fsql_mu_lock(&inst->pool_mu);
    if (host == 0) {
        inst->pool_n = 0;
        inst->pool_state = FSQL_POOL_RELEASED;
        fsql_cv_broadcast(&inst->pool_cv);
        fsql_mu_unlock(&inst->pool_mu);
        for (int i = 0; i < inst->pool_cap; i++) duckdb_disconnect(&inst->pool[i]);
        inst->pool_cap = 0;
        return true;
    }
    inst->pool_state = FSQL_POOL_ON;                    /* a client appeared: thaw, nothing happened */
    fsql_cv_broadcast(&inst->pool_cv);
    fsql_mu_unlock(&inst->pool_mu);
    return false;
}

static void *monitor_main(void *arg) {
    fsql_instance *inst = (fsql_instance *)arg;
    long long quiet_since = -1;
    bool checkpointed = false;
    mon_track trk = { -1, LLONG_MAX, 0 };
    for (;;) {
        fsql_mu_lock(&inst->mon_mu);
        /* While the pool looks idle (a grace period is running) look much more often: a connection that lives for a
         * millisecond and comes back every few is only seen if a sample lands inside it, and the connection count is
         * the one signal that shows a client that did nothing else. The cost is one tiny query every 2 ms, and only
         * for as long as the grace period lasts. */
        unsigned wait_ms = (quiet_since >= 0 && inst->mon_poll_ms > FSQL_MON_FAST_POLL_MS) ? FSQL_MON_FAST_POLL_MS : inst->mon_poll_ms;
        if (!inst->mon_stop) fsql_cv_wait_ms(&inst->mon_cv, &inst->mon_mu, wait_ms);
        bool stop = inst->mon_stop;
        fsql_mu_unlock(&inst->mon_mu);
        if (stop) break;

        int why;
        uint64_t seq = 0;
        int idx = mon_take(inst, &why, &seq);
        if (idx < 0) {
            if (why == 2) break;                        /* released (or being released) elsewhere */
            quiet_since = -1;                           /* a nested query is running: a client is there */
            continue;
        }
        if (trk.step == LLONG_MAX && !mon_calibrate(inst, idx, &trk, seq)) { mon_put(inst, idx); break; }   /* cannot tell: never act */
        long long host, txid;
        if (!mon_probe(inst, idx, &host, &txid)) { mon_put(inst, idx); break; }                              /* cannot tell: never act */
        bool active = mon_changed(&trk, txid, seq);
        if (host > 0 || active) { quiet_since = -1; checkpointed = false; mon_put(inst, idx); continue; }
        long long now = fsql_monotonic_ms();
        if (quiet_since < 0) quiet_since = now;
        if (now - quiet_since < (long long)inst->mon_grace_ms) { mon_put(inst, idx); continue; }
        if (inst->mon_mode == HOST_CLOSE_RELEASE) {
            if (mon_depart(inst, idx, &trk)) break;     /* pool gone, `idx` included: do not touch it */
            quiet_since = -1;
            mon_put(inst, idx);
            continue;
        }
        if (!checkpointed) {                            /* HOST_CLOSE_CHECKPOINT: once per idle spell */
            duckdb_result r;
            memset(&r, 0, sizeof r);
            duckdb_query(inst->pool[idx], "CHECKPOINT", &r);
            duckdb_destroy_result(&r);
            checkpointed = true;
            trk.last_txid = -1;                         /* our own statement moved the counter: not client activity */
        }
        mon_put(inst, idx);
    }
    fsql_mu_lock(&inst->mon_mu);
    if (inst->mon_state == MON_RUNNING) {               /* nobody will join us */
        inst->mon_state = MON_DETACHED;
        fsql_mu_unlock(&inst->mon_mu);
        fsql_thread_detach_self(inst->mon_thread);
        inst_unref(inst);                               /* may free the instance: the last use of it */
    } else {
        fsql_mu_unlock(&inst->mon_mu);                  /* MON_JOINING: the joiner reads the instance afterwards and drops our claim */
    }
    return NULL;
}

static void monitor_start(fsql_instance *inst) {
    if (inst->mon_mode == HOST_CLOSE_OFF) return;
    inst_ref(inst);                                     /* the monitor's claim, dropped as its last act */
    fsql_mu_lock(&inst->mon_mu);                        /* the thread's first act is to take this lock */
    if (fsql_thread_start(&inst->mon_thread, monitor_main, inst) == 0) inst->mon_state = MON_RUNNING;
    else { fsql_mu_unlock(&inst->mon_mu); inst_unref(inst); return; }
    fsql_mu_unlock(&inst->mon_mu);
}

static void monitor_stop(fsql_instance *inst) {
    fsql_mu_lock(&inst->mon_mu);
    if (inst->mon_state != MON_RUNNING) { fsql_mu_unlock(&inst->mon_mu); return; }
    inst->mon_state = MON_JOINING;
    inst->mon_stop = true;
    fsql_cv_broadcast(&inst->mon_cv);
    fsql_thread_t t = inst->mon_thread;
    fsql_mu_unlock(&inst->mon_mu);
    fsql_thread_join(t);
    fsql_mu_lock(&inst->mon_mu);
    inst->mon_state = MON_NONE;
    fsql_mu_unlock(&inst->mon_mu);
    inst_unref(inst);                                   /* the monitor's claim (the caller holds its own) */
}

int fsql_nested_query(fsql_instance *inst, const char *sql, fsql_qres *out, char *err, size_t err_cap) {
    out->have = false;
    int idx = pool_acquire(inst, err, err_cap);
    if (idx < 0) return -1;
    memset(&out->res, 0, sizeof out->res);   /* see mon_probe: a failed duckdb_query may leave the result unwritten */
    duckdb_state st = duckdb_query(inst->pool[idx], sql, &out->res);
    out->have = true;
    pool_release(inst, idx);
    if (st == DuckDBError) {
        const char *e = duckdb_result_error(&out->res);
        if (!e) e = "(no detail)";
        /* the underlying message can be one of this extension's own functions failing inside the query
         * (the executor propagates their text), which already carries the prefix: do not double it */
        if (strncmp(e, "fractalsql: ", 12) == 0) snprintf(err, err_cap, "%s", e);
        else snprintf(err, err_cap, "fractalsql: internal query failed: %s\nSQL: %s", e, sql);
        fsql_qres_free(out);
        return -1;
    }
    return 0;
}

void fsql_qres_free(fsql_qres *q) {
    if (q->have) { duckdb_destroy_result(&q->res); q->have = false; }
}
idx_t fsql_qres_columns(const fsql_qres *q) { return q->have ? duckdb_column_count((duckdb_result *)&q->res) : 0; }
idx_t fsql_qres_rows(const fsql_qres *q)    { return q->have ? duckdb_row_count((duckdb_result *)&q->res) : 0; }
duckdb_data_chunk fsql_qres_next_chunk(fsql_qres *q) { return q->have ? duckdb_fetch_chunk(q->res) : NULL; }

/* ------------------------------------------------------------ rowsets */

typedef struct {
    union { char *s; double d; int64_t i; bool b; struct { void *p; size_t n; } l; } v;
    bool set;
} rs_cell;

struct fsql_rowset {
    int ncols;
    char **names;
    fsql_rs_ty *types;
    rs_cell *cells;
    size_t nrows, cap;
};

fsql_rowset *fsql_rowset_new(int ncols, const char *const *names, const fsql_rs_ty *types) {
    fsql_rowset *rs = (fsql_rowset *)calloc(1, sizeof *rs);
    if (!rs) return NULL;
    rs->ncols = ncols;
    rs->names = (char **)calloc((size_t)ncols, sizeof(char *));
    rs->types = (fsql_rs_ty *)calloc((size_t)ncols, sizeof(fsql_rs_ty));
    if (!rs->names || !rs->types) { fsql_rowset_free(rs); return NULL; }
    for (int i = 0; i < ncols; i++) {
        rs->types[i] = types[i];
        rs->names[i] = strdup(names[i]);
        if (!rs->names[i]) { fsql_rowset_free(rs); return NULL; }
    }
    return rs;
}

void fsql_rowset_free(fsql_rowset *rs) {
    if (!rs) return;
    for (size_t r = 0; r < rs->nrows; r++)
        for (int c = 0; c < rs->ncols; c++) {
            rs_cell *x = &rs->cells[r * (size_t)rs->ncols + (size_t)c];
            if (!x->set) continue;
            if (rs->types[c] == FSQL_RS_VARCHAR) free(x->v.s);
            else if (rs->types[c] == FSQL_RS_LIST_DOUBLE || rs->types[c] == FSQL_RS_LIST_BIGINT) free(x->v.l.p);
        }
    free(rs->cells);
    if (rs->names) for (int i = 0; i < rs->ncols; i++) free(rs->names[i]);
    free(rs->names); free(rs->types); free(rs);
}

bool fsql_rs_row(fsql_rowset *rs) {
    if (rs->nrows == rs->cap) {
        size_t nc = rs->cap ? rs->cap * 2 : 16;
        rs_cell *p = (rs_cell *)realloc(rs->cells, nc * (size_t)rs->ncols * sizeof *p);
        if (!p) return false;
        rs->cells = p; rs->cap = nc;
    }
    memset(&rs->cells[rs->nrows * (size_t)rs->ncols], 0, (size_t)rs->ncols * sizeof(rs_cell));
    rs->nrows++;
    return true;
}
static rs_cell *rs_last(fsql_rowset *rs, int col) { return &rs->cells[(rs->nrows - 1) * (size_t)rs->ncols + (size_t)col]; }

bool fsql_rs_str(fsql_rowset *rs, int col, const char *s, size_t n) {
    char *d = (char *)malloc(n + 1);
    if (!d) return false;
    memcpy(d, s, n); d[n] = 0;
    rs_cell *x = rs_last(rs, col);
    x->v.s = d; x->set = true;
    return true;
}
bool fsql_rs_f64(fsql_rowset *rs, int col, double v)  { rs_cell *x = rs_last(rs, col); x->v.d = v; x->set = true; return true; }
bool fsql_rs_i64(fsql_rowset *rs, int col, int64_t v) { rs_cell *x = rs_last(rs, col); x->v.i = v; x->set = true; return true; }
bool fsql_rs_bool(fsql_rowset *rs, int col, bool v)   { rs_cell *x = rs_last(rs, col); x->v.b = v; x->set = true; return true; }
static bool rs_list(fsql_rowset *rs, int col, const void *v, size_t n, size_t esz) {
    size_t bytes = n * esz;
    void *d = malloc(bytes ? bytes : 1);
    if (!d) return false;
    if (bytes) memcpy(d, v, bytes);
    rs_cell *x = rs_last(rs, col);
    x->v.l.p = d; x->v.l.n = n; x->set = true;
    return true;
}
bool fsql_rs_list_f64(fsql_rowset *rs, int col, const double *v, size_t n)  { return rs_list(rs, col, v, n, sizeof(double)); }
bool fsql_rs_list_i64(fsql_rowset *rs, int col, const int64_t *v, size_t n) { return rs_list(rs, col, v, n, sizeof(int64_t)); }

/* DuckDB's bind-data destructor is void (*)(void *); fsql_rowset_free takes
 * an fsql_rowset *. Casting one signature to the other is a function-pointer
 * type mismatch -- undefined behaviour, which the undefined-behavior
 * sanitizer names outright ("call to function fsql_rowset_free through
 * pointer to incorrect function type"). A thunk with the right signature
 * costs nothing and is not UB. */
static void rowset_bind_data_free(void *p) { fsql_rowset_free((fsql_rowset *)p); }

void fsql_rowset_bind(duckdb_bind_info info, fsql_rowset *rs) {
    for (int c = 0; c < rs->ncols; c++) {
        duckdb_logical_type t = NULL, inner = NULL;
        switch (rs->types[c]) {
        case FSQL_RS_VARCHAR: t = duckdb_create_logical_type(DUCKDB_TYPE_VARCHAR); break;
        case FSQL_RS_DOUBLE:  t = duckdb_create_logical_type(DUCKDB_TYPE_DOUBLE); break;
        case FSQL_RS_BIGINT:  t = duckdb_create_logical_type(DUCKDB_TYPE_BIGINT); break;
        case FSQL_RS_INTEGER: t = duckdb_create_logical_type(DUCKDB_TYPE_INTEGER); break;
        case FSQL_RS_BOOLEAN: t = duckdb_create_logical_type(DUCKDB_TYPE_BOOLEAN); break;
        case FSQL_RS_LIST_DOUBLE: inner = duckdb_create_logical_type(DUCKDB_TYPE_DOUBLE); t = duckdb_create_list_type(inner); break;
        case FSQL_RS_LIST_BIGINT: inner = duckdb_create_logical_type(DUCKDB_TYPE_BIGINT); t = duckdb_create_list_type(inner); break;
        }
        duckdb_bind_add_result_column(info, rs->names[c], t);
        duckdb_destroy_logical_type(&t);
        if (inner) duckdb_destroy_logical_type(&inner);
    }
    duckdb_bind_set_bind_data(info, rs, rowset_bind_data_free);
}

void fsql_rowset_init(duckdb_init_info info) {
    idx_t *off = (idx_t *)calloc(1, sizeof *off);
    if (!off) { duckdb_init_set_error(info, "fractalsql: out of memory"); return; }
    duckdb_init_set_init_data(info, off, free);
}

void fsql_rowset_scan(duckdb_function_info info, duckdb_data_chunk out) {
    fsql_rowset *rs = (fsql_rowset *)duckdb_function_get_bind_data(info);
    idx_t *off = (idx_t *)duckdb_function_get_init_data(info);
    idx_t cap = duckdb_vector_size(), k = 0;
    idx_t n = *off + cap < rs->nrows ? cap : (idx_t)(rs->nrows - *off);
    for (int c = 0; c < rs->ncols; c++) {
        duckdb_vector v = duckdb_data_chunk_get_vector(out, (idx_t)c);
        fsql_list_out w;
        bool is_list = rs->types[c] == FSQL_RS_LIST_DOUBLE || rs->types[c] == FSQL_RS_LIST_BIGINT;
        if (is_list) fsql_list_out_open(&w, v);
        for (k = 0; k < n; k++) {
            rs_cell *x = &rs->cells[(*off + k) * (size_t)rs->ncols + (size_t)c];
            if (!x->set) {
                if (is_list) fsql_list_out_put_null(&w, k); else fsql_set_null(v, k);
                continue;
            }
            switch (rs->types[c]) {
            case FSQL_RS_VARCHAR: duckdb_vector_assign_string_element_len(v, k, x->v.s, strlen(x->v.s)); break;
            case FSQL_RS_DOUBLE:  ((double *)duckdb_vector_get_data(v))[k] = x->v.d; break;
            case FSQL_RS_BIGINT:  ((int64_t *)duckdb_vector_get_data(v))[k] = x->v.i; break;
            case FSQL_RS_INTEGER: ((int32_t *)duckdb_vector_get_data(v))[k] = (int32_t)x->v.i; break;
            case FSQL_RS_BOOLEAN: ((bool *)duckdb_vector_get_data(v))[k] = x->v.b; break;
            case FSQL_RS_LIST_DOUBLE:
                if (!fsql_list_out_put_raw(&w, k, x->v.l.p, x->v.l.n, sizeof(double))) { duckdb_function_set_error(info, "fractalsql: out of memory"); n = k; }
                break;
            case FSQL_RS_LIST_BIGINT:
                if (!fsql_list_out_put_raw(&w, k, x->v.l.p, x->v.l.n, sizeof(int64_t))) { duckdb_function_set_error(info, "fractalsql: out of memory"); n = k; }
                break;
            }
        }
        if (is_list) fsql_list_out_close(&w);
    }
    *off += n;
    duckdb_data_chunk_set_size(out, n);
}

void *fsql_instance_singleton(fsql_instance *inst, int slot, size_t size, void (*init)(void *), void (*destroy)(void *)) {
    if (slot < 0 || slot >= FSQL_SINGLETON_SLOTS) return NULL;
    fsql_mu_lock(&inst->single_mu);
    if (!inst->single[slot]) {
        void *p = calloc(1, size);
        if (p && init) init(p);
        inst->single[slot] = p;
        inst->single_destroy[slot] = destroy;
    }
    void *r = inst->single[slot];
    fsql_mu_unlock(&inst->single_mu);
    return r;
}

int fsql_classify_sql(fsql_instance *inst, const char *sql, int *nstmts, int *type, char *err, size_t err_cap) {
    *nstmts = 0; *type = FSQL_STMT_UNKNOWN;
    int idx = pool_acquire(inst, err, err_cap);
    if (idx < 0) return -1;
    duckdb_connection con = inst->pool[idx];
    duckdb_extracted_statements ex = NULL;
    idx_t n = duckdb_extract_statements(con, sql, &ex);
    int rc = 0;
    if (n == 0) {
        const char *m = ex ? duckdb_extract_statements_error(ex) : NULL;
        if (!m || !*m) m = "empty statement";
        /* the engine prefixes its error class ("Parser Error: ", "Not implemented Error: "); the message
         * a caller wants to show is the text after it */
        const char *colon = strstr(m, " Error: ");
        if (colon && (size_t)(colon - m) < 32) m = colon + 8;
        snprintf(err, err_cap, "%s", m);
        rc = -1;
    } else {
        *nstmts = (int)n;
        if (n == 1) {
            duckdb_prepared_statement p = NULL;
            if (duckdb_prepare_extracted_statement(con, ex, 0, &p) == DuckDBSuccess) {
                switch (duckdb_prepared_statement_type(p)) {
                case DUCKDB_STATEMENT_TYPE_SELECT: *type = FSQL_STMT_SELECT; break;
                case DUCKDB_STATEMENT_TYPE_INSERT: *type = FSQL_STMT_INSERT; break;
                case DUCKDB_STATEMENT_TYPE_UPDATE: *type = FSQL_STMT_UPDATE; break;
                default: *type = FSQL_STMT_OTHER; break;
                }
            }
            if (p) duckdb_destroy_prepare(&p);
        }
    }
    if (ex) duckdb_destroy_extracted(&ex);
    pool_release(inst, idx);
    return rc;
}

/* --------------------------------------------- per-connection state registry */

static void conn_entry_drop(conn_entry *e) {
    if (e->destroy) e->destroy(e->state);
    free(e->state);
    free(e);
}

/* Evicts idle entries, and the least recently used one if the registry is full. Caller holds the lock. */
static void conn_reap_locked(fsql_instance *inst, time_t now) {
    conn_entry **pp = &inst->conn_head;
    while (*pp) {
        conn_entry *e = *pp;
        if (now - e->last_used > FSQL_CONN_IDLE_SECONDS) { *pp = e->next; inst->conn_count--; conn_entry_drop(e); }
        else pp = &e->next;
    }
    while (inst->conn_count >= FSQL_CONN_MAX_ENTRIES && inst->conn_head) {
        conn_entry **lru = &inst->conn_head;
        for (conn_entry **q = &inst->conn_head; *q; q = &(*q)->next) if ((*q)->last_used < (*lru)->last_used) lru = q;
        conn_entry *e = *lru; *lru = e->next; inst->conn_count--; conn_entry_drop(e);
    }
}

void *fsql_conn_state(fsql_instance *inst, idx_t conn_id, size_t size, fsql_conn_init_fn init, fsql_conn_destroy_fn destroy) {
    time_t now = time(NULL);
    fsql_mu_lock(&inst->conn_mu);
    for (conn_entry *e = inst->conn_head; e; e = e->next) {
        if (e->id == conn_id) { e->last_used = now; void *s = e->state; fsql_mu_unlock(&inst->conn_mu); return s; }
    }
    conn_reap_locked(inst, now);
    conn_entry *e = (conn_entry *)calloc(1, sizeof *e);
    void *s = size ? calloc(1, size) : NULL;
    if (!e || (size && !s)) { free(e); free(s); fsql_mu_unlock(&inst->conn_mu); return NULL; }
    e->id = conn_id; e->state = s; e->destroy = destroy; e->last_used = now;
    e->next = inst->conn_head; inst->conn_head = e; inst->conn_count++;
    if (init) init(s);
    fsql_mu_unlock(&inst->conn_mu);
    return s;
}

void fsql_bind_capture_conn(duckdb_bind_info info) {
    duckdb_client_context ctx = NULL;
    duckdb_scalar_function_get_client_context(info, &ctx);
    idx_t *id = (idx_t *)malloc(sizeof *id);
    if (!id) { duckdb_scalar_function_bind_set_error(info, "fractalsql: out of memory"); return; }
    *id = ctx ? duckdb_client_context_get_connection_id(ctx) : 0;
    if (ctx) duckdb_destroy_client_context(&ctx);
    duckdb_scalar_function_set_bind_data(info, id, free);
}

idx_t fsql_exec_conn_id(duckdb_function_info info) {
    idx_t *id = (idx_t *)duckdb_scalar_function_get_bind_data(info);
    return id ? *id : 0;
}


/* -------------------------------------------------------------- version */

bool fsql_parse_version(const char *s, int *major, int *minor, int *patch) {
    if (!s) return false;
    if (*s == 'v') s++;
    return sscanf(s, "%d.%d.%d", major, minor, patch) == 3;
}
