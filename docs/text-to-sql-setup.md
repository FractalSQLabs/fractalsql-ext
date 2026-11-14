<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# Production-Safe Text-to-SQL

`fractal_text_to_sql` and `fractal_sql_agent` transform natural-language
questions into mechanically validated SQL, via a GENERATE → ALLOWLIST →
EXPLAIN → RETURN pipeline (retrying GENERATE with the specific rejection
reason fed back). Both share one validation pipeline, so they can't drift apart.

## The pipeline, and its DuckDB-native mechanics

1. **GENERATE**: the question (plus a `pragma_table_info()`-built schema
   summary of `table_names`, and the previous attempt's rejection reason on
   a retry) is dispatched to the configured reasoning plugin.
2. **ALLOWLIST**: `duckdb::Parser::ParseQuery(sql)` -- real parser-based,
   not a string check. Rejects anything that isn't exactly one statement,
   and (by default) anything that isn't a `SELECT`. Set
   `FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update` to also
   allow `INSERT`/`UPDATE` (the select_insert_update widening); `DELETE`
   and every DDL/utility statement are rejected in both modes -- there's
   no "allow everything" tier.

   One risk an allow-`SELECT` check normally has to gate on separately is
   the *data-modifying CTE*
   (`WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d`),
   which is one statement and would smuggle a mutation past the check.
   Here that's a non-issue by construction:
   `CommonTableExpressionInfo::query` is typed
   `unique_ptr<SelectStatement>`, so a CTE body can only ever be a SELECT
   -- a modifying CTE is simply a parse error, caught by the same
   ALLOWLIST step. (One side effect of the stricter grammar: a
   legitimate `WITH x AS (SELECT ...) SELECT * FROM x` is allowed here.)
3. **EXPLAIN**: `EXPLAIN <sql>` -- parses, binds, and
   plans without executing; a binder or catalog error (bad
   column, missing table, type mismatch) is caught and fed back as the
   next attempt's rejection reason.
4. **RETURN or RETRY**: on success, the validated SQL is returned (never
   executed by `fractal_text_to_sql` itself). On failure, retry from
   GENERATE with the reason, up to the attempt limit.

## `fractal_text_to_sql(question[, table_names]) -> VARCHAR`

Returns the validated SQL text as a plain
string, **never executes it**. Raises an error if 3 attempts (hardcoded)
are exhausted without a validated candidate. Registered as two arities (1
or 2 args; DuckDB scalar functions can't declare `DEFAULT` clauses), like
`fractal_schema_context` below.

```sql
SELECT fractal_text_to_sql(
    'How many orders does customer ''acme'' have?',
    ['orders', 'customers']);
```

## `fractal_sql_agent(question, table_names, max_retries, auto_execute) -> TABLE(generated_sql, execution_status, retry_count, result_json)`

Same pipeline, as a table function with two differences: a caller-chosen
`max_retries` (1-20) instead of the fixed 3, and an optional execute step
(running the validated SQL) when `auto_execute` is true.
Never raises on a validation failure -- reports it in
`execution_status`/`result_json` instead, so a caller can inspect what
happened rather than catching an exception. See
[api-agency.md](api-agency.md#fractal_sql_agent) for the full column
shapes.

```sql
SELECT * FROM fractal_sql_agent(
    'How many orders does customer ''acme'' have?',
    ['orders', 'customers'], 2, false);
```

## `fractal_schema_context(table_names[, query_hint]) -> VARCHAR`

Pure catalog introspection (no LLM call), reading DuckDB's own
`information_schema.columns` and `duckdb_constraints()`. Builds the
plain-text schema description an LLM prompt would use as context -- call it
directly to audit exactly what a model would see:

```sql
SELECT fractal_schema_context(['orders', 'customers']);
-- TABLE customers:
--   id INTEGER PRIMARY KEY
--   name VARCHAR NOT NULL
-- TABLE orders:
--   id INTEGER PRIMARY KEY
--   customer_id INTEGER NOT NULL
--   total_cents INTEGER NOT NULL
--
-- FOREIGN KEYS:
--   orders(customer_id) -> customers(id)
```

Registered as three arities: `fractal_schema_context()` (every table),
`fractal_schema_context(table_names)`, and
`fractal_schema_context(table_names, query_hint)` (`query_hint` accepted
for forward compatibility, not yet used in this build). Capped at
512 requested table names -- pass a smaller, scoped
list if you hit the limit. Table/column `COMMENT` text isn't included. Like `fractal_text_to_sql`, the shorter arities
stand in for optional defaults: the zero-arg form implies table_names =
all tables.

---

## Validation & Testing

- **Harness gates**: `build_test.sh` (Linux/macOS) and `build_test.ps1`
  (Windows) exercise the text-to-sql surface end to end against the shipped
  extension -- the allowlist/candidate matrix and its never-executes proof,
  the `select_insert_update` widening mode, the retry-with-fed-back-reason
  cycle, and the evil-plugin robustness family (crash, length-lying,
  non-terminating plugin fixtures). Same gates on both platforms; run
  `pwsh -File .\build_test.ps1` / `./build_test.sh`.
  On Windows the same matrix can run against a natively instrumented
  build (`pwsh -File .\build_test.ps1 -Asan` / `-Ubsan`), where the
  extension and the CLI that hosts it are both built with the sanitizer
  and any sanitizer report in the captured CLI output fails its gate.
- **Fixture plugins**: `tests/` provides deterministic mock reasoning
  plugins (`mock_reasoning_plugin.c`, `retry_reasoning_plugin.c`,
  `think_reasoning_plugin.c`, `mock_embed_plugin.c`), adversarial ones
  (`evil_crash_plugin.c`, `evil_lying_length_plugin.c`,
  `evil_nonterminating_plugin.c`), and a local mock LLM HTTP server
  (`tests/_mock_llm_server.py`) the harness drives for the HTTP-plugin
  paths.
- **Planned**: the python-driven fuzz/shadow suites
  (`test_text_to_sql_fuzz.py`, `test_text_to_sql_shadow.py`,
  `test_text_to_sql_evil_nonterminating.py`) aren't in this repo yet --
  the harness gates above cover
  their core cases (stacked statements, DDL, injection shapes) in-process
  meanwhile.
- **Seeded fuzzer**: both harnesses carry a deterministic mutation
  fuzzer over `tests/fuzz_corpus/`. Every mutant is fed to the CLI as
  ordinary SQL (it must not die) and handed to `fractal_text_to_sql()` as
  a model reply (the SELECT-only allowlist must still refuse anything
  that is not a single SELECT). Run it with `pwsh -File
  .\build_test.ps1 -Fuzz` / `./build_test.sh --fuzz`; the two harnesses
  generate the same mutants from the same seed.

---

## Known Limitations

- **Distinct-Value Sampling**: The current version does not sample
  enum-like columns (e.g., `'Completed'` vs `'completed'`) to help the LLM
  with value normalization.
- **Table Ranking**: For extremely large schemas, `fractal_search`-based
  table subset ranking is planned to replace the current linear
  auto-discovery.
- **Schema Caps**: `fractal_schema_context`'s explicit `table_names`
  argument and its auto-discovery are both capped at 512 table names
  to bound prompt overhead.
  `fractal_text_to_sql`'s `table_names` list has no equivalent cap in this
  build -- pass a scoped list yourself when prompt size matters.

## Configuration

- `FRACTALSQL_REASONING_PLUGIN` -- required by all three functions above
  (GENERATE needs a live model). See [reasoning-setup.md](reasoning-setup.md).
- `FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS` -- unset/`select` (default) or
  `select_insert_update`. Read once per call, so it can be changed between
  statements in the same session without a restart.
- `FRACTALSQL_TEXT_TO_SQL_USE_REVIEW` -- off by default. Set it to `on`,
  `1`, `true` or `yes` to add the REVIEW round: after the generated SQL
  parses and binds, a second LLM call critiques it, and a critique that
  does not begin with `PASS` sends the round back with the critique as
  the next attempt's feedback. The critique runs on the review tier, so
  it is a separate model call and it costs one round trip per attempt.
  Read once per call, so it can be changed between statements in the same
  session without a restart.

Not configurable here: `fractal_text_to_sql`'s attempt limit is fixed at
3, and `fractal_sql_agent`'s is caller-supplied (1-20) per call instead of
session-wide.

## Security note

This pipeline is a *correctness* aid, not an *authorization* mechanism.
The allowlist/EXPLAIN checks catch shape and schema problems; they don't
replace access control. DuckDB's embedded, typically-single-user model has
no per-role GRANT/RLS layer -- if you're embedding
this in a multi-tenant application, enforce row/table visibility at your
application layer before the generated SQL reaches this pipeline, not
after.
