/* src/fsql_duckdb_internal.h
 *
 * fractalsql-ext (pure-C extension): shared internal contract between the
 * extension's translation units. Not installed; not part of any public ABI.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * TU map (all pure C11, no libstdc++, no DuckDB internals -- only the stable
 * C extension API, reached through fsql_duck.h):
 *
 *   fractalsql_ext.c   entry point (fractalsql_init_c_api), load guard,
 *                         registration table, smoke + search/scout surface
 *                         (fractal_edition/_version, fractal_search,
 *                         fractal_search_explore)
 *   fsql_duck.c/.h        the adapter: the ONLY code that touches
 *                         duckdb_extension.h (registration, vectors, errors,
 *                         the nested-query connection pool, statement
 *                         classifier, per-connection registry)
 *   fsql_buf.c/.h         bounds-checked string builder and arrays
 *   fsql_vector.c/.h      fractal_vector_* (distance, math, quantize, text)
 *   fsql_config.c         fractal_config_set / fractal_config_get
 *   fsql_reasoning.c      the four-tier reasoning machinery (env blocks, plugin
 *                         load + verify, dispatch) and fractal_reason
 *   fsql_t2s.c            fractal_schema_context + fractal_text_to_sql
 *   fsql_vectorizer.c     fractal_vectorizer_* + fractal_embed
 *   fsql_agents.c         agent-tier composition functions
 *   fsql_domain_agents.c  the sixteen Domain Agents
 *   fsql_ledger.c         per-connection ledger + fractal_ledger_* / audit
 *   fsql_enterprise.c     dlopen loader for the enterprise core
 *   fsql_sovereign.c      dimension / portfolio / morphology / diversify
 *   fsql_parse.c/.h       shared string-parsing helpers, no external deps
 *   fsql_hmac.h, fsql_ed25519.h, fsql_audit_redact.h, fsql_sha256.h
 *                         vendored header-only crypto/redaction helpers
 *
 * Differences from the SQLite tree that are deliberate:
 *   - SQLite keeps its configuration in a per-connection FsqlState because a
 *     SQLite extension can hold per-connection user data. The DuckDB column is
 *     configured through the PROCESS ENVIRONMENT (there are no `SET
 *     fractalsql.*` options on the stable C API), so configuration and the
 *     reasoning tiers live in the process-wide FsqlGlobal below, serialized by
 *     one mutex -- exactly as the C++ build did. Only what is genuinely
 *     per-connection (the ledger, the destructive latch, the diversify flag)
 *     is keyed by connection id in the registry (fsql_duck.h).
 *   - There is one build flavour (sovereign): every TU is always linked.
 *   - Errors are returned, not thrown: a helper that can fail takes
 *     `char *err, size_t err_cap` and returns 0 / -1, as the SQLite helpers do.
 */
#ifndef FSQL_DUCKDB_INTERNAL_H
#define FSQL_DUCKDB_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

#include "fractalsql.h"
#include "fractalsql_sql.h"
#include "fsql_buf.h"
#include "fsql_duck.h"

/* ------------------------------------------------------------------ */
/* Constants (names and values follow the SQLite tree where they exist) */
/* ------------------------------------------------------------------ */

/* Extension version. Single source of truth for fractal_version(). */
#define FSQL_DUCKDB_VERSION_STR   "2.0.1"
#define FSQL_DUCKDB_EDITION_STR   "Community"

/* SFS tuning defaults for fractal_search. */
#define FSQL_SFS_DEFAULT_ITERATIONS 30
#define FSQL_SFS_DEFAULT_POP_SIZE   50
#define FSQL_SFS_DEFAULT_DIFFUSION  2
#define FSQL_SFS_DEFAULT_WALK       0.5

/* Input-side DoS guards. */
#define FSQL_ARENA_MAX_DIM     4096
/* Cap on any single text handed to the reasoning plugin (4 MiB), the same cap
 * the other integrations use: a clean rejection, never a silent truncation. */
#define FSQL_MAX_INPUT_BYTES   (4 * 1024 * 1024)
/* Largest reasoning-plugin response accepted (a lying length is rejected). */
#define FSQL_MAX_AI_RESPONSE_BYTES (16 * 1024 * 1024)
/* Scout accumulates the whole column: rows * dim * 8 bytes. */
#define FSQL_SCOUT_MAX_CORPUS_ROWS (2u * 1000u * 1000u)

/* fractal_schema_context table cap. */
#define FSQL_T2S_MAX_TABLES    512

/* SFS hyperparameter ceilings shared by the agent tier's validation. */
#define FSQL_AGENTS_MAX_ITERATIONS   10000
#define FSQL_AGENTS_MAX_POPULATION   10000
#define FSQL_AGENTS_MAX_DIFFUSION    32

/* Work bound on one SFS search: iterations x population_size x
 * diffusion_factor x dim. Each factor is in range on its own, so only the
 * product can catch a call that would run effectively forever inside the host
 * process. The same bound the other engines apply (about 30 ns a unit, so
 * 2^31 is roughly a minute). */
#define FSQL_SEARCH_MAX_WORK  2147483648ULL

/* ------------------------------------------------------------------ */
/* Reasoning tiers                                                     */
/* ------------------------------------------------------------------ */

/* The vendored reasoning plugin reads its ENTIRE configuration from the process
 * environment once, inside fsql_reasoning_init. Each tier therefore applies its
 * OWN env block immediately before that tier's fsql_load_reasoning(); see
 * fsql_reasoning.c for the per-tier blocks. */
typedef enum FsqlReasoningTier {
    FSQL_REASONING_TIER_CHAT   = 0,  /* fractal_reason / agent chat calls */
    FSQL_REASONING_TIER_T2S    = 1,  /* text-to-sql GENERATE only         */
    FSQL_REASONING_TIER_EMBED  = 2,  /* fractal_embed / vectorizer        */
    FSQL_REASONING_TIER_REVIEW = 3,  /* text-to-sql REVIEW only           */
    FSQL_REASONING_TIER_COUNT  = 4
} FsqlReasoningTier;

/* Return codes of the reasoning helpers. -2 is a SETUP failure (the plugin was
 * never configured): a caller that tolerates an outage (the agent engines keep
 * their computed half) must still refuse it, because every retry would fail
 * identically. This is the C form of the C++ build's ReasoningNotConfigured. */
#define FSQL_REASONING_OK              0
#define FSQL_REASONING_ERR            (-1)
#define FSQL_REASONING_NOT_CONFIGURED (-2)

/* ------------------------------------------------------------------ */
/* Reasoning (fsql_reasoning.c)                                        */
/* ------------------------------------------------------------------ */

/* Called once from the entry point, before any tier can load: captures the
 * operator's FSQL_REASONING_HTTP_* chat-scope settings and response mode. */
void fsql_reasoning_capture_boot_env(void);

/* Records a change fractal_config_set made to a chat-scope setting so the chat,
 * t2s and review tiers apply it when they load. Unknown names are ignored. */
void fsql_reasoning_update_operator_env(const char *env_name, const char *value);

/* The operator's current value for one chat-scope setting, copied into buf (empty when
 * unset). Returns 1 if env_name is a chat-scope key, else 0. */
int  fsql_reasoning_operator_env_value(const char *env_name, char *buf, size_t cap);

/* Set the variable, or unset it when value is empty (OS block, this CRT and, on
 * Windows, the shared ucrtbase). */
void fsql_apply_env(const char *name, const char *value);

/* One-shot reasoning call for `tier`; mirrors fsql_reasoning_generate in the
 * SQLite tree. On success returns FSQL_REASONING_OK and sets *out_resp to a
 * malloc'd NUL-terminated copy the caller frees; otherwise a negative code with
 * the operator-facing message in `err`. */
int fsql_reasoning_generate(int tier, const char *query, size_t query_len,
                            const char *context_json, size_t context_len,
                            char **out_resp, char *err, size_t err_cap);

/* ------------------------------------------------------------------ */
/* Enterprise core loader + plugin gate (fsql_enterprise.c)            */
/* ------------------------------------------------------------------ */

/* The community sovereign archive does not export the ledger/audit or multimodal-portfolio
 * symbols; they are resolved from FRACTALSQL_ENTERPRISE_LIB at first use. */
typedef struct FsqlEnterpriseApi {
    int (*ledger_flush)(fsql_ctx *);
    int (*ledger_load)(fsql_ctx *);
    int (*ledger_compact)(fsql_ctx *);
    int (*ledger_reset_soft)(fsql_ctx *);
    int (*ledger_reset_hard)(fsql_ctx *);
    int (*ledger_truth_count)(const fsql_ctx *, size_t *);
    int (*ledger_shadow_count)(const fsql_ctx *, size_t *);
    int (*audit_unpack)(const void *, size_t, char *, size_t *);
    /* optional (tolerant-absence) symbols */
    int (*optimize_portfolio_multimodal)(const double *, const double *, size_t, size_t,
                                         int, double, double, uint64_t, double *, double *, int *);
    int (*optimize_portfolio_multimodal_ex)(const double *, const double *, size_t, size_t,
                                            int, double, double, uint64_t, int, int, double *, double *, int *);
    int (*optimize_portfolio_multimodal_pareto)(const double *, const double *, size_t, size_t,
                                                int, int, uint64_t, int, int, double *, double *, double *, int *);
} FsqlEnterpriseApi;

/* One attempt per process. NULL when the enterprise surface is not live (no library
 * configured, refused by the signature check, or not an enterprise core). */
const FsqlEnterpriseApi *fsql_enterprise_ensure(void);

/* The operator-facing "requires the Enterprise tier" message for `function_name`. */
void fsql_enterprise_not_loaded_msg(const char *function_name, char *buf, size_t cap);

/* Authenticity gate for the reasoning plugin at `path`: 0 = trusted, -1 = refused with the
 * operator-facing reason in `err` (no "fractalsql: " prefix; the caller adds it). */
int fsql_plugin_gate(const char *path, char *err, size_t err_cap);

/* ------------------------------------------------------------------ */
/* Per-connection state (fsql_ledger.c)                                 */
/* ------------------------------------------------------------------ */

/* What belongs to ONE connection: a sovereign core context wired to an in-memory, hash-chained
 * ledger store, plus the one-way destructive latch and the diversify flag. Looked up in the
 * instance's registry by connection id (see fsql_duck.h). An fsql_ctx is documented not
 * thread-safe, so `mu` serialises every call into it. */
typedef struct FsqlConn {
    fsql_ctx           *ctx;                 /* NULL if the core context could not be created */
    fsql_storage_vfs_t  vfs;
    void               *store;               /* the ledger chains (opaque; fsql_ledger.c)       */
    fsql_mu_t           mu;
    int                 diversify_enabled;   /* mirrored here: the core has no getter           */
    int                 destructive_locked;  /* set by fractal_lock_destructive(); never cleared */
    int                 da_diversify;        /* the domain agents' own diversify flag (engines F, I)    */
} FsqlConn;

/* How a result chunk's vector column is laid out (LIST or ARRAY of DOUBLE/FLOAT), and the reader for one
 * of its rows: appends the row to `out` and returns 1; 0 = NULL vector (or NULL element); -1 = malformed.
 * fsql_vkind_of returns -1 for an unsupported column type. (fsql_agents.c) */
typedef struct { bool array; idx_t asz; duckdb_type child; } fsql_vkind;
int fsql_vkind_of(duckdb_vector v, fsql_vkind *k);
int fsql_read_vec_row(duckdb_vector v, const fsql_vkind *k, idx_t row, fsql_vecd *out, size_t *len);

/* The state for the calling connection. NULL only on out-of-memory. */
FsqlConn *fsql_conn_get(fsql_instance *inst, idx_t conn_id);

/* Fails the call with "fractalsql: <fn>: <what>" -- the wording of the C++ build's RunLedgerAction. */
void fsql_ledger_fail(duckdb_function_info info, const char *fn_name, const char *fmt, ...) FSQL_PRINTF(3, 4);

/* --- registration (each TU exposes one; the entry point calls them all) ---- */

bool fsql_search_register(duckdb_connection con, const char **err);       /* fractalsql_ext.c */
/* The rest are added as each TU is ported: */
bool fsql_vector_register(duckdb_connection con, const char **err);          /* fsql_vector.c         */
bool fsql_config_register(duckdb_connection con, const char **err);          /* fsql_config.c         */
/* bool fsql_reasoning_register(duckdb_connection con, const char **err);       fsql_reasoning.c      */
bool fsql_t2s_register(duckdb_connection con, const char **err);             /* fsql_t2s.c            */
bool fsql_vectorizer_register(duckdb_connection con, const char **err);        /* fsql_vectorizer.c     */
bool fsql_agents_register(duckdb_connection con, const char **err);          /* fsql_agents.c         */
bool fsql_domain_agents_register(duckdb_connection con, const char **err);     /* fsql_domain_agents.c  */
bool fsql_ledger_register(duckdb_connection con, const char **err);          /* fsql_ledger.c         */
bool fsql_sovereign_register(duckdb_connection con, const char **err);       /* fsql_sovereign.c      */

#endif /* FSQL_DUCKDB_INTERNAL_H */
