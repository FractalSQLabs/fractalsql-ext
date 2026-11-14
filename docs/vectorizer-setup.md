<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# Vectorizer Setup Guide

The Vectorizer is the Cognition tier's automation engine. It keeps raw text and semantic embeddings in sync, so your data is always "search-ready" without external middleware or a separate ETL pipeline.

By running the embedding sync directly inside the DuckDB process, FractalSQL eliminates the "data shuffle" and keeps your semantic index a reflection of your data. The one structural difference from a trigger-driven engine: **no triggers** -- new rows are discovered by a diff scan the next time the queue is processed, detailed below.

---

## Prerequisites

To enable automated embeddings, set the reasoning plugin env var (see [reasoning-setup.md](reasoning-setup.md)), with the plugin itself configured for embedding mode:

```bash
export FRACTALSQL_REASONING_PLUGIN=/path/to/fractalsql-reasoning-http.so
export FSQL_REASONING_HTTP_MODE=embedding
export FSQL_REASONING_HTTP_URL=http://127.0.0.1:11434/v1/embeddings
export FSQL_REASONING_HTTP_MODEL=nomic-embed-text
```

**Connectivity Check**:
```sql
LOAD '/path/to/fractalsql.duckdb_extension';
SELECT fractal_embed('hello world');
--  [0.0023064255, -0.009327292, ...]
```

---

## Quick Start: Sync on demand

### 1. Define your table
Embeddings live in a plain DuckDB array/list column -- use `DOUBLE[]` (or a fixed-size `DOUBLE[n]` array, which DuckDB itself enforces at the type level if you want dimension-drift protection):

```sql
CREATE SEQUENCE docs_id_seq;
CREATE TABLE docs (
    id        INTEGER PRIMARY KEY DEFAULT nextval('docs_id_seq'),
    body      VARCHAR NOT NULL,
    embedding DOUBLE[]
);

INSERT INTO docs (body) VALUES ('first doc'), ('second doc');
```

### 2. Create the Vectorizer

```sql
SELECT fractal_vectorizer_create('docs', 'id', 'body', 'embedding');
```

> **About the `source_pk_col` argument**: this build's signature is
> `fractal_vectorizer_create(source_table, source_pk_col, text_col,
> embedding_col[, options])` -- the key column is an explicit argument
> because of how this build processes rows. There are no triggers here, so
> nothing is queued "the instant a matching row is written"; instead
> `process_queue` does a diff scan (`text_col IS NOT NULL AND
> embedding_col IS NULL AND NOT already queued`) each time it's called,
> and tracking "already queued" against a row needs an explicit,
> single-column key. Semantics therefore shift from "queued at write
> time" to "discovered the next time `process_queue()` runs" --
> disclosed, not hidden.
>
> Omit the arg and this build will try `duckdb_constraints()` to find a
> single-column PRIMARY KEY on `source_table` and use that -- but a table
> with no declared PK, or a composite one, needs it passed explicitly.

### 3. Process the Queue
No background worker -- you trigger it on your own schedule (cron, a systemd timer, an app-level scheduler):

```sql
SELECT fractal_vectorizer_process_queue();
-- returns the number of rows successfully embedded this call
```

### 4. Monitor Progress
```sql
SELECT * FROM fractal_vectorizer_status();
-- id | source_table | enabled | pending | processing | done | failed
```
`fractal_vectorizer_status` is a **table function** here (`FROM
fractal_vectorizer_status()`), not a view -- DuckDB extensions register
functions through the loader API, not catalog view objects. One row per
vectorizer, with a live count of queue rows in each status.

---

## Storage: `FLOAT[]` / `DOUBLE[]` and vector math functions

Embeddings are plain DuckDB array/list values, not a bespoke vector type.
`fractal_embed` itself returns `DOUBLE[]` (`LIST(DOUBLE)`), which the
vectorizer sync writes straight into `embedding_col`
(`UPDATE ... SET embedding_col = fractal_embed(text_col)`) -- so a
`DOUBLE[]` column is the natural declaration. Declare a fixed-size
`ARRAY(DOUBLE, n)` instead if you want dimension-drift protection enforced
at the type level.

Vector math is plain scalar functions over `LIST(FLOAT)` (float32), not infix operators
(DuckDB doesn't support user-defined operators):

| Function | Meaning |
| --- | --- |
| `fractal_vector_dot(a, b)` | Inner product |
| `fractal_vector_l2_distance(a, b)` | L2 (Euclidean) distance |
| `fractal_vector_cosine_distance(a, b)` | Cosine distance |
| `fractal_vector_l2_squared(a, b)` | Squared L2 distance (`fractal_vector_l2_squared`, no `sqrt`, cheaper for ordering) |
| `fractal_vector_cosine_similarity(a, b)` | Cosine *similarity* |
| `fractal_vector_norm(a)` / `fractal_vector_normalize(a)` | L2 norm / unit vector |
| `fractal_vector_dims(a)` | Dimension count (`INTEGER`) |
| `fractal_vector_from_float8_array(a)` / `fractal_vector_to_float8_array(a)` | Convert between `DOUBLE[]` and `FLOAT[]` |
| `fractal_vector_add(a, b)` / `_sub(a, b)` / `_scale(a, s)` | Element-wise add / subtract / scalar-multiply |
| `fractal_vector_weighted_concat(a, wa, b, wb)` | Weighted element-wise concat: `wa` and `wb` scale the two inputs before concatenation (`FLOAT[]` out) |
| `fractal_vector_lp_distance(a, b, p)` | Generalized $L_p$ distance, any $p > 0$ (for $0 < p < 1$ this is not a proper metric; use explicitly, never as a silent default distance) |
| `fractal_vector_quantize_int8(a)` | Symmetric int8 quantization, 4x compression, returns `STRUCT(codes BLOB, scale FLOAT)` |
| `fractal_vector_quantize_binary(a)` | 1-bit quantization, 32x compression, MSB-first sign bits |
| `fractal_vector_hamming_distance(a, b)` | Hamming distance between two quantized `BLOB` values (cheap candidate filtering ahead of a full-precision re-rank) |

These take `FLOAT[]` specifically (not `DOUBLE[]`) -- cast at the call site
if your column is `DOUBLE[]`:

```sql
SELECT fractal_vector_cosine_distance(
    CAST(embedding AS FLOAT[]), CAST([1.0, 0.0, 0.0] AS FLOAT[]))
FROM docs LIMIT 1;
```

---

## Endpoint Providers

The Vectorizer leverages the same auth-bridge as the Cognition tier's reasoning endpoint. Credentials and region settings are shared; only the URL and model change.

> **Reminder from the header note above**: `fractal_reason` (chat) and
> `fractal_embed` (embeddings) dispatch through the SAME loaded plugin
> instance in this build, and that plugin serves exactly one config at a
> time -- there's no separate `http_embed_url`/
> `http_embed_model` alongside a chat `http_url`/`http_model`; the env
> vars are per-process, single-mode. Set `FSQL_REASONING_HTTP_MODE=embedding`
> and point `FSQL_REASONING_HTTP_URL`/`_MODEL` at the embeddings endpoint
> if `fractal_embed`/the vectorizer is what you're running; switch them
> back for chat. This build has no way to serve both from one session at the same time.

### Ollama (Local or Private Network)
Ideal for fully air-gapped deployments where data never leaves your VPC.

```bash
export FSQL_REASONING_HTTP_URL=http://127.0.0.1:11434/v1/embeddings
export FSQL_REASONING_HTTP_MODEL=nomic-embed-text
export FSQL_REASONING_HTTP_MODE=embedding
export FSQL_REASONING_HTTP_ALLOW_PLAINTEXT=1
```
*Note: You must run `ollama pull nomic-embed-text` separately.*

### OpenAI-Compatible (OpenAI, Together AI, Fireworks, vLLM)
```bash
export FSQL_REASONING_HTTP_URL=https://api.openai.com/v1/embeddings
export FSQL_REASONING_HTTP_TOKEN=sk-...
export FSQL_REASONING_HTTP_MODEL=text-embedding-3-small
export FSQL_REASONING_HTTP_MODE=embedding
```

### AWS Bedrock
Uses `FSQL_REASONING_HTTP_AUTH_TYPE=aws-sigv4` (see [reasoning-setup.md](reasoning-setup.md)).

```bash
export FSQL_REASONING_HTTP_URL=https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/embeddings
export FSQL_REASONING_HTTP_MODEL=amazon.titan-embed-text-v2:0
export FSQL_REASONING_HTTP_MODE=embedding
```

### Azure OpenAI
Requires a **separate deployment resource** for the embedding model.

```bash
export FSQL_REASONING_HTTP_URL="https://<resource>.openai.azure.com/openai/deployments/<embed-deploy>/embeddings?api-version=2024-02-01"
export FSQL_REASONING_HTTP_MODE=embedding
```

### Google Vertex AI
Uses the same OAuth access token as the reasoning endpoint (see
[reasoning-setup.md](reasoning-setup.md), Vertex AI block), only the URL and
model change. Point at the `openapi/v1/embeddings` surface of your project's
region endpoint.

```bash
export FSQL_REASONING_HTTP_URL="https://{LOCATION}-aiplatform.googleapis.com/v1/projects/{PROJECT}/locations/{LOCATION}/endpoints/openapi/embeddings"
export FSQL_REASONING_HTTP_MODEL=text-embedding-005
export FSQL_REASONING_HTTP_MODE=embedding
```

---

## SQL API Reference

> **Where the bookkeeping lives.** The registry and
> queue here are ordinary **persistent, per-database DuckDB tables** with
> fixed names -- `fractal_vectorizers` and `fractal_vectorizer_queue`,
> fed by sequence `fractal_vectorizer_id_seq`, created on first use. They are visible to
> every connection, survive across sessions and restarts, and can be
> queried directly (`SELECT * FROM fractal_vectorizer_queue ...` is
> legitimate read-only bookkeeping inspection). Still not a trigger: rows only
> embed when something calls `fractal_vectorizer_process_queue()`.

### `fractal_vectorizer_create(source_table, source_pk_col, text_col, embedding_col[, options])`
Registers the vectorizer and backfills the queue with existing rows that need embedding (same diff scan `process_queue` runs on every subsequent call). `source_pk_col` is an explicit positional argument here -- see the Quick Start note above for why. `options` is accepted for forward compatibility but not yet consumed (see Rate Capping below).

### `fractal_vectorizer_pause(id)` / `fractal_vectorizer_resume(id)`
Toggles the `enabled` state. When paused, `process_queue` skips this vectorizer entirely (no new diff-scan enqueue, no processing of already-pending rows). Raises a clean exception on a nonexistent id.

### `fractal_vectorizer_drop(id)`
Permanently deregisters the vectorizer: deletes its config row and queue history. No trigger to drop (there isn't one -- see above). Raises a clean exception on a nonexistent id. Irreversible -- for a temporary stop, use `fractal_vectorizer_pause()` instead. Needed before re-creating a vectorizer on the same `(source_table, text_col, embedding_col)`, since that triple is unique.

### `fractal_vectorizer_process_queue([batch_size][, stale_after_secs])`
The engine that drives the synchronization: reclaims stale `'processing'` rows (older than `stale_after_secs`), diff-scan enqueues newly-eligible rows for every enabled vectorizer, then embeds up to `batch_size` pending rows per vectorizer. Registered as 0/1/2-arg overloads (DuckDB scalar functions can't declare `DEFAULT` clauses; defaults 100 and 600). Returns the count of rows **successfully embedded (marked `'done'`) this call** -- a row whose `fractal_embed` throws is marked `'failed'` with the error message and is not counted.

### Rate Capping
Not yet implemented in this build. Every pending row up to `batch_size` gets embedded on each `process_queue()` call, with no per-vectorizer rate limiting or provider-throttling backoff beyond what the reasoning plugin itself does. The `options` argument of `fractal_vectorizer_create` is accepted for forward compatibility but not yet consumed.

---

## Design & Safety

### The "No-Worker" Architecture
No background worker, no trigger. You control exactly when and how often `process_queue()` runs. The real difference from a trigger-driven engine is *how* new rows get noticed -- a diff scan on each call, not a write-time trigger (see the Quick Start note above).

### Crash Safety
- **Per-row commits, not one big transaction**: each row is marked `'processing'` then `'done'`/`'failed'` as its own statement -- if the process is killed mid-batch, already-`'done'` rows stay done, and any left `'processing'` get reclaimed as `'pending'` by the next call's stale-row check (`stale_after_secs`).
- **Identifier Safety**: table and column names are quoted via DuckDB's `KeywordHelper::WriteQuoted`, not string interpolation.
- No `SECURITY INVOKER`/role-based authorization check here -- DuckDB's embedded, typically-single-user model has no per-role GRANT system to check against in the first place.

---

## Known Constraints & Roadmap

- **Text Chunking**: sends the full text of the column to the provider. For documents exceeding model context limits, pre-chunk into a separate "chunks" table.
- **Rate Capping**: not implemented (see above).
- **Automatic Retries**: Failed rows are not retried automatically; reset them to `'pending'` in `fractal_vectorizer_queue` yourself.
- **Backfill Batching**: Initial backfill for very large tables runs as one `INSERT ... SELECT`, not chunked.
- **Chat/embedding mode conflict**: this build's single loaded reasoning-plugin instance can't serve both `fractal_reason` and `fractal_embed`/the vectorizer at once (see the Endpoint Providers note above) -- a real limitation of the single-plugin, single-mode config design.

---

## When to use the Vectorizer

The Vectorizer is the right choice when you want embeddings kept in sync without managing an external Python/Node.js worker -- call `process_queue()` on whatever schedule fits (immediately after a write, or periodically), and it discovers and embeds whatever's eligible at that moment. Note the discovered-on-next-call semantics above: it's not a live trigger, so there's a gap between a write and its embedding appearing, bounded by how often you call `process_queue()`.

If you already have a robust external ETL pipeline, you can skip the Vectorizer and use `fractal_embed()` directly to populate your `DOUBLE[]`/`ARRAY(FLOAT, n)` columns.
