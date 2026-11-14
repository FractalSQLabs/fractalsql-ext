-- demo/demo-vertical-avionics-fault-prediction.sql
--
-- Industry vertical: aerospace -- avionics and flight-path fault
-- prediction across a fleet.  DOMAIN kit built on one installed agent,
-- fractal_agent_track_anomaly, which generalizes directly from the
-- maritime-defense kit's 2D tracks to 3D flight paths: same agent, same
-- contract (trajectory deviation search + heading-change DFA exponent),
-- closing with a reasoned classification of the deviation.
--
-- Prerequisites: extension installed.  Sections 1-3 need no model; the
-- shipped agent and the closing classification are reasoning-bearing
-- (docs/reasoning-setup.md).
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; cat demo/demo-vertical-avionics-fault-prediction.sql; } \
--       | duckdb -unsigned
--
-- Safe to re-run: afp_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture: heading noise comes from an integer
--     LCG in a recursive CTE, not random().
--   * Each flight carries a planned-path vector and its latest-state
--     vector, [x_km, y_km, altitude_km] as a fixed-width float8[3].
--     Flight AC-09 has a stuck control surface: its path has drifted off
--     plan and its heading changes become erratic for a stretch of the
--     flight.
--   * fractal_search_trajectory returns the 0-based scan position (rowid)
--     as doc_id and takes literal vectors; the agent resolves the nearest
--     fleet member's id itself.  AC-09 is built into the INSERT (not a
--     later UPDATE) because DuckDB gives an updated row a new rowid.
--   * DFA needs a reasonable series length (a few dozen points at
--     minimum); the heading series here is 120 samples.

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. A 12-aircraft fleet: planned path vs current state in 3D.  Eleven
-- are on plan to within small offsets; AC-09 has drifted far off plan
-- (lateral and vertical).
-- ------------------------------------------------------------------
.print
.print === 1. Fleet: planned path vs current state (3D) ===

DROP TABLE IF EXISTS afp_flights;
DROP SEQUENCE IF EXISTS seq_afp_flights_id;
CREATE SEQUENCE seq_afp_flights_id;
CREATE TABLE afp_flights (
    id          INTEGER PRIMARY KEY DEFAULT nextval('seq_afp_flights_id'),
    flight      text,
    baseline    float8[3],
    current_pos float8[3]
);

INSERT INTO afp_flights (flight, baseline, current_pos)
SELECT 'AC-' || lpad(g::VARCHAR, 2, '0'),
       [0.20 + 0.05 * g, 0.40 + 0.02 * (g % 4), 0.80]::float8[3],
       CASE WHEN g = 9
            THEN [0.900, 1.400, 0.350]            -- AC-09: far off plan
            ELSE [0.20 + 0.05 * g + 0.004 * (g % 3),
                  0.40 + 0.02 * (g % 4) + 0.003 * (g % 2),
                  0.80 - 0.002 * (g % 3)]
       END::float8[3]
FROM generate_series(1, 12) AS gs(g)
ORDER BY g;

SELECT flight, baseline, current_pos FROM afp_flights WHERE flight IN ('AC-01', 'AC-09');

-- ------------------------------------------------------------------
-- 2. Heading-change series: a steady transit (small noise) vs AC-09's
-- erratic stretch (large swings between samples 60 and 90).  The
-- running sum is the heading walk the DFA exponent is computed on.
-- ------------------------------------------------------------------
.print
.print === 2. DFA of the heading walk: steady flight vs AC-09 ===

WITH RECURSIVE n(t, x) AS (
       SELECT 1, 7919::bigint UNION ALL
       SELECT t + 1, (x * 1103515245 + 12345) % 2147483648 FROM n WHERE t < 120),
     steps AS (SELECT t, (((x // 65536) % 1000) - 500) / 1000.0 AS u FROM n),
     walk AS (SELECT t, sum(u * 0.03) OVER (ORDER BY t) AS s FROM steps),
     walk9 AS (SELECT t, sum(u * CASE WHEN t BETWEEN 60 AND 90 THEN 0.35 ELSE 0.03 END)
                              OVER (ORDER BY t) AS s FROM steps)
SELECT 'steady flight' AS series,
       round(fractal_dimension_dfa(list(round(s, 6) ORDER BY t)), 3) AS dfa_alpha
  FROM walk
UNION ALL
SELECT 'AC-09 erratic stretch',
       round(fractal_dimension_dfa(list(round(s, 6) ORDER BY t)), 3)
  FROM walk9;

-- ------------------------------------------------------------------
-- 3. Hand-composed: trajectory deviation of AC-09 -- the fleet members
-- nearest to its planned path and to where it is now.  (AC-09's planned
-- and current vectors written out as literals: baseline 0.65/0.42/0.80,
-- current 0.90/1.40/0.35.)
-- ------------------------------------------------------------------
.print
.print === 3. AC-09 baseline -> current trajectory search ===

SELECT p.flight, round(tr.distance, 4) AS distance
FROM fractal_search_trajectory(
         'afp_flights', 'current_pos',
         [0.65, 0.42, 0.80]::float8[],
         [0.900, 1.400, 0.350]::float8[],
         5) tr
JOIN afp_flights p ON p.rowid::VARCHAR = tr.doc_id::VARCHAR
ORDER BY tr.distance;

-- ------------------------------------------------------------------
-- 4. The shipped agent: trajectory deviation + heading DFA + a reasoned
-- classification in one call (reasoning plugin).
-- ------------------------------------------------------------------
.print
.print === 4. fractal_agent_track_anomaly (3D flight path) ===

WITH RECURSIVE n(t, x) AS (
       SELECT 1, 7919::bigint UNION ALL
       SELECT t + 1, (x * 1103515245 + 12345) % 2147483648 FROM n WHERE t < 120),
     steps AS (SELECT t, (((x // 65536) % 1000) - 500) / 1000.0 AS u FROM n),
     walk AS (SELECT t, sum(u * CASE WHEN t BETWEEN 60 AND 90 THEN 0.35 ELSE 0.03 END)
                            OVER (ORDER BY t) AS s FROM steps),
     r AS (SELECT fractal_agent_track_anomaly(
               'afp_flights', 'current_pos',
               (SELECT baseline    FROM afp_flights WHERE flight = 'AC-09'),
               (SELECT current_pos FROM afp_flights WHERE flight = 'AC-09'),
               (SELECT list(round(s, 6) ORDER BY t) FROM walk),
               5, 'id') AS j)
SELECT json_extract(j, '$.nearest_fleet_id')                       AS nearest_fleet_id,
       round(json_extract(j, '$.trajectory_distance')::double, 4)  AS trajectory_distance,
       round(json_extract(j, '$.dfa_exponent')::double, 3)         AS dfa_exponent,
       json_extract_string(j, '$.rationale')                       AS rationale
FROM r;

-- ------------------------------------------------------------------
-- 5. Reasoning: classify the deviation (needs the reasoning plugin).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: classify the deviation ===

SELECT fractal_reason(
    'one-line classification of this flight-path deviation: sensor fault, control-surface fault, or weather',
    (SELECT json_group_array(json_object('doc_id', doc_id, 'distance', distance))::VARCHAR
       FROM fractal_search_trajectory('afp_flights', 'current_pos',
              [0.65, 0.42, 0.80]::float8[],
              [0.900, 1.400, 0.350]::float8[], 3))) AS classification;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE afp_flights;
