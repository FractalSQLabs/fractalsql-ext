/* src/fractalsql_ext.c
 *
 * fractalsql-ext (pure C): DuckDB loadable extension driving the FractalSQL
 * community-edition pure-C search core, built on DuckDB's stable C extension API.
 *
 * SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
 * SPDX-FileCopyrightText: 2014 Hamid Salimi (SFS algorithmic lineage)
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Entry point: `fractalsql_init_c_api` (what `LOAD 'fractalsql...duckdb_extension'`
 * resolves). It checks the DuckDB release is one this build supports (the
 * C_STRUCT ABI skips DuckDB's own exact-version check, so the guard is ours),
 * then registers every module.
 *
 * Registered here (smoke + search surface):
 *   fractal_edition() -> VARCHAR        "Community"
 *   fractal_version() -> VARCHAR        "2.0.1"
 *   fractal_search(query [, iterations [, population_size [, diffusion]]])
 *                                          -> DOUBLE[]  (the best point)
 *   fractal_search(vec, query)             -> DOUBLE    (cosine distance to it)
 *   fractal_search_explore(emb, query [, params]) -> DOUBLE[][] (aggregate, Scout)
 * Remaining modules register from their own TUs (see fsql_duckdb_internal.h
 * for the TU map).
 *
 * Two bands are built from this one source (see the Makefile):
 *   band S (stable, C_STRUCT)   -> DuckDB 1.5.6 and later
 *   band L (-DFSQL_BAND_L)      -> exactly one DuckDB 1.4.x (FSQL_BAND_L_VER)
 *
 * Per-row hot path
 *   fractal_search(vec, query) runs SFS ONCE per distinct query (memoized per
 *   executor thread) and reuses the refined best_point for every row of the
 *   scan; per-row cost is one cosine distance.
 *
 * Threading
 *   DuckDB runs a scalar function on several worker threads at once. Each
 *   thread owns its own core context (a thread-local), so the search surface
 *   takes no lock.
 *
 * Vendored pure-C core
 *   include/fractalsql.h + include/fractalsql_sql.h + the per-platform
 *   libfractalsql-community-sovereign-c.a are statically linked into the
 *   extension and stay private to it (one exported symbol).
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DUCKDB_EXTENSION_NAME fractalsql
#include "fsql_duckdb_internal.h"

#ifdef FSQL_BAND_L
#  include "fsql_band_l.h"   /* normally force-included; harmless twice */
#endif

static const char *const kEdition = FSQL_DUCKDB_EDITION_STR;
static const char *const kVersion = FSQL_DUCKDB_VERSION_STR;

static const int    kDefaultIterations = 30;
static const int    kDefaultPopSize    = 50;
static const int    kDefaultDiff       = 2;
static const double kDefaultWalk       = 0.5;

/* Supply-side DoS guard: the query length feeds fsql_search_ptr as `dim` and the
 * core allocates pop_size * dim * 8 bytes of particle storage. */
static const size_t kMaxQueryDim = 4096;

/* --------------------------------------------- per-thread core context
 * One fsql context per executor thread, created lazily, plus a one-entry cache
 * of (query -> best_point). DuckDB's worker threads are long-lived; the key's
 * destructor frees the state when a thread exits. (This replaces the C++
 * FunctionLocalState without needing a 1.5.6-only init callback.) */

typedef struct {
    fsql_ctx *ctx;
    double   *cq;   size_t cq_n;     /* cached query      */
    double   *cbp;  size_t cbp_n;    /* cached best point */
} tls_state;

static void tls_free(tls_state *t) {
    if (!t) return;
    if (t->ctx) fsql_free(t->ctx);
    free(t->cq);
    free(t->cbp);
    free(t);
}

#ifdef _WIN32
static DWORD     g_fls = FLS_OUT_OF_INDEXES;
static INIT_ONCE g_once = INIT_ONCE_STATIC_INIT;
static VOID NTAPI fls_cb(PVOID p) { tls_free((tls_state *)p); }
static BOOL CALLBACK key_init(PINIT_ONCE o, PVOID p, PVOID *c) { (void)o; (void)p; (void)c; g_fls = FlsAlloc(fls_cb); return TRUE; }
static tls_state *tls_get(void) {
    InitOnceExecuteOnce(&g_once, key_init, NULL, NULL);
    if (g_fls == FLS_OUT_OF_INDEXES) return NULL;
    tls_state *t = (tls_state *)FlsGetValue(g_fls);
    if (!t) { t = (tls_state *)calloc(1, sizeof *t); if (t) FlsSetValue(g_fls, t); }
    return t;
}
#else
static pthread_key_t  g_key;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static void key_destroy(void *p) { tls_free((tls_state *)p); }
static void key_init(void) { pthread_key_create(&g_key, key_destroy); }
static tls_state *tls_get(void) {
    pthread_once(&g_once, key_init);
    tls_state *t = (tls_state *)pthread_getspecific(g_key);
    if (!t) { t = (tls_state *)calloc(1, sizeof *t); if (t) pthread_setspecific(g_key, t); }
    return t;
}
#endif

static fsql_ctx *tls_ctx(tls_state *t) {
    if (!t->ctx) t->ctx = fsql_new_minimal();
    return t->ctx;
}

/* ------------------------------------------------------------ SFS call */

/* Tiny `best_point` extractor for fsql_search_ptr's result JSON: the shape is
 * stable, so a substring + strtod loop is enough. */
static int extract_best_point(const char *json, double *out, int cap) {
    const char *p = strstr(json, "\"best_point\"");
    if (!p) return -1;
    p = strchr(p, '[');
    if (!p) return -1;
    p++;
    int n = 0;
    while (*p && n < cap) {
        while (*p == ' ' || *p == ',' || *p == '\n' || *p == '\r' || *p == '\t') p++;
        if (*p == ']' || !*p) break;
        char *end = NULL;
        double d = strtod(p, &end);
        if (end == p) return -1;
        out[n++] = d;
        p = end;
    }
    return n;
}

/* Runs one SFS search; best[dim] receives the best point. 0 = ok, else -1 with
 * the message the C++ build would have thrown in errbuf. */
static int run_sfs(tls_state *t, const double *q, size_t dim, int iters, int pop, int diff,
                   double *best, char *errbuf, size_t errcap) {
    fsql_ctx *ctx = tls_ctx(t);
    if (!ctx) { snprintf(errbuf, errcap, "fractalsql: fsql_new_minimal failed (OOM?)"); return -1; }

    char params[128];
    snprintf(params, sizeof params,
             "{\"max_generation\":%d,\"population_size\":%d,"
             "\"maximum_diffusion\":%d,\"walk\":%g,\"bound_clipping\":true}",
             iters, pop, diff, kDefaultWalk);

    const char *result_json = NULL;
    size_t      result_len  = 0;
    int rc = fsql_search_ptr(ctx, q, /*n_rows*/ 1, dim, q, dim, /*k*/ 1,
                             params, strlen(params), &result_json, &result_len);
    if (rc != 0 || !result_json) {
        const char *err = fsql_last_error(ctx);
        snprintf(errbuf, errcap, "fractalsql: SFS call failed: %s", (err && *err) ? err : "(no detail)");
        return -1;
    }
    if (extract_best_point(result_json, best, (int)dim) != (int)dim) {
        snprintf(errbuf, errcap, "fractalsql: best_point parse mismatch");
        return -1;
    }
    return 0;
}

static double cosine_distance(const double *a, const double *b, size_t dim) {
    double dot = 0, na = 0, nb = 0;
    for (size_t i = 0; i < dim; i++) {
        dot += a[i] * b[i];
        na  += a[i] * a[i];
        nb  += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 1.0;
    return 1.0 - dot / (sqrt(na) * sqrt(nb));
}

/* ------------------------------------------------- scalar functions */

static void edition_exec(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    (void)info;
    idx_t n = duckdb_data_chunk_get_size(in);
    for (idx_t i = 0; i < n; i++) duckdb_vector_assign_string_element(out, i, kEdition);
}

static void version_exec(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    (void)info;
    idx_t n = duckdb_data_chunk_get_size(in);
    for (idx_t i = 0; i < n; i++) duckdb_vector_assign_string_element(out, i, kVersion);
}

/* fractal_search(vec DOUBLE[], query DOUBLE[]) -> DOUBLE
 * Cosine distance from each row's vector to the best point SFS finds for the
 * (constant) query. Only row 0 of the query column is read, as in the C++ build. */
static void search_dist_exec(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    double *res = (double *)duckdb_vector_get_data(out);
    fsql_list_f64 vcol, qcol;
    fsql_list_f64_open(&vcol, duckdb_data_chunk_get_vector(in, 0));
    fsql_list_f64_open(&qcol, duckdb_data_chunk_get_vector(in, 1));

    const double *q = NULL; size_t qn = 0; const char *err = NULL;
    int r = n ? fsql_list_f64_get(&qcol, 0, &q, &qn, &err) : 0;
    if (r < 0) { fsql_fn_error(info, "%s", err); return; }
    if (r == 0) {                               /* NULL query: the whole chunk is NULL */
        for (idx_t i = 0; i < n; i++) fsql_set_null(out, i);
        return;
    }
    if (qn == 0 || qn > kMaxQueryDim) {
        fsql_fn_error(info, "fractalsql: query dim %zu out of range [1, %zu]", qn, kMaxQueryDim);
        return;
    }

    tls_state *t = tls_get();
    if (!t) { fsql_fn_error(info, "fractalsql: out of memory"); return; }

    int hit = t->cq_n == qn && t->cbp_n > 0;
    for (size_t i = 0; hit && i < qn; i++) if (!(t->cq[i] == q[i])) hit = 0;
    if (!hit) {
        double *best = (double *)malloc(qn * sizeof(double));
        double *qcopy = (double *)malloc(qn * sizeof(double));
        char eb[512];
        if (!best || !qcopy) { free(best); free(qcopy); fsql_fn_error(info, "fractalsql: out of memory"); return; }
        if (run_sfs(t, q, qn, kDefaultIterations, kDefaultPopSize, kDefaultDiff, best, eb, sizeof eb) != 0) {
            free(best); free(qcopy); fsql_fn_error(info, "%s", eb); return;
        }
        memcpy(qcopy, q, qn * sizeof(double));
        free(t->cq); free(t->cbp);
        t->cq = qcopy; t->cq_n = qn; t->cbp = best; t->cbp_n = qn;
    }

    for (idx_t i = 0; i < n; i++) {
        const double *row; size_t rn;
        int g = fsql_list_f64_get(&vcol, i, &row, &rn, &err);
        if (g < 0) { fsql_fn_error(info, "%s", err); return; }
        if (g == 0 || rn != t->cbp_n) { fsql_set_null(out, i); continue; }
        res[i] = cosine_distance(row, t->cbp, rn);
    }
}

/* fractal_search(query DOUBLE[] [, iterations INT [, population_size INT [,
 * diffusion_factor INT]]]) -> DOUBLE[]   -- the best point itself. */
static int int_arg(duckdb_data_chunk in, idx_t nargs_have, idx_t col, idx_t row, int dflt) {
    if (col >= nargs_have) return dflt;
    duckdb_vector v = duckdb_data_chunk_get_vector(in, col);
    if (!fsql_valid(duckdb_vector_get_validity(v), row)) return dflt;
    return ((const int32_t *)duckdb_vector_get_data(v))[row];
}

static void search_best_exec(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    idx_t ncols = duckdb_data_chunk_get_column_count(in);
    fsql_list_f64 qcol;
    fsql_list_out w;
    fsql_list_f64_open(&qcol, duckdb_data_chunk_get_vector(in, 0));
    fsql_list_out_open(&w, out);

    tls_state *t = tls_get();
    if (!t) { fsql_fn_error(info, "fractalsql: out of memory"); return; }
    double *best = (double *)malloc(kMaxQueryDim * sizeof(double));
    if (!best) { fsql_fn_error(info, "fractalsql: out of memory"); return; }

    for (idx_t i = 0; i < n; i++) {
        const double *q; size_t qn; const char *err = NULL;
        int g = fsql_list_f64_get(&qcol, i, &q, &qn, &err);
        if (g < 0) { fsql_list_out_close(&w); free(best); fsql_fn_error(info, "%s", err); return; }
        if (g == 0 || qn == 0 || qn > kMaxQueryDim) {
            fsql_set_null(out, i);
            w.entries[i].offset = w.used; w.entries[i].length = 0;
            continue;
        }
        int iters = int_arg(in, ncols, 1, i, kDefaultIterations);
        int pop   = int_arg(in, ncols, 2, i, kDefaultPopSize);
        int diff  = int_arg(in, ncols, 3, i, kDefaultDiff);
        char eb[512];
        /* Each factor is in range on its own, but the cost is their product:
         * the same work bound the other engines apply. */
        if ((unsigned long long)iters * (unsigned long long)pop *
            (unsigned long long)diff * (unsigned long long)qn > FSQL_SEARCH_MAX_WORK) {
            fsql_list_out_close(&w); free(best);
            fsql_fn_error(info, "fractalsql: search too large (iterations x population_size x "
                                "diffusion_factor x dim exceeds %llu)", FSQL_SEARCH_MAX_WORK);
            return;
        }
        if (run_sfs(t, q, qn, iters, pop, diff, best, eb, sizeof eb) != 0) {
            fsql_list_out_close(&w); free(best); fsql_fn_error(info, "%s", eb); return;
        }
        if (!fsql_list_out_put(&w, i, best, qn)) {
            fsql_list_out_close(&w); free(best); fsql_fn_error(info, "fractalsql: out of memory"); return;
        }
    }
    fsql_list_out_close(&w);
    free(best);
}


/* ------------------------------------------------------------------- */
/* Scout Mode -- the fractal_search_explore() aggregate                        */
/* ------------------------------------------------------------------- */
/* Sniper (fractal_search, above) returns a per-row distance and collapses into a
 * single basin. Scout consumes the WHOLE column as the corpus, runs SFS with
 * walk=0 + return_population (the core then uses the min-distance-to-corpus
 * fitness, so the final population disperses across distinct basins) and returns
 * that population as LIST(LIST(DOUBLE)) -- one inner list per particle.
 *
 *   SELECT UNNEST(fractal_search_explore(embedding, [0.1,0.2,...]::DOUBLE[]))
 *   FROM documents;
 *
 * An aggregate is the idiomatic way to scan a column once. */

#define SCOUT_ITERATIONS 15
#define SCOUT_POP_SIZE   50
#define SCOUT_DIFF       2

typedef struct {
    double  *corpus;  size_t corpus_len, corpus_cap;   /* rows*dim doubles */
    double  *query;   size_t query_len;
    char    *opts;
    int32_t  dim;
    idx_t    n_rows;
} explore_state;

static idx_t explore_state_size(duckdb_function_info info) { (void)info; return (idx_t)sizeof(explore_state); }

static void explore_init(duckdb_function_info info, duckdb_aggregate_state state) {
    (void)info;
    explore_state *s = (explore_state *)state;
    memset(s, 0, sizeof *s);
    s->dim = -1;
}

static void explore_destroy(duckdb_aggregate_state *states, idx_t count) {
    for (idx_t i = 0; i < count; i++) {
        explore_state *s = (explore_state *)states[i];
        free(s->corpus); free(s->query); free(s->opts);
        memset(s, 0, sizeof *s);
        s->dim = -1;
    }
}

static bool corpus_append(explore_state *s, const double *v, size_t n) {
    if (n > SIZE_MAX / sizeof(double) || s->corpus_len > SIZE_MAX / sizeof(double) - n) return false;
    size_t need = s->corpus_len + n;
    if (need > s->corpus_cap) {
        size_t cap = s->corpus_cap ? s->corpus_cap : 1024;
        while (cap < need) {
            if (cap > SIZE_MAX / 2 / sizeof(double)) return false;
            cap *= 2;
        }
        double *np = (double *)realloc(s->corpus, cap * sizeof(double));
        if (!np) return false;
        s->corpus = np;
        s->corpus_cap = cap;
    }
    memcpy(s->corpus + s->corpus_len, v, n * sizeof(double));
    s->corpus_len = need;
    return true;
}

static void explore_update(duckdb_function_info info, duckdb_data_chunk in, duckdb_aggregate_state *states) {
    idx_t n = duckdb_data_chunk_get_size(in);
    idx_t ncols = duckdb_data_chunk_get_column_count(in);
    fsql_list emb, qry;
    fsql_list_open(&emb, duckdb_data_chunk_get_vector(in, 0));
    fsql_list_open(&qry, duckdb_data_chunk_get_vector(in, 1));
    duckdb_vector ovec = ncols >= 3 ? duckdb_data_chunk_get_vector(in, 2) : NULL;
    const duckdb_string_t *odata = ovec ? (const duckdb_string_t *)duckdb_vector_get_data(ovec) : NULL;
    const uint64_t *ovalid = ovec ? duckdb_vector_get_validity(ovec) : NULL;

    for (idx_t i = 0; i < n; i++) {
        explore_state *st = (explore_state *)states[i];
        const double *row; size_t rn; const char *err = NULL;
        int g = fsql_list_f64_get(&emb, i, &row, &rn, &err);
        if (g < 0) { duckdb_aggregate_function_set_error(info, err); return; }
        if (g == 0 || rn == 0) continue;
        if (rn > FSQL_ARENA_MAX_DIM) { duckdb_aggregate_function_set_error(info, "fractalsql: embedding dim out of range"); return; }
        if (st->dim < 0) st->dim = (int32_t)rn;
        if ((size_t)st->dim != rn) { duckdb_aggregate_function_set_error(info, "fractalsql: inconsistent embedding dim in column"); return; }
        if (st->n_rows >= FSQL_SCOUT_MAX_CORPUS_ROWS) { duckdb_aggregate_function_set_error(info, "fractalsql: scout corpus exceeds row cap"); return; }
        if (!corpus_append(st, row, rn)) { duckdb_aggregate_function_set_error(info, "fractalsql: out of memory"); return; }
        st->n_rows++;

        if (!st->query) {
            const double *q; size_t qn;
            if (fsql_list_f64_get(&qry, i, &q, &qn, &err) == 1 && qn > 0) {
                st->query = (double *)malloc(qn * sizeof(double));
                if (!st->query) { duckdb_aggregate_function_set_error(info, "fractalsql: out of memory"); return; }
                memcpy(st->query, q, qn * sizeof(double));
                st->query_len = qn;
            }
        }
        if (odata && !st->opts && fsql_valid(ovalid, i)) {
            size_t on;
            const char *op = fsql_str_data(&odata[i], &on);
            st->opts = fsql_xstrndup(op, on);
            if (!st->opts) { duckdb_aggregate_function_set_error(info, "fractalsql: out of memory"); return; }
        }
    }
}

static void explore_combine(duckdb_function_info info, duckdb_aggregate_state *source, duckdb_aggregate_state *target, idx_t count) {
    for (idx_t i = 0; i < count; i++) {
        explore_state *src = (explore_state *)source[i], *tgt = (explore_state *)target[i];
        if (!src->corpus || src->n_rows == 0) continue;
        if (tgt->dim < 0) tgt->dim = src->dim;
        if (!corpus_append(tgt, src->corpus, src->corpus_len)) { duckdb_aggregate_function_set_error(info, "fractalsql: out of memory"); return; }
        tgt->n_rows += src->n_rows;
        if (!tgt->query && src->query) {
            tgt->query = (double *)malloc(src->query_len * sizeof(double));
            if (!tgt->query) { duckdb_aggregate_function_set_error(info, "fractalsql: out of memory"); return; }
            memcpy(tgt->query, src->query, src->query_len * sizeof(double));
            tgt->query_len = src->query_len;
        }
        if (!tgt->opts && src->opts) {
            tgt->opts = fsql_xstrdup(src->opts);
            if (!tgt->opts) { duckdb_aggregate_function_set_error(info, "fractalsql: out of memory"); return; }
        }
    }
}

/* Extract a positive integer value for `key` from a small JSON options string. */
static int json_get_int(const char *opts, const char *key, int dflt) {
    if (!opts || !*opts) return dflt;
    char needle[64];
    snprintf(needle, sizeof needle, "\"%s\"", key);
    const char *pos = strstr(opts, needle);
    if (!pos) return dflt;
    pos = strchr(pos + strlen(needle), ':');
    if (!pos) return dflt;
    long v = strtol(pos + 1, NULL, 10);
    return v > 0 ? (int)v : dflt;
}

/* Parse the additive "population":[[...],[...]] array from the scout result JSON
 * into a flat double array + per-particle lengths. Returns the particle count, or
 * -1 on a shape error. Caller frees *flat and *lens. */
static long extract_population(const char *json, double **flat, size_t **lens) {
    const char *p = strstr(json, "\"population\"");
    if (!p) return -1;
    p = strchr(p, '[');
    if (!p) return -1;
    p++;
    fsql_vecd vals; fsql_vecd_init(&vals);
    size_t *ls = NULL; size_t nl = 0, lcap = 0;
    while (*p) {
        while (*p == ' ' || *p == ',' || *p == '\n' || *p == '\r' || *p == '\t') p++;
        if (*p == ']' || !*p) break;                 /* end of outer array */
        if (*p != '[') goto bad;                     /* expected an inner array */
        p++;
        size_t before = vals.len;
        while (*p) {
            while (*p == ' ' || *p == ',' || *p == '\n' || *p == '\r' || *p == '\t') p++;
            if (*p == ']') { p++; break; }           /* end of inner array */
            char *end = NULL;
            double d = strtod(p, &end);
            if (end == p) goto bad;
            fsql_vecd_push(&vals, d);
            p = end;
        }
        if (nl == lcap) {
            size_t nc = lcap ? lcap * 2 : 64;
            size_t *nlp = (size_t *)realloc(ls, nc * sizeof(size_t));
            if (!nlp) goto bad;
            ls = nlp; lcap = nc;
        }
        ls[nl++] = vals.len - before;
    }
    if (!fsql_vecd_ok(&vals)) goto bad;
    *flat = vals.p;           /* ownership moves to the caller (may be NULL if empty) */
    *lens = ls;
    return (long)nl;
bad:
    fsql_vecd_free(&vals);
    free(ls);
    return -1;
}

/* Run Scout SFS over the whole corpus. 0 = ok (flat/lens/np set), else -1 + message. */
static int run_sfs_scout(tls_state *t, const explore_state *st, int pop_size, int iters, int diff,
                         double **flat, size_t **lens, long *np, char *eb, size_t ecap) {
    fsql_ctx *ctx = tls_ctx(t);
    if (!ctx) { snprintf(eb, ecap, "fractalsql: fsql_new_minimal failed (OOM?)"); return -1; }
    char params[224];
    snprintf(params, sizeof params,
             "{\"max_generation\":%d,\"population_size\":%d,"
             "\"maximum_diffusion\":%d,\"walk\":0,"
             "\"return_population\":true,\"bound_clipping\":true}",
             iters, pop_size, diff);
    /* The query is read as `dim` doubles: a query vector shorter than the corpus vectors would be over-read. */
    if (st->query_len != (size_t)st->dim) {
        snprintf(eb, ecap, "fractalsql: query dimension %zu does not match the corpus dimension %d",
                 st->query_len, (int)st->dim);
        return -1;
    }
    const char *result_json = NULL;
    size_t result_len = 0;
    int rc = fsql_search_ptr(ctx, st->corpus, (size_t)st->n_rows, (size_t)st->dim,
                             st->query, (size_t)st->dim, /*k*/ 1,
                             params, strlen(params), &result_json, &result_len);
    if (rc != 0 || !result_json) {
        const char *err = fsql_last_error(ctx);
        snprintf(eb, ecap, "fractalsql: scout SFS call failed: %s", (err && *err) ? err : "(no detail)");
        return -1;
    }
    *np = extract_population(result_json, flat, lens);
    if (*np < 0) {
        snprintf(eb, ecap, "fractalsql: scout population parse failed (build predates Scout Mode return_population path?)");
        return -1;
    }
    return 0;
}

static void explore_finalize(duckdb_function_info info, duckdb_aggregate_state *source, duckdb_vector result,
                             idx_t count, idx_t offset) {
    (void)info;
    fsql_list2_out w;
    fsql_list2_out_open(&w, result);
    tls_state *t = tls_get();
    for (idx_t i = 0; i < count; i++) {
        explore_state *st = (explore_state *)source[i];
        idx_t ridx = i + offset;
        if (!t || !st->corpus || st->n_rows == 0 || !st->query || st->dim <= 0) {
            fsql_set_null(result, ridx);
            continue;
        }
        int pop_size = json_get_int(st->opts, "population_size", SCOUT_POP_SIZE);
        int iters    = json_get_int(st->opts, "iterations", SCOUT_ITERATIONS);
        int diff     = json_get_int(st->opts, "diffusion_factor", SCOUT_DIFF);
        double *flat = NULL; size_t *lens = NULL; long np = 0; char eb[512];
        /* A failure degrades to a NULL row with the reason on stderr, never an abort
         * of the whole statement (as in the C++ build). */
        if (run_sfs_scout(t, st, pop_size, iters, diff, &flat, &lens, &np, eb, sizeof eb) != 0) {
            fprintf(stderr, "fractalsql: fractal_search_explore finalize error: %s\n", eb);
            fsql_set_null(result, ridx);
            continue;
        }
        if (!fsql_list2_out_put(&w, ridx, flat, lens, (size_t)np)) {
            fprintf(stderr, "fractalsql: fractal_search_explore finalize error: out of memory\n");
            fsql_set_null(result, ridx);
        }
        free(flat); free(lens);
    }
    fsql_list2_out_close(&w);
}

/* ------------------------------------------------------------ register */

#define LD FSQL_T_LIST_DOUBLE
static const fsql_scalar_def kDefs[] = {
    { "fractal_search", 1, { LD },                                          LD,              search_best_exec, NULL, 0 },
    { "fractal_search", 2, { LD, LD },                                      FSQL_T_DOUBLE,   search_dist_exec, NULL, 0 },
    { "fractal_search", 2, { LD, FSQL_T_INTEGER },                          LD,              search_best_exec, NULL, 0 },
    { "fractal_search", 3, { LD, FSQL_T_INTEGER, FSQL_T_INTEGER },          LD,              search_best_exec, NULL, 0 },
    { "fractal_search", 4, { LD, FSQL_T_INTEGER, FSQL_T_INTEGER, FSQL_T_INTEGER }, LD,       search_best_exec, NULL, 0 },
    { "fractal_edition", 0, { 0 }, FSQL_T_VARCHAR, edition_exec, NULL, 0 },
    { "fractal_version", 0, { 0 }, FSQL_T_VARCHAR, version_exec, NULL, 0 },
};

#define LL FSQL_T_LIST_LIST_DOUBLE
static const fsql_aggregate_def kAggs[] = {
    { "fractal_search_explore", 2, { LD, LD },                 LL, explore_state_size, explore_init, explore_update, explore_combine, explore_finalize, explore_destroy },
    { "fractal_search_explore", 3, { LD, LD, FSQL_T_VARCHAR }, LL, explore_state_size, explore_init, explore_update, explore_combine, explore_finalize, explore_destroy },
};

bool fsql_search_register(duckdb_connection con, const char **err) {
    return fsql_register_scalars(con, kDefs, (int)(sizeof kDefs / sizeof kDefs[0]), err) &&
           fsql_register_aggregates(con, kAggs, (int)(sizeof kAggs / sizeof kAggs[0]), err);
}

/* ------------------------------------------------------------------- */
/* Entry point                                                          */
/* ------------------------------------------------------------------- */

static bool version_supported(const char *v, char *why, size_t cap) {
#ifdef FSQL_BAND_L
    if (v && strcmp(v, FSQL_BAND_L_VER) == 0) return true;
    snprintf(why, cap, "fractalsql: this build is for DuckDB %s only; this is DuckDB %s", FSQL_BAND_L_VER, v ? v : "?");
    return false;
#else
    int ma = 0, mi = 0, pa = 0;
    if (fsql_parse_version(v, &ma, &mi, &pa)) {
        if (ma > 1) return true;                       /* 2.x and later */
        if (ma == 1 && (mi > 5 || (mi == 5 && pa >= 6))) return true;
    }
    snprintf(why, cap, "fractalsql: this build supports DuckDB 1.5.6 and later (1.4.x has its own build); this is DuckDB %s", v ? v : "?");
    return false;
#endif
}

/* The stock DUCKDB_EXTENSION_ENTRYPOINT copies the whole API table into the global duckdb_ext_api on every
 * LOAD. A process can hold many databases, and the host-departure monitor of an earlier one reads that table
 * from its own thread, so the copy is done once, under a lock: the table is the same for every database of
 * a process (one libduckdb), and a later LOAD never writes it. The rest is the macro's expansion. */
DUCKDB_EXTENSION_GLOBAL                                         /* defines duckdb_ext_api */
static bool fractalsql_init_c_api_internal(duckdb_connection connection, duckdb_extension_info info,
                                           struct duckdb_extension_access *access);

DUCKDB_CAPI_ENTRY_VISIBILITY DUCKDB_EXTENSION_API bool fractalsql_init_c_api(duckdb_extension_info info,
                                                                              struct duckdb_extension_access *access) {
    static fsql_mu_t api_mu = FSQL_MU_INIT;
    static int api_ready;
    fsql_mu_lock(&api_mu);
    if (!api_ready) {
        duckdb_ext_api_v1 *res = (duckdb_ext_api_v1 *)access->get_api(info, DUCKDB_EXTENSION_API_VERSION_STRING);
        if (!res) { fsql_mu_unlock(&api_mu); return false; }
        duckdb_ext_api = *res;
        api_ready = 1;
    }
    fsql_mu_unlock(&api_mu);
    duckdb_database *db = access->get_database(info);
    duckdb_connection conn;
    if (duckdb_connect(*db, &conn) == DuckDBError) {
        access->set_error(info, "Failed to open connection to database");
        return false;
    }
    bool init_result = fractalsql_init_c_api_internal(conn, info, access);
    duckdb_disconnect(&conn);
    return init_result;
}

static bool fractalsql_init_c_api_internal(duckdb_connection connection, duckdb_extension_info info,
                                           struct duckdb_extension_access *access) {
    char why[256];
    if (!version_supported(duckdb_library_version(), why, sizeof why)) {
        access->set_error(info, why);
        return false;
    }
    const char *err = NULL;
    /* The database handle is only borrowed during LOAD: open the nested-query pool now. */
    fsql_instance *inst = fsql_instance_create(*access->get_database(info), &err);
    if (!inst) {
        access->set_error(info, err);
        return false;
    }
    /* Captured once, before any reasoning tier can load: the operator's chat-scope settings. */
    fsql_reasoning_capture_boot_env();
    /* Feature modules, in the same order as the SQLite tree's registration table. */
    if (!fsql_search_register(connection, &err) ||
        !fsql_vector_register(connection, &err) ||
        !fsql_sovereign_register(connection, &err) ||
        !fsql_config_register(connection, &err) ||
        !fsql_t2s_register(connection, &err) ||
        !fsql_ledger_register(connection, &err) ||
        !fsql_vectorizer_register(connection, &err) ||
        !fsql_domain_agents_register(connection, &err) ||
        !fsql_agents_register(connection, &err)) {
        access->set_error(info, err ? err : "fractalsql: registration failed");
        fsql_instance_registration_done(inst);
        return false;
    }
    fsql_instance_registration_done(inst);
    return true;
}
