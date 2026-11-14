-- demo/demo-vertical-scenario-planning-simulation.sql
--
-- Industry vertical: strategic scenario planning and simulation training
-- -- business continuity, logistics contingency, tabletop and training
-- exercises.  DOMAIN kit built on one installed agent,
-- fractal_agent_plan_explore (MCTS-style exploration), reused verbatim:
-- its designed job is to produce a SPREAD of distinct, non-overlapping
-- strategy trajectories from a seed state, which is exactly a scenario
-- variant set.
--
--   1. A strategy / scenario space (24 candidate scenarios placed in a
--      4-dimension option space: cost, risk, speed, resilience).
--   2. fractal_search_explore (Scout, the diversity-first search) over
--      the raw option space -- pure analytics, no model -- to pick six
--      deliberately different scenarios.
--   3. fractal_agent_plan_explore -- the shipped agent: embeds a seed
--      state description and Scout-searches the vectorized scenario
--      descriptions for diverse branches (needs an embedding endpoint
--      and the reasoning plugin).
--   4. A closing fractal_reason() summarizes the generated scenario set.
--
-- Prerequisites: extension installed.  Sections 1-2 need nothing else.
-- Section 3's vectorization and Section 4's plan_explore need an EMBEDDING
-- endpoint, and Section 5 the reasoning plugin -- see
-- docs/vectorizer-setup.md and docs/reasoning-setup.md.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; cat demo/demo-vertical-scenario-planning-simulation.sql; } \
--       | duckdb -unsigned
--
-- Safe to re-run: sps_* tables are dropped and recreated each time (the
-- vectorizer registry rows are removed first).
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * Scout (fractal_search_explore) is an MMR diversity search: lowering
--     mmr_lambda trades relevance to the seed for spread.  It returns the
--     final population as vectors (one `particle` list per row); Section 2
--     maps each back to its scenario row by exact option-space coordinates.
--   * The embedding column is an open-width float8[]; the width is set by
--     your embedding endpoint.

-- The vectorizer registry tables are created on first use; the status
-- call below makes sure they exist so the cleanup DELETEs work on a
-- brand-new database too.
SELECT count(*) AS registered_vectorizers FROM fractal_vectorizer_status();
DELETE FROM fractal_vectorizer_queue
 WHERE vectorizer_id IN (SELECT id FROM fractal_vectorizers WHERE source_table = 'sps_scenarios');
DELETE FROM fractal_vectorizers WHERE source_table = 'sps_scenarios';

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 24 candidate scenarios in four clusters of six.  Coordinates are
-- [cost, risk, speed, resilience], each in 0..1.
-- ------------------------------------------------------------------
.print
.print === 1. Scenario space: 24 candidates in four clusters ===

DROP TABLE IF EXISTS sps_scenarios;
DROP SEQUENCE IF EXISTS seq_sps_scenarios_id;
CREATE SEQUENCE seq_sps_scenarios_id;
CREATE TABLE sps_scenarios (
    id          INTEGER PRIMARY KEY DEFAULT nextval('seq_sps_scenarios_id'),
    description text,
    cost        float8,
    risk        float8,
    speed       float8,
    resilience  float8,
    opt_vec     float8[4],
    embedding   float8[]                   -- populated by the vectorizer
);

INSERT INTO sps_scenarios (description, cost, risk, speed, resilience, opt_vec)
WITH c AS (
       SELECT g,
              CASE g % 4 WHEN 0 THEN 'dual-source suppliers with safety stock'
                         WHEN 1 THEN 'nearshore relocation of critical lines'
                         WHEN 2 THEN 'regional hub-and-spoke redistribution'
                         ELSE 'expedited air-freight surge capacity' END AS label,
              CASE g % 4 WHEN 0 THEN 0.70 WHEN 1 THEN 0.85 WHEN 2 THEN 0.40 ELSE 0.90 END AS c0,
              CASE g % 4 WHEN 0 THEN 0.20 WHEN 1 THEN 0.35 WHEN 2 THEN 0.30 ELSE 0.55 END AS c1,
              CASE g % 4 WHEN 0 THEN 0.40 WHEN 1 THEN 0.25 WHEN 2 THEN 0.65 ELSE 0.95 END AS c2,
              CASE g % 4 WHEN 0 THEN 0.85 WHEN 1 THEN 0.80 WHEN 2 THEN 0.60 ELSE 0.35 END AS c3
         FROM generate_series(1, 24) AS gs(g)),
     v AS (
       SELECT g, label,
              round(c0 + 0.01 * (g % 5), 3) AS cost,
              round(c1 + 0.01 * (g % 3), 3) AS risk,
              round(c2 + 0.01 * (g % 4), 3) AS speed,
              round(c3 - 0.01 * (g % 5), 3) AS resilience
         FROM c)
SELECT label || ' (variant ' || g || ')', cost, risk, speed, resilience,
       [cost, risk, speed, resilience]::float8[4]
  FROM v ORDER BY g;

SELECT count(*) AS scenarios FROM sps_scenarios;

-- ------------------------------------------------------------------
-- 2. Scout over the raw option space: six deliberately different
-- scenarios around the seed "current plan" (cost 0.6, risk 0.3,
-- speed 0.5, resilience 0.7).  A low mmr_lambda favors spread.
-- ------------------------------------------------------------------
.print
.print === 2. Scout (diversity-first): six different scenarios ===

DROP TABLE IF EXISTS sps_scout;
CREATE TABLE sps_scout AS
SELECT row_number() OVER () AS ord, particle AS p
FROM fractal_search_explore(
         'sps_scenarios', 'opt_vec', [0.6, 0.3, 0.5, 0.7]::float8[],
         '{"population_size": 6, "iterations": 8, "mmr_lambda": 0.15}');

SELECT s.id, s.description
FROM sps_scout t
JOIN sps_scenarios s
  ON abs(s.cost - t.p[1]) < 1e-6 AND abs(s.risk - t.p[2]) < 1e-6
 AND abs(s.speed - t.p[3]) < 1e-6 AND abs(s.resilience - t.p[4]) < 1e-6
ORDER BY t.ord;

.print --- coverage: scenario clusters represented in the six picks ---
SELECT count(DISTINCT s.id % 4) AS clusters_covered_of_4
FROM sps_scout t
JOIN sps_scenarios s
  ON abs(s.cost - t.p[1]) < 1e-6 AND abs(s.risk - t.p[2]) < 1e-6
 AND abs(s.speed - t.p[3]) < 1e-6 AND abs(s.resilience - t.p[4]) < 1e-6;

-- ------------------------------------------------------------------
-- 3. Vectorize the scenario descriptions (your configured embedding
-- endpoint's width).  Without an endpoint the queued rows fail with a
-- clean last_error (see demo-vectorizer.sql) and the agent call below
-- reports an error instead -- the rest of the script still runs.
-- ------------------------------------------------------------------
.print
.print === 3. Vectorize the scenario descriptions ===
SELECT fractal_vectorizer_create('sps_scenarios', 'id', 'description', 'embedding');
SELECT fractal_vectorizer_process_queue();

-- ------------------------------------------------------------------
-- 4. The shipped agent: MCTS-style exploration from a seed state.
-- ------------------------------------------------------------------
.print
.print === 4. fractal_agent_plan_explore (MCTS-style scenario branches) ===

SELECT *
FROM fractal_agent_plan_explore(
    'regional supply disruption with a two-week port closure',
    'sps_scenarios', 'embedding', 4);

-- ------------------------------------------------------------------
-- 5. Reasoning: a summary of the generated scenario set (needs the
-- reasoning plugin).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: summary of the scenario set ===

SELECT fractal_reason(
    'one-line summary of how these continuity scenarios differ and when to use each',
    (SELECT string_agg(s.description, '; ' ORDER BY t.ord)
       FROM sps_scout t
       JOIN sps_scenarios s
         ON abs(s.cost - t.p[1]) < 1e-6 AND abs(s.risk - t.p[2]) < 1e-6
        AND abs(s.speed - t.p[3]) < 1e-6 AND abs(s.resilience - t.p[4]) < 1e-6)) AS summary;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE sps_scenarios, sps_scout;
