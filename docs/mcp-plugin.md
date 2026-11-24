<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# MCP Plugin

`fractalsql-ext-mcp` is a Model Context Protocol (MCP) server that gives an AI assistant the FractalSQL functions as **106 typed tools**.
It is a small standalone C++17 program that links `libduckdb` (DuckDB's C library), loads the FractalSQL extension into its own DuckDB, and then
**locks that DuckDB down** so that nothing a caller or a model-written statement does can read or write a file, fetch or load another extension, or change a setting.

```
assistant  --MCP (stdio or HTTP/TLS)-->  fractalsql-ext-mcp  [ libduckdb + the fractalsql extension, locked down ]  -->  your .duckdb file (or :memory:)
```

Each tool is one extension function: `fractal_search_telemetry` is `SELECT * FROM fractal_search_telemetry(...)`, `fractal_agent_regime_triage` is `fractal_agent_regime_triage(...)`, and so on.
The server's job is the part an assistant is bad at: it validates every argument before the engine sees it, binds numbers as typed lists with an explicit `CAST` on every parameter
(so DuckDB picks the right overload and nothing is ever spliced into SQL text), and turns structs, lists and table functions back into JSON. Tool names are the same wherever the same capability exists.

## Quick start

```bash
# libduckdb must match the DuckDB version the extension was built for (the version is in the extension's file name)
curl -LO https://github.com/duckdb/duckdb/releases/download/v1.5.6/libduckdb-linux-amd64.zip && unzip libduckdb-linux-amd64.zip -d libduckdb
make -C mcp DUCKDB_DIR=$PWD/libduckdb                 # needs a C++17 compiler and OpenSSL headers; builds mcp/fractalsql-ext-mcp

export LD_LIBRARY_PATH=$PWD/libduckdb
export FSQL_DUCKDB_EXTENSION=$PWD/dist/amd64/fractalsql.v1.5.6.linux_amd64.duckdb_extension
export FSQL_DUCKDB_DATABASE=$HOME/analytics.duckdb      # or leave unset for an in-memory database
mcp/fractalsql-ext-mcp --list-tools
```

Register it with an MCP client as a stdio server. For Claude Desktop (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "fractalsql-ext": {
      "command": "/path/to/fractalsql-ext-mcp",
      "env": { "LD_LIBRARY_PATH": "/path/to/libduckdb", "FSQL_DUCKDB_EXTENSION": "/path/to/fractalsql.v1.5.6.linux_amd64.duckdb_extension",
               "FSQL_DUCKDB_DATABASE": "/data/analytics.duckdb", "FSQL_DUCKDB_READ_ONLY": "true" }
    }
  }
}
```

## Opening DuckDB

| Variable | Default | Meaning |
| --- | --- | --- |
| `FSQL_DUCKDB_DATABASE` | `:memory:` | A database file, or `:memory:`. One database is opened per process and every MCP session gets its own connection to it (DuckDB allows one read-write opener per file, so run one server per file) |
| `FSQL_DUCKDB_EXTENSION` | none | A path to `fractalsql.*.duckdb_extension`, or empty for `LOAD 'fractalsql'` (an installed, signed copy) |
| `FSQL_DUCKDB_ALLOW_UNSIGNED` | on when `FSQL_DUCKDB_EXTENSION` is a path | Needed for a locally built, unsigned extension file |
| `FSQL_DUCKDB_BOOTSTRAP` | none | A SQL file run once, after the extension loads and **before** the lock-down: create tables, load data, `ATTACH` what you need |
| `FSQL_DUCKDB_READ_ONLY` | off | Open the database file read-only. Writes are refused by DuckDB itself |
| `FSQL_DUCKDB_LOCK_DOWN` | **on** | See below |
| `FSQL_DUCKDB_MEMORY_LIMIT` / `FSQL_DUCKDB_THREADS` | DuckDB's | e.g. `2GB`; 0 to 1024 threads |

The extension reads its own provider settings from this process's environment, exactly as in a DuckDB shell: `FRACTALSQL_REASONING_PLUGIN`, `FSQL_REASONING_HTTP_URL`, `FSQL_REASONING_HTTP_MODEL`,
`FSQL_REASONING_HTTP_EMBED_URL`, `FSQL_REASONING_HTTP_EMBED_MODEL`, `FRACTALSQL_ENTERPRISE_LIB` ([Reasoning Setup](reasoning-setup.md)). Without them the model-backed tools return a clean engine error naming what is missing.

The native libraries the extension loads are verified before they are used. The reasoning plugin must carry a detached Ed25519 signature (`<plugin>.sig`, beside it) from the FractalSQLabs reasoning-plugin signing key; the one setting below opts out of that check:

| Variable | Default | Meaning |
| --- | --- | --- |
| `FSQL_REASONING_REQUIRE_SIGNATURE` | `1` | Set to `0` to load a plugin that has no `.sig` (one warning goes to stderr), for a plugin you built yourself. A `.sig` that is present but wrong is always refused |
| `FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE` | `1` | Set to `0` to load an enterprise core library that has no `.sig` (one warning goes to stderr). A `.sig` that is present but wrong is always refused |

## Security model

- **The lock-down.** After the extension and the bootstrap are in, the server runs `SET autoinstall_known_extensions=false`, `SET autoload_known_extensions=false`, `SET enable_external_access=false` and `SET lock_configuration=true`.
  From then on `read_csv('/etc/passwd')`, `COPY ... TO`, `ATTACH`, `INSTALL`, `LOAD` and every `SET` are refused by the engine. This matters most for `fractal_sql_agent`, whose model-written statements run on this connection.
  `FSQL_DUCKDB_LOCK_DOWN=false` turns it off; do that only for a database and a model you fully trust.
- **Read-only.** `FSQL_DUCKDB_READ_ONLY=true` opens the file read-only, so even a destructive tool cannot write. `FSQL_MCP_READ_ONLY=true` additionally refuses every tool annotated destructive before it reaches the engine and latches the extension's destructive ledger functions on the connection.
- **No SQL from the caller.** There is no "run this SQL" tool. Strings are bound as parameters, table and column names are values the extension validates, and an injection-shaped table name is refused as an unknown table.
- **Untrusted data.** What an assistant sends is untrusted input and what it reads from your tables is a possible prompt-injection channel. Every argument is type-checked and bounded (arrays at 4 Mi elements, text at 4 MiB) and logs redact secrets and hash long strings.
- **HTTP.** `--http PORT` requires `FSQL_MCP_AUTH_TOKEN` (or `FSQL_MCP_AUTH_TOKEN_FILE`, re-read as it changes), binds `127.0.0.1` unless told otherwise, and with `FSQL_MCP_HTTP_TLS=true`, `FSQL_MCP_TLS_CERT` and `FSQL_MCP_TLS_KEY` serves TLS only and refuses to start on a bad certificate rather than fall back to plaintext. `FSQL_MCP_TOKEN_POLICY_FILE` adds per-client credentials. See [Authentication](#authentication).
- **The destructive surface.** Every tool marked `destructiveHint: true` carries it, and that annotation is locked: `mcp/.mcp-safety-annotations-lock` is a committed fingerprint of every tool's safety annotations, and a change to any of them stops the server (exit 3) until the lock is regenerated on purpose. Read-only mode refuses those calls before they reach the engine — the rule is the annotation, not a fixed list, so the set follows the catalog.

## Authentication

On the HTTP transport a bearer token is the credential. Over stdio there is none: the client spawns the server as a trusted subprocess and speaks to it over its own pipes.

**The deployment token.** `FSQL_MCP_AUTH_TOKEN` is one secret for the whole deployment; every holder of it is the same identity. `FSQL_MCP_AUTH_TOKEN_FILE` holds the same secret in a file and is re-read whenever that file's timestamp changes, so a secrets manager can rotate it in place without a restart. The HTTP transport refuses to start without one.

**Per-client credentials.** `FSQL_MCP_TOKEN_POLICY_FILE` points at a JSON file that names clients, so each caller can be revoked on its own and can be given its own tool allowlist:

```json
{
  "tokens": [
    { "name": "analyst", "sha256": "<hex sha256 of that client's token>",
      "tools": ["fractal_sfs_converge", "fractal_agent_data_analyst"],
      "expires": "2027-01-31T00:00:00Z" },
    { "name": "batch", "sha256": "<hex sha256>", "tools": "*" }
  ]
}
```

The file holds the SHA-256 of each token, never the token itself, so it is safe to keep in a config store or a repository. A client that presents its own token *is* that client: its name is its fairness key (the per-client concurrency share) and its allowlist bounds what it can call. `expires` is optional and is an ISO-8601 date or date-time; an expired credential is refused. `tools` is either `"*"` or a list of tool names. A policy file that cannot be read or parsed at startup stops the server; a later replacement that is malformed leaves the last good policy in place — a typo never widens access.

What the server does with a request that arrives at the JSON-RPC path:

| Situation | Answer |
| --- | --- |
| No token, or a token that matches nothing | `401` with `WWW-Authenticate: Bearer realm="fractalsql-mcp"` |
| A token that was presented but refused, including an expired one | `401` with `WWW-Authenticate: Bearer realm="fractalsql-mcp", error="invalid_token"` |
| A token in the query string instead of the `Authorization` header | `401` — the `Authorization` header is the only place a credential is read from, because a query string ends up in proxy logs and browser history |
| A browser `Origin` header that this deployment does not allow | `403`, checked **before** the token, so an unapproved origin never reaches the credential check; a loopback origin is `localhost`, `[::1]` or a literal address in `127.0.0.0/8` — a name that merely begins with `127.` is not one |
| A chunked request body | `411` — send a `Content-Length` instead |
| A declared `Content-Length` over 32 MB | `413` |
| A repeated `Content-Length`, or one that is not a number | `400` — the framing is ambiguous and is never resolved in favour of one reading |
| A repeated `Host`, `Authorization`, `Origin`, `Content-Type` or `Mcp-*` header | `400` — two values for a header the server acts on are never resolved in favour of one |
| `GET /healthz` and `GET /readyz` | served without a token; `/readyz` runs its engine probe at most once every 5 seconds and answers the cached result in between |

Repeated failed authentications are slowed down (the wait grows with the number of consecutive failures, capped at about two seconds), so guessing a token is not free. The comparison itself is constant-time, and no token is ever written to a log line.

There is no request-signing scheme, and that is deliberate: a standard MCP client cannot sign its requests, so making a signature mandatory would break every client while a replay of a captured request stays possible either way. The controls that do work are the ones a deployment can actually operate: a token that can be rotated without downtime, credentials that can expire, credentials that can be revoked one client at a time, and per-client allowlists that bound what a leaked token can reach.

## Protocol versions

The server speaks both protocol eras at once, and the era a call arrived in is on the operator's log line for that call.

**The legacy era** is the handshake-based one: `initialize` first, an `Mcp-Session-Id` for the calls that follow, and the protocol revision carried in the handshake. The revisions served are `2024-11-05`, `2025-03-26`, `2025-06-18`, `2025-11-25` and `2026-07-28`.

**The modern era** is the stateless one: every request carries its own metadata, and there is no protocol session at all. A modern request must carry `MCP-Protocol-Version` and `Mcp-Method`, and, for the methods that address something by name (`tools/call`, `prompts/get`, `resources/read`), `Mcp-Name`; the headers have to agree with the body.

| Mismatch | Answer |
| --- | --- |
| A required header is missing, or a header disagrees with the body | `-32020` (HeaderMismatch), HTTP `400` |
| The revision is not one this server serves | `-32022` (UnsupportedProtocolVersionError), HTTP `400`, with `data.supported` (the revisions served) and `data.requested` (the one asked for) |
| A method this server does not have | `-32601`, HTTP `404` |

The modern era also adds the discovery method `server/discover`, and every result carries `resultType` (`complete`), `ttlMs` and `cacheScope`.

`FSQL_MCP_PROTOCOL_ERA` chooses what is served: `dual` (the default) serves both, `modern` serves the modern era only and refuses the legacy handshake (and answers `GET` and `DELETE` with `405`). The tools, the arguments and the results are the same in both eras; only the framing differs.

## Session state

Two kinds of server-side state exist, and both are bounded.

A **context handle** (`context_id`) is an opaque 128-bit hex string the server mints. A caller of a context-scoped tool that names no handle gets one back with the result — the `context_id` field of the `tools/call` result — and a caller that passes one back keeps using the same engine state. The handle is bound to the credential that created it: a different token is told the handle does not exist, so a client can neither use nor probe for a handle it does not own. In the legacy era there is no handle to pass: the protocol session supplies the context, and a `context_id` naming a different one is refused.

| Setting | Default | What it bounds |
| --- | --- | --- |
| `FSQL_MCP_SESSION_TTL_SECS` | 3600 | How long an idle handle survives. |
| `FSQL_MCP_MAX_SESSIONS` | 64 | How many handles exist at once. |

Each handle owns a DuckDB connection of its own, so the state is dropped in one of four ways: the handle goes idle for longer than `FSQL_MCP_SESSION_TTL_SECS` and is evicted together with its connection; the server is shut down, which drops every handle and closes every connection after the drain window; a legacy session is closed with `DELETE /mcp` carrying its `Mcp-Session-Id` (the modern era has no session to tear down, so `DELETE` is refused); or the cap is reached, in which case a request that needs a new handle is refused rather than served.

## How arguments map

| You send | The server binds |
| --- | --- |
| a JSON array of numbers | a `DOUBLE` list (strings that parse as numbers are accepted; `NaN`, `Infinity` and non-numbers are refused, naming the element), cast to the function's `DOUBLE[]` or `FLOAT[]` |
| an array of equal-length arrays | the rows flattened row-major; the row width becomes the `dim` argument when you leave it out |
| an array of integers (faces, edges) / strings (table names) | a `BIGINT[]` / `VARCHAR[]` |
| a hex string, or an array of hex strings | a `BLOB` / `BLOB[]` |
| a JSON object (`context`, `options`, `payload`, `meta_filter`) | its JSON text |
| text, integers, numbers, booleans | the same type, with an explicit `CAST` |

Optional arguments you skip are left off. An optional argument that sits before one you did give is filled with its documented default, or with `NULL` for an optional text column; where there is no default the call is refused (`X is required when a later optional argument is given`).
A few arguments only make sense together (`filter_col` needs `filter_val`) and are checked before the engine is called.

Results are always a JSON object: a struct as its fields, a number or string as `{"value": ...}`, a vector as `{"vector": [...], "dim": n}`, a list as `{"items": [...]}`, raw bytes as `{"hex": ..., "bytes": n}`, and a table function as `{"rows": [...], "row_count": n}`.
Table functions take an optional `limit` (default 100, ceiling `FSQL_MCP_MAX_ROWS_CEILING`, default 1000); a result cut short carries `"truncated": true`.

## Errors

| `error_class` | Meaning | Examples |
| --- | --- | --- |
| `schema` | The call was refused before anything ran | wrong type, missing argument, non-numeric element, `limit` over the ceiling, read-only mode |
| `engine` | It reached DuckDB or the extension and was refused | a table that does not exist, "reasoning plugin not configured", "requires the FractalSQL Enterprise tier", a permission error from the lock-down |
| `connectivity` | The database or a provider could not be reached | the extension would not load, the database file is locked or unreadable, an endpoint timed out |
| `cancelled` | The client sent `$/cancel` | |
| `server` | A bug in this server; the detail is logged, never sent | |

## Tools

The catalog below is generated from the server (`tools/list`). The flags are the MCP annotations sent for every tool.

Each tool's arguments are described by the `inputSchema` the server publishes in `tools/list`; that schema is the source of truth, and the schema lock hashes it, so a change to any tool's arguments shows up as a lock change.


### Discovery (search, telemetry, diversification)

| Tool | What it does | Flags |
| --- | --- | --- |
| `fractal_cross_modal_search` | Weighted concatenation of two modality vectors (e.g. | read-only |
| `fractal_detect_collapse` | Current diversity quotient (D_q) for THIS session from the last search. | read-only |
| `fractal_diversify_disable` | Turns the Diversify/Repulsion layer back off for THIS session. | writes state |
| `fractal_diversify_enable` | Turns on the stateful Diversify/Repulsion layer for THIS session: searches then avoid the neighbourhoods of negative-reported results ('shadows'). | writes state |
| `fractal_diversify_set_params` | Tunes the repulsion layer for THIS session. | writes state |
| `fractal_explain_result` | Session-level Diversify diagnostics JSON: {dq, diversify_enabled, overhead_p99_us}. | read-only |
| `fractal_feedback_report` | Reports dwell/positive/negative engagement on a prior search result, feeding the shadow store when Diversify is enabled. | writes state |
| `fractal_hybrid_clinical_search` | Cohort-restricted sibling of fractal_search_telemetry: pass an explicit JSON array of rowid locators to restrict the scan before ranking. | read-only |
| `fractal_isolate_background` | Convenience wrapper for fractal_feedback_report(result_handle,'negative') with no dwell time: reject the result's neighbourhood outright. | writes state |
| `fractal_sfs_converge_debug` | Same Sniper convergence as fractal_sfs_converge with a full trajectory trace: {dim, generations, population_size, best_point, best_fit, best_fit_per_gen, paths}. | read-only |
| `fractal_search_explore` | Scout-mode diverse population search: brute-force relevance scan over your embedding column followed by MMR re-ranking to prevent mode collapse; the anti-collapsed-top-K primitive. | read-only |
| `fractal_sfs_converge` | Raw Stochastic Fractal Search: the refined best point for a query, with no table. | read-only |
| `fractal_search_telemetry` | Ground-truth K-nearest real table rows to a query vector, by exact cosine distance: [{doc_id, distance, scan_pos}]. | read-only |
| `fractal_search_trajectory` | Drift-vector search: finds the K nearest rows to (current_vector - baseline_vector) : 'what changed', not 'where am I'. | read-only |
| `fractal_search` | The indexed search: probes the IVF index built by fractal_index_create and verifies every candidate against the stored vectors, so every distance it returns is exact. Falls back to an exact scan when the table has no index. It does not apply Diversify repulsion. | read-only |
| `fractal_index_create` | Builds the IVF index over a table's embedding column and stores it in the database; samples rows to calibrate the default nprobe. | writes state |
| `fractal_index_ensure` | One call that leaves the index on a table and column fit to use: builds it when missing, folds in a few added rows, rebuilds after large changes, and otherwise changes nothing. For a setup script or a scheduled job. |
| `fractal_index_rebuild` | Full re-cluster from the table's current rows, as a new generation switched in atomically. | writes state |
| `fractal_index_drop` | Deletes the index's stored cells and metadata; the table and its vectors are untouched. | writes state |
| `fractal_index_info` | The index's format, dimension, cells, rows indexed against now, the delta and stale flags, the calibrated nprobe and the last search's statistics. | read-only |
| `fractal_index_candidates` | The candidate row ids for a Scout pass over an indexed table: every row of the nearest cells, plus representatives from the other cells, plus the rows added since the build. | read-only |

### Cognition (needs a reasoning plugin or an embedding provider)

| Tool | What it does | Flags |
| --- | --- | --- |
| `fractal_embed` | Embed text with the configured embedding model; returns the vector. | model |
| `fractal_reason` | Send a question (and optional context) to the configured reasoning model. | model |
| `fractal_schema_context` | The schema (tables, columns, keys, comments) as text, for composing text-to-SQL questions. | read-only |
| `fractal_sql_agent` | Text-to-SQL with review and (only when auto_execute is true) execution of the generated statement under this connection. | **destructive**, model |
| `fractal_text_to_sql` | Generate one validated SELECT from a question. | model |

### Agency (the agents)

| Tool | What it does | Flags |
| --- | --- | --- |
| `fractal_agent_allocate` | Cardinality-constrained portfolio optimisation, then a written rationale. | model |
| `fractal_agent_anomaly_triage` | Drift on one entity's metric series read from a table, then a model-written triage summary. | model |
| `fractal_agent_data_analyst` | Natural-language question over your tables: the model writes SQL, the engine validates and runs it, and the model analyses the rows. | model |
| `fractal_agent_detect_loop` | SimHash + Brent cycle-detection safety monitor for an agent's own behavior. | read-only |
| `fractal_agent_detour_classify` | Classify a vehicle detour: nearest fleet peer by route change plus the box-counting complexity of its GPS trace, with a written verdict. | model |
| `fractal_agent_diverse_portfolios` | Enterprise: several mutually different near-optimal portfolios (sharpe) or the return-versus-risk front (pareto), with a written comparison. | model |
| `fractal_agent_feedback_audit` | Self-contained Diversify health-check cycle, NO LLM step: enable repulsion, warm the D_q window, report negative feedback on the top result, read back diagnostics, then SELF-DISABLE (a complete audit cycle). | writes state |
| `fractal_agent_network_coverage_alert` | Sensor-grid coverage: morphological dimension and lacunarity of the point cloud plus drift in the telemetry, then an alert. | model |
| `fractal_agent_outlier_intercept` | Intercept a proposed state that is too close to a known-bad one. | model |
| `fractal_agent_patient_deterioration_triage` | Cohort search plus the drift from baseline to current, then a written triage. | model |
| `fractal_agent_plan_explore` | Embed a seed state and branch it into the nearest strategies (rows). | model |
| `fractal_agent_rebalance_sibling` | Optimise a portfolio, find the most similar past allocation by weight change, and explain the rebalance. | model |
| `fractal_agent_recall_hybrid` | Pure retrieval, no model: the nearest memories to a query, optionally within a cohort. | read-only |
| `fractal_agent_recommend_diverse` | Repulsion-diverse top-k recommendations, NO LLM step: enables session Diversify, then repulsion-aware top-k so re-searches avoid recently-rejected items. | writes state |
| `fractal_agent_regime_triage` | General-purpose regime check on any series: DFA exponent and drift, then a written triage. | model |
| `fractal_agent_route_task` | Route a task to the nearest capability under a token budget, with a written justification. | model |
| `fractal_agent_schedule_workload` | Place a workload on the nearest node by capability vector, with a written justification and confidence. | model |
| `fractal_agent_track_anomaly` | Track deviation check: nearest peer plus the DFA exponent of the heading series, with a written assessment. | model |
| `fractal_agent_trajectory_predict` | Project the next state: the drift since a baseline row applied to the current state (rows). | writes state |
| `fractal_rag_agent` | Retrieval-augmented answer over a table (rows: answer, source_row_ids, used_index, context_cut): `meta_filter` limits the rows searched. | model |
| `fractal_search_agent` | Embed a question, search a table, and answer from the hits (rows). | model |

### Analytics (series, geometry, optimisation, vector math)

| Tool | What it does | Flags |
| --- | --- | --- |
| `fractal_change_point_detect` | DFA's complement: localizes WHERE a series' mean and/or variance shifted, via a sliding two-sample test over adjacent windows. | read-only |
| `fractal_cortical_folding` | Gyrification Index (Zilles et al. | read-only |
| `fractal_cycle_detect` | Find a cycle in a stream of fingerprints (Brent), tolerating a few differing bits (rows). | read-only |
| `fractal_dimension_boxcount` | Minkowski-Bouligand box-counting dimension of a point cloud. | read-only |
| `fractal_dimension_dfa` | DFA scaling exponent (alpha): ~0.5 uncorrelated noise, ~1.0 1/f pink noise, ~1.5 Brownian motion, <0.5 anti-correlated. | read-only |
| `fractal_dimension_drift` | Regime-change detection: DFA exponent of the recent window vs the baseline. | read-only |
| `fractal_morphological_complexity` | Box-counting dimension + lacunarity of a pre-segmented mask. | read-only |
| `fractal_nerve_plexus_metric` | Nerve-fiber plexus density + dimension from pre-extracted skeleton geometry (corneal confocal microscopy convention). | read-only |
| `fractal_optimize_portfolio_multimodal_pareto` | Pareto-front sibling: same restarts, scored by decomposed (return,risk), NSGA-II crowding-distance truncated. | read-only |
| `fractal_optimize_portfolio_multimodal` | Multi-restart diverse-candidate sibling of fractal_optimize_portfolio. | read-only |
| `fractal_optimize_portfolio` | SFS cardinality-constrained Sharpe-ratio maximizer: the best K assets out of a large universe without brute-force exponential cost. | read-only |
| `fractal_optimize_subset` | Value-weighted k-subset allocation over ANY scored item list: maximize sum(weight[i]*item_values[i]) with at most k nonzero, each weight<=upper_bounds[i], summing to 1.0. | read-only |
| `fractal_periodogram` | Classical periodogram via exact O(n^2) DFT (not FFT). | read-only |
| `fractal_chunk_text` | Splits text into chunks of at most chunk_size characters: `[{no, start, end, text}]`. Pure, no model. | read-only |
| `fractal_spectrogram_entropy` | Short-time spectral entropy: slides a window over a series and returns, per frame, the normalized Shannon entropy (0..1) of its power spectrum (mean removed, Hann tapered). | read-only |
| `fractal_state_fingerprint` | Random-hyperplane SimHash (Charikar 2002) of a state vector, returned as a hex string, (n_bits+7)/8 bytes. | read-only |
| `fractal_tda_persistence_diagram` | Topological persistence over a point cloud's Vietoris-Rips filtration. | read-only |
| `fractal_vascular_network` | Vessel-network tortuosity + branch-density + fractal dimension from PRE-EXTRACTED graph geometry (not raw imaging). | read-only |
| `fractal_vector_add` | The element-wise sum of two vectors, as a JSON array of numbers. | read-only |
| `fractal_vector_cosine_distance` | The cosine distance between two vectors: 0 when they point the same way, 1 when they are orthogonal. | read-only |
| `fractal_vector_cosine_similarity` | The cosine similarity between two vectors: 1 when they point the same way, 0 when they are orthogonal. | read-only |
| `fractal_vector_dims` | The vector's dimension: how many components it has. | read-only |
| `fractal_vector_from_text` | Builds the canonical vector from an array of numbers. On DuckDB the vector is a plain list of floats, so the input is the array itself. | read-only |
| `fractal_vector_l2_distance` | The L2 (Euclidean) distance between two vectors. | read-only |
| `fractal_vector_l2_squared` | The squared L2 distance: the same measure without the square root. | read-only |
| `fractal_vector_norm` | The vector's L2 norm (its magnitude). | read-only |
| `fractal_vector_normalize` | The vector scaled to unit length. | read-only |
| `fractal_vector_scale` | The vector multiplied by a scalar factor. | read-only |
| `fractal_vector_sub` | The element-wise difference of two vectors. | read-only |
| `fractal_vector_to_json` | Renders a vector as JSON: the array of numbers. | read-only |
| `fractal_vector_hamming_distance` | Hamming distance between two binary-quantized vectors (hex strings). | read-only |
| `fractal_vector_lp_distance` | Generalized L_p distance, any p > 0. | read-only |
| `fractal_vector_quantize_binary` | 1-bit (sign) quantization: 32x compression, (dim+7)/8 bytes, MSB-first, returned as a hex string. | read-only |
| `fractal_vector_quantize_int8` | Symmetric int8 quantization of one vector (4x compression). | read-only |

### Enterprise (ledger and audit; need the enterprise library)

| Tool | What it does | Flags |
| --- | --- | --- |
| `fractal_audit_log` | Append a record to the tamper-evident decision-audit chain. | writes state |
| `fractal_audit_unpack` | Decode a persisted audit blob (hex) into its JSON. | read-only |
| `fractal_ledger_compact` | Compact the ledger. | **destructive** |
| `fractal_ledger_flush` | Persist the ledger to its file. | **destructive** |
| `fractal_ledger_load` | Load the persisted ledger into memory. | writes state |
| `fractal_ledger_reset_hard` | Erase the ledger entirely. | **destructive** |
| `fractal_ledger_reset_soft` | Clear the in-memory shadow state, keeping the truth ledger. | **destructive** |
| `fractal_ledger_shadow_count` | Entries in the shadow ledger. | read-only |
| `fractal_ledger_truth_count` | Entries in the truth ledger. | read-only |
| `fractal_ledger_verify` | Walks the ENTIRE chain for the given kind (O(n)). | read-only |

### Vectorizer

| Tool | What it does | Flags |
| --- | --- | --- |
| `fractal_vectorizer_create` | Register a vectorizer on a table column and backfill its queue with the rows that need embedding. | writes state |
| `fractal_vectorizer_drop` | PERMANENT AND IRREVERSIBLE: deregisters the vectorizer, drops its trigger and deletes its config/queue history. | **destructive** |
| `fractal_vectorizer_pause` | Disables a vectorizer (idempotent). | writes state |
| `fractal_vectorizer_process_queue` | Drives the actual embedding sync: call on your own schedule; there is NO background worker in any engine, by design. | writes state |
| `fractal_vectorizer_resume` | Re-enables a paused vectorizer. | writes state |
| `fractal_vectorizer_status` | One row per vectorizer: its source, progress and failures. | read-only |

### Admin

| Tool | What it does | Flags |
| --- | --- | --- |
| `fractal_version` | The extension version and edition, the DuckDB version it is running in, and this MCP server's version. | read-only |
| `fractal_config_get` | The current value of one configuration key. A secret is reported as `***` and never read back. | read-only |
| `fractal_config_keys` | Every configuration key as `{name, type, session_overridable}` (`string`, `path`, `int`, `bool` or `enum`), so a caller can list the keys instead of hard-coding them. | read-only |
| `fractal_config_set` | Change one configuration key. Refused unless `FSQL_MCP_CONFIG_WRITES` allows it. | **destructive** |
| `fractal_configure_reasoning` | Change the reasoning settings in one call: the provider URL, the embedding URL, the chat model, the embedding model and the think mode. | **destructive** |

**The configuration these tools change.** The DuckDB edition of the extension has no `SET fractalsql.*` options: it is configured through the process environment (`FRACTALSQL_REASONING_PLUGIN`, `FSQL_REASONING_HTTP_*`, `FRACTALSQL_ENTERPRISE_LIB`), the same way an operator configures it on the command line. Two SQL functions are the named way to read and change that configuration from inside the engine:

```sql
SELECT fractal_config_get('http_model');            -- the value, or NULL when it is not configured
SELECT fractal_config_set('http_model', 'gpt-oss:20b');
SELECT fractal_config_set('http_model', '');        -- an empty value unsets it
```

The write goes to the process environment, so it is visible to the extension's own `getenv()` on the very next call and to every connection the process opens, and it is gone when the process exits. The keys are `reasoning_plugin`, `http_url`, `http_model`, `http_embed_url`, `http_embed_model`, `http_think`, `http_think_provider`, `http_native_url`, `http_num_ctx`, `http_response_mode`, `http_allow_plaintext`, `http_token`, `enterprise_lib`, `enterprise_require_signature`, `ledger_retention`, `agent_use_index`, `agent_index_min_rows`, `agent_context_row_bytes`, `text_to_sql_allowed_statements` and `text_to_sql_use_review`. `agent_use_index` is `off` (the default), `on` or `auto`: the retrieval and nearest-row agents search through a `fractal_index`, and `auto` only when the index is ready and the table has at least `agent_index_min_rows` rows. `enterprise_require_signature` can only be turned `on` from SQL; turning the signature requirement off is an operator setting (`FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0` in the environment). `text_to_sql_allowed_statements` is `select` (the default) or `select_insert_update`, and `text_to_sql_use_review` is `on` or `off`. The other hosts' text-to-SQL attempt limit and ledger-key settings do not apply here: `fractal_text_to_sql` makes 3 attempts, `fractal_sql_agent` takes its limit as an argument, and the ledger is held in memory. An unknown key is refused rather than passed through to the environment. `http_token` is a credential: it can be set, but `fractal_config_get` refuses it, so no `SELECT`, no tool and no log can turn it into output.


## Resources and prompts

| Resource | Contents |
| --- | --- |
| `fractalsql://agents` | Which agent to use for which problem, and which need a model |
| `fractalsql://schema` | The live output of `fractal_schema_context()`: the tables, columns, keys and comments this connection can see |
| `fractalsql://config` | Extension and DuckDB versions, whether the database is read-only or locked down, which provider settings are present (as booleans), whether the enterprise tier is loaded. Never a token, key or URL |
| `fractalsql://ledger/{kind}` | The ledger audit report |

Eleven prompts cover the common flows (`incident_triage`, `portfolio_rebalance`, `patient_triage`, `fleet_detour_check`, `track_anomaly_check`, `sensor_grid_health`, `churn_recovery`, `ask_my_data`, `safe_sql_question`, `diversity_audit`, `ciso_ledger_check`).

## Operating it

Every environment variable the server reads, and what it does.

**The transport and the credentials**

| Setting | Default | |
| --- | --- | --- |
| `FSQL_MCP_HTTP_PORT` | 8765 | The port `--http` listens on |
| `FSQL_MCP_BIND` | `127.0.0.1` | The address to bind. A non-loopback address needs TLS, or `FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK=true` |
| `FSQL_MCP_HTTP_PATH` | `/mcp` | The path the JSON-RPC endpoint answers on |
| `FSQL_MCP_HTTP_TLS` | off | Serve TLS in this process. With `FSQL_MCP_TLS_CERT` and `FSQL_MCP_TLS_KEY` |
| `FSQL_MCP_TLS_CERT` / `FSQL_MCP_TLS_KEY` | none | The certificate and its key, PEM |
| `FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK` | off | Accept a plaintext bind on a network you control |
| `FSQL_MCP_AUTH_TOKEN` | none | The bearer token for the HTTP transport. The HTTP transport refuses to start without one |
| `FSQL_MCP_AUTH_TOKEN_FILE` | none | The same token in a file, re-read as the file changes |
| `FSQL_MCP_TOKEN_POLICY_FILE` | none | Per-client credentials and their tool allowlists |
| `FSQL_MCP_ALLOWED_ORIGINS` | none | Extra browser origins, comma-separated. Loopback origins are allowed by default |
| `FSQL_MCP_MAX_CONNECTIONS` | 256 | Connections served at once |
| `FSQL_MCP_MAX_SESSIONS` | 64 | Session-state handles alive at once |
| `FSQL_MCP_SESSION_TTL_SECS` | 3600 | How long an idle handle survives |
| `FSQL_MCP_SHUTDOWN_DRAIN_MS` | 5000 | How long shutdown waits for in-flight calls |

**The protocol**

| Setting | Default | |
| --- | --- | --- |
| `FSQL_MCP_PROTOCOL_ERA` | `dual` | `dual` serves both protocol eras, `modern` serves the modern era only |

**The catalog**

| Setting | Default | |
| --- | --- | --- |
| `FSQL_MCP_TOOL_WHITELIST` / `--tool a,b`, `FSQL_MCP_ENABLED_CATEGORIES` / `--category x,y` | all | Narrow the catalog |
| `FSQL_MCP_SCHEMA_LOCK` | `mcp/.mcp-schema-lock` | The catalog fingerprint the server compares against at startup |
| `FSQL_MCP_SAFETY_LOCK` | `mcp/.mcp-safety-annotations-lock` | The fingerprint of the tools' safety annotations |
| `FSQL_MCP_MANIFEST` | `mcp/manifest.json` | The tool manifest |
| `FSQL_MCP_STRICT_SCHEMA_HASH` | `true` | Refuse to start if the catalog differs from the schema lock; set `false` to warn instead |
| `FSQL_MCP_ALLOW_MISSING_LOCKS` | off | Run without the drift check (development only). `FSQL_MCP_REQUIRE_LOCKS=false` has the same effect |

**What a call may do**

| Setting | Default | |
| --- | --- | --- |
| `FSQL_MCP_READ_ONLY` | off | Refuse every tool annotated destructive, and latch the engine's destructive ledger functions on the connection |
| `FSQL_MCP_ALLOW_AUTO_EXECUTE` | off | Let a model ask for `auto_execute=true` on the tools that take it |
| `FSQL_MCP_CONFIG_WRITES` | `safe` | Which configuration a config-writing admin tool may change: `off` (nothing is writable), `safe` (the chat model name, the embedding model name and the think mode only), `all` (any key). The endpoint URLs, the plugin path, the token and the enterprise library are outside the safe set at every level but `all` |
| `FSQL_MCP_MAX_ROWS_CEILING` | 1000 | Largest `limit` a table-function tool accepts |
| `FSQL_MCP_STATEMENT_TIMEOUT_MS` | 600000 | Interrupt any single statement that runs longer than this many milliseconds (`0` disables). The default is generous because reasoning calls run inside SQL. |
| `FSQL_MCP_MAX_CONCURRENT_CHEAP` / `FSQL_MCP_MAX_CONCURRENT_EXPENSIVE` / `FSQL_MCP_MAX_CONCURRENT_EXPENSIVE_PER_CLIENT` | 50 / 5 / 2 | Concurrency caps. Each is a whole number of at least 1; anything else, including 0, makes the server refuse to start rather than hang every call |
| `FSQL_MCP_MAX_QUEUE_WAIT_MS` | 900000 | How long a call waits for a slot before `server busy` |
| `FSQL_MCP_LOG_LEVEL` | `normal` | `verbose` adds debug lines. One JSON line per tool call on stderr, arguments redacted and capped |

**The audit chain (read by the extension, not by the server)**

| Setting | Default | |
| --- | --- | --- |
| `FSQL_LEDGER_ANCHOR_LOG` | `off` | `stderr` or `syslog`: publish the head of the chain on every append |
| `FSQL_AUDIT_REDACT` | `none` | `hash` or `truncate`: what the audit chain keeps instead of the text |
| `FSQL_DUCKDB_LEDGER_MAX_BYTES` | 256 MiB | The size past which appends to the chain are refused (`0` = unbounded) |

`--list-tools`, `--write-schema-lock`, `--write-safety-annotations-lock` and `--write-manifest` run without a database. The safety-annotation lock is always enforced: a change to any tool's destructive, read-only or idempotent hint stops the server (exit 3) until the lock is regenerated on purpose.

**The catalog is data.** `mcp/tools.spec.json` lists every function with its parameters; `python3 mcp/scripts/gen_spec_inc.py` regenerates the compiled-in copy. A new extension function is one new entry.

**Cancellation.** `$/cancel` calls `duckdb_interrupt` on the session's connection. DuckDB stops its own work at once; a function that is deep inside the extension's C code (a long search) finishes its current step first.

**Platforms.** Linux and macOS with a matching `libduckdb`. The extension and `libduckdb` must be the same DuckDB version. On macOS the server uses Homebrew's OpenSSL (`brew install openssl@3`); the release bundle ships `libduckdb.dylib` beside it, and the extension itself does not need OpenSSL.

## Data at rest

What a deployment leaves behind, and where.

**The database file.** The tables the assistant reads and, when the vectorizer is used, the `fractal_vectorizers`, `fractal_vectorizer_queue` and `fractal_vectorizer_rate` tables that hold the vectorizer registry, its embedding queue and its rate counters. This is the object to protect: give the file the same protection as the data it holds (permissions only its owner can read, and encryption at rest on the volume when the data warrants it).

**The ledger and audit chain.** In this engine the chain is held in memory: each connection keeps its own append-only chain of entries, and each entry carries the SHA-256 of the one before it, so the chain verifies on its own with `fractal_ledger_verify()`. Three things follow, and they are worth stating plainly.

- **There is no separate ledger file and no CSV mirror.** Nothing about the chain is written to disk, so there is no ledger file to protect and no file whose permissions could be set. The chain lives and dies with the process: when the server exits, the chain goes with it.
- **There is no separate head record with its own MAC.** Where the chain is a file, a head record can be kept outside it, so that deleting the tail is detectable. Here the head *is* the newest entry in memory, and nothing a SQL statement can reach holds a copy of it: whoever can write to the database cannot reach the chain at all, so a separate head record would only duplicate state the chain already protects. The protection against a truncated chain is therefore published off-host, which is what the anchor log is for.
- **The head can be published to a log you control.** With `FSQL_LEDGER_ANCHOR_LOG=stderr` (or `syslog` where the platform has one) the extension emits one JSON line on every append:

```json
{"event":"ledger_head","kind":2,"rows":17,"hash":"<hex of the newest entry hash>"}
```

`kind` is the chain that was appended to (1 is the truth-and-shadow chain, 2 the decision-audit chain), `rows` is how many entries that chain holds after the append, and `hash` is the newest entry hash. A chain whose tail was dropped no longer matches the last line published, so a truncation is visible from the log even though it is invisible from the engine alone.

**The text of an audit entry can be redacted.** The question an agent was asked, the SQL it generated, the analysis it wrote and the rows it read can all carry customer data. `FSQL_AUDIT_REDACT` decides what the chain keeps:

| `FSQL_AUDIT_REDACT` | What is stored |
| --- | --- |
| `none` (default) | The text, as it is. |
| `hash` | `sha256:<hex> len=<bytes>` — the fingerprint of the text and its length, so equal texts stay comparable and the length is known, but the text is not. |
| `truncate` | The first 64 characters of the text. |

Redaction reaches the fields nested inside the entry as well as the entry itself, and leaves everything else alone: identifiers, counts, statuses and the attribution block are stored as they are. The values returned to the caller are never redacted — the agent still answers with the real question, the real SQL and the real analysis; only what is persisted changes. For a deployment that handles customer data, `FSQL_AUDIT_REDACT=hash` is the setting to turn on.

**The credentials.** The bearer token lives in the environment, or in the file `FSQL_MCP_AUTH_TOKEN_FILE` names; the per-client credential file holds the SHA-256 of each token and never the token itself. Nothing else in the deployment stores a secret.

**A configuration write leaves nothing behind.** The admin tools change the process environment of the server, not a file: a setting written through `fractal_config_set` or `fractal_configure_reasoning` lives in that process, is seen by every connection the process opens, and is gone when the process exits. Nothing about it is written to disk, so there is no configuration file to protect and no permission to set on one.

**The catalog locks.** `mcp/.mcp-schema-lock` and `mcp/.mcp-safety-annotations-lock` are committed fingerprints of the tool catalog and of its safety annotations. They say nothing about the deployment, only about the shape of the tools.

**Encryption at rest.** Confidentiality of the database file comes from the volume or the disk underneath it, or from DuckDB's own file encryption: DuckDB 1.4 and later can encrypt a database file (`ATTACH 'analytics.duckdb' (ENCRYPTION_KEY '...')`, which needs storage format v1.4.0 or later). This server opens its database by path and passes no key, so an encrypted file is not one it can open; protect the file it opens with volume encryption.

## Testing

`./build_test.sh` includes an MCP suite. It builds the server and runs the unit probes (error classification; parameter binding for every kind including the empty list; the lock-down; interrupt; the shared database handle; argument coercion; the concurrency caps; secret redaction);
runs a full MCP session (every tool once, the numbers the tools must produce, row limits, the error taxonomy, resources, prompts, read-only mode, a database file persisted and then opened read-only, `$/cancel`, shutdown)
followed by a framing/robustness sweep and a sweep that mutates one argument of every tool; drives the HTTP transport over TLS; and starts the server in 139 different ways.
A conformance driver runs the server the way real client stacks shape their requests -- in both protocol eras, with and without a bearer token, in read-only mode, with the operator switches on and off, over HTTP and over stdio -- and checks the framing, the authentication, the origin rule, the catalog's shape and the session handles against the published rules. The suite needs `libduckdb`
(`FSQL_LIBDUCKDB_DIR`, or it is fetched for the extension's DuckDB version). Under `--asan` / `--ubsan` the server itself is built instrumented and its output is checked for sanitizer reports (with ASan's
allocator-mismatch check off). `./build_test.sh --tsan` builds the server under ThreadSanitizer and runs the MCP suite against it, and `./build_test.sh --coverage` prints
per-file line coverage of the server's sources. Both cover the server only: DuckDB's own frames and the prebuilt extension are not instrumented, so reports inside them are suppressed
(`mcp/tests/tsan_mcp.supp`). `./build_test.sh --gate mcp` runs just the MCP suite.

## In the demo image

The demo image (`docker/Dockerfile.demo`) also carries the server, with `libduckdb.so` of the same DuckDB release beside it, so a running demo container can serve MCP over stdio:

```bash
docker run --rm -i -v "$PWD/dist/packages:/ext:ro" --entrypoint fractalsql-ext-mcp <image>
```

The image sets `FSQL_DUCKDB_EXTENSION` to the mounted extension file and `FSQL_DUCKDB_ALLOW_UNSIGNED=true` (a locally built extension is unsigned). Mount the extension at `/ext`, as the compose file does.

## Related

- [Reasoning Setup](reasoning-setup.md) and [Text-to-SQL Setup](text-to-sql-setup.md): what the model-backed tools need.
- [Discovery](api-discovery.md), [Analytics](api-analytics.md), [Agency](api-agency.md): the functions behind the tools.
