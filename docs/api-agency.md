<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# Sovereign Agency

> **Result shape: read this first.** All sixteen recipe agents ARE
> implemented here. Each `fractal_agent_*` name registers with this
> extension itself, as a DuckDB scalar function returning one JSON
> document: an object, or an array of objects for `recall_hybrid`,
> `recommend_diverse`, and `diverse_portfolios`. A call is a plain
> whole-document `SELECT fractal_agent_<name>(...)` -- there is no
> composite-row to unpack. The **Returns** lines below are written
> as a composite row: the fields they name are the keys of this build's
> JSON document.
> **[Building blocks: the six Universal
> Agents](#building-blocks-the-six-universal-agents)** further down
> documents the rawer demo agents (`fractal_search_agent`,
> `fractal_sql_agent`, `fractal_agent_plan_explore`, ...) -- six native
> table/scalar functions covering search+reasoning composition,
> NL-to-SQL with retry, MCTS-style exploration, trajectory forecasting,
> and loop detection. Start there.

FractalSQL is bundled with **sixteen agents**: autonomous,
self-correcting routines that compose the extension's Discovery, Analytics, and
Cognition primitives into end-to-end workflows. Each agent is a *recipe* for a
recurring agentic pattern: "drift on a metric series," "match a task to the best
capable sub-agent," "block an action near a known-bad state." You pick the recipe
that matches your problem, point it at your tables and columns, and get back real
computed results plus a human-readable read.

This page is written for the **driver**, not the mechanic. For each agent you'll
find: what problem it solves, when to reach for it, the inputs it needs, how it
works inside, what it returns, a runnable example, and the non-obvious notes.
If you want to build a recipe that isn't in the box, see
[Composing your own](#composing-your-own) and the six Universal Agent building
blocks further down.

> **What's a "recipe agent" vs. a "Universal Agent" vs. a "Domain Agent"?**
> The **recipe agents** (below) are the sixteen productized calls, registered
> as scalar functions with this extension. The **Universal Agents** (lower
> down) are the rawer building blocks the recipes compose -- implemented in
> this build as native DuckDB functions. The **Domain Agents** are the
> original reference blueprints in the `demo/demo-vertical-*.sql` scripts;
> the recipe agents are their productized form.

---

## Install

```sql
LOAD '/path/to/fractalsql.duckdb_extension';
```

No separate agents extension and no install/activation step at all -- one
`LOAD` registers all sixteen recipe agents (plus the six Universal Agents)
immediately.

Thirteen are **cognition** agents that end in a `fractal_reason` step and need
reasoning configured (see [`reasoning-setup.md`](reasoning-setup.md)). Three are
**pure retrieval/analytics** with no LLM step (`recall_hybrid`,
`recommend_diverse`, `feedback_audit`) and need no endpoint. One of the
thirteen (`diverse_portfolios`) is additionally enterprise tier -- see its
recipe below. Confirm reasoning before running the cognition agents:

```sql
SELECT fractal_reason('reply with a short confirmation');
```

---

## Which agent should I use?

Pick by the problem shape, not by the function name.

| Your problem | Agent | Recipe in one line | LLM? |
| --- | --- | --- | --- |
| "Is this entity's metric series drifting into a new regime?" (table-backed, per-entity) | `anomaly_triage` | drift exponent on one entity's series → LLM triage | ✓ |
| "Is this single series in a regime change?" (array-in, no table) | `regime_triage` | DFA + drift over one series → LLM triage | ✓ |
| "Did this vessel/host track deviate from the fleet?" | `track_anomaly` | trajectory deviation + heading DFA → LLM triage | ✓ |
| "Did this vehicle detour, and how complex is its GPS trace?" | `detour_classify` | trajectory deviation + box-counting → LLM classify | ✓ |
| "Is my sensor grid's coverage degrading?" | `network_coverage_alert` | spatial morphology + telemetry drift → LLM alert | ✓ |
| "What's the best cardinality-constrained allocation?" | `allocate` | SFS Sharpe optimizer → LLM rationale | ✓ |
| "Rebalance, and compare to the nearest historical allocation?" | `rebalance_sibling` | optimizer + trajectory search → LLM rationale | ✓ |
| "Give me several distinct good portfolios, not just one?" (enterprise) | `diverse_portfolios` | multimodal optimizer → LLM tradeoff summary | ✓ |
| "Which sub-agent should handle this incoming task?" | `route_task` | nearest-capability search + budget accounting → LLM rationale | ✓ |
| "Which node should this workload land on (with vector refinement)?" | `schedule_workload` | `fractal_sfs_converge` refine + nearest node → LLM rationale | ✓ |
| "Should I block this proposed action (is it near a known-bad state)?" | `outlier_intercept` | distance-to-bad-state safety barrier → LLM justification | ✓ |
| "Triage a patient against a cohort + baseline→current drift" | `patient_deterioration_triage` | cohort search + trajectory drift → LLM triage | ✓ |
| "Ask a natural-language question over my tables" | `data_analyst` | NL→SQL→execute → LLM analysis | ✓ |
| "Recall similar past memories, restricted by a metadata filter" | `recall_hybrid` | cohort-restricted vector recall | -- |
| "Recommend diverse items, avoiding recently-rejected ones" | `recommend_diverse` | repulsion-diverse top-k | -- |
| "Audit my recommender's diversity health" | `feedback_audit` | diversify loop + collapse detection | -- |

> **A guarantee about the outputs.** Every field of each agent's JSON
> document is a **real primitive result, not a literal**. `threat_score` is
> the computed drift exponent; `allocation`/`sharpe` are the optimizer's own
> `{sharpe, weights}` and risk-adjusted return (no hardcoded `0.042`);
> `routed_to` is the real nearest capability name and `confidence` is
> `1/(1+distance)`; `intercepted` is a real distance-vs-threshold comparison;
> `mem_id`/`content` are the real recalled row; `item_id`/`score` are the
> real catalog id and `1 − cosine_distance`. The thirteen cognition agents'
> `triage_summary` / `rationale` / `analysis` keys are real `fractal_reason`
> output. Every agent raises a clean `ERROR` on bad input (empty target
> table, NULL series, filter matching no rows) with an agent-named message.

---

### Writing these examples in DuckDB

Most examples below carry the recipe-set's `float8[]` literals and
`generate_series`/`now()` fixture DDL as written. The mechanical notes for a
DuckDB session:

| As written below | DuckDB note |
| --- | --- |
| `SELECT col1, col2, ... FROM fractal_agent_x(args)` | `SELECT fractal_agent_x(args)` -- one scalar call returning a single JSON document; pick fields with `json_extract_string(result, '$.col1')` |
| `ARRAY[0.1, 0.2, 0.3]::float8[]` | as-is (a `DOUBLE[]` literal -- the vector-argument convention this build uses everywhere; see [vectorizer-setup.md](vectorizer-setup.md) / [api-discovery.md](api-discovery.md)) |
| `timestamptz`, `now()`, `generate_series(1, 96)` | `now() - (96 - gs) * interval '1 second'` and `generate_series` all work natively in DuckDB |
| the [id-resolution](#a-note-on-id-resolution) `rowid`-`row_number()` mapping | identical -- the agents resolve ids this way internally; you only need it yourself when composing primitives by hand |

Every underlying primitive and every argument, default, and return field named
below is the same in this build -- only the call/result shape differs.

---

## The sixteen recipes

> **Result shape note.** Each function below is a DuckDB scalar returning one
> JSON VARCHAR: an object, or an array of objects for `recall_hybrid`,
> `recommend_diverse`, and `diverse_portfolios`. The **Returns** lines still
> name a composite row; those fields are this build's JSON keys instead, and
> the examples below show the whole-document select this build runs. `diverse_portfolios` is the one
> enterprise-gated recipe (see its section).

### Anomaly triage -- `fractal_agent_anomaly_triage`
**Triage drift on one entity's metric time series.**

Use it when you have a per-entity metric series in a table (latency, error rate,
vitals, sensor reading) and want to know whether that entity has drifted into a
new regime: Cybersecurity host triage, DevOps incident triage, MedTech patient
monitoring, Smart-Cities sensor regime change. For a single series you already
hold as an array (no per-row table), use [regime_triage](#regime-triage--fractal_agent_regime_triage)
instead.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `log_table` | `text` | -- | your metric table |
| `metric_col` | `text` | -- | the numeric metric column to read as the series |
| `time_col` | `text` | -- | the timestamp column to order the series by |
| `filter_col` | `text` | -- | the entity-id column to filter on (e.g. `host`) |
| `filter_val` | `text` | -- | which entity (e.g. `'host-1'`) |
| `baseline_window` | `int` | `32` | recent-window size for the drift comparison |

**How it works.** (1) Reads the entity's metric series ordered by time into a
`float8[]` via dynamic SQL. (2) Runs `fractal_dimension_drift(series, baseline_window)`
for the regime-change drift exponent. (3) Calls `fractal_reason` to synthesize a
human-readable triage over the drift result.

**Returns** one JSON document `{threat_score, anomaly_type, triage_summary}`:
`threat_score` is the real drift exponent; `anomaly_type` is the literal
`'vector_drift'` label; `triage_summary` is the LLM's read.

**Example**
```sql
CREATE TABLE agents_demo_logs (metric float8, ts timestamptz, host text);
INSERT INTO agents_demo_logs (metric, ts, host)
SELECT 50.0 + (gs % 8)::float8 * 1.3 + CASE WHEN gs > 48 THEN 30.0 ELSE 0.0 END,
       now() - (96 - gs) * interval '1 second', 'host-1'
FROM generate_series(1, 96) AS gs;

SELECT fractal_agent_anomaly_triage(
    'agents_demo_logs', 'metric', 'ts', 'host', 'host-1', 32);
```

**Notes.** Raises `fractal_agent_anomaly_triage: no rows in …` if the filter
matches no rows. `baseline_window` must be large enough for DFA (16 is too small
and returns `rc=-1`; 32 is safe).

---

### Allocate -- `fractal_agent_allocate`
**Cardinality-constrained portfolio allocation.**

Use it when you want the best allocation of a fixed number of assets from a
universe: Quant-Finance portfolios, Sovereign-Edge resource allocation, FinTech
rebalancing. You supply expected returns (`mu`) and risk (`cov`); the agent runs
the SFS Sharpe maximizer and reasons a rationale.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `mu` | `float8[]` | -- | expected returns per asset |
| `cov` | `float8[]` | -- | covariance matrix, **flattened 1-D row-major n×n** |
| `cardinality` | `int` | -- | how many assets to hold |
| `context` | `text` | `NULL` | optional label passed to the reason call |

**How it works.** (1) `fractal_optimize_portfolio(mu, cov, cardinality)`: the
SFS cardinality-constrained Sharpe maximizer. (2) Extracts the real Sharpe from
the optimizer's own output. (3) `fractal_reason` explains the allocation.

**Returns** one JSON document `{allocation, sharpe, rationale}`:
`allocation` is the optimizer's `{sharpe, weights}` object; `sharpe` is the
real risk-adjusted return; `rationale` is the LLM's explanation.

**Example**
```sql
-- 2 assets, hold 1; cov is the 2×2 identity flattened to 4 elements (row-major).
SELECT fractal_agent_allocate(
    ARRAY[0.05, 0.1]::float8[],
    ARRAY[1.0, 0.0, 0.0, 1.0]::float8[],
    1,
    '{"portfolio": "agents-demo"}'::text);
```

**Notes.** `cov` must be a **flattened 1-D row-major** matrix, not a 2-D array.
The primitive reads it via `float8_array_to_doubles` and rejects 2-D. A
mismatched `cov` length surfaces the primitive's clean `cov length` ERROR.

---

### Route task -- `fractal_agent_route_task`
**Match an incoming task to the best capable sub-agent.**

Use it as a sub-agent dispatcher: DevOps task routing, Customer Support
intent routing, Cybersecurity analyst routing, Sovereign-Edge orchestration. You
pass the task as an embedding (the agent does not embed it for you); it finds the
nearest capability row and accounts a token budget.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `task_emb` | `float8[]` | -- | the incoming task's embedding (same dim as the capability embeddings) |
| `cap_table` | `text` | -- | your capability/sub-agent table |
| `cap_emb_col` | `text` | -- | the embedding column in that table |
| `cap_id_col` | `text` | -- | the column to return as the routed-to name |
| `budget` | `int` | -- | the caller's token budget |
| `cost_per_route` | `int` | `150` | tokens one routing decision costs |

**How it works.** (1) Searches `cap_table.cap_emb_col` for the nearest
capability. (2) Resolves the returned `doc_id` (DuckDB's `rowid`,
stringified) to the named capability id
(see [id resolution](#a-note-on-id-resolution)). (3) Derives
`confidence = 1/(1+distance)`, accounts `remaining_budget = budget − cost_per_route`.
(4) `fractal_reason` writes a one-line routing rationale.

**Searching through an index.** Step (1) scans the table exactly by default. After
`SELECT fractal_config_set('agent_use_index', 'on')`, and when a
[`fractal_index`](api-discovery.md) covers `cap_table.cap_emb_col`, it searches through the
index instead; every distance is still the exact cosine, and rows added after the build are
scanned exactly. The key is off by default because an index can, rarely, pick a different
nearest row than the exact scan. With no index on the table and column the agent scans exactly.
The key takes three values, `off`, `on` and `auto`: with `auto` the agent goes through the index
only when it is `ready` and the table has at least `agent_index_min_rows` rows (default 10000).
`fractal_agent_outlier_intercept` (cosine), `fractal_agent_schedule_workload` and `fractal_agent_recall_hybrid` follow the same rule. For `recall_hybrid` the nearest `k` rows come through the index and a `filter_col`/`filter_val` cohort becomes the search's ids set (the index's id column must be the table's key); the rows and distances are the same as the scan returns.

**Returns** one JSON document `{routed_to, confidence, remaining_budget, rationale}`;
`routed_to` is the named capability id (or null when nothing matched within budget).

**Example**
```sql
CREATE TABLE agents_demo_caps (capability_name text PRIMARY KEY, emb float8[]);
INSERT INTO agents_demo_caps VALUES
    ('root-cause-analyzer', ARRAY[0.1, 0.2, 0.3]),
    ('capacity-autoscaler', ARRAY[0.9, 0.8, 0.7]),
    ('incident-pager',      ARRAY[0.3, 0.3, 0.9]);

SELECT fractal_agent_route_task(
    ARRAY[0.11, 0.21, 0.31]::float8[],
    'agents_demo_caps', 'emb', 'capability_name', 1000);
```

**Notes.** Raises `no capability rows in …` if the capability table is empty
(the agent pre-checks so its message fires before the C primitive's
`no corpus rows to search`).

---

### Outlier intercept -- `fractal_agent_outlier_intercept`
**Pre-commit safety barrier against known-bad states.**

Use it as a pre-commit screen on a proposed action's state vector: DevOps action
screening, Cybersecurity known-bad-state interception, MedTech out-of-range
vital interception, Sovereign-Edge anomalous command interception. It measures
the distance from the proposed state to the nearest known-bad state and intercepts
if that distance is within a threshold.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `state_vec` | `float8[]` | -- | the proposed action's state vector |
| `history_table` | `text` | -- | your known-bad-state table |
| `emb_col` | `text` | -- | the embedding column in that table |
| `threshold` | `float8` | -- | intercept if the nearest bad state is within this distance |
| `metric` | `text` | `'cosine'` | the distance measure: `'cosine'` (exact telemetry engine, ignores magnitude) or `'l2'` (exact Euclidean, a direct `fractal_vector_l2_distance` scan of the same table). Any other value raises `metric must be 'cosine' or 'l2'`. |

**How it works.** With `metric = 'cosine'` (default): (1)
`fractal_search_telemetry(history_table, emb_col, state_vec, 1)` for the
distance to the nearest known-bad state. (2) `intercepted = distance <
threshold`, a real comparison of a real distance. With `metric = 'l2'`: a
direct minimum over `fractal_vector_l2_distance` across the same table, NULL rows
skipped. (3)
`fractal_reason` justifies the decision in one sentence.

**Returns** one JSON document `{intercepted, metric, reason}`;
`intercepted` is the real distance-vs-threshold comparison, `metric` echoes
which distance measure ran, and `reason` is the LLM's one-sentence justification.

**Example**
```sql
CREATE TABLE agents_demo_badstates (emb float8[]);
INSERT INTO agents_demo_badstates VALUES
    (ARRAY[1.0, 0.0, 0.0]),
    (ARRAY[0.9, 0.1, 0.0]);

-- Near a bad state -> intercepted (cosine, the default).
SELECT fractal_agent_outlier_intercept(
    ARRAY[0.95, 0.05, 0.0]::float8[], 'agents_demo_badstates', 'emb', 0.5);

-- Orthogonal/far -> allowed.
SELECT fractal_agent_outlier_intercept(
    ARRAY[0.0, 1.0, 0.0]::float8[], 'agents_demo_badstates', 'emb', 0.5);

-- Same check under Euclidean distance, where magnitude matters:
SELECT fractal_agent_outlier_intercept(
    ARRAY[0.05, 0.0, 0.0]::float8[], 'agents_demo_badstates', 'emb', 0.5, 'l2');
```

**Notes.** Cosine distance **ignores magnitude**: `[0.1,0.1,0.1]` vs
`[0.9,0.9,0.9]` are parallel (distance 0, "near"), not far. To build a "far"
known-bad fixture, point a *different direction* (e.g. `[0,1,0]` vs `[1,0,0]` →
distance 1). If magnitude should count, pass `'l2'` as the fifth
(`metric`) argument: there, `[0.05,0,0]` sits ~0.856 away from the nearer of
the two bad states above and is allowed under the same threshold. Raises `no bad-state rows in …` if the history table is empty.

---

### Recall hybrid -- `fractal_agent_recall_hybrid`
**Cohort-restricted vector recall (no LLM).**

Use it for memory recall restricted by a metadata filter: Customer Support memory
recall, MedTech cohort-restricted patient search, Smart-Cities zone-filtered
sensor recall. The "hybrid" is the cohort: a strict SQL filter applied *before*
the vector search so `k` is respected within the cohort.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `mem_table` | `text` | -- | your memory/corpus table |
| `vec_col` | `text` | -- | the embedding column |
| `query_vec` | `float8[]` | -- | the query embedding |
| `filter_col` | `text` | `NULL` | metadata column to filter on (NULL = no filter, search all) |
| `filter_val` | `text` | `NULL` | the value to match |
| `k` | `int` | `5` | how many results |
| `id_col` | `text` | `'id'` | the column to return as the id (must be bigint-castable) |
| `content_col` | `text` | `NULL` | the text column to return (NULL = no content) |

**How it works.** (1) Builds a cohort of rowids from the optional filter via
ordinary SQL (NULL filter col/value = search the whole table). (2) Runs the
hybrid search restricted to that cohort. (3) Returns each recalled row's named
id and content columns.

**Returns** one JSON **array** of `{mem_id, content}` objects: the recalled
rows' real id and content (not canned `generate_series` ids or
`"recalled memory snippet N"`).

**Example**
```sql
CREATE TABLE agents_demo_mem (
    session_id bigint, customer_id text, state_vector float8[], content text);
INSERT INTO agents_demo_mem VALUES
    (1001, 'cust-a', ARRAY[0.2, 0.2, 0.2], 'resolved churn via loyalty upgrade'),
    (1002, 'cust-a', ARRAY[0.8, 0.8, 0.8], 'escalated billing dispute to agent'),
    (1003, 'cust-b', ARRAY[0.5, 0.5, 0.5], 'refunded a duplicate charge');

SELECT fractal_agent_recall_hybrid(
    'agents_demo_mem', 'state_vector', ARRAY[0.18, 0.22, 0.2]::float8[],
    'customer_id', 'cust-a', 2, 'session_id', 'content');
```

**Notes.** Raises `filter matched no rows in …` if the filter matches nothing.
`id_col` must be bigint-castable. This agent takes a single
`(filter_col, filter_val)`. For a multi-predicate cohort (e.g.
`age>65 AND condition='sepsis'`), build the cohort yourself and use [patient_deterioration_triage](#patient-deterioration-triage--fractal_agent_patient_deterioration_triage),
which accepts a caller-built `cohort_doc_ids`.

---

### Recommend diverse -- `fractal_agent_recommend_diverse`
**Feedback-aware diverse top-k recommendations (no LLM).**

Use it when you want diverse candidates that avoid recently-rejected items:
Customer Support diverse recovery strategies, Recommendation "you might also
like," Smart-Cities diverse representative-zone sampling. It enables the
session-global Diversify/Repulsion layer, then runs a repulsion-diverse top-k.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `catalog_table` | `text` | -- | your catalog table |
| `emb_col` | `text` | -- | the embedding column |
| `query_vec` | `float8[]` | -- | the query embedding |
| `k` | `int` | `10` | how many results |
| `id_col` | `text` | `'id'` | the column to return as the id (must be bigint-castable) |

**How it works.** (1) Enables repulsion on the engine's shared search context,
so re-searches avoid recently-rejected items reported via
`fractal_feedback_report`. (2) Runs the top-k search over the catalog. (3)
Resolves the returned `doc_id` (DuckDB's `rowid`, stringified) to your named id
(see [id resolution](#a-note-on-id-resolution)).

**Returns** one JSON **array** of `{item_id, score}` objects:
`score = 1 − cosine_distance`, real from the primitive (not canned
`0.95 − i*0.01`).

**Example**
```sql
CREATE TABLE agents_demo_catalog (id bigint, emb float8[]);
INSERT INTO agents_demo_catalog VALUES
    (10, ARRAY[0.1, 0.0, 0.0]),
    (20, ARRAY[0.0, 1.0, 0.0]),
    (30, ARRAY[0.0, 0.0, 1.0]);

SELECT fractal_agent_recommend_diverse(
    'agents_demo_catalog', 'emb', ARRAY[0.12, 0.01, 0.0]::float8[], 3, 'id');
```

**Notes.** Repulsion is a **session-global side effect**: this agent calls
`fractal_diversify_enable()` and leaves it on, so re-searches avoid
recently-rejected items reported via `fractal_feedback_report` for the rest
of the connection; the caller owns that policy. Reset it with a SQL toggle in
the same session, `SELECT fractal_diversify_disable();` (the registered
functions act on the calling connection's own engine context), or run
[feedback_audit](#feedback-audit--fractal_agent_feedback_audit), which runs
the whole audit cycle self-contained and self-disables at its end. `id_col`
must be bigint-castable.

---

### Data analyst -- `fractal_agent_data_analyst`
**Natural-language analytics over any of your tables.**

The horizontal catch-all: the closest thing to a general-purpose agent in the
roster. Use it when no vertical agent fits and you just want to ask a
natural-language question over your tables and get a reasoned answer. It composes
`fractal_sql_agent` (NL→SQL→execute, with its own retry loop) then `fractal_reason`
to synthesize a read of the result. No vertical demo is wired to it.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `question` | `text` | -- | the natural-language question |
| `table_names` | `text[]` | `NULL` | the tables the agent may query |
| `max_retries` | `int` | `2` | how many correction loops on EXPLAIN/execution failure |
| `context` | `text` | `'{}'` | optional label passed to the reason call |
| `auto_execute` | `boolean` | `false` | whether the generated SQL is actually run |

**How it works.** (1) `fractal_sql_agent(question, table_names, max_retries, auto_execute)`:
NL→SQL, with `auto_execute=true` so the statement is run and `result_json` carries
the real row count (or a captured execution-failure reason); with `auto_execute=false`
the statement is validated but not run and `result_json` is NULL. (2) `fractal_reason`
writes a one-paragraph analysis over the result -- only when the statement was run.

**Execution is opt-in.** The agent never runs a statement it generated unless the
caller asks it to. The default call generates and validates the SQL and hands it
back in `generated_sql`, so you can read it and run it yourself; `analysis` and
`result_json` are then NULL. Pass `auto_execute` as `true` for the full
NL→SQL→run→reason path.

**Returns** one JSON document `{analysis, generated_sql, result_json}` plus the
SQL agent's own `question`/`execution_status` keys: `analysis` is the LLM's
read; `generated_sql` and `result_json` are the SQL agent's own real outputs
(no canned constants).

**Example**
```sql
CREATE TABLE agents_demo_data (id int PRIMARY KEY, category text, amount float8);
INSERT INTO agents_demo_data VALUES
    (1, 'hardware', 1200.00),
    (2, 'software',  800.50),
    (3, 'hardware',  450.25);

SELECT fractal_agent_data_analyst(
    'total amount spent per category in agents_demo_data',
    ARRAY['agents_demo_data'], 2, '{}', true);
```

**Notes.** No empty-table guard: there is no fixed table to pre-check;
`fractal_sql_agent` handles its own errors and reports empty/failed results via
`execution_status`. Guard the LLM-facing `fractal_sql_agent` step with a
restricted role (see [Safe Agency & Guardrails](#safe-agency--guardrails)).

---

### Patient deterioration triage -- `fractal_agent_patient_deterioration_triage`
**Cohort-restricted patient triage with baseline→current drift.**

Use it for clinical deterioration triage, or any "nearest patient within a
cohort *plus* baseline→current drift" workflow. The `cohort` parameter
accepts a caller-built multi-predicate cohort (e.g. `age>65 AND condition='sepsis'`)
that [recall_hybrid](#recall-hybrid--fractal_agent_recall_hybrid)'s single
`(filter_col, filter_val)` cannot express.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `patient_table` | `text` | -- | your patient/corpus table |
| `vec_col` | `text` | -- | the embedding column |
| `query_vec` | `float8[]` | -- | the patient to triage |
| `baseline_vec` | `float8[]` | -- | the baseline state for the drift search |
| `current_vec` | `float8[]` | -- | the current state for the drift search |
| `cohort` | `bigint[]` | `NULL` | caller-built cohort of rowids (NULL = all rows) |
| `k` | `int` | `5` | how many cohort neighbors |
| `id_col` | `text` | `'id'` | the column to return as the id (must be bigint-castable) |

**How it works.** (1) Builds the cohort: from `cohort` (a list of rowids) if
supplied, else every row (NULL = no restriction). (2) Runs the hybrid search
for up to `k` nearest patients in the cohort,
ranked ascending by distance, each resolved to its named patient id in the
same query. (3)
Runs the trajectory search for the baseline→current drift -- always a single
result; `k` does not apply here. (4) `fractal_reason` synthesizes the triage
over the single nearest cohort match and the drift, not over every entry in
`cohort_matches`.

**Returns** one JSON document `{nearest_cohort_id, cohort_distance,
drift_distance, rationale, cohort_matches}`.
`cohort_matches` is a ranked array of up to `k` `{"id":..,"distance":..}`
entries; `nearest_cohort_id`/`cohort_distance` are always `cohort_matches[0]`.

**Example**
```sql
CREATE TABLE agents_demo_patients (
    id int PRIMARY KEY, age int, condition text, vitals float8[]);
INSERT INTO agents_demo_patients VALUES
    (1, 72, 'sepsis',    ARRAY[0.90, -0.80, 0.70, 0.60]),
    (2, 64, 'sepsis',    ARRAY[0.10,  0.10, 0.10, 0.10]),
    (3, 78, 'pneumonia', ARRAY[0.20,  0.20, 0.20, 0.20]),
    (4, 81, 'sepsis',    ARRAY[0.85, -0.75, 0.65, 0.55]);

SELECT nearest_cohort_id, cohort_distance, drift_distance, rationale, cohort_matches
FROM fractal_agent_patient_deterioration_triage(
    'agents_demo_patients', 'vitals',
    ARRAY[0.9, -0.8, 0.7, 0.6]::float8[],
    ARRAY[0.1, 0.1, 0.1, 0.1]::float8[],
    ARRAY[0.95, -0.85, 0.75, 0.65]::float8[],
    (SELECT list(rowid)
       FROM agents_demo_patients
      WHERE age > 65 AND condition = 'sepsis'),
    5, 'id');
```

**Notes.** Raises `no patient rows in …` if the table is empty, or `cohort
matched no rows in …` if the cohort is empty. `id_col` must be bigint-castable.
`k` controls only the cohort-search width; the drift search always compares a
single baseline point to a single current point, so it stays fixed at its
nearest point regardless of `k`.

---

### Feedback audit -- `fractal_agent_feedback_audit`
**Recommender diversity audit (pure analytics, no LLM).**

Use it to audit a recommender's diversity health: a self-contained cycle that
enables repulsion on the engine's shared search context, warms the rolling
diversity window with varied queries, reports negative feedback on a target
result, then reads back the diversity quotient and session diagnostics. Unlike
[recommend_diverse](#recommend-diverse--fractal_agent_recommend_diverse),
this agent **self-disables** diversify: it is a complete audit cycle that
leaves the session clean.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `catalog_table` | `text` | -- | your catalog table |
| `emb_col` | `text` | -- | the embedding column |
| `query_vec` | `float8[]` | -- | the audit target's query embedding |
| `warmup_table` | `text` | -- | a table of varied vectors to warm the window |
| `warmup_vec_col` | `text` | -- | the vector column in the warmup table |
| `warmup_count` | `int` | `8` | how many warmup vectors to run |
| `k` | `int` | `3` | top-k for the warmup searches |

**How it works.** (1) `fractal_diversify_enable()` + `fractal_diversify_set_params`
with audit defaults (window 5, repulsion sigma 0.3, weight 0.5). (2) Warms the
`D_q` rolling window by running searches over `warmup_count` varied vectors
from the warmup table (the window is empty until several searches have run;
`detect_collapse` returns NaN otherwise). (3) Captures the audit target's top
result and isolates it as background: the **doc_id is the handle**. (4) Reads
back the diversity quotient and the real session diagnostics. (5) Self-disables
diversify on its way out, so the engine context is left clean.

**Returns** one JSON document `{diversity_quotient, explanation}`: the real
collapse reading (not NaN once the window is warm, forced to 0.0 when
undefined) and the real session diagnostics as the explanation object.

**Example**
```sql
CREATE TABLE agents_demo_fcatalog (id bigint PRIMARY KEY, emb float8[]);
INSERT INTO agents_demo_fcatalog
SELECT gs, ARRAY[random()*2-1, random()*2-1, random()*2-1]
FROM generate_series(1, 20) AS gs;
CREATE TABLE agents_demo_fwarmup (center float8[]);
INSERT INTO agents_demo_fwarmup
SELECT ARRAY[random()*2-1, random()*2-1, random()*2-1]
FROM generate_series(1, 8);

SELECT fractal_agent_feedback_audit(
    'agents_demo_fcatalog', 'emb', ARRAY[0.5, 0.5, 0.5]::float8[],
    'agents_demo_fwarmup', 'center', 8, 3);
```

**Notes.** Raises `no catalog rows in …` if the catalog is empty. Needs a
warmup table with enough varied vectors to fill the window, or
`diversity_quotient` reads 0.0. The audit runs on the engine's shared search
context (the same one [recommend_diverse](#recommend-diverse--fractal_agent_recommend_diverse)
leaves repulsion-enabled on), and its self-disable is the SQL-visible reset
point for that context.

---

### Schedule workload -- `fractal_agent_schedule_workload`
**Schedule a workload onto the best node (with vector refinement).**

Use it for Sovereign-Edge node scheduling, or any "refine a task vector, then
find the nearest capable node" workflow. Like [route_task](#route-task--fractal_agent_route_task)
but with a `fractal_sfs_converge` refinement step that route_task lacks: the "sniper
search" in the abstract search space before the nearest-node lookup.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `task_vec` | `float8[]` | -- | the workload's task vector |
| `node_table` | `text` | -- | your node/capability table |
| `node_emb_col` | `text` | -- | the embedding column in that table |
| `node_id_col` | `text` | -- | the column to return as the node id |
| `iterations` | `int` | `30` | `fractal_sfs_converge` refinement iterations |
| `population` | `int` | `50` | `fractal_sfs_converge` population size |
| `k` | `int` | `5` | how many nearest nodes |
| `context` | `text` | `'{}'` | optional label passed to the reason call |

**How it works.** (1) Refines the task vector in the abstract search space
(the sniper search, `population`/`iterations` controlled). (2) Searches
`node_table.node_emb_col` for the nearest node. (3) Resolves the returned
`doc_id` (DuckDB's `rowid`, stringified) to the named node id
(see [id resolution](#a-note-on-id-resolution)). (4) `fractal_reason` writes a
one-line placement rationale.

**Returns** one JSON document `{assigned_node, confidence, rationale}`:
`confidence = 1/(1+distance)`.

**Example**
```sql
CREATE TABLE agents_demo_nodes (id int PRIMARY KEY, capability float8[]);
INSERT INTO agents_demo_nodes VALUES
    (1, ARRAY[0.9, 0.1, 0.0, 0.0, 0.0]),
    (2, ARRAY[0.0, 0.0, 0.9, 0.1, 0.0]),
    (3, ARRAY[0.1, 0.0, 0.0, 0.0, 0.9]);

SELECT fractal_agent_schedule_workload(
    ARRAY[0.8, 0.1, 0.0, 0.0, 0.1]::float8[],
    'agents_demo_nodes', 'capability', 'id', 30, 50, 5);
```

**Notes.** Raises `no node rows in …` if the node table is empty.

---

### Rebalance sibling -- `fractal_agent_rebalance_sibling`
**Rebalance a portfolio and compare to the nearest historical allocation.**

Use it for Quant-Finance rebalancing: run the SFS cardinality-constrained
optimizer, then find the nearest historical allocation pattern in a snapshots
table, then reason over both. Generalizes the fintech-MCTS reference blueprint.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `mu` | `float8[]` | -- | expected returns per asset |
| `cov` | `float8[]` | -- | covariance, **flattened 1-D row-major n×n** |
| `cardinality` | `int` | -- | how many assets to hold |
| `alloc_table` | `text` | -- | your historical-allocation-snapshots table |
| `alloc_emb_col` | `text` | -- | the embedding column in that table |
| `baseline_vec` | `float8[]` | -- | the baseline for the trajectory search |
| `seed` | `bigint` | `NULL` | optimizer RNG seed (NULL = nondeterministic) |
| `k` | `int` | `5` | how many nearest snapshots |
| `id_col` | `text` | `'id'` | the column to return as the allocation id (must be bigint-castable) |
| `context` | `text` | `'{}'` | optional label passed to the reason call |

**How it works.** (1) Runs the SFS optimizer over `mu`/`cov`/`cardinality`
(seeded when `seed` is given). (2) Extracts the weights as a vector. (3) Runs
the trajectory search for the nearest historical allocation. (4) Resolves its
`doc_id` (a 0-indexed scan position) to the named
allocation id through the rowid-ordering mapping (see
[id resolution](#a-note-on-id-resolution)). (5) `fractal_reason`
synthesizes the rebalance rationale.

**Returns** one JSON document `{sharpe, weights, nearest_alloc_id, nearest_distance, rationale}`.

**Example**
```sql
CREATE TABLE agents_demo_alloc (id bigint PRIMARY KEY, alloc float8[]);
INSERT INTO agents_demo_alloc VALUES
    (1, ARRAY[0.25, 0.25, 0.25, 0.25]),
    (2, ARRAY[0.40, 0.30, 0.20, 0.10]),
    (3, ARRAY[0.10, 0.20, 0.30, 0.40]);

SELECT fractal_agent_rebalance_sibling(
    ARRAY[0.05, 0.10, 0.15, 0.20]::float8[],
    ARRAY[0.04, 0.0, 0.0, 0.0,
          0.0, 0.09, 0.0, 0.0,
          0.0, 0.0, 0.16, 0.0,
          0.0, 0.0, 0.0, 0.25]::float8[],
    4, 'agents_demo_alloc', 'alloc',
    ARRAY[0.25, 0.25, 0.25, 0.25]::float8[], NULL, 5, 'id');
```

**Notes.** `cov` is a **flattened 1-D row-major** matrix. `id_col` must be
bigint-castable: `nearest_alloc_id` is returned as `bigint`, so a text label
column won't do (pass the numeric PK). Raises `no allocation rows in …` if the
allocation table is empty.

---

### Diverse portfolios -- `fractal_agent_diverse_portfolios`
**Enterprise tier.** Companion to `allocate`, above: instead of one
cardinality-constrained portfolio, return several structurally distinct good
ones.

Use it when a single "best" portfolio understates the real decision: a
portfolio manager usually wants to see a few genuinely different ways to hit a
similar risk-adjusted return, not one point estimate. Runs
`fractal_optimize_portfolio_multimodal` (multiple restarts, diverse-selected,
same entropy engine as the single-best optimizer, a licensed capability
gate, not a different algorithm) and reasons once over all the candidates'
tradeoffs.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `mu` | `float8[]` | -- | expected returns per asset |
| `cov` | `float8[]` | -- | covariance, **flattened 1-D row-major n×n** |
| `cardinality` | `int` | -- | how many assets each candidate may hold |
| `n_restarts` | `int` | `8` | independent restarts (upper bound on candidates found) |
| `overlap_threshold` | `float8` | `0.15` | max shared-asset fraction between two returned candidates |
| `quality_frac` | `float8` | `0.90` | candidates must be within this fraction of the best Sharpe found |
| `seed` | `bigint` | `NULL` | accepted for compatibility with the other editions; ignored (runs unseeded) |
| `context` | `text` | `'{}'` | optional label passed to the reason call |
| `objective_mode` | `text` | `'sharpe'` | `'sharpe'` or `'pareto'`: selection strategy, see below |

**How it works.** `objective_mode = 'sharpe'` (default): (1)
composes the enterprise multimodal optimizer with
`n_restarts`, `overlap_threshold`, `quality_frac` for up to `n_restarts`
structurally distinct candidates, sharpe-threshold + asset-overlap selected. (2)
One `fractal_reason` call summarizing the tradeoffs across all of them.
`objective_mode = 'pareto'` instead runs the enterprise multimodal pareto
optimizer with the same `n_restarts` independent searches,
but scored by decomposed return/risk and reduced to a genuine non-dominated
Pareto front (NSGA-II crowding-distance truncation, not sharpe-threshold +
overlap selection); `overlap_threshold`/`quality_frac` are ignored in this
mode. Either mode calls `fractal_reason` once over all the candidates (not
one call per candidate); the prompt framing differs by mode (Sharpe-band
language vs. return/risk-dominance language).

**Returns** one JSON **array**, one object per candidate:
`{candidate_id (0-based), sharpe, weights, rationale}`. `rationale` repeats per
object since it's a single reasoning call covering every candidate. In
`'sharpe'` mode `weights` is a bare array, same as `allocate`. In `'pareto'`
mode `weights` is instead `{"weights": [...], "return": r, "risk": v}`: a
richer object so per-row return/risk are machine-queryable straight from the
agent's output, without a second call to the pareto primitive directly.

**Example**
```sql
SELECT fractal_agent_diverse_portfolios(
    ARRAY[0.05, 0.10, 0.15, 0.20]::float8[],
    ARRAY[0.04, 0.0, 0.0, 0.0,
          0.0, 0.09, 0.0, 0.0,
          0.0, 0.0, 0.16, 0.0,
          0.0, 0.0, 0.0, 0.25]::float8[],
    2, 6);

-- Pareto-front mode: weights carries {weights, return, risk} per candidate.
-- All nine arguments are positional; seed/context take their defaults via NULL.
SELECT fractal_agent_diverse_portfolios(
    ARRAY[0.05, 0.10, 0.15, 0.20]::float8[],
    ARRAY[0.04, 0.0, 0.0, 0.0,
          0.0, 0.09, 0.0, 0.0,
          0.0, 0.0, 0.16, 0.0,
          0.0, 0.0, 0.0, 0.25]::float8[],
    2, 6, NULL, NULL, 'pareto');
```

**Notes.** `cov` is a **flattened 1-D row-major** matrix, same as
`allocate`/`rebalance_sibling`. Enterprise tier: errors with `enterprise
tier not loaded` until the `FRACTALSQL_ENTERPRISE_LIB` environment variable
is set (see [enterprise.md](enterprise.md)); dormant on the
community image by default (see `demo/enterprise-qtl-audit.sql` for
activation). In `'sharpe'` mode, raises `no candidates found` if the
optimizer can't find any candidate within `quality_frac` of the best
Sharpe; in `'pareto'` mode, raises the same error if the non-dominated
front comes back empty (should not happen for `n_restarts >= 1`, but
guarded the same way as the sharpe path for consistency).

---

### Detour classify -- `fractal_agent_detour_classify`
**Classify a vehicle detour: route deviation + GPS-trace complexity.**

Use it for Fleet-Logistics detour classification, or any trajectory-deviation +
GPS-trace-complexity workflow. It combines the route-deviation search across the
fleet with the fractal (box-counting) complexity of the vehicle's GPS trace.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `vehicle_table` | `text` | -- | your fleet table |
| `emb_col` | `text` | -- | the embedding column (searched for the deviation) |
| `baseline_vec` | `float8[]` | -- | the vehicle's baseline route vector |
| `current_vec` | `float8[]` | -- | the vehicle's current route vector |
| `gps_trace` | `float8[]` | -- | the GPS trace as a flat interleaved array |
| `k` | `int` | `5` | how many nearest fleet peers |
| `id_col` | `text` | `'id'` | the column to return as the vehicle id (must be bigint-castable) |
| `boxcount_dim` | `int` | `2` | the box-counting embedding dimension |

**How it works.** (1) Runs the trajectory search over the fleet
for the route deviation. (2) Runs the box-counting measure for the
GPS trace complexity. (3) Resolves the nearest fleet peer's `doc_id` (a
0-indexed scan position) to
the named vehicle id through the rowid-ordering mapping (see
[id resolution](#a-note-on-id-resolution)). (4)
`fractal_reason` classifies the detour.

**Returns** one JSON document `{nearest_fleet_id, trajectory_distance, trace_complexity, rationale}`.

**Example**
```sql
CREATE TABLE agents_demo_vehicles (
    id int PRIMARY KEY, baseline float8[], current float8[]);
INSERT INTO agents_demo_vehicles
SELECT gs, ARRAY[b1, b2, b3, b4], ARRAY[b1+0.05, b2+0.05, b3+0.05, b4+0.05]
FROM generate_series(1, 8) AS gs,
     LATERAL (SELECT random()*2-1 AS b1, random()*2-1 AS b2,
                     random()*2-1 AS b3, random()*2-1 AS b4) AS bl;
-- Give vehicle 1 a deliberate detour.
UPDATE agents_demo_vehicles
   SET current = ARRAY[(baseline::float8[])[1]-0.7, (baseline::float8[])[2]+0.6,
                       (baseline::float8[])[3]+0.5, (baseline::float8[])[4]-0.4]
 WHERE id = 1;

SELECT fractal_agent_detour_classify(
    'agents_demo_vehicles', 'current',
    (SELECT baseline::float8[] FROM agents_demo_vehicles WHERE id = 1),
    (SELECT current::float8[]  FROM agents_demo_vehicles WHERE id = 1),
    (SELECT array_agg(cum ORDER BY t, ord) FROM (
         SELECT t, ord, sum(step) OVER (PARTITION BY ord ORDER BY t) AS cum
           FROM generate_series(1, 100) AS t
          CROSS JOIN LATERAL (VALUES (1, (random()-0.5)*0.3),
                              (2, (random()-0.5)*0.3)) AS s(ord, step)
     ) c),
    5, 'id', 2);
```

**Notes.** Raises `no vehicle rows in …` if the vehicle table is empty.
`id_col` must be bigint-castable.

---

### Track anomaly -- `fractal_agent_track_anomaly`
**Triage a track anomaly: trajectory deviation + heading-change DFA.**

Use it for Maritime track-deviation detection or Cybersecurity beaconing/C2
detection: any trajectory-drift + heading-change-DFA workflow. It combines the
track-deviation search across the fleet with the DFA long-range-correlation
exponent of the heading-change series.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `track_table` | `text` | -- | your fleet/track table |
| `emb_col` | `text` | -- | the embedding column (searched for the deviation) |
| `baseline_vec` | `float8[]` | -- | the track's baseline vector |
| `current_vec` | `float8[]` | -- | the track's current vector |
| `heading_series` | `float8[]` | -- | the heading-change series |
| `k` | `int` | `5` | how many nearest fleet peers |
| `id_col` | `text` | `'id'` | the column to return as the track id (must be bigint-castable) |

**How it works.** (1) Runs the trajectory search over the fleet
for the track deviation. (2) Runs the DFA measure on
the heading-change series. (3) Resolves the nearest fleet peer's `doc_id`
(a 0-indexed scan position) to the
named track id through the rowid-ordering mapping (see
[id resolution](#a-note-on-id-resolution)). (4)
`fractal_reason` triages the track.

**Returns** one JSON document `{nearest_fleet_id, trajectory_distance, dfa_exponent, rationale}`.

**Example**
```sql
CREATE TABLE agents_demo_tracks (
    id int PRIMARY KEY, baseline float8[], current float8[]);
INSERT INTO agents_demo_tracks
SELECT gs, ARRAY[b1, b2, b3, b4], ARRAY[b1+0.04, b2+0.04, b3+0.04, b4+0.04]
FROM generate_series(1, 8) AS gs,
     LATERAL (SELECT random()*2-1 AS b1, random()*2-1 AS b2,
                     random()*2-1 AS b3, random()*2-1 AS b4) AS bl;
-- Give vessel 1 a deliberate track deviation.
UPDATE agents_demo_tracks
   SET current = ARRAY[(baseline::float8[])[1]+0.6, (baseline::float8[])[2]-0.5,
                       (baseline::float8[])[3]-0.9, (baseline::float8[])[4]+0.8]
 WHERE id = 1;

SELECT fractal_agent_track_anomaly(
    'agents_demo_tracks', 'current',
    (SELECT baseline::float8[] FROM agents_demo_tracks WHERE id = 1),
    (SELECT current::float8[]  FROM agents_demo_tracks WHERE id = 1),
    (SELECT array_agg(cum ORDER BY t) FROM (
         SELECT t, sum(step) OVER (ORDER BY t) AS cum
           FROM (SELECT t,
                        (random()-0.5) * (CASE WHEN t BETWEEN 40 AND 60 THEN 0.35
                                               ELSE 0.03 END) AS step
                   FROM generate_series(1, 120) AS t) s
     ) c),
    5, 'id');
```

**Notes.** `dfa_exponent` may be `-1` (insufficient window), passed through;
the reason step notes it. Raises `no track rows in …` if the track table is
empty. `id_col` must be bigint-castable.

---

### Network coverage alert -- `fractal_agent_network_coverage_alert`
**Smart-cities coverage alert: spatial morphology + telemetry drift.**

Use it for Smart-Cities sensor-grid coverage alerts, or any spatial-morphology +
telemetry-drift workflow. It combines the sensor grid's fractal morphology
(dimension + lacunarity) with the telemetry series' regime-change drift, then
reasons an alert.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `point_cloud` | `float8[]` | -- | the sensor grid as a flat interleaved point array |
| `drift_series` | `float8[]` | -- | the telemetry series |
| `boxcount_dim` | `int` | `2` | the morphology box-counting dimension |
| `drift_win` | `int` | `48` | the drift recent-window size |
| `drift_threshold` | `float8` | `0.5` | `drift_detected = \|drift\| > drift_threshold` |
| `context` | `text` | `'{}'` | optional label passed to the reason call |

**How it works.** (1) `fractal_morphological_complexity(point_cloud, boxcount_dim)`
→ `{dimension, lacunarity}`. (2) `fractal_dimension_drift(drift_series, drift_win)`
→ the drift field, a **signed numeric** (`recent_alpha − baseline_alpha`, not a
boolean). (3) `drift_detected = abs(drift) > drift_threshold`. (4) `fractal_reason`
issues the alert.

**Returns** one JSON document `{morph_dimension, lacunarity, drift_detected, rationale}`.

**Example**
```sql
-- 20×20 sensor grid (400 points) + a 96-point step-up telemetry series.
SELECT fractal_agent_network_coverage_alert(
    (SELECT array_agg(v ORDER BY id, ord) FROM (
         SELECT r*20 + c AS id, ord, v
           FROM generate_series(0, 19) AS r
          CROSS JOIN generate_series(0, 19) AS c
          CROSS JOIN LATERAL unnest(ARRAY[r + (random()-0.5)*0.3,
                                          c + (random()-0.5)*0.3]) WITH ORDINALITY AS u(v, ord)
     ) g),
    (SELECT array_agg(v ORDER BY t) FROM (
         SELECT t, CASE WHEN t < 48 THEN 4.0 + 1.5*sin(t*0.31) + (random()-0.5)*0.8
                        ELSE 4.0 + 3.0*sin(t*1.4)  + (random()-0.5)*0.4 END AS v
           FROM generate_series(1, 96) AS t) s),
    2, 48, 0.5);
```

**Notes.** `point_cloud` needs **~≥256 points** for the morphology estimator to
succeed (a 20×20 grid = 400 points works; 100 or a scattered 60 fail with
`rc=-1`). `point_cloud` is a flat `n_points × dim` interleaved array. Raises
`point_cloud and drift_series are required` if either is NULL. The `drift` field
is a **signed numeric**, not a boolean: `drift_detected` is the boolean
comparison.

---

### Regime triage -- `fractal_agent_regime_triage`
**Triage a regime change in a single series (array-in, no table).**

Use it for any single-series regime-change triage (Quant-Finance market regime,
Cybersecurity traffic regime, Smart-Cities sensor regime) when you already hold
the series as an array and don't have a per-row time/metric table (that's
[anomaly_triage](#anomaly-triage--fractal_agent_anomaly_triage)). It runs the DFA
long-range-correlation exponent and the regime-change drift, then reasons.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `series` | `float8[]` | -- | the time series |
| `win` | `int` | `64` | the drift recent-window size |
| `drift_threshold` | `float8` | `0.5` | `drift_detected = \|drift\| > drift_threshold` |
| `context` | `text` | `'{}'` | optional label passed to the reason call |

**How it works.** (1) `fractal_dimension_dfa(series)` for the long-range
correlation exponent. (2) `fractal_dimension_drift(series, win)` for the
regime-change drift + recent/baseline alphas. (3) `drift_detected = abs(drift) >
drift_threshold`. (4) `fractal_reason` triages the regime change.

**Returns** one JSON document `{dfa_exponent, drift_detected, recent_alpha, baseline_alpha, rationale}`.

**Example**
```sql
-- 96-point step-up series: baseline for the first 48 points, then a regime change.
SELECT fractal_agent_regime_triage(
    (SELECT array_agg(v ORDER BY t) FROM (
         SELECT t, CASE WHEN t < 48 THEN 4.0 + 1.5*sin(t*0.31) + (random()-0.5)*0.8
                        ELSE 4.0 + 3.0*sin(t*1.4)  + (random()-0.5)*0.4 END AS v
           FROM generate_series(1, 96) AS t) s),
    64, 0.5);
```

**Notes.** `dfa_exponent` may be `-1` (insufficient window), passed through.
Raises `series is required` if `series` is NULL. The `drift` field is a **signed
numeric** (`recent_alpha − baseline_alpha`), not a boolean; `drift_detected` is
the boolean comparison.

---

### A note on id resolution

**In this DuckDB build**, `fractal_search_telemetry` and
`fractal_hybrid_clinical_search` return `doc_id` as DuckDB's **`rowid`
pseudocolumn, stringified**. `rowid` is selectable on an ordinary base
table but is not a durable identifier: treat it as valid for the query
it came from, not as something to store. The
trajectory search's `doc_id` remains a **0-indexed scan position**, mapped
back to rows through the table's `rowid` ordering.

You rarely need any of that in SQL: the agents that search through telemetry
or the hybrid search (`route_task`, `recall_hybrid`, `recommend_diverse`,
`patient_deterioration_triage`, `schedule_workload`) resolve the `doc_id`
for you, joining it back to the named id column (`id_col`) themselves, and
the agents that search through the trajectory search (`rebalance_sibling`,
`detour_classify`, `track_anomaly`) apply the 0-indexed scan-position
mapping the same way.
`id_col` must be **bigint-castable** (e.g. `rebalance_sibling`
`nearest_alloc_id` is an id cast to the id column's bigint, so a text label
column won't do; pass the numeric PK).

Composing the primitives by hand? Resolve `doc_id` yourself the same way the
agents do. For telemetry/hybrid results the `doc_id` **is** the rowid
(stringified), so join with a direct predicate:
`WHERE t.rowid = CAST(doc_id AS BIGINT)` (or `WHERE t.id = CAST(doc_id AS
BIGINT)` against the named id column directly). For trajectory-backed
results the `doc_id` is a 0-indexed scan position, recovered with
`row_number() OVER (ORDER BY rowid) - 1` over the scanned table -- the same
mapping the agents apply internally.

`recommend_diverse` enables repulsion on this session's search context as a
side effect (so re-searches avoid recently-rejected items reported via
`fractal_feedback_report`). The state persists for the rest of the connection;
reset it with `SELECT fractal_diversify_disable();` -- a registered SQL toggle
acting on the calling session's own engine context
-- before later sections expect plain
top-k behavior.
`feedback_audit` runs the whole audit cycle (enable → warmup →
isolate → read-back) **and self-disables** diversify on the same session, so
it doubles as the reset point.

---

## Building blocks: the six Universal Agents

**These are built into the DuckDB extension** -- native functions (five
table functions;
`fractal_agent_detect_loop` is a scalar function, noted below). The sixteen
recipes
above compose the search/trajectory/analytics primitives server-side; you can call these six directly
today and compose your own routines on top of them (see
[Composing your own](#composing-your-own)). They require the reasoning
plugin configured (`FRACTALSQL_REASONING_PLUGIN`; see
[`reasoning-setup.md`](reasoning-setup.md)) for the agents that embed a query
or call `fractal_reason`. Argument order and types are the same as in the other FractalSQL editions; the call SYNTAX differs --
these are DuckDB table functions (`SELECT * FROM fractal_x(...)`, not a
scalar call returning a composite type), and column names/types are verified
against this build's actual `RegisterFractalAgentsFamily` registration.

### `fractal_search_agent`
**End-to-End Synthesis Agent**

Embeds a query, performs a diverse Scout search, and synthesizes the results into a reasoned answer.

`vector_col` must be `float8[]` or `fractal_vector`, and its element width must
match the configured embedding model's output dimension (768 for
`nomic-embed-text`, 1536 for `text-embedding-3-small`). Pointing the agent at a
non-vector column (e.g. a `bigint` state hash) raises a clean
`vector_col must be float8[] or fractal_vector` `ERROR` rather than crashing
the database process.

The reasoning step synthesizes its answer over the **retrieved rows'
content**, not the raw vectors. After the Scout search the agent maps each
top-k result position back to its physical row (by `rowid`, captured during
the corpus scan) and fetches the matched rows' non-vector columns as a JSON
array. That compact, LLM-readable context is what `fractal_reason` consumes.
(The raw Scout result, by contrast, contains the top-k *embeddings*,
useless to an LLM and large enough, at `pop_size × dim` floats, to exceed a
local model's context window and fail the chat call.) `source_row_ids` are the rows' real `rowid`s, best first.

```sql
-- DuckDB table function; the five positional arguments are required, meta_filter is a named argument.
SELECT answer, execution_time_ms, source_row_ids, used_index, context_cut
FROM fractal_search_agent(
    query       VARCHAR,
    table_name  VARCHAR,
    vector_col  VARCHAR,
    pop_size    INTEGER,
    iterations  INTEGER,
    meta_filter := '{"parent_id": 7}'   -- optional
);
```
- `answer`: The synthesized text response from the LLM.
- `execution_time_ms`: Total pipeline latency, measured, `INTEGER`.
- `source_row_ids`: `LIST(BIGINT)` -- the retrieved rows' `rowid`s, best first.
- `used_index`: `BOOLEAN` -- `true` when the nearest rows came from a `fractal_index` (`agent_use_index` on, or auto with a ready index), `false` for the Scout search.
- `context_cut`: `VARCHAR` (JSON) `{"cells": N, "rows": M}` -- text cells cut to `agent_context_row_bytes` (default 8192 bytes, cut at a character boundary, 0 means no limit, a cut cell carries a marker saying how much was left out) and matched rows left out by the 64-row cap.
- `meta_filter` is a flat JSON object `{"column": value, ...}`: only rows where every named column equals its value are searched; `null` matches NULL. A filter that is not an object, names a column the table does not have, or matches no row is an error, never ignored. Through an index the matching keys are passed to `fractal_search` as its `ids` option (up to 100000 keys, otherwise the exact scan runs). The table needs an index `id_col` that is an integer key for the index path.

### `fractal_sql_agent`
**Self-Correcting SQL Agent**

Generates SQL from natural language and automatically retries upon `EXPLAIN` or execution failure.

```sql
-- DuckDB table function; no defaults, pass all four args (table_names
-- can be NULL, but must be present positionally).
SELECT generated_sql, execution_status, retry_count, result_json
FROM fractal_sql_agent(
    question      VARCHAR,
    table_names   VARCHAR[],  -- or NULL
    max_retries   INTEGER,
    auto_execute  BOOLEAN
);
```
- `generated_sql`: The final validated SQL statement.
- `execution_status`: Status of the auto-execution (e.g., `"executed"`, `"failed"`).
- `retry_count`: Number of correction loops performed.
- `result_json`: JSON representation of the query results (if `auto_execute` was true).

### `fractal_text_to_sql`
**Validated Text-to-SQL** (scalar function, not a table function
like the other five -- see [text-to-sql-setup.md](text-to-sql-setup.md) for
the full pipeline)

Same GENERATE → ALLOWLIST → EXPLAIN → RETRY pipeline as `fractal_sql_agent`
above (they share one validation pipeline), returning just the validated SQL
text and never executing it.

```sql
SELECT fractal_text_to_sql(
    question      VARCHAR,
    table_names   VARCHAR[]  -- optional; omit for none
);
```
- Returns `VARCHAR`: the validated SQL. Raises an error if 3 attempts
  (fixed) are exhausted without a validated candidate -- unlike
  `fractal_sql_agent`, which reports a failure via `execution_status`
  instead of raising.

### `fractal_agent_plan_explore`
**Strategy Trajectory Exploration**

Uses MCTS-style diversification to explore multiple non-overlapping strategy trajectories in a state space. Returns one row per explored branch.

```sql
-- DuckDB table function.
SELECT branch_id, plan_trajectory, confidence_score
FROM fractal_agent_plan_explore(
    initial_state    VARCHAR,
    strategy_table   VARCHAR,
    vector_col       VARCHAR,
    max_branches     INTEGER
);
```

`max_branches` is required (no default). `initial_state` is `text`: the
exploration seeds from the vector nearest to this state label, not from a
raw vector. The function is `STRICT`: a `NULL` argument returns no rows
rather than executing.

Each returned branch carries its own `plan_trajectory`: the **matched
strategy's** embedding (the corpus row at that branch's result index), so the
branches are distinct rather than all echoing the query vector.
`confidence_score` is `1.0 − distance`. The rows are produced by the
function's own execution and drained by the executor; calling it in a context
that cannot accept a set raises a clean `ERROR`.
- `branch_id`: Unique identifier for the explored trajectory.
- `plan_trajectory`: The converged state vector for this branch.
- `confidence_score`: The fitness/relevance score of the trajectory.

### `fractal_agent_trajectory_predict`
**State Drift Forecasting**

Projects future state by searching for similar delta-vectors ($\Delta = V_{now} - V_{baseline}$) in historical telemetry.

```sql
-- DuckDB table function.
SELECT predicted_state_vector, projected_drift_delta, risk_threshold_exceeded
FROM fractal_agent_trajectory_predict(
    table_name      VARCHAR,
    vector_col      VARCHAR,
    baseline_id     BIGINT,
    forecast_steps  INTEGER
);
```

All four arguments are required. The function resolves `table_name`'s
primary-key column via DuckDB's `pragma_table_info()`, reads the **baseline**
vector from the row whose PK equals `baseline_id`, and the **current** vector
from the latest row (max PK). It derives `dim` from the data (not a hardcoded
width) and searches the corpus for the nearest state to
$\Delta = V_{current} - V_{baseline}$. `table_name` must therefore have a
single-column primary key (a composite key raises a clean error rather than
guessing) and a non-NULL `DOUBLE[]` `vector_col` on both the baseline and
latest rows. `forecast_steps` is reserved for a future extrapolation step.
- `predicted_state_vector`: The corpus row nearest to the drift delta (real, data-derived dim).
- `projected_drift_delta`: The distance to that nearest row.
- `risk_threshold_exceeded`: True if the drift exceeds 0.5.

### `fractal_agent_detect_loop`
**Loop-Detection Safety Monitor**

Detects infinite agent loops or repetitive behavior by fingerprinting a
trajectory of real state vectors and watching for a cycle to close.

```sql
-- DuckDB scalar function returning STRUCT(agent_id VARCHAR,
-- dfa_exponent DOUBLE, is_loop_detected BOOLEAN). No SQL-level defaults
-- (DuckDB scalar functions can't declare them) -- registered as 4
-- arity overloads (3..6 args) instead; call with 3, 4, 5, or 6 args to
-- get n_bits=64/seed=42.0/hamming_threshold=0 defaults implicitly, or
-- pass them explicitly.
SELECT r.agent_id, r.dfa_exponent, r.is_loop_detected
FROM (SELECT fractal_agent_detect_loop(
    agent_id          VARCHAR,
    state_log         DOUBLE[],
    dim               INTEGER
    -- , n_bits INTEGER, seed DOUBLE, hamming_threshold INTEGER  -- optional, in this order
) AS r);
```

`state_log` is a `float8[]` holding the agent's states flattened row-major
(`n_states = length(state_log) / dim` doubles, the same convention
`fractal_search_telemetry` uses for corpus flattening). Each state is
fingerprinted via SimHash (`n_bits`, `seed`) and the fingerprints stream
through Brent's cycle detector, so a loop is flagged when it closes:

- with `hamming_threshold = 0`, only byte-identical repeated states count;
  raise it (say 1 to 4) to catch near-identical repeats that are not
  byte-identical, which an exact-hash period scan would miss.
- independently, `dfa_exponent` (the DFA scaling exponent of each state's L2
  norm across the trajectory) exceeding 0.9 flags a random-walk-like wander
  the fingerprint-cycle check can miss if it never closes within the
  threshold.

> The SimHash fingerprint is **direction-based**: it hashes projection signs,
> so two states differing only in magnitude collide. Encode each state so the
> meaning lives in its direction -- real vectors work best; cast scalar states
> into a distinguishable direction (a one-hot encoding, for example) rather
> than folding them into a 1-dimensional vector.

- `agent_id`: echoed back in the result (so one monitor can serve several agents).
- `dfa_exponent`: the calculated $\alpha$ scaling exponent.
- `is_loop_detected`: true if either the fingerprint-cycle check or the DFA
  threshold fires.

### `fractal_rag_agent`
**Hybrid Retrieve-Reason Agent**

Embeds a query, Scout-searches a corpus, then reasons over the retrieved context to produce a single answer: a focused, single-turn RAG pattern.

Like `fractal_search_agent`, the reasoning step consumes the **retrieved rows'
content** (their non-vector columns, fetched by `rowid`) rather than the raw
top-k vectors. See that function's note for why. The chat-dispatch return
code is checked: a reasoning-endpoint failure raises a clean
`rag_agent reasoning failed (rc=…)` `ERROR` with the plugin's detail, instead
of returning a NULL/garbage answer.

```sql
-- DuckDB table function; no defaults, pass all four args.
SELECT answer
FROM fractal_rag_agent(
    query        VARCHAR,
    table_name   VARCHAR,
    vector_col   VARCHAR,
    meta_filter  VARCHAR  -- pass '{}' for "no filter"
);
```

`meta_filter` is a flat JSON object `{"column": value, ...}` (`'{}'` or an empty string for none) and works as it does for `fractal_search_agent`.
- `answer`: The synthesized text response from the LLM. Output columns: `answer`, `source_row_ids` (`LIST(BIGINT)`), `used_index` (`BOOLEAN`), `context_cut` (JSON text). The old note follows: unlike `fractal_search_agent`, it has no `source_doc_ids`/`execution_time_ms`.)

---

## Reference blueprints: Domain Agents

These Domain Agent blueprints are hand-written functions defined inline in
the vertical demo files under `demo/` -- not part of the extension. In this
build, the recipes
that generalized them are registered with the extension itself (see the
sixteen recipes above), and each demo keeps its raw-primitive blueprint as a
commented reference sitting right above the shipped agent call.

The three agentic-vertical demos (`demo/demo-vertical-agentic-ops-devops.sql`
for DevOps/SRE, `-fintech-mcts.sql` for FinTech, `-customer-support.sql` for
Customer Support) carry six hand-written **Domain Agent**
blueprints: SOC incident triage and task routing, portfolio rebalancing, and
hybrid memory recall with diverse recommendations. Their hand-rolled
compositions show the agent logic inline, so you can see the plumbing the
registered recipes fold away; a couple of the blueprints stub their inner
reasoning/retrieval step with canned data, which is the one part worth
swapping for a real call against your own corpus before reusing the pattern.
To try them: load the extension and configure reasoning (see
[reasoning-setup.md](reasoning-setup.md)), then run a demo end to end
(`{ echo "LOAD '/path/to/fractalsql.duckdb_extension';"; cat
demo/demo-vertical-agentic-customer-support.sql; } | duckdb -bail -unsigned`).

The tables below describe the demo files' original hand-written blueprints,
kept as reference for what the underlying demo SQL illustrates; the shipped
recipes above are their productized form in this build.

### DevOps / SRE -- `demo/demo-vertical-agentic-ops-devops.sql`

| Domain Agent blueprint | Composes | Purpose |
| --- | --- | --- |
| `fractal_agent_route_task(task, cap_map, budget)` → `(routed_to, confidence, remaining_budget)` | `fractal_search_agent` (embed → Scout → reason) | Sub-agent dispatcher: matches an incoming task to the best capable sub-agent and returns a confidence plus a token-budget accounting. Shipped: `fractal_agent_route_task`. |
| `fractal_agent_outlier_intercept(state_vec, history_table, emb_col, threshold, metric)` → `(intercepted, reason)` | `fractal_search_telemetry` | Pre-commit safety barrier: screens a proposed action's state vector against known-bad state clusters and intercepts it when the nearest bad state is within `threshold`, measured by `metric` (`'cosine'` by default, or `'l2'`). Shipped: `fractal_agent_outlier_intercept`. |
| `fractal_agent_threat_triage(host_id, log_table, baseline_window)` → `(threat_score, anomaly_type, triage_summary)` | `fractal_dimension_drift` + `fractal_reason` | SOC incident triage: scores drift on the host's latency series, then reasons a human-readable triage summary over the drift result. Shipped: `fractal_agent_anomaly_triage`. |

### FinTech -- `demo/demo-vertical-agentic-fintech-mcts.sql`

| Domain Agent blueprint | Composes | Purpose |
| --- | --- | --- |
| `fractal_agent_portfolio_rebalance(portfolio_id, target_cardinality)` → `(new_weights, drift_score, rationale)` | `fractal_optimize_portfolio` + `fractal_reason` | Cardinality-constrained rebalance: runs the SFS Sharpe optimizer for the target asset count, then reasons a rationale for the weight shift. Shipped: `fractal_agent_rebalance_sibling`. |

### Customer Support -- `demo/demo-vertical-agentic-customer-support.sql`

| Domain Agent blueprint | Composes | Purpose |
| --- | --- | --- |
| `fractal_agent_recall_hybrid(query, mem_table, alpha)` → `(mem_id, content)` | `fractal_search_trajectory` + SQL filter | Hybrid memory recall: fuses a strict metadata filter with a drift-vector (current-vs-baseline) state search. Shipped: `fractal_agent_recall_hybrid`. |
| `fractal_agent_recommend_diverse(customer_id, catalog_table, k)` → `(item_id, score)` | `fractal_diversify_enable` + Scout (`fractal_search_explore`) | Feedback-aware recommender: enables the stateful Diversify/Repulsion layer so re-searches avoid recently-rejected items, then Scout-searches for diverse candidates. Shipped: `fractal_agent_recommend_diverse`. |

### Getting started

1. **Prerequisites**: the extension loaded
   (`LOAD '/path/to/fractalsql.duckdb_extension';`)
   and reasoning configured. The universal agents call `fractal_reason` /
   `fractal_embed` (the demo-local blueprints stub their reasoning steps),
   so follow [`reasoning-setup.md`](reasoning-setup.md) first. The two
   embed-coupled demos (DevOps, FinTech) also need an embeddings endpoint and
   a vectorized column. See [`vectorizer-setup.md`](vectorizer-setup.md).
2. **Run a demo** end to end via the DuckDB CLI:
   ```sh
   { echo "LOAD '/path/to/fractalsql.duckdb_extension';"; cat demo/demo-vertical-agentic-customer-support.sql; } \
       | duckdb -bail -unsigned
   ```
3. **Read the composition**: the shipped recipes are native scalar functions;
   the demo files keep the
   hand-rolled blueprint alongside each call. See
   [composition-guide.md](composition-guide.md)'s composing note for what
   composing the same logic looks like in this build.

---

## Composing your own

The six Universal Agents above are the building blocks; the sixteen registered
recipes show them composed into vertical workflows as native scalar functions. **DuckDB has no procedural
SQL** -- a custom agent is either a routine in your host language or a native
extension function (scalar for a
single-row result, table function for a rowset) calling the underlying
primitives in sequence, following the two patterns the shipped agents use:
the search and RAG agents (embed → scan corpus → search →
fetch context → reason → shape result) and the recipe agents (parse args →
run primitives → resolve ids → reason → emit one JSON document). There's no
procedural-SQL composition shortcut here; a new native agent is a genuine, if
mechanical, addition to the extension.

For the full guide, see **[composition-guide.md](composition-guide.md)**: the
building-block pick-list, the four-stage pipeline (retrieve → reason → act →
guard), three worked patterns (single-turn RAG, self-correcting analyst,
multi-step agent with a safety barrier), the Safe Agency & Guardrails rules
for `fractal_sql_agent`, and a copy-paste skeleton.

---

## Validate

`demo/demo-agents.sql` exercises all sixteen registered recipe agents end to
end, alongside the six Universal Agents. Run it with the DuckDB CLI:

```sh
{ echo "LOAD '/path/to/fractalsql.duckdb_extension';"; cat demo/demo-agents.sql; } \
    | duckdb -unsigned
```

(no `-bail`: the file's enterprise-tier call prints its activation error
on a community build, and the shell should carry on past it)

This repo's `build_test.sh`/`build_test.ps1` harness smoke-tests
the same compositions against the built extension through the DuckDB CLI
and the Python `duckdb` driver, with a mock reasoning canary.
See [the agents demo](../demo/README.md) and
[`getting-started.md`](getting-started.md) to get set up first.
---

## When the reasoning step fails

An agent that composes a data step with a final reasoning call (`fractal_search_agent`, `fractal_rag_agent` and the `fractal_agent_*` domain agents) raises a clear error when the reasoning endpoint fails, by default. A reasoning plugin that was never configured always raises.

Set `fractal_config_set('agent_partial_reasoning_fail', 'on')` to change that. If the reasoning call fails after the data step has already computed, the agent returns its computed half and marks the failure instead of raising:

- the domain agents return their JSON document with `"rationale": null` and a `"reasoning_step_failed"` field carrying the plugin's error text;
- `fractal_search_agent` and `fractal_rag_agent` return their row (the retrieved row ids, `used_index` and the rest) with `answer` set to `reasoning_step_failed: <error>`.

The setting is `off` by default, and `fractal_reason` and `fractal_text_to_sql` are not covered by it (there the reasoning call is the whole result, so its failure is the error). It is the same setting the SQLite and PostgreSQL hosts have.
