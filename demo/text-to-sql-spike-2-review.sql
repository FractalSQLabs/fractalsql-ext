-- demo/text-to-sql-spike-2-review.sql
-- Part 2 of 3 of the text-to-sql validation walkthrough. Requires Part 1 to
-- have already run (reads from spike_candidates).
--
-- REQUIRES FSQL_REASONING_HTTP_RESPONSE_MODE=text -- set it before
-- starting a fresh process (switching back from the code mode Part 1
-- needed; the reasoning plugin reads this env once, at first
-- dispatch, so changing it mid-process has no effect).
-- See "Switching modes" in ../docs/reasoning-setup.md.
--
-- The model reviews its OWN candidate, matching how the real feature
-- would run (same configured endpoint for both steps). This build has
-- no SQL-visible "current model" setting -- the `model` label below
-- must match whatever literal spike-1 used for this to find the row.

.print === REVIEW ===
UPDATE spike_candidates SET review = fractal_reason(
    'Original request: for each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert.

Candidate SQL:
' || sql_text || '

Does this candidate correctly implement the stated rule -- specifically, does it correctly EXCLUDE services with no critical-severity alerts, not just show all services grouped by severity? Answer PASS or FAIL on the first line, then explain briefly.'
) WHERE model = 'configured-model';

.print === Review ===
SELECT model, review FROM spike_candidates;

.print
.print ================================================================
.print Next: run demo/text-to-sql-spike-3-validate.sql (no mode change
.print needed -- EXPLAIN and direct execution have no mode dependency).
.print ================================================================
