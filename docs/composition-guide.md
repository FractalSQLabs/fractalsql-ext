<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# Composition Guide: Build Your Own Agent

You have run the [industry starter kits](starter-kits.md) and read the
[six Universal Agents](api-agency.md#building-blocks-the-six-universal-agents).
Now the question is: **how do I build a proprietary agent that isn't in the box?**

> **Composition note -- DuckDB has no procedural-SQL extension surface.**
> There is no `CREATE FUNCTION` in DuckDB, so you cannot add a custom agent
> as a stored SQL routine. The patterns below are therefore expressed two
> ways: as runnable plain SQL where a single statement suffices, and as a
> wiring recipe for a routine in your host language (or for a native
> table/scalar function added to the extension, the
> pattern the shipped agents follow: embed → scan corpus → search →
> fetch context → reason → shape result). Composing a new
> *native* agent means adding a function to the extension source, compiling, and
> reloading the extension. What you copy into either shape is the
> composition *logic*: retrieve, reason, act, guard.
>
> What you genuinely CAN compose in plain SQL, no native code needed: calling the
> six Universal Agents directly and combining their results with ordinary
> `SELECT`/`JOIN`/CTEs -- see Pattern A below for exactly that, no
> composition required.

## The six building blocks

These are the **Universal Agents**, implemented as native DuckDB table
functions (they need the
reasoning plugin configured -- `FRACTALSQL_REASONING_PLUGIN`; see
[reasoning-setup.md](reasoning-setup.md)). Full signatures and behaviour are
in [api-agency.md → Building blocks](api-agency.md#building-blocks-the-six-universal-agents);
here is the pick-list.

| Block | Role | Use it when… |
|---|---|---|
| `fractal_search_agent` | Embed → Scout-search → synthesize an answer over retrieved rows | You want a single reasoned answer grounded in a vector corpus |
| `fractal_rag_agent` | Single-turn RAG (embed → Scout → reason) | Same as above, focused one-shot; the lighter RAG pattern |
| `fractal_sql_agent` | NL → SQL with self-correction on `EXPLAIN`/exec failure | You need structured answers from tables, not vector prose |
| `fractal_agent_plan_explore` | MCTS-style diverse strategy trajectories | You need *multiple* non-overlapping plans, not one answer |
| `fractal_agent_trajectory_predict` | Forecast state by matching a drift delta-vector in history | You need "where is this heading, based on past drift?" |
| `fractal_agent_detect_loop` | SimHash + Brent cycle detector over a state-vector log | You need a safety monitor on an autonomous agent's state log |

Underneath these, the **Discovery primitives** (`fractal_search`,
`fractal_search_explore`, `fractal_search_trajectory`, `fractal_search_telemetry`,
`fractal_optimize_portfolio`, the `fractal_dimension_*` family) are also
ordinary functions you can chain directly when a Universal Agent is more than
you need.

---

## The composition principle

A composition is a pipeline with up to four stages:

1. **Retrieve**: find the relevant rows (Scout for diversity, or a trajectory
   search for "what changed"). Either call a Discovery primitive directly or
   let `fractal_search_agent` / `fractal_rag_agent` do embed→search for you.
2. **Reason**: `fractal_reason(query, context)` over the retrieved rows'
   *content* (not their raw vectors; the Universal Agents fetch the matched
   rows' non-vector columns by `rowid` and pass that compact JSON to the LLM).
3. **Act** (optional): `fractal_sql_agent(question, table_names,
   max_retries, auto_execute)` with `auto_execute` set (`true`) when the
   agent must run a query, under the guardrails
   ([Safe Agency](#safe-agency--guardrails) below).
4. **Guard** (optional): `fractal_agent_detect_loop` on the agent's state-hash
   log, and/or `fractal_agent_outlier_intercept`-style screening of a proposed
   action against known-bad states.

Stages 1–2 are the common case (most "answer my data" agents). Add 3 when the
agent must *do* something. Add 4 any time the agent is autonomous.

---

## Worked patterns

### Pattern A -- "Answer my corpus" (single-turn RAG)

The simplest useful agent, and you usually don't even need to compose it:
call the block directly:

```sql
SELECT answer FROM fractal_rag_agent(
    'What does our runbook say about a node that stops heartbeating?',
    'runbook_chunks', 'emb'
);
```

You can pre-filter the corpus and shape the reasoning context with plain SQL
-- no new function needed, this composes today:

```sql
WITH ctx AS (
    SELECT to_json(list({'title': title, 'body': body})) AS payload
    FROM (
        SELECT title, body FROM runbook_chunks
        WHERE team = 'sre' AND updated_at > now() - INTERVAL '90 days'
        ORDER BY updated_at DESC LIMIT 25
    ) t
)
SELECT fractal_reason(
    'What does our runbook say about a node that stops heartbeating?',
    (SELECT payload FROM ctx))
AS answer;
```

For a genuinely new *retrieval pattern* (not just a differently-filtered
call to an existing block), see the note at the top of this page -- that
needs a native table function, not a SQL wrapper.

### Pattern B -- Self-correcting read-only analyst

`fractal_sql_agent` generates SQL, validates it (real parser-based
statement-type allowlist -- SELECT-only by default, or also INSERT/UPDATE
under `FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update` --
then an `EXPLAIN`-equivalent bind/plan check; see
[text-to-sql-setup.md](text-to-sql-setup.md)), retrying on rejection with
the specific reason fed back, and (with the fourth argument `true`) runs the
validated statement. Compose it when the user's question is about
*tables*, not vector prose:

```sql
SELECT generated_sql, execution_status, retry_count, result_json
FROM fractal_sql_agent(
    'total spend per category last quarter',
    ['invoices'], 2, true);
```

DuckDB has no role/GRANT system to run this "as a least-privilege role"
under (see [Safe Agency](#safe-agency--guardrails) below) -- the access
control this needs lives at your application layer instead.

The shipped `fractal_agent_data_analyst` (one of the sixteen registered
recipes) is the productized version of this: NL→SQL inside its own
composition, plus a reasoned summary of the result. Call it directly, or
see how that composition
is wired as a native scalar function (it calls `fractal_sql_agent`'s underlying
primitives, then feeds `result_json` into `fractal_reason` for the summary).

### Pattern C -- Multi-step agent with a safety barrier

This is the pattern the [DevOps starter kit](starter-kits.md#agentic-kits-model-on-composed-agents)
productizes: retrieve → act → guard. There's no server-side stored routine
to put it in (see the note at the top of this page), so this whole skeleton
lives in your host language -- or a demo-style script -- calling the same
four primitives in the same order. The wiring is the part to copy.

The four steps, over the real surface names, as runnable plain SQL (the
branching that picks between them is a few lines of host-language code):

```sql
-- 1. RETRIEVE: collect the incident corpus's non-vector columns and shape
--    them into a compact JSON context payload
SELECT to_json(list({'title': title, 'body': body})) AS payload
    FROM (SELECT title, body FROM incident_notes
           WHERE incident_id = 42
           ORDER BY updated_at DESC LIMIT 20) t;
-- decide in the host language: if this list has fewer than 3 entries,
-- run step 2 as a fallback; otherwise skip to step 3.

-- 2. ACT (fallback): NL->SQL over the metrics tables
--    (positional args: question, table_names, max_retries, auto_execute)
SELECT generated_sql, execution_status, retry_count, result_json
    FROM fractal_sql_agent('summarize last quarter metrics',
                           ['metrics'], 2, true);

-- 3. REASON over the retrieved context (pass step 1's payload)
SELECT fractal_reason('headline for incident 42',
    (SELECT to_json(list({'title': title, 'body': body}))
       FROM (SELECT title, body FROM incident_notes
              WHERE incident_id = 42
              ORDER BY updated_at DESC LIMIT 20) t)) AS answer;

-- 4. GUARD: check this agent's state log for a loop.
--    state_log is a FLOAT[] of state vectors flattened row-major:
--    n_states * dim doubles, `dim` doubles per state.
SELECT * FROM fractal_agent_detect_loop('tier1-resolver',
    [1.0, 0.0,  0.98, 0.02,  1.01, -0.01,  0.97, 0.03], 2);
-- -> {'agent_id': 'tier1-resolver', 'dfa_exponent': ..., 'is_loop_detected': ...}
```

> The skeleton is illustrative. The state-vector scheme is yours
> to define (real vectors work best; the SimHash fingerprint inside
> `fractal_agent_detect_loop` is direction-based, so encode scalar states
> into a distinguishable direction, for example one-hot, rather than
> casting them to 1-dimensional vectors). The wiring (retrieve, fall back to
> `fractal_sql_agent`, reason,
> then `fractal_agent_detect_loop` on the state log) is the part to copy. The
> shipped `route_task` + `outlier_intercept` +
> `detect_loop` composition in
> `demo/demo-vertical-agentic-ops-devops.sql` is the full, runnable form.

---

## Safe Agency & Guardrails

`fractal_sql_agent` (and any composition that calls it with the
`auto_execute` argument set) generates and executes arbitrary SQL. Treat it the way
you'd treat any NL→SQL surface:

- **Restrict what the underlying process can reach.** DuckDB has no role/
  GRANT system to bound this at the database layer -- restrict it at your
  application layer (a separate process/container with only the tables the
  agent needs attached, a read-only mounted database file, etc.).
- **The deterministic allowlist also backstops `fractal_sql_agent`.** Its
  generated SQL runs through the same pipeline as `fractal_text_to_sql`
  (the same GENERATE → ALLOWLIST → EXPLAIN → RETRY loop):
  parse-check via the real parser, a single-statement check, and a
  statement-type allowlist (select-only unless
  `FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS` is widened to
  `select_insert_update`). DDL, DELETE and
  utility statements are rejected before execution. Keep in mind it is an
  allowlist, not a sandbox: a `SELECT` can still read everything the
  connection can see.
- **Prefer `auto_execute` unset (`false`) for exploratory use.** Let the
  caller review `generated_sql` and run it themselves.

For autonomous agents (Pattern C), add the **safety barriers** the DevOps
blueprint uses: `fractal_agent_detect_loop` on the state-vector log to catch
infinite loops, and an `outlier_intercept`-style screen that checks a proposed
action's state vector against known-bad state clusters before the action runs.

---

## Notes

Two issues surfaced while building the shipped agents, and apply equally to any composition you write.

- **`doc_id` is a scan-attached locator, not a durable key.**
  `fractal_search_telemetry`/`fractal_hybrid_clinical_search` return
  `doc_id` as DuckDB's `rowid` pseudocolumn, stringified. That resolves back
  to the row with `WHERE rowid = CAST(doc_id AS BIGINT)` within the same
  query/transaction, but don't store it: `rowid` is not a durable identifier
  (DuckDB guarantees no stable physical locator across relation rewrites),
  so rebuild it from a query when you need it.
  `fractal_search_trajectory`/`fractal_cross_modal_search` return `doc_id`
  as a plain 0-indexed scan position (`BIGINT`) instead.
  See [api-agency.md → A note on id resolution](api-agency.md#a-note-on-id-resolution).
- **Diversify is session-global.** `recommend_diverse` calls
  `fractal_diversify_enable()` as a session side effect so re-searches avoid
  recently-rejected items. Reset it with `fractal_diversify_disable()` when
  your session is done, or call `feedback_audit`, which runs the
  whole audit cycle and self-disables.

---

## Where next

- **Full signatures and per-agent behaviour** →
  [api-agency.md](api-agency.md) (the six Universal Agents block and the
  sixteen recipes).
- **Runnable compositions to copy** → the three agentic starter kits
  ([starter-kits.md](starter-kits.md#agentic-kits-model-on-composed-agents))
  for the *logic*, and `demo/` for what actually runs in this repo: the
  runnable equivalents of the patterns above are
  `demo/demo-agents.sql` (the sixteen registered recipe agents; the
  cognition ones need a reasoning endpoint) and
  `demo/demo-vertical-agentic-ops-devops.sql`'s shipped
  route_task + outlier_intercept + detect_loop composition. Run them per
  [docker-demo.md](docker-demo.md#-the-learning-path):

  ```bash
  { echo "LOAD '/path/to/fractalsql.duckdb_extension';"; cat demo/demo-agents.sql; } \
      | duckdb -unsigned
  { echo "LOAD '/path/to/fractalsql.duckdb_extension';"; cat demo/demo-vertical-agentic-ops-devops.sql; } \
      | duckdb -unsigned
  ```

  Neither command passes `-bail`, so the shell carries on past an
  expected error and the rest of each file still runs. The two files
  print different ones: `demo-agents.sql` calls an enterprise-tier
  function, which reports that the tier is not loaded on a community
  build, and `demo-vertical-agentic-ops-devops.sql` dispatches to the
  reasoning endpoint, which reports that no endpoint is configured until
  you set one up.
- **Configure the reasoning endpoint** the Universal Agents call →
  [reasoning-setup.md](reasoning-setup.md).
- **Validate your composition** against the same demo path the shipped agents
  use → the `demo-agents.sql` command above.