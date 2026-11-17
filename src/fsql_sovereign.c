/* src/fsql_sovereign.c
 *
 * Dimension / topology / fingerprint analytics, portfolio optimisation, morphology
 * and the diversify layer: the functions that characterise DATA (a time series, a
 * spatial point cloud, a stream of state fingerprints) or optimise over it, rather
 * than search a corpus.
 * See fractalsql_sql.h's "Fractal Dimension Analysis" / "Topological Data
 * Analysis" / "State Fingerprinting" / "Cycle Detection" sections for the C ABI
 * doc comments this file wraps.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * ---- analytics (this part) ----
 *   fractal_dimension_dfa(series DOUBLE[]) -> DOUBLE
 *   fractal_dimension_boxcount(points DOUBLE[], dim INTEGER) -> DOUBLE
 *   fractal_dimension_drift(series DOUBLE[], win INTEGER)
 *       -> STRUCT(drift DOUBLE, recent_alpha DOUBLE, baseline_alpha DOUBLE)
 *   fractal_change_point_detect(series DOUBLE[], win INTEGER,
 *                               threshold DOUBLE := 2.0, max_points INTEGER := 64) -> BIGINT[]
 *   fractal_periodogram(series DOUBLE[], max_peaks INTEGER := 8)
 *       -> TABLE(freq DOUBLE, power DOUBLE)
 *   fractal_spectrogram_entropy(series DOUBLE[], window INTEGER := 64, hop INTEGER := 32,
 *                               max_frames INTEGER := 4096) -> DOUBLE[]
 *   fractal_tda_persistence_diagram(points DOUBLE[], dim INTEGER, max_dim INTEGER,
 *                                   max_thresh DOUBLE, max_h0_bars INTEGER := 64)
 *       -> STRUCT(h0_bars STRUCT(birth DOUBLE, death DOUBLE)[], betti1 BIGINT)
 *   fractal_state_fingerprint(v DOUBLE[], n_bits INTEGER := 128, seed DOUBLE := 0.0) -> BLOB
 *   fractal_cycle_detect(fingerprints BLOB[], hamming_threshold INTEGER := 0)
 *       -> TABLE(at_index INTEGER, cycle_len BIGINT)
 *
 * None of these take an fsql_ctx: every fsql_dimension_* / fsql_change_point_detect /
 * fsql_periodogram / fsql_tda_persistence_diagram / fsql_state_fingerprint /
 * fsql_cycle_detect_* symbol works on raw buffers the caller owns.
 *
 * Composite results (drift, tda) are fixed-shape data, so they return DuckDB's
 * native STRUCT/LIST -- callers use `result.drift` and `UNNEST(result.h0_bars)`.
 *
 * NULL handling: a NULL argument (including a NULL passed for a defaulted trailing
 * parameter) or a NULL element in a list gives a NULL result for that row, never an
 * error.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_duckdb_internal.h"

/* ------------------------------------------------------------------ */
/* Supply-side DoS guards, sized well above any realistic workload.     */
/* The C ABI accepts whatever array/int the caller hands it, so the     */
/* DuckDB side enforces its own bounds.                                 */
/* ------------------------------------------------------------------ */

#define MAX_SERIES_LEN        ((size_t)1000000)    /* dfa / drift / change_point / spectrogram */
/* periodogram is a direct O(n^2) DFT BY DESIGN, so its cap stays small. */
#define MAX_PERIODOGRAM_LEN   ((size_t)16384)
#define MAX_PEAKS             4096
#define MAX_CHANGE_POINTS     65536
#define MAX_POINTS_FLAT_LEN   ((size_t)2000000)
#define MAX_SPATIAL_DIM       64
#define MAX_TDA_H0_BARS       FSQL_TDA_MAX_POINTS
#define MAX_FINGERPRINT_DIM   ((size_t)1000000)
#define MAX_FINGERPRINT_BITS  65536

/* Most random draws one fingerprint (n_bits x vector length) may cost: about
 * 4 ns each, so 2^28 is roughly a second, and the loop cannot be interrupted.
 * The same bound as the core's and the other engines'. */
#define FSQL_FINGERPRINT_MAX_WORK 268435456

/* Most work one k-subset optimisation may cost (items x k, about 3 us a unit,
 * so 2^24 is roughly a minute). The same bound as the core's. */
#define FSQL_SUBSET_MAX_WORK 16777216
#define MAX_CYCLE_DETECT_LEN  ((size_t)1000000)
#define MAX_SPECTROGRAM_FRAMES 4096

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

/* The row's list of doubles, or a classification:
 *   1 ok / 0 NULL row (or NULL element) / -1 failed (message already set). */
static int series_row(duckdb_function_info info, const fsql_list *l, idx_t row, const double **p, size_t *n) {
    const char *err = NULL;
    int g = fsql_list_f64_get(l, row, p, n, &err);
    if (g < 0) fsql_fn_error(info, "%s", err);
    return g;
}

static int series_cap(duckdb_function_info info, size_t n) {
    if (n > MAX_SERIES_LEN) {
        fsql_fn_error(info, "fractalsql: series length %zu exceeds cap %zu", n, MAX_SERIES_LEN);
        return -1;
    }
    return 0;
}

static int rc_fail(duckdb_function_info info, const char *fn, int rc, const char *hint) {
    fsql_fn_error(info, "fractalsql: %s rc=%d%s%s", fn, rc, hint ? " " : "", hint ? hint : "");
    return -1;
}

/* ------------------------------------------------------------------ */
/* fractal_dimension_dfa(series DOUBLE[]) -> DOUBLE                      */
/* ------------------------------------------------------------------ */

static void dimension_dfa_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    double *res = (double *)duckdb_vector_get_data(out);
    fsql_list sl;
    fsql_list_open(&sl, duckdb_data_chunk_get_vector(in, 0));
    for (idx_t i = 0; i < n; i++) {
        const double *s; size_t sn;
        int g = series_row(info, &sl, i, &s, &sn);
        if (g < 0) return;
        if (g == 0) { fsql_set_null(out, i); continue; }
        if (series_cap(info, sn)) return;
        double alpha;
        int rc = fsql_dimension_dfa(s, sn, &alpha);
        if (rc != FSQL_OK) { rc_fail(info, "fractal_dimension_dfa", rc, "(series needs >= 16 points)"); return; }
        res[i] = alpha;
    }
}

/* ------------------------------------------------------------------ */
/* fractal_dimension_drift(series DOUBLE[], win INTEGER) -> STRUCT        */
/* ------------------------------------------------------------------ */

static void dimension_drift_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    double *d0 = (double *)duckdb_vector_get_data(duckdb_struct_vector_get_child(out, 0));
    double *d1 = (double *)duckdb_vector_get_data(duckdb_struct_vector_get_child(out, 1));
    double *d2 = (double *)duckdb_vector_get_data(duckdb_struct_vector_get_child(out, 2));
    const int32_t *win = (const int32_t *)fsql_col_data(in, 1);
    const uint64_t *wv = fsql_col_validity(in, 1);
    fsql_list sl;
    fsql_list_open(&sl, duckdb_data_chunk_get_vector(in, 0));
    for (idx_t i = 0; i < n; i++) {
        const double *s; size_t sn;
        int g = series_row(info, &sl, i, &s, &sn);
        if (g < 0) return;
        if (g == 0 || !fsql_valid(wv, i)) { fsql_set_null(out, i); continue; }
        if (win[i] <= 0) { fsql_fn_error(info, "fractalsql: win must be > 0"); return; }
        if (series_cap(info, sn)) return;
        double drift, recent, baseline;
        int rc = fsql_dimension_drift(s, sn, (size_t)win[i], &drift, &recent, &baseline);
        if (rc != FSQL_OK) { rc_fail(info, "fractal_dimension_drift", rc, "(need n >= window + 16, window >= 16)"); return; }
        d0[i] = drift; d1[i] = recent; d2[i] = baseline;
    }
}

/* ------------------------------------------------------------------ */
/* fractal_dimension_boxcount(points DOUBLE[], dim INTEGER) -> DOUBLE    */
/* ------------------------------------------------------------------ */

static void dimension_boxcount_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    double *res = (double *)duckdb_vector_get_data(out);
    const int32_t *dimv = (const int32_t *)fsql_col_data(in, 1);
    const uint64_t *dv = fsql_col_validity(in, 1);
    fsql_list pl;
    fsql_list_open(&pl, duckdb_data_chunk_get_vector(in, 0));
    for (idx_t i = 0; i < n; i++) {
        const double *p; size_t pn;
        int g = series_row(info, &pl, i, &p, &pn);
        if (g < 0) return;
        if (g == 0 || !fsql_valid(dv, i)) { fsql_set_null(out, i); continue; }
        int64_t dim = dimv[i];
        if (dim <= 0 || dim > MAX_SPATIAL_DIM) { fsql_fn_error(info, "fractalsql: dim %d out of range [1, %d]", dim, MAX_SPATIAL_DIM); return; }
        if (pn > MAX_POINTS_FLAT_LEN) { fsql_fn_error(info, "fractalsql: points length %zu exceeds cap %zu", pn, MAX_POINTS_FLAT_LEN); return; }
        if (pn % (size_t)dim != 0) { fsql_fn_error(info, "fractalsql: points length (%zu) must be a multiple of dim (%lld)", pn, (long long)dim); return; }
        double dimension;
        int rc = fsql_dimension_boxcount(p, pn / (size_t)dim, (size_t)dim, &dimension);
        if (rc != FSQL_OK) { rc_fail(info, "fractal_dimension_boxcount", rc, "(need >= 8 points, non-degenerate bounding box)"); return; }
        res[i] = dimension;
    }
}

/* ------------------------------------------------------------------ */
/* fractal_change_point_detect(series, win [, threshold [, max_points]]) */
/* A scalar returning BIGINT[]: the change points are a bounded list per */
/* input row.                                                            */
/* ------------------------------------------------------------------ */

static void change_point_detect_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    idx_t ncols = duckdb_data_chunk_get_column_count(in);
    const int32_t *win = (const int32_t *)fsql_col_data(in, 1);
    const uint64_t *wv = fsql_col_validity(in, 1);
    const double *thr = ncols >= 3 ? (const double *)fsql_col_data(in, 2) : NULL;
    const uint64_t *tv = ncols >= 3 ? fsql_col_validity(in, 2) : NULL;
    const int32_t *mp = ncols >= 4 ? (const int32_t *)fsql_col_data(in, 3) : NULL;
    const uint64_t *mv = ncols >= 4 ? fsql_col_validity(in, 3) : NULL;
    fsql_list sl;
    fsql_list_out w;
    size_t *idxs = NULL; size_t idxs_cap = 0;
    fsql_list_open(&sl, duckdb_data_chunk_get_vector(in, 0));
    fsql_list_out_open(&w, out);
    for (idx_t i = 0; i < n; i++) {
        const double *s; size_t sn;
        int g = series_row(info, &sl, i, &s, &sn);
        if (g < 0) goto done;
        if (g == 0 || !fsql_valid(wv, i) || (thr && !fsql_valid(tv, i)) || (mp && !fsql_valid(mv, i))) {
            fsql_list_out_put_null(&w, i); continue;
        }
        double threshold = thr ? thr[i] : 2.0;
        int64_t max_points = mp ? mp[i] : 64;
        if (win[i] <= 0) { fsql_fn_error(info, "fractalsql: win must be > 0"); goto done; }
        if (max_points <= 0 || max_points > MAX_CHANGE_POINTS) { fsql_fn_error(info, "fractalsql: max_points %d out of range [1, %d]", max_points, MAX_CHANGE_POINTS); goto done; }
        if (series_cap(info, sn)) goto done;
        if ((size_t)max_points > idxs_cap) {
            size_t *ni = (size_t *)realloc(idxs, (size_t)max_points * sizeof(size_t));
            if (!ni) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
            idxs = ni; idxs_cap = (size_t)max_points;
        }
        size_t out_n = 0;
        int rc = fsql_change_point_detect(s, sn, (size_t)win[i], threshold, idxs, (size_t)max_points, &out_n);
        if (rc != FSQL_OK) { rc_fail(info, "fractal_change_point_detect", rc, "(need n >= 2*win, threshold > 0)"); goto done; }
        int64_t tmp_small[64];
        int64_t *tmp = out_n <= 64 ? tmp_small : (int64_t *)fsql_xmalloc_array(out_n, sizeof(int64_t));
        if (!tmp) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
        for (size_t j = 0; j < out_n; j++) tmp[j] = (int64_t)idxs[j];
        bool ok = fsql_list_out_put_raw(&w, i, tmp, out_n, sizeof(int64_t));
        if (tmp != tmp_small) free(tmp);
        if (!ok) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
    }
done:
    fsql_list_out_close(&w);
    free(idxs);
}

/* ------------------------------------------------------------------ */
/* fractal_spectrogram_entropy(series [, window [, hop [, max_frames]]]) */
/* Short-time spectral entropy: one normalised value in [0,1] per frame  */
/* (mean removed, Hann tapered, direct DFT) -- low when the frame's      */
/* energy sits in a few frequencies, high when spread across the band.   */
/* A constant frame reports 0.0, never NaN. window in [8,512], hop >= 1, */
/* max_frames in [1,4096], series length >= window.                      */
/* ------------------------------------------------------------------ */

static void spectrogram_entropy_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    idx_t ncols = duckdb_data_chunk_get_column_count(in);
    const int32_t *wc = ncols >= 2 ? (const int32_t *)fsql_col_data(in, 1) : NULL;
    const uint64_t *wcv = ncols >= 2 ? fsql_col_validity(in, 1) : NULL;
    const int32_t *hc = ncols >= 3 ? (const int32_t *)fsql_col_data(in, 2) : NULL;
    const uint64_t *hcv = ncols >= 3 ? fsql_col_validity(in, 2) : NULL;
    const int32_t *mc = ncols >= 4 ? (const int32_t *)fsql_col_data(in, 3) : NULL;
    const uint64_t *mcv = ncols >= 4 ? fsql_col_validity(in, 3) : NULL;
    fsql_list sl;
    fsql_list_out w;
    double *ent = NULL; size_t ent_cap = 0;
    fsql_list_open(&sl, duckdb_data_chunk_get_vector(in, 0));
    fsql_list_out_open(&w, out);
    for (idx_t i = 0; i < n; i++) {
        const double *s; size_t sn;
        int g = series_row(info, &sl, i, &s, &sn);
        if (g < 0) goto done;
        if (g == 0 || (wc && !fsql_valid(wcv, i)) || (hc && !fsql_valid(hcv, i)) || (mc && !fsql_valid(mcv, i))) {
            fsql_list_out_put_null(&w, i); continue;
        }
        int64_t window = wc ? wc[i] : 64, hop = hc ? hc[i] : 32, max_frames = mc ? mc[i] : MAX_SPECTROGRAM_FRAMES;
        if (window < 8 || window > 512) { fsql_fn_error(info, "fractalsql: window %d out of range [8, 512]", window); goto done; }
        if (hop <= 0) { fsql_fn_error(info, "fractalsql: hop must be > 0"); goto done; }
        if (max_frames <= 0 || max_frames > MAX_SPECTROGRAM_FRAMES) { fsql_fn_error(info, "fractalsql: max_frames %d out of range [1, %d]", max_frames, MAX_SPECTROGRAM_FRAMES); goto done; }
        if (series_cap(info, sn)) goto done;
        if (sn < (size_t)window) { fsql_fn_error(info, "fractalsql: series shorter than window"); goto done; }
        /* The core writes min(available, max_frames) frames, so capping the buffer at
         * the available frame count changes no result. */
        size_t avail = (sn - (size_t)window) / (size_t)hop + 1;
        size_t cap = avail < (size_t)max_frames ? avail : (size_t)max_frames;
        if (cap > ent_cap) {
            double *ne = (double *)realloc(ent, cap * sizeof(double));
            if (!ne) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
            ent = ne; ent_cap = cap;
        }
        size_t out_n = 0;
        int rc = fsql_spectrogram_entropy(s, sn, (size_t)window, (size_t)hop, ent, cap, &out_n);
        if (rc != FSQL_OK) { rc_fail(info, "fractal_spectrogram_entropy", rc, NULL); goto done; }
        if (!fsql_list_out_put(&w, i, ent, out_n)) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
    }
done:
    fsql_list_out_close(&w);
    free(ent);
}

/* ------------------------------------------------------------------ */
/* fractal_tda_persistence_diagram(points, dim, max_dim, max_thresh     */
/*                                 [, max_h0_bars])                     */
/* max_dim and max_thresh are REQUIRED: max_dim is 0 (the exact 0-dim   */
/* bars only) or 1 (the bars plus the graph cycle-rank estimate), and    */
/* max_thresh is the filtration threshold (> 0).                          */
/* One composite value per call: STRUCT(h0_bars LIST(STRUCT(birth,       */
/* death)), betti1 BIGINT). betti1 is NULL exactly when max_dim < 1.     */
/*                                                                       */
/* Scope: h0 is exact single-linkage persistence, and betti1 is the      */
/* cycle rank of the underlying Vietoris-Rips graph (edges - vertices +  */
/* connected components), not simplicial H1 -- it over-counts whenever   */
/* filled triangles exist.                                               */
/* ------------------------------------------------------------------ */

static void tda_persistence_diagram_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    idx_t ncols = duckdb_data_chunk_get_column_count(in);
    const int32_t *dimv = (const int32_t *)fsql_col_data(in, 1);
    const uint64_t *dv = fsql_col_validity(in, 1);
    const int32_t *mdv = ncols >= 3 ? (const int32_t *)fsql_col_data(in, 2) : NULL;
    const uint64_t *mdvv = ncols >= 3 ? fsql_col_validity(in, 2) : NULL;
    const double *mtv = ncols >= 4 ? (const double *)fsql_col_data(in, 3) : NULL;
    const uint64_t *mtvv = ncols >= 4 ? fsql_col_validity(in, 3) : NULL;
    const int32_t *mbv = ncols >= 5 ? (const int32_t *)fsql_col_data(in, 4) : NULL;
    const uint64_t *mbvv = ncols >= 5 ? fsql_col_validity(in, 4) : NULL;

    duckdb_vector bars_list = duckdb_struct_vector_get_child(out, 0);
    duckdb_vector betti     = duckdb_struct_vector_get_child(out, 1);
    int64_t *betti_data = (int64_t *)duckdb_vector_get_data(betti);
    duckdb_list_entry *entries = (duckdb_list_entry *)duckdb_vector_get_data(bars_list);
    idx_t used = duckdb_list_vector_get_size(bars_list);

    fsql_list pl;
    fsql_list_open(&pl, duckdb_data_chunk_get_vector(in, 0));
    fsql_tda_bar_t *bars = NULL; size_t bars_cap = 0;

    for (idx_t i = 0; i < n; i++) {
        const double *p; size_t pn;
        int g = series_row(info, &pl, i, &p, &pn);
        if (g < 0) goto done;
        if (g == 0 || !fsql_valid(dv, i) || (mdv && !fsql_valid(mdvv, i)) || (mtv && !fsql_valid(mtvv, i)) ||
            (mbv && !fsql_valid(mbvv, i))) {
            fsql_set_null(out, i);
            entries[i].offset = used; entries[i].length = 0;
            continue;
        }
        int64_t dim = dimv[i];
        int64_t max_dim = mdv ? mdv[i] : 1;
        double max_thresh = mtv ? mtv[i] : 1.0;
        int64_t max_h0_bars = mbv ? mbv[i] : 64;

        if (dim <= 0) { fsql_fn_error(info, "fractalsql: dim must be > 0"); goto done; }
        if (dim > MAX_SPATIAL_DIM) { fsql_fn_error(info, "fractalsql: dim exceeds cap %d", MAX_SPATIAL_DIM); goto done; }
        if (pn > MAX_POINTS_FLAT_LEN) { fsql_fn_error(info, "fractalsql: points length %zu exceeds cap %zu", pn, MAX_POINTS_FLAT_LEN); goto done; }
        if (max_h0_bars > MAX_TDA_H0_BARS) { fsql_fn_error(info, "fractalsql: max_h0_bars %d out of range [1, %d]", max_h0_bars, MAX_TDA_H0_BARS); goto done; }
        /* The wrapper's four preconditions ride in ONE error: dim must divide the points
         * length, max_dim is 0 or 1, max_thresh > 0, max_h0_bars > 0. !(max_thresh > 0)
         * also catches a NaN threshold. */
        if (pn % (size_t)dim != 0 || (max_dim != 0 && max_dim != 1) || !(max_thresh > 0.0) || max_h0_bars <= 0) {
            fsql_fn_error(info, "fractalsql: invalid input (dim must divide points length, "
                                "max_dim must be 0 or 1, max_thresh > 0, max_h0_bars > 0)");
            goto done;
        }
        if ((size_t)max_h0_bars > bars_cap) {
            fsql_tda_bar_t *nb = (fsql_tda_bar_t *)realloc(bars, (size_t)max_h0_bars * sizeof *bars);
            if (!nb) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
            bars = nb; bars_cap = (size_t)max_h0_bars;
        }
        memset(bars, 0, (size_t)max_h0_bars * sizeof *bars);
        size_t out_n = 0, out_betti1 = 0;
        bool want_betti1 = max_dim >= 1;
        int rc = fsql_tda_persistence_diagram(p, pn / (size_t)dim, (size_t)dim, (int)max_dim, max_thresh,
                                              bars, (size_t)max_h0_bars, &out_n, want_betti1 ? &out_betti1 : NULL);
        if (rc != FSQL_OK) {
            fsql_fn_error(info, "fractalsql: fractal_tda_persistence_diagram rc=%d (2 <= n_points <= %d, max_dim in {0,1}, max_thresh > 0)",
                          rc, FSQL_TDA_MAX_POINTS);
            goto done;
        }
        if (duckdb_list_vector_reserve(bars_list, used + (idx_t)out_n) != DuckDBSuccess) {
            fsql_fn_error(info, "fractalsql: out of memory"); goto done;
        }
        /* fetch children AFTER reserving: reserve may move their storage */
        duckdb_vector elem = duckdb_list_vector_get_child(bars_list);
        double *birth = (double *)duckdb_vector_get_data(duckdb_struct_vector_get_child(elem, 0));
        double *death = (double *)duckdb_vector_get_data(duckdb_struct_vector_get_child(elem, 1));
        for (size_t j = 0; j < out_n; j++) { birth[used + j] = bars[j].birth; death[used + j] = bars[j].death; }
        entries[i].offset = used; entries[i].length = (idx_t)out_n;
        used += (idx_t)out_n;
        if (want_betti1) betti_data[i] = (int64_t)out_betti1;
        else fsql_set_null(betti, i);
    }
done:
    duckdb_list_vector_set_size(bars_list, used);
    free(bars);
}

/* ------------------------------------------------------------------ */
/* fractal_state_fingerprint(v DOUBLE[] [, n_bits [, seed]]) -> BLOB     */
/*                                                                       */
/* The seed default is 0.0 here; fractal_agent_detect_loop's own seed    */
/* default is 42.0. Each function's contract is its own: a 2-arg         */
/* fingerprint call and a default-seeded detect_loop therefore do not    */
/* agree bit-for-bit on the same state vector.                           */
/* ------------------------------------------------------------------ */

static void state_fingerprint_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    idx_t ncols = duckdb_data_chunk_get_column_count(in);
    const int32_t *nb = ncols >= 2 ? (const int32_t *)fsql_col_data(in, 1) : NULL;
    const uint64_t *nbv = ncols >= 2 ? fsql_col_validity(in, 1) : NULL;
    const double *sd = ncols >= 3 ? (const double *)fsql_col_data(in, 2) : NULL;
    const uint64_t *sdv = ncols >= 3 ? fsql_col_validity(in, 2) : NULL;
    fsql_list vl;
    uint8_t *buf = NULL; size_t buf_cap = 0;
    fsql_list_open(&vl, duckdb_data_chunk_get_vector(in, 0));
    for (idx_t i = 0; i < n; i++) {
        const double *v; size_t vn;
        int g = series_row(info, &vl, i, &v, &vn);
        if (g < 0) goto done;
        if (g == 0 || (nb && !fsql_valid(nbv, i)) || (sd && !fsql_valid(sdv, i))) { fsql_set_null(out, i); continue; }
        int64_t n_bits = nb ? nb[i] : 128;
        double seed = sd ? sd[i] : 0.0;
        if (vn == 0 || vn > MAX_FINGERPRINT_DIM) { fsql_fn_error(info, "fractalsql: v dim %zu out of range [1, %zu]", vn, MAX_FINGERPRINT_DIM); goto done; }
        if (n_bits <= 0 || n_bits > MAX_FINGERPRINT_BITS) { fsql_fn_error(info, "fractalsql: n_bits %lld out of range [1, %d]", (long long)n_bits, MAX_FINGERPRINT_BITS); goto done; }
        if (vn > 0 && (size_t)n_bits > (size_t)FSQL_FINGERPRINT_MAX_WORK / vn) {
            fsql_fn_error(info, "fractalsql: n_bits x vector length must not exceed %d", FSQL_FINGERPRINT_MAX_WORK);
            goto done;
        }
        size_t n_bytes = ((size_t)n_bits + 7) / 8;
        if (n_bytes > buf_cap) {
            uint8_t *nbuf = (uint8_t *)realloc(buf, n_bytes);
            if (!nbuf) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
            buf = nbuf; buf_cap = n_bytes;
        }
        memset(buf, 0, n_bytes);
        int rc = fsql_state_fingerprint(v, vn, (size_t)n_bits, seed, buf);
        if (rc != FSQL_OK) { rc_fail(info, "fractal_state_fingerprint", rc, NULL); goto done; }
        fsql_set_str(out, i, (const char *)buf, n_bytes);
    }
done:
    free(buf);
}

/* ------------------------------------------------------------------ */
/* Table functions: computed once in bind (a one-shot, bounded analytic  */
/* call, not a scan) and streamed out a vector at a time.                */
/* ------------------------------------------------------------------ */

typedef struct { idx_t offset; } stream_state;

static void stream_init(duckdb_init_info info) {
    stream_state *st = (stream_state *)calloc(1, sizeof *st);
    if (!st) { duckdb_init_set_error(info, "fractalsql: out of memory"); return; }
    duckdb_init_set_init_data(info, st, free);
}

/* Bind-time list-of-doubles parameter `idx`. 0 ok; -1 failed (message set on `info`). */
static int bind_series(duckdb_bind_info info, idx_t idx, fsql_vecd *out) {
    duckdb_value v = duckdb_bind_get_parameter(info, idx);
    if (duckdb_is_null_value(v)) {
        duckdb_destroy_value(&v);
        duckdb_bind_set_error(info, "fractalsql: series must not be NULL");
        return -1;
    }
    idx_t cnt = duckdb_get_list_size(v);
    for (idx_t k = 0; k < cnt; k++) {
        duckdb_value c = duckdb_get_list_child(v, k);
        if (duckdb_is_null_value(c)) {
            duckdb_destroy_value(&c); duckdb_destroy_value(&v);
            duckdb_bind_set_error(info, "fractalsql: series must not contain NULL elements");
            return -1;
        }
        fsql_vecd_push(out, duckdb_get_double(c));
        duckdb_destroy_value(&c);
    }
    duckdb_destroy_value(&v);
    if (!fsql_vecd_ok(out)) { duckdb_bind_set_error(info, "fractalsql: out of memory"); return -1; }
    return 0;
}

/* --- fractal_periodogram(series [, max_peaks]) -> TABLE(freq, power) --- */

typedef struct { double *freq, *power; size_t n; } periodogram_bind;

static void periodogram_bind_free(void *p) {
    periodogram_bind *b = (periodogram_bind *)p;
    if (!b) return;
    free(b->freq); free(b->power); free(b);
}

static void periodogram_bind_fn(duckdb_bind_info info) {
    fsql_vecd series; fsql_vecd_init(&series);
    periodogram_bind *b = NULL;
    double *freqs = NULL, *power = NULL;
    if (bind_series(info, 0, &series)) goto fail;

    int64_t max_peaks = 8;
    if (duckdb_bind_get_parameter_count(info) >= 2) {
        duckdb_value mp = duckdb_bind_get_parameter(info, 1);
        if (duckdb_is_null_value(mp)) {
            duckdb_destroy_value(&mp);
            duckdb_bind_set_error(info, "fractalsql: max_peaks must not be NULL");
            goto fail;
        }
        max_peaks = duckdb_get_int64(mp);
        duckdb_destroy_value(&mp);
    }
    if (max_peaks <= 0 || max_peaks > MAX_PEAKS) {
        char m[96]; snprintf(m, sizeof m, "fractalsql: max_peaks %lld out of range [1, %d]", (long long)max_peaks, MAX_PEAKS);
        duckdb_bind_set_error(info, m); goto fail;
    }
    if (series.len > MAX_PERIODOGRAM_LEN) {
        char m[256];
        snprintf(m, sizeof m, "fractalsql: series length %zu exceeds periodogram cap %zu "
                              "(direct O(n^2) DFT, capped tighter than the other analytics)", series.len, MAX_PERIODOGRAM_LEN);
        duckdb_bind_set_error(info, m); goto fail;
    }
    freqs = (double *)calloc((size_t)max_peaks, sizeof(double));
    power = (double *)calloc((size_t)max_peaks, sizeof(double));
    b = (periodogram_bind *)calloc(1, sizeof *b);
    if (!freqs || !power || !b) { duckdb_bind_set_error(info, "fractalsql: out of memory"); goto fail; }
    size_t out_n = 0;
    int rc = fsql_periodogram(series.p, series.len, freqs, power, (size_t)max_peaks, &out_n);
    if (rc != FSQL_OK) {
        char m[128]; snprintf(m, sizeof m, "fractalsql: fractal_periodogram rc=%d (need n >= 4)", rc);
        duckdb_bind_set_error(info, m); goto fail;
    }
    b->freq = freqs; b->power = power; b->n = out_n;
    freqs = power = NULL;
    {
        duckdb_logical_type t = duckdb_create_logical_type(DUCKDB_TYPE_DOUBLE);
        duckdb_bind_add_result_column(info, "freq", t);
        duckdb_bind_add_result_column(info, "power", t);
        duckdb_destroy_logical_type(&t);
    }
    duckdb_bind_set_bind_data(info, b, periodogram_bind_free);
    fsql_vecd_free(&series);
    return;
fail:
    fsql_vecd_free(&series); free(freqs); free(power); free(b);
}

static void periodogram_fn(duckdb_function_info info, duckdb_data_chunk out) {
    periodogram_bind *b = (periodogram_bind *)duckdb_function_get_bind_data(info);
    stream_state *st = (stream_state *)duckdb_function_get_init_data(info);
    double *f = (double *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(out, 0));
    double *p = (double *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(out, 1));
    idx_t remaining = (idx_t)b->n - st->offset;
    idx_t cap = duckdb_vector_size();
    idx_t k = remaining < cap ? remaining : cap;
    for (idx_t i = 0; i < k; i++) { f[i] = b->freq[st->offset + i]; p[i] = b->power[st->offset + i]; }
    st->offset += k;
    duckdb_data_chunk_set_size(out, k);
}

/* --- fractal_cycle_detect(fingerprints BLOB[] [, hamming_threshold]) ---- */
/* A BATCH call: one fsql_cycle_state_t is created, fsql_cycle_detect_feed    */
/* runs over every element of the supplied array in order, and the detector    */
/* is freed before returning -- the raw streaming API is never exposed across  */
/* separate SQL calls.                                                         */

typedef struct { int32_t *at_index; int64_t *cycle_len; size_t n, cap; } cycle_bind;

static void cycle_bind_free(void *p) {
    cycle_bind *b = (cycle_bind *)p;
    if (!b) return;
    free(b->at_index); free(b->cycle_len); free(b);
}

static bool cycle_push(cycle_bind *b, int32_t at, int64_t len) {
    if (b->n == b->cap) {
        size_t nc = b->cap ? b->cap * 2 : 64;
        int32_t *na = (int32_t *)realloc(b->at_index, nc * sizeof(int32_t));
        if (!na) return false;
        b->at_index = na;
        int64_t *nl = (int64_t *)realloc(b->cycle_len, nc * sizeof(int64_t));
        if (!nl) return false;
        b->cycle_len = nl;
        b->cap = nc;
    }
    b->at_index[b->n] = at; b->cycle_len[b->n] = len; b->n++;
    return true;
}

static void cycle_detect_bind_fn(duckdb_bind_info info) {
    cycle_bind *b = (cycle_bind *)calloc(1, sizeof *b);
    duckdb_value fps = duckdb_bind_get_parameter(info, 0);
    bool cs_live = false;
    fsql_cycle_state_t cs;
    char m[256];
    if (!b) { duckdb_bind_set_error(info, "fractalsql: out of memory"); goto fail; }
    if (duckdb_is_null_value(fps)) { duckdb_bind_set_error(info, "fractalsql: fingerprints must not be NULL"); goto fail; }
    idx_t cnt = duckdb_get_list_size(fps);
    if (cnt == 0) { duckdb_bind_set_error(info, "fractalsql: fingerprints array must not be empty"); goto fail; }
    if (cnt > MAX_CYCLE_DETECT_LEN) {
        snprintf(m, sizeof m, "fractalsql: fingerprints array length %llu exceeds cap %zu", (unsigned long long)cnt, MAX_CYCLE_DETECT_LEN);
        duckdb_bind_set_error(info, m); goto fail;
    }
    int64_t hamming = 0;
    if (duckdb_bind_get_parameter_count(info) >= 2) {
        duckdb_value hv = duckdb_bind_get_parameter(info, 1);
        if (duckdb_is_null_value(hv)) { duckdb_destroy_value(&hv); duckdb_bind_set_error(info, "fractalsql: hamming_threshold must not be NULL"); goto fail; }
        hamming = duckdb_get_int64(hv);
        duckdb_destroy_value(&hv);
    }
    if (hamming < 0) { duckdb_bind_set_error(info, "fractalsql: hamming_threshold must be >= 0"); goto fail; }

    size_t n_bytes = 0;
    {
        duckdb_value c0 = duckdb_get_list_child(fps, 0);
        if (duckdb_is_null_value(c0)) { duckdb_destroy_value(&c0); duckdb_bind_set_error(info, "fractalsql: fingerprints array must not contain NULLs"); goto fail; }
        duckdb_blob b0 = duckdb_get_blob(c0);
        n_bytes = (size_t)b0.size;
        duckdb_free(b0.data);
        duckdb_destroy_value(&c0);
    }
    if (n_bytes == 0) { duckdb_bind_set_error(info, "fractalsql: fingerprint length must be > 0"); goto fail; }
    int rc = fsql_cycle_detect_init(&cs, n_bytes, (size_t)hamming);
    if (rc != FSQL_OK) { snprintf(m, sizeof m, "fractalsql: fsql_cycle_detect_init rc=%d", rc); duckdb_bind_set_error(info, m); goto fail; }
    cs_live = true;

    for (idx_t i = 0; i < cnt; i++) {
        duckdb_value c = duckdb_get_list_child(fps, i);
        if (duckdb_is_null_value(c)) { duckdb_destroy_value(&c); duckdb_bind_set_error(info, "fractalsql: fingerprints array must not contain NULLs"); goto fail; }
        duckdb_blob fp = duckdb_get_blob(c);
        if ((size_t)fp.size != n_bytes) {
            snprintf(m, sizeof m, "fractalsql: every fingerprint must be the same length (index 0 was %zu bytes, index %llu is %llu)",
                     n_bytes, (unsigned long long)i, (unsigned long long)fp.size);
            duckdb_free(fp.data); duckdb_destroy_value(&c);
            duckdb_bind_set_error(info, m); goto fail;
        }
        int detected = 0; size_t cycle_len = 0;
        rc = fsql_cycle_detect_feed(&cs, (const uint8_t *)fp.data, &detected, &cycle_len);
        duckdb_free(fp.data); duckdb_destroy_value(&c);
        if (rc != FSQL_OK) { snprintf(m, sizeof m, "fractalsql: fsql_cycle_detect_feed rc=%d", rc); duckdb_bind_set_error(info, m); goto fail; }
        if (detected && !cycle_push(b, (int32_t)i, (int64_t)cycle_len)) { duckdb_bind_set_error(info, "fractalsql: out of memory"); goto fail; }
    }
    fsql_cycle_detect_free(&cs);
    cs_live = false;
    {
        duckdb_logical_type ti = duckdb_create_logical_type(DUCKDB_TYPE_INTEGER);
        duckdb_logical_type tb = duckdb_create_logical_type(DUCKDB_TYPE_BIGINT);
        duckdb_bind_add_result_column(info, "at_index", ti);
        duckdb_bind_add_result_column(info, "cycle_len", tb);
        duckdb_destroy_logical_type(&ti); duckdb_destroy_logical_type(&tb);
    }
    duckdb_destroy_value(&fps);
    duckdb_bind_set_bind_data(info, b, cycle_bind_free);
    return;
fail:
    if (cs_live) fsql_cycle_detect_free(&cs);
    duckdb_destroy_value(&fps);
    cycle_bind_free(b);
}

static void cycle_detect_fn(duckdb_function_info info, duckdb_data_chunk out) {
    cycle_bind *b = (cycle_bind *)duckdb_function_get_bind_data(info);
    stream_state *st = (stream_state *)duckdb_function_get_init_data(info);
    int32_t *a = (int32_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(out, 0));
    int64_t *l = (int64_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(out, 1));
    idx_t remaining = (idx_t)b->n - st->offset;
    idx_t cap = duckdb_vector_size();
    idx_t k = remaining < cap ? remaining : cap;
    for (idx_t i = 0; i < k; i++) { a[i] = b->at_index[st->offset + i]; l[i] = b->cycle_len[st->offset + i]; }
    st->offset += k;
    duckdb_data_chunk_set_size(out, k);
}


/* ------------------------------------------------------------------ */
/* Morphology: domain-specific geometric / topological metrics over     */
/* PRE-EXTRACTED geometry (vessel graphs, meshes, skeleton graphs,      */
/* point-cloud masks) -- not raw medical imaging data. Segmentation     */
/* from raw imaging is a much larger, separate problem.                 */
/*                                                                      */
/*   fractal_vascular_network(node_coords DOUBLE[], edges BIGINT[],     */
/*       edge_arc_length DOUBLE[]) -> STRUCT(mean_tortuosity,           */
/*       branch_density, fractal_dimension)                             */
/*   fractal_cortical_folding(vertices DOUBLE[], faces BIGINT[])        */
/*       -> STRUCT(mesh_area, hull_area, gyrification_index)            */
/*   fractal_nerve_plexus_metric(node_coords DOUBLE[], dim INTEGER,     */
/*       edges BIGINT[]) -> STRUCT(fiber_length_density,                */
/*       branch_density, fractal_dimension)                             */
/*   fractal_morphological_complexity(points DOUBLE[], dim INTEGER)     */
/*       -> STRUCT(dimension, lacunarity)                               */
/*                                                                      */
/* Every result is small and fixed-shape, so each is a native STRUCT.   */
/* None needs an fsql_ctx.                                              */
/* ------------------------------------------------------------------ */

#define MAX_GEOM_ELEMENTS ((size_t)1000000)   /* n_nodes / n_vertices / n_points */
#define MAX_GEOM_LINKS    ((size_t)2000000)   /* n_edges / n_faces               */
#define MAX_GEOM_DIM      3

/* A BIGINT list row: 1 ok / 0 NULL (row or element) / -1 failed (message set). */
typedef struct {
    const duckdb_list_entry *entries;
    const uint64_t *validity;
    const int64_t *child;
    const uint64_t *child_valid;
    idx_t child_size;
} bigint_list;

static void bigint_list_open(bigint_list *l, duckdb_vector v) {
    fsql_list b;
    fsql_list_open(&b, v);
    l->entries = b.entries; l->validity = b.validity; l->child = (const int64_t *)b.child;
    l->child_valid = b.child_valid; l->child_size = b.child_size;
}

static int bigint_row(duckdb_function_info info, const bigint_list *l, idx_t row, const int64_t **p, size_t *n) {
    fsql_list b = { l->entries, l->validity, l->child, l->child_valid, l->child_size };
    idx_t off; const char *err = NULL;
    int g = fsql_list_range(&b, row, &off, n, &err);
    if (g < 0) { fsql_fn_error(info, "%s", err); return -1; }
    if (g == 1) *p = l->child + off;
    return g;
}

/* Every index must lie in [0, n). 0 ok, -1 failed (message set). */
static int check_index_range(duckdb_function_info info, const int64_t *idx, size_t cnt, size_t n, const char *what) {
    for (size_t i = 0; i < cnt; i++) {
        if (idx[i] < 0 || (size_t)idx[i] >= n) {
            fsql_fn_error(info, "fractalsql: %s index %lld out of range [0, %zu)", what, (long long)idx[i], n);
            return -1;
        }
    }
    return 0;
}

/* int64 indices -> a size_t array (the core's index type). NULL on OOM. */
static size_t *to_size_t(const int64_t *v, size_t n) {
    size_t *o = (size_t *)fsql_xmalloc_array(n ? n : 1, sizeof(size_t));
    if (o) for (size_t i = 0; i < n; i++) o[i] = (size_t)v[i];
    return o;
}

static int check_geom_dim(duckdb_function_info info, int32_t dim) {
    if (dim < 1 || dim > MAX_GEOM_DIM) {
        fsql_fn_error(info, "fractalsql: dim %d out of range [1, %d]", (int)dim, MAX_GEOM_DIM);
        return -1;
    }
    return 0;
}

/* The result struct's DOUBLE children. */
static void struct3(duckdb_vector out, double **a, double **b, double **c) {
    *a = (double *)duckdb_vector_get_data(duckdb_struct_vector_get_child(out, 0));
    *b = (double *)duckdb_vector_get_data(duckdb_struct_vector_get_child(out, 1));
    if (c) *c = (double *)duckdb_vector_get_data(duckdb_struct_vector_get_child(out, 2));
}

static void vascular_network_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    double *r0, *r1, *r2;
    struct3(out, &r0, &r1, &r2);
    fsql_list nc, arc;
    bigint_list ed;
    fsql_list_open(&nc, duckdb_data_chunk_get_vector(in, 0));
    bigint_list_open(&ed, duckdb_data_chunk_get_vector(in, 1));
    fsql_list_open(&arc, duckdb_data_chunk_get_vector(in, 2));
    for (idx_t i = 0; i < n; i++) {
        const double *coords, *arcs; const int64_t *edges; size_t cn, en, an;
        int g1 = series_row(info, &nc, i, &coords, &cn);
        if (g1 < 0) return;
        int g2 = g1 ? bigint_row(info, &ed, i, &edges, &en) : 0;
        if (g2 < 0) return;
        int g3 = (g1 && g2) ? series_row(info, &arc, i, &arcs, &an) : 0;
        if (g3 < 0) return;
        if (!g1 || !g2 || !g3) { fsql_set_null(out, i); continue; }

        if (cn % 3 != 0) { fsql_fn_error(info, "fractalsql: node_coords length must be a multiple of 3"); return; }
        if (en % 2 != 0) { fsql_fn_error(info, "fractalsql: edges length must be a multiple of 2"); return; }
        size_t n_nodes = cn / 3, n_edges = en / 2;
        if (an != n_edges) {
            fsql_fn_error(info, "fractalsql: edge_arc_length length (%zu) must equal edges length / 2 (%zu)", an, n_edges);
            return;
        }
        if (n_nodes > MAX_GEOM_ELEMENTS) { fsql_fn_error(info, "fractalsql: node_coords node count exceeds cap"); return; }
        if (n_edges > MAX_GEOM_LINKS) { fsql_fn_error(info, "fractalsql: edges edge count exceeds cap"); return; }
        if (check_index_range(info, edges, en, n_nodes, "edges")) return;
        size_t *e = to_size_t(edges, en);
        if (!e) { fsql_fn_error(info, "fractalsql: out of memory"); return; }
        double tort, dens, fdim;
        int rc = fsql_vascular_network(coords, n_nodes, e, arcs, n_edges, &tort, &dens, &fdim);
        free(e);
        if (rc != FSQL_OK) { rc_fail(info, "fractal_vascular_network", rc, NULL); return; }
        r0[i] = tort; r1[i] = dens; r2[i] = fdim;
    }
}

static void cortical_folding_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    double *r0, *r1, *r2;
    struct3(out, &r0, &r1, &r2);
    fsql_list vl;
    bigint_list fl;
    fsql_list_open(&vl, duckdb_data_chunk_get_vector(in, 0));
    bigint_list_open(&fl, duckdb_data_chunk_get_vector(in, 1));
    for (idx_t i = 0; i < n; i++) {
        const double *verts; const int64_t *faces; size_t vn, fn;
        int g1 = series_row(info, &vl, i, &verts, &vn);
        if (g1 < 0) return;
        int g2 = g1 ? bigint_row(info, &fl, i, &faces, &fn) : 0;
        if (g2 < 0) return;
        if (!g1 || !g2) { fsql_set_null(out, i); continue; }
        if (vn % 3 != 0) { fsql_fn_error(info, "fractalsql: vertices length must be a multiple of 3"); return; }
        if (fn % 3 != 0) { fsql_fn_error(info, "fractalsql: faces length must be a multiple of 3"); return; }
        size_t n_vertices = vn / 3, n_faces = fn / 3;
        if (n_vertices > MAX_GEOM_ELEMENTS) { fsql_fn_error(info, "fractalsql: vertices vertex count exceeds cap"); return; }
        if (n_faces > MAX_GEOM_LINKS) { fsql_fn_error(info, "fractalsql: faces face count exceeds cap"); return; }
        if (check_index_range(info, faces, fn, n_vertices, "faces")) return;
        size_t *f = to_size_t(faces, fn);
        if (!f) { fsql_fn_error(info, "fractalsql: out of memory"); return; }
        double mesh, hull, gyr;
        int rc = fsql_cortical_folding(verts, n_vertices, f, n_faces, &mesh, &hull, &gyr);
        free(f);
        if (rc != FSQL_OK) { rc_fail(info, "fractal_cortical_folding", rc, "(need >= 4 non-coplanar vertices)"); return; }
        r0[i] = mesh; r1[i] = hull; r2[i] = gyr;
    }
}

static void nerve_plexus_metric_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    double *r0, *r1, *r2;
    struct3(out, &r0, &r1, &r2);
    const int32_t *dimv = (const int32_t *)fsql_col_data(in, 1);
    const uint64_t *dv = fsql_col_validity(in, 1);
    fsql_list nc;
    bigint_list ed;
    fsql_list_open(&nc, duckdb_data_chunk_get_vector(in, 0));
    bigint_list_open(&ed, duckdb_data_chunk_get_vector(in, 2));
    for (idx_t i = 0; i < n; i++) {
        const double *coords; const int64_t *edges; size_t cn, en;
        int g1 = series_row(info, &nc, i, &coords, &cn);
        if (g1 < 0) return;
        int g2 = (g1 && fsql_valid(dv, i)) ? 1 : 0;
        int g3 = g2 ? bigint_row(info, &ed, i, &edges, &en) : 0;
        if (g3 < 0) return;
        if (!g1 || !g2 || !g3) { fsql_set_null(out, i); continue; }
        int32_t dim = dimv[i];
        if (check_geom_dim(info, dim)) return;
        if (cn == 0 || cn % (size_t)dim != 0) {
            fsql_fn_error(info, "fractalsql: node_coords length (%zu) must be a positive multiple of dim (%d)", cn, (int)dim);
            return;
        }
        if (en % 2 != 0) { fsql_fn_error(info, "fractalsql: edges length must be a multiple of 2"); return; }
        size_t n_nodes = cn / (size_t)dim, n_edges = en / 2;
        if (n_nodes > MAX_GEOM_ELEMENTS) { fsql_fn_error(info, "fractalsql: node_coords node count exceeds cap"); return; }
        if (n_edges > MAX_GEOM_LINKS) { fsql_fn_error(info, "fractalsql: edges edge count exceeds cap"); return; }
        if (check_index_range(info, edges, en, n_nodes, "edges")) return;
        size_t *e = to_size_t(edges, en);
        if (!e) { fsql_fn_error(info, "fractalsql: out of memory"); return; }
        double fld, bd, fdim;
        int rc = fsql_nerve_plexus_metric(coords, n_nodes, (size_t)dim, e, n_edges, &fld, &bd, &fdim);
        free(e);
        if (rc != FSQL_OK) { rc_fail(info, "fractal_nerve_plexus_metric", rc, NULL); return; }
        r0[i] = fld; r1[i] = bd; r2[i] = fdim;
    }
}

static void morphological_complexity_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    double *r0, *r1;
    struct3(out, &r0, &r1, NULL);
    const int32_t *dimv = (const int32_t *)fsql_col_data(in, 1);
    const uint64_t *dv = fsql_col_validity(in, 1);
    fsql_list pl;
    fsql_list_open(&pl, duckdb_data_chunk_get_vector(in, 0));
    for (idx_t i = 0; i < n; i++) {
        const double *pts; size_t pn;
        int g = series_row(info, &pl, i, &pts, &pn);
        if (g < 0) return;
        if (!g || !fsql_valid(dv, i)) { fsql_set_null(out, i); continue; }
        int32_t dim = dimv[i];
        if (check_geom_dim(info, dim)) return;
        if (pn == 0 || pn % (size_t)dim != 0) {
            fsql_fn_error(info, "fractalsql: points length (%zu) must be a positive multiple of dim (%d)", pn, (int)dim);
            return;
        }
        size_t n_points = pn / (size_t)dim;
        if (n_points > MAX_GEOM_ELEMENTS) { fsql_fn_error(info, "fractalsql: points point count exceeds cap"); return; }
        double dimension, lacunarity;
        int rc = fsql_morphological_complexity(pts, n_points, (size_t)dim, &dimension, &lacunarity);
        if (rc != FSQL_OK) { rc_fail(info, "fractal_morphological_complexity", rc, "(need >= 8 points, non-degenerate bounding box)"); return; }
        r0[i] = dimension; r1[i] = lacunarity;
    }
}


/* ------------------------------------------------------------------ */
/* Portfolio optimisation (community): cardinality-constrained,          */
/* Sharpe-objective search via the core's SFS engine.                    */
/*                                                                       */
/*   fractal_optimize_portfolio(mu DOUBLE[], cov DOUBLE[], k INTEGER      */
/*       [, seed BIGINT [, use_obl BOOLEAN [, diffusion_mode VARCHAR]]])  */
/*       -> STRUCT(sharpe DOUBLE, weights DOUBLE[])                       */
/*   fractal_optimize_subset(item_values DOUBLE[], upper_bounds DOUBLE[], */
/*       k INTEGER [, prev_weights DOUBLE[] [, turnover_penalty DOUBLE    */
/*       [, seed BIGINT]]]) -> STRUCT(score DOUBLE, weights DOUBLE[])     */
/*                                                                       */
/* fractal_optimize_portfolio always calls the _ex core entry point with  */
/* use_obl=false / diffusion_mode=0 (gaussian) as the SQL-level defaults. */
/* The multimodal and Pareto variants are enterprise-gated and register   */
/* with the enterprise loader (fsql_enterprise.c).                        */
/* ------------------------------------------------------------------ */

/* A STRUCT(<DOUBLE>, <LIST(DOUBLE)>) result being filled row by row. */
typedef struct {
    double *scalar;
    fsql_list_out w;
    duckdb_vector parent;
} dl_out;

static void dl_out_open(dl_out *o, duckdb_vector out) {
    o->parent = out;
    o->scalar = (double *)duckdb_vector_get_data(duckdb_struct_vector_get_child(out, 0));
    fsql_list_out_open(&o->w, duckdb_struct_vector_get_child(out, 1));
}
static void dl_out_null(dl_out *o, idx_t row) {
    fsql_set_null(o->parent, row);
    o->w.entries[row].offset = o->w.used;
    o->w.entries[row].length = 0;
}
static bool dl_out_put(dl_out *o, idx_t row, double scalar, const double *v, size_t n) {
    o->scalar[row] = scalar;
    return fsql_list_out_put(&o->w, row, v, n);
}
static void dl_out_close(dl_out *o) { fsql_list_out_close(&o->w); }

static int parse_diffusion_mode(duckdb_function_info info, const char *m, size_t n, int *out) {
    if (n == 8 && memcmp(m, "gaussian", 8) == 0) { *out = 0; return 0; }
    if (n == 4 && memcmp(m, "levy", 4) == 0)     { *out = 1; return 0; }
    fsql_fn_error(info, "fractalsql: diffusion_mode must be 'gaussian' or 'levy' (got '%.*s')", (int)n, m);
    return -1;
}

static void optimize_portfolio_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    idx_t ncols = duckdb_data_chunk_get_column_count(in);
    fsql_list ml, cl;
    dl_out o;
    double *weights = NULL; size_t wcap = 0;
    const int32_t *kv = (const int32_t *)fsql_col_data(in, 2);
    const uint64_t *kvv = fsql_col_validity(in, 2);
    const int64_t *sv = ncols > 3 ? (const int64_t *)fsql_col_data(in, 3) : NULL;
    const uint64_t *svv = ncols > 3 ? fsql_col_validity(in, 3) : NULL;
    const uint8_t *ov = ncols > 4 ? (const uint8_t *)fsql_col_data(in, 4) : NULL;
    const uint64_t *ovv = ncols > 4 ? fsql_col_validity(in, 4) : NULL;
    const duckdb_string_t *dm = ncols > 5 ? (const duckdb_string_t *)fsql_col_data(in, 5) : NULL;
    const uint64_t *dmv = ncols > 5 ? fsql_col_validity(in, 5) : NULL;
    fsql_list_open(&ml, duckdb_data_chunk_get_vector(in, 0));
    fsql_list_open(&cl, duckdb_data_chunk_get_vector(in, 1));
    dl_out_open(&o, out);
    for (idx_t i = 0; i < n; i++) {
        const double *mu, *cov; size_t mn, cn;
        int g = series_row(info, &ml, i, &mu, &mn);
        if (g < 0) goto done;
        if (g == 0 || mn == 0) { fsql_fn_error(info, "fractalsql: mu must not be NULL or empty"); goto done; }
        g = series_row(info, &cl, i, &cov, &cn);
        if (g < 0) goto done;
        if (g == 0) { fsql_fn_error(info, "fractalsql: cov must not be NULL"); goto done; }
        if (!fsql_valid(kvv, i)) { fsql_fn_error(info, "fractalsql: k must not be NULL"); goto done; }
        int32_t k32 = kv[i];
        size_t n_assets = mn;
        if (n_assets > 8192 || cn != n_assets * n_assets) {   /* bounded so n*n cannot wrap (SECURITY_AUDIT.md 3.15) */
            fsql_fn_error(info, "fractalsql: cov length (%zu) must be n_assets^2 (n_assets=%zu, expected %zu)", cn, n_assets, n_assets * n_assets);
            goto done;
        }
        if (k32 <= 0 || (size_t)k32 > n_assets) { fsql_fn_error(info, "fractalsql: k must satisfy 1 <= k <= n_assets (%zu)", n_assets); goto done; }
        int64_t seed = (sv && fsql_valid(svv, i)) ? sv[i] : 0;
        bool use_obl = (ov && fsql_valid(ovv, i)) ? ov[i] != 0 : false;
        int diffusion_mode = 0;
        if (dm && fsql_valid(dmv, i)) {
            size_t ln; const char *m = fsql_str_data(&dm[i], &ln);
            if (parse_diffusion_mode(info, m, ln, &diffusion_mode)) goto done;
        }
        if (n_assets > wcap) {
            double *nw = (double *)realloc(weights, n_assets * sizeof(double));
            if (!nw) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
            weights = nw; wcap = n_assets;
        }
        double sharpe;
        int rc = fsql_optimize_portfolio_ex(mu, cov, n_assets, (size_t)k32, (uint64_t)seed,
                                            use_obl ? 1 : 0, diffusion_mode, weights, &sharpe);
        if (rc != FSQL_OK) { rc_fail(info, "fractal_optimize_portfolio", rc, NULL); goto done; }
        if (!dl_out_put(&o, i, sharpe, weights, n_assets)) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
    }
done:
    dl_out_close(&o);
    free(weights);
}

/* fsql_optimize_subset's objective is a C function pointer into the core: there is no way
 * to marshal a SQL expression into that slot, so a fixed objective is provided: maximise
 * sum(weight[i] * item_values[i]), reported to the core negated (its contract is "lower is
 * better") and negated back before returning. */
static double subset_value_weighted_objective(const double *weights, size_t n, void *ctx) {
    const double *item_values = (const double *)ctx;
    double total = 0.0;
    for (size_t i = 0; i < n; i++) total += weights[i] * item_values[i];
    return -total;
}

static void optimize_subset_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    idx_t ncols = duckdb_data_chunk_get_column_count(in);
    fsql_list il, ul, pl;
    dl_out o;
    double *weights = NULL; size_t wcap = 0;
    const int32_t *kv = (const int32_t *)fsql_col_data(in, 2);
    const uint64_t *kvv = fsql_col_validity(in, 2);
    const double *tv = ncols > 4 ? (const double *)fsql_col_data(in, 4) : NULL;
    const uint64_t *tvv = ncols > 4 ? fsql_col_validity(in, 4) : NULL;
    const int64_t *sv = ncols > 5 ? (const int64_t *)fsql_col_data(in, 5) : NULL;
    const uint64_t *svv = ncols > 5 ? fsql_col_validity(in, 5) : NULL;
    fsql_list_open(&il, duckdb_data_chunk_get_vector(in, 0));
    fsql_list_open(&ul, duckdb_data_chunk_get_vector(in, 1));
    if (ncols > 3) fsql_list_open(&pl, duckdb_data_chunk_get_vector(in, 3));
    dl_out_open(&o, out);
    for (idx_t i = 0; i < n; i++) {
        const double *iv, *ub, *prev = NULL; size_t in_n, ubn, pn;
        int g = series_row(info, &il, i, &iv, &in_n);
        if (g < 0) goto done;
        if (g == 0) { dl_out_null(&o, i); continue; }       /* NULL (or NULL element) -> typed NULL */
        if (in_n == 0) { fsql_fn_error(info, "fractalsql: item_values must not be NULL or empty"); goto done; }
        g = series_row(info, &ul, i, &ub, &ubn);
        if (g < 0) goto done;
        if (g == 0 || !fsql_valid(kvv, i)) { dl_out_null(&o, i); continue; }
        int32_t k32 = kv[i];
        size_t n_items = in_n;
        if (ubn != n_items) { fsql_fn_error(info, "fractalsql: upper_bounds length (%zu) must match item_values length (%zu)", ubn, n_items); goto done; }
        if (k32 <= 0 || (size_t)k32 > n_items) { fsql_fn_error(info, "fractalsql: k must satisfy 1 <= k <= n_items (%zu)", n_items); goto done; }
        if ((unsigned long long)n_items * (unsigned long long)k32 > FSQL_SUBSET_MAX_WORK) {
            fsql_fn_error(info, "fractalsql: item count x k must not exceed %llu", FSQL_SUBSET_MAX_WORK);
            goto done;
        }
        if (ncols > 3) {
            g = series_row(info, &pl, i, &prev, &pn);
            if (g < 0) goto done;
            if (g == 1) {
                if (pn != n_items) { fsql_fn_error(info, "fractalsql: prev_weights length (%zu) must match item_values length (%zu)", pn, n_items); goto done; }
            } else prev = NULL;
        }
        double turnover = (tv && fsql_valid(tvv, i)) ? tv[i] : 0.0;
        int64_t seed = (sv && fsql_valid(svv, i)) ? sv[i] : 0;
        if (n_items > wcap) {
            double *nw = (double *)realloc(weights, n_items * sizeof(double));
            if (!nw) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
            weights = nw; wcap = n_items;
        }
        double score;
        int rc = fsql_optimize_subset(subset_value_weighted_objective, (void *)iv, n_items, (size_t)k32,
                                      /* lower_bounds */ NULL, ub, prev, turnover, (uint64_t)seed, weights, &score);
        if (rc != FSQL_OK) {
            rc_fail(info, "fractal_optimize_subset", rc, "(check upper_bounds in [0,1], sum of k largest upper_bounds >= 1.0)");
            goto done;
        }
        if (!dl_out_put(&o, i, -score, weights, n_items)) { fsql_fn_error(info, "fractalsql: out of memory"); goto done; }
    }
done:
    dl_out_close(&o);
    free(weights);
}


/* ------------------------------------------------------------------ */
/* Diversify / Repulsion controls and engagement feedback               */
/*                                                                      */
/*   fractal_diversify_enable() / _disable() -> BOOLEAN                 */
/*   fractal_diversify_set_params([window_n INTEGER [, stall_threshold  */
/*       DOUBLE [, repulsion_sigma DOUBLE [, repulsion_weight DOUBLE    */
/*       [, max_shadows_considered INTEGER [, tail_buffer_cap INTEGER   */
/*       ]]]]]]) -> BOOLEAN   -- trailing args omitted (or passed NULL)  */
/*       leave the core's current value for that field; scalar          */
/*       functions are positional only, so skipping a middle field means */
/*       passing NULL for it                                            */
/*   fractal_detect_collapse() -> DOUBLE        (current D_q)           */
/*   fractal_explain_result() -> VARCHAR (json)                         */
/*   fractal_feedback_report(result_handle BIGINT, kind VARCHAR         */
/*       [, dwell_ms INTEGER]) -> BOOLEAN                               */
/*   fractal_isolate_background(result_handle BIGINT) -> BOOLEAN        */
/*                                                                      */
/* They act on the CALLING CONNECTION's core context (the per-connection */
/* state in fsql_ledger.c). Zero-argument functions run once per chunk   */
/* and answer every row alike.                                          */
/* ------------------------------------------------------------------ */

static FsqlConn *div_conn(duckdb_function_info info, const char *fn) {
    FsqlConn *c = fsql_conn_get(fsql_scalar_instance(info), fsql_exec_conn_id(info));
    if (!c || !c->ctx) { fsql_ledger_fail(info, fn, "fsql_new_sovereign failed (OOM?)"); return NULL; }
    return c;
}

/* rc != OK -> "<what> rc=N: <core error>". 0 ok, -1 failed (message set). */
static int div_rc(duckdb_function_info info, FsqlConn *c, const char *fn, int rc, const char *what) {
    if (rc == FSQL_OK) return 0;
    const char *e = fsql_last_error(c->ctx);
    fsql_ledger_fail(info, fn, "%s rc=%d: %s", what, rc, (e && *e) ? e : "(no detail)");
    return -1;
}

static void fill_bool(duckdb_data_chunk in, duckdb_vector out, bool v) {
    bool *res = (bool *)duckdb_vector_get_data(out);
    for (idx_t i = 0, n = duckdb_data_chunk_get_size(in); i < n; i++) res[i] = v;
}

static void diversify_enable_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    FsqlConn *c = div_conn(info, "fractal_diversify_enable");
    if (!c) return;
    fsql_mu_lock(&c->mu);
    int bad = div_rc(info, c, "fractal_diversify_enable", fsql_diversify_enable(c->ctx), "fsql_diversify_enable");
    if (!bad) c->diversify_enabled = 1;
    fsql_mu_unlock(&c->mu);
    if (!bad) fill_bool(in, out, true);
}

static void diversify_disable_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    FsqlConn *c = div_conn(info, "fractal_diversify_disable");
    if (!c) return;
    fsql_mu_lock(&c->mu);
    int bad = div_rc(info, c, "fractal_diversify_disable", fsql_diversify_disable(c->ctx), "fsql_diversify_disable");
    if (!bad) c->diversify_enabled = 0;
    fsql_mu_unlock(&c->mu);
    if (!bad) fill_bool(in, out, false);
}

static void diversify_set_params_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    FsqlConn *c = div_conn(info, "fractal_diversify_set_params");
    if (!c) return;
    idx_t n = duckdb_data_chunk_get_size(in);
    idx_t ncols = duckdb_data_chunk_get_column_count(in);
    bool *res = (bool *)duckdb_vector_get_data(out);
    for (idx_t i = 0; i < n; i++) {
        fsql_diversify_params_t p;
        fsql_mu_lock(&c->mu);
        int bad = div_rc(info, c, "fractal_diversify_set_params", fsql_diversify_get_params(c->ctx, &p), "fsql_diversify_get_params");
        if (!bad) {
            if (ncols > 0 && fsql_valid(fsql_col_validity(in, 0), i)) p.window_n = (uint32_t)((const int32_t *)fsql_col_data(in, 0))[i];
            if (ncols > 1 && fsql_valid(fsql_col_validity(in, 1), i)) p.stall_threshold = ((const double *)fsql_col_data(in, 1))[i];
            if (ncols > 2 && fsql_valid(fsql_col_validity(in, 2), i)) p.repulsion_sigma = ((const double *)fsql_col_data(in, 2))[i];
            if (ncols > 3 && fsql_valid(fsql_col_validity(in, 3), i)) p.repulsion_weight = ((const double *)fsql_col_data(in, 3))[i];
            if (ncols > 4 && fsql_valid(fsql_col_validity(in, 4), i)) p.max_shadows_considered = (uint32_t)((const int32_t *)fsql_col_data(in, 4))[i];
            if (ncols > 5 && fsql_valid(fsql_col_validity(in, 5), i)) p.tail_buffer_cap = (uint32_t)((const int32_t *)fsql_col_data(in, 5))[i];
            bad = div_rc(info, c, "fractal_diversify_set_params", fsql_diversify_set_params(c->ctx, &p), "fsql_diversify_set_params");
        }
        fsql_mu_unlock(&c->mu);
        if (bad) return;
        res[i] = true;
    }
}

static void detect_collapse_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    FsqlConn *c = div_conn(info, "fractal_detect_collapse");
    if (!c) return;
    fsql_mu_lock(&c->mu);
    double dq = fsql_diversify_current_dq(c->ctx);
    fsql_mu_unlock(&c->mu);
    double *res = (double *)duckdb_vector_get_data(out);
    for (idx_t i = 0, n = duckdb_data_chunk_get_size(in); i < n; i++) res[i] = dq;
}

/* A NaN is rendered as null; the numbers use "%f" (six decimals), as the C++ build's std::to_string did. */
static void explain_result_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    FsqlConn *c = div_conn(info, "fractal_explain_result");
    if (!c) return;
    fsql_mu_lock(&c->mu);
    int enabled = c->diversify_enabled;
    double dq = fsql_diversify_current_dq(c->ctx);
    double overhead = fsql_diversify_overhead_p99_us(c->ctx);
    fsql_mu_unlock(&c->mu);
    char dqs[64], ovs[64], json[256];
    if (dq != dq) snprintf(dqs, sizeof dqs, "null"); else snprintf(dqs, sizeof dqs, "%f", dq);
    if (overhead != overhead) snprintf(ovs, sizeof ovs, "null"); else snprintf(ovs, sizeof ovs, "%f", overhead);
    snprintf(json, sizeof json, "{\"dq\":%s,\"diversify_enabled\":%s,\"overhead_p99_us\":%s}", dqs, enabled ? "true" : "false", ovs);
    for (idx_t i = 0, n = duckdb_data_chunk_get_size(in); i < n; i++) fsql_set_str(out, i, json, strlen(json));
}

static void feedback_report_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    FsqlConn *c = div_conn(info, "fractal_feedback_report");
    if (!c) return;
    idx_t n = duckdb_data_chunk_get_size(in);
    idx_t ncols = duckdb_data_chunk_get_column_count(in);
    bool *res = (bool *)duckdb_vector_get_data(out);
    const int64_t *hd = (const int64_t *)fsql_col_data(in, 0);
    const duckdb_string_t *kd = (const duckdb_string_t *)fsql_col_data(in, 1);
    const uint64_t *hv = fsql_col_validity(in, 0), *kv = fsql_col_validity(in, 1);
    const int32_t *dw = ncols >= 3 ? (const int32_t *)fsql_col_data(in, 2) : NULL;
    const uint64_t *dwv = ncols >= 3 ? fsql_col_validity(in, 2) : NULL;
    for (idx_t i = 0; i < n; i++) {
        if (!fsql_valid(hv, i) || !fsql_valid(kv, i)) { fsql_set_null(out, i); continue; }
        size_t kl; const char *ks = fsql_str_data(&kd[i], &kl);
        int32_t dwell_ms = (dw && fsql_valid(dwv, i)) ? dw[i] : 0;
        if (hd[i] < 0) { fsql_fn_error(info, "fractalsql: fractal_feedback_report: result_handle must be >= 0"); return; }
        fsql_engagement_kind_t kind;
        if (kl == 5 && !memcmp(ks, "dwell", 5)) kind = FSQL_ENGAGE_DWELL;
        else if (kl == 8 && !memcmp(ks, "positive", 8)) kind = FSQL_ENGAGE_POSITIVE;
        else if (kl == 8 && !memcmp(ks, "negative", 8)) kind = FSQL_ENGAGE_NEGATIVE;
        else {
            fsql_ledger_fail(info, "fractal_feedback_report", "kind must be one of 'dwell', 'positive', 'negative' (got '%.*s')", (int)kl, ks);
            return;
        }
        fsql_mu_lock(&c->mu);
        int bad = div_rc(info, c, "fractal_feedback_report",
                         fsql_feedback_report(c->ctx, (uint64_t)hd[i], kind, (uint32_t)dwell_ms), "fsql_feedback_report");
        fsql_mu_unlock(&c->mu);
        if (bad) return;
        res[i] = true;
    }
}

static void isolate_background_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    FsqlConn *c = div_conn(info, "fractal_isolate_background");
    if (!c) return;
    idx_t n = duckdb_data_chunk_get_size(in);
    bool *res = (bool *)duckdb_vector_get_data(out);
    const int64_t *hd = (const int64_t *)fsql_col_data(in, 0);
    const uint64_t *hv = fsql_col_validity(in, 0);
    for (idx_t i = 0; i < n; i++) {
        if (!fsql_valid(hv, i)) { fsql_set_null(out, i); continue; }
        if (hd[i] < 0) { fsql_fn_error(info, "fractalsql: fractal_isolate_background: result_handle must be >= 0"); return; }
        fsql_mu_lock(&c->mu);
        int bad = div_rc(info, c, "fractal_isolate_background",
                         fsql_feedback_report(c->ctx, (uint64_t)hd[i], FSQL_ENGAGE_NEGATIVE, 0), "fsql_feedback_report");
        fsql_mu_unlock(&c->mu);
        if (bad) return;
        res[i] = true;
    }
}

/* ------------------------------------------------------------------ */
/* Enterprise multimodal portfolio search (table functions)             */
/*                                                                      */
/*   fractal_optimize_portfolio_multimodal(mu DOUBLE[], cov DOUBLE[],   */
/*       k INTEGER, n_restarts := 8, overlap_threshold := 0.15,         */
/*       quality_frac := 0.90, seed := 0, use_obl := false,             */
/*       diffusion_mode := 'gaussian') -> TABLE(sharpe, weights)        */
/*   fractal_optimize_portfolio_multimodal_pareto(mu, cov, k,           */
/*       n_restarts := 8, max_front := 8, seed := 0, use_obl,           */
/*       diffusion_mode) -> TABLE(return, risk, sharpe, weights)        */
/*                                                                      */
/* Both are enterprise-gated: they resolve their entry points through   */
/* the enterprise loader and fail when the library is not loaded. The   */
/* multimodal core exposes an extended entry point carrying the OBL /   */
/* Levy-flight knobs and a plain one without them; a library may export */
/* either or both, so the call site picks the extended one when present,*/
/* the plain one for a default-arguments call, and errors when the      */
/* caller asked for knobs only the extended one can honour.             */
/* ------------------------------------------------------------------ */

typedef struct {
    size_t   n, n_assets;
    double  *ret, *risk, *sharpe;      /* per candidate (ret/risk NULL for multimodal) */
    double  *weights;                  /* n * n_assets, row-major */
} mm_bind;

static void mm_bind_free(void *p) {
    mm_bind *b = (mm_bind *)p;
    if (!b) return;
    free(b->ret); free(b->risk); free(b->sharpe); free(b->weights); free(b);
}

static int64_t named_i64(duckdb_bind_info info, const char *name, int64_t dflt) {
    duckdb_value v = fsql_bind_named(info, name);
    if (!v) return dflt;
    int64_t r = duckdb_get_int64(v);
    duckdb_destroy_value(&v);
    return r;
}
static double named_f64(duckdb_bind_info info, const char *name, double dflt) {
    duckdb_value v = fsql_bind_named(info, name);
    if (!v) return dflt;
    double r = duckdb_get_double(v);
    duckdb_destroy_value(&v);
    return r;
}
static bool named_bool(duckdb_bind_info info, const char *name, bool dflt) {
    duckdb_value v = fsql_bind_named(info, name);
    if (!v) return dflt;
    bool r = duckdb_get_bool(v);
    duckdb_destroy_value(&v);
    return r;
}
/* Returns 0 / 1 / -1 (invalid, message set) for 'gaussian' / 'levy'. */
static int named_diffusion(duckdb_bind_info info, int *out) {
    duckdb_value v = fsql_bind_named(info, "diffusion_mode");
    *out = 0;
    if (!v) return 0;
    char *s = duckdb_get_varchar(v);
    duckdb_destroy_value(&v);
    int rc = 0;
    if (s && !strcmp(s, "gaussian")) *out = 0;
    else if (s && !strcmp(s, "levy")) *out = 1;
    else {
        char m[256];
        snprintf(m, sizeof m, "fractalsql: diffusion_mode must be 'gaussian' or 'levy' (got '%s')", s ? s : "");
        duckdb_bind_set_error(info, m);
        rc = -1;
    }
    if (s) duckdb_free(s);
    return rc;
}

/* A bind-time list-of-doubles parameter the way the portfolio functions read it: a NULL list is an EMPTY list
 * (the caller then reports "must not be NULL or empty"), and a NULL element is an error. */
static int bind_list_doubles(duckdb_bind_info info, idx_t idx, fsql_vecd *out) {
    duckdb_value v = duckdb_bind_get_parameter(info, idx);
    if (duckdb_is_null_value(v)) { duckdb_destroy_value(&v); return 0; }
    idx_t cnt = duckdb_get_list_size(v);
    for (idx_t k = 0; k < cnt; k++) {
        duckdb_value c = duckdb_get_list_child(v, k);
        if (duckdb_is_null_value(c)) {
            duckdb_destroy_value(&c); duckdb_destroy_value(&v);
            duckdb_bind_set_error(info, "fractalsql: list argument contains a NULL element");
            return -1;
        }
        fsql_vecd_push(out, duckdb_get_double(c));
        duckdb_destroy_value(&c);
    }
    duckdb_destroy_value(&v);
    if (!fsql_vecd_ok(out)) { duckdb_bind_set_error(info, "fractalsql: out of memory"); return -1; }
    return 0;
}

/* The common bind-time validation of mu / cov / k. 0 ok, -1 failed (message set). */
static int mm_validate(duckdb_bind_info info, fsql_vecd *mu, fsql_vecd *cov, int64_t *k) {
    if (bind_list_doubles(info, 0, mu) || bind_list_doubles(info, 1, cov)) return -1;
    if (mu->len == 0) { duckdb_bind_set_error(info, "fractalsql: mu must not be NULL or empty"); return -1; }
    duckdb_value kv = duckdb_bind_get_parameter(info, 2);
    if (duckdb_is_null_value(kv)) { duckdb_destroy_value(&kv); duckdb_bind_set_error(info, "fractalsql: k must not be NULL"); return -1; }
    *k = duckdb_get_int64(kv);
    duckdb_destroy_value(&kv);
    size_t na = mu->len;
    char m[256];
    if (cov->len != na * na) {
        snprintf(m, sizeof m, "fractalsql: cov length (%zu) must be n_assets^2 (n_assets=%zu, expected %zu)", cov->len, na, na * na);
        duckdb_bind_set_error(info, m); return -1;
    }
    if (*k <= 0 || (size_t)*k > na) {
        snprintf(m, sizeof m, "fractalsql: k must satisfy 1 <= k <= n_assets (%zu)", na);
        duckdb_bind_set_error(info, m); return -1;
    }
    return 0;
}

static void mm_add_cols(duckdb_bind_info info, const char *const *dnames, int nd) {
    duckdb_logical_type d = duckdb_create_logical_type(DUCKDB_TYPE_DOUBLE);
    for (int i = 0; i < nd; i++) duckdb_bind_add_result_column(info, dnames[i], d);
    duckdb_destroy_logical_type(&d);
    duckdb_logical_type inner = duckdb_create_logical_type(DUCKDB_TYPE_DOUBLE);
    duckdb_logical_type lst = duckdb_create_list_type(inner);
    duckdb_bind_add_result_column(info, "weights", lst);
    duckdb_destroy_logical_type(&inner); duckdb_destroy_logical_type(&lst);
}

static void multimodal_bind_fn(duckdb_bind_info info) {
    fsql_instance *dummy = fsql_bind_instance(info); (void)dummy;
    const FsqlEnterpriseApi *ent = fsql_enterprise_ensure();
    if (!ent) {
        char m[600]; fsql_enterprise_not_loaded_msg("fractal_optimize_portfolio_multimodal", m, sizeof m);
        duckdb_bind_set_error(info, m); return;
    }
    fsql_vecd mu, cov; fsql_vecd_init(&mu); fsql_vecd_init(&cov);
    mm_bind *b = NULL; double *w = NULL, *sh = NULL;
    int64_t k;
    if (mm_validate(info, &mu, &cov, &k)) goto done;
    int64_t n_restarts = named_i64(info, "n_restarts", 8);
    double overlap = named_f64(info, "overlap_threshold", 0.15), quality = named_f64(info, "quality_frac", 0.90);
    int64_t seed = named_i64(info, "seed", 0);
    bool use_obl = named_bool(info, "use_obl", false);
    int dmode;
    if (named_diffusion(info, &dmode)) goto done;
    if (n_restarts <= 0 || n_restarts > 64) { duckdb_bind_set_error(info, "fractalsql: n_restarts must satisfy 1 <= n_restarts <= 64"); goto done; }
    size_t na = mu.len;
    w = (double *)calloc((size_t)n_restarts * na, sizeof(double));
    sh = (double *)calloc((size_t)n_restarts, sizeof(double));
    if (!w || !sh) { duckdb_bind_set_error(info, "fractalsql: out of memory"); goto done; }
    int n_found = 0, rc = FSQL_OK;
    if (ent->optimize_portfolio_multimodal_ex) {
        rc = ent->optimize_portfolio_multimodal_ex(mu.p, cov.p, na, (size_t)k, (int)n_restarts, overlap, quality, (uint64_t)seed,
                                                   use_obl ? 1 : 0, dmode, w, sh, &n_found);
    } else if (use_obl || dmode != 0) {
        duckdb_bind_set_error(info, "fractalsql: use_obl/diffusion_mode not available in this enterprise library (this enterprise core "
                                    "build predates portfolio OBL/Levy-flight support -- upgrade enterprise_lib, or omit use_obl/diffusion_mode)");
        goto done;
    } else if (ent->optimize_portfolio_multimodal) {
        rc = ent->optimize_portfolio_multimodal(mu.p, cov.p, na, (size_t)k, (int)n_restarts, overlap, quality, (uint64_t)seed, w, sh, &n_found);
    } else {
        duckdb_bind_set_error(info, "fractalsql: fractal_optimize_portfolio_multimodal not available in this enterprise library "
                                    "(this enterprise core build predates portfolio multimodal support -- upgrade enterprise_lib)");
        goto done;
    }
    if (rc != FSQL_OK) {
        char m[128]; snprintf(m, sizeof m, "fractalsql: fractal_optimize_portfolio_multimodal rc=%d", rc);
        duckdb_bind_set_error(info, m); goto done;
    }
    if (n_found > n_restarts) n_found = (int)n_restarts;
    if (n_found < 0) n_found = 0;
    b = (mm_bind *)calloc(1, sizeof *b);
    if (!b) { duckdb_bind_set_error(info, "fractalsql: out of memory"); goto done; }
    b->n = (size_t)n_found; b->n_assets = na; b->sharpe = sh; b->weights = w;
    sh = w = NULL;
    { static const char *const dn[] = { "sharpe" }; mm_add_cols(info, dn, 1); }
    duckdb_bind_set_bind_data(info, b, mm_bind_free);
    b = NULL;
done:
    fsql_vecd_free(&mu); fsql_vecd_free(&cov); free(w); free(sh); mm_bind_free(b);
}

static void pareto_bind_fn(duckdb_bind_info info) {
    const FsqlEnterpriseApi *ent = fsql_enterprise_ensure();
    if (!ent) {
        char m[600]; fsql_enterprise_not_loaded_msg("fractal_optimize_portfolio_multimodal_pareto", m, sizeof m);
        duckdb_bind_set_error(info, m); return;
    }
    fsql_vecd mu, cov; fsql_vecd_init(&mu); fsql_vecd_init(&cov);
    mm_bind *b = NULL; double *w = NULL, *rt = NULL, *rk = NULL;
    int64_t k;
    if (mm_validate(info, &mu, &cov, &k)) goto done;
    int64_t n_restarts = named_i64(info, "n_restarts", 8), max_front = named_i64(info, "max_front", 8);
    int64_t seed = named_i64(info, "seed", 0);
    bool use_obl = named_bool(info, "use_obl", false);
    int dmode;
    if (named_diffusion(info, &dmode)) goto done;
    if (n_restarts <= 0 || n_restarts > 64) { duckdb_bind_set_error(info, "fractalsql: n_restarts must satisfy 1 <= n_restarts <= 64"); goto done; }
    if (max_front <= 0 || max_front > n_restarts) {
        char m[160]; snprintf(m, sizeof m, "fractalsql: max_front must satisfy 1 <= max_front <= n_restarts (%lld)", (long long)n_restarts);
        duckdb_bind_set_error(info, m); goto done;
    }
    size_t na = mu.len;
    w = (double *)calloc((size_t)max_front * na, sizeof(double));
    rt = (double *)calloc((size_t)max_front, sizeof(double));
    rk = (double *)calloc((size_t)max_front, sizeof(double));
    if (!w || !rt || !rk) { duckdb_bind_set_error(info, "fractalsql: out of memory"); goto done; }
    int n_found = 0;
    int rc = ent->optimize_portfolio_multimodal_pareto(mu.p, cov.p, na, (size_t)k, (int)n_restarts, (int)max_front, (uint64_t)seed,
                                                       use_obl ? 1 : 0, dmode, w, rt, rk, &n_found);
    if (rc != FSQL_OK) {
        char m[128]; snprintf(m, sizeof m, "fractalsql: fractal_optimize_portfolio_multimodal_pareto rc=%d", rc);
        duckdb_bind_set_error(info, m); goto done;
    }
    if (n_found > max_front) n_found = (int)max_front;
    if (n_found < 0) n_found = 0;
    b = (mm_bind *)calloc(1, sizeof *b);
    if (!b) { duckdb_bind_set_error(info, "fractalsql: out of memory"); goto done; }
    b->n = (size_t)n_found; b->n_assets = na; b->weights = w; b->ret = rt; b->risk = rk;
    w = rt = rk = NULL;
    { static const char *const dn[] = { "return", "risk", "sharpe" }; mm_add_cols(info, dn, 3); }
    duckdb_bind_set_bind_data(info, b, mm_bind_free);
    b = NULL;
done:
    fsql_vecd_free(&mu); fsql_vecd_free(&cov); free(w); free(rt); free(rk); mm_bind_free(b);
}

/* Streams the candidates out; `pareto` adds the return/risk/sharpe columns instead of just sharpe. */
static void mm_scan(duckdb_function_info info, duckdb_data_chunk out, bool pareto) {
    mm_bind *b = (mm_bind *)duckdb_function_get_bind_data(info);
    stream_state *st = (stream_state *)duckdb_function_get_init_data(info);
    idx_t cap = duckdb_vector_size();
    idx_t k = 0;
    int wcol = pareto ? 3 : 1;
    double *c0 = (double *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(out, 0));
    double *c1 = pareto ? (double *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(out, 1)) : NULL;
    double *c2 = pareto ? (double *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(out, 2)) : NULL;
    fsql_list_out w;
    fsql_list_out_open(&w, duckdb_data_chunk_get_vector(out, wcol));
    while (st->offset + k < b->n && k < cap) {
        size_t c = (size_t)(st->offset + k);
        if (pareto) {
            c0[k] = b->ret[c]; c1[k] = b->risk[c];
            c2[k] = b->risk[c] != 0.0 ? b->ret[c] / b->risk[c] : 0.0;
        } else c0[k] = b->sharpe[c];
        if (!fsql_list_out_put(&w, k, b->weights + c * b->n_assets, b->n_assets)) {
            duckdb_function_set_error(info, "fractalsql: out of memory");
            break;
        }
        k++;
    }
    fsql_list_out_close(&w);
    st->offset += k;
    duckdb_data_chunk_set_size(out, k);
}
static void multimodal_fn(duckdb_function_info info, duckdb_data_chunk out) { mm_scan(info, out, false); }
static void pareto_fn(duckdb_function_info info, duckdb_data_chunk out) { mm_scan(info, out, true); }

/* ------------------------------------------------------------------ */
/* Registration                                                         */
/* ------------------------------------------------------------------ */

#define LD  FSQL_T_LIST_DOUBLE
#define I32 FSQL_T_INTEGER
#define D   FSQL_T_DOUBLE
static const char *const kVascularFields[]   = { "mean_tortuosity", "branch_density", "fractal_dimension", NULL };
static const char *const kCorticalFields[]   = { "mesh_area", "hull_area", "gyrification_index", NULL };
static const char *const kNerveFields[]      = { "fiber_length_density", "branch_density", "fractal_dimension", NULL };
static const char *const kComplexityFields[] = { "dimension", "lacunarity", NULL };

static const char *const kPortfolioFields[] = { "sharpe", "weights", NULL };
static const char *const kSubsetFields[]    = { "score", "weights", NULL };

static const fsql_scalar_def kSovereignScalars[] = {
    { "fractal_dimension_dfa",      1, { LD },      D,                       dimension_dfa_fn,      NULL, 0 },
    { "fractal_dimension_drift",    2, { LD, I32 }, FSQL_T_STRUCT_DRIFT,     dimension_drift_fn,    NULL, 0 },
    { "fractal_dimension_boxcount", 2, { LD, I32 }, D,                       dimension_boxcount_fn, NULL, 0 },

    { "fractal_change_point_detect", 2, { LD, I32 },           FSQL_T_LIST_BIGINT, change_point_detect_fn, NULL, 0 },
    { "fractal_change_point_detect", 3, { LD, I32, D },        FSQL_T_LIST_BIGINT, change_point_detect_fn, NULL, 0 },
    { "fractal_change_point_detect", 4, { LD, I32, D, I32 },   FSQL_T_LIST_BIGINT, change_point_detect_fn, NULL, 0 },

    { "fractal_spectrogram_entropy", 1, { LD },                LD, spectrogram_entropy_fn, NULL, 0 },
    { "fractal_spectrogram_entropy", 2, { LD, I32 },           LD, spectrogram_entropy_fn, NULL, 0 },
    { "fractal_spectrogram_entropy", 3, { LD, I32, I32 },      LD, spectrogram_entropy_fn, NULL, 0 },
    { "fractal_spectrogram_entropy", 4, { LD, I32, I32, I32 }, LD, spectrogram_entropy_fn, NULL, 0 },

    { "fractal_tda_persistence_diagram", 4, { LD, I32, I32, D },          FSQL_T_STRUCT_TDA, tda_persistence_diagram_fn, NULL, 0 },
    { "fractal_tda_persistence_diagram", 5, { LD, I32, I32, D, I32 },     FSQL_T_STRUCT_TDA, tda_persistence_diagram_fn, NULL, 0 },

    { "fractal_state_fingerprint", 1, { LD },        FSQL_T_BLOB, state_fingerprint_fn, NULL, 0 },
    { "fractal_state_fingerprint", 2, { LD, I32 },   FSQL_T_BLOB, state_fingerprint_fn, NULL, 0 },
    { "fractal_state_fingerprint", 3, { LD, I32, D }, FSQL_T_BLOB, state_fingerprint_fn, NULL, 0 },

    { "fractal_vascular_network",        3, { LD, FSQL_T_LIST_BIGINT, LD },  FSQL_T_STRUCT_DOUBLES, vascular_network_fn,        NULL, 0, kVascularFields },
    { "fractal_cortical_folding",        2, { LD, FSQL_T_LIST_BIGINT },      FSQL_T_STRUCT_DOUBLES, cortical_folding_fn,        NULL, 0, kCorticalFields },
    { "fractal_nerve_plexus_metric",     3, { LD, I32, FSQL_T_LIST_BIGINT }, FSQL_T_STRUCT_DOUBLES, nerve_plexus_metric_fn,     NULL, 0, kNerveFields },
    { "fractal_morphological_complexity",2, { LD, I32 },                     FSQL_T_STRUCT_DOUBLES, morphological_complexity_fn, NULL, 0, kComplexityFields },

    { "fractal_optimize_portfolio", 3, { LD, LD, I32 },                                   FSQL_T_STRUCT_DOUBLE_LIST, optimize_portfolio_fn, NULL, 0, kPortfolioFields },
    { "fractal_optimize_portfolio", 4, { LD, LD, I32, FSQL_T_BIGINT },                    FSQL_T_STRUCT_DOUBLE_LIST, optimize_portfolio_fn, NULL, 0, kPortfolioFields },
    { "fractal_optimize_portfolio", 5, { LD, LD, I32, FSQL_T_BIGINT, FSQL_T_BOOLEAN },    FSQL_T_STRUCT_DOUBLE_LIST, optimize_portfolio_fn, NULL, 0, kPortfolioFields },
    { "fractal_optimize_portfolio", 6, { LD, LD, I32, FSQL_T_BIGINT, FSQL_T_BOOLEAN, FSQL_T_VARCHAR }, FSQL_T_STRUCT_DOUBLE_LIST, optimize_portfolio_fn, NULL, 0, kPortfolioFields },

    { "fractal_optimize_subset", 3, { LD, LD, I32 },                      FSQL_T_STRUCT_DOUBLE_LIST, optimize_subset_fn, NULL, FSQL_FN_SPECIAL_NULL, kSubsetFields },
    { "fractal_optimize_subset", 4, { LD, LD, I32, LD },                  FSQL_T_STRUCT_DOUBLE_LIST, optimize_subset_fn, NULL, FSQL_FN_SPECIAL_NULL, kSubsetFields },
    { "fractal_optimize_subset", 5, { LD, LD, I32, LD, D },               FSQL_T_STRUCT_DOUBLE_LIST, optimize_subset_fn, NULL, FSQL_FN_SPECIAL_NULL, kSubsetFields },
    { "fractal_optimize_subset", 6, { LD, LD, I32, LD, D, FSQL_T_BIGINT }, FSQL_T_STRUCT_DOUBLE_LIST, optimize_subset_fn, NULL, FSQL_FN_SPECIAL_NULL, kSubsetFields },

    /* diversify + feedback: per-connection, side-effecting */
    { "fractal_diversify_enable",  0, { 0 }, FSQL_T_BOOLEAN, diversify_enable_fn,  fsql_bind_capture_conn, FSQL_FN_VOLATILE },
    { "fractal_diversify_disable", 0, { 0 }, FSQL_T_BOOLEAN, diversify_disable_fn, fsql_bind_capture_conn, FSQL_FN_VOLATILE },
    { "fractal_diversify_set_params", 0, { 0 },                                    FSQL_T_BOOLEAN, diversify_set_params_fn, fsql_bind_capture_conn, FSQL_FN_VOLATILE | FSQL_FN_SPECIAL_NULL },
    { "fractal_diversify_set_params", 1, { I32 },                                  FSQL_T_BOOLEAN, diversify_set_params_fn, fsql_bind_capture_conn, FSQL_FN_VOLATILE | FSQL_FN_SPECIAL_NULL },
    { "fractal_diversify_set_params", 2, { I32, D },                               FSQL_T_BOOLEAN, diversify_set_params_fn, fsql_bind_capture_conn, FSQL_FN_VOLATILE | FSQL_FN_SPECIAL_NULL },
    { "fractal_diversify_set_params", 3, { I32, D, D },                            FSQL_T_BOOLEAN, diversify_set_params_fn, fsql_bind_capture_conn, FSQL_FN_VOLATILE | FSQL_FN_SPECIAL_NULL },
    { "fractal_diversify_set_params", 4, { I32, D, D, D },                         FSQL_T_BOOLEAN, diversify_set_params_fn, fsql_bind_capture_conn, FSQL_FN_VOLATILE | FSQL_FN_SPECIAL_NULL },
    { "fractal_diversify_set_params", 5, { I32, D, D, D, I32 },                    FSQL_T_BOOLEAN, diversify_set_params_fn, fsql_bind_capture_conn, FSQL_FN_VOLATILE | FSQL_FN_SPECIAL_NULL },
    { "fractal_diversify_set_params", 6, { I32, D, D, D, I32, I32 },               FSQL_T_BOOLEAN, diversify_set_params_fn, fsql_bind_capture_conn, FSQL_FN_VOLATILE | FSQL_FN_SPECIAL_NULL },
    { "fractal_detect_collapse",   0, { 0 }, D,             detect_collapse_fn, fsql_bind_capture_conn, 0 },
    { "fractal_explain_result",    0, { 0 }, FSQL_T_VARCHAR, explain_result_fn, fsql_bind_capture_conn, 0 },
    { "fractal_feedback_report",   2, { FSQL_T_BIGINT, FSQL_T_VARCHAR },      FSQL_T_BOOLEAN, feedback_report_fn, fsql_bind_capture_conn, FSQL_FN_VOLATILE },
    { "fractal_feedback_report",   3, { FSQL_T_BIGINT, FSQL_T_VARCHAR, I32 }, FSQL_T_BOOLEAN, feedback_report_fn, fsql_bind_capture_conn, FSQL_FN_VOLATILE },
    { "fractal_isolate_background",1, { FSQL_T_BIGINT },                      FSQL_T_BOOLEAN, isolate_background_fn, fsql_bind_capture_conn, FSQL_FN_VOLATILE },
};

static const fsql_table_def kSovereignTables[] = {
    { "fractal_periodogram",  1, { LD },      periodogram_bind_fn,  stream_init, periodogram_fn },
    { "fractal_periodogram",  2, { LD, I32 }, periodogram_bind_fn,  stream_init, periodogram_fn },
    { "fractal_cycle_detect", 1, { FSQL_T_LIST_BLOB },      cycle_detect_bind_fn, stream_init, cycle_detect_fn },
    { "fractal_cycle_detect", 2, { FSQL_T_LIST_BLOB, I32 }, cycle_detect_bind_fn, stream_init, cycle_detect_fn },

    { "fractal_optimize_portfolio_multimodal", 3, { LD, LD, I32 }, multimodal_bind_fn, stream_init, multimodal_fn,
      { { "n_restarts", I32 }, { "overlap_threshold", D }, { "quality_frac", D }, { "seed", FSQL_T_BIGINT },
        { "use_obl", FSQL_T_BOOLEAN }, { "diffusion_mode", FSQL_T_VARCHAR } } },
    { "fractal_optimize_portfolio_multimodal_pareto", 3, { LD, LD, I32 }, pareto_bind_fn, stream_init, pareto_fn,
      { { "n_restarts", I32 }, { "max_front", I32 }, { "seed", FSQL_T_BIGINT },
        { "use_obl", FSQL_T_BOOLEAN }, { "diffusion_mode", FSQL_T_VARCHAR } } },
};
#undef LD
#undef I32
#undef D

bool fsql_sovereign_register(duckdb_connection con, const char **err) {
    return fsql_register_scalars(con, kSovereignScalars, (int)(sizeof kSovereignScalars / sizeof kSovereignScalars[0]), err) &&
           fsql_register_tables(con, kSovereignTables, (int)(sizeof kSovereignTables / sizeof kSovereignTables[0]), err);
}
