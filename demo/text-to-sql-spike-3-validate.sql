-- demo/text-to-sql-spike-3-validate.sql
-- Part 3 of 3 of the text-to-sql validation walkthrough. Requires Parts 1
-- and 2 to have already run. No mode dependency -- EXPLAIN and direct
-- execution are mechanical, not reasoning calls.
--
-- Correct result: exactly 2 rows in the final SELECT's output,
-- service=api-gateway, (severity=info, count=2) and
-- (severity=critical, count=2). payments and auth-service must NOT
-- appear.
--
-- There is no client-side "execute this string I just got back"
-- mechanism in this CLI outside a host language. This file prints the
-- candidate's EXPLAIN and its own SQL
-- text for you to copy/paste and run directly, rather than faking
-- automation that doesn't exist. A host script (Python/Node/R against
-- the duckdb client library) could automate this by re-issuing the
-- fetched string as a new query -- not attempted here, this is a
-- manual walkthrough by design.

.print === Candidate SQL (model: configured-model) ===
SELECT sql_text FROM spike_candidates WHERE model = 'configured-model';

.print
.print === EXPLAIN it yourself: paste "EXPLAIN <sql_text above>" here ===
.print (mechanical only -- confirms it parses and plans, doesn't run it)

.print
.print === Then run the candidate's sql_text directly to see the actual rows ===
.print (manual validation only -- the real feature never auto-executes;
.print this is you checking the answer is actually correct, not just
.print syntactically valid. fractal_sql_agent's auto_execute argument is
.print the in-database alternative when the candidate comes straight out
.print of fractal_text_to_sql/fractal_sql_agent rather than from this
.print walkthrough's separately-stored table.)

.print
.print ================================================================
.print Interpretation:
.print   - EXPLAIN failed -> syntactically broken SQL, a real problem
.print     (EXPLAIN-only validation would have caught it).
.print   - EXPLAIN passed but running it shows payments/auth-service rows
.print     -> syntactically valid, semantically WRONG. This is exactly
.print     the gap review exists to catch -- check whether review said
.print     PASS or FAIL for this (wrong) candidate.
.print   - Review said PASS on a candidate that runs wrong -> the
.print     review step itself is not reliable for this model.
.print   - EXPLAIN passes, running it shows only api-gateway (info=2,
.print     critical=2) -> strong go signal for this model.
.print
.print Clean up when done: DROP TABLE spike_candidates;
.print ================================================================
