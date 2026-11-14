-- demo/demo-vertical-adas-safety-validation.sql
--
-- Industry vertical: ADAS / autonomous-driving safety validation --
-- edge-case interception before a maneuver is committed.  AGENTIC kit:
-- two signals are composed, shown hand-composed first and then as the
-- shipped one-call agent.
--
--   1. fractal_agent_outlier_intercept -- a pre-commit safety barrier:
--      screens a PROPOSED vehicle state vector against a history of
--      known-bad states (prior disengagements and near-misses), exactly
--      its designed contract.
--   2. fractal_search_trajectory -- flags when the vehicle's current
--      routing vector has moved away from the fleet baseline.
--   3. A closing fractal_reason() turns both signals into one verdict.
--
-- Prerequisites: extension installed.  The hand-composed sections (2, 4)
-- need no model; the shipped outlier_intercept agent returns a reasoned
-- `reason`, so Sections 3 and 5 need the reasoning plugin
-- (docs/reasoning-setup.md).
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; cat demo/demo-vertical-adas-safety-validation.sql; } \
--       | duckdb -unsigned
--
-- Safe to re-run: asv_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * State vectors are [speed_z, lateral_accel_z, brake_z, steer_rate_z]
--     as float8[4].  The intercept distance is COSINE by default, which
--     ignores magnitude: a mild maneuver in the same direction as a known-
--     bad one is intercepted too.  Pass 'l2' as the fifth argument when
--     magnitude should count (Section 3).
--   * The search table functions take literal arguments (no subqueries),
--     so the three proposals in Section 2 are written out; the shipped
--     agent in Section 3 is a scalar and reads them from the table.
--     Row locators: doc_id is DuckDB's rowid (0-based scan position).

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Known-bad state history and three proposed maneuvers.
-- ------------------------------------------------------------------
.print
.print === 1. Known-bad history + proposed maneuvers ===

DROP TABLE IF EXISTS asv_known_bad;
DROP SEQUENCE IF EXISTS seq_asv_known_bad_id;
CREATE SEQUENCE seq_asv_known_bad_id;
CREATE TABLE asv_known_bad (
    id       INTEGER PRIMARY KEY DEFAULT nextval('seq_asv_known_bad_id'),
    scenario text,
    state    float8[4]
);
INSERT INTO asv_known_bad (scenario, state) VALUES
    ('hard brake at highway speed',   [0.90, 0.10, 0.95, 0.10]),
    ('evasive swerve',                [0.50, 0.90, 0.20, 0.95]),
    ('late brake approaching a stop', [0.40, 0.05, 0.90, 0.05]),
    ('lane drift under load',         [0.70, 0.60, 0.05, 0.30]);

DROP TABLE IF EXISTS asv_proposed;
DROP SEQUENCE IF EXISTS seq_asv_proposed_id;
CREATE SEQUENCE seq_asv_proposed_id;
CREATE TABLE asv_proposed (
    id    INTEGER PRIMARY KEY DEFAULT nextval('seq_asv_proposed_id'),
    label text,
    state float8[4]
);
INSERT INTO asv_proposed (label, state) VALUES
    ('P1 firm brake, high speed',   [0.88, 0.12, 0.90, 0.15]),
    ('P2 steady cruise',            [0.55, 0.02, 0.02, 0.01]),
    ('P3 gentle lane change',       [0.45, 0.35, 0.05, 0.30]);

SELECT count(*) AS known_bad_states FROM asv_known_bad;

-- ------------------------------------------------------------------
-- 2. Step 1, hand-composed: nearest known-bad state per proposal,
-- threshold 0.15 (cosine).
-- ------------------------------------------------------------------
.print
.print === 2. Step 1 (hand-composed): nearest known-bad state, threshold 0.15 ===

WITH hits AS (
    SELECT 'P1 firm brake, high speed' AS label, doc_id, distance
      FROM fractal_search_telemetry('asv_known_bad', 'state', [0.88, 0.12, 0.90, 0.15]::float8[], 1)
    UNION ALL
    SELECT 'P2 steady cruise', doc_id, distance
      FROM fractal_search_telemetry('asv_known_bad', 'state', [0.55, 0.02, 0.02, 0.01]::float8[], 1)
    UNION ALL
    SELECT 'P3 gentle lane change', doc_id, distance
      FROM fractal_search_telemetry('asv_known_bad', 'state', [0.45, 0.35, 0.05, 0.30]::float8[], 1))
SELECT h.label, k.scenario AS nearest_bad,
       round(h.distance, 4) AS distance,
       (h.distance < 0.15) AS intercepted
FROM hits h
JOIN asv_known_bad k ON k.rowid::VARCHAR = h.doc_id::VARCHAR
JOIN asv_proposed p ON p.label = h.label
ORDER BY p.id;

-- ------------------------------------------------------------------
-- 3. Step 1, productized: the shipped agent (a scalar returning one JSON
-- document; its `reason` field is reasoning-bearing).  Note P3: the
-- cosine check intercepts it (same direction as the known-bad lane
-- drift, just gentler); exact Euclidean distance lets it through because
-- magnitude counts.
-- ------------------------------------------------------------------
.print
.print === 3. Step 1 (shipped agent): fractal_agent_outlier_intercept ===

SELECT p.label,
       json_extract(o, '$.intercepted')        AS intercepted,
       json_extract_string(o, '$.metric')      AS metric,
       json_extract_string(o, '$.reason')      AS reason
FROM (SELECT id, label, fractal_agent_outlier_intercept(
               state, 'asv_known_bad', 'state', 0.15) AS o FROM asv_proposed) p
ORDER BY p.id;

.print --- same check under exact Euclidean distance (magnitude counts) ---
SELECT p.label, json_extract(o, '$.intercepted') AS intercepted_l2
FROM (SELECT id, label, fractal_agent_outlier_intercept(
               state, 'asv_known_bad', 'state', 0.30, 'l2') AS o FROM asv_proposed) p
ORDER BY p.id;

-- ------------------------------------------------------------------
-- 4. Step 2: routing deviation from the fleet baseline.  40 fleet
-- vehicles on three lane/speed bands; vehicle V-17's routing vector
-- (lateral offset, heading, speed) is compared against the fleet
-- baseline.  The nearest fleet members to the baseline and to the
-- current vector show how far this vehicle has strayed.
-- ------------------------------------------------------------------
.print
.print === 4. Step 2: routing deviation from the fleet baseline ===

DROP TABLE IF EXISTS asv_routes;
DROP SEQUENCE IF EXISTS seq_asv_routes_id;
CREATE SEQUENCE seq_asv_routes_id;
CREATE TABLE asv_routes (
    id      INTEGER PRIMARY KEY DEFAULT nextval('seq_asv_routes_id'),
    vehicle text,
    route   float8[3]
);
INSERT INTO asv_routes (vehicle, route)
SELECT 'V-' || g,
       [0.10 * (g % 3) + 0.01 * (g % 7),            -- lateral offset
        0.05 * (g % 4),                             -- heading error
        0.60 + 0.05 * (g % 3) + 0.004 * (g % 5)]    -- speed band
FROM generate_series(1, 40) AS gs(g)
ORDER BY g;

SELECT r.vehicle, round(tr.distance, 4) AS distance
FROM fractal_search_trajectory(
         'asv_routes', 'route',
         [0.100, 0.050, 0.650]::float8[],      -- fleet baseline routing vector
         [0.900, 0.800, 0.200]::float8[],      -- V-17 now: far off its lane/speed band
         3) tr
JOIN asv_routes r ON r.rowid::VARCHAR = tr.doc_id::VARCHAR
ORDER BY tr.distance;

-- ------------------------------------------------------------------
-- 5. Reasoning: one go / no-go verdict over both signals (needs the
-- reasoning plugin).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: go / no-go verdict for proposal P1 ===

SELECT fractal_reason(
    'one-line go/no-go safety verdict for this proposed ADAS maneuver',
    json_object(
      'intercept', json((SELECT fractal_agent_outlier_intercept(
                           state, 'asv_known_bad', 'state', 0.15)
                           FROM asv_proposed WHERE id = 1)),
      'routing_deviation', (SELECT json_group_array(json_object('doc_id', doc_id, 'distance', distance))
                              FROM fractal_search_trajectory('asv_routes', 'route',
                                     [0.100, 0.050, 0.650]::float8[],
                                     [0.900, 0.800, 0.200]::float8[], 2)))::VARCHAR) AS verdict;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE asv_known_bad, asv_proposed, asv_routes;
