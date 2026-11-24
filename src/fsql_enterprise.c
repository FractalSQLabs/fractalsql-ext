/* src/fsql_enterprise.c
 *
 * The enterprise-tier gate, and the authenticity gate for the reasoning plugin.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * The community sovereign archive does not export the ledger/audit or the
 * multimodal-portfolio symbols. When FRACTALSQL_ENTERPRISE_LIB names a compiled
 * enterprise core library, those entry points are resolved from it at first use.
 *
 * Trust rule (both for the enterprise library and the reasoning plugin, which are
 * native shared objects mapped into this process -- loading one is arbitrary code
 * execution):
 *   a detached Ed25519 signature, <path>.sig (exactly 64 raw bytes) over the file's
 *   exact bytes, must verify against the FractalSQLabs release-signing key below.
 *   The check runs BEFORE the library is mapped (nothing to clean up on refusal) and
 *   again AFTER the load to narrow the swap-between-check-and-load window. A
 *   present-but-wrong .sig is always fatal; a missing .sig (or an unreadable file) is
 *   fatal unless the process environment turns the requirement off
 *   (FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0 for the enterprise library;
 *   FSQL_REASONING_REQUIRE_SIGNATURE=0 for the plugin).
 *
 * One attempt per process: a failed load leaves the tier permanently unavailable for
 * the life of the process (the configuration is process-static, so a retry would fail
 * identically).
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#  include <windows.h>
#else
#  include <dlfcn.h>
#endif

#include "fsql_duckdb_internal.h"
#include "fsql_vendored_begin.h"
#include "fsql_ed25519.h"
#include "fsql_hmac.h"
#include "fsql_vendored_end.h"

/* The FractalSQLabs enterprise-library signing public key. */
static const unsigned char kSigningPubkey[32] = {
    0xd5, 0xf6, 0x08, 0xa5, 0x8b, 0x1e, 0xb7, 0xe5, 0x9a, 0xcb, 0x8f, 0xab,
    0x80, 0x35, 0x9d, 0x58, 0x3f, 0x4e, 0xd1, 0xd1, 0xa2, 0x9c, 0x33, 0x6b,
    0xcb, 0x4b, 0x43, 0xcf, 0xf1, 0x07, 0x7f, 0xcb
};

/* The FractalSQLabs reasoning-plugin signing public key. A plugin release is
 * signed with the matching private key; its detached <plugin>.sig (64 raw
 * bytes) must verify against this key before the plugin is loaded. It is a
 * different key from the enterprise-library key above. Compiled in; no setting
 * can replace it. */
static const unsigned char kReasoningPluginPubkey[32] = {
    0xbb, 0x24, 0x79, 0x25, 0x84, 0xe8, 0x9b, 0x1d, 0x1b, 0x48, 0x49, 0xba,
    0x70, 0x1d, 0xa1, 0x71, 0xa3, 0x4f, 0x8a, 0x29, 0x47, 0x83, 0xd1, 0xd4,
    0x74, 0xdf, 0x9b, 0x07, 0x44, 0xc5, 0x94, 0x53
};

typedef enum { SIG_OK, SIG_MISSING, SIG_INVALID, SIG_IOERROR } sig_result;

#ifdef _WIN32
typedef HMODULE lib_handle;
static lib_handle do_dlopen(const char *p) { return LoadLibraryA(p); }
static void *do_dlsym(lib_handle h, const char *n) { return (void *)GetProcAddress(h, n); }
static void do_dlclose(lib_handle h) { FreeLibrary(h); }
#else
typedef void *lib_handle;
static lib_handle do_dlopen(const char *p) { return dlopen(p, RTLD_NOW | RTLD_LOCAL); }
static void *do_dlsym(lib_handle h, const char *n) { return dlsym(h, n); }
static void do_dlclose(lib_handle h) { dlclose(h); }
#endif

/* Reads a whole file into a malloc'd buffer. 0 ok, -1 unreadable. */
static int read_file(const char *path, unsigned char **out, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    size_t cap = 65536, n = 0;
    unsigned char *buf = (unsigned char *)malloc(cap);
    if (!buf) { fclose(f); return -1; }
    size_t got;
    while ((got = fread(buf + n, 1, cap - n, f)) > 0) {
        n += got;
        if (n == cap) {
            if (cap > ((size_t)1 << 30)) { free(buf); fclose(f); return -1; }
            unsigned char *nb = (unsigned char *)realloc(buf, cap * 2);
            if (!nb) { free(buf); fclose(f); return -1; }
            buf = nb; cap *= 2;
        }
    }
    int err = ferror(f);
    fclose(f);
    if (err) { free(buf); return -1; }
    *out = buf; *len = n;
    return 0;
}

static sig_result check_signature(const char *lib_path, const unsigned char pubkey[32]) {
    char sig_path[1100];
    if (snprintf(sig_path, sizeof sig_path, "%s.sig", lib_path) >= (int)sizeof sig_path) return SIG_INVALID;
    unsigned char sig[64];
    FILE *f = fopen(sig_path, "rb");
    if (!f) return SIG_MISSING;
    size_t n = fread(sig, 1, sizeof sig, f);
    int extra = ferror(f) ? 0 : fgetc(f);       /* exactly 64 bytes, not "at least"; no fgetc after a read error */
    fclose(f);
    if (n != sizeof sig || extra != EOF) return SIG_INVALID;

    unsigned char *bytes = NULL; size_t len = 0;
    if (read_file(lib_path, &bytes, &len)) return SIG_IOERROR;
    int ok = fsql_ed25519_verify_detached(sig, bytes, len, pubkey);
    free(bytes);
    return ok ? SIG_OK : SIG_INVALID;
}

static bool sig_acceptable(sig_result r, bool allow_unverified) {
    if (r == SIG_OK) return true;
    if (r == SIG_INVALID) return false;
    return allow_unverified;                    /* missing / io error */
}

/* ------------------------------------------------------------------ */
/* Reasoning-plugin authenticity gate                                   */
/* ------------------------------------------------------------------ */

int fsql_plugin_gate(const char *path, char *err, size_t err_cap) {
    /* A signature is required unless FSQL_REASONING_REQUIRE_SIGNATURE=0 is in the environment. With it
     * off, a plugin that has no .sig still loads (one warning); a .sig that is present is always
     * checked and a wrong one is always refused. */
    const char *rq = getenv("FSQL_REASONING_REQUIRE_SIGNATURE");
    const bool require = !(rq && rq[0] == '0');
    if (!path || !*path) {
        if (!require) return 0;                  /* the loader reports the missing plugin itself */
        snprintf(err, err_cap, "no reasoning plugin path configured");
        return -1;
    }

    sig_result r = check_signature(path, kReasoningPluginPubkey);
    if (r == SIG_OK) return 0;
    if (r == SIG_INVALID) {
        snprintf(err, err_cap, "reasoning plugin \"%s\" failed signature verification -- refusing to load (the plugin or its "
                               ".sig is corrupt or not from FractalSQLabs)", path);
        return -1;
    }
    if (!require) {
        static bool warned = false;
        if (!warned) {
            warned = true;
            fprintf(stderr, "fractalsql: loading reasoning plugin \"%s\" without a signature "
                            "(FSQL_REASONING_REQUIRE_SIGNATURE=0)\n", path);
        }
        return 0;
    }
    if (r == SIG_MISSING)
        snprintf(err, err_cap, "no signature found for reasoning plugin \"%s\" (expected \"%s.sig\"); place the .sig "
                               "beside the plugin, or set FSQL_REASONING_REQUIRE_SIGNATURE=0 to load an unsigned plugin", path, path);
    else
        snprintf(err, err_cap, "could not read reasoning plugin \"%s\" for signature verification -- refusing to load", path);
    return -1;
}

/* ------------------------------------------------------------------ */
/* Enterprise core loader                                               */
/* ------------------------------------------------------------------ */

static fsql_mu_t g_ent_mu = FSQL_MU_INIT;
static bool g_ent_attempted = false, g_ent_loaded = false;
static FsqlEnterpriseApi g_ent;

#define RESOLVE(h, name, field) do { *(void **)&g_ent.field = do_dlsym((h), (name)); if (!g_ent.field) ok = false; } while (0)

const FsqlEnterpriseApi *fsql_enterprise_ensure(void) {
    fsql_mu_lock(&g_ent_mu);
    if (g_ent_attempted) {
        const FsqlEnterpriseApi *r = g_ent_loaded ? &g_ent : NULL;
        fsql_mu_unlock(&g_ent_mu);
        return r;
    }
    g_ent_attempted = true;
    const FsqlEnterpriseApi *result = NULL;

    const char *path = getenv("FRACTALSQL_ENTERPRISE_LIB");
    if (!path || !*path) goto out;

    const char *rq_env = getenv("FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE");
    const bool allow_unverified = (rq_env && rq_env[0] == '0');   /* required unless =0 */
    sig_result sig = check_signature(path, kSigningPubkey);
    if (!sig_acceptable(sig, allow_unverified)) {
        if (sig == SIG_INVALID)
            fprintf(stderr, "fractalsql: enterprise library \"%s\" failed signature verification -- refusing to load "
                            "(the library or its .sig is corrupt or not from FractalSQLabs)\n", path);
        else if (sig == SIG_MISSING)
            fprintf(stderr, "fractalsql: no signature found for enterprise library \"%s\" (expected \"%s.sig\"); place the "
                            ".sig beside the library, or set FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0 to load an unsigned library\n",
                    path, path);
        else
            fprintf(stderr, "fractalsql: could not read enterprise library \"%s\" for signature verification -- "
                            "refusing to load\n", path);
        goto out;
    }

    lib_handle h = do_dlopen(path);
    if (!h) { fprintf(stderr, "fractalsql: could not load enterprise library \"%s\"\n", path); goto out; }

    if (!sig_acceptable(check_signature(path, kSigningPubkey), allow_unverified)) {
        fprintf(stderr, "fractalsql: enterprise library changed between signature verification and load -- refusing to use it "
                        "(the file was swapped or modified; retry with a stable library file)\n");
        do_dlclose(h);
        goto out;
    }

    bool ok = true;
    memset(&g_ent, 0, sizeof g_ent);
    RESOLVE(h, "fsql_ledger_flush",        ledger_flush);
    RESOLVE(h, "fsql_ledger_load",         ledger_load);
    RESOLVE(h, "fsql_ledger_compact",      ledger_compact);
    RESOLVE(h, "fsql_ledger_reset_soft",   ledger_reset_soft);
    RESOLVE(h, "fsql_ledger_reset_hard",   ledger_reset_hard);
    RESOLVE(h, "fsql_ledger_truth_count",  ledger_truth_count);
    RESOLVE(h, "fsql_ledger_shadow_count", ledger_shadow_count);
    RESOLVE(h, "fsql_audit_unpack",        audit_unpack);
    RESOLVE(h, "fsql_optimize_portfolio_multimodal_pareto", optimize_portfolio_multimodal_pareto);
    /* The two scalar-multimodal entry points are OPTIONAL: a core library that predates one
     * of them still loads, and the caller picks the entry point that matches its arguments. */
    *(void **)&g_ent.ledger_set_retention             = do_dlsym(h, "fsql_ledger_set_retention");   /* optional: the retention modes */
    *(void **)&g_ent.optimize_portfolio_multimodal    = do_dlsym(h, "fsql_optimize_portfolio_multimodal");
    *(void **)&g_ent.optimize_portfolio_multimodal_ex = do_dlsym(h, "fsql_optimize_portfolio_multimodal_ex");

    if (!ok) {
        fprintf(stderr, "fractalsql: \"%s\" is missing expected enterprise symbols -- not a FractalSQL Enterprise core library?\n", path);
        memset(&g_ent, 0, sizeof g_ent);
        do_dlclose(h);
        goto out;
    }
    g_ent_loaded = true;
    result = &g_ent;
out:
    fsql_mu_unlock(&g_ent_mu);
    return result;
}

void fsql_enterprise_not_loaded_msg(const char *function_name, char *buf, size_t cap) {
    snprintf(buf, cap,
        "fractalsql: %s requires the FractalSQL Enterprise tier -- set FRACTALSQL_ENTERPRISE_LIB to the absolute path of a "
        "compiled enterprise core library to enable this function. All Community/Sovereign search, diversify, and "
        "single-restart portfolio optimization functions continue to work regardless.", function_name);
}
