/* src/fsql_config.c
 *
 * fractal_config_set / fractal_config_get: the one place where the extension's own
 * configuration can be read and changed from SQL.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * SQL surface:
 *
 *   fractal_config_set(key VARCHAR, value VARCHAR) -> BOOLEAN
 *   fractal_config_get(key VARCHAR) -> VARCHAR
 *
 * The configuration surface of this edition
 *   The stable C extension API has no custom `SET fractalsql.*` options on every
 *   supported DuckDB line, so the extension is configured through the PROCESS
 *   ENVIRONMENT (FRACTALSQL_REASONING_PLUGIN, FSQL_REASONING_HTTP_*,
 *   FRACTALSQL_ENTERPRISE_LIB), the way the operator configures it on the command
 *   line. These two functions are the documented, named way to read and change that
 *   configuration from SQL -- and the only way to change it in a running process: the
 *   write goes to the OS environment block, this module's CRT and the shared ucrtbase,
 *   so the extension's getenv() sees the new value on the very next call.
 *
 *   The key names are short and stable ("http_url", "http_model"); each maps to exactly
 *   one environment variable. A key that is not in the table is refused rather than
 *   passed through: an unknown key is a typo, and a typo that quietly created an
 *   environment variable nobody reads is worse than an error.
 *
 * Secrets
 *   http_token is a credential. It can be SET but it is never read back: fractal_config_get
 *   refuses it, so no SELECT, no MCP tool and no log can turn it into output.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_duckdb_internal.h"

typedef struct {
    const char *key;
    const char *env;
    bool        secret;
} config_key;

static const config_key kConfigKeys[] = {
    { "reasoning_plugin",    "FRACTALSQL_REASONING_PLUGIN",       false },
    { "http_url",            "FSQL_REASONING_HTTP_URL",           false },
    { "http_model",          "FSQL_REASONING_HTTP_MODEL",         false },
    { "http_embed_url",      "FSQL_REASONING_HTTP_EMBED_URL",     false },
    { "http_embed_model",    "FSQL_REASONING_HTTP_EMBED_MODEL",   false },
    { "http_think",          "FSQL_REASONING_HTTP_THINK",         false },
    { "http_think_provider", "FSQL_REASONING_HTTP_THINK_PROVIDER", false },
    { "http_native_url",     "FSQL_REASONING_HTTP_NATIVE_URL",    false },
    { "http_num_ctx",        "FSQL_REASONING_HTTP_NUM_CTX",       false },
    { "http_response_mode",  "FSQL_REASONING_HTTP_RESPONSE_MODE", false },
    { "http_allow_plaintext","FSQL_REASONING_HTTP_ALLOW_PLAINTEXT", false },
    { "http_token",          "FSQL_REASONING_HTTP_TOKEN",         true  },
    { "enterprise_lib",      "FRACTALSQL_ENTERPRISE_LIB",         false },
    { "enterprise_require_signature", "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE", false },   /* on only: the library's signature is required (the default); opting out is an operator setting */
    { "text_to_sql_allowed_statements", "FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS", false },   /* select (default) | select_insert_update */
    { "text_to_sql_use_review",   "FRACTALSQL_TEXT_TO_SQL_USE_REVIEW",   false },   /* a second model reviews each generated statement */
    { "ledger_retention",    "FRACTALSQL_LEDGER_RETENTION",       false },   /* fade (default) | exact */
    { "ledger_max_bytes",    "FSQL_DUCKDB_LEDGER_MAX_BYTES",      false },   /* the in-memory audit ledger may not grow past this many bytes (default 268435456; 0 = unlimited); appends past it are refused */
    { "agent_partial_reasoning_fail", "FRACTALSQL_AGENT_PARTIAL_REASONING_FAIL", false },   /* off (default): an agent raises when its reasoning step fails; on: it returns its computed half plus reasoning_step_failed */
    { "agent_use_index",     "FRACTALSQL_AGENT_USE_INDEX",        false },   /* off (default), on or auto: the agents search through a fractal_index */
    { "agent_index_min_rows","FRACTALSQL_AGENT_INDEX_MIN_ROWS",   false },   /* auto mode: the smallest table searched through an index (default 10000) */
    { "agent_context_row_bytes","FRACTALSQL_AGENT_CONTEXT_ROW_BYTES", false },   /* the longest text cell the retrieval agents pass to the model (default 8192; 0 = no limit) */
};
#define N_KEYS (sizeof kConfigKeys / sizeof kConfigKeys[0])

/* The environment variable's own name is accepted as a spelling of the key too, so an
 * operator who knows the variable can use it. */
static const config_key *find_key(const char *key, size_t klen) {
    for (size_t i = 0; i < N_KEYS; i++) {
        if (strlen(kConfigKeys[i].key) == klen && memcmp(key, kConfigKeys[i].key, klen) == 0) return &kConfigKeys[i];
        if (strlen(kConfigKeys[i].env) == klen && memcmp(key, kConfigKeys[i].env, klen) == 0) return &kConfigKeys[i];
    }
    return NULL;
}

/* Reports an unknown key; returns NULL. */
static const config_key *require_key(duckdb_function_info info, const char *key, size_t klen) {
    const config_key *e = find_key(key, klen);
    if (e) return e;
    fsql_sb list; fsql_sb_init(&list);
    for (size_t i = 0; i < N_KEYS; i++) fsql_sb_printf(&list, "%s%s", i ? ", " : "", kConfigKeys[i].key);
    fsql_fn_error(info, "fractalsql: unknown config key '%.*s': the documented keys are %s", (int)klen, key, fsql_sb_cstr(&list));
    fsql_sb_free(&list);
    return NULL;
}

/* fractal_config_get(key) -> VARCHAR (NULL when not configured) */
static void config_get_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    const duckdb_string_t *kd = (const duckdb_string_t *)fsql_col_data(in, 0);
    const uint64_t *kv = fsql_col_validity(in, 0);
    for (idx_t i = 0; i < n; i++) {
        if (!fsql_valid(kv, i)) { fsql_set_null(out, i); continue; }
        size_t klen; const char *key = fsql_str_data(&kd[i], &klen);
        const config_key *e = require_key(info, key, klen);
        if (!e) return;
        if (e->secret) {
            fsql_fn_error(info, "fractalsql: '%.*s' is a secret and is never read back: it is a credential, and no SELECT may "
                                "turn it into output. Check the environment that set it instead.", (int)klen, key);
            return;
        }
        const char *v = getenv(e->env);
        /* The chat-scope settings are read from the copy the extension keeps of the operator's own
         * configuration: the embedding tier points the same environment variables at the embeddings
         * endpoint, so a plain environment read would report that as the operator's chat endpoint once
         * anything had been embedded. */
        char op[4096];
        if (fsql_reasoning_operator_env_value(e->env, op, sizeof op)) v = op;
        if (!v || !*v) { fsql_set_null(out, i); continue; }       /* not configured */
        fsql_set_str(out, i, v, strlen(v));
    }
}

/* fractal_config_keys() -> VARCHAR: a JSON array of {name, type, session_overridable} for every key, so a caller
 * can discover the knobs instead of hard-coding them. type is string, path, int, bool or enum (agent_use_index is
 * an enum: off, on, auto). Every key is changed with fractal_config_set, so session_overridable is true. */
static const char *key_type(const char *k) {
    static const char *const ints[]  = { "http_num_ctx", "agent_index_min_rows", "agent_context_row_bytes", "ledger_max_bytes" };
    static const char *const bools[] = { "http_allow_plaintext", "enterprise_require_signature", "text_to_sql_use_review", "agent_partial_reasoning_fail" };
    static const char *const enums[] = { "text_to_sql_allowed_statements", "ledger_retention", "agent_use_index" };
    static const char *const paths[] = { "reasoning_plugin", "enterprise_lib" };
    for (size_t i = 0; i < sizeof ints / sizeof *ints; i++) if (!strcmp(k, ints[i])) return "int";
    for (size_t i = 0; i < sizeof bools / sizeof *bools; i++) if (!strcmp(k, bools[i])) return "bool";
    for (size_t i = 0; i < sizeof enums / sizeof *enums; i++) if (!strcmp(k, enums[i])) return "enum";
    for (size_t i = 0; i < sizeof paths / sizeof *paths; i++) if (!strcmp(k, paths[i])) return "path";
    return "string";
}

static void config_keys_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    (void)info;
    fsql_sb sb; fsql_sb_init(&sb);
    fsql_sb_printf(&sb, "[");
    for (size_t i = 0; i < N_KEYS; i++)
        fsql_sb_printf(&sb, "%s{\"name\":\"%s\",\"type\":\"%s\",\"session_overridable\":true}",
                       i ? "," : "", kConfigKeys[i].key, key_type(kConfigKeys[i].key));
    fsql_sb_printf(&sb, "]");
    const char *j = fsql_sb_cstr(&sb);
    for (idx_t i = 0, n = duckdb_data_chunk_get_size(in); i < n; i++) fsql_set_str(out, i, j, strlen(j));
    fsql_sb_free(&sb);
}

/* fractal_config_set(key, value) -> BOOLEAN. An empty value unsets the variable: the plugin reads a
 * missing variable as "not configured", which is how a setting is turned off again. */
static void config_set_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    bool *res = (bool *)duckdb_vector_get_data(out);
    const duckdb_string_t *kd = (const duckdb_string_t *)fsql_col_data(in, 0);
    const duckdb_string_t *vd = (const duckdb_string_t *)fsql_col_data(in, 1);
    const uint64_t *kv = fsql_col_validity(in, 0), *vv = fsql_col_validity(in, 1);
    for (idx_t i = 0; i < n; i++) {
        if (!fsql_valid(kv, i) || !fsql_valid(vv, i)) { fsql_set_null(out, i); continue; }
        size_t klen, vlen;
        const char *key = fsql_str_data(&kd[i], &klen), *val = fsql_str_data(&vd[i], &vlen);
        const config_key *e = require_key(info, key, klen);
        if (!e) return;
        char *value = fsql_xstrndup(val, vlen);
        if (!value) { fsql_fn_error(info, "fractalsql: out of memory"); return; }
        if (strcmp(e->key, "ledger_retention") == 0 && *value && strcmp(value, "fade") != 0 && strcmp(value, "exact") != 0) {
            free(value);
            fsql_fn_error(info, "fractalsql: 'ledger_retention' must be one of: fade, exact");
            return;
        }
        if (strcmp(e->key, "ledger_max_bytes") == 0) {
            char *end = NULL;
            long long v = strtoll(value, &end, 10);
            if (*value && (*end != '\0' || v < 0 || v > 68719476736LL)) {
                fsql_fn_error(info, "fractalsql: 'ledger_max_bytes' must be an integer between 0 and 68719476736 (0 = unlimited)");
                free(value);
                return;
            }
        } else if (strcmp(e->key, "agent_index_min_rows") == 0 || strcmp(e->key, "agent_context_row_bytes") == 0) {
            long long lim = strcmp(e->key, "agent_index_min_rows") == 0 ? 2000000 : 1048576;
            char *end = NULL;
            long long v = strtoll(value, &end, 10);
            if (!*value || *end != '\0' || v < 0 || v > lim) {
                fsql_fn_error(info, "fractalsql: '%s' must be an integer between 0 and %lld", e->key, lim);
                free(value);
                return;
            }
        } else if (strcmp(e->key, "agent_use_index") == 0) {
            /* off (stored as empty, which unsets the variable), on (1) or auto; the old boolean spellings still mean on / off */
            static const char *const on_vals[] = { "on", "1", "true", "yes" }, *const off_vals[] = { "off", "0", "false", "no", "" };
            int state = -1;
            for (size_t v = 0; v < sizeof on_vals / sizeof on_vals[0]; v++) if (strcmp(value, on_vals[v]) == 0) state = 1;
            for (size_t v = 0; v < sizeof off_vals / sizeof off_vals[0]; v++) if (strcmp(value, off_vals[v]) == 0) state = 0;
            if (strcmp(value, "auto") == 0) state = 2;
            if (state < 0) {
                fsql_fn_error(info, "fractalsql: 'agent_use_index' must be one of: off, on, auto");
                free(value);
                return;
            }
            if (state != 2) { value[0] = state ? '1' : '\0'; if (state) value[1] = '\0'; }
        } else if (strcmp(e->key, "text_to_sql_allowed_statements") == 0) {
            if (*value && strcmp(value, "select") != 0 && strcmp(value, "select_insert_update") != 0) {
                fsql_fn_error(info, "fractalsql: 'text_to_sql_allowed_statements' must be one of: select, select_insert_update");
                free(value);
                return;
            }
        } else if (strcmp(e->key, "enterprise_require_signature") == 0) {
            /* SQL can only make the requirement stricter (on, or empty = the default, which is on). Turning it off lets an unsigned
             * library load, which is the operator's decision: set FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0 in the environment. */
            static const char *const on_vals[] = { "on", "1", "true", "yes", "" };
            int ok = 0;
            for (size_t v = 0; v < sizeof on_vals / sizeof on_vals[0]; v++) if (strcmp(value, on_vals[v]) == 0) ok = 1;
            if (!ok) {
                fsql_fn_error(info, "fractalsql: 'enterprise_require_signature' can only be turned on from SQL (on, the default); turning the "
                                    "signature requirement off is an operator setting: set FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0 in the environment");
                free(value);
                return;
            }
            value[0] = *value ? '1' : '\0';
            if (*value) value[1] = '\0';
        } else if (strcmp(e->key, "http_allow_plaintext") == 0 || strcmp(e->key, "text_to_sql_use_review") == 0 || strcmp(e->key, "agent_partial_reasoning_fail") == 0) {
            /* the on/off keys: the same spellings every FractalSQL host accepts, stored the way the plugin reads them
             * (1 = on, empty = off, which unsets the variable) */
            static const char *const on_vals[] = { "on", "1", "true", "yes" }, *const off_vals[] = { "off", "0", "false", "no", "" };
            int state = -1;
            for (size_t v = 0; v < sizeof on_vals / sizeof on_vals[0]; v++) if (strcmp(value, on_vals[v]) == 0) state = 1;
            for (size_t v = 0; v < sizeof off_vals / sizeof off_vals[0]; v++) if (strcmp(value, off_vals[v]) == 0) state = 0;
            if (state < 0) {
                fsql_fn_error(info, "fractalsql: '%s' must be one of: on, off", e->key);
                free(value);
                return;
            }
            value[0] = state ? '1' : '\0';
            if (state) value[1] = '\0';
        }
        fsql_apply_env(e->env, value);
        /* The chat, text-to-SQL and review tiers apply the operator's own settings when they load, from
         * a copy taken at extension init -- a change made here has to reach that copy too. */
        fsql_reasoning_update_operator_env(e->env, value);
        free(value);
        res[i] = true;
    }
}

/* fractal_release() -> BOOLEAN. Closes the connections the extension keeps for running SQL on the caller's
 * database (the text-to-SQL, agent and vectorizer functions), so the host can finish closing the database:
 * its shutdown checkpoint runs, the file is released. Irreversible for this database: those functions then
 * report that nested queries were released. Call it as the last statement of a session that is about to close
 * a file database. The destructive latch does not refuse it: the latch refuses the destructive ledger actions,
 * not the closing of the extension's own connections. */
static void release_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    char err[256];
    if (fsql_instance_release(fsql_scalar_instance(info), err, sizeof err) != 0) { fsql_fn_error(info, "%s", err); return; }
    bool *res = (bool *)duckdb_vector_get_data(out);
    for (idx_t i = 0, n = duckdb_data_chunk_get_size(in); i < n; i++) res[i] = true;
}

/* Both functions can refuse (an unknown key, a secret key), and fractal_config_set changes process
 * state, so it is not folded or reordered. */
static const fsql_scalar_def kConfigDefs[] = {
    { "fractal_config_get", 1, { FSQL_T_VARCHAR },                  FSQL_T_VARCHAR, config_get_fn, NULL, 0 },
    { "fractal_config_keys", 0, { 0 },                              FSQL_T_VARCHAR, config_keys_fn, NULL, 0 },
    { "fractal_config_set", 2, { FSQL_T_VARCHAR, FSQL_T_VARCHAR },  FSQL_T_BOOLEAN, config_set_fn, NULL, 0 },
    { "fractal_release", 0, { 0 },                              FSQL_T_BOOLEAN, release_fn,    NULL, FSQL_FN_VOLATILE },
};

bool fsql_config_register(duckdb_connection con, const char **err) {
    return fsql_register_scalars(con, kConfigDefs, (int)(sizeof kConfigDefs / sizeof kConfigDefs[0]), err);
}
