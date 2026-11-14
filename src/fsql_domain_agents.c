/* src/fsql_domain_agents.c
 *
 * The domain agents: sixteen installable "agent engine" products (A-P), each a parameterised
 * composition of the base primitives over CALLER-SUPPLIED tables and columns.
 *
 *   A fractal_agent_anomaly_triage        B fractal_agent_allocate
 *   C fractal_agent_route_task            D fractal_agent_outlier_intercept
 *   E fractal_agent_recall_hybrid         F fractal_agent_recommend_diverse
 *   G fractal_agent_data_analyst          H fractal_agent_patient_deterioration_triage
 *   I fractal_agent_feedback_audit        J fractal_agent_schedule_workload
 *   K fractal_agent_rebalance_sibling     L fractal_agent_detour_classify
 *   M fractal_agent_track_anomaly         N fractal_agent_network_coverage_alert
 *   O fractal_agent_regime_triage         P fractal_agent_diverse_portfolios
 *
 * Every engine is a scalar function returning one VARCHAR holding a JSON document. Each supported
 * arity is a registered overload; all use SPECIAL null handling so NULL arguments reach the engine
 * body and raise the engine's own required-argument message. Vector inputs are DOUBLE[] lists.
 *
 * Composition: the searches (telemetry top-k, cohort-restricted hybrid, task refinement, trajectory
 * delta) run in-process on ONE engine sovereign context per database instance, serialised by a
 * mutex (an fsql_ctx is not thread-safe); the diversify state of engines F and I lives on that same
 * context. The analytics primitives are context-free core calls wrapped in the registered
 * functions' own validation, so a composed failure reads like the registered function's. The
 * portfolio engines compose the REGISTERED optimisers as SQL (nested queries), keeping their
 * validation and enterprise gating the single source. Provenance is a best-effort
 * fractal_audit_log re-entry whose failures are swallowed. The cognition step is a CHAT-tier
 * dispatch; an outage there keeps the engine's computed half (reasoning_step_failed), but a plugin
 * that was never configured is refused.
 *
 * Porting note: the engine bodies were exceptions in the C++ build. Here an engine runs under a
 * `da` frame: every allocation is registered with the frame, and DA_FAIL() longjmps back to the
 * entry wrapper, which frees everything and fails the call with the message. Nothing in a body
 * holds a resource that is not registered.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 */

#include <ctype.h>
#include <inttypes.h>
#include <math.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_duckdb_internal.h"
#include "fsql_port.h"

#define DA_ERRCAP 4096
#define DA_MAX_SERIES_LEN      (1u * 1000u * 1000u)
#define DA_MAX_POINTS_FLAT_LEN (2u * 1000u * 1000u)
#define DA_MAX_SPATIAL_DIM     64
#define DA_MAX_GEOM_DIM        3

/* ------------------------------------------------------------------ */
/* The engine frame                                                     */
/* ------------------------------------------------------------------ */

typedef struct da_item { void *p; void (*fn)(void *); struct da_item *next; } da_item;

typedef struct {
    fsql_mu_t  mu;
    fsql_ctx  *ctx;
} da_engine;

typedef struct {
    fsql_instance *inst;
    FsqlConn      *conn;       /* the calling connection's state (diversify flag) */
    da_engine     *eng;
    fsql_ctx      *ctx;        /* the engine context, created on first use */
    jmp_buf        jb;
    char           err[DA_ERRCAP];
    da_item       *items;
} da;

static void da_engine_init(void *p) { fsql_mu_init(&((da_engine *)p)->mu); }
static void da_engine_destroy(void *p) { da_engine *e = (da_engine *)p; if (e->ctx) { fsql_free(e->ctx); e->ctx = NULL; } }

static void *da_track(da *d, void *p, void (*fn)(void *)) {
    if (!p) { snprintf(d->err, sizeof d->err, "fractalsql: out of memory"); longjmp(d->jb, 1); }   /* the caller's allocation failed */
    da_item *it = (da_item *)malloc(sizeof *it);
    if (!it) { if (fn) fn(p); snprintf(d->err, sizeof d->err, "fractalsql: out of memory"); longjmp(d->jb, 1); }
    it->p = p; it->fn = fn; it->next = d->items; d->items = it;
    return p;
}
static void da_release(da *d) {
    while (d->items) {
        da_item *it = d->items;
        d->items = it->next;
        if (it->fn) it->fn(it->p);
        free(it);
    }
}

static void da_fail(da *d, const char *fmt, ...) FSQL_PRINTF(2, 3);
static void da_fail(da *d, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(d->err, sizeof d->err, fmt, ap);
    va_end(ap);
    longjmp(d->jb, 1);
}
#define DA_FAIL(d, ...) da_fail((d), __VA_ARGS__)

static char *da_dupn(da *d, const char *s, size_t n) {
    char *p = (char *)malloc(n + 1);
    if (!p) da_fail(d, "fractalsql: out of memory");
    memcpy(p, s, n); p[n] = 0;
    return (char *)da_track(d, p, free);
}
static char *da_dup(da *d, const char *s) { return da_dupn(d, s, strlen(s)); }

static void sb_destroy(void *p) { fsql_sb_free((fsql_sb *)p); free(p); }
static fsql_sb *da_sb(da *d) {
    fsql_sb *b = (fsql_sb *)malloc(sizeof *b);
    if (!b) da_fail(d, "fractalsql: out of memory");
    fsql_sb_init(b);
    return (fsql_sb *)da_track(d, b, sb_destroy);
}
/* Finishes a builder into a frame-owned string. */
static const char *da_sb_str(da *d, fsql_sb *b) {
    if (!fsql_sb_ok(b)) da_fail(d, "fractalsql: out of memory");
    return fsql_sb_cstr(b);
}

static void vec_destroy(void *p) { fsql_vecd_free((fsql_vecd *)p); free(p); }
static fsql_vecd *da_vecd(da *d) {
    fsql_vecd *v = (fsql_vecd *)malloc(sizeof *v);
    if (!v) da_fail(d, "fractalsql: out of memory");
    fsql_vecd_init(v);
    return (fsql_vecd *)da_track(d, v, vec_destroy);
}
static void da_vec_ok(da *d, fsql_vecd *v) { if (!fsql_vecd_ok(v)) da_fail(d, "fractalsql: out of memory"); }

/* An int64 growable vector (row locators). */
typedef struct { int64_t *p; size_t n, cap; } da_i64v;
static void i64v_destroy(void *p) { free(((da_i64v *)p)->p); free(p); }
static da_i64v *da_i64vec(da *d) {
    da_i64v *v = (da_i64v *)calloc(1, sizeof *v);
    if (!v) da_fail(d, "fractalsql: out of memory");
    return (da_i64v *)da_track(d, v, i64v_destroy);
}
static void i64v_push(da *d, da_i64v *v, int64_t x) {
    if (v->n == v->cap) {
        size_t nc = v->cap ? v->cap * 2 : 16;
        int64_t *np = (int64_t *)realloc(v->p, nc * sizeof(int64_t));
        if (!np) da_fail(d, "fractalsql: out of memory");
        v->p = np; v->cap = nc;
    }
    v->p[v->n++] = x;
}

static void qres_destroy(void *p) { fsql_qres_free((fsql_qres *)p); free(p); }

/* A frame-owned nested query. A failure fails the engine with the query's message. */
static fsql_qres *da_query(da *d, const char *sql) {
    fsql_qres *q = (fsql_qres *)calloc(1, sizeof *q);
    if (!q) da_fail(d, "fractalsql: out of memory");
    char err[DA_ERRCAP];
    if (fsql_nested_query(d->inst, sql, q, err, sizeof err)) { free(q); da_fail(d, "%s", err); }
    return (fsql_qres *)da_track(d, q, qres_destroy);
}

/* The same query, but a failure is returned to the caller (message in err). NULL on failure. */
static fsql_qres *da_try_query(da *d, const char *sql, char *err, size_t cap) {
    fsql_qres *q = (fsql_qres *)calloc(1, sizeof *q);
    if (!q) da_fail(d, "fractalsql: out of memory");
    if (fsql_nested_query(d->inst, sql, q, err, cap)) { free(q); return NULL; }
    return (fsql_qres *)da_track(d, q, qres_destroy);
}

/* Result accessors over a materialised nested result. */
static bool q_null(fsql_qres *q, idx_t c, idx_t r) { return duckdb_value_is_null(&q->res, c, r); }
static int64_t q_i64(fsql_qres *q, idx_t c, idx_t r) { return duckdb_value_int64(&q->res, c, r); }
static double q_f64(fsql_qres *q, idx_t c, idx_t r) { return duckdb_value_double(&q->res, c, r); }
static idx_t q_rows(fsql_qres *q) { return duckdb_row_count(&q->res); }
/* ToString of a cell; "" for NULL. */
static char *q_text(da *d, fsql_qres *q, idx_t c, idx_t r) {
    if (q_null(q, c, r)) return da_dup(d, "");
    char *s = duckdb_value_varchar(&q->res, c, r);
    char *copy = da_dup(d, s ? s : "");
    if (s) duckdb_free(s);
    return copy;
}

/* ------------------------------------------------------------------ */
/* Formatting helpers                                                   */
/* ------------------------------------------------------------------ */

static char *da_fmt(da *d, const char *fmt, ...) FSQL_PRINTF(2, 3);
static char *da_fmt(da *d, const char *fmt, ...) {
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n < 0) { va_end(ap2); da_fail(d, "fractalsql: formatting failed"); }
    char *p = (char *)malloc((size_t)n + 1);
    if (!p) { va_end(ap2); da_fail(d, "fractalsql: out of memory"); }
    vsnprintf(p, (size_t)n + 1, fmt, ap2);
    va_end(ap2);
    return (char *)da_track(d, p, free);
}

static char *da_f10(da *d, double v) { return da_fmt(d, "%.10f", v); }

static void put_number_json(fsql_sb *b, double v) {
    if (isnan(v)) fsql_sb_puts(b, "null"); else fsql_sb_printf(b, "%.17g", v);
}

/* A JSON string literal with the C++ build's escapes (\b and \f spelled out). */
static void put_json_string(fsql_sb *b, const char *s) {
    fsql_sb_putc(b, '"');
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"':  fsql_sb_puts(b, "\\\""); break;
        case '\\': fsql_sb_puts(b, "\\\\"); break;
        case '\b': fsql_sb_puts(b, "\\b"); break;
        case '\f': fsql_sb_puts(b, "\\f"); break;
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

static bool json_number_ok(const char *p) {
    if (!*p) return false;
    if (*p == '-') p++;
    if (!(*p >= '0' && *p <= '9')) return false;
    if (p[0] == '0' && p[1] >= '0' && p[1] <= '9') return false;
    while (*p >= '0' && *p <= '9') p++;
    if (*p == '.') {
        p++;
        if (!(*p >= '0' && *p <= '9')) return false;
        while (*p >= '0' && *p <= '9') p++;
    }
    if (*p == 'e' || *p == 'E') {
        p++;
        if (*p == '+' || *p == '-') p++;
        if (!(*p >= '0' && *p <= '9')) return false;
        while (*p >= '0' && *p <= '9') p++;
    }
    return *p == '\0';
}
/* A row id as JSON: bare when it is a valid JSON number, else a string. */
static void put_id_value_json(fsql_sb *b, const char *s) {
    if (*s && json_number_ok(s)) fsql_sb_puts(b, s); else put_json_string(b, s);
}
static void put_id_or_null_json(fsql_sb *b, const char *s) {
    if (!*s) fsql_sb_puts(b, "null"); else put_id_value_json(b, s);
}
/* Text that already looks like JSON is emitted raw; anything else as a string. */
static void put_raw_or_string(fsql_sb *b, const char *s) {
    const char *p = s;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p == '{' || *p == '[' || *p == '"' || (*p == 't' && !strncmp(p, "true", 4)) || (*p == 'f' && !strncmp(p, "false", 5)) ||
        (*p == 'n' && !strncmp(p, "null", 4)) || *p == '-' || (*p >= '0' && *p <= '9'))
        fsql_sb_puts(b, s);
    else
        put_json_string(b, s);
}
static void put_raw_or_null(fsql_sb *b, const char *s) { if (s) put_raw_or_string(b, s); else fsql_sb_puts(b, "null"); }
static void put_vec_json(fsql_sb *b, const double *v, size_t n) {
    fsql_sb_putc(b, '[');
    for (size_t i = 0; i < n; i++) { if (i) fsql_sb_putc(b, ','); put_number_json(b, v[i]); }
    fsql_sb_putc(b, ']');
}
static char *da_vec_literal(da *d, const double *v, size_t n) {
    fsql_sb *b = da_sb(d);
    fsql_sb_putc(b, '[');
    for (size_t i = 0; i < n; i++) { if (i) fsql_sb_putc(b, ','); fsql_sb_printf(b, "%.17g", v[i]); }
    fsql_sb_putc(b, ']');
    return da_dup(d, da_sb_str(d, b));
}

static void put_quoted(fsql_sb *b, const char *s, char q) {
    fsql_sb_putc(b, q);
    for (; *s; s++) { if (*s == q) fsql_sb_putc(b, q); fsql_sb_putc(b, *s); }
    fsql_sb_putc(b, q);
}
static void put_ident(fsql_sb *b, const char *s) { put_quoted(b, s, '"'); }
static void put_lit(fsql_sb *b, const char *s)   { put_quoted(b, s, '\''); }

/* ------------------------------------------------------------------ */
/* Table helpers                                                        */
/* ------------------------------------------------------------------ */

static int da_table_has_rows(da *d, const char *table) {
    fsql_sb *s = da_sb(d);
    fsql_sb_puts(s, "SELECT 1 FROM "); put_ident(s, table); fsql_sb_puts(s, " LIMIT 1");
    fsql_qres *q = da_query(d, da_sb_str(d, s));
    return q_rows(q) > 0 ? 1 : 0;
}

/* The id column's text for a row located by rowid / scan position. "" when not found. */
static char *da_resolve_rowid(da *d, const char *table, const char *id_col, int64_t rowid) {
    fsql_sb *s = da_sb(d);
    fsql_sb_puts(s, "SELECT "); put_ident(s, id_col); fsql_sb_puts(s, " FROM "); put_ident(s, table);
    fsql_sb_printf(s, " WHERE rowid = %" PRId64, rowid);
    fsql_qres *q = da_query(d, da_sb_str(d, s));
    return q_rows(q) > 0 ? q_text(d, q, 0, 0) : da_dup(d, "");
}
static char *da_resolve_scan_pos(da *d, const char *table, const char *id_col, int64_t pos) {
    fsql_sb *s = da_sb(d);
    fsql_sb_puts(s, "SELECT "); put_ident(s, id_col); fsql_sb_puts(s, " FROM (SELECT "); put_ident(s, id_col);
    fsql_sb_puts(s, ", row_number() OVER (ORDER BY rowid) - 1 AS __fsql_doc_id FROM "); put_ident(s, table);
    fsql_sb_printf(s, ") WHERE __fsql_doc_id = %" PRId64, pos);
    fsql_qres *q = da_query(d, da_sb_str(d, s));
    return q_rows(q) > 0 ? q_text(d, q, 0, 0) : da_dup(d, "");
}
static char *da_resolve_locator(da *d, const char *table, const char *id_col, int64_t locator, bool used_rowid) {
    return used_rowid ? da_resolve_rowid(d, table, id_col, locator) : da_resolve_scan_pos(d, table, id_col, locator);
}

/* The rowids of the rows matching `filter_col = filter_val` (all rows when filter_col is NULL). */
static void da_build_cohort(da *d, const char *table, const char *filter_col, const char *filter_val, bool filter_val_null, da_i64v *out) {
    fsql_sb *s = da_sb(d);
    fsql_sb_puts(s, "SELECT rowid FROM "); put_ident(s, table);
    if (filter_col) {
        fsql_sb_puts(s, " WHERE "); put_ident(s, filter_col); fsql_sb_puts(s, " = ");
        if (filter_val_null) fsql_sb_puts(s, "NULL"); else put_lit(s, filter_val);
    }
    fsql_qres *q = da_query(d, da_sb_str(d, s));
    idx_t n = q_rows(q);
    for (idx_t i = 0; i < n; i++) if (!q_null(q, 0, i)) i64v_push(d, out, q_i64(q, 0, i));
}

/* ------------------------------------------------------------------ */
/* Analytics primitives (context-free), with the registered wrappers'    */
/* validation and error text                                            */
/* ------------------------------------------------------------------ */

typedef struct { double drift, recent_alpha, baseline_alpha; } da_drift;

static void da_series_cap(da *d, size_t n) {
    if (n > DA_MAX_SERIES_LEN) da_fail(d, "fractalsql: series length %zu exceeds cap %u", n, (unsigned)DA_MAX_SERIES_LEN);
}
static da_drift da_drift_of(da *d, const double *s, size_t n, int64_t window) {
    if (window <= 0) da_fail(d, "fractalsql: win must be > 0");
    da_series_cap(d, n);
    da_drift r = { 0, 0, 0 };
    int rc = fsql_dimension_drift(s, n, (size_t)window, &r.drift, &r.recent_alpha, &r.baseline_alpha);
    if (rc != FSQL_OK) da_fail(d, "fractalsql: fractal_dimension_drift rc=%d (need n >= window + 16, window >= 16)", rc);
    return r;
}
static double da_dfa_of(da *d, const double *s, size_t n) {
    da_series_cap(d, n);
    double alpha = 0.0;
    int rc = fsql_dimension_dfa(s, n, &alpha);
    if (rc != FSQL_OK) da_fail(d, "fractalsql: fractal_dimension_dfa rc=%d (series needs >= 16 points)", rc);
    return alpha;
}
static double da_boxcount_of(da *d, const double *pts, size_t n, int64_t dim) {
    if (dim <= 0 || dim > DA_MAX_SPATIAL_DIM) da_fail(d, "fractalsql: dim out of range [1, %d]", DA_MAX_SPATIAL_DIM);
    if (n > DA_MAX_POINTS_FLAT_LEN) da_fail(d, "fractalsql: points length %zu exceeds cap %u", n, (unsigned)DA_MAX_POINTS_FLAT_LEN);
    if (n % (size_t)dim != 0) da_fail(d, "fractalsql: points length (%zu) must be a multiple of dim (%" PRId64 ")", n, dim);
    double out = 0.0;
    int rc = fsql_dimension_boxcount(pts, n / (size_t)dim, (size_t)dim, &out);
    if (rc != FSQL_OK) da_fail(d, "fractalsql: fractal_dimension_boxcount rc=%d (need >= 8 points, non-degenerate bounding box)", rc);
    return out;
}
static void da_morphology_of(da *d, const double *pts, size_t n, int64_t dim, double *dimension, double *lacunarity) {
    if (dim < 1 || dim > DA_MAX_GEOM_DIM) da_fail(d, "fractalsql: dim %" PRId64 " out of range [1, %d]", dim, DA_MAX_GEOM_DIM);
    if (n == 0 || n % (size_t)dim != 0) da_fail(d, "fractalsql: points length (%zu) must be a positive multiple of dim (%" PRId64 ")", n, dim);
    size_t np = n / (size_t)dim;
    if (np > 1000000u) da_fail(d, "fractalsql: points point count exceeds cap");
    int rc = fsql_morphological_complexity(pts, np, (size_t)dim, dimension, lacunarity);
    if (rc != FSQL_OK) da_fail(d, "fractalsql: fractal_morphological_complexity rc=%d (need >= 8 points, non-degenerate bounding box)", rc);
}

/* ------------------------------------------------------------------ */
/* Corpus + in-process searches on the shared engine context             */
/* ------------------------------------------------------------------ */

typedef struct {
    fsql_vecd flat;          /* row-major, n_rows * dim */
    da_i64v  *row_ids;       /* populated when used_rowid */
    size_t    n_rows;
    int       dim;
    bool      used_rowid;
} da_corpus;

static const char *da_search_params(void) {
    return "{\"max_generation\":15,\"population_size\":50,\"maximum_diffusion\":2,\"walk\":0.5,\"bound_clipping\":true}";
}

/* Loads `col` of `table` (with rowids when `want_ids` and the table has them). */
static void da_scan_corpus(da *d, const char *who, const char *table, const char *col, bool want_ids, da_corpus *out, bool skip_nulls) {
    fsql_sb *s = da_sb(d);
    memset(out, 0, sizeof *out);
    fsql_vecd *flat = da_vecd(d);
    out->row_ids = da_i64vec(d);
    fsql_qres *q = NULL;
    char err[DA_ERRCAP];
    char lim[40];
    snprintf(lim, sizeof lim, " LIMIT %u", 2u * 1000u * 1000u);
    for (int attempt = 0; attempt < 2 && !q; attempt++) {
        bool ids = want_ids && attempt == 0;
        fsql_sb_clear(s);
        fsql_sb_puts(s, "SELECT ");
        if (ids) fsql_sb_puts(s, "rowid, ");
        put_ident(s, col); fsql_sb_puts(s, " FROM "); put_ident(s, table);
        if (skip_nulls) { fsql_sb_puts(s, " WHERE "); put_ident(s, col); fsql_sb_puts(s, " IS NOT NULL"); }
        fsql_sb_puts(s, lim);
        if (want_ids && attempt == 0) { q = da_try_query(d, da_sb_str(d, s), err, sizeof err); if (q) out->used_rowid = true; }
        else q = da_query(d, da_sb_str(d, s));
    }
    idx_t vec_col = out->used_rowid ? 1 : 0;
    size_t n = 0;
    for (duckdb_data_chunk ch = fsql_qres_next_chunk(q); ch; ch = fsql_qres_next_chunk(q)) {
        idx_t rows = duckdb_data_chunk_get_size(ch);
        if (rows == 0) { duckdb_destroy_data_chunk(&ch); break; }
        duckdb_vector vv = duckdb_data_chunk_get_vector(ch, vec_col);
        fsql_vkind kind;
        if (fsql_vkind_of(vv, &kind)) { duckdb_destroy_data_chunk(&ch); da_fail(d, "%s: %s.%s is not a LIST/ARRAY of DOUBLE or FLOAT", who, table, col); }
        for (idx_t r = 0; r < rows; r++) {
            size_t len = 0;
            size_t before = flat->len;
            int g = fsql_read_vec_row(vv, &kind, r, flat, &len);
            if (g < 0) { duckdb_destroy_data_chunk(&ch); da_fail(d, "%s: malformed list in %s.%s", who, table, col); }
            if (g == 0) {
                flat->len = before;
                if (skip_nulls) continue;
                duckdb_destroy_data_chunk(&ch);
                da_fail(d, "%s: NULL vector in %s.%s", who, table, col);
            }
            if (out->dim == 0) {
                out->dim = (int)len;
                if (out->dim <= 0) { duckdb_destroy_data_chunk(&ch); da_fail(d, "%s: %s.%s has zero-length vectors", who, table, col); }
            } else if ((int)len != out->dim) {
                duckdb_destroy_data_chunk(&ch);
                da_fail(d, "%s: %s.%s row %zu has dim %zu, expected %d", who, table, col, n, len, out->dim);
            }
            if (out->used_rowid) {
                duckdb_vector iv = duckdb_data_chunk_get_vector(ch, 0);
                i64v_push(d, out->row_ids, fsql_valid(duckdb_vector_get_validity(iv), r) ? ((const int64_t *)duckdb_vector_get_data(iv))[r] : -1);
            }
            n++;
        }
        duckdb_destroy_data_chunk(&ch);
    }
    da_vec_ok(d, flat);
    out->flat = *flat;
    out->n_rows = n;
}

/* Top-k over an in-memory corpus on the engine context. Returns the count; idx/dist are frame-owned. */
static int da_topk(da *d, const double *corpus, size_t n_rows, int dim, const double *query, int k, int **idx_out, double **dist_out) {
    const char *params = da_search_params();
    const char *rj = NULL; size_t rl = 0;
    int rc = fsql_search_ptr(d->ctx, corpus, n_rows, (size_t)dim, query, (size_t)dim, k, params, strlen(params), &rj, &rl);
    if (rc != FSQL_OK || !rj) {
        const char *e = fsql_last_error(d->ctx);
        da_fail(d, "fractalsql: search rc=%d: %s", rc, (e && *e) ? e : "(no detail)");
    }
    const char *p = strstr(rj, "\"top_k\":[");
    if (!p) da_fail(d, "fractalsql: malformed top_k in search result");
    p += strlen("\"top_k\":[");
    int *idx = (int *)da_track(d, calloc((size_t)k + 1, sizeof(int)), free);
    double *dist = (double *)da_track(d, calloc((size_t)k + 1, sizeof(double)), free);
    int n = 0;
    while (n < k) {
        while (*p == ' ' || *p == ',' || *p == '\n' || *p == '\r') p++;
        if (*p == ']' || !*p) break;
        const char *ik = strstr(p, "\"idx\":");
        if (!ik) da_fail(d, "fractalsql: malformed top_k in search result");
        char *end = NULL;
        long i = strtol(ik + 6, &end, 10);
        if (end == ik + 6) da_fail(d, "fractalsql: malformed top_k in search result");
        p = end;
        double dd = 0.0;
        const char *dk = strstr(p, "\"dist\":");
        if (!dk) da_fail(d, "fractalsql: malformed top_k in search result");
        dk += strlen("\"dist\":");
        if (!strncmp(dk, "null", 4)) p = dk + 4;
        else {
            dd = strtod(dk, &end);
            if (end == dk) da_fail(d, "fractalsql: malformed top_k in search result");
            p = end;
        }
        p = strchr(p, '}');
        if (!p) da_fail(d, "fractalsql: malformed top_k in search result");
        p++;
        if (i < 0 || (size_t)i >= n_rows) da_fail(d, "fractalsql: core reported out-of-range corpus index");
        { idx[n] = (int)i; dist[n] = dd; n++; }
    }
    *idx_out = idx; *dist_out = dist;
    return n;
}

/* One search step of `iterations` x `population` over the task vector alone; appends the best point to out. */
static void da_refine_best_point(da *d, const double *task, size_t dim, int iterations, int population, fsql_vecd *out) {
    char params[192];
    snprintf(params, sizeof params, "{\"max_generation\":%d,\"population_size\":%d,\"maximum_diffusion\":2,\"walk\":0.5,\"bound_clipping\":true}",
             iterations, population);
    const char *rj = NULL; size_t rl = 0;
    int rc = fsql_search_ptr(d->ctx, task, 1, dim, task, dim, 1, params, strlen(params), &rj, &rl);
    if (rc != FSQL_OK || !rj) {
        const char *e = fsql_last_error(d->ctx);
        da_fail(d, "fractalsql: search rc=%d: %s", rc, (e && *e) ? e : "(no detail)");
    }
    const char *p = strstr(rj, "\"best_point\":");
    if (!p) da_fail(d, "fractalsql: primitive call returned NULL");
    p += strlen("\"best_point\":");
    while (*p == ' ' || *p == '[' || *p == '"') p++;
    for (;;) {
        while (*p == ' ' || *p == ',' || *p == '\n' || *p == '\r') p++;
        if (*p == ']' || *p == '"' || !*p) break;
        char *end = NULL;
        double v = strtod(p, &end);
        if (end == p) break;
        fsql_vecd_push(out, v);
        p = end;
    }
    da_vec_ok(d, out);
    if (out->len == 0) da_fail(d, "fractalsql: primitive call returned NULL");
}

/* Nearest single neighbour over a plain corpus. 1 found (idx/dist set), 0 none. */
static int da_nearest1_plain(da *d, const double *corpus, size_t n_rows, int dim, const double *query, int64_t *out_idx, double *out_dist) {
    int *idx; double *dist;
    *out_idx = -1; *out_dist = 0.0;
    int n = da_topk(d, corpus, n_rows, dim, query, 1, &idx, &dist);
    if (n <= 0) return 0;
    *out_idx = idx[0]; *out_dist = dist[0];
    return 1;
}

typedef struct { bool used_rowid; da_i64v *locators; fsql_vecd *distances; } da_hybrid;

static int cmp_i64(const void *a, const void *b) { int64_t x = *(const int64_t *)a, y = *(const int64_t *)b; return x < y ? -1 : x > y; }

/* The query and the corpus are compared element by element, so their dimensions must agree. A query
 * that is shorter than the corpus -- or empty -- would have the search read past the end of its
 * buffer, so the call is refused with the two dimensions named instead. */
static void da_check_dim(da *d, const char *who, size_t query_len, const char *table, const char *col, int dim) {
    if (query_len != (size_t)dim)
        da_fail(d, "%s: query dim %zu does not match %s.%s's dim %d", who, query_len, table, col, dim);
}

/* Cohort-restricted top-k. An empty cohort means the whole corpus. */
static void da_hybrid_search(da *d, const char *who, const char *table, const char *col, const double *query,
                             size_t query_len, int k, const da_i64v *cohort, da_hybrid *out, bool allow_empty_corpus) {
    out->used_rowid = false;
    out->locators = da_i64vec(d);
    out->distances = da_vecd(d);
    da_corpus scan;
    da_scan_corpus(d, who, table, col, true, &scan, false);
    if (scan.n_rows == 0) {
        if (allow_empty_corpus) return;
        da_fail(d, "%s: no corpus rows in %s.%s", who, table, col);
    }
    da_check_dim(d, who, query_len, table, col, scan.dim);
    fsql_vecd *kept = da_vecd(d);
    int *kept_pos = (int *)da_track(d, calloc(scan.n_rows ? scan.n_rows : 1, sizeof(int)), free);
    size_t nk = 0;
    if (scan.used_rowid && cohort->n > 0) {
        int64_t *sorted = (int64_t *)da_track(d, malloc(cohort->n * sizeof(int64_t)), free);
        memcpy(sorted, cohort->p, cohort->n * sizeof(int64_t));
        qsort(sorted, cohort->n, sizeof(int64_t), cmp_i64);
        for (size_t r = 0; r < scan.n_rows; r++) {
            if (!bsearch(&scan.row_ids->p[r], sorted, cohort->n, sizeof(int64_t), cmp_i64)) continue;
            for (int c = 0; c < scan.dim; c++) fsql_vecd_push(kept, scan.flat.p[r * (size_t)scan.dim + (size_t)c]);
            kept_pos[nk++] = (int)r;
        }
        da_vec_ok(d, kept);
        if (nk == 0) da_fail(d, "fractalsql: doc_ids cohort matched no rows in the corpus");
    } else {
        for (size_t r = 0; r < scan.n_rows; r++) kept_pos[r] = (int)r;
        nk = scan.n_rows;
    }
    int *idx; double *dist;
    const double *kp = (scan.used_rowid && cohort->n > 0) ? kept->p : scan.flat.p;
    int n = da_topk(d, kp, nk, scan.dim, query, k, &idx, &dist);
    out->used_rowid = scan.used_rowid;
    for (int i = 0; i < n; i++) {
        int orig = kept_pos[idx[i]];
        i64v_push(d, out->locators, scan.used_rowid ? scan.row_ids->p[orig] : (int64_t)orig);
        fsql_vecd_push(out->distances, dist[i]);
    }
    da_vec_ok(d, out->distances);
}

typedef struct { size_t hit_index; char *id_text; bool has_id; bool has_content; char *content_text; } da_joined;
typedef struct { da_joined *p; size_t n; } da_joined_list;

/* Resolves each hit's id (and optional content) column; unresolved hits are dropped. */
static da_joined_list da_join_hits(da *d, const char *table, const char *id_col, const char *content_col, const da_hybrid *hits) {
    da_joined_list out = { NULL, 0 };
    if (hits->locators->n == 0) return out;
    fsql_sb *inl = da_sb(d), *cols = da_sb(d), *sql = da_sb(d);
    for (size_t i = 0; i < hits->locators->n; i++) { if (i) fsql_sb_putc(inl, ','); fsql_sb_printf(inl, "%" PRId64, hits->locators->p[i]); }
    put_ident(cols, id_col);
    if (content_col) { fsql_sb_puts(cols, ", "); put_ident(cols, content_col); }
    if (hits->used_rowid) {
        fsql_sb_puts(sql, "SELECT rowid, "); fsql_sb_puts(sql, da_sb_str(d, cols)); fsql_sb_puts(sql, " FROM "); put_ident(sql, table);
        fsql_sb_printf(sql, " WHERE rowid IN (%s)", da_sb_str(d, inl));
    } else {
        fsql_sb_puts(sql, "SELECT __fsql_doc_id, "); fsql_sb_puts(sql, da_sb_str(d, cols));
        fsql_sb_puts(sql, " FROM (SELECT "); fsql_sb_puts(sql, da_sb_str(d, cols));
        fsql_sb_puts(sql, ", row_number() OVER (ORDER BY rowid) - 1 AS __fsql_doc_id FROM "); put_ident(sql, table);
        fsql_sb_printf(sql, ") WHERE __fsql_doc_id IN (%s)", da_sb_str(d, inl));
    }
    fsql_qres *q = da_query(d, da_sb_str(d, sql));
    idx_t nr = q_rows(q);
    /* the query result, keyed by locator, in result order; first row per key wins */
    out.p = (da_joined *)da_track(d, calloc(hits->locators->n, sizeof(da_joined)), free);
    for (size_t h = 0; h < hits->locators->n; h++) {
        for (idx_t i = 0; i < nr; i++) {
            if (q_null(q, 0, i) || q_i64(q, 0, i) != hits->locators->p[h]) continue;
            da_joined *j = &out.p[out.n++];
            j->hit_index = h;
            j->has_id = !q_null(q, 1, i);
            j->id_text = q_text(d, q, 1, i);
            if (content_col) { j->has_content = true; j->content_text = q_text(d, q, 2, i); }
            break;
        }
    }
    return out;
}

/* ------------------------------------------------------------------ */
/* Provenance, reasoning and argument helpers                            */
/* ------------------------------------------------------------------ */

/* Best-effort fractal_audit_log re-entry. A failure is swallowed; one that is not the enterprise gate
 * is reported on stderr. */
static void da_audit(da *d, const char *entry_type, const char *payload_json) {
    fsql_sb *s = da_sb(d);
    fsql_sb_puts(s, "SELECT fractal_audit_log("); put_lit(s, entry_type); fsql_sb_puts(s, ", "); put_lit(s, payload_json); fsql_sb_putc(s, ')');
    char err[DA_ERRCAP];
    fsql_qres *q = da_try_query(d, da_sb_str(d, s), err, sizeof err);
    if (!q && !strstr(err, "nterprise"))
        fprintf(stderr, "fractalsql: provenance entry '%s' was not recorded: %s\n", entry_type, err);
}

static void da_no_row(da *d) { da_fail(d, "fractalsql: primitive call returned NULL"); }

/* A CHAT-tier cognition step. true = a rationale (frame-owned) in *out; false = an outage, text in *err_out.
 * A plugin that was never configured fails the engine. */
static bool da_try_reasoning(da *d, int tier, const char *prompt, const char *ctx, char **out, char **err_out) {
    char *resp = NULL;
    char err[DA_ERRCAP];
    int rc = fsql_reasoning_generate(tier, prompt, strlen(prompt), ctx, strlen(ctx), &resp, err, sizeof err);
    if (rc == FSQL_REASONING_OK) { *out = da_dup(d, resp); free(resp); *err_out = NULL; return true; }
    if (rc == FSQL_REASONING_NOT_CONFIGURED) da_fail(d, "%s", err);
    *out = NULL;
    *err_out = da_dup(d, err);
    return false;
}

/* The rationale slot of an engine document: the string, or null plus a reasoning_step_failed field. */
static void da_rationale_value(fsql_sb *out, bool ok, const char *rationale, const char *err) {
    if (ok) { put_json_string(out, rationale); return; }
    fsql_sb_puts(out, "null,\"reasoning_step_failed\":");
    put_json_string(out, err);
}

/* ---- arguments: column c of row r of the input chunk ---- */

typedef struct { duckdb_data_chunk in; idx_t row; idx_t ncols; } da_args;

static bool a_null(const da_args *a, idx_t c) { return !fsql_valid(fsql_col_validity(a->in, c), a->row); }
static char *a_str(da *d, const da_args *a, idx_t c) {
    size_t l; const char *s = fsql_str_data(&((const duckdb_string_t *)fsql_col_data(a->in, c))[a->row], &l);
    return da_dupn(d, s, l);
}
static int a_i32(const da_args *a, idx_t c) { return ((const int32_t *)fsql_col_data(a->in, c))[a->row]; }
static int64_t a_i64(const da_args *a, idx_t c) { return ((const int64_t *)fsql_col_data(a->in, c))[a->row]; }
static double a_f64(const da_args *a, idx_t c) { return ((const double *)fsql_col_data(a->in, c))[a->row]; }

static void da_require_not_null(da *d, const da_args *a, const char *who, idx_t count, const char *msg) {
    for (idx_t c = 0; c < count; c++) if (a_null(a, c)) da_fail(d, "%s: %s", who, msg);
}
static int a_opt_int(const da_args *a, idx_t c, int dflt) { return (a->ncols <= c || a_null(a, c)) ? dflt : a_i32(a, c); }
static double a_opt_double(const da_args *a, idx_t c, double dflt) { return (a->ncols <= c || a_null(a, c)) ? dflt : a_f64(a, c); }
static const char *a_opt_string(da *d, const da_args *a, idx_t c, const char *dflt) { return (a->ncols <= c || a_null(a, c)) ? dflt : a_str(d, a, c); }
/* NULL when the optional text argument is absent or NULL. */
static const char *a_optional_text(da *d, const da_args *a, idx_t c) { return (a->ncols <= c || a_null(a, c)) ? NULL : a_str(d, a, c); }

/* A DOUBLE[] argument into `out`; false when the list is NULL. A NULL element fails. */
static bool a_vec(da *d, const da_args *a, idx_t c, fsql_vecd *out) {
    if (a_null(a, c)) return false;
    fsql_list l; fsql_list_open(&l, duckdb_data_chunk_get_vector(a->in, c));
    const double *p; size_t n; const char *le;
    int g = fsql_list_f64_get(&l, a->row, &p, &n, &le);
    if (g < 0) da_fail(d, "%s", le ? le : "fractalsql: malformed list");
    if (g == 0) da_fail(d, "fractalsql: list argument contains a NULL element");
    for (size_t i = 0; i < n; i++) fsql_vecd_push(out, p[i]);
    da_vec_ok(d, out);
    return true;
}

/* ---- the engine entry wrapper ---- */

typedef void (*da_body)(da *d, const da_args *a, fsql_sb *out);

static void da_run_engine(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector vout, da_body body) {
    fsql_instance *inst = fsql_scalar_instance(info);
    idx_t n = duckdb_data_chunk_get_size(in);
    da_engine *eng = (da_engine *)fsql_instance_singleton(inst, 0, sizeof(da_engine), da_engine_init, da_engine_destroy);
    if (!eng) { fsql_fn_error(info, "fractalsql: out of memory"); return; }
    FsqlConn *conn = fsql_conn_get(inst, fsql_exec_conn_id(info));
    for (idx_t i = 0; i < n; i++) {
        da d;
        memset(&d, 0, sizeof d);
        d.inst = inst; d.conn = conn; d.eng = eng;
        da_args a = { in, i, duckdb_data_chunk_get_column_count(in) };
        fsql_mu_lock(&eng->mu);
        if (setjmp(d.jb) == 0) {
            if (!eng->ctx) {
                eng->ctx = fsql_new_sovereign(NULL, NULL);
                if (!eng->ctx) da_fail(&d, "fractalsql: fsql_new_sovereign failed (OOM?)");
            }
            d.ctx = eng->ctx;
            fsql_sb *out = da_sb(&d);
            body(&d, &a, out);
            const char *s = da_sb_str(&d, out);
            fsql_set_str(vout, i, s, strlen(s));
            da_release(&d);
            fsql_mu_unlock(&eng->mu);
        } else {
            da_release(&d);
            fsql_mu_unlock(&eng->mu);
            duckdb_scalar_function_set_error(info, d.err);
            return;
        }
    }
}

/* ------------------------------------------------------------------ */
/* A. fractal_agent_anomaly_triage                                      */
/*    (log_table, metric_col, time_col, filter_col, filter_val [, baseline_window]) */
/* ------------------------------------------------------------------ */

static void body_anomaly_triage(da *d, const da_args *a, fsql_sb *out) {
    const char *who = "fractal_agent_anomaly_triage";
    da_require_not_null(d, a, who, 5, "identifier arguments must not be NULL");
    int baseline_window = a_opt_int(a, 5, 32);
    const char *log_table = a_str(d, a, 0), *metric_col = a_str(d, a, 1), *time_col = a_str(d, a, 2),
               *filter_col = a_str(d, a, 3), *filter_val = a_str(d, a, 4);
    fsql_sb *s = da_sb(d);
    fsql_sb_puts(s, "SELECT "); put_ident(s, metric_col); fsql_sb_puts(s, " FROM "); put_ident(s, log_table);
    fsql_sb_puts(s, " WHERE "); put_ident(s, filter_col); fsql_sb_puts(s, " = "); put_lit(s, filter_val);
    fsql_sb_puts(s, " ORDER BY "); put_ident(s, time_col);
    fsql_qres *q = da_query(d, da_sb_str(d, s));
    fsql_vecd *series = da_vecd(d);
    for (idx_t i = 0, n = q_rows(q); i < n; i++) if (!q_null(q, 0, i)) fsql_vecd_push(series, q_f64(q, 0, i));
    da_vec_ok(d, series);
    if (series->len == 0) da_fail(d, "%s: no rows in %s.%s matching %s = %s", who, log_table, metric_col, filter_col, filter_val);
    da_drift dr = da_drift_of(d, series->p, series->len, baseline_window);
    double threat = dr.drift;
    const char *prompt = da_fmt(d, "Triage this anomaly: drift score %s", da_f10(d, threat));
    fsql_sb *cj = da_sb(d);
    fsql_sb_puts(cj, "{\"table\":"); put_json_string(cj, log_table);
    fsql_sb_puts(cj, ",\"filter\":"); put_json_string(cj, filter_val); fsql_sb_putc(cj, '}');
    char *rationale, *rerr;
    bool ok = da_try_reasoning(d, FSQL_REASONING_TIER_CHAT, prompt, da_sb_str(d, cj), &rationale, &rerr);
    fsql_sb *body = da_sb(d);
    fsql_sb_printf(body, "{\"threat_score\":%s,\"anomaly_type\":\"vector_drift\",\"triage_summary\":", da_f10(d, threat));
    da_rationale_value(body, ok, rationale, rerr);
    fsql_sb_putc(body, '}');
    da_audit(d, "agent_anomaly_triage", da_sb_str(d, body));
    fsql_sb_puts(out, da_sb_str(d, body));
}

/* ------------------------------------------------------------------ */
/* B. fractal_agent_allocate (mu, cov, cardinality [, context_json])    */
/* ------------------------------------------------------------------ */

typedef struct { double sharpe; fsql_vecd *weights; } da_opt;

/* Composes the REGISTERED fractal_optimize_portfolio as SQL; seed_sql is the seed argument's SQL text. */
static da_opt da_compose_optimizer(da *d, const fsql_vecd *mu, const fsql_vecd *cov, int64_t cardinality, const char *seed_sql) {
    fsql_sb *s = da_sb(d);
    fsql_sb_printf(s, "SELECT o.sharpe AS __sharpe, o.weights AS __weights FROM (SELECT fractal_optimize_portfolio(%s, %s, %" PRId64 ", %s) AS o)",
                   da_vec_literal(d, mu->p, mu->len), da_vec_literal(d, cov->p, cov->len), cardinality, seed_sql);
    fsql_qres *q = da_query(d, da_sb_str(d, s));
    duckdb_data_chunk ch = fsql_qres_next_chunk(q);
    if (!ch || duckdb_data_chunk_get_size(ch) == 0) { if (ch) duckdb_destroy_data_chunk(&ch); da_no_row(d); }
    duckdb_vector sv = duckdb_data_chunk_get_vector(ch, 0), wv = duckdb_data_chunk_get_vector(ch, 1);
    da_opt r = { 0.0, da_vecd(d) };
    fsql_vkind kind; size_t len = 0;
    bool ok = fsql_valid(duckdb_vector_get_validity(sv), 0) && !fsql_vkind_of(wv, &kind) && fsql_read_vec_row(wv, &kind, 0, r.weights, &len) == 1;
    if (ok) r.sharpe = ((const double *)duckdb_vector_get_data(sv))[0];
    duckdb_destroy_data_chunk(&ch);
    if (!ok || r.weights->len == 0) da_no_row(d);
    return r;
}

static const char *da_opt_json(da *d, const da_opt *o) {
    fsql_sb *b = da_sb(d);
    fsql_sb_printf(b, "{\"sharpe\":%s,\"weights\":", da_f10(d, o->sharpe));
    put_vec_json(b, o->weights->p, o->weights->len);
    fsql_sb_putc(b, '}');
    return da_sb_str(d, b);
}

static void body_allocate(da *d, const da_args *a, fsql_sb *out) {
    const char *who = "fractal_agent_allocate";
    da_require_not_null(d, a, who, 3, "mu, cov, and cardinality are required");
    fsql_vecd *mu = da_vecd(d), *cov = da_vecd(d);
    if (!a_vec(d, a, 0, mu) || !a_vec(d, a, 1, cov)) da_fail(d, "%s: mu, cov, and cardinality are required", who);
    const char *context_json = a_opt_string(d, a, 3, "{}");
    int64_t card = a_i32(a, 2);
    da_opt opt = da_compose_optimizer(d, mu, cov, card, "0");
    const char *opt_json = da_opt_json(d, &opt);
    const char *prompt = da_fmt(d, "Explain this cardinality-constrained allocation and its risk/return: %s", opt_json);
    char *rationale, *rerr;
    bool ok = da_try_reasoning(d, FSQL_REASONING_TIER_CHAT, prompt, context_json, &rationale, &rerr);
    fsql_sb *audit = da_sb(d);
    fsql_sb_printf(audit, "{\"sharpe\":%s,\"cardinality\":%" PRId64 ",\"rationale\":", da_f10(d, opt.sharpe), card);
    da_rationale_value(audit, ok, rationale, rerr);
    fsql_sb_putc(audit, '}');
    da_audit(d, "agent_allocate", da_sb_str(d, audit));
    fsql_sb_printf(out, "{\"allocation\":%s,\"sharpe\":%s,\"rationale\":", opt_json, da_f10(d, opt.sharpe));
    da_rationale_value(out, ok, rationale, rerr);
    fsql_sb_putc(out, '}');
}

/* ------------------------------------------------------------------ */
/* C. fractal_agent_route_task (task_emb, cap_table, cap_emb_col, cap_id_col [, budget [, cost_per_route]]) */
/* ------------------------------------------------------------------ */

static void body_route_task(da *d, const da_args *a, fsql_sb *out) {
    const char *who = "fractal_agent_route_task";
    da_require_not_null(d, a, who, 4, "identifier arguments must not be NULL");
    int budget = a_opt_int(a, 4, 0), cost = a_opt_int(a, 5, 150);
    fsql_vecd *task = da_vecd(d);
    if (!a_vec(d, a, 0, task)) da_fail(d, "%s: identifier arguments must not be NULL", who);
    const char *cap_table = a_str(d, a, 1), *cap_emb = a_str(d, a, 2), *cap_id = a_str(d, a, 3);
    if (!da_table_has_rows(d, cap_table)) da_fail(d, "%s: no capability rows in %s", who, cap_table);
    da_hybrid hit;
    da_i64v *cohort = da_i64vec(d);
    da_hybrid_search(d, who, cap_table, cap_emb, task->p, task->len, 1, cohort, &hit, false);
    if (hit.locators->n == 0) da_fail(d, "%s: no capability rows in %s", who, cap_table);
    double dist = hit.distances->p[0];
    const char *routed = da_resolve_locator(d, cap_table, cap_id, hit.locators->p[0], hit.used_rowid);
    const char *prompt = da_fmt(d, "Route this task to capability %s (cosine distance %s). Justify the routing in one sentence.",
                                *routed ? routed : "?", da_f10(d, dist));
    const char *cj = da_fmt(d, "{\"budget\":%d,\"cost_per_route\":%d}", budget, cost);
    char *rationale, *rerr;
    bool ok = da_try_reasoning(d, FSQL_REASONING_TIER_CHAT, prompt, cj, &rationale, &rerr);
    double confidence = 1.0 / (1.0 + dist);
    fsql_sb *audit = da_sb(d);
    fsql_sb_puts(audit, "{\"routed_to\":");
    if (!*routed) fsql_sb_puts(audit, "null"); else put_json_string(audit, routed);   /* always a string */
    fsql_sb_printf(audit, ",\"confidence\":%s,\"remaining_budget\":%lld,\"rationale\":", da_f10(d, confidence), (long long)budget - (long long)cost);   /* 64-bit: two caller ints can overflow an int */
    da_rationale_value(audit, ok, rationale, rerr);
    fsql_sb_putc(audit, '}');
    da_audit(d, "agent_route_task", da_sb_str(d, audit));
    fsql_sb_puts(out, da_sb_str(d, audit));
}

/* ------------------------------------------------------------------ */
/* D. fractal_agent_outlier_intercept (state, history_table, emb_col, threshold [, metric]) */
/* ------------------------------------------------------------------ */

static void body_outlier_intercept(da *d, const da_args *a, fsql_sb *out) {
    const char *who = "fractal_agent_outlier_intercept";
    da_require_not_null(d, a, who, 4, "all arguments are required");
    const char *metric = "cosine";
    if (a->ncols == 5) {
        const char *m = a_null(a, 4) ? NULL : a_str(d, a, 4);
        if (!m || (strcmp(m, "cosine") && strcmp(m, "l2"))) da_fail(d, "%s: metric must be 'cosine' or 'l2'", who);
        metric = m;
    }
    fsql_vecd *state = da_vecd(d);
    if (!a_vec(d, a, 0, state)) da_fail(d, "%s: all arguments are required", who);
    const char *table = a_str(d, a, 1), *emb = a_str(d, a, 2);
    double threshold = a_f64(a, 3);
    if (!da_table_has_rows(d, table)) da_fail(d, "%s: no bad-state rows in %s", who, table);
    double dist = 0.0;
    if (!strcmp(metric, "l2")) {
        da_corpus scan;
        da_scan_corpus(d, who, table, emb, false, &scan, true);
        if (scan.n_rows == 0) da_fail(d, "%s: no bad-state rows in %s", who, table);
        da_check_dim(d, who, state->len, table, emb, scan.dim);
        float *q = (float *)da_track(d, malloc(state->len * sizeof(float)), free);
        float *row = (float *)da_track(d, malloc((size_t)scan.dim * sizeof(float)), free);
        for (size_t i = 0; i < state->len; i++) q[i] = (float)state->p[i];
        bool have = false;
        for (size_t r = 0; r < scan.n_rows; r++) {
            for (int j = 0; j < scan.dim; j++) row[j] = (float)scan.flat.p[r * (size_t)scan.dim + (size_t)j];
            float d2 = 0.0f;
            if (fsql_vector_l2(q, row, (size_t)scan.dim, &d2) != FSQL_OK) da_fail(d, "%s: fractal_vector_l2_distance failed", who);
            if (!have || d2 < dist) { dist = d2; have = true; }
        }
    } else {
        da_i64v *cohort = da_i64vec(d);
        da_hybrid hit;
        da_hybrid_search(d, who, table, emb, state->p, state->len, 1, cohort, &hit, false);
        if (hit.locators->n == 0) da_fail(d, "%s: no bad-state rows in %s", who, table);
        dist = hit.distances->p[0];
    }
    bool intercepted = dist < threshold;
    const char *prompt = da_fmt(d, "Outlier intercept: nearest known-bad state is at %s distance %s, threshold %s, so %s. Justify the decision in one sentence.",
                                metric, da_f10(d, dist), da_f10(d, threshold), intercepted ? "INTERCEPT" : "allow");
    fsql_sb *cj = da_sb(d);
    fsql_sb_printf(cj, "{\"threshold\":%s,\"metric\":", da_f10(d, threshold));
    put_json_string(cj, metric);
    fsql_sb_printf(cj, ",\"intercepted\":%s}", intercepted ? "true" : "false");
    char *reason, *rerr;
    bool ok = da_try_reasoning(d, FSQL_REASONING_TIER_CHAT, prompt, da_sb_str(d, cj), &reason, &rerr);
    fsql_sb *audit = da_sb(d);
    fsql_sb_printf(audit, "{\"intercepted\":%s,\"nearest_distance\":%s,\"threshold\":%s,\"metric\":", intercepted ? "true" : "false",
                   da_f10(d, dist), da_f10(d, threshold));
    put_json_string(audit, metric);
    fsql_sb_puts(audit, ",\"reason\":");
    da_rationale_value(audit, ok, reason, rerr);
    fsql_sb_putc(audit, '}');
    da_audit(d, "agent_outlier_intercept", da_sb_str(d, audit));
    fsql_sb_printf(out, "{\"intercepted\":%s,\"metric\":", intercepted ? "true" : "false");
    put_json_string(out, metric);
    fsql_sb_puts(out, ",\"reason\":");
    da_rationale_value(out, ok, reason, rerr);
    fsql_sb_putc(out, '}');
}

/* ------------------------------------------------------------------ */
/* E. fractal_agent_recall_hybrid                                       */
/*    (mem_table, vec_col, query [, filter_col [, filter_val [, k [, id_col [, content_col]]]]]) */
/* ------------------------------------------------------------------ */

static void body_recall_hybrid(da *d, const da_args *a, fsql_sb *out) {
    const char *who = "fractal_agent_recall_hybrid";
    da_require_not_null(d, a, who, 3, "mem_table, vec_col, query_vec are required");
    const char *filter_col = NULL, *filter_val = NULL;
    bool filter_val_null = false;
    if (a->ncols == 4 && !a_null(a, 3)) da_fail(d, "%s: filter_col requires filter_val", who);
    filter_col = a_optional_text(d, a, 3);
    if (filter_col) {
        filter_val = a_optional_text(d, a, 4);
        if (!filter_val && a->ncols > 4 && a_null(a, 4)) filter_val_null = true;
    }
    int k = a_opt_int(a, 5, 5);
    const char *id_col = a_opt_string(d, a, 6, "id");
    const char *content_col = a_optional_text(d, a, 7);
    fsql_vecd *query = da_vecd(d);
    if (!a_vec(d, a, 2, query)) da_fail(d, "%s: mem_table, vec_col, query_vec are required", who);
    const char *mem_table = a_str(d, a, 0), *vec_col = a_str(d, a, 1);

    da_i64v *cohort = da_i64vec(d);
    if (filter_col) {
        da_build_cohort(d, mem_table, filter_col, filter_val, filter_val_null, cohort);
        if (cohort->n == 0) da_fail(d, "%s: filter matched no rows in %s", who, mem_table);
    }
    da_hybrid hits;
    da_hybrid_search(d, who, mem_table, vec_col, query->p, query->len, k, cohort, &hits, true);
    da_joined_list jl = da_join_hits(d, mem_table, id_col, content_col, &hits);
    fsql_sb_putc(out, '[');
    for (size_t i = 0; i < jl.n; i++) {
        if (i) fsql_sb_putc(out, ',');
        fsql_sb_puts(out, "{\"mem_id\":");
        if (jl.p[i].has_id) put_id_value_json(out, jl.p[i].id_text); else fsql_sb_puts(out, "null");
        fsql_sb_puts(out, ",\"content\":");
        if (jl.p[i].has_content) put_json_string(out, jl.p[i].content_text); else fsql_sb_puts(out, "null");
        fsql_sb_putc(out, '}');
    }
    fsql_sb_putc(out, ']');
}

/* ------------------------------------------------------------------ */
/* F. fractal_agent_recommend_diverse (catalog_table, emb_col, query [, k [, id_col]]) */
/* ------------------------------------------------------------------ */

static void body_recommend_diverse(da *d, const da_args *a, fsql_sb *out) {
    const char *who = "fractal_agent_recommend_diverse";
    da_require_not_null(d, a, who, 3, "catalog_table, emb_col, query_vec are required");
    int k = a_opt_int(a, 3, 10);
    const char *id_col = a_opt_string(d, a, 4, "id");
    fsql_vecd *query = da_vecd(d);
    if (!a_vec(d, a, 2, query)) da_fail(d, "%s: catalog_table, emb_col, query_vec are required", who);
    const char *table = a_str(d, a, 0), *emb = a_str(d, a, 1);
    if (!da_table_has_rows(d, table)) da_no_row(d);       /* an empty aggregate: the NULL sentinel */
    if (fsql_diversify_enable(d->ctx) == FSQL_OK && d->conn) d->conn->da_diversify = 1;
    da_hybrid hits;
    da_i64v *cohort = da_i64vec(d);
    da_hybrid_search(d, who, table, emb, query->p, query->len, k, cohort, &hits, false);
    da_joined_list jl = da_join_hits(d, table, id_col, NULL, &hits);
    if (jl.n == 0) da_no_row(d);
    fsql_sb_putc(out, '[');
    for (size_t i = 0; i < jl.n; i++) {
        if (i) fsql_sb_putc(out, ',');
        fsql_sb_puts(out, "{\"item_id\":");
        if (jl.p[i].has_id) put_id_value_json(out, jl.p[i].id_text); else fsql_sb_puts(out, "null");
        fsql_sb_puts(out, ",\"score\":");
        put_number_json(out, 1.0 - hits.distances->p[i]);
        fsql_sb_putc(out, '}');
    }
    fsql_sb_putc(out, ']');
}

/* ------------------------------------------------------------------ */
/* G. fractal_agent_data_analyst (question [, table_names [, max_retries [, context [, auto_execute]]]]) */
/* ------------------------------------------------------------------ */

/* The elements of a VARCHAR[] argument; NULL elements read as "NULL". *n = 0 for an empty list. */
static char **a_str_list(da *d, const da_args *a, idx_t c, size_t *n) {
    duckdb_vector v = duckdb_data_chunk_get_vector(a->in, c);
    duckdb_list_entry e = ((const duckdb_list_entry *)duckdb_vector_get_data(v))[a->row];
    duckdb_vector child = duckdb_list_vector_get_child(v);
    const duckdb_string_t *cd = (const duckdb_string_t *)duckdb_vector_get_data(child);
    const uint64_t *cv = duckdb_vector_get_validity(child);
    if (e.offset > UINT64_MAX - e.length || e.offset + e.length > duckdb_list_vector_get_size(v)) da_fail(d, "fractalsql: malformed list");
    char **arr = (char **)da_track(d, calloc((size_t)e.length + 1, sizeof(char *)), free);
    for (idx_t i = 0; i < e.length; i++) {
        if (!fsql_valid(cv, e.offset + i)) { arr[i] = da_dup(d, "NULL"); continue; }
        size_t l; const char *p = fsql_str_data(&cd[e.offset + i], &l);
        arr[i] = da_dupn(d, p, l);
    }
    *n = (size_t)e.length;
    return arr;
}

static void body_data_analyst(da *d, const da_args *a, fsql_sb *out) {
    const char *who = "fractal_agent_data_analyst";
    if (a_null(a, 0)) da_fail(d, "%s: question must not be NULL", who);
    char **tables = NULL; size_t nt = 0;
    bool have_tables = a->ncols > 1 && !a_null(a, 1);
    if (have_tables) tables = a_str_list(d, a, 1, &nt);
    int max_retries = a_opt_int(a, 2, 2);
    const char *context_json = a_opt_string(d, a, 3, "{}");
    bool auto_execute = false;
    if (a->ncols > 4 && !a_null(a, 4)) auto_execute = ((const bool *)fsql_col_data(a->in, 4))[a->row];
    const char *question = a_str(d, a, 0);

    fsql_sb *s = da_sb(d);
    fsql_sb_puts(s, "SELECT generated_sql, execution_status, result_json FROM fractal_sql_agent(");
    put_lit(s, question); fsql_sb_puts(s, ", ");
    if (have_tables) {
        fsql_sb_putc(s, '[');
        for (size_t i = 0; i < nt; i++) { if (i) fsql_sb_putc(s, ','); put_lit(s, tables[i]); }
        fsql_sb_putc(s, ']');
    } else fsql_sb_puts(s, "NULL");
    fsql_sb_printf(s, ", %d, %s)", max_retries, auto_execute ? "TRUE" : "FALSE");
    fsql_qres *q = da_query(d, da_sb_str(d, s));
    if (q_rows(q) == 0) da_fail(d, "fractalsql: fractal_sql_agent returned NULL");
    bool gen_null = q_null(q, 0, 0), exe_null = q_null(q, 1, 0), rj_null = q_null(q, 2, 0);
    if (gen_null && exe_null) da_fail(d, "fractalsql: fractal_sql_agent returned NULL");
    const char *gen = gen_null ? NULL : q_text(d, q, 0, 0);
    const char *exe = exe_null ? NULL : q_text(d, q, 1, 0);
    const char *rj = rj_null ? NULL : q_text(d, q, 2, 0);
    const char *rj_or_null = rj ? rj : "null";

    fsql_sb *audit = da_sb(d);
    fsql_sb_puts(audit, "{\"question\":"); put_json_string(audit, question);
    fsql_sb_puts(audit, ",\"generated_sql\":"); put_raw_or_null(audit, gen);
    fsql_sb_puts(audit, ",\"execution_status\":"); put_raw_or_null(audit, exe);
    fsql_sb_printf(audit, ",\"auto_execute\":%s", auto_execute ? "true" : "false");
    if (!auto_execute) {
        fsql_sb_puts(audit, ",\"analysis\":null}");
        da_audit(d, "agent_data_analyst", da_sb_str(d, audit));
        fsql_sb_puts(out, "{\"analysis\":null,\"generated_sql\":"); put_raw_or_null(out, gen);
        fsql_sb_puts(out, ",\"result_json\":"); put_raw_or_string(out, rj_or_null);
        fsql_sb_putc(out, '}');
        return;
    }
    const char *prompt = da_fmt(d, "Analyze this database query result and answer in one paragraph: %s", rj_or_null);
    char *analysis, *rerr;
    bool ok = da_try_reasoning(d, FSQL_REASONING_TIER_CHAT, prompt, context_json, &analysis, &rerr);
    fsql_sb_puts(audit, ",\"analysis\":"); da_rationale_value(audit, ok, analysis, rerr); fsql_sb_putc(audit, '}');
    da_audit(d, "agent_data_analyst", da_sb_str(d, audit));
    fsql_sb_puts(out, "{\"analysis\":"); da_rationale_value(out, ok, analysis, rerr);
    fsql_sb_puts(out, ",\"generated_sql\":"); put_raw_or_null(out, gen);
    fsql_sb_puts(out, ",\"result_json\":"); put_raw_or_string(out, rj_or_null);
    fsql_sb_putc(out, '}');
}

/* ---- shared by the trajectory-based engines (H, K, L, M) ---- */

typedef struct { bool found; int64_t doc; double dist; } da_traj_hit;

/* Nearest corpus row to the (current - baseline) delta. An empty corpus or an empty top-k is a miss. */
static void da_trajectory_nearest(da *d, const char *who, const char *table, const char *col, const fsql_vecd *baseline, const fsql_vecd *current, da_traj_hit *out) {
    out->found = false; out->doc = -1; out->dist = 0.0;
    if (baseline->len != current->len) da_fail(d, "fractalsql: baseline dim %zu != current dim %zu", baseline->len, current->len);
    fsql_vecd *delta = da_vecd(d);
    for (size_t j = 0; j < current->len; j++) fsql_vecd_push(delta, current->p[j] - baseline->p[j]);
    da_vec_ok(d, delta);
    da_corpus scan;
    da_scan_corpus(d, who, table, col, false, &scan, false);
    if (scan.n_rows == 0) return;
    da_check_dim(d, who, delta->len, table, col, scan.dim);
    int64_t idx; double dist;
    if (!da_nearest1_plain(d, scan.flat.p, scan.n_rows, scan.dim, delta->p, &idx, &dist)) return;
    out->found = true; out->doc = idx; out->dist = dist;
}

/* A BIGINT[] argument into an int64 vector. */
static void a_i64_list(da *d, const da_args *a, idx_t c, da_i64v *out) {
    duckdb_vector v = duckdb_data_chunk_get_vector(a->in, c);
    duckdb_list_entry e = ((const duckdb_list_entry *)duckdb_vector_get_data(v))[a->row];
    duckdb_vector child = duckdb_list_vector_get_child(v);
    const int64_t *cd = (const int64_t *)duckdb_vector_get_data(child);
    if (e.offset > UINT64_MAX - e.length || e.offset + e.length > duckdb_list_vector_get_size(v)) da_fail(d, "fractalsql: malformed list");
    for (idx_t i = 0; i < e.length; i++) i64v_push(d, out, cd[e.offset + i]);
}

/* ------------------------------------------------------------------ */
/* H. fractal_agent_patient_deterioration_triage                        */
/*    (patient_table, vec_col, query, baseline, current [, cohort_ids [, k [, id_col]]]) */
/* ------------------------------------------------------------------ */

static void body_patient_triage(da *d, const da_args *a, fsql_sb *out) {
    const char *who = "fractal_agent_patient_deterioration_triage";
    da_require_not_null(d, a, who, 5, "the first five arguments are required");
    da_i64v *provided = da_i64vec(d);
    bool have_cohort = false;
    if (a->ncols > 5 && !a_null(a, 5)) { a_i64_list(d, a, 5, provided); have_cohort = true; }
    int k = a_opt_int(a, 6, 5);
    const char *id_col = a_opt_string(d, a, 7, "id");
    fsql_vecd *query = da_vecd(d), *baseline = da_vecd(d), *current = da_vecd(d);
    if (!a_vec(d, a, 2, query) || !a_vec(d, a, 3, baseline) || !a_vec(d, a, 4, current))
        da_fail(d, "%s: the first five arguments are required", who);
    const char *table = a_str(d, a, 0), *vec_col = a_str(d, a, 1);

    if (!da_table_has_rows(d, table)) da_fail(d, "%s: no patient rows in %s", who, table);
    da_i64v *cohort = provided;
    if (!have_cohort) {
        cohort = da_i64vec(d);
        da_build_cohort(d, table, NULL, NULL, false, cohort);
        if (cohort->n == 0) da_fail(d, "%s: cohort matched no rows in %s", who, table);
    }
    da_hybrid hits;
    da_hybrid_search(d, who, table, vec_col, query->p, query->len, k, cohort, &hits, false);
    fsql_sb *matches = da_sb(d);
    fsql_sb_putc(matches, '[');
    bool found_first = false;
    const char *first_id = "";
    double cohort_dist = 0.0;
    for (size_t h = 0; h < hits.locators->n; h++) {
        const char *id_text = da_resolve_locator(d, table, id_col, hits.locators->p[h], hits.used_rowid);
        if (strlen(da_sb_str(d, matches)) > 1) fsql_sb_putc(matches, ',');
        fsql_sb_puts(matches, "{\"id\":");
        if (*id_text) put_id_value_json(matches, id_text); else fsql_sb_puts(matches, "null");
        fsql_sb_puts(matches, ",\"distance\":");
        put_number_json(matches, hits.distances->p[h]);
        fsql_sb_putc(matches, '}');
        if (!found_first) { found_first = true; cohort_dist = hits.distances->p[h]; first_id = id_text; }
    }
    fsql_sb_putc(matches, ']');
    if (!found_first) da_fail(d, "%s: hybrid search returned no row in %s", who, table);
    da_traj_hit traj;
    da_trajectory_nearest(d, who, table, vec_col, baseline, current, &traj);
    const char *prompt = da_fmt(d, "Triage this patient: nearest cohort match is id %s at cosine distance %s; baseline->current drift distance is %s. Justify the deterioration triage in one sentence.",
                                *first_id ? first_id : "?", da_f10(d, cohort_dist), da_f10(d, traj.dist));
    const char *cj = da_fmt(d, "{\"cohort_distance\":%s,\"drift_distance\":%s}", da_f10(d, cohort_dist), da_f10(d, traj.dist));
    char *rationale, *rerr;
    bool ok = da_try_reasoning(d, FSQL_REASONING_TIER_CHAT, prompt, cj, &rationale, &rerr);
    fsql_sb *audit = da_sb(d);
    fsql_sb_puts(audit, "{\"nearest_cohort_id\":"); put_id_or_null_json(audit, first_id);
    fsql_sb_printf(audit, ",\"cohort_distance\":%s,\"drift_distance\":%s,\"rationale\":", da_f10(d, cohort_dist), da_f10(d, traj.dist));
    da_rationale_value(audit, ok, rationale, rerr);
    fsql_sb_puts(audit, ",\"cohort_matches\":"); put_raw_or_string(audit, da_sb_str(d, matches));
    fsql_sb_putc(audit, '}');
    da_audit(d, "agent_patient_deterioration_triage", da_sb_str(d, audit));
    fsql_sb_puts(out, da_sb_str(d, audit));
}

/* ------------------------------------------------------------------ */
/* I. fractal_agent_feedback_audit                                      */
/*    (catalog_table, emb_col, query, warmup_table, warmup_vec_col [, warmup_count [, k]]) */
/* ------------------------------------------------------------------ */

/* The registered fractal_explain_result shape, computed on the engine context ("%f" numbers, NaN as null). */
static const char *da_explain_diag(da *d, bool enabled) {
    double dq = fsql_diversify_current_dq(d->ctx), overhead = fsql_diversify_overhead_p99_us(d->ctx);
    char dqs[64], ovs[64];
    if (isnan(dq)) snprintf(dqs, sizeof dqs, "null"); else snprintf(dqs, sizeof dqs, "%f", dq);
    if (isnan(overhead)) snprintf(ovs, sizeof ovs, "null"); else snprintf(ovs, sizeof ovs, "%f", overhead);
    return da_fmt(d, "{\"dq\":%s,\"diversify_enabled\":%s,\"overhead_p99_us\":%s}", dqs, enabled ? "true" : "false", ovs);
}

/* One warm-up search; any failure is swallowed (the frame's allocations are released with the call). */
static void da_warm_one(da *d, const char *who, const char *catalog, const char *emb, const double *warm, int k) {
    jmp_buf saved;
    memcpy(&saved, &d->jb, sizeof saved);
    if (setjmp(d->jb) == 0) {
        da_corpus cal;
        da_scan_corpus(d, who, catalog, emb, false, &cal, false);
        if (cal.n_rows != 0) { int *idx; double *dist; da_topk(d, cal.flat.p, cal.n_rows, cal.dim, warm, k, &idx, &dist); }
    }
    memcpy(&d->jb, &saved, sizeof saved);
}

/* The warm-up pass: searches the catalog with each vector of warm_table.warm_col (LIMIT warmup_count) so the
 * diversify window has history. A failure anywhere in here is swallowed. */
static void da_warmup(da *d, const char *who, const char *catalog, const char *emb, const char *warm_table, const char *warm_col, int warmup_count, int k) {
    jmp_buf saved;
    memcpy(&saved, &d->jb, sizeof saved);
    if (setjmp(d->jb) == 0) {
        fsql_sb *s = da_sb(d);
        fsql_sb_puts(s, "SELECT "); put_ident(s, warm_col); fsql_sb_puts(s, " FROM "); put_ident(s, warm_table);
        fsql_sb_printf(s, " LIMIT %d", warmup_count);
        fsql_qres *q = da_query(d, da_sb_str(d, s));
        for (duckdb_data_chunk ch = fsql_qres_next_chunk(q); ch; ch = fsql_qres_next_chunk(q)) {
            idx_t rows = duckdb_data_chunk_get_size(ch);
            if (rows == 0) { duckdb_destroy_data_chunk(&ch); break; }
            duckdb_vector vv = duckdb_data_chunk_get_vector(ch, 0);
            fsql_vkind kind;
            if (fsql_vkind_of(vv, &kind)) { duckdb_destroy_data_chunk(&ch); break; }
            for (idx_t r = 0; r < rows; r++) {
                fsql_vecd *warm = da_vecd(d);
                size_t len = 0;
                if (fsql_read_vec_row(vv, &kind, r, warm, &len) != 1 || len == 0) continue;
                da_warm_one(d, who, catalog, emb, warm->p, k);
            }
            duckdb_destroy_data_chunk(&ch);
        }
    }
    memcpy(&d->jb, &saved, sizeof saved);
}

static void body_feedback_audit(da *d, const da_args *a, fsql_sb *out) {
    const char *who = "fractal_agent_feedback_audit";
    da_require_not_null(d, a, who, 5, "the first five arguments are required");
    int warmup_count = a_opt_int(a, 5, 8), k = a_opt_int(a, 6, 3);
    fsql_vecd *query = da_vecd(d);
    if (!a_vec(d, a, 2, query)) da_fail(d, "%s: the first five arguments are required", who);
    const char *catalog = a_str(d, a, 0), *emb = a_str(d, a, 1), *warm_table = a_str(d, a, 3), *warm_col = a_str(d, a, 4);
    if (!da_table_has_rows(d, catalog)) da_fail(d, "%s: no catalog rows in %s", who, catalog);
    if (fsql_diversify_enable(d->ctx) == FSQL_OK && d->conn) d->conn->da_diversify = 1;
    {
        fsql_diversify_params_t p;
        if (fsql_diversify_get_params(d->ctx, &p) == FSQL_OK) {
            p.window_n = 5; p.repulsion_sigma = 0.3; p.repulsion_weight = 0.5;
            fsql_diversify_set_params(d->ctx, &p);
        }
    }
    da_warmup(d, who, catalog, emb, warm_table, warm_col, warmup_count, k);
    {
        da_corpus tgt;
        da_scan_corpus(d, who, catalog, emb, false, &tgt, false);
        if (tgt.n_rows > 0) {
            int *idx; double *dist;
            int n = da_topk(d, tgt.flat.p, tgt.n_rows, tgt.dim, query->p, 1, &idx, &dist);
            if (n > 0) (void)fsql_feedback_report(d->ctx, (uint64_t)idx[0], FSQL_ENGAGE_NEGATIVE, 0);
        }
    }
    double dq = fsql_diversify_current_dq(d->ctx);
    if (isnan(dq)) dq = 0.0;
    const char *diag = da_explain_diag(d, d->conn ? d->conn->da_diversify != 0 : false);
    if (fsql_diversify_disable(d->ctx) == FSQL_OK && d->conn) d->conn->da_diversify = 0;
    fsql_sb_printf(out, "{\"diversity_quotient\":%s,\"explanation\":", da_f10(d, dq));
    put_raw_or_string(out, diag);
    fsql_sb_putc(out, '}');
}

/* ------------------------------------------------------------------ */
/* J. fractal_agent_schedule_workload                                   */
/*    (task, node_table, node_emb_col, node_id_col [, iterations [, population [, <unused> [, context]]]]) */
/* ------------------------------------------------------------------ */

static void body_schedule_workload(da *d, const da_args *a, fsql_sb *out) {
    const char *who = "fractal_agent_schedule_workload";
    da_require_not_null(d, a, who, 4, "the first four arguments are required");
    int iterations = a_opt_int(a, 4, 30), population = a_opt_int(a, 5, 50);
    const char *context_json = a_opt_string(d, a, 7, "{}");
    fsql_vecd *task = da_vecd(d);
    if (!a_vec(d, a, 0, task)) da_fail(d, "%s: the first four arguments are required", who);
    const char *table = a_str(d, a, 1), *emb = a_str(d, a, 2), *id_col = a_str(d, a, 3);
    if (!da_table_has_rows(d, table)) da_fail(d, "%s: no node rows in %s", who, table);
    fsql_vecd *refined = da_vecd(d);
    da_refine_best_point(d, task->p, task->len, iterations, population, refined);
    da_hybrid hit;
    da_i64v *cohort = da_i64vec(d);
    da_hybrid_search(d, who, table, emb, refined->p, refined->len, 1, cohort, &hit, false);
    if (hit.locators->n == 0) da_fail(d, "%s: no node rows in %s", who, table);
    double dist = hit.distances->p[0];
    const char *assigned = da_resolve_locator(d, table, id_col, hit.locators->p[0], hit.used_rowid);
    const char *prompt = da_fmt(d, "Schedule this workload onto node %s (cosine distance %s after fractal_search refinement). Justify the placement in one sentence.",
                                *assigned ? assigned : "?", da_f10(d, dist));
    char *rationale, *rerr;
    bool ok = da_try_reasoning(d, FSQL_REASONING_TIER_CHAT, prompt, context_json, &rationale, &rerr);
    double confidence = 1.0 / (1.0 + dist);
    fsql_sb *audit = da_sb(d);
    fsql_sb_puts(audit, "{\"assigned_node\":");
    if (!*assigned) fsql_sb_puts(audit, "null"); else put_json_string(audit, assigned);
    fsql_sb_printf(audit, ",\"confidence\":%s,\"rationale\":", da_f10(d, confidence));
    da_rationale_value(audit, ok, rationale, rerr);
    fsql_sb_putc(audit, '}');
    da_audit(d, "agent_schedule_workload", da_sb_str(d, audit));
    fsql_sb_puts(out, da_sb_str(d, audit));
}

/* ------------------------------------------------------------------ */
/* K. fractal_agent_rebalance_sibling                                   */
/*    (mu, cov, cardinality, alloc_table, alloc_emb_col, baseline [, seed [, <unused> [, id_col [, context]]]]) */
/* ------------------------------------------------------------------ */

static void body_rebalance_sibling(da *d, const da_args *a, fsql_sb *out) {
    const char *who = "fractal_agent_rebalance_sibling";
    da_require_not_null(d, a, who, 6, "the first six arguments are required");
    const char *seed_sql = "0";
    if (a->ncols > 6 && !a_null(a, 6)) seed_sql = da_fmt(d, "%" PRId64, a_i64(a, 6));
    const char *id_col = a_opt_string(d, a, 8, "id"), *context_json = a_opt_string(d, a, 9, "{}");
    fsql_vecd *mu = da_vecd(d), *cov = da_vecd(d), *baseline = da_vecd(d);
    if (!a_vec(d, a, 0, mu) || !a_vec(d, a, 1, cov) || !a_vec(d, a, 5, baseline)) da_fail(d, "%s: the first six arguments are required", who);
    int64_t card = a_i32(a, 2);
    const char *table = a_str(d, a, 3), *emb = a_str(d, a, 4);
    if (!da_table_has_rows(d, table)) da_fail(d, "%s: no allocation rows in %s", who, table);
    da_opt opt = da_compose_optimizer(d, mu, cov, card, seed_sql);
    da_traj_hit traj;
    da_trajectory_nearest(d, who, table, emb, baseline, opt.weights, &traj);
    if (!traj.found) da_fail(d, "%s: no allocation rows in %s", who, table);
    const char *rid = da_resolve_scan_pos(d, table, id_col, traj.doc);
    const char *prompt = da_fmt(d, "Rebalance triage: the optimized portfolio has Sharpe %s and is nearest to historical allocation id %s (cosine distance %s). Justify the rebalance in one sentence.",
                                da_f10(d, opt.sharpe), *rid ? rid : "?", da_f10(d, traj.dist));
    char *rationale, *rerr;
    bool ok = da_try_reasoning(d, FSQL_REASONING_TIER_CHAT, prompt, context_json, &rationale, &rerr);
    fsql_sb *audit = da_sb(d);
    fsql_sb_printf(audit, "{\"sharpe\":%s,\"nearest_alloc_id\":", da_f10(d, opt.sharpe));
    put_id_or_null_json(audit, rid);
    fsql_sb_printf(audit, ",\"nearest_distance\":%s,\"rationale\":", da_f10(d, traj.dist));
    da_rationale_value(audit, ok, rationale, rerr);
    fsql_sb_putc(audit, '}');
    da_audit(d, "agent_rebalance_sibling", da_sb_str(d, audit));
    fsql_sb_printf(out, "{\"sharpe\":%s,\"weights\":", da_f10(d, opt.sharpe));
    put_vec_json(out, opt.weights->p, opt.weights->len);
    fsql_sb_puts(out, ",\"nearest_alloc_id\":");
    put_id_or_null_json(out, rid);
    fsql_sb_printf(out, ",\"nearest_distance\":%s,\"rationale\":", da_f10(d, traj.dist));
    da_rationale_value(out, ok, rationale, rerr);
    fsql_sb_putc(out, '}');
}

/* ------------------------------------------------------------------ */
/* L. fractal_agent_detour_classify                                     */
/*    (vehicle_table, emb_col, baseline, current, gps_trace [, <unused> [, id_col [, boxcount_dim]]]) */
/* ------------------------------------------------------------------ */

static void body_detour_classify(da *d, const da_args *a, fsql_sb *out) {
    const char *who = "fractal_agent_detour_classify";
    da_require_not_null(d, a, who, 5, "the first five arguments are required");
    const char *id_col = a_opt_string(d, a, 6, "id");
    int boxcount_dim = a_opt_int(a, 7, 2);
    fsql_vecd *baseline = da_vecd(d), *current = da_vecd(d), *gps = da_vecd(d);
    if (!a_vec(d, a, 2, baseline) || !a_vec(d, a, 3, current) || !a_vec(d, a, 4, gps)) da_fail(d, "%s: the first five arguments are required", who);
    const char *table = a_str(d, a, 0), *emb = a_str(d, a, 1);
    if (!da_table_has_rows(d, table)) da_fail(d, "%s: no vehicle rows in %s", who, table);
    da_traj_hit traj;
    da_trajectory_nearest(d, who, table, emb, baseline, current, &traj);
    if (!traj.found) da_fail(d, "%s: no vehicle rows in %s", who, table);
    double bc = da_boxcount_of(d, gps->p, gps->len, boxcount_dim);
    const char *rid = da_resolve_scan_pos(d, table, id_col, traj.doc);
    const char *prompt = da_fmt(d, "Detour classify: vehicle %s deviates from its baseline by cosine distance %s (nearest fleet peer); its GPS trace has box-counting dimension %s. Classify the detour in one sentence.",
                                *rid ? rid : "?", da_f10(d, traj.dist), da_f10(d, bc));
    const char *cj = da_fmt(d, "{\"trajectory_distance\":%s,\"trace_complexity\":%s}", da_f10(d, traj.dist), da_f10(d, bc));
    char *rationale, *rerr;
    bool ok = da_try_reasoning(d, FSQL_REASONING_TIER_CHAT, prompt, cj, &rationale, &rerr);
    fsql_sb *audit = da_sb(d);
    fsql_sb_puts(audit, "{\"nearest_fleet_id\":"); put_id_or_null_json(audit, rid);
    fsql_sb_printf(audit, ",\"trajectory_distance\":%s,\"trace_complexity\":%s,\"rationale\":", da_f10(d, traj.dist), da_f10(d, bc));
    da_rationale_value(audit, ok, rationale, rerr);
    fsql_sb_putc(audit, '}');
    da_audit(d, "agent_detour_classify", da_sb_str(d, audit));
    fsql_sb_puts(out, da_sb_str(d, audit));
}

/* ------------------------------------------------------------------ */
/* M. fractal_agent_track_anomaly                                       */
/*    (track_table, emb_col, baseline, current, heading_series [, <unused> [, id_col]]) */
/* ------------------------------------------------------------------ */

static void body_track_anomaly(da *d, const da_args *a, fsql_sb *out) {
    const char *who = "fractal_agent_track_anomaly";
    da_require_not_null(d, a, who, 5, "the first five arguments are required");
    const char *id_col = a_opt_string(d, a, 6, "id");
    fsql_vecd *baseline = da_vecd(d), *current = da_vecd(d), *heading = da_vecd(d);
    if (!a_vec(d, a, 2, baseline) || !a_vec(d, a, 3, current) || !a_vec(d, a, 4, heading)) da_fail(d, "%s: the first five arguments are required", who);
    const char *table = a_str(d, a, 0), *emb = a_str(d, a, 1);
    if (!da_table_has_rows(d, table)) da_fail(d, "%s: no track rows in %s", who, table);
    da_traj_hit traj;
    da_trajectory_nearest(d, who, table, emb, baseline, current, &traj);
    if (!traj.found) da_fail(d, "%s: no track rows in %s", who, table);
    double dfa = da_dfa_of(d, heading->p, heading->len);
    const char *rid = da_resolve_scan_pos(d, table, id_col, traj.doc);
    const char *prompt = da_fmt(d, "Track anomaly: vessel/host %s deviates from baseline by cosine distance %s; its heading-change series has DFA exponent %s (dfa=-1 means insufficient window). Triage the track in one sentence.",
                                *rid ? rid : "?", da_f10(d, traj.dist), da_f10(d, dfa));
    const char *cj = da_fmt(d, "{\"trajectory_distance\":%s,\"dfa_exponent\":%s}", da_f10(d, traj.dist), da_f10(d, dfa));
    char *rationale, *rerr;
    bool ok = da_try_reasoning(d, FSQL_REASONING_TIER_CHAT, prompt, cj, &rationale, &rerr);
    fsql_sb *audit = da_sb(d);
    fsql_sb_puts(audit, "{\"nearest_fleet_id\":"); put_id_or_null_json(audit, rid);
    fsql_sb_printf(audit, ",\"trajectory_distance\":%s,\"dfa_exponent\":%s,\"rationale\":", da_f10(d, traj.dist), da_f10(d, dfa));
    da_rationale_value(audit, ok, rationale, rerr);
    fsql_sb_putc(audit, '}');
    da_audit(d, "agent_track_anomaly", da_sb_str(d, audit));
    fsql_sb_puts(out, da_sb_str(d, audit));
}

/* ------------------------------------------------------------------ */
/* N. fractal_agent_network_coverage_alert                              */
/*    (point_cloud, drift_series [, boxcount_dim [, drift_win [, drift_threshold [, context]]]]) */
/* ------------------------------------------------------------------ */

static void body_network_coverage(da *d, const da_args *a, fsql_sb *out) {
    const char *who = "fractal_agent_network_coverage_alert";
    da_require_not_null(d, a, who, 2, "point_cloud and drift_series are required");
    int boxcount_dim = a_opt_int(a, 2, 2), drift_win = a_opt_int(a, 3, 48);
    double threshold = a_opt_double(a, 4, 0.5);
    const char *context_json = a_opt_string(d, a, 5, "{}");
    fsql_vecd *points = da_vecd(d), *series = da_vecd(d);
    if (!a_vec(d, a, 0, points) || !a_vec(d, a, 1, series)) da_fail(d, "%s: point_cloud and drift_series are required", who);
    double md = 0.0, lac = 0.0;
    da_morphology_of(d, points->p, points->len, boxcount_dim, &md, &lac);
    da_drift dr = da_drift_of(d, series->p, series->len, drift_win);
    bool dd = fabs(dr.drift) > threshold;
    const char *prompt = da_fmt(d, "Network coverage alert: the sensor grid has morphological dimension %s and lacunarity %s; the telemetry drift is %s (drift_detected=%s, threshold %s). Issue the coverage alert in one sentence.",
                                da_f10(d, md), da_f10(d, lac), da_f10(d, dr.drift), dd ? "true" : "false", da_f10(d, threshold));
    char *rationale, *rerr;
    bool ok = da_try_reasoning(d, FSQL_REASONING_TIER_CHAT, prompt, context_json, &rationale, &rerr);
    fsql_sb *audit = da_sb(d);
    fsql_sb_printf(audit, "{\"morph_dimension\":%s,\"lacunarity\":%s,\"drift_detected\":%s,\"rationale\":", da_f10(d, md), da_f10(d, lac), dd ? "true" : "false");
    da_rationale_value(audit, ok, rationale, rerr);
    fsql_sb_putc(audit, '}');
    da_audit(d, "agent_network_coverage_alert", da_sb_str(d, audit));
    fsql_sb_puts(out, da_sb_str(d, audit));
}

/* ------------------------------------------------------------------ */
/* O. fractal_agent_regime_triage (series [, win [, drift_threshold [, context]]]) */
/* ------------------------------------------------------------------ */

static void body_regime_triage(da *d, const da_args *a, fsql_sb *out) {
    const char *who = "fractal_agent_regime_triage";
    if (a_null(a, 0)) da_fail(d, "%s: series is required", who);
    int64_t win = a_opt_int(a, 1, 64);
    double threshold = a_opt_double(a, 2, 0.5);
    const char *context_json = a_opt_string(d, a, 3, "{}");
    fsql_vecd *series = da_vecd(d);
    if (!a_vec(d, a, 0, series)) da_fail(d, "%s: series is required", who);
    double dfa = da_dfa_of(d, series->p, series->len);
    da_drift dr = da_drift_of(d, series->p, series->len, win);
    bool dd = fabs(dr.drift) > threshold;
    const char *prompt = da_fmt(d, "Regime triage: the series has DFA exponent %s and drift %s (drift_detected=%s, recent_alpha=%s, baseline_alpha=%s). Triage the regime change in one sentence.",
                                da_f10(d, dfa), da_f10(d, dr.drift), dd ? "true" : "false", da_f10(d, dr.recent_alpha), da_f10(d, dr.baseline_alpha));
    char *rationale, *rerr;
    bool ok = da_try_reasoning(d, FSQL_REASONING_TIER_CHAT, prompt, context_json, &rationale, &rerr);
    fsql_sb *audit = da_sb(d);
    fsql_sb_printf(audit, "{\"dfa_exponent\":%s,\"drift_detected\":%s,\"drift\":%s,\"rationale\":", da_f10(d, dfa), dd ? "true" : "false", da_f10(d, dr.drift));
    da_rationale_value(audit, ok, rationale, rerr);
    fsql_sb_putc(audit, '}');
    da_audit(d, "agent_regime_triage", da_sb_str(d, audit));
    fsql_sb_printf(out, "{\"dfa_exponent\":%s,\"drift_detected\":%s,\"recent_alpha\":%s,\"baseline_alpha\":%s,\"rationale\":", da_f10(d, dfa),
                   dd ? "true" : "false", da_f10(d, dr.recent_alpha), da_f10(d, dr.baseline_alpha));
    da_rationale_value(out, ok, rationale, rerr);
    fsql_sb_putc(out, '}');
}

/* ------------------------------------------------------------------ */
/* P. fractal_agent_diverse_portfolios                                  */
/*    (mu, cov, cardinality [, n_restarts [, overlap [, quality [, <unused> [, context [, objective_mode]]]]]]) */
/* ------------------------------------------------------------------ */

typedef struct { double sharpe, ret, risk; fsql_vecd *weights; } da_cand;

static void body_diverse_portfolios(da *d, const da_args *a, fsql_sb *out) {
    const char *who = "fractal_agent_diverse_portfolios";
    da_require_not_null(d, a, who, 3, "mu, cov, cardinality are required");
    int n_restarts = a_opt_int(a, 3, 8);
    double overlap = a_opt_double(a, 4, 0.15), quality = a_opt_double(a, 5, 0.90);
    const char *context_json = a_opt_string(d, a, 7, "{}"), *mode = a_opt_string(d, a, 8, "sharpe");
    fsql_vecd *mu = da_vecd(d), *cov = da_vecd(d);
    if (!a_vec(d, a, 0, mu) || !a_vec(d, a, 1, cov)) da_fail(d, "%s: mu, cov, cardinality are required", who);
    int64_t card = a_i32(a, 2);
    bool is_pareto = !strcmp(mode, "pareto");
    if (!is_pareto && strcmp(mode, "sharpe")) da_fail(d, "fractal_agent_diverse_portfolios: objective_mode must be 'sharpe' or 'pareto' (got %s)", mode);

    fsql_sb *s = da_sb(d);
    const char *mul = da_vec_literal(d, mu->p, mu->len), *covl = da_vec_literal(d, cov->p, cov->len);
    if (is_pareto)
        fsql_sb_printf(s, "SELECT \"return\", risk, sharpe, weights FROM fractal_optimize_portfolio_multimodal_pareto(%s, %s, %" PRId64 ", n_restarts := %d, max_front := %d)",
                       mul, covl, card, n_restarts, n_restarts);
    else
        fsql_sb_printf(s, "SELECT sharpe, weights FROM fractal_optimize_portfolio_multimodal(%s, %s, %" PRId64 ", n_restarts := %d, overlap_threshold := %s, quality_frac := %s)",
                       mul, covl, card, n_restarts, da_f10(d, overlap), da_f10(d, quality));
    fsql_qres *q = da_query(d, da_sb_str(d, s));
    da_cand *cands = NULL; size_t nc = 0, capc = 0;
    for (duckdb_data_chunk ch = fsql_qres_next_chunk(q); ch; ch = fsql_qres_next_chunk(q)) {
        idx_t rows = duckdb_data_chunk_get_size(ch);
        if (rows == 0) { duckdb_destroy_data_chunk(&ch); break; }
        int col = 0;
        const double *ret = NULL, *risk = NULL;
        if (is_pareto) {
            ret = (const double *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(ch, (idx_t)col++));
            risk = (const double *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(ch, (idx_t)col++));
        }
        const double *sharpe = (const double *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(ch, (idx_t)col++));
        duckdb_vector wv = duckdb_data_chunk_get_vector(ch, (idx_t)col);
        fsql_vkind kind;
        if (fsql_vkind_of(wv, &kind)) { duckdb_destroy_data_chunk(&ch); free(cands); da_fail(d, "%s: unexpected weights column type", who); }
        for (idx_t r = 0; r < rows; r++) {
            fsql_vecd *w = da_vecd(d);
            size_t len;
            if (fsql_read_vec_row(wv, &kind, r, w, &len) != 1) continue;
            if (nc == capc) {
                size_t n2 = capc ? capc * 2 : 16;
                da_cand *np = (da_cand *)realloc(cands, n2 * sizeof *np);
                if (!np) { duckdb_destroy_data_chunk(&ch); free(cands); da_fail(d, "fractalsql: out of memory"); }
                cands = np; capc = n2;
            }
            da_cand c = { sharpe[r], ret ? ret[r] : 0.0, risk ? risk[r] : 0.0, w };
            cands[nc++] = c;
        }
        duckdb_destroy_data_chunk(&ch);
    }
    da_track(d, cands, free);
    if (nc == 0) da_fail(d, "fractal_agent_diverse_portfolios: no candidates found");

    fsql_sb *opt = da_sb(d);
    fsql_sb_printf(opt, "{\"n_found\":%zu,\"candidates\":[", nc);
    for (size_t i = 0; i < nc; i++) {
        if (i) fsql_sb_putc(opt, ',');
        fsql_sb_puts(opt, "{\"sharpe\":"); put_number_json(opt, cands[i].sharpe);
        fsql_sb_puts(opt, ",\"weights\":"); put_vec_json(opt, cands[i].weights->p, cands[i].weights->len);
        if (is_pareto) {
            fsql_sb_puts(opt, ",\"return\":"); put_number_json(opt, cands[i].ret);
            fsql_sb_puts(opt, ",\"risk\":"); put_number_json(opt, cands[i].risk);
        }
        fsql_sb_putc(opt, '}');
    }
    fsql_sb_puts(opt, "]}");
    const char *head = is_pareto
        ? da_fmt(d, "Found %zu Pareto-optimal (non-dominated return-vs-risk) portfolios. Summarize in one paragraph the return/risk tradeoffs a portfolio manager should weigh between these options. Candidates: ", nc)
        : da_fmt(d, "Found %zu structurally distinct portfolios. Summarize in one paragraph the strategic tradeoffs a portfolio manager should weigh between these options. Candidates: ", nc);
    const char *prompt = da_fmt(d, "%s%s", head, da_sb_str(d, opt));
    char *rationale, *rerr;
    bool ok = da_try_reasoning(d, FSQL_REASONING_TIER_CHAT, prompt, context_json, &rationale, &rerr);
    fsql_sb *audit = da_sb(d);
    fsql_sb_puts(audit, "{\"objective_mode\":"); put_json_string(audit, mode);
    fsql_sb_printf(audit, ",\"n_found\":%zu,\"cardinality\":%" PRId64 ",\"rationale\":", nc, card);
    da_rationale_value(audit, ok, rationale, rerr);
    fsql_sb_putc(audit, '}');
    da_audit(d, "agent_diverse_portfolios", da_sb_str(d, audit));
    fsql_sb_putc(out, '[');
    for (size_t i = 0; i < nc; i++) {
        if (i) fsql_sb_putc(out, ',');
        fsql_sb_printf(out, "{\"candidate_id\":%lld,\"sharpe\":%s,\"weights\":", (long long)i, da_f10(d, cands[i].sharpe));
        if (is_pareto) {
            fsql_sb_puts(out, "{\"weights\":"); put_vec_json(out, cands[i].weights->p, cands[i].weights->len);
            fsql_sb_puts(out, ",\"return\":"); put_number_json(out, cands[i].ret);
            fsql_sb_puts(out, ",\"risk\":"); put_number_json(out, cands[i].risk);
            fsql_sb_putc(out, '}');
        } else put_vec_json(out, cands[i].weights->p, cands[i].weights->len);
        fsql_sb_puts(out, ",\"rationale\":");
        da_rationale_value(out, ok, rationale, rerr);
        fsql_sb_putc(out, '}');
    }
    fsql_sb_putc(out, ']');
}

/* ------------------------------------------------------------------ */
/* Registration                                                         */
/* ------------------------------------------------------------------ */

#define DA_ENTRY(fn)                                                                   \
    static void fn##_scalar(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) { da_run_engine(info, in, out, body_##fn); }

DA_ENTRY(anomaly_triage) DA_ENTRY(allocate) DA_ENTRY(route_task) DA_ENTRY(outlier_intercept) DA_ENTRY(recall_hybrid)
DA_ENTRY(recommend_diverse) DA_ENTRY(data_analyst) DA_ENTRY(patient_triage) DA_ENTRY(feedback_audit) DA_ENTRY(schedule_workload)
DA_ENTRY(rebalance_sibling) DA_ENTRY(detour_classify) DA_ENTRY(track_anomaly) DA_ENTRY(network_coverage) DA_ENTRY(regime_triage)
DA_ENTRY(diverse_portfolios)

#define T FSQL_T_VARCHAR
#define VEC FSQL_T_LIST_DOUBLE
#define IDS FSQL_T_LIST_BIGINT
#define LST FSQL_T_LIST_VARCHAR
#define INT FSQL_T_INTEGER
#define BIG FSQL_T_BIGINT
#define DBL FSQL_T_DOUBLE
#define BOOL FSQL_T_BOOLEAN
#define ENG(name, n, fn, ...) { name, n, { __VA_ARGS__ }, T, fn##_scalar, fsql_bind_capture_conn, FSQL_FN_SPECIAL_NULL }

static const fsql_scalar_def kDomainDefs[] = {
    ENG("fractal_agent_anomaly_triage", 5, anomaly_triage, T, T, T, T, T),
    ENG("fractal_agent_anomaly_triage", 6, anomaly_triage, T, T, T, T, T, INT),
    ENG("fractal_agent_allocate", 3, allocate, VEC, VEC, INT),
    ENG("fractal_agent_allocate", 4, allocate, VEC, VEC, INT, T),
    ENG("fractal_agent_route_task", 5, route_task, VEC, T, T, T, INT),
    ENG("fractal_agent_route_task", 6, route_task, VEC, T, T, T, INT, INT),
    ENG("fractal_agent_outlier_intercept", 4, outlier_intercept, VEC, T, T, DBL),
    ENG("fractal_agent_outlier_intercept", 5, outlier_intercept, VEC, T, T, DBL, T),
    ENG("fractal_agent_recall_hybrid", 3, recall_hybrid, T, T, VEC),
    ENG("fractal_agent_recall_hybrid", 4, recall_hybrid, T, T, VEC, T),
    ENG("fractal_agent_recall_hybrid", 5, recall_hybrid, T, T, VEC, T, T),
    ENG("fractal_agent_recall_hybrid", 6, recall_hybrid, T, T, VEC, T, T, INT),
    ENG("fractal_agent_recall_hybrid", 7, recall_hybrid, T, T, VEC, T, T, INT, T),
    ENG("fractal_agent_recall_hybrid", 8, recall_hybrid, T, T, VEC, T, T, INT, T, T),
    ENG("fractal_agent_recommend_diverse", 3, recommend_diverse, T, T, VEC),
    ENG("fractal_agent_recommend_diverse", 4, recommend_diverse, T, T, VEC, INT),
    ENG("fractal_agent_recommend_diverse", 5, recommend_diverse, T, T, VEC, INT, T),
    ENG("fractal_agent_data_analyst", 1, data_analyst, T),
    ENG("fractal_agent_data_analyst", 2, data_analyst, T, LST),
    ENG("fractal_agent_data_analyst", 3, data_analyst, T, LST, INT),
    ENG("fractal_agent_data_analyst", 4, data_analyst, T, LST, INT, T),
    ENG("fractal_agent_data_analyst", 5, data_analyst, T, LST, INT, T, BOOL),
    ENG("fractal_agent_patient_deterioration_triage", 5, patient_triage, T, T, VEC, VEC, VEC),
    ENG("fractal_agent_patient_deterioration_triage", 6, patient_triage, T, T, VEC, VEC, VEC, IDS),
    ENG("fractal_agent_patient_deterioration_triage", 7, patient_triage, T, T, VEC, VEC, VEC, IDS, INT),
    ENG("fractal_agent_patient_deterioration_triage", 8, patient_triage, T, T, VEC, VEC, VEC, IDS, INT, T),
    ENG("fractal_agent_feedback_audit", 5, feedback_audit, T, T, VEC, T, T),
    ENG("fractal_agent_feedback_audit", 6, feedback_audit, T, T, VEC, T, T, INT),
    ENG("fractal_agent_feedback_audit", 7, feedback_audit, T, T, VEC, T, T, INT, INT),
    ENG("fractal_agent_schedule_workload", 4, schedule_workload, VEC, T, T, T),
    ENG("fractal_agent_schedule_workload", 5, schedule_workload, VEC, T, T, T, INT),
    ENG("fractal_agent_schedule_workload", 6, schedule_workload, VEC, T, T, T, INT, INT),
    ENG("fractal_agent_schedule_workload", 7, schedule_workload, VEC, T, T, T, INT, INT, INT),
    ENG("fractal_agent_schedule_workload", 8, schedule_workload, VEC, T, T, T, INT, INT, INT, T),
    ENG("fractal_agent_rebalance_sibling", 6, rebalance_sibling, VEC, VEC, INT, T, T, VEC),
    ENG("fractal_agent_rebalance_sibling", 7, rebalance_sibling, VEC, VEC, INT, T, T, VEC, BIG),
    ENG("fractal_agent_rebalance_sibling", 8, rebalance_sibling, VEC, VEC, INT, T, T, VEC, BIG, INT),
    ENG("fractal_agent_rebalance_sibling", 9, rebalance_sibling, VEC, VEC, INT, T, T, VEC, BIG, INT, T),
    ENG("fractal_agent_rebalance_sibling", 10, rebalance_sibling, VEC, VEC, INT, T, T, VEC, BIG, INT, T, T),
    ENG("fractal_agent_detour_classify", 5, detour_classify, T, T, VEC, VEC, VEC),
    ENG("fractal_agent_detour_classify", 6, detour_classify, T, T, VEC, VEC, VEC, INT),
    ENG("fractal_agent_detour_classify", 7, detour_classify, T, T, VEC, VEC, VEC, INT, T),
    ENG("fractal_agent_detour_classify", 8, detour_classify, T, T, VEC, VEC, VEC, INT, T, INT),
    ENG("fractal_agent_track_anomaly", 5, track_anomaly, T, T, VEC, VEC, VEC),
    ENG("fractal_agent_track_anomaly", 6, track_anomaly, T, T, VEC, VEC, VEC, INT),
    ENG("fractal_agent_track_anomaly", 7, track_anomaly, T, T, VEC, VEC, VEC, INT, T),
    ENG("fractal_agent_network_coverage_alert", 2, network_coverage, VEC, VEC),
    ENG("fractal_agent_network_coverage_alert", 3, network_coverage, VEC, VEC, INT),
    ENG("fractal_agent_network_coverage_alert", 4, network_coverage, VEC, VEC, INT, INT),
    ENG("fractal_agent_network_coverage_alert", 5, network_coverage, VEC, VEC, INT, INT, DBL),
    ENG("fractal_agent_network_coverage_alert", 6, network_coverage, VEC, VEC, INT, INT, DBL, T),
    ENG("fractal_agent_regime_triage", 1, regime_triage, VEC),
    ENG("fractal_agent_regime_triage", 2, regime_triage, VEC, INT),
    ENG("fractal_agent_regime_triage", 3, regime_triage, VEC, INT, DBL),
    ENG("fractal_agent_regime_triage", 4, regime_triage, VEC, INT, DBL, T),
    ENG("fractal_agent_diverse_portfolios", 3, diverse_portfolios, VEC, VEC, INT),
    ENG("fractal_agent_diverse_portfolios", 4, diverse_portfolios, VEC, VEC, INT, INT),
    ENG("fractal_agent_diverse_portfolios", 5, diverse_portfolios, VEC, VEC, INT, INT, DBL),
    ENG("fractal_agent_diverse_portfolios", 6, diverse_portfolios, VEC, VEC, INT, INT, DBL, DBL),
    ENG("fractal_agent_diverse_portfolios", 7, diverse_portfolios, VEC, VEC, INT, INT, DBL, DBL, BIG),
    ENG("fractal_agent_diverse_portfolios", 8, diverse_portfolios, VEC, VEC, INT, INT, DBL, DBL, BIG, T),
    ENG("fractal_agent_diverse_portfolios", 9, diverse_portfolios, VEC, VEC, INT, INT, DBL, DBL, BIG, T, T),
};

bool fsql_domain_agents_register(duckdb_connection con, const char **err) {
    return fsql_register_scalars(con, kDomainDefs, (int)(sizeof kDomainDefs / sizeof kDomainDefs[0]), err);
}
