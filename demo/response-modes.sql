-- demo/response-modes.sql
--
-- FractalSQL reasoning response modes: text | code | json.
--
-- Unlike demo.sql, this is NOT meant to be run start-to-finish in one
-- `duckdb` invocation. FSQL_REASONING_HTTP_RESPONSE_MODE is an env-var-
-- only setting read once when the reasoning plugin initializes --
-- switching modes needs an OS-level environment variable change plus a
-- brand new process (there's no running service or cluster here --
-- DuckDB is embedded, so "restart" just means
-- start a fresh `duckdb` invocation with the new env var set). See
-- "Switching modes" in ../docs/reasoning-setup.md for the exact
-- commands on your platform (Windows/Linux/macOS all differ here).
--
-- Prerequisites:
--   1. Run demo.sql first -- this reuses its demo_alerts table.
--   2. Reasoning already configured per ../docs/reasoning-setup.md.
--
-- Workflow for each section below:
--   1. Set FSQL_REASONING_HTTP_RESPONSE_MODE to that section's mode.
--   2. Start a fresh `duckdb` process (the reasoning plugin reads the env var once, at first dispatch).
--   3. Run ONLY that section's query -- not the whole file at once.

-- (Timing is omitted -- DuckDB's CLI has no per-statement
-- timing dot-command; measure latency at the harness level, e.g.
-- demo/demo-workload.sh.)

-- ============================================================
-- MODE: text (the default -- nothing to configure or restart for)
-- ============================================================
-- Raw model output, unchanged. This is what demo.sql and every other
-- example in the docs already use.

-- No JSON extension loaded -- list(t) (a table alias referenced bare
-- yields the row as a STRUCT) with a ::text cast renders DuckDB's own
-- struct/list format, fine here since
-- this is free-form prompt context, not something parsed back out.
SELECT fractal_reason(
    'summarize what happened in demo_alerts in one sentence',
    (SELECT list(t)::text
       FROM (SELECT service, message, severity, created_at FROM demo_alerts) t)
);

-- ============================================================
-- MODE: code   (FSQL_REASONING_HTTP_RESPONSE_MODE=code, then start a fresh process)
-- ============================================================
-- The plugin auto-appends an instruction telling the model to answer
-- with a single fenced code block, then strips the fence markers on
-- extraction. Expect back a bare SQL statement -- no "Here's a query
-- that does that:" preamble, no explanation, no visible ``` markers.

SELECT fractal_reason(
    'write a SQL query that selects all rows from demo_alerts where severity is critical'
);

-- ============================================================
-- MODE: json   (FSQL_REASONING_HTTP_RESPONSE_MODE=json, then start a fresh process)
-- ============================================================
-- Same fenced-block extraction as code mode, plus a structural
-- validity check (balanced braces/brackets) on the plugin side before
-- it's returned. A deeper parse-proof over the returned text (parsing
-- it as JSON again inside SQL) would need a JSON extension this build
-- does not load by default -- so that second check is not part of this
-- walkthrough; the plugin-side structural check is still real.
SELECT fractal_reason(
    'return a JSON object with keys critical_count, warning_count, and info_count summarizing the severities present',
    (SELECT list(t)::text FROM (SELECT severity FROM demo_alerts) t)
);
