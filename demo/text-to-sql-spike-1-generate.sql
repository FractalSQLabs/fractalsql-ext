-- demo/text-to-sql-spike-1-generate.sql
-- Part 1 of 3 of the text-to-sql validation walkthrough (see
-- text-to-sql-spike-2-review.sql and -3-validate.sql for the rest).
--
-- Generates one candidate using whichever model FSQL_REASONING_HTTP_
-- MODEL is currently pointed at -- a quality-control check on
-- fractal_text_to_sql()/fractal_reason() for YOUR configured model,
-- not a fixed model comparison.
--
-- REQUIRES FSQL_REASONING_HTTP_RESPONSE_MODE=code -- set it before
-- starting the process that loads this extension (the reasoning
-- plugin reads its env once, at first dispatch; a change to
-- this env var needs a fresh process). See "Switching modes" in
-- ../docs/reasoning-setup.md.
--
-- Prerequisites: reasoning configured, demo_alerts table present (run
-- demo.sql first if you haven't).
--
-- The env vars above are this build's only model configuration --
-- the `model` column
-- below is a plain descriptive label, not something queried from the
-- session. Edit the literal on the INSERT below to match whatever
-- FSQL_REASONING_HTTP_MODEL you actually have set, if you want
-- the label to be accurate.
--
-- Without a reasoning plugin configured the fractal_reason() statement
-- below is the intended first failure, and its error is the clean
-- "reasoning plugin not configured" hint rather than a crash.

DROP TABLE IF EXISTS spike_candidates;
CREATE TABLE spike_candidates (
    model    text PRIMARY KEY,
    sql_text text,
    review   text
);

.print === GENERATE ===
INSERT INTO spike_candidates (model, sql_text) VALUES (
    'configured-model',
    fractal_reason(
        'Write a single DuckDB SELECT statement that answers this question: for each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert. Return only the SQL, no explanation.',
        'Schema: demo_alerts(id INTEGER PK, service text, message text, severity text CHECK IN (''info'',''warning'',''critical''), created_at timestamptz). No foreign keys, this is the only table.'
    )
);

.print === Candidate ===
SELECT model, sql_text FROM spike_candidates;

.print
.print ================================================================
.print Next: switch FSQL_REASONING_HTTP_RESPONSE_MODE=text (new process),
.print then run demo/text-to-sql-spike-2-review.sql
.print ================================================================
