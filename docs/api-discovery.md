<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# Discovery API Reference

The Discovery tier provides high-precision and diverse retrieval mechanisms. Unlike traditional vector search, it treats the embedding space as a continuous optimization problem.

---

## `fractal_search`
**Two overloads under one name: per-row Sniper distance, and the raw best-point optimizer**

`fractal_search` is overloaded by argument count/type -- DuckDB resolves
which one you meant the same way it resolves any other overloaded function:

**Overload 1 -- Sniper Mode (per-row cosine distance), a DuckDB-idiomatic
addition.**
```sql
fractal_search(vector DOUBLE[], query_vector DOUBLE[]) -> DOUBLE
```
Runs SFS once per distinct query vector (cached per pipeline thread) to
refine it toward the best point in the unit box, then returns the cosine
distance from each row's vector to that refined point -- the vectorized
`ORDER BY ... LIMIT` nearest-neighbor idiom: a raw SFS refinement of the
query plus the cosine-distance comparison, fused into one call.

| Argument | Type | Description |
| --- | --- | --- |
| `vector` | `DOUBLE[]` | The row's own vector (per-row, from a table column). |
| `query_vector` | `DOUBLE[]` | The query to refine and compare against -- constant across the call, refined via SFS (30 iterations, population 50, diffusion 2 -- fixed for this overload, unlike overload 2 below). |

```sql
SELECT id, fractal_search(embedding, [0.1, 0.2, -0.3]::DOUBLE[]) AS dist
FROM my_embeddings
ORDER BY dist
LIMIT 10;
```

**Overload 2 -- raw SFS best point.**
```sql
fractal_search(query DOUBLE[]) -> DOUBLE[]
fractal_search(query DOUBLE[], iterations INTEGER) -> DOUBLE[]
fractal_search(query DOUBLE[], iterations INTEGER, population_size INTEGER) -> DOUBLE[]
fractal_search(query DOUBLE[], iterations INTEGER, population_size INTEGER, diffusion_factor INTEGER) -> DOUBLE[]
```
Takes only the query and returns the raw SFS-refined best point -- a
standalone optimizer call with no per-row scoring (registered as 1-4-arg
overloads since DuckDB scalar functions have no SQL-level defaults).

```sql
SELECT fractal_search([0.6, 0.8, 0.0]::DOUBLE[], 50);
```

---

## `fractal_search_explore` (aggregate form)
**Scout Discovery over the rows you `SELECT`**

`fractal_search_explore` has two forms in DuckDB with the same name and the same engine: this aggregate, which scans the
rows of the query it appears in, and the [table form](#fractal_search_explore-table-form) below, which names its table
and column as arguments. Both forms are available in DuckDB.

### Signature
```sql
-- DuckDB aggregate, registered as 2- and 3-arg overloads
-- (options defaults to '{}').
fractal_search_explore(vector LIST(DOUBLE), query DOUBLE[]) -> LIST(LIST(DOUBLE))
fractal_search_explore(vector LIST(DOUBLE), query DOUBLE[], options VARCHAR)
    -> LIST(LIST(DOUBLE))
```

Same Scout engine (brute-force relevance scan + MMR) as the table form. `options` takes the same JSON keys as the
table form's `options` (see its table below). The query vector must have the same dimension as the embeddings, or the
row is NULL and the reason is printed on stderr. `UNNEST` the result to get one row per particle:

```sql
SELECT UNNEST(fractal_search_explore(emb, [0.1, 0.2, 0.3]::DOUBLE[])) FROM catalog;
```

Because it is an aggregate, grouping works: one nested list per group.
Passing a NULL vector row is skipped, like any aggregate.

---

## `fractal_search_debug`
**SFS Trajectory Trace**

Runs raw SFS (like `fractal_search`'s raw best-point overload above, not this build's per-row `fractal_search` sniper mode) and returns a detailed trace of the convergence process as JSON text.

### Signature
```sql
-- DuckDB scalar function, no SQL-level defaults -- all four args required.
fractal_search_debug(
    query            DOUBLE[],
    iterations       INTEGER,
    population_size  INTEGER,
    diffusion_factor INTEGER
) -> VARCHAR  -- JSON document as text
```

> **DuckDB note.** In the other FractalSQL editions `fractal_search_debug`
> has SQL-level defaults (iterations 30, population_size 50, diffusion_factor 2);
> DuckDB
> scalar functions can't declare `DEFAULT` clauses, so here it is
> a single 4-positional-args form -- pass 30/50/2 explicitly to reproduce those defaults.

### Return Value
Returns a JSON document (as `VARCHAR`) with the following keys:
- `dim`: Vector dimensionality.
- `generations`: Total iterations run.
- `population_size`: Particles per generation.
- `best_point`: The final converged vector.
- `best_fit`: Final cosine distance.
- `best_fit_per_gen`: Array of best fits across all generations.
- `paths`: Full particle trajectories for visualization.

---

## `fractal_search_explore` (table form)
**Scout Discovery Mode**

Scans a stored corpus and returns a diverse population of results. It uses a brute-force relevance scan followed by **Maximal Marginal Relevance (MMR)** to prevent "mode collapse."

### Signature
```sql
-- DuckDB table function, no SQL-level defaults -- all four args required
-- (pass '{}' explicitly for "no options").
SELECT particle FROM fractal_search_explore(
    table_name  VARCHAR,
    vector_col  VARCHAR,
    query       DOUBLE[],
    options     VARCHAR  -- JSON text
);
```

### Arguments
| Argument | Type | Description |
| --- | --- | --- |
| `table_name` | `VARCHAR` | (Required) The table containing the embeddings. |
| `vector_col` | `VARCHAR` | (Required) The `DOUBLE[]` column. |
| `query` | `DOUBLE[]` | (Required) The target vector for relevance scoring. |
| `options` | `VARCHAR` | (Required) JSON text tuning parameters (see below); pass `'{}'` for defaults. |

Returns one row per result, column `particle` (`LIST(DOUBLE)`).

### Options (JSON keys)
| Key | Type | Default | Range | Description |
| --- | --- | --- | --- | --- |
| `population_size` | `int` | `50` | [1, 100000] | Number of results to return. |
| `mmr_lambda` | `float` | `0.5` | $[0, 1]$ (clamped outside) | Tradeoff between relevance ($1.0$) and diversity ($0.0$). Lower it when a query lands inside a dense cluster. |
| `walk` | `float` | `0.0` | $[0,1]$-ish | Fraction of random-walk diffusion steps in the underlying SFS population search (the full Scout surface; the MMR/telemetry paths pin it lower). |
| `iterations` | `int` | `15` | [1, 10000] | SFS generations for the population search Scout embeds. Raising it deepens the search before MMR re-ranking. |
| `diffusion_factor` | `int` | `2` | [1, 32] | SFS maximum-diffusion knob for that population search. |

Out-of-range `iterations`/`diffusion_factor` raise `out of range` errors rather than falling back to defaults.

---

## `fractal_search_telemetry`
**Ground-Truth Row Retrieval**

A deterministic primitive that returns the $K$ nearest real table rows to a query. This is the foundation for all higher-order agency functions.

### Signature
```sql
SELECT doc_id, distance, scan_pos FROM fractal_search_telemetry(
    table_name  VARCHAR,
    vector_col  VARCHAR,
    query       DOUBLE[],
    k           INTEGER
);
```

### Arguments
| Argument | Type | Description |
| --- | --- | --- |
| `table_name` | `VARCHAR` | The table containing the embeddings. |
| `vector_col` | `VARCHAR` | The `DOUBLE[]` column. |
| `query` | `DOUBLE[]` | The target vector. |
| `k` | `INTEGER` | Number of nearest neighbors to return. |

### Returns
Rows ascending by distance:

| Column | Type | Description |
| --- | --- | --- |
| `doc_id` | `VARCHAR` | The row's DuckDB `rowid` pseudocolumn, stringified. Not a durable identifier: `rowid` is valid for the query it came from; resolve back to the row with `WHERE rowid = CAST(doc_id AS BIGINT)` within the same query/transaction, and don't store it. |
| `distance` | `DOUBLE` | Exact cosine distance from the query (brute-force scan, not approximate). Diversify/Repulsion applies if enabled on the session. |
| `scan_pos` | `BIGINT` | The raw 0-indexed position within this call's corpus scan. Distinct from `doc_id`: it identifies a result within this call (for example the `result_handle` argument of `fractal_isolate_background`), not a database row. |

**Why `doc_id` is a row locator and not an index.** `rowid` on a base
table stays stable across updates in the same database, which makes it
usable as the join key back to the row inside one connection lifetime.
No such column exists on every relation: a view generally has none.
When the scanned relation cannot select `rowid`, `doc_id` degrades to
the 0-indexed scan position and equals `scan_pos`. The raw `scan_pos`
is therefore always present: it distinguishes the row-locator regime
from the degraded regime without either of them being hidden -- a
result whose `doc_id` equals its `scan_pos` is telling you it was the
degraded path, not that the table's first row happened to match.

---

## `fractal_hybrid_clinical_search`
**Cohort-Restricted Telemetry**

Wraps `fractal_search_telemetry` but restricts the search to a specific subset of documents.

### Signature
```sql
SELECT doc_id, distance, scan_pos FROM fractal_hybrid_clinical_search(
    table_name  VARCHAR,
    vector_col  VARCHAR,
    query       DOUBLE[],
    doc_ids     VARCHAR[],
    k           INTEGER
);
```

### Arguments
| Argument | Type | Description |
| --- | --- | --- |
| `doc_ids` | `VARCHAR[]` | The cohort: an array of stringified `rowid` values, computed by ordinary SQL, for example `SELECT list(CAST(rowid AS VARCHAR)) FROM patients WHERE age > 65 AND condition = 'sepsis'`. Deliberately a row-id array rather than a raw SQL filter string, so no dynamic-SQL injection surface exists here. |

`doc_id`, `distance`, and `scan_pos` have the same semantics as `fractal_search_telemetry` (including the not-a-durable-identifier `rowid` caveat), with `scan_pos` counted within this call's cohort-filtered corpus rather than the whole table. Errors with `doc_ids cohort matched no rows` if the cohort matches zero rows.

### Example
```sql
SELECT t.doc_id, d.id, t.distance
  FROM fractal_hybrid_clinical_search(
           'patients', 'vitals_emb',
           [0.4, 0.1, 0.2]::DOUBLE[],
           (SELECT list(CAST(rowid AS VARCHAR))
              FROM patients WHERE age > 65 AND condition = 'sepsis'),
           5) t
  JOIN patients d ON d.rowid = CAST(t.doc_id AS BIGINT);
```

---

## `fractal_search_trajectory`
**Drift-Vector Search**

Searches near the delta between two states ($\Delta = V_{current} - V_{baseline}$) to find a matching trajectory in historical data.

### Signature
```sql
SELECT doc_id, distance FROM fractal_search_trajectory(
    table_name       VARCHAR,
    vector_col       VARCHAR,
    baseline_vector  DOUBLE[],
    current_vector   DOUBLE[],
    k                INTEGER
);
```

**Note.** `doc_id` here is the 0-indexed scan position (`BIGINT`), not a
`rowid`. Only `fractal_search_telemetry` and `fractal_hybrid_clinical_search`
return `doc_id` as a stringified `rowid`.

No `fractal_vector`-typed overload -- this build has no bespoke vector
catalog type; `DOUBLE[]` is the only form.

---

## `fractal_cross_modal_search`
**Weighted Modality Concatenation**

Searches a combined space of two different modalities (e.g., morphology and clinical data) using a weighted concatenation.

### Signature
```sql
SELECT doc_id, distance FROM fractal_cross_modal_search(
    table_name         VARCHAR,
    vector_col         VARCHAR,
    morphology_vector  DOUBLE[],
    clinical_vector    DOUBLE[],
    alpha_weight       DOUBLE,
    k                  INTEGER
);
```

### Arguments
| Argument | Type | Range | Description |
| --- | --- | --- | --- |
| `alpha_weight` | `DOUBLE` | $[0, 1]$ | Weight given to the morphology vector. $(1 - \text{alpha})$ is given to the clinical vector. |

**Note.** `doc_id` here is a **0-indexed scan position** (`BIGINT`), not a
`rowid` -- same semantics as `fractal_search_trajectory` above; only
`fractal_search_telemetry` and `fractal_hybrid_clinical_search` return the
stringified-rowid `doc_id`.

No `fractal_vector`-typed overload -- same note as `fractal_search_trajectory` above.

---

## Stateful Diversify & Feedback

Scout Discovery (`fractal_search_explore`) is *stateless* diversity: MMR
spreads one result set within a single call. The **Diversify/Repulsion**
layer adds *stateful* diversity **across searches**: a session records which
results the user rejected, and subsequent searches actively avoid the
neighborhoods of those rejected results ("shadows"). This is the real
differentiator over plain top-K or MMR: neither of which is stateful across
searches.

The layer is **off by default** (bit-for-bit identical to v1.0 behavior); it
must be enabled per session, and it is session-scoped. Shadows do not persist
across connections.

### `fractal_diversify_enable()` / `fractal_diversify_disable()`
Turn the Diversify/Repulsion layer on or off for the current session. Both
return `BOOLEAN` (`true`) -- DuckDB scalar functions have no `void` return
type, so this build's `RETURNS void` equivalent is `RETURNS BOOLEAN` /
always `true` on success (an error is thrown, not a `false` return, on
failure).

Session-scoped state here means **per DuckDB connection**, kept
with the connection -- not shared with other connections in this
process.

### `fractal_diversify_set_params(...)`
Tunes the repulsion layer. DuckDB scalar functions can't declare SQL-level
defaults, so this is registered as arity overloads (0 through 6 positional
args) rather than named-DEFAULT-NULL args -- passing fewer than 6 args, or
passing `NULL` for a given arg, both keep the core's current value for that
field:

```sql
-- call with 0..6 args; any trailing/positional NULL also means "keep current"
fractal_diversify_set_params(
    window_n               INTEGER,
    stall_threshold        DOUBLE,
    repulsion_sigma        DOUBLE,
    repulsion_weight       DOUBLE,
    max_shadows_considered INTEGER,
    tail_buffer_cap        INTEGER
) -> BOOLEAN
```

| Argument | Description |
| --- | --- |
| `window_n` | Search-context window size the repulsion layer tracks. |
| `stall_threshold` | Diversity-stall threshold below which repulsion intensifies. |
| `repulsion_sigma` | Gaussian width of each shadow's repulsion field. |
| `repulsion_weight` | Overall strength of the repulsion penalty. |
| `max_shadows_considered` | Cap on how many recorded shadows influence a search. |
| `tail_buffer_cap` | **Reserved.** Reserved for a future shadow-index release: the value is range-checked (1-1024) and stored, but has no effect on search or the ledger in v2.0.x. |

Takes effect on the next `fractal_search` call.

### `fractal_detect_collapse()` -> `DOUBLE`
Returns the current **D_q** (diversity quotient) from the last search on this
session's context. Low values indicate the search population has collapsed
toward a single basin. Returns `NaN` if no search has run yet or Diversify is
disabled.

### `fractal_explain_result()` -> `VARCHAR`
Session-level Diversify diagnostics as JSON text:
`{dq, diversify_enabled, overhead_p99_us}`. This is a session health
readout, **not** a per-candidate "this result was penalized by shadow X"
trace. The core ABI does not currently expose shadow attribution at that
granularity.

### `fractal_feedback_report(result_handle, kind, dwell_ms)` -> `BOOLEAN`
Reports engagement on a prior search result, feeding the shadow store when
Diversify is enabled (inert otherwise). Registered as 2- and 3-arg
overloads (no SQL-level default for `dwell_ms`).

| Argument | Type | Description |
| --- | --- | --- |
| `result_handle` | `BIGINT` | The 0-based corpus scan position the result came from (matches the `scan_pos` returned by the telemetry search functions, not their `rowid`-based `doc_id`). |
| `kind` | `VARCHAR` | One of `'dwell'`, `'positive'`, `'negative'`. Anything else raises `kind must be one of ...`. |
| `dwell_ms` | `INTEGER` | Optional (omit for the 2-arg overload). Dwell time in ms. |

`fractal_isolate_background(result_handle)` is a convenience wrapper that
reports negative engagement with no dwell time.

### The stateful loop
The canonical usage is a feedback-driven re-search loop:

```sql
SELECT fractal_diversify_enable();                -- 1. turn on the repulsion layer
SELECT UNNEST(fractal_search_explore(emb, [...]::DOUBLE[]))  -- 2. first (diverse) search
FROM catalog;
SELECT fractal_feedback_report(0, 'negative');    -- 3. reject the top result
SELECT UNNEST(fractal_search_explore(emb, [...]::DOUBLE[]))  -- 4. re-search the SAME query
FROM catalog;
-- 5. confirm the rejected row's neighborhood is now avoided
SELECT fractal_explain_result();                  -- -> JSON: {dq, diversify_enabled, ...}
SELECT fractal_diversify_disable();               -- 6. turn it off when done
```
