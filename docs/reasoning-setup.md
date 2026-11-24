<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# Sovereign Reasoning Setup Guide

The **Cognition Tier** is the intelligence layer of FractalSQL. It provides a pluggable bridge that lets DuckDB call Large Language Models (LLMs) and embedding providers directly from SQL.

By bringing reasoning directly into the DuckDB process, FractalSQL lets you synthesize, analyze, and reason over your data without an external application-middleware hop. Sovereignty here is a deployment choice, not a guarantee baked into every provider: local models (Ollama/vLLM) keep data on your own infrastructure, while cloud providers (Bedrock, Azure OpenAI, Vertex) send it to that provider under your own account and compliance agreement.

---

## 🧠 The Cognition Model

At its core, the Cognition tier provides the `fractal_reason(query, context)` primitive. Unlike traditional RAG, which relies on external orchestrators, FractalSQL performs the synthesis inside the process:

1. **Context Assembly**: You use ordinary SQL (subqueries, `list`/struct aggregation, or `fractal_search_explore`) to gather the precise data needed.
2. **Sovereign Dispatch**: The extension dispatches the query and context to your configured LLM via a dedicated C-bridge.
3. **In-Place Synthesis**: The response is returned directly into your query result, allowing you to combine reasoning with standard SQL filters, joins, and aggregations in a single statement.

---

## 🛠️ Prerequisites

To activate the Cognition tier, you need a reasoning plugin and a configured endpoint.

### 1. The Reasoning Plugin
The reasoning plugin (`fractalsql-reasoning-http.so`/`.dylib`/`.dll`, vendored per-platform under `include/<platform>/`) is loaded via `fsql_load_reasoning()` inside the extension -- not a separate install step. Point `FRACTALSQL_REASONING_PLUGIN` (an environment variable read by this process, not a config file) at the file before the first `fractal_reason`/`fractal_embed` call:

```bash
export FRACTALSQL_REASONING_PLUGIN="$(pwd)/include/linux-x86_64/fractalsql-reasoning-http.so"
```

The plugin is native code the extension maps into its own process, so the extension checks where it came from before it loads it. The plugin must carry a detached Ed25519 signature from the FractalSQLabs reasoning-plugin signing key -- a `<plugin>.sig` file of exactly 64 raw bytes beside it. The release packages ship the plugin and its `.sig` together; keep the two together. A plugin without a valid signature is refused, and the call that wanted it says so. An operator testing their own build can set `FSQL_REASONING_REQUIRE_SIGNATURE=0` to load a plugin that has no `.sig`; one warning goes to stderr when that happens, and a `.sig` that is present but wrong is still refused.

The enterprise core library is checked the same way, with its own setting: `FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0` loads a core library that has no `.sig`, and a warning says so on stderr.

### 2. Technical Requirements
- **Extension Version**: `fractalsql-ext` 2.0.0+ (`SELECT fractal_version();`).
- **Reasoning Plugin ABI**: the plugin's `fsql_reasoning_init` must set
  `abi_version` to `FSQL_REASONING_ABI_VERSION` (= 1,
  `include/fractalsql_sql.h:132`) or the load is rejected. The vendored
  plugin shipped here is `reasoning-http v1.4.1` (recorded in
  `include/REASONING_VERSION`); the env vars and behaviors documented on
  this page, `FSQL_REASONING_HTTP_TOKEN_FILE` included, are features of
  that floor.
- **Host Dependencies**: `libcurl` 7.75.0+ (required for AWS SigV4 auth).
- **Windows**: requires the Microsoft Visual C++ 2015-2022 Redistributable (x64) ([download](https://aka.ms/vs/17/release/vc_redist.x64.exe)).
- **Endpoint**: An LLM provider (Ollama, AWS Bedrock, Azure OpenAI, GCP Vertex, or any OpenAI-compatible API).

---

## 🚀 Setup Sequence

## Step 1: Activate the Plugin

```bash
export FRACTALSQL_REASONING_PLUGIN=/path/to/fractalsql-reasoning-http.so
```

The plugin loads lazily upon the first reasoning call in the process. Since
there's no config file to reload, changing it means restarting the process
with the new value set -- there's no live-reload path.

## Step 2: Universal LLM Connectivity
One of the core strengths of this design is **zero provider lock-in**: the provider bridge abstracts each provider's API, so your SQL calls to `fractal_reason()` remain identical whether you're using a local model for privacy or a cloud provider for scale.

Pick your provider and add the corresponding block to your configuration. Only one block should be active at a time.

## Ollama (Local or Private Network)
The gold standard for fully air-gapped, sovereign deployments. Traffic stays inside your network perimeter.

```sh
# Local Ollama
export FSQL_REASONING_HTTP_URL=http://127.0.0.1:11434/v1/chat/completions
export FSQL_REASONING_HTTP_ALLOW_PLAINTEXT=1
export FSQL_REASONING_HTTP_MODEL=gpt-oss:20b
```
*Note: Run `ollama pull gpt-oss:20b` or `ollama pull gemma4:12b` or `ollama pull phi4:14b` before connecting.*

## OpenAI-Compatible (OpenAI, Together AI, Fireworks, vLLM)
```sh
export FSQL_REASONING_HTTP_URL=https://api.openai.com/v1/chat/completions
export FSQL_REASONING_HTTP_TOKEN=sk-...
export FSQL_REASONING_HTTP_MODEL=gpt-4o-mini
```

## AWS Bedrock
Bedrock uses AWS SigV4 signing. The URL must point to the **OpenAI-compatible** surface.

```sh
export FSQL_REASONING_HTTP_URL=https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/chat/completions
export FSQL_REASONING_HTTP_MODEL=amazon.nova-lite-v1:0
export FSQL_REASONING_HTTP_AUTH_TYPE=aws-sigv4
export FSQL_REASONING_HTTP_AWS_REGION=us-east-1
```

Credentials come from the standard AWS environment of the process that loads the plugin: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, plus `AWS_SESSION_TOKEN` when you use temporary (IAM role) credentials. With `aws-sigv4` both the access key and the secret key are required. If either is missing, the plugin fails to initialize and prints `AUTH_TYPE=aws-sigv4 requires AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY` to stderr, so a missing credential shows up when the plugin loads rather than as a generic HTTP 403 from Bedrock. A credential or region that contains a control character (for example a stray newline pasted with a secret) is refused instead of being sent.

## Azure OpenAI
Azure requires a separate deployment for the chat model.

```sh
export FSQL_REASONING_HTTP_URL="https://<resource>.openai.azure.com/openai/deployments/<deployment>/chat/completions?api-version=2024-02-01"
export FSQL_REASONING_HTTP_TOKEN=<azure-api-key>
export FSQL_REASONING_HTTP_MODEL=gpt-4o
```

## Google Vertex AI
Vertex AI exposes an OpenAI-compatible endpoint on the `openai/v1` path of your
project's region endpoint. Auth is a Google **service-account OAuth access
token** (a short-lived bearer), supplied via `FSQL_REASONING_HTTP_TOKEN`
exactly like an API key. No SigV4-style signing is needed.

```sh
export FSQL_REASONING_HTTP_URL="https://{LOCATION}-aiplatform.googleapis.com/v1/projects/{PROJECT}/locations/{LOCATION}/endpoints/openapi/chat/completions"
export FSQL_REASONING_HTTP_TOKEN=<gcp-oauth-access-token>
export FSQL_REASONING_HTTP_MODEL=google/gemini-2.5-flash
```

**Generating the token**: `FSQL_REASONING_HTTP_TOKEN` must be a valid Google
OAuth access token for a service account with the Vertex AI User role. The
canonical way is a service-account JSON key plus the gcloud CLI:

```sh
gcloud auth activate-service-account --key-file=sa-key.json
gcloud auth print-access-token > /run/fractalsql/vertex-token.txt
```

The token is short-lived (~1 hour), and this build is exact about the
refresh mechanics: the plugin reads the static `FSQL_REASONING_HTTP_TOKEN`
**once, at plugin load** (`reasoning_http.c:2044`) -- re-exporting that env
var in a long-running process changes nothing. The refreshable mechanism is
`FSQL_REASONING_HTTP_TOKEN_FILE`: point it at a file holding the current
token and the plugin **re-reads the file on every request**
(`refresh_token_file`, `reasoning_http.c:1852-1868`; capped at 65536
bytes), falling back to the static token only if a read fails. A sidecar
that refreshes the file before expiry keeps a long-running process live
with no restart:

```sh
export FSQL_REASONING_HTTP_TOKEN_FILE=/run/fractalsql/vertex-token.txt
# sidecar (every ~55 minutes, before the token expires):
#   gcloud auth print-access-token > /run/fractalsql/vertex-token.txt
```

---

## ⚖️ Hardware & Performance (Local Reasoning)

For users deploying Ollama locally, hardware affects "cold-load" latency.

| Resource | Recommendation | Notes |
| --- | --- | --- |
| **GPU VRAM** | 8GB $\rightarrow$ 16GB | 8GB runs Phi-4/Gemma4 (Q4); 16GB runs GPT-OSS 20B. |
| **System RAM** | 16GB+ | Covers model, OS, and process overhead. |
| **CPU** | AVX2 Support | Essential for acceptable CPU-side inference (Post-2016). |

### Handling Constrained Hardware
Local models can take up to 300s to cold-load into memory. To prevent `curl` from aborting the request, raise the timeout and low-speed windows in the process environment before it starts:

```sh
export FSQL_REASONING_HTTP_TIMEOUT_MS=330000
export FSQL_REASONING_HTTP_LOW_SPEED_SECS=300
```

---

## 🛠️ Advanced Configuration

Every advanced knob at a glance -- details for each are in the sections below:

| Variable | Notes |
| --- | --- |
| `FSQL_REASONING_HTTP_RESPONSE_MODE` | `text` (default) / `code` / `json` -- see [Response Modes](#response-modes) |
| `FSQL_REASONING_HTTP_THINK` | Reasoning effort for hybrid-thinker models -- see [Reasoning Effort](#reasoning-effort) |
| `FSQL_REASONING_HTTP_THINK_PROVIDER` | Request shape THINK uses -- see [Reasoning Effort](#reasoning-effort) |
| `FSQL_REASONING_HTTP_NATIVE_URL` | Override URL for the ollama/anthropic native shape |
| `FSQL_REASONING_HTTP_NUM_CTX` | Ollama-native context-window cap |
| `FSQL_REASONING_HTTP_AUTH_TYPE` | `bearer` (default) / `api-key` / `aws-sigv4` -- see [AWS Bedrock](#aws-bedrock) |
| `FSQL_REASONING_HTTP_AWS_REGION` | AWS region for `aws-sigv4` |
| `FSQL_REASONING_HTTP_TIMEOUT_MS` | Total request timeout -- see [Handling Constrained Hardware](#handling-constrained-hardware) |
| `FSQL_REASONING_HTTP_LOW_SPEED_SECS` | Slow-response abort window |
| `FSQL_REASONING_HTTP_SYSTEM_PROMPT` | Replaces the baseline anti-injection system prompt -- see [Security & Governance](#-security--governance) |
| `FSQL_REASONING_REQUIRE_SIGNATURE` | `1` (default) requires a valid plugin signature; `0` loads a plugin that has no `.sig` (one warning goes to stderr) |
| `FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE` | `1` (default) requires a valid enterprise core library signature; `0` loads one that has no `.sig` (one warning goes to stderr) |

### Response Modes
Shape how the plugin post-processes the LLM response via environment variables:
- `text` (default): Raw content.
- `code`: Forces a single fenced code block and extracts it.
- `json`: Forces a fenced JSON block and validates structural integrity.

Applies to `fractal_reason`. Set `FSQL_REASONING_HTTP_RESPONSE_MODE` in the
process environment before the first reasoning call.

### Reasoning Effort
Hybrid-thinker models (Granite 4.2, OpenAI o-series, Claude extended thinking, DeepSeek-R1, QwQ) emit an internal reasoning trace before their final answer -- left uncontrolled, that trace dominates latency and, on memory-constrained GPUs, VRAM. Two env vars throttle it:

| Variable | Values | Notes |
| --- | --- | --- |
| `FSQL_REASONING_HTTP_THINK` | unset (default) / `none` / `off` / any other string (`low`, `medium`, `high`, `minimal`, `xhigh`, `max`, ...) | Unset (or `none`) sends no thinking-control field, so the model's own default applies. `off` explicitly disables thinking on the wire -- not the same thing, since a hybrid-thinker model's own default is often ON. Any other value is forwarded to the provider verbatim, not checked against a fixed list -- provider effort scales keep adding tiers, so this plugin doesn't hardcode any one vendor's current names. Applies to `fractal_reason()`; never `fractal_embed()`. Also applies to `fractal_text_to_sql()`/`fractal_sql_agent()`'s GENERATE step, which dispatches through the same plugin. |
| `FSQL_REASONING_HTTP_THINK_PROVIDER` | unset (defaults to `openai`) / `openai` / `ollama` / `anthropic` / `vllm` / `grok` | Selects the request SHAPE, not a vendor -- `openai` also covers Azure OpenAI, AWS Bedrock, and Google Vertex AI's OpenAI-compatible surfaces, since this is independent of how `FSQL_REASONING_HTTP_URL` is authenticated. `grok` is for xAI's Grok models on Bedrock's OpenAI-compatible surface, which take a nested `reasoning.effort` field instead of `openai`'s top-level one. Ollama and Anthropic speak a native request shape instead, since their OpenAI-compatible endpoints don't honor thinking control. Ignored entirely when `FSQL_REASONING_HTTP_THINK` is unset. |
| `FSQL_REASONING_HTTP_NATIVE_URL` | unset (default) / URL | Only consulted for the ollama/anthropic native shape. Leave unset to target `FSQL_REASONING_HTTP_URL` verbatim. |
| `FSQL_REASONING_HTTP_NUM_CTX` | `0` (default, unset) / positive integer | Ollama-native context window cap (`options.num_ctx`) -- a measured fix for hybrid-thinker VRAM blowup on memory-constrained GPUs. Only applies when `FSQL_REASONING_HTTP_THINK_PROVIDER=ollama`. Forwarded verbatim into the request, not bound-checked by the vendored plugin (`reasoning_http.c:1291-1297`; malformed/non-positive values are silently ignored with a stderr warning, `:396-408`) -- pick values your Ollama server and VRAM can serve; the reference docset's 1048576 figure is a sanity ceiling from its own toolchain, not an enforced number here. |

```sh
# Local Ollama, medium reasoning effort, capped context window
export FSQL_REASONING_HTTP_THINK=medium
export FSQL_REASONING_HTTP_THINK_PROVIDER=ollama
export FSQL_REASONING_HTTP_NUM_CTX=16384
```

The plugin never surfaces the reasoning trace itself -- `fractal_reason()` still returns the final answer only, regardless of `FSQL_REASONING_HTTP_THINK_PROVIDER`'s shape.

### Target-System Hints
Set `FSQL_REASONING_HTTP_SYSTEM_TAG=duckdb` to hint to the model that it should use DuckDB SQL syntax rather than another dialect's.

---

## 🧭 Setting names on every host

The same setting is spelled by the convention of the host it lives in: a SQL setting name where the extension runs inside the database, a `fractalsqld.conf` key where a daemon holds the model client. This table is the same in every host's guide; **—** means the host does not have the setting, and the note says why.

| Setting | SQLite, DuckDB (`fractal_config_set`) | PostgreSQL (`SET` / `ALTER SYSTEM`) | MariaDB (`fractal_config_set`, `fractalsqld.conf`) | Valkey (`fractalsqld.conf`, module argument) | Druid (`fractalsqld.conf`, property) | Plugin environment variable |
| --- | --- | --- | --- | --- | --- | --- |
| Reasoning plugin path | `reasoning_plugin` | `fractalsql.reasoning_plugin` | `reasoning_plugin` | `reasoning_plugin` | `reasoning_plugin` | `FRACTALSQL_REASONING_PLUGIN` |
| Chat endpoint URL | `http_url` | `fractalsql.http_url` | `reasoning_url` | `reasoning_url` | `reasoning_url` | `FSQL_REASONING_HTTP_URL` |
| Bearer token (a secret, never read back) | `http_token` | `fractalsql.http_token` | `reasoning_token` | `reasoning_token` | `reasoning_token` | `FSQL_REASONING_HTTP_TOKEN` |
| Chat model | `http_model` | `fractalsql.http_model` | `reasoning_model` | `reasoning_model` | `reasoning_model` | `FSQL_REASONING_HTTP_MODEL` |
| Allow plain HTTP | `http_allow_plaintext` | `fractalsql.http_allow_plaintext` | `reasoning_allow_plaintext` | `reasoning_allow_plaintext` | `reasoning_allow_plaintext` | `FSQL_REASONING_HTTP_ALLOW_PLAINTEXT` |
| Embedding endpoint URL | `http_embed_url` | `fractalsql.http_embed_url` | `embed_url` | `embed_url` | `embed_url` | set per call by the host |
| Embedding model | `http_embed_model` | `fractalsql.http_embed_model` | `embed_model` | `embed_model` | `embed_model` | set per call by the host |
| Reasoning effort | `http_think` | `fractalsql.http_think` | `think` | `think` | `think` | `FSQL_REASONING_HTTP_THINK` |
| Effort provider | `http_think_provider` | `fractalsql.http_think_provider` | `think_provider` | `think_provider` | `think_provider` | `FSQL_REASONING_HTTP_THINK_PROVIDER` |
| Native endpoint URL | `http_native_url` | `fractalsql.http_native_url` | `think_native_url` | `think_native_url` | `think_native_url` | `FSQL_REASONING_HTTP_NATIVE_URL` |
| Context window | `http_num_ctx` | `fractalsql.http_num_ctx` | `think_num_ctx` | `think_num_ctx` | `think_num_ctx` | `FSQL_REASONING_HTTP_NUM_CTX` |
| Response mode | `http_response_mode` (SQLite, DuckDB) | `fractalsql.http_response_mode` | environment of `fractalsqld` | environment of `fractalsqld` | environment of `fractalsqld` | `FSQL_REASONING_HTTP_RESPONSE_MODE` |
| Text-to-SQL attempts | `text_to_sql_max_attempts` (SQLite); DuckDB makes 3 | `fractalsql.text_to_sql_max_attempts` | `t2s_max_attempts` | — no text-to-SQL | `t2s_max_attempts` | — |
| Text-to-SQL statements allowed | `text_to_sql_allowed_statements` | `fractalsql.text_to_sql_allowed_statements` | `t2s_allowed_statements` | — no text-to-SQL | `t2s_allowed_statements` | `FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS` (DuckDB) |
| Text-to-SQL review pass | `text_to_sql_use_review` | `fractalsql.text_to_sql_use_review` | `t2s_use_review` | — no text-to-SQL | `t2s_use_review` | `FRACTALSQL_TEXT_TO_SQL_USE_REVIEW` (DuckDB) |
| Enterprise library | `enterprise_lib` | `fractalsql.enterprise_lib` | `enterprise_lib` | `enterprise_lib` | `enterprise_lib` | `FRACTALSQL_ENTERPRISE_LIB` |
| Ledger file | — the ledger is a table (SQLite) or held in memory (DuckDB) | — the ledger is a table | `enterprise_ledger_path` | `enterprise_ledger_path` | `enterprise_ledger_path` | `FRACTALSQL_ENTERPRISE_LEDGER_PATH` |
| Ledger authentication key (a secret) | `enterprise_ledger_key` (SQLite); — DuckDB holds the ledger in memory | `fractalsql.enterprise_ledger_key` | `enterprise_ledger_key` | `enterprise_ledger_key` | `enterprise_ledger_key` | `FRACTALSQL_ENTERPRISE_LEDGER_KEY` |
| Require the library's signature | `enterprise_require_signature` (DuckDB: can only be turned on) | `fractalsql.enterprise_require_signature` | `enterprise_require_signature` | `enterprise_require_signature` | `enterprise_require_signature` | `FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE` |
| Ledger retention (`fade` or `exact`) | `ledger_retention` | `fractalsql.ledger_retention` | environment of `fractalsqld` | environment of `fractalsqld` | environment of `fractalsqld` | `FRACTALSQL_LEDGER_RETENTION` |
| Ledger size cap | `ledger_max_rows` (SQLite, rows; 0 = unbounded) or `ledger_max_bytes` (DuckDB, bytes; 0 = unbounded) | `fractalsql.ledger_max_rows` (rows) | environment of `fractalsqld`: `FRACTALSQL_LEDGER_MAX_BYTES` (bytes, default 1 GiB; 0 = unbounded) | environment of `fractalsqld`: `FRACTALSQL_LEDGER_MAX_BYTES` | environment of `fractalsqld`: `FRACTALSQL_LEDGER_MAX_BYTES` | `FRACTALSQL_LEDGER_MAX_BYTES` |
| Partial agent results | `agent_partial_reasoning_fail` (SQLite and DuckDB) | `fractalsql.agent_partial_reasoning_fail` | `fractal_agent_partial_fail(session, 'on')` | `agent-partial-reasoning-fail` | the request argument `partial` | — |
| Agents search through an index (`off`, `on`, `auto`) | `agent_use_index` | `fractalsql.agent_use_index` | `agent_use_index` | `agent-use-index` (`no`, `yes`, `auto`) | `druid.fractalsql.agent_use_index` | `FRACTALSQL_AGENT_USE_INDEX` (DuckDB) |
| Smallest table `auto` uses an index for (not used on MariaDB and Druid, where `auto` scans exactly until they calibrate an index) | `agent_index_min_rows` | `fractalsql.agent_index_min_rows` | `agent_index_min_rows` | `agent-index-min-rows` | `druid.fractalsql.agent_index_min_rows` | `FRACTALSQL_AGENT_INDEX_MIN_ROWS` (DuckDB) |
| Longest text cell an agent passes to the model | `agent_context_row_bytes` | `fractalsql.agent_context_row_bytes` | `agent_context_row_bytes` | — the total is capped at 1 MiB | `druid.fractalsql.agent_context_row_bytes` | `FRACTALSQL_AGENT_CONTEXT_ROW_BYTES` (DuckDB) |

Values that name an on/off choice accept `on`, `off`, `1`, `0`, `true`, `false`, `yes` and `no` everywhere they are a setting. `fractal_config_keys()` (where the host has it) lists the keys the running build knows.

---

## 🔒 Security & Governance

### The Sovereign Guardrail: Bound What the Context Query Can See
DuckDB has no `CREATE ROLE`, row-level-security, or per-role `GRANT`
layer to configure here -- its embedded, typically-single-user model has
no database-level access control at all. The equivalent discipline in this build is application-level: only ever build the context payload passed to `fractal_reason()` from a query that already excludes columns/rows the LLM shouldn't see (e.g. `SELECT id, title, body FROM documents WHERE tenant_id = current_tenant`, never `SELECT *`), since there's no database-enforced backstop if that query is wrong.

### Row Isolation
If you're embedding this in a multi-tenant application, enforce tenant/row visibility in the query that builds the context payload, every time -- there's no RLS to fall back on if a call site forgets the filter.

### Prompt Injection (OWASP LLM01)
The plugin prepends a baseline anti-injection instruction to every system message as a best-effort mitigation. No system-prompt instruction can fully prevent prompt injection from untrusted context, since the model still can't reliably distinguish instructions from data. Treat it as raising the bar, not closing the door. The real defense is architectural: the context-discipline rules above restricting what the context subquery can see, and treating every LLM response as untrusted output, never executed as SQL (see the checklist below). To replace the baseline instruction, set `FSQL_REASONING_HTTP_SYSTEM_PROMPT`.

---

## 📋 Production Checklist

- [ ] **Plugin Path**: `FRACTALSQL_REASONING_PLUGIN` is absolute and readable by the process running DuckDB.
- [ ] **Context Discipline**: every context query passed to `fractal_reason()` explicitly selects only the columns/rows the LLM should see -- no `SELECT *`, no relying on a permission system that doesn't exist in this embedded model.
- [ ] **Egress Review**: Cloud endpoints' DPA/BAA have been reviewed for the specific data classification.
- [ ] **Environment**: `FSQL_REASONING_HTTP_AUTH_TYPE` (and every other `FSQL_REASONING_HTTP_*`/`FRACTALSQL_REASONING_PLUGIN` var) is correctly exported to the process environment before DuckDB starts.
- [ ] **Output Safety**: LLM responses are treated as untrusted display text and never executed as SQL.
