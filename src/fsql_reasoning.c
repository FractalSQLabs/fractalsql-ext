/* src/fsql_reasoning.c
 *
 * The shared, four-tier reasoning machinery that fractal_reason (fsql_agents.c),
 * fractal_embed (fsql_vectorizer.c), fractal_text_to_sql (fsql_t2s.c) and the agent
 * tiers dispatch through. A helpers-only TU: it registers no SQL
 * functions of its own.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Reasoning plugin
 *   Calls dispatch through fsql_dispatch_ai on an fsql_ctx built by fsql_new_sovereign
 *   and populated via fsql_load_reasoning against a genuinely dlopen-loadable
 *   fractalsql-reasoning-*.so. The plugin path comes from FRACTALSQL_REASONING_PLUGIN,
 *   an environment variable rather than a `SET fractalsql.*` option (the stable C
 *   extension API has no custom settings on every supported DuckDB line).
 *
 * Four tiers, four contexts
 *   The tiers (CHAT, T2S, REVIEW, EMBED) each get their own ctx, each loaded lazily the
 *   first time that tier dispatches. Before a tier's load, that tier's env block is
 *   applied and the plugin reads it once, at its init:
 *
 *     CHAT:   MODE and SYSTEM_TAG are unset; RESPONSE_MODE is restored to the value
 *             captured at extension init (or unset when the operator set none).
 *     T2S:    SYSTEM_TAG is "duckdb" and RESPONSE_MODE is hard-forced to "code"; the
 *             latter is unset again right after the load so it cannot outlive this
 *             tier's init.
 *     REVIEW: MODE, SYSTEM_TAG and RESPONSE_MODE are unset, so a raw PASS/FAIL-style
 *             answer stays available whatever response mode the operator configured.
 *     EMBED:  MODE is forced to "embedding"; the endpoint and model come from
 *             FSQL_REASONING_HTTP_EMBED_URL / _EMBED_MODEL (NO fallback to the chat
 *             URL/model: a chat model is not an embedding model); SYSTEM_TAG,
 *             RESPONSE_MODE and every think variable are unset; a missing embed URL is a
 *             hard error raised before any environment is touched.
 *
 *   The URL and MODEL variables are re-applied by the chat/t2s/review tiers on every
 *   load, from the operator's captured configuration, so a prior embed load cannot leak
 *   its endpoint or model into a chat-mode load.
 *
 * One process-wide mutex serializes environment application, plugin loading and
 * dispatch: the environment is process-global and racy, and an fsql_ctx is documented
 * not thread-safe.
 */

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#  include <windows.h>
#endif

#include "fsql_duckdb_internal.h"

/* ------------------------------------------------------------------ */
/* State                                                                */
/* ------------------------------------------------------------------ */

static fsql_mu_t g_mu = FSQL_MU_INIT;

typedef struct {
    fsql_ctx *ctx;
    bool      tried;       /* a load was attempted (try-once per tier)                      */
    bool      loaded;
    bool      setup_error; /* the recorded failure was a SETUP failure (plugin never configured) */
    char      fail_msg[512];
} tier_state;

static tier_state g_tier[FSQL_REASONING_TIER_COUNT];

/* The operator's chat-scope configuration, captured at extension init rather than read
 * from the environment each time a tier loads. The plugin reads its endpoint and model
 * from the environment when it initialises and every tier writes its own values there; the
 * embedding tier points the same variables at the embeddings endpoint, so a chat tier that
 * loads afterwards would otherwise find the embeddings endpoint and dispatch its chat call
 * to it. Capturing keeps each tier on the configuration the operator gave it. */
typedef struct {
    char *response_mode;     /* FSQL_REASONING_HTTP_RESPONSE_MODE at init */
    char *url, *model, *think, *think_provider, *native_url, *num_ctx;
} operator_env;
static operator_env g_op;

static void set_str(char **slot, const char *v) {
    free(*slot);
    *slot = (v && *v) ? fsql_xstrdup(v) : NULL;
}

void fsql_reasoning_capture_boot_env(void) {
    fsql_mu_lock(&g_mu);
    set_str(&g_op.response_mode, getenv("FSQL_REASONING_HTTP_RESPONSE_MODE"));
    set_str(&g_op.url,            getenv("FSQL_REASONING_HTTP_URL"));
    set_str(&g_op.model,          getenv("FSQL_REASONING_HTTP_MODEL"));
    set_str(&g_op.think,          getenv("FSQL_REASONING_HTTP_THINK"));
    set_str(&g_op.think_provider, getenv("FSQL_REASONING_HTTP_THINK_PROVIDER"));
    set_str(&g_op.native_url,     getenv("FSQL_REASONING_HTTP_NATIVE_URL"));
    set_str(&g_op.num_ctx,        getenv("FSQL_REASONING_HTTP_NUM_CTX"));
    fsql_mu_unlock(&g_mu);
}

static char **operator_slot(const char *env_name) {
    if (!strcmp(env_name, "FSQL_REASONING_HTTP_URL"))           return &g_op.url;
    if (!strcmp(env_name, "FSQL_REASONING_HTTP_MODEL"))         return &g_op.model;
    if (!strcmp(env_name, "FSQL_REASONING_HTTP_THINK"))         return &g_op.think;
    if (!strcmp(env_name, "FSQL_REASONING_HTTP_THINK_PROVIDER")) return &g_op.think_provider;
    if (!strcmp(env_name, "FSQL_REASONING_HTTP_NATIVE_URL"))    return &g_op.native_url;
    if (!strcmp(env_name, "FSQL_REASONING_HTTP_NUM_CTX"))       return &g_op.num_ctx;
    return NULL;
}

void fsql_reasoning_update_operator_env(const char *env_name, const char *value) {
    if (!env_name || !*env_name) return;
    fsql_mu_lock(&g_mu);
    char **slot = operator_slot(env_name);
    if (slot) set_str(slot, value);
    fsql_mu_unlock(&g_mu);
}

int fsql_reasoning_operator_env_value(const char *env_name, char *buf, size_t cap) {
    if (!env_name || !*env_name || !buf || cap == 0) return 0;
    fsql_mu_lock(&g_mu);
    char **slot = operator_slot(env_name);
    if (slot) snprintf(buf, cap, "%s", *slot ? *slot : "");
    fsql_mu_unlock(&g_mu);
    return slot != NULL;
}

/* ------------------------------------------------------------------ */
/* Environment writes                                                   */
/*                                                                      */
/* Reasoning plugins are a public C-ABI surface: a plugin built with a  */
/* different CRT than this host won't see _putenv_s's update on Windows,*/
/* since that only touches the caller's own CRT-private environment.    */
/* The Windows write is therefore: OS block first, then this module's    */
/* CRT, then the shared ucrtbase CRT last (that order matters: the      */
/* reverse races the UCRT's resync and can land a stale empty entry).   */
/* The value is copied out of the environment table before anything is  */
/* written: it usually points INTO that table, and _putenv_s replaces   */
/* the entry's buffer, leaving the pointer dangling.                    */
/* ------------------------------------------------------------------ */

#ifdef _WIN32
typedef int (*putenv_s_fn)(const char *, const char *);
static putenv_s_fn shared_crt_putenv_s(void) {
    static putenv_s_fn fn;
    static int resolved;
    if (!resolved) {
        HMODULE u = GetModuleHandleA("ucrtbase.dll");
        if (!u) u = LoadLibraryA("ucrtbase.dll");
        if (u) fn = (putenv_s_fn)(void *)GetProcAddress(u, "_putenv_s");
        resolved = 1;
    }
    return fn;
}
#endif

static void env_set(const char *name, const char *value) {
#ifdef _WIN32
    char *copy = fsql_xstrdup(value ? value : "");
    if (!copy) return;
    SetEnvironmentVariableA(name, copy);
    _putenv_s(name, copy);
    putenv_s_fn shared = shared_crt_putenv_s();
    if (shared) shared(name, copy);
    free(copy);
#else
    setenv(name, value, 1);
#endif
}

static void env_unset(const char *name) {
#ifdef _WIN32
    SetEnvironmentVariableA(name, NULL);
    _putenv_s(name, "");
    putenv_s_fn shared = shared_crt_putenv_s();
    if (shared) shared(name, "");
#else
    unsetenv(name);
#endif
}

/* Set or clear one variable: an empty value unsets (the plugin reads a missing variable as
 * "not configured" for every optional field). */
static void env_apply(const char *name, const char *value) {
    if (value && *value) env_set(name, value); else env_unset(name);
}

void fsql_apply_env(const char *name, const char *value) { env_apply(name, value); }

/* The variable names the vendored plugin's init reads, once, at load time. */
#define ENV_URL            "FSQL_REASONING_HTTP_URL"
#define ENV_MODEL          "FSQL_REASONING_HTTP_MODEL"
#define ENV_MODE           "FSQL_REASONING_HTTP_MODE"
#define ENV_SYSTEM_TAG     "FSQL_REASONING_HTTP_SYSTEM_TAG"
#define ENV_RESPONSE_MODE  "FSQL_REASONING_HTTP_RESPONSE_MODE"
#define ENV_THINK          "FSQL_REASONING_HTTP_THINK"
#define ENV_THINK_PROVIDER "FSQL_REASONING_HTTP_THINK_PROVIDER"
#define ENV_NATIVE_URL     "FSQL_REASONING_HTTP_NATIVE_URL"
#define ENV_NUM_CTX        "FSQL_REASONING_HTTP_NUM_CTX"

/* The surface shared by CHAT / T2S / REVIEW: the operator's endpoint, model and think
 * settings, re-applied by value so a prior load of another tier cannot leak into this one. */
static void apply_operator_common(void) {
    env_apply(ENV_URL, g_op.url);
    env_apply(ENV_MODEL, g_op.model);
    env_apply(ENV_THINK, g_op.think);
    env_apply(ENV_THINK_PROVIDER, g_op.think_provider);
    env_apply(ENV_NATIVE_URL, g_op.native_url);
    env_apply(ENV_NUM_CTX, g_op.num_ctx);
}

static void apply_chat_env(void) {
    apply_operator_common();
    env_apply(ENV_RESPONSE_MODE, g_op.response_mode);
    env_unset(ENV_MODE);          /* chat completions, not embedding */
    env_unset(ENV_SYSTEM_TAG);    /* no host tag on the chat tier    */
}

static void apply_t2s_env(void) {
    apply_operator_common();
    env_unset(ENV_MODE);
    env_set(ENV_SYSTEM_TAG, "duckdb");   /* the provider can attribute this tier's traffic */
    env_set(ENV_RESPONSE_MODE, "code");  /* the caller unsets it right after the load       */
}

/* REVIEW needs a raw leading PASS/FAIL, which neither the T2S tier's forced "code" mode nor an
 * operator's configured chat response mode (e.g. "json") would reliably produce. */
static void apply_review_env(void) {
    apply_operator_common();
    env_unset(ENV_MODE);
    env_unset(ENV_SYSTEM_TAG);
    env_unset(ENV_RESPONSE_MODE);
}

static void apply_embed_env(void) {
    env_apply(ENV_URL, getenv("FSQL_REASONING_HTTP_EMBED_URL"));
    env_apply(ENV_MODEL, getenv("FSQL_REASONING_HTTP_EMBED_MODEL"));
    env_set(ENV_MODE, "embedding");
    env_unset(ENV_SYSTEM_TAG);
    env_unset(ENV_RESPONSE_MODE);
    env_unset(ENV_THINK);
    env_unset(ENV_THINK_PROVIDER);
    env_unset(ENV_NATIVE_URL);
    env_unset(ENV_NUM_CTX);
}

/* ------------------------------------------------------------------ */
/* Tier load                                                            */
/* ------------------------------------------------------------------ */

static int record_fail(tier_state *t, bool setup, char *err, size_t cap, const char *fmt, ...) FSQL_PRINTF(5, 6);
static int record_fail(tier_state *t, bool setup, char *err, size_t cap, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(t->fail_msg, sizeof t->fail_msg, fmt, ap);
    va_end(ap);
    if (setup) t->setup_error = true;
    snprintf(err, cap, "%s", t->fail_msg);
    return setup ? FSQL_REASONING_NOT_CONFIGURED : FSQL_REASONING_ERR;
}

/* Caller holds g_mu. Try-once per tier: a failed load leaves the tier permanently unavailable
 * for this process (the configuration is process-static, so a retry would fail identically) --
 * the same convention as the enterprise-tier gate. The failure text is recorded so a sticky
 * error still tells the operator what actually failed, even when DuckDB's optimizer folded a
 * constant-argument call at plan time and swallowed the first attempt's exception. */
static int ensure_tier_ctx_locked(int tier, fsql_ctx **out, char *err, size_t cap) {
    tier_state *t = &g_tier[tier];

    if (t->tried) {
        if (!t->loaded) {
            snprintf(err, cap, "fractalsql: no reasoning plugin loaded (FRACTALSQL_REASONING_PLUGIN load failed earlier "
                               "this session): %s", t->fail_msg);
            return t->setup_error ? FSQL_REASONING_NOT_CONFIGURED : FSQL_REASONING_ERR;
        }
        *out = t->ctx;
        return FSQL_REASONING_OK;
    }
    t->tried = true;

    /* Copied before any environment change: a pointer from getenv() is invalid once setenv()/unsetenv() runs
     * (POSIX), and this one is handed to the signature verifier and to dlopen below. */
    char path[1024];
    {
        const char *p = getenv("FRACTALSQL_REASONING_PLUGIN");
        if (!p || !*p)
            return record_fail(t, true, err, cap,
                "fractalsql: reasoning plugin not configured -- set FRACTALSQL_REASONING_PLUGIN to the absolute path of a "
                "compiled fractalsql-reasoning-*.so to enable this function");
        if (strlen(p) >= sizeof path)
            return record_fail(t, true, err, cap, "fractalsql: FRACTALSQL_REASONING_PLUGIN is too long (limit %zu bytes)",
                               sizeof path - 1);
        memcpy(path, p, strlen(p) + 1);
    }

    /* Embed tier: the endpoint must be configured. Rejected here so the clear error fires before
     * any environment mutation. No fallback to the chat URL: a chat model is not a substitute for
     * a purpose-trained embedding model, and the two live on different endpoint paths. */
    if (tier == FSQL_REASONING_TIER_EMBED && !getenv("FSQL_REASONING_HTTP_EMBED_URL"))
        return record_fail(t, true, err, cap,
            "fractal_embed: FSQL_REASONING_HTTP_EMBED_URL is not configured (set it to the embeddings endpoint, e.g. "
            "'https://.../v1/embeddings')");

    if (!t->ctx) {
        t->ctx = fsql_new_sovereign(NULL, NULL);
        if (!t->ctx) return record_fail(t, false, err, cap, "fractalsql: reasoning ctx allocation failed (OOM?)");
    }

    switch (tier) {
    case FSQL_REASONING_TIER_CHAT:   apply_chat_env();   break;
    case FSQL_REASONING_TIER_T2S:    apply_t2s_env();    break;
    case FSQL_REASONING_TIER_REVIEW: apply_review_env(); break;
    case FSQL_REASONING_TIER_EMBED:  apply_embed_env();  break;
    }

    {
        char verr[512];
        if (fsql_plugin_gate(path, verr, sizeof verr) != 0)
            return record_fail(t, false, err, cap, "fractalsql: %s", verr);
    }
    int rc = fsql_load_reasoning(t->ctx, path);

    /* RESPONSE_MODE is unset right after the t2s load so the hard-forced "code" does not outlive this
     * tier's init (the plugin only reads the env at init, so the next t2s load re-sets it first). */
    if (tier == FSQL_REASONING_TIER_T2S) env_unset(ENV_RESPONSE_MODE);

    if (rc != FSQL_OK) {
        const char *e = fsql_last_error(t->ctx);
        return record_fail(t, false, err, cap, "fractalsql: failed to load reasoning plugin \"%s\" (rc=%d): %s",
                           path, rc, (e && *e) ? e : "(no detail)");
    }
    t->loaded = true;
    *out = t->ctx;
    return FSQL_REASONING_OK;
}

/* ------------------------------------------------------------------ */
/* Dispatch                                                             */
/* ------------------------------------------------------------------ */

/* NULL-summary / implausible-length / embedded-NUL guard, before any further read of the response:
 * the reasoning ABI hands back summary_len as a plain size_t the plugin supplies, so a buggy plugin
 * can claim a huge length while backing it with a tiny allocation. A zero-length response
 * legitimately arrives with summary == NULL. Frees the response and fills err on a violation. */
static int guard_response(fsql_ai_response_t *resp, char *err, size_t cap) {
    if (!resp->summary && resp->summary_len > 0) {
        size_t len = resp->summary_len;
        fsql_ai_response_free(resp);
        snprintf(err, cap, "fractalsql: reasoning plugin reported a NULL summary with a non-zero length (%zu bytes) -- "
                           "likely a plugin bug", len);
        return -1;
    }
    if (resp->summary_len > FSQL_MAX_AI_RESPONSE_BYTES) {
        size_t len = resp->summary_len;
        fsql_ai_response_free(resp);
        snprintf(err, cap, "fractalsql: reasoning plugin reported an implausible response length (%zu bytes, limit %zu) -- "
                           "likely a plugin bug", len, (size_t)FSQL_MAX_AI_RESPONSE_BYTES);
        return -1;
    }
    if (resp->summary && memchr(resp->summary, '\0', resp->summary_len)) {
        fsql_ai_response_free(resp);
        snprintf(err, cap, "fractalsql: reasoning response contains an embedded NUL -- likely a plugin bug");
        return -1;
    }
    return 0;
}

int fsql_reasoning_generate(int tier, const char *query, size_t query_len,
                            const char *context_json, size_t context_len,
                            char **out_resp, char *err, size_t err_cap) {
    *out_resp = NULL;
    if (tier < 0 || tier >= FSQL_REASONING_TIER_COUNT) {
        snprintf(err, err_cap, "fractalsql: unknown reasoning tier");
        return FSQL_REASONING_ERR;
    }
    fsql_mu_lock(&g_mu);
    fsql_ctx *ctx = NULL;
    int lrc = ensure_tier_ctx_locked(tier, &ctx, err, err_cap);
    if (lrc != FSQL_REASONING_OK) { fsql_mu_unlock(&g_mu); return lrc; }

    fsql_ai_response_t resp;
    memset(&resp, 0, sizeof resp);
    int rc = fsql_dispatch_ai(ctx, query, query_len, context_json, context_len, &resp);
    if (rc != FSQL_OK || resp.rc != 0) {
        int err_rc = rc != FSQL_OK ? rc : resp.rc;
        const char *e = fsql_last_error(ctx);
        snprintf(err, err_cap, "fractalsql: reasoning dispatch failed (rc=%d): %s", err_rc, (e && *e) ? e : "(no detail)");
        fsql_ai_response_free(&resp);
        fsql_mu_unlock(&g_mu);
        return FSQL_REASONING_ERR;
    }
    if (guard_response(&resp, err, err_cap)) { fsql_mu_unlock(&g_mu); return FSQL_REASONING_ERR; }
    char *copy = fsql_xstrndup(resp.summary ? resp.summary : "", resp.summary_len);
    fsql_ai_response_free(&resp);
    fsql_mu_unlock(&g_mu);
    if (!copy) { snprintf(err, err_cap, "fractalsql: out of memory"); return FSQL_REASONING_ERR; }
    *out_resp = copy;
    return FSQL_REASONING_OK;
}
