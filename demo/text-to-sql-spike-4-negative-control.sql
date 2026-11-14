-- demo/text-to-sql-spike-4-negative-control.sql
-- Negative control for the review step: does review correctly say
-- FAIL on a deliberately WRONG candidate, or does it rubber-stamp
-- anything? Parts 1-3 only proved review says PASS on GOOD SQL --
-- this is the harder, more valuable check.
--
-- No mode change needed -- still in FSQL_REASONING_HTTP_RESPONSE_MODE=text
-- from part 2. Review-only, no generate/explain/execute. This build has
-- no SQL-visible "current model" setting -- uses the same
-- 'configured-model' label as parts 1-3.
--
-- The wrong candidate is the SAME query as the correct answer with the
-- critical-only filter simply removed -- syntactically perfect SQL
-- that answers a DIFFERENT, wrong question (includes payments and
-- auth-service, which have no critical alerts and should be excluded).

DROP TABLE IF EXISTS spike_negative_control;
CREATE TABLE spike_negative_control (
    model    text PRIMARY KEY,
    sql_text text,
    review   text
);

INSERT INTO spike_negative_control (model, sql_text) VALUES (
    'configured-model',
    'SELECT service, severity, COUNT(*) FROM demo_alerts GROUP BY service, severity;'
);

.print === What the wrong candidate actually produces (for reference) ===
SELECT service, severity, COUNT(*) FROM demo_alerts GROUP BY service, severity ORDER BY service ASC, severity ASC;
.print Note payments and auth-service present -- that is the bug review should catch.

.print === REVIEW (wrong candidate) ===
UPDATE spike_negative_control SET review = fractal_reason(
    'Original request: for each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert.

Candidate SQL:
' || sql_text || '

Does this candidate correctly implement the stated rule -- specifically, does it correctly EXCLUDE services with no critical-severity alerts, not just show all services grouped by severity? Answer PASS or FAIL on the first line, then explain briefly.'
) WHERE model = 'configured-model';

.print === Review of the WRONG candidate ===
SELECT model, review FROM spike_negative_control;

.print
.print ================================================================
.print Interpretation:
.print   - FAIL, correctly citing the missing critical-only filter ->
.print     review is discriminating, not rubber-stamping. Strong signal.
.print   - PASS on this obviously-wrong candidate -> review is not
.print     reliable for this model, do not depend on it as a real gate.
.print
.print Clean up: DROP TABLE spike_negative_control;
.print (spike_candidates from parts 1-3 is untouched by this file.)
.print ================================================================
