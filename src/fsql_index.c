/* src/fsql_index.c -- the native IVF index (fractal_index_*) and the indexed fractal_search for DuckDB.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * The core does the maths (k-means cells, INT8 / INT4 / FP16 / FP32 codes, candidate search, recall
 * estimation -- fsql_ivf_*); this file owns the storage and the SQL surface:
 *
 *   fractal_index_create(table, column [, options]) -> VARCHAR (JSON)  build and store an index
 *   fractal_index_rebuild(name)                     -> VARCHAR (JSON)  full rebuild from the current rows
 *   fractal_index_drop(name)                        -> BIGINT          1 when dropped
 *   fractal_index_info(name)                        -> VARCHAR (JSON)  format, sizes, staleness, calibration, stats
 *   fractal_search(table, column, query, k [, options]) -> VARCHAR (JSON array of {doc_id, distance, scan_pos})
 *                                                       indexed approximate search; exact scan when no index exists
 *   fractal_index_candidates(table, column, query [, options]) -> VARCHAR (JSON array of row ids) for Scout
 *
 * Storage (ordinary tables, so they travel with the database file):
 *   fractal_index_meta(name PRIMARY KEY, tbl, col, dim, metric, format, nlist, pca_dim, rows, max_id,
 *                      model, seed, generation, format_version, options, built_at, nprobe_default, calib,
 *                      model_blob, id_col)
 *   fractal_index_cells(name, generation, cell, n, ids BIGINT[], codes VARCHAR[])   one row per cell
 * A build writes a NEW generation: the cell rows are written first and the metadata pointer is flipped
 * in ONE statement afterwards, so a reader only ever sees a complete generation (the nested query pool
 * gives each statement its own autocommit frame, so the multi-step write is NOT one transaction).
 *
 * THE BUILD STREAMS. The corpus is never held in memory: pass one feeds the k-means/PCA trainer from a
 * reservoir inside the core, pass two encodes every row and writes it straight into a staging table, and
 * the staging table is folded into the per-cell rows by the engine (a GROUP BY with ordered list
 * aggregates). Only one batch of rows is in flight at a time.
 *
 * The delta rule is "committed rows only": the nested query runs on a pooled connection in its own
 * autocommit frame, so rows written in the caller's still-open transaction are invisible to it. A row
 * whose id is greater than the largest indexed id is treated as newer than the index and scanned exactly.
 *
 * The row id is a stable primary key (option id_col; by default the table's single-column PRIMARY KEY).
 * DuckDB's rowid is NOT stable, so it is never used as an id.
 *
 * Every candidate is verified: the shortlist rows are fetched, deleted rows dropped, exact double cosine
 * distances computed with the one shared implementation (fsql_precision.h) and ordered by distance then
 * row id. The index never returns an approximate distance as an answer. Indexed fractal_search does not
 * apply Diversify repulsion (there is no repulsion in this host's search surface at all).
 */

#include <ctype.h>
#include <inttypes.h>
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_duckdb_internal.h"
#include "fsql_precision.h"

#define ERRCAP            4096
#define FI_MAXDIM         8192
#define FI_MAX_CACHED     8
#define FI_MAX_CELLS_BYTES ((size_t)1 << 30)   /* 1 GiB: the resident index cap */
#define FI_CALIB_BYTES    ((size_t)1 << 28)     /* 256 MiB: the corpus + codes the calibration may hold */
#define FI_FORMAT_VERSION 1
#define FI_STAGE_BATCH    256

#define FI_NO_IVF_MSG \
    "fractalsql: this build of fractalsql-core does not carry the IVF index " \
    "(rebuild the core and refresh include/<platform>)"

/* ------------------------------------------------------------------ */
/* The weak-symbol guard (see the host brief, section 2.1)             */
/* ------------------------------------------------------------------ */
/* The vendored core archive in include/<platform>/ must carry the IVF symbols. The linker extracts
 * an archive member only to resolve an undefined STRONG reference, so a weak reference would leave
 * the symbol NULL -- the index would then be silently unavailable even with a fresh archive. The
 * references below are therefore strong. A build against a core that predates the index opts out
 * explicitly (FSQL_HAVE_IVF off, FSQL_NO_IVF on): there the whole IVF surface is compiled out and
 * every index function reports the same message, so the SQL surface is identical on every platform. */

#if defined(FSQL_HAVE_IVF) || (defined(__GNUC__) && !defined(_WIN32))
#  define FI_IVF_HARD 1
#else
#  define FI_IVF_NONE 1
#endif

#if defined(FI_IVF_HARD)
#  define FSQL_IVF_WEAK
extern FSQL_IVF_WEAK fsql_ivf_trainer *fsql_ivf_trainer_new(const fsql_ivf_options_t *opt, int *rc_out);
extern FSQL_IVF_WEAK int   fsql_ivf_trainer_add(fsql_ivf_trainer *t, const float *vecs, size_t count);
extern FSQL_IVF_WEAK int   fsql_ivf_trainer_finish(fsql_ivf_trainer *t, uint8_t **model_out, size_t *model_len_out);
extern FSQL_IVF_WEAK void  fsql_ivf_trainer_free(fsql_ivf_trainer *t);
extern FSQL_IVF_WEAK fsql_ivf_model *fsql_ivf_model_load(const uint8_t *blob, size_t len, int *rc_out);
extern FSQL_IVF_WEAK void  fsql_ivf_model_free(fsql_ivf_model *m);
extern FSQL_IVF_WEAK int   fsql_ivf_model_info(const fsql_ivf_model *m, fsql_ivf_info_t *out);
extern FSQL_IVF_WEAK void  fsql_ivf_free(void *p);
extern FSQL_IVF_WEAK int   fsql_ivf_encode(const fsql_ivf_model *m, const float *vec, uint32_t *cell_out, uint8_t *code_out);
extern FSQL_IVF_WEAK int   fsql_ivf_normalize(const float *in, size_t dim, float *out);
extern FSQL_IVF_WEAK fsql_ivf_index *fsql_ivf_index_new(const fsql_ivf_model *m);
extern FSQL_IVF_WEAK void  fsql_ivf_index_free(fsql_ivf_index *x);
extern FSQL_IVF_WEAK int   fsql_ivf_index_set_cell(fsql_ivf_index *x, uint32_t cell, const int64_t *ids, const uint8_t *codes, size_t n);
extern FSQL_IVF_WEAK int   fsql_ivf_index_cell_rows(const fsql_ivf_index *x, uint32_t cell, uint64_t *n_out);
extern FSQL_IVF_WEAK uint64_t fsql_ivf_index_rows(const fsql_ivf_index *x);
extern FSQL_IVF_WEAK int   fsql_ivf_probe_cells(const fsql_ivf_model *m, const float *query, uint32_t nprobe, uint32_t *cells_out, uint32_t *n_out);
extern FSQL_IVF_WEAK int   fsql_ivf_search(const fsql_ivf_index *x, const float *query, uint32_t nprobe, uint32_t shortlist,
                                          int64_t *ids_out, double *dist_out, size_t *n_out, fsql_ivf_stats_t *stats_out);
extern FSQL_IVF_WEAK int   fsql_ivf_sample_rows(uint64_t n_rows, uint32_t count, uint64_t seed, uint64_t *out);
extern FSQL_IVF_WEAK int   fsql_ivf_exact_topk(const float *corpus_n, const int64_t *ids, size_t n, size_t dim, const float *query_n,
                                                int64_t self_id, int use_self, uint32_t k, int64_t *out_ids, size_t *n_out);
extern FSQL_IVF_WEAK int   fsql_ivf_estimate_recall(const fsql_ivf_index *x, const float *queries, const int64_t *self_ids,
                                                     const int64_t *truth, size_t nq, uint32_t k, const uint32_t *nprobes, size_t nnp,
                                                     uint32_t shortlist, double target, double *mean_out, double *se_out, double *lo_out,
                                                     double *scanned_out, uint32_t *recommended_out);
#endif /* FI_IVF_HARD */

/* The call sites always go through these names, so the compiled-out build needs no #ifdefs. */
#if defined(FI_IVF_HARD)
#  define fi_ivf_trainer_new        fsql_ivf_trainer_new
#  define fi_ivf_trainer_add         fsql_ivf_trainer_add
#  define fi_ivf_trainer_finish      fsql_ivf_trainer_finish
#  define fi_ivf_trainer_free        fsql_ivf_trainer_free
#  define fi_ivf_model_load          fsql_ivf_model_load
#  define fi_ivf_model_free          fsql_ivf_model_free
#  define fi_ivf_model_info          fsql_ivf_model_info
#  define fi_ivf_free                fsql_ivf_free
#  define fi_ivf_encode              fsql_ivf_encode
#  define fi_ivf_normalize           fsql_ivf_normalize
#  define fi_ivf_index_new           fsql_ivf_index_new
#  define fi_ivf_index_free          fsql_ivf_index_free
#  define fi_ivf_index_set_cell      fsql_ivf_index_set_cell
#  define fi_ivf_index_cell_rows     fsql_ivf_index_cell_rows
#  define fi_ivf_index_rows          fsql_ivf_index_rows
#  define fi_ivf_probe_cells         fsql_ivf_probe_cells
#  define fi_ivf_search              fsql_ivf_search
#  define fi_ivf_sample_rows         fsql_ivf_sample_rows
#  define fi_ivf_exact_topk          fsql_ivf_exact_topk
#  define fi_ivf_estimate_recall     fsql_ivf_estimate_recall
#else
/* compiled-out stubs: the same signatures, so nothing above changes */
static fsql_ivf_trainer *fi_ivf_trainer_new(const fsql_ivf_options_t *o, int *rc) { (void)o; if (rc) *rc = FSQL_ERR_INVALID; return NULL; }
static int   fi_ivf_trainer_add(fsql_ivf_trainer *t, const float *v, size_t c) { (void)t; (void)v; (void)c; return FSQL_ERR_INVALID; }
static int   fi_ivf_trainer_finish(fsql_ivf_trainer *t, uint8_t **m, size_t *l) { (void)t; (void)m; (void)l; return FSQL_ERR_INVALID; }
static void  fi_ivf_trainer_free(fsql_ivf_trainer *t) { (void)t; }
static fsql_ivf_model *fi_ivf_model_load(const uint8_t *b, size_t l, int *rc) { (void)b; (void)l; if (rc) *rc = FSQL_ERR_INVALID; return NULL; }
static void  fi_ivf_model_free(fsql_ivf_model *m) { (void)m; }
static int   fi_ivf_model_info(const fsql_ivf_model *m, fsql_ivf_info_t *o) { (void)m; (void)o; return FSQL_ERR_INVALID; }
static void  fi_ivf_free(void *p) { (void)p; }
static int   fi_ivf_encode(const fsql_ivf_model *m, const float *v, uint32_t *c, uint8_t *code) { (void)m; (void)v; (void)c; (void)code; return FSQL_ERR_INVALID; }
static int   fi_ivf_normalize(const float *i, size_t d, float *o) { (void)i; (void)d; (void)o; return FSQL_ERR_INVALID; }
static fsql_ivf_index *fi_ivf_index_new(const fsql_ivf_model *m) { (void)m; return NULL; }
static void  fi_ivf_index_free(fsql_ivf_index *x) { (void)x; }
static int   fi_ivf_index_set_cell(fsql_ivf_index *x, uint32_t c, const int64_t *ids, const uint8_t *codes, size_t n) { (void)x; (void)c; (void)ids; (void)codes; (void)n; return FSQL_ERR_INVALID; }
static int   fi_ivf_index_cell_rows(const fsql_ivf_index *x, uint32_t c, uint64_t *n) { (void)x; (void)c; (void)n; return FSQL_ERR_INVALID; }
static uint64_t fi_ivf_index_rows(const fsql_ivf_index *x) { (void)x; return 0; }
static int   fi_ivf_probe_cells(const fsql_ivf_model *m, const float *q, uint32_t np, uint32_t *c, uint32_t *n) { (void)m; (void)q; (void)np; (void)c; (void)n; return FSQL_ERR_INVALID; }
static int   fi_ivf_search(const fsql_ivf_index *x, const float *q, uint32_t np, uint32_t sl, int64_t *ids, double *d, size_t *n, fsql_ivf_stats_t *s) { (void)x; (void)q; (void)np; (void)sl; (void)ids; (void)d; (void)n; (void)s; return FSQL_ERR_INVALID; }
static int   fi_ivf_sample_rows(uint64_t nr, uint32_t c, uint64_t seed, uint64_t *o) { (void)nr; (void)c; (void)seed; (void)o; return FSQL_ERR_INVALID; }
static int   fi_ivf_exact_topk(const float *c, const int64_t *ids, size_t n, size_t d, const float *q, int64_t self, int us, uint32_t k, int64_t *o, size_t *no) { (void)c; (void)ids; (void)n; (void)d; (void)q; (void)self; (void)us; (void)k; (void)o; (void)no; return FSQL_ERR_INVALID; }
static int   fi_ivf_estimate_recall(const fsql_ivf_index *x, const float *q, const int64_t *s, const int64_t *t, size_t nq, uint32_t k, const uint32_t *np, size_t nnp, uint32_t sl, double target, double *m, double *se, double *lo, double *sc, uint32_t *rec) { (void)x; (void)q; (void)s; (void)t; (void)nq; (void)k; (void)np; (void)nnp; (void)sl; (void)target; (void)m; (void)se; (void)lo; (void)sc; (void)rec; return FSQL_ERR_INVALID; }
#endif

/* True when this build of the core actually carries the IVF index. */
static int fi_ivf_available(void)
{
#if defined(FI_IVF_HARD)
    return 1;
#else
    return 0;
#endif
}

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
/* ------------------------------------------------------------------ */

static const char *const FI_FMT_NAME[4] = { "INT8", "INT4", "FP16", "FP32" };

static int fi_parse_fmt(const char *s)
{
    int i;
    for (i = 0; i < 4; i++) if (s && !strcmp(s, FI_FMT_NAME[i])) return i;
    return -1;
}

static size_t fi_default_rerank(int fmt) { return fmt == FSQL_IVF_FMT_INT4 ? 40u : (fmt == FSQL_IVF_FMT_INT8 ? 30u : 0u); }

/* --- identifiers ---------------------------------------------------- */

#define FI_IDENT_MAX_SEGMENT 63
#define FI_IDENT_MAX_TOTAL   256

typedef struct { char seg[3][FI_IDENT_MAX_SEGMENT + 1]; int n; } fi_ident;

static int fi_ident_char_ok(char c, int first)
{
    return c == '_' || isalpha((unsigned char)c) || (!first && isdigit((unsigned char)c));
}

/* Splits on '.'; n is the TOTAL segment count (only the first three are kept). */
static int fi_split_ident(const char *s, fi_ident *o)
{
    size_t len, i, sl = 0;
    char cur[FI_IDENT_MAX_SEGMENT + 1];
    if (!s) return -1;
    len = strlen(s);
    if (len == 0 || len > FI_IDENT_MAX_TOTAL) return -1;
    o->n = 0;
    for (i = 0; i < len; i++) {
        char c = s[i];
        if (c == '.') {
            if (sl == 0) return -1;
            cur[sl] = 0;
            if (o->n < 3) memcpy(o->seg[o->n], cur, sl + 1);
            o->n++; sl = 0;
            continue;
        }
        if (!fi_ident_char_ok(c, sl == 0)) return -1;
        if (sl >= FI_IDENT_MAX_SEGMENT) return -1;
        cur[sl++] = c;
    }
    if (sl == 0) return -1;
    cur[sl] = 0;
    if (o->n < 3) memcpy(o->seg[o->n], cur, sl + 1);
    o->n++;
    return 0;
}

static void fi_put_segments(fsql_sb *b, const fi_ident *id)
{
    int k = id->n < 3 ? id->n : 3, i;
    for (i = 0; i < k; i++) { if (i) fsql_sb_putc(b, '.'); fsql_sb_putc(b, '"'); fsql_sb_puts(b, id->seg[i]); fsql_sb_putc(b, '"'); }
}

/* A table may be schema-qualified (two segments); a column may not. */
static int fi_quote_table(const char *s, fsql_sb *b, char *err)
{
    fi_ident id;
    if (fi_split_ident(s, &id) != 0 || id.n > 2) {
        snprintf(err, ERRCAP, "fractalsql: invalid table identifier: %s", s ? s : "(null)");
        return -1;
    }
    fi_put_segments(b, &id);
    return 0;
}

static int fi_quote_column(const char *s, fsql_sb *b, char *err)
{
    fi_ident id;
    if (fi_split_ident(s, &id) != 0 || id.n != 1) {
        snprintf(err, ERRCAP, "fractalsql: invalid column identifier: %s", s ? s : "(null)");
        return -1;
    }
    fi_put_segments(b, &id);
    return 0;
}

/* A SQL string literal. */
static void fi_put_lit(fsql_sb *b, const char *s)
{
    fsql_sb_putc(b, '\'');
    for (; s && *s; s++) {
        if (*s == '\'') fsql_sb_putc(b, '\'');
        fsql_sb_putc(b, *s);
    }
    fsql_sb_putc(b, '\'');
}

/* --- hex ------------------------------------------------------------ */

static void fi_hex(const uint8_t *p, size_t n, char *out)
{
    static const char *d = "0123456789abcdef";
    size_t i;
    for (i = 0; i < n; i++) { out[2 * i] = d[p[i] >> 4]; out[2 * i + 1] = d[p[i] & 15]; }
    out[2 * n] = 0;
}

static int fi_unhex(const char *s, uint8_t *out, size_t n)
{
    size_t i;
    if (!s) return -1;
    for (i = 0; i < n; i++) {
        int hi = -1, lo = -1, j;
        for (j = 0; j < 2; j++) {
            char c = s[2 * i + j];
            int v;
            if (c >= '0' && c <= '9') v = c - '0';
            else if (c >= 'a' && c <= 'f') v = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') v = c - 'A' + 10;
            else return -1;
            if (j == 0) hi = v; else lo = v;
        }
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    return 0;
}

/* --- a tiny JSON option reader -------------------------------------- */

/* Returns a pointer to the value text of a TOP-LEVEL key, or NULL. */
static const char *fi_json_find(const char *s, const char *key)
{
    size_t n, i = 0, klen;
    if (!s) return NULL;
    n = strlen(s);
    klen = strlen(key);
    while (i < n && s[i] != '{') i++;
    if (i >= n) return NULL;
    i++;
    for (;;) {
        size_t ks, vs;
        while (i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
        if (i >= n || s[i] == '}') return NULL;
        if (s[i] != '"') return NULL;
        ks = ++i;
        while (i < n && s[i] != '"') { if (s[i] == '\\' && i + 1 < n) i++; i++; }
        if (i >= n) return NULL;
        {
            size_t this_len = i - ks;
            i++;                                    /* the closing quote */
            while (i < n && (s[i] == ' ' || s[i] == '\t')) i++;
            if (i >= n || s[i] != ':') return NULL;
            i++;
            while (i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
            vs = i;
            if (i < n && s[i] == '"') {
                i++;
                while (i < n && s[i] != '"') { if (s[i] == '\\' && i + 1 < n) i++; i++; }
                if (i < n) i++;
            } else if (i < n && s[i] == '{') {
                int depth = 0;
                while (i < n) {
                    if (s[i] == '"') { i++; while (i < n && s[i] != '"') { if (s[i] == '\\' && i + 1 < n) i++; i++; } if (i < n) i++; continue; }
                    if (s[i] == '{') depth++;
                    else if (s[i] == '}') { depth--; if (!depth) { i++; break; } }
                    i++;
                }
            } else if (i < n && s[i] == '[') {
                int depth = 0;
                while (i < n) {
                    if (s[i] == '"') { i++; while (i < n && s[i] != '"') { if (s[i] == '\\' && i + 1 < n) i++; i++; } if (i < n) i++; continue; }
                    if (s[i] == '[') depth++;
                    else if (s[i] == ']') { depth--; if (!depth) { i++; break; } }
                    i++;
                }
            } else {
                while (i < n && s[i] != ',' && s[i] != '}') i++;
            }
            if (this_len == klen && !strncmp(s + ks, key, klen)) return s + vs;
        }
        while (i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
        if (i < n && s[i] == ',') { i++; continue; }
        return NULL;
    }
}

static double fi_opt_num(const char *json, const char *key, double dflt)
{
    const char *p = fi_json_find(json, key);
    char *e;
    double v;
    if (!p) return dflt;
    v = strtod(p, &e);
    if (e == p || v != v) return dflt;
    return v;
}

static int fi_opt_bool(const char *json, const char *key, int dflt)
{
    const char *p = fi_json_find(json, key);
    if (!p) return dflt;
    if (!strncmp(p, "true", 4)) return 1;
    if (!strncmp(p, "false", 5)) return 0;
    return dflt;
}

static int fi_opt_str(const char *json, const char *key, char *out, size_t cap)
{
    const char *p = fi_json_find(json, key);
    size_t n = 0;
    if (cap == 0) return 0;
    if (!p || *p != '"') return 0;       /* absent: the caller's default stays in *out */
    p++;
    while (*p && *p != '"' && n + 1 < cap) out[n++] = *p++;
    out[n] = 0;
    return 1;
}

/* ------------------------------------------------------------------ */
/* The resident index cache                                            */
/* ------------------------------------------------------------------ */

typedef struct {
    char             name[64], tbl[192], col[64], model[64], id_col[64];
    int              dim, fmt, nlist, pca_dim, generation, loaded, nprobe_default;
    int64_t          rows, max_id;
    uint32_t         code_bytes;
    fsql_ivf_model  *m;
    fsql_ivf_index  *x;
} FIdx;

typedef struct {
    fsql_mu_t mu;
    FIdx      cache[FI_MAX_CACHED];
    int       ncache;
    /* the last search's statistics: the "index actually used" evidence */
    int64_t   last_rows_scanned;
    int       last_cells_probed, last_used_index, last_lookups;
    char      last_index[64];
} FIdxState;

static void fi_release(FIdx *x)
{
    if (x->x) fi_ivf_index_free(x->x);
    if (x->m) fi_ivf_model_free(x->m);
    memset(x, 0, sizeof *x);
}

static void fi_state_init(void *p)
{
    FIdxState *S = (FIdxState *)p;
    fsql_mu_init(&S->mu);
}

static void fi_state_destroy(void *p)
{
    FIdxState *S = (FIdxState *)p;
    int i;
    if (!S) return;
    for (i = 0; i < S->ncache; i++) fi_release(&S->cache[i]);
}

static FIdxState *fi_state(fsql_instance *inst)
{
    return (FIdxState *)fsql_instance_singleton(inst, 1, sizeof(FIdxState), fi_state_init, fi_state_destroy);
}

/* ------------------------------------------------------------------ */
/* Nested-query helpers                                                */
/* ------------------------------------------------------------------ */

static int fi_run(fsql_instance *inst, const char *sql, char *err)
{
    fsql_qres r;
    if (fsql_nested_query(inst, sql, &r, err, ERRCAP)) return -1;
    fsql_qres_free(&r);
    return 0;
}

static int64_t fi_cell_i64(duckdb_data_chunk ch, idx_t c, idx_t row)
{
    return ((const int64_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(ch, c)))[row];
}

static char *fi_cell_str(duckdb_data_chunk ch, idx_t c, idx_t row)
{
    duckdb_vector v = duckdb_data_chunk_get_vector(ch, c);
    size_t n;
    const char *p;
    if (!fsql_valid(duckdb_vector_get_validity(v), row)) return fsql_xstrdup("");
    p = fsql_str_data(&((const duckdb_string_t *)duckdb_vector_get_data(v))[row], &n);
    return fsql_xstrndup(p, n);
}

/* The row's vector, copied into `out` (which must hold `cap` doubles). Returns the length,
 * or -1 when the row is malformed. */
static int fi_row_vec(duckdb_data_chunk ch, idx_t col, idx_t row, double *out, size_t cap)
{
    fsql_list l;
    const double *src;
    size_t len;
    const char *err = NULL;
    int g;
    fsql_list_open(&l, duckdb_data_chunk_get_vector(ch, col));
    g = fsql_list_f64_get(&l, row, &src, &len, &err);
    if (g < 0) return -1;
    if (g == 0) return 0;
    if (len > cap) return -1;
    if (len) memcpy(out, src, len * sizeof(double));
    return (int)len;
}

/* ------------------------------------------------------------------ */
/* The storage tables                                                  */
/* ------------------------------------------------------------------ */

static int fi_ensure_tables(fsql_instance *inst, char *err)
{
    static const char *const ddl[] = {
        "CREATE TABLE IF NOT EXISTS fractal_index_meta("
        " name VARCHAR PRIMARY KEY, tbl VARCHAR NOT NULL, col VARCHAR NOT NULL, dim BIGINT NOT NULL,"
        " metric VARCHAR NOT NULL, format VARCHAR NOT NULL, nlist BIGINT NOT NULL, pca_dim BIGINT NOT NULL,"
        " rows BIGINT NOT NULL, max_id BIGINT NOT NULL, model VARCHAR NOT NULL, seed BIGINT NOT NULL,"
        " generation BIGINT NOT NULL, format_version BIGINT NOT NULL, options VARCHAR NOT NULL,"
        " built_at VARCHAR NOT NULL, nprobe_default BIGINT NOT NULL DEFAULT 0, calib VARCHAR NOT NULL DEFAULT '',"
        " model_blob VARCHAR NOT NULL, id_col VARCHAR NOT NULL)",
        "CREATE TABLE IF NOT EXISTS fractal_index_cells("
        " name VARCHAR NOT NULL, generation BIGINT NOT NULL, cell BIGINT NOT NULL,"
        " n BIGINT NOT NULL, ids BIGINT[] NOT NULL, codes VARCHAR[] NOT NULL)",
        "CREATE TABLE IF NOT EXISTS fractal_index_stage("
        " name VARCHAR NOT NULL, generation BIGINT NOT NULL, cell BIGINT NOT NULL,"
        " id BIGINT NOT NULL, code VARCHAR NOT NULL)",
    };
    size_t i;
    for (i = 0; i < sizeof ddl / sizeof ddl[0]; i++) if (fi_run(inst, ddl[i], err)) return -1;
    return 0;
}

typedef struct {
    char     name[64], tbl[192], col[64], fmt[16], model[64], id_col[64];
    char     built_at[40], calib[4096];
    int64_t  dim, nlist, pca_dim, rows, max_id, seed, generation, format_version, nprobe_default;
} FiMeta;

/* Reads the metadata row of `name`. 0 = found, 1 = absent, -1 = error (err filled). */
static int fi_read_meta(fsql_instance *inst, const char *name, FiMeta *mt, char *err)
{
    fsql_sb sb;
    fsql_qres r;
    duckdb_data_chunk ch;
    int rc = 1;
    fsql_sb_init(&sb);
    fsql_sb_puts(&sb, "SELECT name, tbl, col, dim::BIGINT, format, nlist::BIGINT, pca_dim::BIGINT, rows::BIGINT,"
                      " max_id::BIGINT, model, seed::BIGINT, generation::BIGINT, format_version::BIGINT,"
                      " built_at, nprobe_default::BIGINT, calib, id_col FROM fractal_index_meta WHERE name = ");
    fi_put_lit(&sb, name);
    if (fsql_nested_query(inst, fsql_sb_cstr(&sb), &r, err, ERRCAP)) { fsql_sb_free(&sb); return -1; }
    ch = fsql_qres_next_chunk(&r);
    if (ch && duckdb_data_chunk_get_size(ch) > 0) {
        char *s;
        memset(mt, 0, sizeof *mt);
        s = fi_cell_str(ch, 0, 0); snprintf(mt->name, sizeof mt->name, "%s", s ? s : ""); free(s);
        s = fi_cell_str(ch, 1, 0); snprintf(mt->tbl, sizeof mt->tbl, "%s", s ? s : ""); free(s);
        s = fi_cell_str(ch, 2, 0); snprintf(mt->col, sizeof mt->col, "%s", s ? s : ""); free(s);
        mt->dim = fi_cell_i64(ch, 3, 0);
        s = fi_cell_str(ch, 4, 0); snprintf(mt->fmt, sizeof mt->fmt, "%s", s ? s : ""); free(s);
        mt->nlist = fi_cell_i64(ch, 5, 0);
        mt->pca_dim = fi_cell_i64(ch, 6, 0);
        mt->rows = fi_cell_i64(ch, 7, 0);
        mt->max_id = fi_cell_i64(ch, 8, 0);
        s = fi_cell_str(ch, 9, 0); snprintf(mt->model, sizeof mt->model, "%s", s ? s : ""); free(s);
        mt->seed = fi_cell_i64(ch, 10, 0);
        mt->generation = fi_cell_i64(ch, 11, 0);
        mt->format_version = fi_cell_i64(ch, 12, 0);
        s = fi_cell_str(ch, 13, 0); snprintf(mt->built_at, sizeof mt->built_at, "%s", s ? s : ""); free(s);
        mt->nprobe_default = fi_cell_i64(ch, 14, 0);
        s = fi_cell_str(ch, 15, 0); snprintf(mt->calib, sizeof mt->calib, "%s", s ? s : ""); free(s);
        s = fi_cell_str(ch, 16, 0); snprintf(mt->id_col, sizeof mt->id_col, "%s", s ? s : ""); free(s);
        rc = 0;
    }
    if (ch) duckdb_destroy_data_chunk(&ch);
    fsql_qres_free(&r);
    fsql_sb_free(&sb);
    return rc;
}

/* The name of the index on (tbl, col), or 0 when there is none. */
static int fi_find_name(fsql_instance *inst, const char *tbl, const char *col, char *name, size_t cap, char *err)
{
    fsql_sb sb;
    fsql_qres r;
    duckdb_data_chunk ch;
    int ok = 0;
    fsql_sb_init(&sb);
    fsql_sb_puts(&sb, "SELECT name FROM fractal_index_meta WHERE tbl = ");
    fi_put_lit(&sb, tbl);
    fsql_sb_puts(&sb, " AND col = ");
    fi_put_lit(&sb, col);
    fsql_sb_puts(&sb, " ORDER BY name LIMIT 1");
    if (fsql_nested_query(inst, fsql_sb_cstr(&sb), &r, err, ERRCAP)) {
        /* the storage tables may not exist yet (no index has ever been built): create them once
           and try again, so "no index" is not reported as an error */
        fsql_qres_free(&r);
        fsql_sb_free(&sb);
        if (fi_ensure_tables(inst, err)) return -1;
        fsql_sb_init(&sb);
        fsql_sb_puts(&sb, "SELECT name FROM fractal_index_meta WHERE tbl = ");
        fi_put_lit(&sb, tbl);
        fsql_sb_puts(&sb, " AND col = ");
        fi_put_lit(&sb, col);
        fsql_sb_puts(&sb, " ORDER BY name LIMIT 1");
        if (fsql_nested_query(inst, fsql_sb_cstr(&sb), &r, err, ERRCAP)) { fsql_sb_free(&sb); return -1; }
    }
    ch = fsql_qres_next_chunk(&r);
    if (ch && duckdb_data_chunk_get_size(ch) > 0) {
        char *s = fi_cell_str(ch, 0, 0);
        if (s) { snprintf(name, cap, "%s", s); ok = 1; }
        free(s);
    }
    if (ch) duckdb_destroy_data_chunk(&ch);
    fsql_qres_free(&r);
    fsql_sb_free(&sb);
    return ok;
}

/* The single-column PRIMARY KEY of `table`, malloc'd; NULL when there is none. */
static char *fi_detect_pk(fsql_instance *inst, const char *table, char *err)
{
    fsql_sb sb;
    fsql_qres r;
    duckdb_data_chunk ch;
    char *res = NULL;
    fi_ident id;
    fsql_sb_init(&sb);
    fsql_sb_puts(&sb, "SELECT 1 FROM ");
    if (fi_quote_table(table, &sb, err)) { fsql_sb_free(&sb); return NULL; }
    fsql_sb_puts(&sb, " LIMIT 0");
    if (fi_run(inst, fsql_sb_cstr(&sb), err)) { fsql_sb_free(&sb); return NULL; }
    if (fi_split_ident(table, &id) != 0) { fsql_sb_free(&sb); return NULL; }
    fsql_sb_clear(&sb);
    fsql_sb_puts(&sb, "SELECT constraint_column_names FROM duckdb_constraints() WHERE constraint_type = 'PRIMARY KEY' AND table_name = ");
    fi_put_lit(&sb, id.seg[id.n == 2 ? 1 : 0]);
    if (id.n == 2) { fsql_sb_puts(&sb, " AND schema_name = "); fi_put_lit(&sb, id.seg[0]); }
    if (fsql_nested_query(inst, fsql_sb_cstr(&sb), &r, err, ERRCAP)) { fsql_sb_free(&sb); return NULL; }
    ch = fsql_qres_next_chunk(&r);
    if (!ch || duckdb_data_chunk_get_size(ch) == 0) {
        if (ch) duckdb_destroy_data_chunk(&ch);
        fsql_qres_free(&r);
        fsql_sb_free(&sb);
        snprintf(err, ERRCAP, "fractalsql: %s has no declared PRIMARY KEY -- pass id_col explicitly to fractal_index_create", table);
        return NULL;
    }
    {
        duckdb_vector lv = duckdb_data_chunk_get_vector(ch, 0);
        duckdb_list_entry e = ((const duckdb_list_entry *)duckdb_vector_get_data(lv))[0];
        if (e.length != 1) {
            duckdb_destroy_data_chunk(&ch); fsql_qres_free(&r); fsql_sb_free(&sb);
            snprintf(err, ERRCAP, "fractalsql: %s has a composite primary key -- the index needs a single-column key", table);
            return NULL;
        }
        {
            duckdb_vector child = duckdb_list_vector_get_child(lv);
            size_t n;
            const char *p = fsql_str_data(&((const duckdb_string_t *)duckdb_vector_get_data(child))[e.offset], &n);
            res = fsql_xstrndup(p, n);
        }
    }
    duckdb_destroy_data_chunk(&ch);
    fsql_qres_free(&r);
    fsql_sb_free(&sb);
    return res;
}

/* ------------------------------------------------------------------ */
/* Streaming the corpus                                                */
/* ------------------------------------------------------------------ */

/* The SQL that reads the corpus: the stable id and the vector (cast to DOUBLE[] so one decoder
 * covers LIST(FLOAT), LIST(DOUBLE) and ARRAY columns). */
static int fi_corpus_sql(fsql_sb *sb, const char *tbl, const char *col, const char *id_col, const char *extra)
{
    char err[ERRCAP];
    if (fi_quote_table(tbl, sb, err)) return -1;
    fsql_sb_puts(sb, " WHERE ");
    if (fi_quote_column(col, sb, err)) return -1;
    fsql_sb_puts(sb, " IS NOT NULL");
    if (extra) fsql_sb_puts(sb, extra);
    return 0;
}

typedef struct {
    fsql_instance *inst;
    const char   *tbl, *col, *id_col;
    char          err[ERRCAP];
    fsql_qres     q;
    duckdb_data_chunk ch;
    int           started;
    int64_t       nrows;
} FiCursor;

/* Opens the corpus scan. `id_expr` is the SQL expression that yields the row's id (a quoted
 * column, or "rowid" when the table has no usable key). 0 = ok. */
static int fi_cursor_open(FiCursor *c, fsql_instance *inst, const char *id_expr, const char *tbl, const char *col,
                          const char *extra, char *err)
{
    fsql_sb sb;
    memset(c, 0, sizeof *c);
    c->inst = inst;
    fsql_sb_init(&sb);
    fsql_sb_puts(&sb, "SELECT ");
    fsql_sb_puts(&sb, id_expr);
    fsql_sb_puts(&sb, "::BIGINT AS fi_id, CAST(");
    if (fi_quote_column(col, &sb, err)) { fsql_sb_free(&sb); return -1; }
    fsql_sb_puts(&sb, " AS DOUBLE[]) AS fi_vec FROM ");
    if (fi_corpus_sql(&sb, tbl, col, NULL, extra)) { fsql_sb_free(&sb); return -1; }
    if (fsql_nested_query(inst, fsql_sb_cstr(&sb), &c->q, err, ERRCAP)) { fsql_sb_free(&sb); return -1; }
    fsql_sb_free(&sb);
    c->started = 1;
    return 0;
}

static void fi_cursor_close(FiCursor *c)
{
    if (c->ch) duckdb_destroy_data_chunk(&c->ch);
    if (c->started) fsql_qres_free(&c->q);
    c->started = 0;
}

/* ------------------------------------------------------------------ */
/* The build                                                           */
/* ------------------------------------------------------------------ */

typedef struct {
    fsql_ivf_trainer *t;
    int64_t           rows;
    int               dim;
} FiSampleCtx;

/* The dimension of the corpus, taken from its first row. 0 when the table has no vectors. */
static int fi_probe_dim(fsql_instance *inst, const char *tbl, const char *col, char *err)
{
    fsql_sb sb;
    fsql_qres r;
    duckdb_data_chunk ch;
    int dim = 0;
    fsql_sb_init(&sb);
    fsql_sb_puts(&sb, "SELECT CAST(");
    if (fi_quote_column(col, &sb, err)) { fsql_sb_free(&sb); return 0; }
    fsql_sb_puts(&sb, " AS DOUBLE[]) FROM ");
    if (fi_corpus_sql(&sb, tbl, col, NULL, " LIMIT 1")) { fsql_sb_free(&sb); return 0; }
    if (fsql_nested_query(inst, fsql_sb_cstr(&sb), &r, err, ERRCAP)) { fsql_sb_free(&sb); return 0; }
    ch = fsql_qres_next_chunk(&r);
    if (ch && duckdb_data_chunk_get_size(ch) > 0) {
        fsql_list l;
        size_t len;
        fsql_list_open(&l, duckdb_data_chunk_get_vector(ch, 0));
        if (fsql_list_length(&l, 0, &len)) dim = (int)len;
    }
    if (ch) duckdb_destroy_data_chunk(&ch);
    fsql_qres_free(&r);
    fsql_sb_free(&sb);
    return dim;
}

/* The training sample pass: feed the trainer from the reservoir it keeps. */
static int fi_sample_pass(fsql_instance *inst, const char *id_expr, const char *tbl, const char *col,
                          fsql_ivf_trainer *t, int dim, int64_t *rows, char *err)
{
    FiCursor c;
    double *dv;
    float  *fv;
    int rc = 0;
    *rows = 0;
    dv = (double *)malloc((size_t)dim * sizeof(double));
    fv = (float *)malloc((size_t)dim * sizeof(float));
    if (!dv || !fv) { free(dv); free(fv); snprintf(err, ERRCAP, "fractalsql: out of memory"); return -1; }
    if (fi_cursor_open(&c, inst, id_expr, tbl, col, NULL, err)) { free(dv); free(fv); return -1; }
    for (;;) {
        idx_t rows_in_chunk, i;
        if (!c.ch) {
            c.ch = fsql_qres_next_chunk(&c.q);
            if (!c.ch) break;
        }
        rows_in_chunk = duckdb_data_chunk_get_size(c.ch);
        if (rows_in_chunk == 0) { duckdb_destroy_data_chunk(&c.ch); c.ch = NULL; break; }
        for (i = 0; i < rows_in_chunk; i++) {
            int d = fi_row_vec(c.ch, 1, i, dv, (size_t)dim);
            int j;
            if (d < 0) { snprintf(err, ERRCAP, "fractalsql: malformed vector in %s.%s", tbl, col); rc = -1; break; }
            if (d == 0) continue;
            if (d != dim) { snprintf(err, ERRCAP, "fractalsql: vector dimension %d differs from %d in %s.%s", d, dim, tbl, col); rc = -1; break; }
            for (j = 0; j < dim; j++) {
                if (!isfinite(dv[j]) || fabs(dv[j]) > 3.0e38) {
                    snprintf(err, ERRCAP, "fractalsql: non-finite or out-of-range component in %s.%s", tbl, col);
                    rc = -1; break;
                }
                fv[j] = (float)dv[j];
            }
            if (rc) break;
            if (fi_ivf_trainer_add(t, fv, 1) != FSQL_OK) { snprintf(err, ERRCAP, "fractalsql: the trainer rejected a row"); rc = -1; break; }
            (*rows)++;
        }
        duckdb_destroy_data_chunk(&c.ch);
        c.ch = NULL;
        if (rc) break;
    }
    fi_cursor_close(&c);
    free(dv); free(fv);
    return rc;
}

/* The rows the calibration needs: the ids, the normalised corpus and the codes, all in memory.
 * The calibration is skipped (and the buffers released) as soon as the corpus outgrows the cap:
 * an index build must never hold the whole corpus. */
typedef struct {
    int64_t  *ids;
    uint32_t *cell;
    float    *corpus;          /* n * dim, normalised */
    uint8_t  *codes;           /* n * code_bytes */
    size_t    n, cap;
    size_t    dim, code_bytes;
    size_t    bytes_cap;
    int       collecting;
} FiCollect;

static void fi_collect_free(FiCollect *c)
{
    free(c->ids); free(c->cell); free(c->corpus); free(c->codes);
    memset(c, 0, sizeof *c);
}

/* Appends one row to the collection. false when the cap is reached (the collection is dropped). */
static int fi_collect_add(FiCollect *c, int64_t id, uint32_t cell, const float *norm, const uint8_t *code)
{
    size_t need;
    if (!c->collecting) return 0;
    need = (c->n + 1) * (sizeof(int64_t) + sizeof(uint32_t) + c->dim * sizeof(float) + c->code_bytes);
    if (need > c->bytes_cap) { fi_collect_free(c); return 0; }
    if (c->n == c->cap) {
        size_t nc = c->cap ? c->cap * 2 : 1024;
        int64_t *ni = (int64_t *)realloc(c->ids, nc * sizeof(int64_t));
        uint32_t *ng = (uint32_t *)realloc(c->cell, nc * sizeof(uint32_t));
        float *nv = (float *)realloc(c->corpus, nc * c->dim * sizeof(float));
        uint8_t *nk = (uint8_t *)realloc(c->codes, nc * c->code_bytes);
        if (ni) c->ids = ni;
        if (ng) c->cell = ng;
        if (nv) c->corpus = nv;
        if (nk) c->codes = nk;
        if (!ni || !ng || !nv || !nk) { fi_collect_free(c); return 0; }
        c->cap = nc;
    }
    c->ids[c->n] = id;
    c->cell[c->n] = cell;
    memcpy(c->corpus + c->n * c->dim, norm, c->dim * sizeof(float));
    memcpy(c->codes + c->n * c->code_bytes, code, c->code_bytes);
    c->n++;
    return 1;
}

/* The encode pass: encode every row and write it into the staging table. */
static int fi_encode_pass(fsql_instance *inst, const char *id_expr, const char *tbl, const char *col,
                           const fsql_ivf_model *m, uint32_t code_bytes, int dim, const char *name,
                           int64_t generation, int64_t *rows, int64_t *max_id, FiCollect *collect, const char *extra, char *err)
{
    FiCursor c;
    double *dv;
    float  *fv;
    uint8_t *code;
    char  *hex;
    fsql_sb batch;
    int    pending = 0, rc = 0;
    *rows = 0; *max_id = 0;
    dv = (double *)malloc((size_t)dim * sizeof(double));
    fv = (float *)malloc((size_t)dim * sizeof(float));
    code = (uint8_t *)malloc(code_bytes ? code_bytes : 1);
    hex = (char *)malloc((size_t)code_bytes * 2 + 1);
    fsql_sb_init(&batch);
    if (!dv || !fv || !code || !hex) { free(dv); free(fv); free(code); free(hex); fsql_sb_free(&batch); snprintf(err, ERRCAP, "fractalsql: out of memory"); return -1; }

#define FI_FLUSH_BATCH()                                                                    \
    do {                                                                                    \
        if (pending) {                                                                      \
            if (fi_run(inst, fsql_sb_cstr(&batch), err)) { rc = -1; }                       \
            fsql_sb_clear(&batch); pending = 0;                                             \
            if (rc) goto done;                                                              \
        }                                                                                   \
    } while (0)

    if (fi_cursor_open(&c, inst, id_expr, tbl, col, extra, err)) { rc = -1; goto done; }
    for (;;) {
        idx_t rows_in_chunk, i;
        if (!c.ch) {
            c.ch = fsql_qres_next_chunk(&c.q);
            if (!c.ch) break;
        }
        rows_in_chunk = duckdb_data_chunk_get_size(c.ch);
        if (rows_in_chunk == 0) { duckdb_destroy_data_chunk(&c.ch); c.ch = NULL; break; }
        for (i = 0; i < rows_in_chunk; i++) {
            int64_t id = fi_cell_i64(c.ch, 0, i);
            uint32_t cell = 0;
            int d = fi_row_vec(c.ch, 1, i, dv, (size_t)dim), j;
            if (d < 0) { snprintf(err, ERRCAP, "fractalsql: malformed vector in %s.%s", tbl, col); rc = -1; break; }
            if (d == 0) continue;
            if (d != dim) { snprintf(err, ERRCAP, "fractalsql: vector dimension %d differs from %d in %s.%s", d, dim, tbl, col); rc = -1; break; }
            for (j = 0; j < dim; j++) {
                if (!isfinite(dv[j]) || fabs(dv[j]) > 3.0e38) { snprintf(err, ERRCAP, "fractalsql: non-finite or out-of-range component in %s.%s", tbl, col); rc = -1; break; }
                fv[j] = (float)dv[j];
            }
            if (rc) break;
            if (fi_ivf_encode(m, fv, &cell, code) != FSQL_OK) { snprintf(err, ERRCAP, "fractalsql: the encoder rejected a row"); rc = -1; break; }
            if (collect && collect->collecting) {
                float *norm = (float *)malloc((size_t)dim * sizeof(float));
                if (norm) {
                    if (fi_ivf_normalize(fv, (size_t)dim, norm) == FSQL_OK) fi_collect_add(collect, id, cell, norm, code);
                    else fi_collect_add(collect, id, cell, fv, code);
                    free(norm);
                }
            }
            fi_hex(code, code_bytes, hex);
            if (!pending) {
                fsql_sb_clear(&batch);
                fsql_sb_puts(&batch, "INSERT INTO fractal_index_stage(name, generation, cell, id, code) VALUES ");
            } else {
                fsql_sb_puts(&batch, ",");
            }
            fsql_sb_puts(&batch, "(");
            fi_put_lit(&batch, name);
            fsql_sb_printf(&batch, ",%" PRId64 ",%u,%" PRId64 ",", generation, cell, id);
            fi_put_lit(&batch, hex);
            fsql_sb_puts(&batch, ")");
            pending++;
            if (pending >= FI_STAGE_BATCH) FI_FLUSH_BATCH();
            (*rows)++;
            if (id > *max_id) *max_id = id;
        }
        duckdb_destroy_data_chunk(&c.ch);
        c.ch = NULL;
        if (rc) break;
    }
    FI_FLUSH_BATCH();
done:
#undef FI_FLUSH_BATCH
    fi_cursor_close(&c);
    fsql_sb_free(&batch);
    free(dv); free(fv); free(code); free(hex);
    return rc;
}

/* The Monte-Carlo calibration: sample rows as queries (each left out of its own ground truth),
 * compare the index with an exact search at nprobe 1, 2, 4 ... nlist and recommend the smallest
 * nprobe whose 95% lower bound reaches the target. The corpus is held in memory for this, so it
 * only runs when the corpus fits the cap. */
static int fi_calibrate(const fsql_ivf_index *x, const fsql_ivf_info_t *info, const float *Xn,
                        const int64_t *ids, size_t n, int dim, double target, unsigned samples,
                        uint64_t seed, int fmt, char *calib, size_t ccap, int *nprobe_out)
{
    const unsigned K = 10;
    uint64_t *pos;
    float *Q;
    int64_t *self, *truth;
    uint32_t np[24];
    size_t nnp = 0, a;
    double mean[24], se[24], lo[24], sc[24];
    uint32_t rec = 0;
    uint32_t shortlist = (uint32_t)fi_default_rerank(fmt);
    int er, ret;
    if (samples < 20u) samples = 20u;
    if (samples > 2000u) samples = 2000u;
    if (n < (size_t)K + 2u) return 1;
    if ((size_t)samples > n) samples = (unsigned)n;
    pos = (uint64_t *)malloc((size_t)samples * sizeof(uint64_t));
    Q = (float *)malloc((size_t)samples * (size_t)dim * sizeof(float));
    self = (int64_t *)malloc((size_t)samples * sizeof(int64_t));
    truth = (int64_t *)malloc((size_t)samples * K * sizeof(int64_t));
    if (!pos || !Q || !self || !truth) { free(pos); free(Q); free(self); free(truth); return -1; }
    er = fi_ivf_sample_rows((uint64_t)n, samples, seed, pos);
    for (a = 0; er == FSQL_OK && a < samples; a++) {
        size_t nt = 0;
        memcpy(Q + a * (size_t)dim, Xn + pos[a] * (size_t)dim, (size_t)dim * sizeof(float));
        self[a] = ids[pos[a]];
        er = fi_ivf_exact_topk(Xn, ids, n, (size_t)dim, Xn + pos[a] * (size_t)dim, self[a], 1, K, truth + a * K, &nt);
        if (er == FSQL_OK && nt != K) er = FSQL_ERR_INVALID;
    }
    for (uint32_t v = 1; v < info->nlist && nnp < 22; v *= 2u) np[nnp++] = v;
    np[nnp++] = info->nlist;
    if (shortlist < K + 5u) shortlist = K + 5u;
    er = fi_ivf_estimate_recall(x, Q, self, truth, samples, K, np, nnp, shortlist, target, mean, se, lo, sc, &rec);
    ret = (er == FSQL_OK || er == 1) ? 0 : -1;
    if (ret == 0) {
        /* When the target cannot be reached (rc 1), the core recommends the LARGEST nprobe.
           Probing every cell to get the same recall as probing one is waste: recommend instead
           the smallest nprobe that reaches the best achievable recall (the point where the
           estimate saturates). */
        if (er == 1 && nnp > 0) {
            double best = mean[0];
            size_t b;
            for (b = 1; b < nnp; b++) if (mean[b] > best) best = mean[b];
            for (b = 0; b < nnp; b++) {
                if (mean[b] >= best - 0.02) { rec = np[b]; break; }
            }
        }
    }
    if (ret == 0) {
        size_t len = 0;
        len += (size_t)snprintf(calib + len, ccap - len, "{\"samples\":%u,\"k\":%u,\"target\":%g,\"shortlist\":%u,\"estimates\":[", samples, K, target, shortlist);
        for (a = 0; a < nnp && len + 160 < ccap; a++)
            len += (size_t)snprintf(calib + len, ccap - len, "%s{\"nprobe\":%u,\"recall\":%.4f,\"se\":%.4f,\"ci95_low\":%.4f,\"mean_rows_scanned\":%.0f}",
                                    a ? "," : "", np[a], mean[a], se[a], lo[a], sc[a]);
        snprintf(calib + len, ccap - len, "],\"recommended_nprobe\":%u,\"reaches_target\":%s}", rec, er == FSQL_OK ? "true" : "false");
        *nprobe_out = (int)rec;
    }
    free(pos); free(Q); free(self); free(truth);
    return ret;
}

/* Builds (or rebuilds) an index. 0 = ok. */
static int fi_build(fsql_instance *inst, const char *name, const char *tbl, const char *col,
                    const char *id_col, const char *opts, int is_rebuild,
                    char *out, size_t ocap, char *err, size_t ecap)
{
    char fmtname[16] = "INT8", model[64] = "";
    int fmt, dim, rc = -1;
    double nlist_d, iters_d, sample_d, pca_d, seed_d;
    uint64_t seed;
    fsql_ivf_options_t o;
    fsql_ivf_trainer *t = NULL;
    fsql_ivf_model *m = NULL;
    uint8_t *blob = NULL;
    size_t blen = 0;
    fsql_ivf_info_t info;
    int64_t rows = 0, max_id = 0, generation = 1;
    char calib[4096];
    int calibrated_nprobe = 0;
    fsql_sb sb;
    FiMeta prev;
    char *pk = NULL;
    char pkq[FI_IDENT_MAX_SEGMENT + 8];
    int have_prev;

    snprintf(calib, sizeof calib, "{}");     /* valid JSON even when there is no calibration */
    if (!fi_ivf_available()) { snprintf(err, ecap, "%s", FI_NO_IVF_MSG); return -1; }
    if (fi_ensure_tables(inst, err)) return -1;

    fi_opt_str(opts, "vector_format", fmtname, sizeof fmtname);
    fmt = fi_parse_fmt(fmtname);
    if (fmt < 0) { snprintf(err, ecap, "fractalsql: vector_format must be INT8, INT4, FP16 or FP32 (got '%s')", fmtname); return -1; }
    fi_opt_str(opts, "model", model, sizeof model);
    nlist_d = fi_opt_num(opts, "nlist", 0);
    iters_d = fi_opt_num(opts, "iters", 0);
    sample_d = fi_opt_num(opts, "sample", 0);
    pca_d = fi_opt_num(opts, "pca_dim", 0);
    seed_d = fi_opt_num(opts, "seed", 1);
    if (nlist_d < 0 || nlist_d > 4096 || iters_d < 0 || iters_d > 100 || sample_d < 0 || sample_d > 1000000 ||
        pca_d < 0 || pca_d > FI_MAXDIM || seed_d < 0) {
        snprintf(err, ecap, "fractalsql: nlist must be 0..4096, iters 0..100, sample 0..1000000, pca_dim 0..%d, seed >= 0", FI_MAXDIM);
        return -1;
    }
    seed = (uint64_t)seed_d;
    if (!seed) seed = 1;

    have_prev = fi_read_meta(inst, name, &prev, err) == 0;
    if (have_prev && !is_rebuild) { snprintf(err, ecap, "fractalsql: index '%s' already exists (use fractal_index_rebuild or drop it first)", name); return -1; }
    if (!have_prev && is_rebuild) { snprintf(err, ecap, "fractalsql: no index named '%s'", name); return -1; }
    if (have_prev) generation = prev.generation + 1;

    /* the stable row id: the caller's id_col, else the table's single-column primary key */
    if (id_col && *id_col) pk = fsql_xstrdup(id_col);
    else {
        pk = fi_detect_pk(inst, tbl, err);
        if (!pk) return -1;
    }

    dim = fi_probe_dim(inst, tbl, col, err);
    if (dim <= 0) {
        snprintf(err, ecap, "fractalsql: %s.%s has no vectors to index", tbl, col);
        free(pk);
        return -1;
    }

    /* the quoted id expression, used by both passes */
    {
        fsql_sb q;
        fsql_sb_init(&q);
        if (fi_quote_column(pk, &q, err)) { fsql_sb_free(&q); free(pk); return -1; }
        snprintf(pkq, sizeof pkq, "%s", fsql_sb_cstr(&q));
        fsql_sb_free(&q);
    }

    memset(&o, 0, sizeof o);
    o.struct_size = sizeof o;
    o.dim = (uint32_t)dim;
    o.format = (uint32_t)fmt;
    o.nlist = (uint32_t)nlist_d;
    o.pca_dim = (fmt <= FSQL_IVF_FMT_INT4) ? (uint32_t)pca_d : 0u;
    o.kmeans_iters = (uint32_t)iters_d;
    o.sample = (uint32_t)sample_d;
    o.seed = seed;

    /* pass one: the training sample (it also counts the rows) */
    {
        int trc = 0;
        t = fi_ivf_trainer_new(&o, &trc);
        if (!t) {
            snprintf(err, ecap, trc == FSQL_ERR_OOM ? "fractalsql: out of memory"
                           : "fractalsql: invalid index options for dimension %d (INT8/INT4 need dimension <= 4096 and pca_dim <= dimension)", dim);
            free(pk);
            return -1;
        }
    }
    if (fi_sample_pass(inst, pkq, tbl, col, t, dim, &rows, err)) { fi_ivf_trainer_free(t); free(pk); return -1; }
    if (rows <= 0) {
        fi_ivf_trainer_free(t); free(pk);
        snprintf(err, ecap, "fractalsql: %s.%s has no vectors to index", tbl, col);
        return -1;
    }
    if (fi_ivf_trainer_finish(t, &blob, &blen) != FSQL_OK) {
        fi_ivf_trainer_free(t); free(pk);
        snprintf(err, ecap, "fractalsql: could not train the index for %s.%s", tbl, col);
        return -1;
    }
    fi_ivf_trainer_free(t);
    t = NULL;
    m = fi_ivf_model_load(blob, blen, NULL);
    if (!m) { fi_ivf_free(blob); free(pk); snprintf(err, ecap, "fractalsql: internal error loading the trained model"); return -1; }
    if (fi_ivf_model_info(m, &info) != FSQL_OK) {
        fi_ivf_model_free(m); fi_ivf_free(blob); free(pk);
        snprintf(err, ecap, "fractalsql: internal error reading the trained model");
        return -1;
    }

    /* pass two: encode every row into the staging table */
    {
        FiCollect fc;
        memset(&fc, 0, sizeof fc);
        fc.dim = (size_t)dim;
        fc.code_bytes = info.code_bytes;
        fc.bytes_cap = FI_CALIB_BYTES;
        fc.collecting = 1;
        if (fi_encode_pass(inst, pkq, tbl, col, m, info.code_bytes, dim, name, generation, &rows, &max_id, &fc, NULL, err)) {
            fi_collect_free(&fc);
            fi_ivf_model_free(m); fi_ivf_free(blob); free(pk);
            return -1;
        }
        /* The Monte-Carlo calibration: the smallest nprobe whose 95% lower bound reaches the
           target recall. It needs the corpus and the codes in memory, so it only runs when they
           fit the cap (an index build must never hold the whole corpus). */
        if (fc.collecting && fc.n > 0 && fi_opt_num(opts, "calibration_samples", 200) > 0 &&
            fi_opt_num(opts, "target_recall", 0.95) > 0) {
            fsql_ivf_index *x = fi_ivf_index_new(m);
            if (x) {
                int64_t *ids = NULL;
                uint8_t *codes = NULL;
                uint32_t c;
                int ok = 1;
                for (c = 0; c < info.nlist && ok; c++) {
                    size_t k = 0, j;
                    for (j = 0; j < fc.n; j++) if (fc.cell[j] == c) k++;
                    ids = (int64_t *)malloc((k ? k : 1) * sizeof(int64_t));
                    codes = (uint8_t *)malloc((k ? k : 1) * info.code_bytes);
                    if (!ids || !codes) { ok = 0; break; }
                    k = 0;
                    for (j = 0; j < fc.n; j++)
                        if (fc.cell[j] == c) {
                            ids[k] = fc.ids[j];
                            memcpy(codes + k * info.code_bytes, fc.codes + j * info.code_bytes, info.code_bytes);
                            k++;
                        }
                    if (fi_ivf_index_set_cell(x, c, ids, codes, k) != FSQL_OK) ok = 0;
                    free(ids); free(codes);
                }
                if (ok) {
                    double target = fi_opt_num(opts, "target_recall", 0.95);
                    if (target > 1.0) target = 1.0;
                    if (fi_calibrate(x, &info, fc.corpus, fc.ids, fc.n, dim, target,
                                     (unsigned)fi_opt_num(opts, "calibration_samples", 200), seed, fmt,
                                     calib, sizeof calib, &calibrated_nprobe) != 0) {
                        snprintf(calib, sizeof calib, "{\"skipped\":\"the calibration did not finish; the default nprobe is used\"}");
                        calibrated_nprobe = 0;
                    }
                } else {
                    snprintf(calib, sizeof calib, "{\"skipped\":\"the calibration did not fit in memory; the default nprobe is used\"}");
                }
                fi_ivf_index_free(x);
            }
        }
        fi_collect_free(&fc);
    }
    if (rows <= 0) {
        fi_ivf_model_free(m); fi_ivf_free(blob); free(pk);
        snprintf(err, ecap, "fractalsql: %s.%s has no vectors to index", tbl, col);
        return -1;
    }

    /* fold the staging rows into the per-cell rows (the engine does the grouping) */
    fsql_sb_init(&sb);
    fsql_sb_puts(&sb, "INSERT INTO fractal_index_cells(name, generation, cell, n, ids, codes) "
                      "SELECT name, generation, cell, count(*), list(id ORDER BY id), list(code ORDER BY id) "
                      "FROM fractal_index_stage WHERE name = ");
    fi_put_lit(&sb, name);
    fsql_sb_printf(&sb, " AND generation = %" PRId64 " GROUP BY name, generation, cell", generation);
    if (fi_run(inst, fsql_sb_cstr(&sb), err)) { fsql_sb_free(&sb); goto fail; }
    fsql_sb_clear(&sb);
    fsql_sb_puts(&sb, "DELETE FROM fractal_index_stage WHERE name = ");
    fi_put_lit(&sb, name);
    fsql_sb_printf(&sb, " AND generation = %" PRId64, generation);
    if (fi_run(inst, fsql_sb_cstr(&sb), err)) { fsql_sb_free(&sb); goto fail; }
    fsql_sb_free(&sb);

    /* the metadata pointer is flipped LAST, in one statement: a reader only ever sees a
       complete generation (each nested query is its own autocommit frame). */
    {
        char *hexblob;
        fsql_sb_init(&sb);
        hexblob = (char *)malloc(blen * 2 + 1);
        if (!hexblob) { fsql_sb_free(&sb); snprintf(err, ecap, "fractalsql: out of memory"); goto fail; }
        fi_hex(blob, blen, hexblob);
        fsql_sb_puts(&sb, "INSERT OR REPLACE INTO fractal_index_meta(name,tbl,col,dim,metric,format,nlist,pca_dim,rows,max_id,"
                          "model,seed,generation,format_version,options,built_at,nprobe_default,calib,model_blob,id_col) VALUES (");
        fi_put_lit(&sb, name); fsql_sb_puts(&sb, ",");
        fi_put_lit(&sb, tbl); fsql_sb_puts(&sb, ",");
        fi_put_lit(&sb, col); fsql_sb_printf(&sb, ",%d,'cosine',", dim);
        fi_put_lit(&sb, FI_FMT_NAME[fmt]);
        fsql_sb_printf(&sb, ",%u,%u,%" PRId64 ",%" PRId64 ",", info.nlist, info.pca_dim, rows, max_id);
        fi_put_lit(&sb, model); fsql_sb_printf(&sb, ",%" PRIu64 ",%" PRId64 ",%d,", seed, generation, FI_FORMAT_VERSION);
        fi_put_lit(&sb, opts && *opts ? opts : "{}"); fsql_sb_puts(&sb, ",");
        fsql_sb_puts(&sb, "strftime(now()::TIMESTAMPTZ, '%Y-%m-%dT%H:%M:%SZ')");
        fsql_sb_printf(&sb, ",%d,", calibrated_nprobe);
        fi_put_lit(&sb, calib); fsql_sb_puts(&sb, ",");
        fi_put_lit(&sb, hexblob); fsql_sb_puts(&sb, ",");
        fi_put_lit(&sb, pk); fsql_sb_puts(&sb, ")");
        free(hexblob);
        if (fi_run(inst, fsql_sb_cstr(&sb), err)) { fsql_sb_free(&sb); goto fail; }
        fsql_sb_free(&sb);
    }

    /* the older generation is no longer needed */
    fsql_sb_init(&sb);
    fsql_sb_puts(&sb, "DELETE FROM fractal_index_cells WHERE name = ");
    fi_put_lit(&sb, name);
    fsql_sb_printf(&sb, " AND generation < %" PRId64, generation);
    fi_run(inst, fsql_sb_cstr(&sb), err);
    fsql_sb_clear(&sb);
    fsql_sb_puts(&sb, "DELETE FROM fractal_index_stage WHERE name = ");
    fi_put_lit(&sb, name);
    fi_run(inst, fsql_sb_cstr(&sb), err);
    fsql_sb_free(&sb);

    {
        int n = snprintf(out, ocap, "{\"name\":\"%s\",\"table\":\"%s\",\"column\":\"%s\",\"id_col\":\"%s\",\"format\":\"%s\",\"dim\":%d,"
                        "\"rows\":%" PRId64 ",\"nlist\":%u,\"pca_dim\":%u,\"generation\":%" PRId64 ",\"bytes\":%" PRIu64,
                        name, tbl, col, pk, FI_FMT_NAME[fmt], dim, rows, info.nlist, info.pca_dim, generation,
                        (uint64_t)rows * (uint64_t)info.code_bytes);
        if (n > 0 && (size_t)n < ocap && calibrated_nprobe > 0)
            snprintf(out + n, ocap - (size_t)n, ",\"calibrated_nprobe\":%d}", calibrated_nprobe);
        else if (n > 0 && (size_t)n + 2 < ocap) { out[n] = '}'; out[n + 1] = 0; }
    }
    rc = 0;
    goto done;
fail:
    rc = -1;
done:
    if (rc) {
        /* a failed build leaves no half-generation behind */
        fsql_sb junk;
        fsql_sb_init(&junk);
        fsql_sb_puts(&junk, "DELETE FROM fractal_index_stage WHERE name = ");
        fi_put_lit(&junk, name);
        fsql_sb_printf(&junk, " AND generation = %" PRId64, generation);
        fi_run(inst, fsql_sb_cstr(&junk), err);
        fsql_sb_clear(&junk);
        fsql_sb_puts(&junk, "DELETE FROM fractal_index_cells WHERE name = ");
        fi_put_lit(&junk, name);
        fsql_sb_printf(&junk, " AND generation = %" PRId64, generation);
        fi_run(inst, fsql_sb_cstr(&junk), err);
        fsql_sb_free(&junk);
    }
    free(pk);
    if (m) fi_ivf_model_free(m);
    if (blob) fi_ivf_free(blob);
    return rc;
}

/* ------------------------------------------------------------------ */
/* Loading an index into the resident cache                           */
/* ------------------------------------------------------------------ */

/* Loads the current generation of `name` into the cache (or returns the cached one).
 * The caller must hold the cache lock. */
static FIdx *fi_load_locked(FIdxState *S, fsql_instance *inst, const char *name, char *err, size_t ecap)
{
    FiMeta mt;
    FIdx *slot = NULL;
    int i;
    uint8_t *blob = NULL;
    size_t blen = 0;
    fsql_qres r;
    duckdb_data_chunk ch;
    fsql_sb sb;

    if (fi_read_meta(inst, name, &mt, err) != 0) { snprintf(err, ecap, "fractalsql: no index named '%s'", name); return NULL; }
    for (i = 0; i < S->ncache; i++) {
        if (!strcmp(S->cache[i].name, name)) {
            if (S->cache[i].loaded && S->cache[i].generation == (int)mt.generation) {
                S->cache[i].nprobe_default = (int)mt.nprobe_default;
                return &S->cache[i];
            }
            fi_release(&S->cache[i]);
            slot = &S->cache[i];
            break;
        }
    }
    if (!slot) {
        if (S->ncache >= FI_MAX_CACHED) { snprintf(err, ecap, "fractalsql: too many resident indexes (limit %d)", FI_MAX_CACHED); return NULL; }
        slot = &S->cache[S->ncache++];
    }
    memset(slot, 0, sizeof *slot);
    snprintf(slot->name, sizeof slot->name, "%s", name);
    snprintf(slot->tbl, sizeof slot->tbl, "%s", mt.tbl);
    snprintf(slot->col, sizeof slot->col, "%s", mt.col);
    snprintf(slot->model, sizeof slot->model, "%s", mt.model);
    snprintf(slot->id_col, sizeof slot->id_col, "%s", mt.id_col);
    slot->dim = (int)mt.dim;
    slot->fmt = fi_parse_fmt(mt.fmt);
    slot->nlist = (int)mt.nlist;
    slot->pca_dim = (int)mt.pca_dim;
    slot->generation = (int)mt.generation;
    slot->nprobe_default = (int)mt.nprobe_default;
    slot->rows = mt.rows;
    slot->max_id = mt.max_id;
    if (slot->fmt < 0) { snprintf(err, ecap, "fractalsql: index '%s' has an unknown vector format", name); fi_release(slot); return NULL; }

    /* the model blob */
    fsql_sb_init(&sb);
    fsql_sb_puts(&sb, "SELECT model_blob FROM fractal_index_meta WHERE name = ");
    fi_put_lit(&sb, name);
    if (fsql_nested_query(inst, fsql_sb_cstr(&sb), &r, err, ecap)) { fsql_sb_free(&sb); fi_release(slot); return NULL; }
    fsql_sb_free(&sb);
    ch = fsql_qres_next_chunk(&r);
    if (ch && duckdb_data_chunk_get_size(ch) > 0) {
        char *hex = fi_cell_str(ch, 0, 0);
        if (hex && *hex) {
            blen = strlen(hex) / 2;
            blob = (uint8_t *)malloc(blen ? blen : 1);
            if (!blob || fi_unhex(hex, blob, blen) != 0) { free(blob); blob = NULL; }
        }
        free(hex);
    }
    if (ch) duckdb_destroy_data_chunk(&ch);
    fsql_qres_free(&r);
    if (!blob) { snprintf(err, ecap, "fractalsql: index '%s' has a missing or corrupt model; rebuild it", name); fi_release(slot); return NULL; }
    slot->m = fi_ivf_model_load(blob, blen, NULL);
    free(blob);
    if (!slot->m) { snprintf(err, ecap, "fractalsql: index '%s' has a missing or corrupt model; rebuild it", name); fi_release(slot); return NULL; }
    {
        fsql_ivf_info_t info;
        if (fi_ivf_model_info(slot->m, &info) != FSQL_OK || (int)info.dim != slot->dim ||
            (int)info.nlist != slot->nlist || (int)info.format != slot->fmt) {
            snprintf(err, ecap, "fractalsql: index '%s' has a missing or corrupt model; rebuild it", name);
            fi_release(slot); return NULL;
        }
        slot->code_bytes = info.code_bytes;
    }
    slot->x = fi_ivf_index_new(slot->m);
    if (!slot->x) { snprintf(err, ecap, "fractalsql: out of memory loading index '%s'", name); fi_release(slot); return NULL; }

    /* the cells */
    fsql_sb_init(&sb);
    fsql_sb_puts(&sb, "SELECT cell, n, ids, codes FROM fractal_index_cells WHERE name = ");
    fi_put_lit(&sb, name);
    fsql_sb_printf(&sb, " AND generation = %" PRId64 " ORDER BY cell", slot->generation);
    if (fsql_nested_query(inst, fsql_sb_cstr(&sb), &r, err, ecap)) { fsql_sb_free(&sb); fi_release(slot); return NULL; }
    fsql_sb_free(&sb);
    {
        int cells = 0;
        int64_t total = 0;
        int64_t *ids = NULL;
        uint8_t *codes = NULL;
        size_t ids_cap = 0, codes_cap = 0;
        char *seen = (char *)calloc((size_t)(slot->nlist > 0 ? slot->nlist : 1), 1);
        int ci;
        if (!seen) { snprintf(err, ecap, "fractalsql: out of memory loading index"); fi_release(slot); return NULL; }
        for (;;) {
            idx_t rows, i;
            ch = fsql_qres_next_chunk(&r);
            if (!ch) break;
            rows = duckdb_data_chunk_get_size(ch);
            if (rows == 0) { duckdb_destroy_data_chunk(&ch); break; }
            for (i = 0; i < rows; i++) {
                int64_t cell = fi_cell_i64(ch, 0, i);
                int64_t n = fi_cell_i64(ch, 1, i);
                if (cell < 0 || cell >= slot->nlist || n < 0) {
                    duckdb_destroy_data_chunk(&ch); fsql_qres_free(&r); free(seen);
                    snprintf(err, ecap, "fractalsql: index '%s' is corrupt (cell %" PRId64 ")", name, cell);
                    fi_release(slot); return NULL;
                }
                /* the ids and the codes are read through the child vectors directly */
                {
                    duckdb_vector iv = duckdb_list_vector_get_child(duckdb_data_chunk_get_vector(ch, 2));
                    duckdb_vector cv = duckdb_list_vector_get_child(duckdb_data_chunk_get_vector(ch, 3));
                    duckdb_list_entry ie = ((const duckdb_list_entry *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(ch, 2)))[i];
                    duckdb_list_entry ce = ((const duckdb_list_entry *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(ch, 3)))[i];
                    const int64_t *idv = (const int64_t *)duckdb_vector_get_data(iv);
                    size_t j;
                    if ((int64_t)ie.length != n || (int64_t)ce.length != n) {
                        duckdb_destroy_data_chunk(&ch); fsql_qres_free(&r);
                        snprintf(err, ecap, "fractalsql: index '%s' is corrupt (cell %" PRId64 ")", name, cell);
                        fi_release(slot); return NULL;
                    }
                    if ((size_t)n > ids_cap) {
                        int64_t *nn = (int64_t *)realloc(ids, (size_t)n * sizeof(int64_t));
                        if (!nn) { duckdb_destroy_data_chunk(&ch); fsql_qres_free(&r); free(seen); snprintf(err, ecap, "fractalsql: out of memory loading index"); fi_release(slot); return NULL; }
                        ids = nn; ids_cap = (size_t)n;
                    }
                    if ((size_t)n * slot->code_bytes > codes_cap) {
                        size_t nbytes = (size_t)n * slot->code_bytes;
                        uint8_t *nc = (uint8_t *)realloc(codes, nbytes ? nbytes : 1);
                        if (!nc) { duckdb_destroy_data_chunk(&ch); fsql_qres_free(&r); free(seen); snprintf(err, ecap, "fractalsql: out of memory loading index"); fi_release(slot); return NULL; }
                        codes = nc; codes_cap = (size_t)n * slot->code_bytes;
                    }
                    for (j = 0; j < (size_t)n; j++) ids[j] = idv[ie.offset + j];
                    for (j = 0; j < (size_t)n; j++) {
                        size_t lcodn = 0;
                        const char *hx = fsql_str_data(&((const duckdb_string_t *)duckdb_vector_get_data(cv))[ce.offset + j], &lcodn);
                        /* DuckDB strings are not NUL-terminated: the stored hex must be exactly as long as the code, or the decode would read past it */
                        if (lcodn != 2 * slot->code_bytes || fi_unhex(hx, codes + j * slot->code_bytes, slot->code_bytes) != 0) {
                            duckdb_destroy_data_chunk(&ch); fsql_qres_free(&r); free(seen);
                            snprintf(err, ecap, "fractalsql: index '%s' is corrupt (cell %" PRId64 ")", name, cell);
                            fi_release(slot); return NULL;
                        }
                    }
                    if (fi_ivf_index_set_cell(slot->x, (uint32_t)cell, ids, codes, (size_t)n) != FSQL_OK) {
                        duckdb_destroy_data_chunk(&ch); fsql_qres_free(&r); free(seen);
                        snprintf(err, ecap, "fractalsql: out of memory loading index");
                        fi_release(slot); return NULL;
                    }
                }
                seen[cell] = 1;
                cells++;
                total += n;
            }
            duckdb_destroy_data_chunk(&ch);
        }
        fsql_qres_free(&r);
        free(ids);
        free(codes);
        /* a cell with no rows has no row in the storage table: mark it loaded and empty */
        for (ci = 0; ci < slot->nlist; ci++) {
            if (seen[ci]) continue;
            if (fi_ivf_index_set_cell(slot->x, (uint32_t)ci, NULL, NULL, 0) != FSQL_OK) {
                snprintf(err, ecap, "fractalsql: out of memory loading index");
                free(seen); fi_release(slot); return NULL;
            }
        }
        free(seen);
        if (total != slot->rows) {
            snprintf(err, ecap, "fractalsql: index '%s' is incomplete (%" PRId64 " of %" PRId64 " rows in %d of %d cells)",
                     name, total, slot->rows, cells, slot->nlist);
            fi_release(slot);
            return NULL;
        }
    }
    slot->loaded = 1;
    return slot;
}

/* ------------------------------------------------------------------ */
/* The result accumulator: sorted ascending by distance, ties by id    */
/* ------------------------------------------------------------------ */

typedef struct { int64_t id; double d; } FiCand;

static void fi_ins(FiCand *a, int *n, int cap, FiCand c)
{
    int i;
    if (*n == cap) {
        FiCand *w = &a[cap - 1];
        if (!(c.d < w->d || (c.d == w->d && c.id < w->id))) return;
        i = cap - 1;
    } else {
        i = (*n)++;
    }
    while (i > 0 && (a[i - 1].d > c.d || (a[i - 1].d == c.d && a[i - 1].id > c.id))) { a[i] = a[i - 1]; i--; }
    a[i] = c;
}

/* ------------------------------------------------------------------ */
/* The exact scan (the fallback, and the delta)                       */
/* ------------------------------------------------------------------ */

/* Scans the corpus (or the rows the extra clause selects) and keeps the best k. */
static int fi_exact_scan(fsql_instance *inst, const char *id_expr, const char *tbl, const char *col,
                          const double *q, int dim, int k, const char *extra,
                          FiCand *res, int *nres, int64_t *scanned, char *err)
{
    FiCursor c;
    double *dv;
    int rc = 0;
    dv = (double *)malloc((size_t)dim * sizeof(double));
    if (!dv) { snprintf(err, ERRCAP, "fractalsql: out of memory"); return -1; }
    if (fi_cursor_open(&c, inst, id_expr, tbl, col, extra, err)) { free(dv); return -1; }
    for (;;) {
        idx_t rows_in_chunk, i;
        if (!c.ch) {
            c.ch = fsql_qres_next_chunk(&c.q);
            if (!c.ch) break;
        }
        rows_in_chunk = duckdb_data_chunk_get_size(c.ch);
        if (rows_in_chunk == 0) { duckdb_destroy_data_chunk(&c.ch); c.ch = NULL; break; }
        for (i = 0; i < rows_in_chunk; i++) {
            int64_t id = fi_cell_i64(c.ch, 0, i);
            int d = fi_row_vec(c.ch, 1, i, dv, (size_t)dim);
            FiCand cand;
            if (d < 0) { snprintf(err, ERRCAP, "fractalsql: malformed vector in %s.%s", tbl, col); rc = -1; break; }
            if (d == 0) continue;
            if (d != dim) continue;                     /* a row of another shape is not a candidate */
            cand.id = id;
            cand.d = fsqlp_cosine_distance_d(dv, q, (size_t)dim);
            fi_ins(res, nres, k, cand);
            if (scanned) (*scanned)++;
        }
        duckdb_destroy_data_chunk(&c.ch);
        c.ch = NULL;
        if (rc) break;
    }
    fi_cursor_close(&c);
    free(dv);
    return rc;
}

/* Fetches the rows with the given ids and keeps the best k of them (the verify step). */
static int fi_verify_rows(fsql_instance *inst, const char *tbl, const char *col, const char *id_col,
                          const int64_t *ids, size_t nids, const double *q, int dim, int k,
                          FiCand *res, int *nres, int *lookups, char *err)
{
    fsql_sb sb;
    fsql_qres r;
    duckdb_data_chunk ch;
    double *dv;
    size_t i;
    int rc = 0;
    dv = (double *)malloc((size_t)dim * sizeof(double));
    if (!dv) { snprintf(err, ERRCAP, "fractalsql: out of memory"); return -1; }
    fsql_sb_init(&sb);
    fsql_sb_puts(&sb, "SELECT ");
    if (fi_quote_column(id_col, &sb, err)) { free(dv); fsql_sb_free(&sb); return -1; }
    fsql_sb_puts(&sb, "::BIGINT AS fi_id, CAST(");
    if (fi_quote_column(col, &sb, err)) { free(dv); fsql_sb_free(&sb); return -1; }
    fsql_sb_puts(&sb, " AS DOUBLE[]) AS fi_vec FROM ");
    if (fi_quote_table(tbl, &sb, err)) { free(dv); fsql_sb_free(&sb); return -1; }
    fsql_sb_puts(&sb, " WHERE ");
    if (fi_quote_column(id_col, &sb, err)) { free(dv); fsql_sb_free(&sb); return -1; }
    fsql_sb_puts(&sb, " IN (");
    for (i = 0; i < nids; i++) fsql_sb_printf(&sb, "%s%" PRId64, i ? "," : "", ids[i]);
    fsql_sb_puts(&sb, ")");
    if (fsql_nested_query(inst, fsql_sb_cstr(&sb), &r, err, ERRCAP)) { free(dv); fsql_sb_free(&sb); return -1; }
    fsql_sb_free(&sb);
    for (;;) {
        idx_t rows, j;
        ch = fsql_qres_next_chunk(&r);
        if (!ch) break;
        rows = duckdb_data_chunk_get_size(ch);
        if (rows == 0) { duckdb_destroy_data_chunk(&ch); break; }
        for (j = 0; j < rows; j++) {
            int64_t id = fi_cell_i64(ch, 0, j);
            int d = fi_row_vec(ch, 1, j, dv, (size_t)dim);
            FiCand cand;
            if (lookups) (*lookups)++;
            if (d < 0 || d == 0 || d != dim) continue;   /* the row was deleted or changed shape: dropped */
            cand.id = id;
            cand.d = fsqlp_cosine_distance_d(dv, q, (size_t)dim);
            fi_ins(res, nres, k, cand);
        }
        duckdb_destroy_data_chunk(&ch);
    }
    fsql_qres_free(&r);
    free(dv);
    return rc;
}

/* ------------------------------------------------------------------ */
/* The SQL functions                                                   */
/* ------------------------------------------------------------------ */

/* The old two-argument fractal_search(vector, query) was renamed fractal_search: it runs SFS
 * toward the query direction; it is not a retrieval function. Not an alias: calling the old form is
 * an error that says what changed. */
static void fi_renamed_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out)
{
    (void)in; (void)out;
    fsql_fn_error(info, "fractalsql: fractal_search(vector, query) was renamed fractal_sfs_converge(vector, query); "
                        "fractal_search is now fractal_search(table, column, query, k, options) (the indexed search)");
}

/* fractal_index_create(table, column [, options]) -> JSON */
static void fi_create_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out)
{
    fsql_instance *inst = fsql_scalar_instance(info);
    idx_t n = duckdb_data_chunk_get_size(in);
    idx_t nc = duckdb_data_chunk_get_column_count(in);
    char *a[3] = { NULL, NULL, NULL };
    fsql_sb out_sb;
    idx_t i;
    if (nc < 2 || nc > 3) { fsql_fn_error(info, "fractalsql: fractal_index_create takes 2 or 3 arguments"); return; }
    for (i = 0; i < n; i++) {
        idx_t c;
        char name[64] = "";
        char *opts;
        for (c = 0; c < nc; c++) {
            size_t l;
            const char *p;
            if (!fsql_valid(fsql_col_validity(in, c), i)) { a[c] = fsql_xstrdup(""); continue; }
            p = fsql_str_data(&((const duckdb_string_t *)fsql_col_data(in, c))[i], &l);
            a[c] = fsql_xstrndup(p, l);
            if (!a[c]) { fsql_fn_error(info, "fractalsql: out of memory"); return; }
        }
        /* a private copy: opts must not alias a[2] (both are freed below) */
        opts = fsql_xstrdup(a[2] ? a[2] : "{}");
        if (!opts) { fsql_fn_error(info, "fractalsql: out of memory"); return; }
        if (!fi_opt_str(opts, "name", name, sizeof name)) snprintf(name, sizeof name, "%.24s_%.24s", a[0] ? a[0] : "", a[1] ? a[1] : "");
        {
            char *id_col = NULL;
            char built[1400];
            char err2[ERRCAP];
            {
                char idbuf[64];
                if (fi_opt_str(opts, "id_col", idbuf, sizeof idbuf)) id_col = fsql_xstrdup(idbuf);
            }
            err2[0] = 0;
            if (fi_build(inst, name, a[0] ? a[0] : "", a[1] ? a[1] : "", id_col, opts, 0, built, sizeof built, err2, sizeof err2)) {
                fsql_fn_error(info, "%s", err2[0] ? err2 : "fractalsql: the index build failed");
                free(id_col);
                for (c = 0; c < nc; c++) free(a[c]);
                free(opts);
                return;
            }
            free(id_col);
            fsql_sb_init(&out_sb);
            fsql_sb_puts(&out_sb, built);
            fsql_set_str(out, i, fsql_sb_cstr(&out_sb), out_sb.len);
            fsql_sb_free(&out_sb);
        }
        for (c = 0; c < nc; c++) free(a[c]);
        free(opts);
    }
}

/* fractal_index_rebuild(name) -> JSON */
static void fi_rebuild_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out)
{
    fsql_instance *inst = fsql_scalar_instance(info);
    idx_t n = duckdb_data_chunk_get_size(in);
    idx_t i;
    for (i = 0; i < n; i++) {
        char *name = NULL;
        size_t l;
        const char *p;
        char built[1400], err2[ERRCAP];
        FiMeta mt;
        char opts[1024] = "{}";
        if (!fsql_valid(fsql_col_validity(in, 0), i)) { fsql_fn_error(info, "fractalsql: fractal_index_rebuild: no index name"); return; }
        p = fsql_str_data(&((const duckdb_string_t *)fsql_col_data(in, 0))[i], &l);
        name = fsql_xstrndup(p, l);
        if (!name) { fsql_fn_error(info, "fractalsql: out of memory"); return; }
        err2[0] = 0;
        if (fi_read_meta(inst, name, &mt, err2) != 0) {
            fsql_fn_error(info, "fractalsql: no such index");
            free(name);
            return;
        }
        {
            /* the stored options are re-used verbatim, so a rebuild keeps the shape of the index */
            fsql_sb sb;
            fsql_qres r;
            duckdb_data_chunk ch;
            fsql_sb_init(&sb);
            fsql_sb_puts(&sb, "SELECT options FROM fractal_index_meta WHERE name = ");
            fi_put_lit(&sb, name);
            if (!fsql_nested_query(inst, fsql_sb_cstr(&sb), &r, err2, ERRCAP)) {
                ch = fsql_qres_next_chunk(&r);
                if (ch && duckdb_data_chunk_get_size(ch) > 0) {
                    char *o = fi_cell_str(ch, 0, 0);
                    if (o) { snprintf(opts, sizeof opts, "%s", o); free(o); }
                }
                if (ch) duckdb_destroy_data_chunk(&ch);
                fsql_qres_free(&r);
            }
            fsql_sb_free(&sb);
        }
        if (fi_build(inst, name, mt.tbl, mt.col, mt.id_col, opts, 1, built, sizeof built, err2, sizeof err2)) {
            fsql_fn_error(info, "%s", err2[0] ? err2 : "fractalsql: the index rebuild failed");
            free(name);
            return;
        }
        {
            fsql_sb out_sb;
            fsql_sb_init(&out_sb);
            fsql_sb_puts(&out_sb, built);
            fsql_set_str(out, i, fsql_sb_cstr(&out_sb), out_sb.len);
            fsql_sb_free(&out_sb);
        }
        free(name);
    }
}

/* fractal_index_drop(name) -> BIGINT */
static void fi_drop_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out)
{
    fsql_instance *inst = fsql_scalar_instance(info);
    idx_t n = duckdb_data_chunk_get_size(in);
    int64_t *res = (int64_t *)duckdb_vector_get_data(out);
    char err[ERRCAP];
    idx_t i;
    if (fi_ensure_tables(inst, err)) { fsql_fn_error(info, "%s", err); return; }
    for (i = 0; i < n; i++) {
        char *name = NULL;
        size_t l;
        const char *p;
        fsql_sb sb;
        FiMeta mt;
        if (!fsql_valid(fsql_col_validity(in, 0), i)) { fsql_fn_error(info, "fractalsql: fractal_index_drop: no index name"); return; }
        p = fsql_str_data(&((const duckdb_string_t *)fsql_col_data(in, 0))[i], &l);
        name = fsql_xstrndup(p, l);
        if (!name) { fsql_fn_error(info, "fractalsql: out of memory"); return; }
        if (fi_read_meta(inst, name, &mt, err) != 0) { fsql_fn_error(info, "fractalsql: no such index"); free(name); return; }
        fsql_sb_init(&sb);
        fsql_sb_puts(&sb, "DELETE FROM fractal_index_cells WHERE name = "); fi_put_lit(&sb, name);
        if (fi_run(inst, fsql_sb_cstr(&sb), err)) { fsql_sb_free(&sb); fsql_fn_error(info, "%s", err); free(name); return; }
        fsql_sb_clear(&sb);
        fsql_sb_puts(&sb, "DELETE FROM fractal_index_stage WHERE name = "); fi_put_lit(&sb, name);
        if (fi_run(inst, fsql_sb_cstr(&sb), err)) { fsql_sb_free(&sb); fsql_fn_error(info, "%s", err); free(name); return; }
        fsql_sb_clear(&sb);
        fsql_sb_puts(&sb, "DELETE FROM fractal_index_meta WHERE name = "); fi_put_lit(&sb, name);
        if (fi_run(inst, fsql_sb_cstr(&sb), err)) { fsql_sb_free(&sb); fsql_fn_error(info, "%s", err); free(name); return; }
        fsql_sb_free(&sb);
        res[i] = 1;
        free(name);
    }
}

/* fractal_index_info(name) -> JSON */
/* ------------------------------------------------------------------ */
/* Health: what the index's state says about whether to trust it       */
/* ------------------------------------------------------------------ */

/* Thresholds behind the status and the advice in fractal_index_info. They are advice, never an error. */
#define FI_REFRESH_MAX_FRAC   0.25     /* more than this fraction of the rows added since the build: rebuild, do not just refresh */
#define FI_DELETED_MAX_FRAC   0.20     /* more than this fraction deleted: the cells hold many dead entries */

typedef struct {
    int64_t now, maxnow, added, deleted;
    int     stale, has_delta, have_calib, reaches_target, missing;
    double  target, recall;
} FiHealth;

/* The calibration JSON the build stored: whether it reached its target, the target, and the recall at the recommended nprobe. */
static void fi_calib_facts(const char *calib, FiHealth *h)
{
    const char *p = calib ? strstr(calib, "\"reaches_target\":") : NULL;
    h->have_calib = p != NULL;
    if (!p) return;
    h->reaches_target = strncmp(p + 17, "true", 4) == 0;
    {
        const char *t = strstr(calib, "\"target\":"), *r = strstr(calib, "\"recommended_nprobe\":");
        h->target = t ? strtod(t + 9, NULL) : 0.95;
        if (r) {
            long np = strtol(r + 21, NULL, 10);
            char key[48];
            const char *e;
            snprintf(key, sizeof key, "\"nprobe\":%ld,\"recall\":", np);
            e = strstr(calib, key);
            if (e) h->recall = strtod(e + strlen(key), NULL);
        }
    }
}

/* One nested query returning (BIGINT, BIGINT) in its first row. 0 = ok. */
static int fi_q2(fsql_instance *inst, const char *sql, int64_t *a, int64_t *b)
{
    fsql_qres r;
    duckdb_data_chunk ch;
    char err[ERRCAP];
    int rc = -1;
    if (fsql_nested_query(inst, sql, &r, err, ERRCAP)) return -1;
    ch = fsql_qres_next_chunk(&r);
    if (ch && duckdb_data_chunk_get_size(ch) > 0) { if (a) *a = fi_cell_i64(ch, 0, 0); if (b) *b = fi_cell_i64(ch, 1, 0); rc = 0; }
    if (ch) duckdb_destroy_data_chunk(&ch);
    fsql_qres_free(&r);
    return rc;
}

static void fi_health(fsql_instance *inst, const FiMeta *mt, FiHealth *h)
{
    fsql_sb q;
    char err[ERRCAP];
    memset(h, 0, sizeof *h);
    h->now = -1;
    fsql_sb_init(&q);
    fsql_sb_puts(&q, "SELECT count(*)::BIGINT, coalesce(max(");
    if (fi_quote_column(mt->id_col, &q, err)) { fsql_sb_free(&q); h->missing = 1; h->deleted = mt->rows; fi_calib_facts(mt->calib, h); return; }
    fsql_sb_puts(&q, "),0)::BIGINT FROM ");
    if (fi_quote_table(mt->tbl, &q, err)) { fsql_sb_free(&q); h->missing = 1; h->deleted = mt->rows; fi_calib_facts(mt->calib, h); return; }
    fsql_sb_puts(&q, " WHERE ");
    if (fi_quote_column(mt->col, &q, err)) { fsql_sb_free(&q); h->missing = 1; h->deleted = mt->rows; fi_calib_facts(mt->calib, h); return; }
    fsql_sb_puts(&q, " IS NOT NULL");
    /* The catalog outlives the table it indexes: a table, vector column or key column that is gone is "orphaned", not an error. */
    if (fi_q2(inst, fsql_sb_cstr(&q), &h->now, &h->maxnow) != 0) { fsql_sb_free(&q); h->missing = 1; h->deleted = mt->rows; fi_calib_facts(mt->calib, h); return; }
    fsql_sb_clear(&q);
    fsql_sb_puts(&q, "SELECT count(*)::BIGINT, 0::BIGINT FROM ");
    fi_quote_table(mt->tbl, &q, err);
    fsql_sb_puts(&q, " WHERE ");
    fi_quote_column(mt->col, &q, err);
    fsql_sb_puts(&q, " IS NOT NULL AND ");
    fi_quote_column(mt->id_col, &q, err);
    fsql_sb_printf(&q, " > %" PRId64, mt->max_id);
    fi_q2(inst, fsql_sb_cstr(&q), &h->added, NULL);
    fsql_sb_free(&q);
    h->deleted = mt->rows - (h->now - h->added);
    if (h->deleted < 0) h->deleted = 0;
    h->has_delta = h->added > 0;
    h->stale = h->now != mt->rows || h->maxnow != mt->max_id;
    fi_calib_facts(mt->calib, h);
}

/* ready | stale | degraded | empty | orphaned. "stale" here means there is something to do (rows were added, or many were deleted); the raw
 * stale flag in fractal_index_info is true for any change, including a few deleted rows the verify step already drops. */
static const char *fi_status(const FiMeta *mt, const FiHealth *h)
{
    double rows = mt->rows > 0 ? (double)mt->rows : 1.0;
    if (h->missing) return "orphaned";
    if (h->now == 0) return "empty";
    if (h->have_calib && !h->reaches_target) return "degraded";
    if (h->added > 0 || (h->deleted > 0 && (double)h->deleted / rows > FI_DELETED_MAX_FRAC)) return "stale";
    return "ready";
}

/* The advice list as a JSON array body (no brackets): every applicable item, most useful first. */
static void fi_advice(const FiMeta *mt, const FiHealth *h, fsql_sb *b)
{
    int n = 0, fmt = fi_parse_fmt(mt->fmt);
    double rows = mt->rows > 0 ? (double)mt->rows : 1.0;
    if (h->missing) {
        fsql_sb_printf(b, "\"the table %s or its columns %s and %s no longer exist; fractal_index_drop removes the index\"", mt->tbl, mt->col, mt->id_col);
        return;
    }
    if (h->now == 0) { fsql_sb_puts(b, "\"the table has no vectors; load rows and build the index again\""); n++; }
    if (h->have_calib && !h->reaches_target)
        fsql_sb_printf(b, "%s\"the build's calibration reached recall %.2f against a target of %.2f; %s\"", n++ ? "," : "", h->recall, h->target,
                       (fmt == FSQL_IVF_FMT_INT8 || fmt == FSQL_IVF_FMT_INT4) ? "rebuild with vector_format FP16 or FP32, or search with a larger rerank"
                                                                               : "rebuild with a smaller nlist, or lower the target");
    if (h->now > 0 && h->added > 0 && (double)h->added / rows > FI_REFRESH_MAX_FRAC)
        fsql_sb_printf(b, "%s\"rebuild: %.0f%% of the rows (%" PRId64 ") were added since the build, more than the cells were trained for\"", n++ ? "," : "",
                       100.0 * (double)h->added / rows, h->added);
    else if (h->added > 0)
        fsql_sb_printf(b, "%s\"refresh: %" PRId64 " rows (%.0f%% of the index) were added since the build; fractal_index_refresh folds them in\"", n++ ? "," : "",
                      h->added, 100.0 * (double)h->added / rows);
    if (h->deleted > 0 && (double)h->deleted / rows > FI_DELETED_MAX_FRAC)
        fsql_sb_printf(b, "%s\"rebuild: %" PRId64 " rows (%.0f%%) were deleted since the build; they are dropped from results but still held in the cells\"", n++ ? "," : "",
                       h->deleted, 100.0 * (double)h->deleted / rows);
}

/* Folds the rows added since the build (id above the watermark) into the cells: each new row is encoded with the index's existing model
 * (no retraining), staged, and merged into a NEW generation of the cells in one statement; the metadata pointer is flipped last, so a reader
 * only ever sees a complete generation. Deleted rows and rows whose vector changed in place are not touched. */
static int fi_refresh(fsql_instance *inst, const char *name, char *out, size_t ocap, char *err, size_t ecap)
{
    FiMeta mt;
    fsql_sb sb;
    fsql_qres r;
    duckdb_data_chunk ch;
    fsql_ivf_model *m = NULL;
    fsql_ivf_info_t info;
    uint8_t *blob = NULL;
    size_t blen = 0;
    char pkq[FI_IDENT_MAX_SEGMENT + 8], extra[96];
    int64_t new_gen, rows_added = 0, max_id = 0;
    int rc = -1;
    if (fi_ensure_tables(inst, err)) return -1;
    if (fi_read_meta(inst, name, &mt, err) != 0) { snprintf(err, ecap, "fractalsql: no index named '%s'", name); return -1; }
    fsql_sb_init(&sb);
    fsql_sb_puts(&sb, "SELECT model_blob FROM fractal_index_meta WHERE name = ");
    fi_put_lit(&sb, name);
    if (fsql_nested_query(inst, fsql_sb_cstr(&sb), &r, err, ecap)) { fsql_sb_free(&sb); return -1; }
    fsql_sb_free(&sb);
    ch = fsql_qres_next_chunk(&r);
    if (ch && duckdb_data_chunk_get_size(ch) > 0) {
        char *hex = fi_cell_str(ch, 0, 0);
        if (hex && *hex) {
            blen = strlen(hex) / 2;
            blob = (uint8_t *)malloc(blen ? blen : 1);
            if (!blob || fi_unhex(hex, blob, blen) != 0) { free(blob); blob = NULL; }
        }
        free(hex);
    }
    if (ch) duckdb_destroy_data_chunk(&ch);
    fsql_qres_free(&r);
    if (blob) m = fi_ivf_model_load(blob, blen, NULL);
    free(blob);
    if (!m || fi_ivf_model_info(m, &info) != FSQL_OK) {
        if (m) fi_ivf_model_free(m);
        snprintf(err, ecap, "fractalsql: index '%s' has a missing or corrupt model; rebuild it", name);
        return -1;
    }
    fsql_sb_init(&sb);
    if (fi_quote_column(mt.id_col, &sb, err)) { fsql_sb_free(&sb); fi_ivf_model_free(m); return -1; }
    snprintf(pkq, sizeof pkq, "%s", fsql_sb_cstr(&sb));
    fsql_sb_free(&sb);
    snprintf(extra, sizeof extra, " AND %s > %" PRId64, pkq, mt.max_id);
    new_gen = mt.generation + 1;
    if (fi_encode_pass(inst, pkq, mt.tbl, mt.col, m, info.code_bytes, (int)mt.dim, name, new_gen, &rows_added, &max_id, NULL, extra, err)) goto fail;
    if (rows_added == 0) {
        snprintf(out, ocap, "{\"name\":\"%s\",\"added\":0,\"rows\":%" PRId64 ",\"generation\":%" PRId64 ",\"refreshed\":false}", name, mt.rows, mt.generation);
        rc = 0;
        goto done;
    }
    /* the old cells, with the staged rows appended, as the new generation */
    fsql_sb_init(&sb);
    fsql_sb_printf(&sb, "INSERT INTO fractal_index_cells(name, generation, cell, n, ids, codes) "
                        "SELECT c.name, %" PRId64 ", c.cell, c.n + coalesce(s.k, 0), "
                        "list_concat(c.ids, coalesce(s.ids, []::BIGINT[])), list_concat(c.codes, coalesce(s.codes, []::VARCHAR[])) "
                        "FROM fractal_index_cells c LEFT JOIN (SELECT cell, count(*)::BIGINT AS k, list(id ORDER BY id) AS ids, list(code ORDER BY id) AS codes "
                        "FROM fractal_index_stage WHERE name = ", new_gen);
    fi_put_lit(&sb, name);
    fsql_sb_printf(&sb, " AND generation = %" PRId64 " GROUP BY cell) s ON s.cell = c.cell WHERE c.name = ", new_gen);
    fi_put_lit(&sb, name);
    fsql_sb_printf(&sb, " AND c.generation = %" PRId64, mt.generation);
    if (fi_run(inst, fsql_sb_cstr(&sb), err)) { fsql_sb_free(&sb); goto fail; }
    fsql_sb_clear(&sb);
    fsql_sb_printf(&sb, "UPDATE fractal_index_meta SET rows = %" PRId64 ", max_id = %" PRId64 ", generation = %" PRId64 " WHERE name = ",
                   mt.rows + rows_added, max_id > mt.max_id ? max_id : mt.max_id, new_gen);
    fi_put_lit(&sb, name);
    if (fi_run(inst, fsql_sb_cstr(&sb), err)) { fsql_sb_free(&sb); goto fail; }
    fsql_sb_clear(&sb);
    fsql_sb_puts(&sb, "DELETE FROM fractal_index_cells WHERE name = ");
    fi_put_lit(&sb, name);
    fsql_sb_printf(&sb, " AND generation < %" PRId64, new_gen);
    fi_run(inst, fsql_sb_cstr(&sb), err);
    fsql_sb_free(&sb);
    snprintf(out, ocap, "{\"name\":\"%s\",\"added\":%" PRId64 ",\"rows\":%" PRId64 ",\"generation\":%" PRId64 ",\"max_id\":%" PRId64 ",\"refreshed\":true}",
             name, rows_added, mt.rows + rows_added, new_gen, max_id > mt.max_id ? max_id : mt.max_id);
    rc = 0;
    goto done;
fail:
    rc = -1;
done:
    /* the staging rows are never kept, and a failed refresh leaves no half-generation behind */
    {
        fsql_sb junk;
        char e2[ERRCAP];
        fsql_sb_init(&junk);
        fsql_sb_puts(&junk, "DELETE FROM fractal_index_stage WHERE name = ");
        fi_put_lit(&junk, name);
        fi_run(inst, fsql_sb_cstr(&junk), e2);
        if (rc) {
            fsql_sb_clear(&junk);
            fsql_sb_puts(&junk, "DELETE FROM fractal_index_cells WHERE name = ");
            fi_put_lit(&junk, name);
            fsql_sb_printf(&junk, " AND generation = %" PRId64, new_gen);
            fi_run(inst, fsql_sb_cstr(&junk), e2);
        }
        fsql_sb_free(&junk);
    }
    fi_ivf_model_free(m);
    return rc;
}

static void fi_refresh_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out)
{
    fsql_instance *inst = fsql_scalar_instance(info);
    idx_t n = duckdb_data_chunk_get_size(in);
    idx_t i;
    for (i = 0; i < n; i++) {
        char *name = NULL;
        size_t l;
        const char *p;
        char res[512], err2[ERRCAP];
        if (!fsql_valid(fsql_col_validity(in, 0), i)) { fsql_fn_error(info, "fractalsql: fractal_index_refresh: no index name"); return; }
        p = fsql_str_data(&((const duckdb_string_t *)fsql_col_data(in, 0))[i], &l);
        name = fsql_xstrndup(p, l);
        if (!name) { fsql_fn_error(info, "fractalsql: out of memory"); return; }
        err2[0] = 0;
        if (fi_refresh(inst, name, res, sizeof res, err2, sizeof err2) != 0) {
            fsql_fn_error(info, "%s", err2[0] ? err2 : "fractalsql: the index refresh failed");
            free(name);
            return;
        }
        fsql_set_str(out, i, res, strlen(res));
        free(name);
    }
}

/* The first column of the first row of `sql` as text (malloc'd); NULL when there is none or the query fails (message in err). */
static char *fi_first_text(fsql_instance *inst, const char *sql, char *err)
{
    fsql_qres r;
    char *out = NULL;
    if (fsql_nested_query(inst, sql, &r, err, ERRCAP)) return NULL;
    if (duckdb_row_count(&r.res) > 0) {
        char *v = duckdb_value_varchar(&r.res, 0, 0);
        if (v) { out = fsql_xstrdup(v); duckdb_free(v); }
    }
    fsql_qres_free(&r);
    return out;
}

/* fractal_index_ensure(table, column [, options]) -> {name, action, status, generation, rows}
 * Leaves the index on that table and column fit to use: builds it when missing (created), folds in the added rows when that is all that is
 * needed (refreshed), rebuilds after a large change (rebuilt), otherwise changes nothing (unchanged). Done through the extension's own
 * management functions, so each step is exactly what calling it by hand does. */
static void fi_ensure_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out)
{
    fsql_instance *inst = fsql_scalar_instance(info);
    idx_t n = duckdb_data_chunk_get_size(in);
    idx_t nc = duckdb_data_chunk_get_column_count(in);
    if (nc < 2 || nc > 3) { fsql_fn_error(info, "fractalsql: fractal_index_ensure takes 2 or 3 arguments"); return; }
    for (idx_t i = 0; i < n; i++) {
        char *a[3] = { NULL, NULL, NULL };
        char err[ERRCAP] = "", name[64] = "";
        const char *action = "unchanged";
        for (idx_t c = 0; c < nc; c++) {
            size_t l; const char *p;
            if (!fsql_valid(fsql_col_validity(in, c), i)) { a[c] = fsql_xstrdup(c == 2 ? "{}" : ""); continue; }
            p = fsql_str_data(&((const duckdb_string_t *)fsql_col_data(in, c))[i], &l);
            a[c] = fsql_xstrndup(p, l);
        }
        if (!a[2]) a[2] = fsql_xstrdup("{}");
        if (!a[0] || !a[1] || !a[2]) { fsql_fn_error(info, "fractalsql: out of memory"); return; }
        int have_opts = strcmp(a[2], "{}") != 0 && *a[2];
        fsql_sb q; fsql_sb_init(&q);
        fsql_sb_puts(&q, "SELECT name FROM fractal_index_meta WHERE tbl = "); fi_put_lit(&q, a[0]);
        fsql_sb_puts(&q, " AND col = "); fi_put_lit(&q, a[1]); fsql_sb_puts(&q, " ORDER BY name LIMIT 1");
        char *found = fi_first_text(inst, fsql_sb_cstr(&q), err);      /* an error here: the catalog does not exist yet, so no index does */
        fsql_sb_free(&q);
        err[0] = 0;
        char *res = NULL;
        if (!found) {
            if (!fi_opt_str(a[2], "name", name, sizeof name)) snprintf(name, sizeof name, "%.24s_%.24s", a[0], a[1]);
            fsql_sb_init(&q);
            fsql_sb_puts(&q, "SELECT fractal_index_create("); fi_put_lit(&q, a[0]); fsql_sb_putc(&q, ','); fi_put_lit(&q, a[1]);
            fsql_sb_putc(&q, ','); fi_put_lit(&q, a[2]); fsql_sb_putc(&q, ')');
            res = fi_first_text(inst, fsql_sb_cstr(&q), err);
            fsql_sb_free(&q);
            if (!res) { fsql_fn_error(info, "%s", err[0] ? err : "fractalsql: the index build failed"); goto bad; }
            free(res); res = NULL;
            action = "created";
        } else {
            snprintf(name, sizeof name, "%s", found);
            free(found);
            fsql_sb_init(&q);
            fsql_sb_puts(&q, "SELECT json_extract_string(i, '$.status') || chr(1) || json_extract(i, '$.rows_added_since_build')::VARCHAR || chr(1) || "
                             "json_extract(i, '$.rows_deleted_since_build')::VARCHAR || chr(1) || json_extract(i, '$.rows_indexed')::VARCHAR FROM (SELECT fractal_index_info(");
            fi_put_lit(&q, name); fsql_sb_puts(&q, ") AS i)");
            char *st = fi_first_text(inst, fsql_sb_cstr(&q), err);
            fsql_sb_free(&q);
            if (!st) { fsql_fn_error(info, "%s", err[0] ? err : "fractalsql: could not read the index"); goto bad; }
            char *f1 = strchr(st, '\x01'), *f2 = f1 ? strchr(f1 + 1, '\x01') : NULL, *f3 = f2 ? strchr(f2 + 1, '\x01') : NULL;
            if (!f3) { free(st); fsql_fn_error(info, "fractalsql: could not read the index"); goto bad; }
            *f1 = *f2 = *f3 = '\0';
            double added = atof(f1 + 1), deleted = atof(f2 + 1), rows = atof(f3 + 1);
            if (rows < 1) rows = 1;
            int big = added / rows > 0.25 || deleted / rows > 0.20;
            const char *cmd = NULL;
            if (!strcmp(st, "degraded")) { if (have_opts) cmd = "rebuild_new"; }
            else if (!strcmp(st, "stale")) cmd = big ? "rebuild" : (added > 0 ? "refresh" : NULL);
            free(st);
            if (cmd) {
                fsql_sb_init(&q);
                if (!strcmp(cmd, "refresh")) { fsql_sb_puts(&q, "SELECT fractal_index_refresh("); fi_put_lit(&q, name); fsql_sb_putc(&q, ')'); action = "refreshed"; }
                else if (!strcmp(cmd, "rebuild")) { fsql_sb_puts(&q, "SELECT fractal_index_rebuild("); fi_put_lit(&q, name); fsql_sb_putc(&q, ')'); action = "rebuilt"; }
                else {
                    /* a degraded index with new options: drop it and build again with them */
                    fsql_sb d; fsql_sb_init(&d);
                    fsql_sb_puts(&d, "SELECT fractal_index_drop("); fi_put_lit(&d, name); fsql_sb_putc(&d, ')');
                    free(fi_first_text(inst, fsql_sb_cstr(&d), err)); fsql_sb_free(&d);
                    fsql_sb_puts(&q, "SELECT fractal_index_create("); fi_put_lit(&q, a[0]); fsql_sb_putc(&q, ','); fi_put_lit(&q, a[1]);
                    fsql_sb_putc(&q, ','); fi_put_lit(&q, a[2]); fsql_sb_putc(&q, ')'); action = "rebuilt";
                }
                res = fi_first_text(inst, fsql_sb_cstr(&q), err);
                fsql_sb_free(&q);
                if (!res) { fsql_fn_error(info, "%s", err[0] ? err : "fractalsql: the index update failed"); goto bad; }
                free(res); res = NULL;
            }
        }
        {
            fsql_sb q2; fsql_sb_init(&q2);
            fsql_sb_puts(&q2, "SELECT json_object('name', ");
            fi_put_lit(&q2, name);
            fsql_sb_printf(&q2, ", 'action', '%s', 'status', json_extract_string(i, '$.status'), 'generation', json_extract(i, '$.generation')::BIGINT, "
                                "'rows', json_extract(i, '$.rows_indexed')::BIGINT)::VARCHAR FROM (SELECT fractal_index_info(", action);
            fi_put_lit(&q2, name); fsql_sb_puts(&q2, ") AS i)");
            res = fi_first_text(inst, fsql_sb_cstr(&q2), err);
            fsql_sb_free(&q2);
            if (!res) { fsql_fn_error(info, "%s", err[0] ? err : "fractalsql: could not read the index"); goto bad; }
            fsql_set_str(out, i, res, strlen(res));
            free(res);
        }
        free(a[0]); free(a[1]); free(a[2]);
        continue;
bad:
        free(a[0]); free(a[1]); free(a[2]);
        return;
    }
}

static void fi_info_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out)
{
    fsql_instance *inst = fsql_scalar_instance(info);
    idx_t n = duckdb_data_chunk_get_size(in);
    char err[ERRCAP];
    idx_t i;
    for (i = 0; i < n; i++) {
        char *name = NULL;
        size_t l;
        const char *p;
        FiMeta mt;
        FiHealth h;
        fsql_sb sb, adv;
        FIdxState *S = fi_state(inst);
        if (!fsql_valid(fsql_col_validity(in, 0), i)) { fsql_fn_error(info, "fractalsql: fractal_index_info: no index name"); return; }
        p = fsql_str_data(&((const duckdb_string_t *)fsql_col_data(in, 0))[i], &l);
        name = fsql_xstrndup(p, l);
        if (!name) { fsql_fn_error(info, "fractalsql: out of memory"); return; }
        if (fi_read_meta(inst, name, &mt, err) != 0) { fsql_fn_error(info, "fractalsql: no such index"); free(name); return; }
        fi_health(inst, &mt, &h);
        fsql_sb_init(&adv);
        fi_advice(&mt, &h, &adv);
        fsql_sb_init(&sb);
        fsql_sb_printf(&sb, "{\"name\":\"%s\",\"table\":\"%s\",\"column\":\"%s\",\"id_col\":\"%s\",\"metric\":\"cosine\",\"format\":\"%s\","
                            "\"dim\":%" PRId64 ",\"model\":\"%s\",\"nlist\":%" PRId64 ",\"pca_dim\":%" PRId64 ",\"generation\":%" PRId64 ","
                            "\"format_version\":%" PRId64 ",\"seed\":%" PRId64 ",\"built_at\":\"%s\",\"rows_indexed\":%" PRId64 ","
                            "\"rows_now\":%" PRId64 ",\"max_id_indexed\":%" PRId64 ",\"max_id_now\":%" PRId64 ","
                            "\"has_delta\":%s,\"stale\":%s,\"rows_added_since_build\":%" PRId64 ",\"rows_deleted_since_build\":%" PRId64 ","
                            "\"status\":\"%s\",\"advice\":[%s],"
                            "\"rerank_default\":%zu,\"nprobe_default\":%" PRId64 ",\"calibration\":%s,",
                        mt.name, mt.tbl, mt.col, mt.id_col, mt.fmt, mt.dim, mt.model, mt.nlist, mt.pca_dim, mt.generation,
                        mt.format_version, mt.seed, mt.built_at, mt.rows, h.now, mt.max_id, h.maxnow,
                        h.has_delta ? "true" : "false", h.stale ? "true" : "false", h.added, h.deleted,
                        fi_status(&mt, &h), fsql_sb_cstr(&adv),
                        fi_default_rerank(fi_parse_fmt(mt.fmt)), mt.nprobe_default, mt.calib[0] ? mt.calib : "{}");
        fsql_sb_free(&adv);
        if (S) {
            fsql_mu_lock(&S->mu);
            fsql_sb_printf(&sb, "\"last_search\":{\"used_index\":%s,\"rows_scanned\":%" PRId64 ",\"cells_probed\":%d,\"lookups\":%d,\"index\":\"%s\"}",
                           S->last_used_index ? "true" : "false", S->last_rows_scanned, S->last_cells_probed, S->last_lookups,
                           S->last_index);
            fsql_mu_unlock(&S->mu);
        } else {
            fsql_sb_puts(&sb, "\"last_search\":{\"used_index\":false,\"rows_scanned\":0,\"cells_probed\":0,\"lookups\":0,\"index\":\"\"}");
        }
        fsql_sb_putc(&sb, '}');
        fsql_set_str(out, i, fsql_sb_cstr(&sb), sb.len);
        fsql_sb_free(&sb);
        free(name);
    }
}

/* ------------------------------------------------------------------ */
/* The bind-time parameter readers                                     */
/* ------------------------------------------------------------------ */
/* A table function's arguments arrive as duckdb_values, so the strings and the query vector are
 * read through the value API (the same shape the host's other table functions use). */

static char *fi_bp_str(duckdb_bind_info info, idx_t i)
{
    duckdb_value v = duckdb_bind_get_parameter(info, i);
    char *r;
    if (duckdb_is_null_value(v)) r = fsql_xstrdup("NULL");
    else { char *s = duckdb_get_varchar(v); r = fsql_xstrdup(s ? s : ""); if (s) duckdb_free(s); }
    duckdb_destroy_value(&v);
    return r;
}

static bool fi_bp_int(duckdb_bind_info info, idx_t i, int64_t *out)
{
    duckdb_value v = duckdb_bind_get_parameter(info, i);
    bool ok = !duckdb_is_null_value(v);
    if (ok) *out = duckdb_get_int64(v);
    duckdb_destroy_value(&v);
    return ok;
}

/* A LIST(DOUBLE) parameter appended to `out`. false when the list (or an element) is NULL. */
static bool fi_bp_vec(duckdb_bind_info info, idx_t i, fsql_vecd *out)
{
    duckdb_value v = duckdb_bind_get_parameter(info, i);
    idx_t n;
    bool ok = true;
    if (duckdb_is_null_value(v)) { duckdb_destroy_value(&v); return false; }
    n = duckdb_get_list_size(v);
    for (idx_t k = 0; k < n && ok; k++) {
        duckdb_value c = duckdb_get_list_child(v, k);
        if (duckdb_is_null_value(c)) ok = false;
        else fsql_vecd_push(out, duckdb_get_double(c));
        duckdb_destroy_value(&c);
    }
    duckdb_destroy_value(&v);
    return ok;
}

/* ------------------------------------------------------------------ */
/* The indexed search                                                   */
/* ------------------------------------------------------------------ */

/* The result columns: the SAME columns fractal_search_telemetry returns (doc_id, distance,
 * scan_pos). doc_id is the row's stable locator (the primary key, rendered as text); scan_pos is
 * the row's stable id in the indexed path (an indexed search does not scan the table) and the
 * 0-indexed position in the exact fallback. */
static const char *const kSearchCols[] = { "doc_id", "distance", "scan_pos" };
static const fsql_rs_ty  kSearchTys[]  = { FSQL_RS_VARCHAR, FSQL_RS_DOUBLE, FSQL_RS_BIGINT };

/* The ids option: restrict a search to a set of keys (a JSON array, for example from list(id) over an ordinary WHERE). A short set is scanned
 * exactly; a long one goes through the index and is filtered, and when that leaves fewer than k rows the set is scanned exactly, so the answer
 * is never short just because the index's shortlist missed the set. */
#define FI_IDS_MAX         1000000
#define FI_IDS_EXACT_MAX   4096

typedef struct { int64_t *v; size_t n; } FiIds;

static int fi_ids_cmp(const void *a, const void *b)
{
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

static int fi_ids_has(const FiIds *s, int64_t id)
{
    size_t lo = 0, hi = s->n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (s->v[mid] == id) return 1;
        if (s->v[mid] < id) lo = mid + 1; else hi = mid;
    }
    return 0;
}

/* 0: no ids option; 1: parsed (sorted, de-duplicated); -1: malformed (err filled). */
static int fi_ids_parse(const char *opts, FiIds *out, char *err)
{
    const char *p = opts ? fi_json_find(opts, "ids") : NULL;
    size_t cap = 64, n = 0, w = 0, i;
    int64_t *v;
    if (!p) return 0;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p != '[') { snprintf(err, ERRCAP, "fractalsql: ids must be a JSON array of integer keys"); return -1; }
    p++;
    v = (int64_t *)malloc(cap * sizeof(int64_t));
    if (!v) { snprintf(err, ERRCAP, "fractalsql: out of memory"); return -1; }
    for (;;) {
        char *e;
        long long x;
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
        if (*p == ']') break;
        errno = 0;
        x = strtoll(p, &e, 10);
        if (e == p || errno == ERANGE) { free(v); snprintf(err, ERRCAP, "fractalsql: ids must be a JSON array of integer keys"); return -1; }
        if (n >= FI_IDS_MAX) { free(v); snprintf(err, ERRCAP, "fractalsql: ids holds more than %d keys", FI_IDS_MAX); return -1; }
        if (n == cap) { int64_t *nv; cap *= 2; nv = (int64_t *)realloc(v, cap * sizeof(int64_t)); if (!nv) { free(v); snprintf(err, ERRCAP, "fractalsql: out of memory"); return -1; } v = nv; }
        v[n++] = (int64_t)x;
        p = e;
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
        if (*p == ',') { p++; continue; }
        if (*p == ']') break;
        free(v); snprintf(err, ERRCAP, "fractalsql: ids must be a JSON array of integer keys"); return -1;
    }
    qsort(v, n, sizeof(int64_t), fi_ids_cmp);
    for (i = 0; i < n; i++) if (w == 0 || v[i] != v[w - 1]) v[w++] = v[i];
    out->v = v; out->n = w;
    return 1;
}

/* " AND <idq> IN (a, b, c)" (with an optional extra lower bound) as an `extra` fragment for fi_exact_scan. */
static void fi_ids_extra(fsql_sb *sb, const char *idq, const FiIds *ids, int64_t above)
{
    size_t i;
    fsql_sb_puts(sb, " AND ");
    fsql_sb_puts(sb, idq);
    fsql_sb_puts(sb, " IN (");
    for (i = 0; i < ids->n; i++) fsql_sb_printf(sb, "%s%" PRId64, i ? "," : "", ids->v[i]);
    if (ids->n == 0) fsql_sb_puts(sb, "NULL");
    fsql_sb_putc(sb, ')');
    if (above != INT64_MIN) { fsql_sb_puts(sb, " AND "); fsql_sb_puts(sb, idq); fsql_sb_printf(sb, " > %" PRId64, above); }
}

/* The search itself. Fills `res` with the best k candidates (sorted by distance, then id).
 * 0 = ok; -1 with the message in `err`. */
static int fi_search_run_impl(fsql_instance *inst, const char *tbl, const char *col, const double *q, size_t qn,
                              int k, const char *opts, const FiIds *ids, FiCand *res, int *nres, char *err)
{
    int use_index = fi_opt_bool(opts, "use_index", 1);
    int verify = fi_opt_bool(opts, "verify", 1);
    double nprobe_d = fi_opt_num(opts, "nprobe", 0);
    double rerank_d = fi_opt_num(opts, "rerank", -1);
    FIdxState *S = fi_state(inst);
    FIdx *x = NULL;
    char index_name[64] = "";
    char qmodel[64];
    int have_model = fi_opt_str(opts, "model", qmodel, sizeof qmodel);
    int64_t scanned = 0;
    int cells_probed = 0, lookups = 0, used_index = 0;
    int rc = 0;
    int have_ids = ids != NULL, exact_ids;

    if (use_index && fi_ivf_available() && S) {
        if (!fi_opt_str(opts, "index", index_name, sizeof index_name)) {
            if (!fi_find_name(inst, tbl, col, index_name, sizeof index_name, err)) index_name[0] = 0;
        }
        if (index_name[0]) {
            fsql_mu_lock(&S->mu);
            x = fi_load_locked(S, inst, index_name, err, ERRCAP);
            fsql_mu_unlock(&S->mu);
            if (!x) { return -1; }
        }
    }
    exact_ids = have_ids && (x == NULL || ids->n <= FI_IDS_EXACT_MAX);

    if (exact_ids) {
        /* a short set (or no index): only the rows the ids name are read, and scanned exactly */
        int dim = (int)qn;
        char idq[FI_IDENT_MAX_SEGMENT + 8] = "";
        fsql_sb extra;
        if (dim <= 0) { snprintf(err, ERRCAP, "fractalsql: fractal_search: the query vector is empty"); return -1; }
        if (x) {
            fsql_sb q;
            if ((int)qn != x->dim) { snprintf(err, ERRCAP, "fractalsql: fractal_search: the query dimension %zu does not match index '%s' (%d)", qn, x->name, x->dim); return -1; }
            fsql_sb_init(&q);
            if (fi_quote_column(x->id_col, &q, err) == 0) snprintf(idq, sizeof idq, "%s", fsql_sb_cstr(&q));
            fsql_sb_free(&q);
        } else {
            char *pk = fi_detect_pk(inst, tbl, err);
            if (pk) {
                fsql_sb q;
                fsql_sb_init(&q);
                if (fi_quote_column(pk, &q, err) == 0) snprintf(idq, sizeof idq, "%s", fsql_sb_cstr(&q));
                fsql_sb_free(&q);
                free(pk);
            }
            if (!idq[0]) { snprintf(idq, sizeof idq, "rowid"); err[0] = 0; }
        }
        fsql_sb_init(&extra);
        fi_ids_extra(&extra, idq, ids, INT64_MIN);
        rc = fi_exact_scan(inst, idq, tbl, col, q, dim, k, fsql_sb_cstr(&extra), res, nres, &scanned, err);
        fsql_sb_free(&extra);
        if (rc) { return -1; }
    } else if (x) {
        /* the indexed path */
        int dim = x->dim;
        int nprobe;
        size_t rr, R, ncand = 0, j;
        float *qf;
        int64_t *cid;
        double *cd;
        fsql_ivf_stats_t st;

        if ((int)qn != dim) {
            snprintf(err, ERRCAP, "fractalsql: fractal_search: the query dimension %zu does not match index '%s' (%d)",
                     qn, x->name, dim);
            return -1;
        }
        if (have_model && x->model[0] && strcmp(qmodel, x->model)) {
            snprintf(err, ERRCAP, "fractalsql: fractal_search: model '%s' does not match index '%s' (built for '%s'); rebuild the index",
                     qmodel, x->name, x->model);
            return -1;
        }
        nprobe = nprobe_d > 0 ? (int)(nprobe_d > 1e9 ? 1e9 : nprobe_d) : (x->nprobe_default > 0 ? x->nprobe_default : 16);
        if (nprobe < 1) nprobe = 1;
        if (nprobe > x->nlist) nprobe = x->nlist;
        rr = fi_default_rerank(x->fmt);
        if (rerank_d >= 0) {
            if (rerank_d > 100000) { snprintf(err, ERRCAP, "fractalsql: fractal_search: rerank out of range"); return -1; }
            if (x->fmt == FSQL_IVF_FMT_INT4 && rerank_d < 20) {
                snprintf(err, ERRCAP, "fractalsql: fractal_search: INT4 indexes always rerank; rerank must be at least 20");
                return -1;
            }
            rr = (size_t)rerank_d;
        }
        R = rr > (size_t)k ? rr : (size_t)k + 5u;
        if (R > (size_t)k + 400u) R = (size_t)k + 400u;
        if (have_ids) R = (size_t)k + 400u;                  /* a filtered search needs a deeper shortlist to still have k rows left */

        qf = (float *)malloc((size_t)dim * sizeof(float));
        cid = (int64_t *)malloc(R * sizeof(int64_t));
        cd = (double *)malloc(R * sizeof(double));
        if (!qf || !cid || !cd) { free(qf); free(cid); free(cd); snprintf(err, ERRCAP, "fractalsql: out of memory"); return -1; }
        for (j = 0; j < (size_t)dim; j++) {
            if (!isfinite(q[j]) || fabs(q[j]) > 3.0e38) {
                free(qf); free(cid); free(cd);
                snprintf(err, ERRCAP, "fractalsql: fractal_search: the query contains non-finite values");
                return -1;
            }
            qf[j] = (float)q[j];
        }
        {
            int sr;
            fsql_mu_lock(&S->mu);
            sr = fi_ivf_search(x->x, qf, (uint32_t)nprobe, (uint32_t)R, cid, cd, &ncand, &st);
            fsql_mu_unlock(&S->mu);
            if (sr != FSQL_OK) {
                free(qf); free(cid); free(cd);
                snprintf(err, ERRCAP, "fractalsql: fractal_search: the index search failed");
                return -1;
            }
            scanned = (int64_t)st.rows_scanned;
            cells_probed = (int)st.cells_probed;
        }
        free(qf);
        used_index = 1;

        /* the delta: the rows newer than the index (their id is above the largest indexed id) */
        {
            fsql_sb extra, idq;
            fsql_sb_init(&idq);
            fsql_sb_init(&extra);
            if (fi_quote_column(x->id_col, &idq, err)) { fsql_sb_free(&idq); fsql_sb_free(&extra); free(cid); free(cd); return -1; }
            if (have_ids) {
                fi_ids_extra(&extra, fsql_sb_cstr(&idq), ids, x->max_id);
            } else {
                fsql_sb_puts(&extra, " AND ");
                fsql_sb_puts(&extra, fsql_sb_cstr(&idq));
                fsql_sb_printf(&extra, " > %" PRId64, x->max_id);
            }
            rc = fi_exact_scan(inst, fsql_sb_cstr(&idq), tbl, col, q, dim, k, fsql_sb_cstr(&extra), res, nres, &scanned, err);
            fsql_sb_free(&idq);
            fsql_sb_free(&extra);
        }
        if (rc) { free(cid); free(cd); return -1; }

        if (have_ids) {                                       /* keep only the shortlist rows that are in the set */
            size_t w = 0;
            for (j = 0; j < ncand; j++) if (fi_ids_has(ids, cid[j])) { cid[w] = cid[j]; cd[w] = cd[j]; w++; }
            ncand = w;
        }
        /* the verify step: the shortlist is fetched from the base table and its distances are
           recomputed exactly (a deleted row is dropped) */
        if ((verify || have_ids) && ncand > 0) {
            rc = fi_verify_rows(inst, tbl, col, x->id_col, cid, ncand, q, dim, k, res, nres, &lookups, err);
        } else if (!verify && !have_ids) {
            for (j = 0; j < ncand && (int)j < k; j++) { FiCand cand; cand.id = cid[j]; cand.d = cd[j]; fi_ins(res, nres, k, cand); }
        }
        free(cid); free(cd);
        if (rc) { return -1; }
        /* the filter left fewer than k rows: the set is small enough that scanning it exactly is the honest answer */
        if (have_ids && *nres < k && (size_t)*nres < ids->n) {
            fsql_sb idq, extra;
            fsql_sb_init(&idq); fsql_sb_init(&extra);
            if (fi_quote_column(x->id_col, &idq, err)) { fsql_sb_free(&idq); fsql_sb_free(&extra); return -1; }
            fi_ids_extra(&extra, fsql_sb_cstr(&idq), ids, INT64_MIN);
            *nres = 0;
            rc = fi_exact_scan(inst, fsql_sb_cstr(&idq), tbl, col, q, dim, k, fsql_sb_cstr(&extra), res, nres, &scanned, err);
            fsql_sb_free(&idq); fsql_sb_free(&extra);
            used_index = 0;
            if (rc) { return -1; }
        }
    } else {
        /* the exact fallback: the whole table, scanned exactly */
        int dim = (int)qn;
        char idq[FI_IDENT_MAX_SEGMENT + 8] = "";
        char *pk = NULL;
        if (dim <= 0) { snprintf(err, ERRCAP, "fractalsql: fractal_search: the query vector is empty"); return -1; }
        /* the row id: the table's primary key, or rowid when it has none */
        pk = fi_detect_pk(inst, tbl, err);
        if (pk) {
            fsql_sb q;
            fsql_sb_init(&q);
            if (fi_quote_column(pk, &q, err) == 0) snprintf(idq, sizeof idq, "%s", fsql_sb_cstr(&q));
            fsql_sb_free(&q);
            free(pk);
        }
        if (!idq[0]) { snprintf(idq, sizeof idq, "rowid"); err[0] = 0; }   /* no key: not an error here */
        rc = fi_exact_scan(inst, idq, tbl, col, q, dim, k, NULL, res, nres, &scanned, err);
        if (rc) return -1;
    }

    if (S) {
        fsql_mu_lock(&S->mu);
        S->last_rows_scanned = scanned;
        S->last_cells_probed = cells_probed;
        S->last_used_index = used_index;
        S->last_lookups = lookups;
        snprintf(S->last_index, sizeof S->last_index, "%s", index_name);
        fsql_mu_unlock(&S->mu);
    }
    return 0;
}

/* The search: parses the ids option once and always frees it, whichever way the body returns. */
static int fi_search_run(fsql_instance *inst, const char *tbl, const char *col, const double *q, size_t qn,
                         int k, const char *opts, FiCand *res, int *nres, char *err)
{
    FiIds ids = { NULL, 0 };
    int pr = fi_ids_parse(opts, &ids, err), rc;
    if (pr < 0) return -1;
    rc = fi_search_run_impl(inst, tbl, col, q, qn, k, opts, pr > 0 ? &ids : NULL, res, nres, err);
    free(ids.v);
    return rc;
}

/* fractal_search(table, column, query, k, options) -> TABLE(doc_id, distance, scan_pos)
 * The indexed search: the index proposes the candidates, the base table verifies every one of them
 * with the shared double-precision cosine, and the delta (the rows newer than the index) is scanned
 * exactly. With no index (or use_index = false) it is an exact scan of the whole table. */
static void fi_search_bind(duckdb_bind_info info)
{
    fsql_instance *inst = fsql_bind_instance(info);
    char err[ERRCAP];
    char *table = NULL, *col = NULL, *opts = NULL;
    fsql_vecd q;
    fsql_vecd_init(&q);
    int64_t k = 0;
    fsql_rowset *rs = NULL;
    FiCand *res = NULL;
    int nres = 0, i;

    err[0] = 0;
    table = fi_bp_str(info, 0);
    col = fi_bp_str(info, 1);
    opts = fi_bp_str(info, 4);
    if (!table || !col || !opts) { snprintf(err, ERRCAP, "fractalsql: out of memory"); goto fail; }
    if (!fi_bp_vec(info, 2, &q)) { snprintf(err, ERRCAP, "fractalsql: fractal_search: the query must not be NULL"); goto fail; }
    if (!fi_bp_int(info, 3, &k)) { snprintf(err, ERRCAP, "fractalsql: fractal_search: k must not be NULL"); goto fail; }
    if (k < 1 || k > 1000) { snprintf(err, ERRCAP, "fractalsql: fractal_search: k out of range [1, 1000]"); goto fail; }
    if (q.len == 0) { snprintf(err, ERRCAP, "fractalsql: fractal_search: the query vector is empty"); goto fail; }
    res = (FiCand *)malloc(sizeof(FiCand) * (size_t)k);
    if (!res) { snprintf(err, ERRCAP, "fractalsql: out of memory"); goto fail; }
    if (fi_search_run(inst, table, col, q.p, q.len, (int)k, opts, res, &nres, err)) goto fail;
    rs = fsql_rowset_new(3, kSearchCols, kSearchTys);
    if (!rs) { snprintf(err, ERRCAP, "fractalsql: out of memory"); goto fail; }
    for (i = 0; i < nres; i++) {
        char buf[32];
        snprintf(buf, sizeof buf, "%" PRId64, res[i].id);
        if (!fsql_rs_row(rs) || !fsql_rs_str(rs, 0, buf, strlen(buf)) ||
            !fsql_rs_f64(rs, 1, res[i].d) || !fsql_rs_i64(rs, 2, res[i].id)) {
            snprintf(err, ERRCAP, "fractalsql: out of memory");
            goto fail;
        }
    }
    fsql_rowset_bind(info, rs);
    rs = NULL;
    goto cleanup;
fail:
    duckdb_bind_set_error(info, err[0] ? err : "fractalsql: fractal_search failed");
cleanup:
    if (rs) fsql_rowset_free(rs);
    free(res);
    fsql_vecd_free(&q);
    free(table); free(col); free(opts);
}

/* fractal_index_list() -> TABLE(name, table_name, vector_col, format, dim, rows, rows_now, stale, status, generation): one row per index.
 * Reads the catalog without creating it: a database that never built an index lists nothing. */
static const char *const kListCols[] = { "name", "table_name", "vector_col", "format", "dim", "rows", "rows_now", "stale", "status", "generation" };
static const fsql_rs_ty  kListTys[]  = { FSQL_RS_VARCHAR, FSQL_RS_VARCHAR, FSQL_RS_VARCHAR, FSQL_RS_VARCHAR, FSQL_RS_BIGINT, FSQL_RS_BIGINT,
                                         FSQL_RS_BIGINT, FSQL_RS_BOOLEAN, FSQL_RS_VARCHAR, FSQL_RS_BIGINT };

static void fi_list_bind(duckdb_bind_info info)
{
    fsql_instance *inst = fsql_bind_instance(info);
    char err[ERRCAP] = "";
    fsql_rowset *rs = fsql_rowset_new(10, kListCols, kListTys);
    char **names = NULL;
    size_t nn = 0, cap = 0, k;
    fsql_qres r;
    duckdb_data_chunk ch;
    if (!rs) { duckdb_bind_set_error(info, "fractalsql: out of memory"); return; }
    /* the names first: each index is then read with its own nested queries */
    if (fsql_nested_query(inst, "SELECT name FROM fractal_index_meta ORDER BY name", &r, err, ERRCAP) == 0) {
        for (;;) {
            idx_t rows, i;
            ch = fsql_qres_next_chunk(&r);
            if (!ch) break;
            rows = duckdb_data_chunk_get_size(ch);
            if (rows == 0) { duckdb_destroy_data_chunk(&ch); break; }
            for (i = 0; i < rows; i++) {
                if (nn == cap) {
                    char **nv = (char **)realloc(names, (cap ? cap * 2 : 16) * sizeof(char *));
                    if (!nv) { duckdb_destroy_data_chunk(&ch); fsql_qres_free(&r); snprintf(err, ERRCAP, "fractalsql: out of memory"); goto fail; }
                    names = nv; cap = cap ? cap * 2 : 16;
                }
                names[nn] = fi_cell_str(ch, 0, i);
                if (names[nn]) nn++;
            }
            duckdb_destroy_data_chunk(&ch);
        }
        fsql_qres_free(&r);
    }                                                    /* no catalog table yet: an empty list, not an error */
    for (k = 0; k < nn; k++) {
        FiMeta mt;
        FiHealth h;
        const char *st;
        err[0] = 0;
        if (fi_read_meta(inst, names[k], &mt, err) != 0) continue;
        fi_health(inst, &mt, &h);
        st = fi_status(&mt, &h);
        if (!fsql_rs_row(rs) || !fsql_rs_str(rs, 0, mt.name, strlen(mt.name)) || !fsql_rs_str(rs, 1, mt.tbl, strlen(mt.tbl)) ||
            !fsql_rs_str(rs, 2, mt.col, strlen(mt.col)) || !fsql_rs_str(rs, 3, mt.fmt, strlen(mt.fmt)) || !fsql_rs_i64(rs, 4, mt.dim) ||
            !fsql_rs_i64(rs, 5, mt.rows) || !fsql_rs_i64(rs, 6, h.now) || !fsql_rs_bool(rs, 7, h.stale != 0) ||
            !fsql_rs_str(rs, 8, st, strlen(st)) || !fsql_rs_i64(rs, 9, mt.generation)) {
            snprintf(err, ERRCAP, "fractalsql: out of memory");
            goto fail;
        }
    }
    for (k = 0; k < nn; k++) free(names[k]);
    free(names);
    fsql_rowset_bind(info, rs);
    return;
fail:
    for (k = 0; k < nn; k++) free(names[k]);
    free(names);
    fsql_rowset_free(rs);
    duckdb_bind_set_error(info, err[0] ? err : "fractalsql: fractal_index_list failed");
}

/* fractal_index_candidates(table, column, query, options) -> TABLE(doc_id)
 * Every row of the `near` nearest cells, plus `per_cell` representatives of every other cell, plus
 * the rows newer than the index (the delta): the candidate set Scout consumes. */
static void fi_candidates_bind(duckdb_bind_info info)
{
    fsql_instance *inst = fsql_bind_instance(info);
    char err[ERRCAP];
    char *table = NULL, *col = NULL, *opts = NULL;
    fsql_vecd q;
    fsql_vecd_init(&q);
    fsql_rowset *rs = NULL;
    char index_name[64] = "";
    double near_d, per_d;
    int n_near, n_per;
    FIdxState *S;
    FIdx *x = NULL;
    uint32_t *cells = NULL;
    char *isnear = NULL;
    int first = 1;

    err[0] = 0;
    table = fi_bp_str(info, 0);
    col = fi_bp_str(info, 1);
    opts = fi_bp_str(info, 3);
    if (!table || !col || !opts) { snprintf(err, ERRCAP, "fractalsql: out of memory"); goto fail; }
    if (!fi_bp_vec(info, 2, &q)) { snprintf(err, ERRCAP, "fractalsql: fractal_index_candidates: the query must not be NULL"); goto fail; }
    near_d = fi_opt_num(opts, "near", 6);
    per_d = fi_opt_num(opts, "per_cell", 1);
    n_near = (int)(near_d < 0 ? 0 : (near_d > 4096 ? 4096 : near_d));
    n_per = (int)(per_d < 0 ? 0 : (per_d > 100000 ? 100000 : per_d));

    S = fi_state(inst);
    if (!fi_opt_str(opts, "index", index_name, sizeof index_name)) {
        if (!fi_find_name(inst, table, col, index_name, sizeof index_name, err)) {
            snprintf(err, ERRCAP, "fractalsql: no index on this table and column");
            goto fail;
        }
    }
    if (S) {
        fsql_mu_lock(&S->mu);
        x = fi_load_locked(S, inst, index_name, err, ERRCAP);
        fsql_mu_unlock(&S->mu);
    }
    if (!x) { if (!err[0]) snprintf(err, ERRCAP, "fractalsql: cannot load the index"); goto fail; }
    if ((int)q.len != x->dim) {
        snprintf(err, ERRCAP, "fractalsql: fractal_index_candidates: the query dimension does not match the index");
        goto fail;
    }
    cells = (uint32_t *)malloc((size_t)(x->nlist > 0 ? x->nlist : 1) * sizeof(uint32_t));
    isnear = (char *)calloc((size_t)(x->nlist > 0 ? x->nlist : 1), 1);
    if (!cells || !isnear) { snprintf(err, ERRCAP, "fractalsql: out of memory"); goto fail; }
    {
        uint32_t nc = 0;
        float *qf = (float *)malloc((size_t)x->dim * sizeof(float));
        size_t j;
        if (!qf) { snprintf(err, ERRCAP, "fractalsql: out of memory"); goto fail; }
        for (j = 0; j < (size_t)x->dim; j++) qf[j] = (float)q.p[j];
        if (fi_ivf_probe_cells(x->m, qf, (uint32_t)(n_near > 0 ? n_near : 1), cells, &nc) == FSQL_OK) {
            for (j = 0; j < nc; j++) if (cells[j] < (uint32_t)x->nlist) isnear[cells[j]] = 1;
        }
        free(qf);
    }
    rs = fsql_rowset_new(1, kSearchCols, kSearchTys);
    if (!rs) { snprintf(err, ERRCAP, "fractalsql: out of memory"); goto fail; }
    /* the ids of every cell, straight from the storage table */
    {
        fsql_sb sb;
        fsql_qres r;
        duckdb_data_chunk ch;
        fsql_sb_init(&sb);
        fsql_sb_puts(&sb, "SELECT cell, ids FROM fractal_index_cells WHERE name = ");
        fi_put_lit(&sb, x->name);
        fsql_sb_printf(&sb, " AND generation = %d ORDER BY cell", x->generation);
        if (fsql_nested_query(inst, fsql_sb_cstr(&sb), &r, err, ERRCAP) == 0) {
            for (;;) {
                idx_t rows, i2;
                ch = fsql_qres_next_chunk(&r);
                if (!ch) break;
                rows = duckdb_data_chunk_get_size(ch);
                if (rows == 0) { duckdb_destroy_data_chunk(&ch); break; }
                for (i2 = 0; i2 < rows; i2++) {
                    int64_t cell = fi_cell_i64(ch, 0, i2);
                    duckdb_vector iv = duckdb_list_vector_get_child(duckdb_data_chunk_get_vector(ch, 1));
                    duckdb_list_entry ie = ((const duckdb_list_entry *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(ch, 1)))[i2];
                    const int64_t *idv = (const int64_t *)duckdb_vector_get_data(iv);
                    int64_t take, t;
                    if (cell < 0 || cell >= x->nlist) continue;
                    take = isnear[cell] ? (int64_t)ie.length : (n_per < (int64_t)ie.length ? n_per : (int64_t)ie.length);
                    for (t = 0; t < take; t++) {
                        char buf[32];
                        snprintf(buf, sizeof buf, "%" PRId64, idv[ie.offset + t]);
                        if (!fsql_rs_row(rs) || !fsql_rs_str(rs, 0, buf, strlen(buf))) {
                            snprintf(err, ERRCAP, "fractalsql: out of memory");
                            duckdb_destroy_data_chunk(&ch);
                            fsql_qres_free(&r);
                            fsql_sb_free(&sb);
                            goto fail;
                        }
                        first = 0;
                    }
                }
                duckdb_destroy_data_chunk(&ch);
            }
            fsql_qres_free(&r);
        }
        fsql_sb_free(&sb);
    }
    /* the delta: the rows newer than the index */
    {
        fsql_sb sb;
        fsql_qres r;
        duckdb_data_chunk ch;
        fsql_sb_init(&sb);
        fsql_sb_puts(&sb, "SELECT ");
        if (fi_quote_column(x->id_col, &sb, err) == 0) {
            fsql_sb_puts(&sb, "::BIGINT FROM ");
            if (fi_quote_table(table, &sb, err) == 0) {
                fsql_sb_puts(&sb, " WHERE ");
                if (fi_quote_column(x->id_col, &sb, err) == 0) {
                    fsql_sb_printf(&sb, " > %" PRId64, x->max_id);
                    if (fsql_nested_query(inst, fsql_sb_cstr(&sb), &r, err, ERRCAP) == 0) {
                        for (;;) {
                            idx_t rows, i2;
                            ch = fsql_qres_next_chunk(&r);
                            if (!ch) break;
                            rows = duckdb_data_chunk_get_size(ch);
                            if (rows == 0) { duckdb_destroy_data_chunk(&ch); break; }
                            for (i2 = 0; i2 < rows; i2++) {
                                char buf[32];
                                snprintf(buf, sizeof buf, "%" PRId64, fi_cell_i64(ch, 0, i2));
                                if (!fsql_rs_row(rs) || !fsql_rs_str(rs, 0, buf, strlen(buf))) {
                                    snprintf(err, ERRCAP, "fractalsql: out of memory");
                                    duckdb_destroy_data_chunk(&ch);
                                    fsql_qres_free(&r);
                                    fsql_sb_free(&sb);
                                    goto fail;
                                }
                            }
                            duckdb_destroy_data_chunk(&ch);
                        }
                        fsql_qres_free(&r);
                    }
                }
            }
        }
        fsql_sb_free(&sb);
    }
    (void)first;
    fsql_rowset_bind(info, rs);
    rs = NULL;
    goto cleanup;
fail:
    duckdb_bind_set_error(info, err[0] ? err : "fractalsql: fractal_index_candidates failed");
cleanup:
    if (rs) fsql_rowset_free(rs);
    free(cells);
    free(isnear);
    fsql_vecd_free(&q);
    free(table); free(col); free(opts);
}

/* ------------------------------------------------------------------ */
/* Registration                                                         */
/* ------------------------------------------------------------------ */

#define V   FSQL_T_VARCHAR
#define I   FSQL_T_INTEGER
#define LD  FSQL_T_LIST_DOUBLE

/* Every "fractal_search" SCALAR overload lives in ONE set: the DuckDB C API merges the overloads of
 * one name, but registering the same name from two places would race with the catalog. The indexed
 * search itself is a TABLE function (DuckDB cannot overload one, so it takes all five arguments),
 * which lives in a different catalog and therefore cannot clash with these. */
static const fsql_scalar_def kIndexDefs[] = {
    /* the old table-free forms: renamed, NOT aliased */
    { "fractal_search", 1, { LD },                    LD, fi_renamed_fn, NULL, 0 },
    { "fractal_search", 2, { LD, LD },                FSQL_T_DOUBLE, fi_renamed_fn, NULL, 0 },
    { "fractal_search", 2, { LD, I },                  LD, fi_renamed_fn, NULL, 0 },
    { "fractal_search", 3, { LD, I, I },              LD, fi_renamed_fn, NULL, 0 },
    { "fractal_search", 4, { LD, I, I, I },           LD, fi_renamed_fn, NULL, 0 },
    /* the management functions */
    { "fractal_index_create", 2, { V, V },             V, fi_create_fn, NULL, FSQL_FN_VOLATILE },
    { "fractal_index_create", 3, { V, V, V },          V, fi_create_fn, NULL, FSQL_FN_VOLATILE },
    { "fractal_index_rebuild", 1, { V },               V, fi_rebuild_fn, NULL, FSQL_FN_VOLATILE },
    { "fractal_index_refresh", 1, { V },               V, fi_refresh_fn, NULL, FSQL_FN_VOLATILE },
    { "fractal_index_ensure", 2, { V, V },             V, fi_ensure_fn, NULL, FSQL_FN_VOLATILE },
    { "fractal_index_ensure", 3, { V, V, V },          V, fi_ensure_fn, NULL, FSQL_FN_VOLATILE },
    { "fractal_index_drop", 1, { V },                 FSQL_T_BIGINT, fi_drop_fn, NULL, FSQL_FN_VOLATILE },
    { "fractal_index_info", 1, { V },                 V, fi_info_fn, NULL, 0 },
};

static const fsql_table_def kIndexTables[] = {
    { "fractal_search", 5, { V, V, LD, I, V }, fi_search_bind, fsql_rowset_init, fsql_rowset_scan },
    { "fractal_index_candidates", 4, { V, V, LD, V }, fi_candidates_bind, fsql_rowset_init, fsql_rowset_scan },
    { "fractal_index_list", 0, { V }, fi_list_bind, fsql_rowset_init, fsql_rowset_scan },
};

#undef V
#undef I
#undef LD

bool fsql_index_register(duckdb_connection con, const char **err)
{
    return fsql_register_scalars(con, kIndexDefs, (int)(sizeof kIndexDefs / sizeof kIndexDefs[0]), err) &&
           fsql_register_tables(con, kIndexTables, (int)(sizeof kIndexTables / sizeof kIndexTables[0]), err);
}
