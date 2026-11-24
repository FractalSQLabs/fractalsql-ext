/* src/fsql_vector.c
 *
 * "Vector Arithmetic" family: plain float32 vector-math primitives (dot product,
 * distances, norm, elementwise ops, quantization). See fractalsql_sql.h's
 * "Vector Arithmetic" section for the authoritative doc comments on every
 * fsql_vector_* symbol wrapped here. DuckDB has native
 * LIST(FLOAT), so there is no decode layer.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * None of these need an fsql_ctx: they are pure O(dim) math over caller-supplied
 * buffers, available in every build tier.
 *
 * SQL surface (fsql_<name> -> fractal_vector_<name>):
 *
 *   fractal_vector_dot(LIST(FLOAT), LIST(FLOAT))              -> FLOAT
 *   fractal_vector_l2_squared(LIST(FLOAT), LIST(FLOAT))            -> FLOAT
 *   fractal_vector_l2_distance(LIST(FLOAT), LIST(FLOAT))               -> FLOAT
 *   fractal_vector_cosine_distance(LIST(FLOAT), LIST(FLOAT))  -> FLOAT
 *   fractal_vector_cosine_similarity(LIST(FLOAT), LIST(FLOAT))-> FLOAT
 *   fractal_vector_norm(LIST(FLOAT))                          -> FLOAT
 *   fractal_vector_normalize(LIST(FLOAT))                     -> LIST(FLOAT)
 *   fractal_vector_dims(LIST(FLOAT))                          -> INTEGER
 *   fractal_vector_from_float8_array(LIST(DOUBLE))            -> LIST(FLOAT)
 *   fractal_vector_to_float8_array(LIST(FLOAT))               -> LIST(DOUBLE)
 *   fractal_vector_add / _sub(LIST(FLOAT), LIST(FLOAT))       -> LIST(FLOAT)
 *   fractal_vector_scale(LIST(FLOAT), FLOAT)                  -> LIST(FLOAT)
 *   fractal_vector_weighted_concat(a, alpha, b, beta)         -> LIST(FLOAT)
 *   fractal_vector_lp_distance(LIST(FLOAT), LIST(FLOAT), FLOAT p) -> FLOAT
 *   fractal_vector_quantize_int8(LIST(FLOAT))   -> JSON TEXT {"scale":S,"codes":[...]}
 *   fractal_vector_quantize_binary(LIST(FLOAT)) -> BLOB
 *   fractal_vector_hamming_distance(BLOB, BLOB) -> BIGINT
 *
 * NULL handling: a NULL argument (or a NULL element inside a list) gives a NULL
 * result for that row, as in the C++ build.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_duckdb_internal.h"
#include "fsql_precision.h"

/* Supply-side DoS guard: these primitives allocate an output buffer sized to the
 * input dim (twice that for weighted_concat). */
#define FSQL_VEC_MAX_DIM ((size_t)1 * 1024 * 1024)

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

/* 0 = ok; -1 = the call was failed (message set). */
static int check_dim(duckdb_function_info info, size_t dim, const char *fn_name) {
    if (dim == 0 || dim > FSQL_VEC_MAX_DIM) {
        fsql_fn_error(info, "fractalsql: %s vector dim %zu out of range [1, %zu]",
                      fn_name, dim, FSQL_VEC_MAX_DIM);
        return -1;
    }
    return 0;
}

/* The fsql_vector_* C ABI takes one `dim` and trusts the caller that both buffers
 * are that long; this is the one check that has to happen here, before the call,
 * or a mismatched pair reads past the shorter buffer. */
static int check_equal_dim(duckdb_function_info info, size_t a, size_t b, const char *fn_name) {
    if (a != b) {
        fsql_fn_error(info, "fractalsql: %s dimension mismatch (%zu vs %zu)", fn_name, a, b);
        return -1;
    }
    return 0;
}

static int rc_check(duckdb_function_info info, int rc, const char *what) {
    if (rc != FSQL_OK) {
        fsql_fn_error(info, "fractalsql: %s failed (rc=%d)", what, rc);
        return -1;
    }
    return 0;
}

/* A float scratch buffer reused across the rows of one chunk. */
typedef struct { float *p; size_t cap; } fbuf;
static float *fbuf_get(fbuf *b, size_t n) {
    if (n > b->cap) {
        float *np = (float *)realloc(b->p, n * sizeof(float));
        if (!np) return NULL;
        b->p = np;
        b->cap = n;
    }
    return b->p;
}


/* ------------------------------------------------------------------ */
/* (LIST(FLOAT), LIST(FLOAT)) -> FLOAT : dot, l2_sq, l2, cosine x2     */
/* ------------------------------------------------------------------ */

/* Every distance here is computed in DOUBLE by the ONE shared implementation
 * (fsql_precision.h) and rounded once to float32, because the SQL-visible result
 * of these functions is a FLOAT (precision plan R2/R5: double accumulation, one
 * rounding, no contraction, no vectorisation). */
typedef int (*two_vec_fn)(const float *, const float *, size_t, float *);

static int vec_dot_local(const float *a, const float *b, size_t n, float *out) {
    *out = (float)fsqlp_dot_f(a, b, n);
    return FSQL_OK;
}
static int vec_l2_sq_local(const float *a, const float *b, size_t n, float *out) {
    *out = (float)fsqlp_l2_sq_f(a, b, n);
    return FSQL_OK;
}
static int vec_l2_local(const float *a, const float *b, size_t n, float *out) {
    *out = (float)fsqlp_l2_f(a, b, n);
    return FSQL_OK;
}
static int vec_cos_dist_local(const float *a, const float *b, size_t n, float *out) {
    *out = (float)fsqlp_cosine_distance_f(a, b, n);
    return FSQL_OK;
}
static int vec_cos_sim_local(const float *a, const float *b, size_t n, float *out) {
    *out = (float)fsqlp_cosine_similarity_f(a, b, n);
    return FSQL_OK;
}
static int vec_add_local(const float *a, const float *b, size_t n, float *out) {
    fsqlp_add_f(a, b, n, out);
    return FSQL_OK;
}
static int vec_sub_local(const float *a, const float *b, size_t n, float *out) {
    fsqlp_sub_f(a, b, n, out);
    return FSQL_OK;
}

static void two_vec_to_scalar(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out, two_vec_fn fn) {
    idx_t n = duckdb_data_chunk_get_size(in);
    float *res = (float *)duckdb_vector_get_data(out);
    fsql_list la, lb;
    fsql_list_open(&la, duckdb_data_chunk_get_vector(in, 0));
    fsql_list_open(&lb, duckdb_data_chunk_get_vector(in, 1));
    for (idx_t i = 0; i < n; i++) {
        const float *a, *b; size_t an, bn; const char *err = NULL;
        int ga = fsql_list_f32_get(&la, i, &a, &an, &err);
        if (ga < 0) { fsql_fn_error(info, "%s", err); return; }
        int gb = ga ? fsql_list_f32_get(&lb, i, &b, &bn, &err) : 0;
        if (gb < 0) { fsql_fn_error(info, "%s", err); return; }
        if (!ga || !gb) { fsql_set_null(out, i); continue; }
        if (check_dim(info, an, "fractal_vector") || check_equal_dim(info, an, bn, "fractal_vector")) return;
        float v = 0.0f;
        if (rc_check(info, fn(a, b, an, &v), "vector op")) return;
        res[i] = v;
    }
}

#define TWO_VEC_SCALAR(NAME, FN) \
    static void NAME(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) { \
        two_vec_to_scalar(info, in, out, FN); }

TWO_VEC_SCALAR(vec_dot_fn,               vec_dot_local)
TWO_VEC_SCALAR(vec_l2_sq_fn,             vec_l2_sq_local)
TWO_VEC_SCALAR(vec_l2_fn,                vec_l2_local)
TWO_VEC_SCALAR(vec_cosine_distance_fn,   vec_cos_dist_local)
TWO_VEC_SCALAR(vec_cosine_similarity_fn, vec_cos_sim_local)

/* (LIST(FLOAT), LIST(FLOAT)) -> LIST(FLOAT) : add, sub */
static void two_vec_to_vec(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out, two_vec_fn fn) {
    idx_t n = duckdb_data_chunk_get_size(in);
    fsql_list la, lb;
    fsql_list_out w;
    fbuf ob = { NULL, 0 };
    fsql_list_open(&la, duckdb_data_chunk_get_vector(in, 0));
    fsql_list_open(&lb, duckdb_data_chunk_get_vector(in, 1));
    fsql_list_out_open(&w, out);
    for (idx_t i = 0; i < n; i++) {
        const float *a, *b; size_t an, bn; const char *err = NULL;
        int ga = fsql_list_f32_get(&la, i, &a, &an, &err);
        if (ga < 0) { fsql_fn_error(info, "%s", err); goto done; }
        int gb = ga ? fsql_list_f32_get(&lb, i, &b, &bn, &err) : 0;
        if (gb < 0) { fsql_fn_error(info, "%s", err); goto done; }
        if (!ga || !gb) { fsql_list_out_put_null(&w, i); continue; }
        if (check_dim(info, an, "fractal_vector") || check_equal_dim(info, an, bn, "fractal_vector")) goto done;
        float *o = fbuf_get(&ob, an);
        if (!o) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
        if (rc_check(info, fn(a, b, an, o), "vector op")) goto done;
        if (!fsql_list_out_put_f32(&w, i, o, an)) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
    }
done:
    fsql_list_out_close(&w);
    free(ob.p);
}

#define TWO_VEC_VEC(NAME, FN) \
    static void NAME(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) { \
        two_vec_to_vec(info, in, out, FN); }

TWO_VEC_VEC(vec_add_fn, vec_add_local)
TWO_VEC_VEC(vec_sub_fn, vec_sub_local)

/* ------------------------------------------------------------------ */
/* norm, normalize                                                      */
/* ------------------------------------------------------------------ */

static void vec_norm_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    float *res = (float *)duckdb_vector_get_data(out);
    fsql_list la;
    fsql_list_open(&la, duckdb_data_chunk_get_vector(in, 0));
    for (idx_t i = 0; i < n; i++) {
        const float *a; size_t an; const char *err = NULL;
        int g = fsql_list_f32_get(&la, i, &a, &an, &err);
        if (g < 0) { fsql_fn_error(info, "%s", err); return; }
        if (!g) { fsql_set_null(out, i); continue; }
        if (check_dim(info, an, "fractal_vector_norm")) return;
        float v = 0.0f;
        v = (float)fsqlp_norm_f(a, an);
        res[i] = v;
    }
}

static void vec_normalize_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    fsql_list la;
    fsql_list_out w;
    fbuf ob = { NULL, 0 };
    fsql_list_open(&la, duckdb_data_chunk_get_vector(in, 0));
    fsql_list_out_open(&w, out);
    for (idx_t i = 0; i < n; i++) {
        const float *a; size_t an; const char *err = NULL;
        int g = fsql_list_f32_get(&la, i, &a, &an, &err);
        if (g < 0) { fsql_fn_error(info, "%s", err); goto done; }
        if (!g) { fsql_list_out_put_null(&w, i); continue; }
        if (check_dim(info, an, "fractal_vector_normalize")) goto done;
        float *o = fbuf_get(&ob, an);
        if (!o) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
        fsqlp_normalize_f(a, an, o);
        if (!fsql_list_out_put_f32(&w, i, o, an)) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
    }
done:
    fsql_list_out_close(&w);
    free(ob.p);
}

/* ------------------------------------------------------------------ */
/* dims, from/to_float8_array : no core call, plain length / cast       */
/* ------------------------------------------------------------------ */

static void vec_dims_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    (void)info;
    idx_t n = duckdb_data_chunk_get_size(in);
    int32_t *res = (int32_t *)duckdb_vector_get_data(out);
    fsql_list la;
    fsql_list_open(&la, duckdb_data_chunk_get_vector(in, 0));
    for (idx_t i = 0; i < n; i++) {
        size_t len;
        if (!fsql_list_length(&la, i, &len)) { fsql_set_null(out, i); continue; }
        res[i] = (int32_t)len;
    }
}

/* elementwise convert between LIST(DOUBLE) and LIST(FLOAT) */
static void vec_convert(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out, int to_float) {
    idx_t n = duckdb_data_chunk_get_size(in);
    fsql_list la;
    fsql_list_out w;
    fsql_vecd tmp; fsql_vecd_init(&tmp);
    fbuf ob = { NULL, 0 };
    fsql_list_open(&la, duckdb_data_chunk_get_vector(in, 0));
    fsql_list_out_open(&w, out);
    for (idx_t i = 0; i < n; i++) {
        idx_t off; size_t len; const char *err = NULL;
        /* a NULL list is NULL; elements are read through the validity-checked range */
        int g = fsql_list_range(&la, i, &off, &len, &err);
        if (g < 0) { fsql_fn_error(info, "%s", err); goto done; }
        if (!g) { fsql_list_out_put_null(&w, i); continue; }
        if (to_float) {
            float *o = fbuf_get(&ob, len);
            if (!o && len) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
            const double *src = (const double *)la.child + off;
            for (size_t k = 0; k < len; k++) o[k] = (float)src[k];
            if (!fsql_list_out_put_f32(&w, i, o, len)) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
        } else {
            tmp.len = 0;
            const float *src = (const float *)la.child + off;
            for (size_t k = 0; k < len; k++) fsql_vecd_push(&tmp, (double)src[k]);
            if (!fsql_vecd_ok(&tmp) || !fsql_list_out_put(&w, i, tmp.p, len)) {
                fsql_fn_error(info, "fractalsql: out of memory"); goto done;
            }
        }
    }
done:
    fsql_list_out_close(&w);
    fsql_vecd_free(&tmp);
    free(ob.p);
}

static void vec_from_float8_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) { vec_convert(info, in, out, 1); }
static void vec_to_float8_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out)   { vec_convert(info, in, out, 0); }

/* ------------------------------------------------------------------ */
/* scale : (LIST(FLOAT), FLOAT) -> LIST(FLOAT)                          */
/* ------------------------------------------------------------------ */

static void vec_scale_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    fsql_list la;
    fsql_list_out w;
    fbuf ob = { NULL, 0 };
    const float *sc = (const float *)fsql_col_data(in, 1);
    const uint64_t *sc_valid = fsql_col_validity(in, 1);
    fsql_list_open(&la, duckdb_data_chunk_get_vector(in, 0));
    fsql_list_out_open(&w, out);
    for (idx_t i = 0; i < n; i++) {
        const float *a; size_t an; const char *err = NULL;
        int g = fsql_list_f32_get(&la, i, &a, &an, &err);
        if (g < 0) { fsql_fn_error(info, "%s", err); goto done; }
        if (!g || !fsql_valid(sc_valid, i)) { fsql_list_out_put_null(&w, i); continue; }
        if (check_dim(info, an, "fractal_vector_scale")) goto done;
        float *o = fbuf_get(&ob, an);
        if (!o) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
        fsqlp_scale_f(a, an, (double)sc[i], o);
        if (!fsql_list_out_put_f32(&w, i, o, an)) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
    }
done:
    fsql_list_out_close(&w);
    free(ob.p);
}

/* ------------------------------------------------------------------ */
/* weighted_concat : (a, alpha, b, beta) -> LIST(FLOAT) of dim_a+dim_b  */
/* The primitive behind cross-modal similarity (alpha*a concat beta*b). */
/* ------------------------------------------------------------------ */

static void vec_weighted_concat_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    fsql_list la, lb;
    fsql_list_out w;
    fbuf ob = { NULL, 0 };
    const float *alpha = (const float *)fsql_col_data(in, 1), *beta = (const float *)fsql_col_data(in, 3);
    const uint64_t *av = fsql_col_validity(in, 1), *bv = fsql_col_validity(in, 3);
    fsql_list_open(&la, duckdb_data_chunk_get_vector(in, 0));
    fsql_list_open(&lb, duckdb_data_chunk_get_vector(in, 2));
    fsql_list_out_open(&w, out);
    for (idx_t i = 0; i < n; i++) {
        const float *a, *b; size_t an, bn; const char *err = NULL;
        int ga = fsql_list_f32_get(&la, i, &a, &an, &err);
        if (ga < 0) { fsql_fn_error(info, "%s", err); goto done; }
        int gb = ga ? fsql_list_f32_get(&lb, i, &b, &bn, &err) : 0;
        if (gb < 0) { fsql_fn_error(info, "%s", err); goto done; }
        if (!ga || !gb || !fsql_valid(av, i) || !fsql_valid(bv, i)) { fsql_list_out_put_null(&w, i); continue; }
        if (check_dim(info, an, "fractal_vector_weighted_concat") ||
            check_dim(info, bn, "fractal_vector_weighted_concat")) goto done;
        /* `out` must not alias a or b: it never does, it is a fresh buffer */
        float *o = fbuf_get(&ob, an + bn);
        if (!o) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
        {   /* accumulated in double, rounded once to float32 (R2) */
            double al = (double)alpha[i], be = (double)beta[i];
            for (size_t j = 0; j < an; j++) o[j] = (float)(al * (double)a[j]);
            for (size_t j = 0; j < bn; j++) o[an + j] = (float)(be * (double)b[j]);
        }
        if (!fsql_list_out_put_f32(&w, i, o, an + bn)) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
    }
done:
    fsql_list_out_close(&w);
    free(ob.p);
}

/* ------------------------------------------------------------------ */
/* lp_distance : (LIST(FLOAT), LIST(FLOAT), FLOAT p) -> FLOAT, p > 0    */
/* ------------------------------------------------------------------ */

static void vec_lp_distance_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    float *res = (float *)duckdb_vector_get_data(out);
    fsql_list la, lb;
    const float *pp = (const float *)fsql_col_data(in, 2);
    const uint64_t *pv = fsql_col_validity(in, 2);
    fsql_list_open(&la, duckdb_data_chunk_get_vector(in, 0));
    fsql_list_open(&lb, duckdb_data_chunk_get_vector(in, 1));
    for (idx_t i = 0; i < n; i++) {
        const float *a, *b; size_t an, bn; const char *err = NULL;
        int ga = fsql_list_f32_get(&la, i, &a, &an, &err);
        if (ga < 0) { fsql_fn_error(info, "%s", err); return; }
        int gb = ga ? fsql_list_f32_get(&lb, i, &b, &bn, &err) : 0;
        if (gb < 0) { fsql_fn_error(info, "%s", err); return; }
        if (!ga || !gb || !fsql_valid(pv, i)) { fsql_set_null(out, i); continue; }
        if (check_dim(info, an, "fractal_vector_lp_distance") ||
            check_equal_dim(info, an, bn, "fractal_vector_lp_distance")) return;
        float p = pp[i];
        /* A single negative-free test, so NaN is rejected by the same branch (NaN
         * fails "p > 0" but would slip past "p <= 0"). p = 2 matches the L2 math,
         * not bit-for-bit; 0 < p < 1 is a real Lp value but not a metric. */
        if (!(p > 0.0f)) { fsql_fn_error(info, "fractalsql: fractal_vector_lp_distance: p must be > 0"); return; }
        float d = 0.0f;
        d = (float)fsqlp_lp_distance_f(a, b, an, (double)p);
        res[i] = d;
    }
}

/* ------------------------------------------------------------------ */
/* quantize_int8 : (LIST(FLOAT)) -> JSON TEXT {"scale":S,"codes":[...]} */
/* Symmetric per-vector scale: v[i] ~= codes[i] * scale. The wire format is JSON */
/* on purpose: it is the document form every edition returns.            */
/* ------------------------------------------------------------------ */

static void vec_quantize_int8_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    fsql_list la;
    int8_t *codes = NULL; size_t codes_cap = 0;
    fsql_list_open(&la, duckdb_data_chunk_get_vector(in, 0));
    for (idx_t i = 0; i < n; i++) {
        const float *a; size_t an; const char *err = NULL;
        int g = fsql_list_f32_get(&la, i, &a, &an, &err);
        if (g < 0) { fsql_fn_error(info, "%s", err); goto done; }
        if (!g) { fsql_set_null(out, i); continue; }
        if (check_dim(info, an, "fractal_vector_quantize_int8")) goto done;
        if (an > codes_cap) {
            int8_t *nc = (int8_t *)realloc(codes, an);
            if (!nc) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
            codes = nc; codes_cap = an;
        }
        float scale = 0.0f;
        if (rc_check(info, fsql_vector_quantize_int8(a, an, codes, &scale), "fractal_vector_quantize_int8")) goto done;
        /* bounds-checked assembly: every append checks its own space */
        fsql_sb sb; fsql_sb_init(&sb);
        fsql_sb_printf(&sb, "{\"scale\":%.9g,\"codes\":[", (double)scale);
        for (size_t j = 0; j < an; j++) fsql_sb_printf(&sb, "%s%d", j ? "," : "", (int)codes[j]);
        fsql_sb_puts(&sb, "]}");
        if (!fsql_sb_ok(&sb)) { fsql_sb_free(&sb); fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
        fsql_set_str(out, i, sb.p, sb.len);
        fsql_sb_free(&sb);
    }
done:
    free(codes);
}

/* ------------------------------------------------------------------ */
/* quantize_binary : (LIST(FLOAT)) -> BLOB of (dim+7)/8 bytes, sign MSB-first */
/* ------------------------------------------------------------------ */

static void vec_quantize_binary_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    fsql_list la;
    uint8_t *packed = NULL; size_t packed_cap = 0;
    fsql_list_open(&la, duckdb_data_chunk_get_vector(in, 0));
    for (idx_t i = 0; i < n; i++) {
        const float *a; size_t an; const char *err = NULL;
        int g = fsql_list_f32_get(&la, i, &a, &an, &err);
        if (g < 0) { fsql_fn_error(info, "%s", err); goto done; }
        if (!g) { fsql_set_null(out, i); continue; }
        if (check_dim(info, an, "fractal_vector_quantize_binary")) goto done;
        size_t nb = (an + 7) / 8;
        if (nb > packed_cap) {
            uint8_t *np = (uint8_t *)realloc(packed, nb);
            if (!np) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
            packed = np; packed_cap = nb;
        }
        if (rc_check(info, fsql_vector_quantize_binary(a, an, packed), "fractal_vector_quantize_binary")) goto done;
        fsql_set_str(out, i, (const char *)packed, nb);
    }
done:
    free(packed);
}

/* ------------------------------------------------------------------ */
/* hamming_distance : (BLOB, BLOB) -> BIGINT, equal-length non-empty    */
/* ------------------------------------------------------------------ */

static void vec_hamming_distance_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    int64_t *res = (int64_t *)duckdb_vector_get_data(out);
    const duckdb_string_t *sa = (const duckdb_string_t *)fsql_col_data(in, 0);
    const duckdb_string_t *sb = (const duckdb_string_t *)fsql_col_data(in, 1);
    const uint64_t *va = fsql_col_validity(in, 0), *vb = fsql_col_validity(in, 1);
    for (idx_t i = 0; i < n; i++) {
        if (!fsql_valid(va, i) || !fsql_valid(vb, i)) { fsql_set_null(out, i); continue; }
        size_t an, bn;
        const char *a = fsql_str_data(&sa[i], &an), *b = fsql_str_data(&sb[i], &bn);
        /* Empty inputs are rejected like the non-packed ones: a zero-length pair would
         * otherwise flow into the ABI as a vacuous 0-byte comparison. */
        if (an == 0 || bn == 0) {
            fsql_fn_error(info, "fractalsql: fractal_vector_hamming_distance expects two "
                                "packed-bit BLOBs (see fractal_vector_quantize_binary)");
            return;
        }
        if (an != bn) {
            fsql_fn_error(info, "fractalsql: fractal_vector_hamming_distance: BLOBs must "
                                "be non-empty and the same length (%zu vs %zu bytes)", an, bn);
            return;
        }
        if (an > FSQL_VEC_MAX_DIM) {
            fsql_fn_error(info, "fractalsql: fractal_vector_hamming_distance: blob exceeds %zu bytes", FSQL_VEC_MAX_DIM);
            return;
        }
        size_t dist = 0;
        if (rc_check(info, fsql_vector_hamming_distance((const uint8_t *)a, (const uint8_t *)b, an, &dist),
                     "fractal_vector_hamming_distance")) return;
        res[i] = (int64_t)dist;
    }
}

/* ------------------------------------------------------------------ */
/* Registration                                                         */
/* ------------------------------------------------------------------ */

#define V  FSQL_T_LIST_FLOAT
#define F  FSQL_T_FLOAT
static const fsql_scalar_def kVectorDefs[] = {
    { "fractal_vector_dot",               2, { V, V },       F,                 vec_dot_fn,               NULL, 0 },
    { "fractal_vector_l2_squared",             2, { V, V },       F,                 vec_l2_sq_fn,             NULL, 0 },
    { "fractal_vector_l2_distance",                2, { V, V },       F,                 vec_l2_fn,                NULL, 0 },
    { "fractal_vector_cosine_distance",   2, { V, V },       F,                 vec_cosine_distance_fn,   NULL, 0 },
    { "fractal_vector_cosine_similarity", 2, { V, V },       F,                 vec_cosine_similarity_fn, NULL, 0 },
    { "fractal_vector_norm",              1, { V },          F,                 vec_norm_fn,              NULL, 0 },
    { "fractal_vector_normalize",         1, { V },          V,                 vec_normalize_fn,         NULL, 0 },
    { "fractal_vector_dims",              1, { V },          FSQL_T_INTEGER,    vec_dims_fn,              NULL, 0 },
    { "fractal_vector_from_float8_array", 1, { FSQL_T_LIST_DOUBLE }, V,         vec_from_float8_fn,       NULL, 0 },
    { "fractal_vector_to_float8_array",   1, { V },          FSQL_T_LIST_DOUBLE, vec_to_float8_fn,        NULL, 0 },
    { "fractal_vector_add",               2, { V, V },       V,                 vec_add_fn,               NULL, 0 },
    { "fractal_vector_sub",               2, { V, V },       V,                 vec_sub_fn,               NULL, 0 },
    { "fractal_vector_scale",             2, { V, F },       V,                 vec_scale_fn,             NULL, 0 },
    { "fractal_vector_weighted_concat",   4, { V, F, V, F }, V,                 vec_weighted_concat_fn,   NULL, 0 },
    { "fractal_vector_lp_distance",       3, { V, V, F },    F,                 vec_lp_distance_fn,       NULL, 0 },
    { "fractal_vector_quantize_int8",     1, { V },          FSQL_T_VARCHAR,    vec_quantize_int8_fn,     NULL, 0 },
    { "fractal_vector_quantize_binary",   1, { V },          FSQL_T_BLOB,       vec_quantize_binary_fn,   NULL, 0 },
    { "fractal_vector_hamming_distance",  2, { FSQL_T_BLOB, FSQL_T_BLOB }, FSQL_T_BIGINT, vec_hamming_distance_fn, NULL, 0 },
};
#undef V
#undef F

bool fsql_vector_register(duckdb_connection con, const char **err) {
    return fsql_register_scalars(con, kVectorDefs, (int)(sizeof kVectorDefs / sizeof kVectorDefs[0]), err);
}
