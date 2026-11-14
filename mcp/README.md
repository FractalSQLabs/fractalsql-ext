<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# fractalsql-ext-mcp

A Model Context Protocol server for FractalSQL on DuckDB: 81 typed tools over the extension's functions, stdio or HTTP/TLS. A standalone C++17 program that links `libduckdb`, loads the extension into its own DuckDB and locks that DuckDB down (no file access, no INSTALL/LOAD, settings frozen).

    make -C mcp DUCKDB_DIR=/path/to/libduckdb          # duckdb.h + libduckdb.so of the extension's DuckDB version; needs OpenSSL headers
    FSQL_DUCKDB_EXTENSION=/path/fractalsql.duckdb_extension mcp/fractalsql-ext-mcp --list-tools

Documentation: [docs/mcp-plugin.md](../docs/mcp-plugin.md). Tests: the MCP suite in `./build_test.sh`, or `mcp/tests/` directly.

Layout: `src/` the generic MCP core (JSON-RPC, transports, concurrency, registry, locks), `src/db.*` the DuckDB connection layer, `src/adapters/functions.cpp` the table-driven adapter,
`tools.spec.json` the tool catalog (source of truth; `scripts/gen_spec_inc.py` regenerates `src/adapters/tools_spec.inc`), `tests/` the probes and drivers, `.mcp-schema-lock` and
`.mcp-safety-annotations-lock` the committed catalog fingerprints, `manifest.json` the tool manifest.

## Hardening switches

| Variable | Effect |
|---|---|
| `FSQL_MCP_READ_ONLY` | `true` / `1` / `on` / `yes` (any case). Refuses every tool that writes state, and applies the engine-side backstop where the engine has one. |
| `FSQL_MCP_ALLOW_MISSING_LOCKS` | Off by default. A missing schema or safety-annotation lock file stops startup; set `true` to run without the drift check (development only). An explicit `FSQL_MCP_REQUIRE_LOCKS=false` has the same effect. Lock files are looked up in the working directory first, then next to the executable. |
| `FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK` | Off by default. The HTTP transport refuses to bind a non-loopback address without TLS (enable TLS with `FSQL_MCP_HTTP_TLS=true` and a certificate/key); set this to `true` to accept a plaintext bind on a network you control. |
Every state-changing tool is reported with `destructiveHint: true` -- so a client that honours the annotation asks before calling it and read-only mode refuses it. That annotation is itself locked: `mcp/.mcp-safety-annotations-lock` is a committed fingerprint of every tool's safety hints, and a change to any of them stops the server until the lock is regenerated on purpose. Each `tool_call` log line carries a short `client` digest identifying the session or token that made the call.

## Configuration

The settings the server reads, and what each one decides. The full list, with the defaults, is in [docs/mcp-plugin.md](../docs/mcp-plugin.md#operating-it).

| Variable | Default | Effect |
|---|---|---|
| `FSQL_MCP_CONFIG_WRITES` | `safe` | What a config-writing admin tool may change: `off` (nothing), `safe` (the chat model name, the embedding model name and the think mode), `all` (any key). The endpoint URLs, the plugin path, the token and the enterprise library are outside the safe set. |
| `FSQL_MCP_ALLOW_AUTO_EXECUTE` | off | Whether a model may ask for `auto_execute=true` on the tools that take it. |
| `FSQL_MCP_MANIFEST` | `mcp/manifest.json` | Where `--write-manifest` writes the manifest (relative to the working directory). The server never reads it; it is a distribution document. |
| `FSQL_MCP_SCHEMA_LOCK` / `FSQL_MCP_SAFETY_LOCK` | `mcp/.mcp-schema-lock` / `mcp/.mcp-safety-annotations-lock` | The catalog fingerprints the server compares against at startup, and refuses to start on a mismatch. A path that exists is used as it is; a relative one that does not exist in the working directory is looked for beside the executable, by file name. |
| `FSQL_MCP_TOOL_WHITELIST` / `FSQL_MCP_ENABLED_CATEGORIES` | all | Narrow the catalog the server offers. |
| `FSQL_MCP_PROTOCOL_ERA` | `dual` | `dual` serves both protocol eras, `modern` the modern one only. |
| `FSQL_MCP_LOG_LEVEL` | `normal` | `verbose` adds debug lines. One JSON line per tool call on stderr, arguments redacted and capped. |

## Authentication

Over stdio there is no credential: the client spawns the server as a trusted subprocess. Over HTTP a bearer token is the credential, and it is never optional. `FSQL_MCP_AUTH_TOKEN` is the deployment-wide secret; `FSQL_MCP_AUTH_TOKEN_FILE` holds the same secret in a file and is re-read as that file changes, so it can be rotated without a restart.

`FSQL_MCP_TOKEN_POLICY_FILE` names per-client credentials, so each caller can be revoked on its own and can be given its own tool allowlist:

```json
{ "tokens": [ { "name": "analyst", "sha256": "<hex sha256 of that client's token>",
                "tools": ["fractal_search"], "expires": "2027-01-31T00:00:00Z" } ] }
```

The file holds the SHA-256 of each token, never the token itself. A refused credential is answered with `401` and `WWW-Authenticate: Bearer realm="fractalsql-mcp"` (`error="invalid_token"` when a token was presented). The `Authorization` header is the only place a credential is read from: a token in the query string is refused, because a query string ends up in proxy logs and browser history. `GET /healthz` and `GET /readyz` answer without a token.

## Protocol versions

Both eras are served at once. The legacy era is the handshake-based one (`initialize`, then an `Mcp-Session-Id`); the revisions served are `2024-11-05`, `2025-03-26`, `2025-06-18`, `2025-11-25` and `2026-07-28`. The modern era is stateless: every request carries `MCP-Protocol-Version` and `Mcp-Method`, plus `Mcp-Name` for the methods that address something by name, and the headers have to agree with the body. `FSQL_MCP_PROTOCOL_ERA` chooses: `dual` (the default) serves both, `modern` serves the modern era only.

## Data at rest

The ledger and audit chain is held in memory, per connection, and is gone when the process exits: there is no ledger file, no CSV mirror and no separate head record to protect. The protection against a truncated chain is the off-host anchor log -- `FSQL_LEDGER_ANCHOR_LOG=stderr` (or `syslog`) publishes one JSON line per append, `{"event":"ledger_head","kind":K,"rows":N,"hash":"<hex>"}`. `FSQL_AUDIT_REDACT=hash` stores a fingerprint of the audit text instead of the text; `truncate` stores its first 64 characters. A configuration write changes the process environment only, so it leaves nothing on disk either. Everything else that persists is the database file and the credential files, and confidentiality for the database file comes from volume or disk encryption.
