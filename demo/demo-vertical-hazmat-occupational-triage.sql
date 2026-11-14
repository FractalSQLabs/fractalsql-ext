-- demo/demo-vertical-hazmat-occupational-triage.sql
--
-- Industry vertical: occupational exposure monitoring -- hazardous-
-- materials response, chemical and nuclear plant crews, wearable-sensor
-- workforce safety.  DOMAIN kit built on one installed agent,
-- fractal_agent_patient_deterioration_triage, reused verbatim: its
-- contract (cohort vector search + baseline-vs-current trajectory drift)
-- is domain-neutral, so the kit only supplies exposure columns in place
-- of clinical vitals and a worker's pre-shift baseline in place of an
-- admission baseline.
--
-- Prerequisites: extension installed.  Sections 1-3 need no model; the
-- shipped agent and the closing recommendation are reasoning-bearing
-- (docs/reasoning-setup.md).
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; cat demo/demo-vertical-hazmat-occupational-triage.sql; } \
--       | duckdb -unsigned
--
-- Safe to re-run: hot_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * Exposure vectors are [dose_rate_z, body_temp_z, air_quality_z,
--     heart_rate_z] as a fixed-width float8[4]: a wrong-width write from
--     a wearable integration fails loudly at write time, not silently
--     inside a worker record.
--   * Row locators: DuckDB's rowid is the doc_id of the search table
--     functions, and the agent takes its cohort as a list of rowid
--     values.  A table function takes literal arguments, so Section 2's
--     cohort is the rowid list written out (Section 1 prints it from the
--     table so you can see they match); the agent in Section 4 builds
--     its cohort with a subquery.
--   * The cohort is caller-built with ordinary SQL (same work zone AND
--     same shift) -- the two-predicate cohort a single filter pair cannot
--     express.

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 36 synthetic workers across three work zones and two shifts.
-- Zone 'reactor-bay' on the night shift is the contaminated cohort:
-- workers 7, 15 and 31 show elevated dose rate, temperature and heart
-- rate.
-- ------------------------------------------------------------------
.print
.print === 1. 36 workers: zone, shift and current exposure vector ===

DROP TABLE IF EXISTS hot_workers;
DROP SEQUENCE IF EXISTS seq_hot_workers_id;
CREATE SEQUENCE seq_hot_workers_id;
CREATE TABLE hot_workers (
    id       INTEGER PRIMARY KEY DEFAULT nextval('seq_hot_workers_id'),
    zone     text,
    shift    text,
    exposure float8[4]
);

-- The contaminated cohort (workers 7, 15, 31) is forced inside the INSERT,
-- not with a later UPDATE: DuckDB rewrites an updated row under a new
-- rowid, which would shift the rowid locators this kit relies on.
INSERT INTO hot_workers (zone, shift, exposure)
SELECT CASE WHEN g IN (7, 15, 31) THEN 'reactor-bay'
            ELSE CASE g % 3 WHEN 0 THEN 'reactor-bay' WHEN 1 THEN 'fuel-handling' ELSE 'control-room' END END,
       CASE WHEN g IN (7, 15, 31) THEN 'night'
            ELSE CASE WHEN g % 2 = 0 THEN 'night' ELSE 'day' END END,
       CASE WHEN g IN (7, 15, 31) THEN [1.40, 0.90, 1.10, 1.20]
            ELSE [0.05 * (g % 5),            -- dose rate
                  0.04 * (g % 7) - 0.10,     -- body temperature
                  0.03 * (g % 4),            -- air quality
                  0.06 * (g % 6) - 0.10]     -- heart rate
       END::float8[4]
FROM generate_series(1, 36) AS gs(g)
ORDER BY g;

SELECT zone, shift, count(*) AS workers FROM hot_workers
 GROUP BY zone, shift ORDER BY zone, shift;

.print --- the reactor-bay night-shift cohort as rowids (used literally in Section 2) ---
SELECT list(rowid::VARCHAR ORDER BY rowid) AS cohort_rowids
  FROM hot_workers WHERE zone = 'reactor-bay' AND shift = 'night';

-- ------------------------------------------------------------------
-- 2. Hand-composed: cohort-restricted search.  Nearest reactor-bay
-- night-shift workers to the exposure profile of the worker under
-- review.
-- ------------------------------------------------------------------
.print
.print === 2. Cohort-restricted search: reactor-bay, night shift ===

SELECT w.id AS worker_id, w.zone, w.shift, round(h.distance, 4) AS distance
FROM fractal_hybrid_clinical_search(
         'hot_workers', 'exposure', [1.40, 0.90, 1.10, 1.20]::float8[],
         ['5', '6', '11', '14', '17', '23', '29', '30', '35'], 5) h
JOIN hot_workers w ON w.rowid::VARCHAR = h.doc_id::VARCHAR
ORDER BY h.distance, w.id;

-- ------------------------------------------------------------------
-- 3. Hand-composed: pre-shift baseline vs current exposure.
-- ------------------------------------------------------------------
.print
.print === 3. Baseline -> current exposure trajectory ===

SELECT p.id AS worker_id, p.zone, p.shift, round(tr.distance, 4) AS distance
FROM fractal_search_trajectory(
         'hot_workers', 'exposure',
         [0.05, 0.00, 0.03, 0.00]::float8[],    -- pre-shift baseline
         [1.40, 0.90, 1.10, 1.20]::float8[],    -- current (escalating)
         5) tr
JOIN hot_workers p ON p.rowid::VARCHAR = tr.doc_id::VARCHAR
ORDER BY tr.distance, p.id;

-- ------------------------------------------------------------------
-- 4. The shipped agent: both searches plus a reasoned rationale in one
-- call (reasoning plugin).  The rationale is the countermeasure-
-- dispatch recommendation.
-- ------------------------------------------------------------------
.print
.print === 4. fractal_agent_patient_deterioration_triage (exposure triage) ===

SELECT json_extract(j, '$.nearest_cohort_id')                 AS nearest_cohort_id,
       round(json_extract(j, '$.cohort_distance')::double, 4) AS cohort_distance,
       round(json_extract(j, '$.drift_distance')::double, 4)  AS drift_distance,
       json_extract_string(j, '$.rationale')                  AS rationale,
       json_extract(j, '$.cohort_matches')                    AS cohort_matches
FROM (SELECT fractal_agent_patient_deterioration_triage(
    'hot_workers', 'exposure', [1.40, 0.90, 1.10, 1.20]::float8[],
    [0.05, 0.00, 0.03, 0.00]::float8[], [1.40, 0.90, 1.10, 1.20]::float8[],
    (SELECT list(rowid ORDER BY rowid) FROM hot_workers
      WHERE zone = 'reactor-bay' AND shift = 'night'),
    5, 'id') AS j);

-- ------------------------------------------------------------------
-- 5. Reasoning: the medical-countermeasure dispatch recommendation
-- (needs the reasoning plugin).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: countermeasure dispatch recommendation ===

SELECT fractal_reason(
    'one-line medical-countermeasure dispatch recommendation for this exposed work crew',
    (SELECT json_group_array(json_object('doc_id', doc_id, 'distance', distance))::VARCHAR
       FROM fractal_hybrid_clinical_search(
         'hot_workers', 'exposure', [1.40, 0.90, 1.10, 1.20]::float8[],
         ['5', '6', '11', '14', '17', '23', '29', '30', '35'], 3))) AS recommendation;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE hot_workers;
