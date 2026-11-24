/* test/mock_enterprise.c -- a stand-in for the licensed enterprise core, for tests only.
 *
 * It exports exactly the symbols fsql_enterprise.c resolves, with deterministic behaviour, so the
 * parity runner can drive the enterprise-gated functions (ledger actions, audit log/unpack, the
 * multimodal portfolio table functions) through the REAL loader, in both the C++ and the C extension.
 * Load it with FRACTALSQL_ENTERPRISE_LIB=<this .so> and FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 (it is not
 * signed). Never shipped.
 *
 * Variants (for the loader's optional-symbol branches): -DNO_EX omits the extended multimodal entry point,
 * -DNO_MM omits the plain one (-DNO_EX -DNO_MM omits both), -DNO_RETENTION omits fsql_ledger_set_retention /
 * fsql_ledger_get_retention (a core older than the retention modes). With them, the retention mode is observable: the
 * Shadow count reads 33 in exact mode and 3 in fade mode.
 *
 * Build: cc -shared -fPIC -std=c99 -Iinclude mock_enterprise.c -o mock_enterprise.so
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "fractalsql_sql.h"

static int g_retention;   /* 0 fade, 1 exact */
#ifndef NO_RETENTION
int fsql_ledger_set_retention(fsql_ctx *c, int mode) { (void)c; if (mode < 0 || mode > 1) return 1; g_retention = mode; return FSQL_OK; }
int fsql_ledger_get_retention(const fsql_ctx *c, int *out) { (void)c; *out = g_retention; return FSQL_OK; }
#endif

int fsql_ledger_flush(fsql_ctx *c)      { (void)c; return FSQL_OK; }
int fsql_ledger_load(fsql_ctx *c)       { (void)c; return FSQL_ESTORAGE_UNAVAILABLE; }  /* nothing stored yet */
int fsql_ledger_compact(fsql_ctx *c)    { (void)c; return FSQL_OK; }
int fsql_ledger_reset_soft(fsql_ctx *c) { (void)c; return FSQL_OK; }
int fsql_ledger_reset_hard(fsql_ctx *c) { (void)c; return FSQL_OK; }
int fsql_ledger_truth_count(const fsql_ctx *c, size_t *n)  { (void)c; *n = 7; return FSQL_OK; }
int fsql_ledger_shadow_count(const fsql_ctx *c, size_t *n) { (void)c; *n = g_retention ? 33 : 3; return FSQL_OK; }

/* Writes "{"unpacked":<len>,"pad":"xxxx..."}"; wants 6000 bytes of room so the caller's growth path
 * (4096 -> reported size) is exercised. An input starting with 0xFF fails; one starting with 0xFE reports a
 * length larger than the buffer it was given. */
int fsql_audit_unpack(const void *blob, size_t len, char *json, size_t *cap) {
    const unsigned char *b = (const unsigned char *)blob;
    if (len > 0 && b[0] == 0xFF) return -1;
    if (len > 0 && b[0] == 0xFE) { *cap = *cap + 1000; return FSQL_OK; }
    if (*cap < 6000) { *cap = 6000; return FSQL_ETRUNCATED; }
    int n = snprintf(json, *cap, "{\"unpacked\":%zu,\"pad\":\"", len);
    for (int i = 0; i < 5900; i++) json[n++] = 'x';
    json[n++] = '"'; json[n++] = '}';
    *cap = (size_t)n;
    return FSQL_OK;
}

/* The multimodal entry points: n_found = min(n_restarts, 3) candidates; candidate r puts weight 1/k on assets
 * r .. r+k-1 (mod n), with sharpe 2.0 - 0.5*r. */
static int fill(size_t n_assets, size_t k, int n_restarts, double *w, double *sharpes, int *found) {
    int f = n_restarts < 3 ? n_restarts : 3;
    if (f < 0) f = 0;
    for (int r = 0; r < f; r++) {
        for (size_t a = 0; a < n_assets; a++) w[(size_t)r * n_assets + a] = 0.0;
        for (size_t j = 0; j < k; j++) w[(size_t)r * n_assets + ((size_t)r + j) % n_assets] = 1.0 / (double)k;
        sharpes[r] = 2.0 - 0.5 * r;
    }
    *found = f;
    return FSQL_OK;
}

#ifndef NO_MM
int fsql_optimize_portfolio_multimodal(const double *mu, const double *cov, size_t n_assets, size_t k, int n_restarts,
                                       double overlap, double quality, uint64_t seed,
                                       double *out_weights, double *out_sharpes, int *out_n_found) {
    (void)mu; (void)cov; (void)overlap; (void)quality; (void)seed;
    return fill(n_assets, k, n_restarts, out_weights, out_sharpes, out_n_found);
}
#endif

#ifndef NO_EX
int fsql_optimize_portfolio_multimodal_ex(const double *mu, const double *cov, size_t n_assets, size_t k, int n_restarts,
                                          double overlap, double quality, uint64_t seed, int use_obl, int diffusion_mode,
                                          double *out_weights, double *out_sharpes, int *out_n_found) {
    (void)mu; (void)cov; (void)overlap; (void)quality; (void)seed; (void)use_obl; (void)diffusion_mode;
    return fill(n_assets, k, n_restarts, out_weights, out_sharpes, out_n_found);
}
#endif

int fsql_optimize_portfolio_multimodal_pareto(const double *mu, const double *cov, size_t n_assets, size_t k, int n_restarts,
                                              int max_front, uint64_t seed, int use_obl, int diffusion_mode,
                                              double *out_weights, double *out_returns, double *out_risks, int *out_n_found) {
    (void)mu; (void)cov; (void)seed; (void)use_obl; (void)diffusion_mode;
    int f = n_restarts < max_front ? n_restarts : max_front;
    if (f > 3) f = 3;
    if (f < 0) f = 0;
    double sharpes[3];
    int found;
    fill(n_assets, k, f, out_weights, sharpes, &found);
    for (int r = 0; r < f; r++) { out_returns[r] = 0.10 + 0.01 * r; out_risks[r] = 0.05 + 0.02 * r; }
    *out_n_found = f;
    return FSQL_OK;
}
