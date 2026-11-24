/* src/fsql_precision.h
 *
 * ONE implementation of dot / L2 / norm / cosine for every SQL-visible distance in the extension
 * (precision plan R2, R3, R5). All sums are accumulated in double, in fixed sequential order, with
 * no contraction and no vectorisation (the Makefile builds the files that include this header with
 * -ffp-contract=off -fno-tree-vectorize). float inputs are widened exactly (a float*float product
 * is exact in a double), so the float and double entry points return bit-identical results for the
 * same values. SQL-visible results are returned as double (the host API already widens), so no
 * intermediate rounding to float happens; the core's own float API (fsql_vector_*) rounds once to
 * float32 and is used where a float result is the contract.
 *
 * The host's own second cosine (fractalsql_ext.c's cosine_distance) is routed through here too, so
 * there is exactly ONE cosine in this repository (R5).
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
#ifndef FSQL_PRECISION_H
#define FSQL_PRECISION_H

#include <math.h>
#include <stddef.h>

static inline void
fsqlp_parts_f(const float *a, const float *b, size_t n, double *dot, double *na, double *nb)
{
    double d = 0.0, x = 0.0, y = 0.0;
    for (size_t i = 0; i < n; i++) {
        double p = (double)a[i], q = (double)b[i];
        d += p * q; x += p * p; y += q * q;
    }
    *dot = d; *na = x; *nb = y;
}

static inline void
fsqlp_parts_d(const double *a, const double *b, size_t n, double *dot, double *na, double *nb)
{
    double d = 0.0, x = 0.0, y = 0.0;
    for (size_t i = 0; i < n; i++) {
        double p = a[i], q = b[i];
        d += p * q; x += p * p; y += q * q;
    }
    *dot = d; *na = x; *nb = y;
}

/* distance: 1 - cos, 1.0 when either vector is all-zero (the convention the Sniper cosine always had) */
static inline double
fsqlp_cos_dist_from_parts(double dot, double na, double nb)
{
    if (na == 0.0 || nb == 0.0) return 1.0;
    return 1.0 - dot / (sqrt(na) * sqrt(nb));
}

static inline double
fsqlp_cos_sim_from_parts(double dot, double na, double nb)
{
    if (na == 0.0 || nb == 0.0) return 0.0;
    return dot / (sqrt(na) * sqrt(nb));
}

static inline double
fsqlp_cosine_distance_f(const float *a, const float *b, size_t n)
{ double d, x, y; fsqlp_parts_f(a, b, n, &d, &x, &y); return fsqlp_cos_dist_from_parts(d, x, y); }

static inline double
fsqlp_cosine_distance_d(const double *a, const double *b, size_t n)
{ double d, x, y; fsqlp_parts_d(a, b, n, &d, &x, &y); return fsqlp_cos_dist_from_parts(d, x, y); }

static inline double
fsqlp_cosine_similarity_f(const float *a, const float *b, size_t n)
{ double d, x, y; fsqlp_parts_f(a, b, n, &d, &x, &y); return fsqlp_cos_sim_from_parts(d, x, y); }

static inline double
fsqlp_cosine_similarity_d(const double *a, const double *b, size_t n)
{ double d, x, y; fsqlp_parts_d(a, b, n, &d, &x, &y); return fsqlp_cos_sim_from_parts(d, x, y); }

static inline double
fsqlp_dot_f(const float *a, const float *b, size_t n)
{ double d, x, y; fsqlp_parts_f(a, b, n, &d, &x, &y); return d; }

static inline double
fsqlp_dot_d(const double *a, const double *b, size_t n)
{ double d, x, y; fsqlp_parts_d(a, b, n, &d, &x, &y); return d; }

static inline double
fsqlp_l2_sq_f(const float *a, const float *b, size_t n)
{
    double s = 0.0;
    for (size_t i = 0; i < n; i++) { double t = (double)a[i] - (double)b[i]; s += t * t; }
    return s;
}

static inline double
fsqlp_l2_sq_d(const double *a, const double *b, size_t n)
{
    double s = 0.0;
    for (size_t i = 0; i < n; i++) { double t = a[i] - b[i]; s += t * t; }
    return s;
}

static inline double
fsqlp_l2_f(const float *a, const float *b, size_t n) { return sqrt(fsqlp_l2_sq_f(a, b, n)); }

static inline double
fsqlp_l2_d(const double *a, const double *b, size_t n) { return sqrt(fsqlp_l2_sq_d(a, b, n)); }

static inline double
fsqlp_norm_f(const float *a, size_t n)
{ double s = 0.0; for (size_t i = 0; i < n; i++) { double p = (double)a[i]; s += p * p; } return sqrt(s); }

static inline double
fsqlp_norm_d(const double *a, size_t n)
{ double s = 0.0; for (size_t i = 0; i < n; i++) { double p = a[i]; s += p * p; } return sqrt(s); }

/* The Lp distance, accumulated in double like everything else (the core's fsql_vector_lp_distance
 * is the float32 contract and is NOT used here). p must be > 0. */
static inline double
fsqlp_lp_distance_f(const float *a, const float *b, size_t n, double p)
{
    double s = 0.0;
    for (size_t i = 0; i < n; i++) { double t = (double)a[i] - (double)b[i]; s += pow(fabs(t), p); }
    return pow(s, 1.0 / p);
}

/* Normalise in double, then round once to float32: the vector is stored as float32, so the norm is
 * computed on the widened (exact) values and the result is the float32 rounding of that. */
static inline void
fsqlp_normalize_f(const float *a, size_t n, float *out)
{
    double nrm = fsqlp_norm_f(a, n);
    if (!(nrm > 0.0)) { for (size_t i = 0; i < n; i++) out[i] = 0.0f; return; }
    for (size_t i = 0; i < n; i++) out[i] = (float)((double)a[i] / nrm);
}

/* Elementwise scale: the product is computed in double and rounded once. */
static inline void
fsqlp_scale_f(const float *a, size_t n, double s, float *out)
{
    for (size_t i = 0; i < n; i++) out[i] = (float)((double)a[i] * s);
}

static inline void
fsqlp_add_f(const float *a, const float *b, size_t n, float *out)
{
    for (size_t i = 0; i < n; i++) out[i] = (float)((double)a[i] + (double)b[i]);
}

static inline void
fsqlp_sub_f(const float *a, const float *b, size_t n, float *out)
{
    for (size_t i = 0; i < n; i++) out[i] = (float)((double)a[i] - (double)b[i]);
}

#endif /* FSQL_PRECISION_H */
