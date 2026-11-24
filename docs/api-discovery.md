<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# Discovery API Reference

The Discovery tier provides high-precision and diverse retrieval mechanisms. Unlike traditional vector search, it treats the embedding space as a continuous optimization problem.

---

## `fractal_sfs_converge`
**Two overloads under one name: per-row Sniper distance, and the raw best-point optimizer**

`fractal_sfs_converge` is overloaded by argument count/type -- DuckDB resolves
which one you meant the same way it resolves any other overloaded function:

**Overload 1 -- Sniper Mode (per-row cosine distance), a DuckDB-idiomatic
addition.**
```sql
fractal_sfs_converge(vector DOUBLE[], query_vector DOUBLE[]) -> DOUBLE
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
SELECT id, fractal_sfs_converge(embedding, [0.1, 0.2, -0.3]::DOUBLE[]) AS dist
FROM my_embeddings
ORDER BY dist
LIMIT 10;
```

**Overload 2 -- raw SFS best point.**
```sql
fractal_sfs_converge(query DOUBLE[]) -> DOUBLE[]
fractal_sfs_converge(query DOUBLE[], iterations INTEGER) -> DOUBLE[]
fractal_sfs_converge(query DOUBLE[], iterations INTEGER, population_size INTEGER) -> DOUBLE[]
fractal_sfs_converge(query DOUBLE[], iterations INTEGER, population_size INTEGER, diffusion_factor INTEGER) -> DOUBLE[]
```
Takes only the query and returns the raw SFS-refined best point -- a
standalone optimizer call with no per-row scoring (registered as 1-4-arg
overloads since DuckDB scalar functions have no SQL-level defaults).

```sql
SELECT fractal_sfs_converge([0.6, 0.8, 0.0]::DOUBLE[], 50);
```

---

## `fractal_search` (the indexed search)
**Approximate nearest neighbours from a native IVF index -- and always an exact distance**

`fractal_search` is a TABLE function: it takes a table, the column that holds
the vectors, a query and how many neighbours you want, and returns the same
columns as `fractal_search_telemetry` (`doc_id`, `distance`, `scan_pos`).

```sql
fractal_search(table_name VARCHAR, vector_col VARCHAR, query DOUBLE[], k INTEGER, options VARCHAR)
    -> TABLE(doc_id VARCHAR, distance DOUBLE, scan_pos BIGINT)
```

A TABLE function cannot be overloaded in DuckDB's C API, so **every argument is
positional and required**: the five-argument form is the only one.

| Argument | Type | Description |
| --- | --- | --- |
| `table_name` | `VARCHAR` | The table to search. |
| `vector_col` | `VARCHAR` | The column holding the vectors (`DOUBLE[]` or `FLOAT[]`). |
| `query` | `DOUBLE[]` | The query vector. |
| `k` | `INTEGER` | How many neighbours to return (1..1000). |
| `options` | `VARCHAR` | A JSON object (see below). `{}` is fine. |

```sql
SELECT * FROM fractal_search('documents', 'embedding', [0.1, 0.2, -0.3]::DOUBLE[], 10, '{}');
```

**The index never returns an approximate distance.** The index proposes the
candidates; every one of them is then fetched from the base table and its
distance is recomputed with the shared double-precision cosine (the same one
`fractal_vector_cosine_distance` uses). A row that was deleted after the
build is dropped, ties break on the row id, and the results are ordered by
distance then id. With no index (or with `"use_index": false`) the call is an
exact scan of the whole table.

**Indexed search does not apply Diversify repulsion.** There is no repulsion
in this host's search surface at all: use `fractal_search_explore` (Scout) when
you want a diverse population rather than the nearest neighbours.

#### The options

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `index` | `VARCHAR` | the index on (table, column) | Which index to use. |
| `nprobe` | `INTEGER` | the calibrated value | How many cells to probe. |
| `rerank` | `INTEGER` | 30 (INT8), 40 (INT4), 0 (FP16/FP32) | How many candidates to verify exactly. |
| `use_index` | `BOOLEAN` | `true` | `false` forces the exact scan. |
| `verify` | `BOOLEAN` | `true` | `false` returns the index's approximate distances (not recommended). |
| `model` | `VARCHAR` | -- | Refuse the search unless the index was built with that model. |
| `id_col` | `VARCHAR` | the table's single-column PRIMARY KEY | The stable row id the index stores. |
| `ids` | `BIGINT[]` (JSON array) | -- | Restrict the search to a set of row ids: `'{"ids":[5,77,100]}'`. Ids that are not rows are ignored. See below. |

#### Restricting a search to a set of rows (`ids`)

This is the one-call form of "index plus filter": compute the allowed ids with ordinary SQL, then pass them in.

```sql
SELECT * FROM fractal_search('docs', 'embedding', [0.1, 0.2, 0.3]::DOUBLE[], 5,
         json_object('ids', (SELECT list(id) FROM docs WHERE tenant = 'acme'))::VARCHAR);
```

A short set (up to 4096 ids), or a table with no index, is scanned exactly: only those rows are read, so the answer is the true nearest of the set. A longer set goes through the index and is filtered, which keeps it fast on a big table; if that leaves fewer than `k` rows, the set is scanned exactly, so the answer is never short just because the index's shortlist missed the set. Every distance is exact either way, and `fractal_index_info`'s `last_search.used_index` says which path ran. A malformed `ids` (not a JSON array of integers) is an error; an empty array returns no rows.

#### The delta, and the "committed rows only" rule

A row whose id is **greater than the largest indexed id** was committed after
the build: it is not in the index, so it is scanned exactly and merged into the
result. `fractal_index_info` reports the delta (`has_delta`, `stale`).

The nested queries the extension runs (the index build, the candidate fetch)
run on a pooled connection in **its own autocommit frame**: rows written in the
caller's still-open transaction are **invisible** to them. Only committed rows
are indexed and searched.

#### The row id

DuckDB's `rowid` is **not stable**, so the index stores a stable primary key:
the table's single-column `PRIMARY KEY` by default, or the column named by the
`id_col` option. `doc_id` is that value rendered as text; `scan_pos` is the
same value as an integer (an indexed search does not scan the table, so there
is no scan position).

---

## `fractal_index_create` / `_rebuild` / `_refresh` / `_ensure` / `_drop` / `_info` / `_list`
**Build, refresh and inspect the native IVF index**

| Function | Returns | Meaning |
| --- | --- | --- |
| `fractal_index_create(table_name, vector_col [, options])` | `VARCHAR` (JSON) | Build an index over the column and store it in the database. |
| `fractal_index_rebuild(name)` | `VARCHAR` (JSON) | Rebuild the index from the current rows, keeping its options. |
| `fractal_index_refresh(name)` | `VARCHAR` (JSON) | Fold the rows added since the build into the cells, without retraining. |
| `fractal_index_ensure(table_name, vector_col [, options])` | `VARCHAR` (JSON) | Leave the index fit to use: build it when missing (`created`), fold in a few added rows (`refreshed`), rebuild after a large change (`rebuilt`), otherwise change nothing (`unchanged`). Returns `{name, action, status, generation, rows}`. |
| `fractal_index_drop(name)` | `BIGINT` | `1` when the index was dropped. |
| `fractal_index_info(name)` | `VARCHAR` (JSON) | The index's format, sizes, staleness, status, advice, calibration and last-search statistics. |
| `fractal_index_list()` | table | One row per index: `name`, `table_name`, `vector_col`, `format`, `dim`, `rows`, `rows_now`, `stale`, `status`, `generation`. |

The index lives in two ordinary tables, so it travels with the database file:
`fractal_index_meta` (one row per index) and `fractal_index_cells` (one row
per cell). A build writes a **new generation**: the cell rows are written
first and the metadata pointer is flipped in one statement afterwards, so a
reader only ever sees a complete generation.

#### One call for a setup script: `fractal_index_ensure`

`fractal_index_ensure(table_name, vector_col [, options])` looks at the index on that table and column and does only what is needed: it builds the index when none exists (`created`), folds in the added rows when that is all the advice asks for (`refreshed`), rebuilds when more than a quarter of the rows were added or more than a fifth deleted (`rebuilt`), and otherwise leaves it alone (`unchanged`; a `degraded` index is rebuilt only when you pass new options). The options are used only when it builds. A search never builds or changes an index.

#### Agents and the index

The agents that find the nearest row (`fractal_agent_route_task`, `fractal_agent_outlier_intercept`, `fractal_agent_schedule_workload`) and the retrieval agents (`fractal_rag_agent`, `fractal_search_agent`) scan exactly by default. `fractal_config_set('agent_use_index', ...)` takes `off` (the default), `on` and `auto`. In `auto` an agent goes through an index only when the index is `ready` and the table has at least `agent_index_min_rows` rows (default 10000); otherwise it scans exactly. Every distance is still the exact cosine. See [api-agency.md](api-agency.md).

#### Keeping an index current: `fractal_index_refresh`

Rows added after the build are scanned exactly and merged into every search, so an index never misses a new row, but each search pays for the unindexed rows. `fractal_index_refresh(name)` folds them into the cells: each new row is encoded with the index's existing model (nothing is retrained), staged, and merged into a **new generation** of the cells in one statement, with the metadata pointer flipped last, so a reader only ever sees a complete generation. It returns `{"name", "added", "rows", "generation", "refreshed"}`; with nothing to add it changes nothing (`"refreshed": false`). A refresh does not touch deleted rows (they are already dropped from results) or rows whose vector was changed in place, and it keeps the cells the original build trained, so when a large share of the table is new, a rebuild fits the data better than a refresh does. Like the build, it reads only **committed** rows.

#### Is it healthy? `fractal_index_info` and `fractal_index_list`

`fractal_index_info(name)` carries a verdict next to the numbers:

| `status` | Meaning |
| --- | --- |
| `ready` | Nothing needs doing: the build's calibration reached its recall target and the table has not outgrown the index. A few deleted rows do not change this (they are dropped from results; `stale` is still `true` and `rows_deleted_since_build` counts them). |
| `stale` | There is something to do: rows were added since the build, or more than a fifth of the rows were deleted. |
| `degraded` | The build's own calibration did not reach its recall target (typical of INT8 or INT4 codes on tightly clustered data). |
| `empty` | The table has no vectors left. |
| `orphaned` | The table, or the vector or key column, the index was built on no longer exists (the catalog outlives it). `fractal_index_drop` removes the index. |

`advice` is a JSON array of plain sentences, most useful first, for example `"refresh: 60 rows (10% of the index) were added since the build; fractal_index_refresh folds them in"`, `"rebuild: 30% of the rows (180) were deleted since the build; they are dropped from results but still held in the cells"` or `"the build's calibration reached recall 0.63 against a target of 0.95; rebuild with vector_format FP16 or FP32, or search with a larger rerank"`. `rows_added_since_build` and `rows_deleted_since_build` give the counts. The advice recommends a refresh while the added rows are a minor share (up to a quarter of the index) and a rebuild beyond that, or when more than a fifth of the rows were deleted. It is advice only, never an error.

`fractal_index_list()` is the catalog, one row per index: `SELECT * FROM fractal_index_list();` gives `name`, `table_name`, `vector_col`, `format`, `dim`, `rows` (indexed), `rows_now`, `stale`, `status` and `generation`, ordered by name, and no rows when the database has no index.

#### The build options

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `name` | `VARCHAR` | `<table>_<column>` | The index's name. |
| `vector_format` | `VARCHAR` | `INT8` | `INT8`, `INT4`, `FP16` or `FP32`. |
| `nlist` | `INTEGER` | `sqrt(rows)` | The number of cells (at most 4096). |
| `pca_dim` | `INTEGER` | `dim/4` | The PCA basis size for `INT8`/`INT4`. |
| `iters` | `INTEGER` | 6 | The k-means iterations. |
| `sample` | `INTEGER` | 50000 | The training sample size. |
| `seed` | `BIGINT` | 1 | The training seed. |
| `target_recall` | `DOUBLE` | 0.95 | The recall the calibration aims at. |
| `calibration_samples` | `INTEGER` | 200 | How many rows the recall calibration samples. |
| `id_col` | `VARCHAR` | the table's single-column PRIMARY KEY | The stable row id the index stores. |

```sql
SELECT fractal_index_create('documents', 'embedding',
    '{"name":"documents_embedding","vector_format":"INT8","nlist":64}');
```

**The build streams.** The corpus is never held in memory: one pass feeds the
k-means/PCA trainer, a second pass encodes every row straight into a staging
table, and the engine folds that into the per-cell rows. Only the recall
calibration needs the corpus in memory, and it is skipped (with a note in
`fractal_index_info`) when the corpus does not fit the cap.

`fractal_index_info` also reports the **last search's statistics**:
`last_search.rows_scanned` is how many rows the index actually read, and
`last_search.used_index` says whether it did. A search that silently fell back
to a flat scan shows `used_index: false` and a row count equal to the table's.

---

## `fractal_index_candidates`
**The candidate set Scout consumes**

```sql
fractal_index_candidates(table_name VARCHAR, vector_col VARCHAR, query DOUBLE[], options VARCHAR)
    -> TABLE(doc_id VARCHAR)
```

Returns the row ids of the `near` nearest cells in full, plus `per_cell`
representatives of every other cell, plus the rows newer than the index (the
delta). The options are `near` (default 6), `per_cell` (default 1) and
`index`.

---

## The precision contract

Every SQL-visible distance in this extension is computed the same way, and
the same way in every FractalSQL host:

* **One cosine.** The shared double-precision implementation in
  `src/fsql_precision.h` is the only one: `fractal_vector_cosine_distance`,
  `fractal_vector_cosine_similarity`, the per-row SFS distance and the indexed
  search's verification all route through it.
* **Double accumulation, one rounding.** Norms, dot products and distances are
  accumulated in `double`, in a fixed sequential order, and rounded once to
  `float32` where the contract is a `FLOAT`.
* **No contraction, no vectorisation.** The files that carry the float paths
  are built with `-ffp-contract=off -fno-tree-vectorize` (`/fp:precise
  /Qvec-` on MSVC), so the results are bit-identical on every platform.
* **Ties break on the row id**, so two equal distances always come back in the
  same order.

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

## `fractal_sfs_converge_debug`
**SFS Trajectory Trace**

Runs raw SFS (like `fractal_sfs_converge`'s raw best-point overload above, not this build's per-row `fractal_sfs_converge` sniper mode) and returns a detailed trace of the convergence process as JSON text.

> **Renamed.** This was `fractal_search_debug`; the table-free convergence function was
> renamed because it runs SFS toward a direction and is not a retrieval function:
> `fractal_search` -> `fractal_sfs_converge` and `fractal_search_debug` ->
> `fractal_sfs_converge_debug`. There is no alias: the old name is refused with a message
> that names the new one.

### Signature
```sql
-- DuckDB scalar function, no SQL-level defaults -- all four args required.
fractal_sfs_converge_debug(
    query            DOUBLE[],
    iterations       INTEGER,
    population_size  INTEGER,
    diffusion_factor INTEGER
) -> VARCHAR  -- JSON document as text
```

> **DuckDB note.** In the other FractalSQL editions `fractal_sfs_converge_debug`
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
**Persisted ledgers.** Flushing a ledger writes a QTL v2 snapshot: every entry's weight
and, for a rejected row, the repulsion shape (intensity and sigma) it was recorded with.
Loading restores that snapshot exactly -- the same rejections, with the same strength -- and
**replaces** the in-memory ledgers, so whatever the session had recorded before the load is
gone. A ledger written by an older version (which stored no weights) comes back with every
entry at weight 1.0, taking its repulsion shape from the current session's parameters.

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

Takes effect on the next `fractal_sfs_converge` call.

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

## Which functions use the index

The `agent_use_index` setting (`off` by default; the key, GUC, module argument or property that carries it on each host is in the settings table in [Reasoning Setup](reasoning-setup.md)) decides whether the agents below search through a `fractal_index` when one covers the table and column. Every distance an indexed search returns is still exact, and rows added after the build are scanned exactly. This table lists what goes through the index and, for the rest, why not.

| Function or agent | Search it does | Index |
| --- | --- | --- |
| `fractal_search` | nearest rows, exact scan or index | Yes: this is the indexed search |
| `fractal_agent_route_task`, `fractal_agent_schedule_workload` | the nearest row | Yes, with `agent_use_index` |
| `fractal_agent_outlier_intercept` (cosine) | the nearest row | Yes, with `agent_use_index` (L2 scans exactly) |
| `fractal_search_agent`, `fractal_rag_agent` | the top rows for a question | Yes, with `agent_use_index`; a metadata filter restricts the indexed search to the matching rows |
| `fractal_agent_recall_hybrid` | the nearest rows within a cohort | Yes where the host has it and the cohort is a list of row ids: the cohort goes to the indexed search as its `ids` option (SQLite, PostgreSQL, DuckDB, MariaDB) |
| `fractal_hybrid_clinical_search` | the nearest rows within a cohort | No: exact scan of the cohort |
| `fractal_agent_rebalance_sibling`, `fractal_agent_detour_classify`, `fractal_agent_track_anomaly`, `fractal_agent_trajectory_predict`, `fractal_search_trajectory`, `fractal_agent_patient_deterioration_triage` | nearest row to a computed vector (current minus baseline) | No: exact scan. The index was tuned with queries taken from the rows themselves, and a computed query has not been measured against it |
| `fractal_cross_modal_search` | nearest rows to a combined vector | No: exact scan, for the same reason |
| `fractal_search_telemetry`, `fractal_agent_recommend_diverse`, `fractal_agent_feedback_audit` | exact scan with Diversify repulsion | No, by design: the repulsion needs every row's distance, and the indexed search does not apply it |
| `fractal_search_explore`, `fractal_agent_plan_explore` | population (Scout) search | No, by design: the search is exploratory, not nearest-row |
| `fractal_index_candidates` | a shortlist of ids from the index | It is the index; the shortlist is for a caller's own follow-up search |
| the other agents (allocate, anomaly triage, regime triage, loop detection, data analyst, SQL agent, and so on) | no vector search | Not applicable |
