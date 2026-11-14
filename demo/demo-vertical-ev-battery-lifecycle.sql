-- demo/demo-vertical-ev-battery-lifecycle.sql
--
-- Industry vertical: Electric-vehicle fleet battery lifecycle -- state-of-
-- health (SoH) and thermal-regime monitoring.  AGENTIC kit: two installed
-- agents are chained, shown hand-composed first and then as the shipped
-- one-call agents.
--
--   1. fractal_agent_patient_deterioration_triage -- cohort search plus
--      baseline-vs-current trajectory drift.  Its contract is domain-
--      neutral (a vehicle's intake baseline plays the patient's admission
--      baseline), so the kit only supplies different columns.
--   2. fractal_agent_anomaly_triage -- the DFA drift exponent of one
--      vehicle's temperature series, flagging a shift into a new regime
--      (pre-thermal-runaway) independently of the SoH comparison.
--   3. A closing fractal_reason() synthesizes both signals into one
--      maintenance / safety recommendation.
--
-- Prerequisites: extension installed.  Sections 1-4's hand-composed steps
-- need no model; the shipped agents and Section 5 need the reasoning
-- plugin (docs/reasoning-setup.md).
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; cat demo/demo-vertical-ev-battery-lifecycle.sql; } \
--       | duckdb -unsigned
--
-- Safe to re-run: ebl_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture: no random(), so every run returns the
--     same numbers.
--   * state is a float8[4] of [soh, temp_z, volt_z, fade_rate].
--   * Row locators: the search table functions return DuckDB's rowid as
--     doc_id (0-based scan position), and the patient_deterioration_triage
--     agent takes its cohort as a list of rowid values and resolves the
--     id column itself.
--   * The temperature series needs >= 48 points per vehicle for the 32-
--     point drift window (DFA needs the recent window large enough).  The
--     fault is an accelerating ramp, not a level shift: DFA removes a
--     constant offset, so only a change in the series' dynamics registers.

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Fleet telemetry: 3 vehicles x 96 readings.  EV-101 and EV-102 age
-- gently.  EV-203 develops a fault at reading 65: an accelerating
-- (quadratic) thermal ramp, a voltage sag and an accelerating SoH fade.
-- ------------------------------------------------------------------
.print
.print === 1. Fleet telemetry: 3 vehicles x 96 readings ===

DROP TABLE IF EXISTS ebl_telemetry;
DROP SEQUENCE IF EXISTS seq_ebl_telemetry_id;
CREATE SEQUENCE seq_ebl_telemetry_id;
CREATE TABLE ebl_telemetry (
    id         INTEGER PRIMARY KEY DEFAULT nextval('seq_ebl_telemetry_id'),
    vin        text,
    model_year int,
    seq        int,              -- reading order within the vehicle
    soh        float8,           -- state of health, fraction of nominal capacity
    temp_c     float8,           -- pack temperature
    volt       float8,           -- mean cell voltage under load
    state      float8[4]         -- fixed width: [soh, temp_z, volt_z, fade_rate]
);

INSERT INTO ebl_telemetry (vin, model_year, seq, soh, temp_c, volt, state)
WITH v(vi, vin, my) AS (VALUES (1, 'EV-101', 2024), (2, 'EV-102', 2024), (3, 'EV-203', 2023)),
     r AS (
       SELECT vi, vin, my, g,
              0.99 - 0.0004 * g
                - CASE WHEN vin = 'EV-203' AND g > 64 THEN 0.004 * (g - 64) ELSE 0 END AS soh,
              31.0 + (g % 8) * 0.6
                + CASE WHEN vin = 'EV-203' AND g > 64
                       THEN 0.02 * (g - 64) * (g - 64) ELSE 0 END AS temp_c,
              3.72 - (g % 5) * 0.004
                - CASE WHEN vin = 'EV-203' AND g > 64 THEN 0.09 ELSE 0 END AS volt
         FROM v, generate_series(1, 96) AS gs(g))
SELECT vin, my, g, soh, temp_c, volt,
       [round(soh, 4), round((temp_c - 35.0) / 10.0, 4),
        round((volt - 3.70) / 0.10, 4), round((0.99 - soh) / g, 6)]::float8[4]
  FROM r
 ORDER BY vi, g;

SELECT vin, count(*) AS readings, round(min(soh), 3) AS min_soh,
       round(max(temp_c), 1) AS max_temp_c
  FROM ebl_telemetry GROUP BY vin ORDER BY vin;

-- ------------------------------------------------------------------
-- 2. Step 1, hand-composed: baseline-vs-current trajectory search.
-- EV-203's intake baseline vs its latest reading; the nearest fleet
-- readings show where in the fleet's history the pack now sits.
-- (trajectory doc_id is the 0-based scan position = rowid.)
-- ------------------------------------------------------------------
.print
.print === 2. Step 1 (hand-composed): EV-203 baseline -> current trajectory ===

-- (A DuckDB table function takes literal arguments, not subqueries, so the
-- two states are EV-203's reading-1 and reading-96 `state` values written
-- out; the shipped agent in Section 3 reads them from the table itself.)
SELECT t.vin, t.seq, round(tr.distance, 4) AS distance
FROM fractal_search_trajectory(
         'ebl_telemetry', 'state',
         [0.9896, -0.34, 0.16, 0.0004]::float8[],      -- EV-203 intake baseline
         [0.8236, 1.648, -0.74, 0.001733]::float8[],   -- EV-203 reading 96
         5) tr
JOIN ebl_telemetry t ON t.rowid::VARCHAR = tr.doc_id::VARCHAR
ORDER BY tr.distance;

-- ------------------------------------------------------------------
-- 3. Step 1, productized: the shipped agent (a scalar returning one JSON
-- document).  The cohort is caller-built with ordinary SQL (model year
-- 2023, the cohort EV-203 belongs to) as a list of rowid values;
-- nearest_cohort_id / cohort_distance / drift_distance are real.
-- Reasoning-bearing: needs the plugin.
-- ------------------------------------------------------------------
.print
.print === 3. Step 1 (shipped agent): fractal_agent_patient_deterioration_triage ===

SELECT json_extract(j, '$.nearest_cohort_id')        AS nearest_cohort_id,
       round(json_extract(j, '$.cohort_distance')::double, 4) AS cohort_distance,
       round(json_extract(j, '$.drift_distance')::double, 4)  AS drift_distance,
       json_extract_string(j, '$.rationale')         AS rationale
FROM (SELECT fractal_agent_patient_deterioration_triage(
    'ebl_telemetry', 'state',
    (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 96),
    (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 1),
    (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 96),
    (SELECT list(rowid ORDER BY rowid) FROM ebl_telemetry WHERE model_year = 2023),
    5, 'id') AS j);

-- ------------------------------------------------------------------
-- 4. Step 2, hand-composed then productized: temperature-regime drift.
-- fractal_dimension_drift on each vehicle's temperature series; the
-- healthy pair sits near zero (slightly negative), EV-203's accelerating
-- ramp pushes the recent-window exponent far above its baseline.  (DFA
-- measures how the series' fluctuation scales, so the regime change is a
-- change in dynamics -- a pure level shift would not move it.)
-- ------------------------------------------------------------------
.print
.print === 4. Step 2 (hand-composed): temperature-regime drift per vehicle ===

SELECT vin,
       round(d.drift, 4)          AS drift,
       round(d.recent_alpha, 4)   AS recent_alpha,
       round(d.baseline_alpha, 4) AS baseline_alpha
FROM (SELECT vin, fractal_dimension_drift(list(temp_c ORDER BY seq), 32) AS d
        FROM ebl_telemetry GROUP BY vin) x
ORDER BY vin;

.print --- the shipped agent: same composition, one call (reasoning plugin) ---
SELECT json_extract(j, '$.threat_score')        AS threat_score,
       json_extract_string(j, '$.anomaly_type') AS anomaly_type,
       json_extract_string(j, '$.triage_summary') AS triage_summary
FROM (SELECT fractal_agent_anomaly_triage('ebl_telemetry', 'temp_c', 'seq', 'vin', 'EV-203', 32) AS j);

-- ------------------------------------------------------------------
-- 5. Reasoning: one maintenance / safety recommendation over BOTH
-- signals (needs the reasoning plugin).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: maintenance / safety recommendation for EV-203 ===

SELECT fractal_reason(
    'one-line maintenance and safety recommendation for an EV pack showing '
    || 'both an accelerating state-of-health fade and a thermal regime shift',
    json_object(
      'thermal_drift', (SELECT fractal_dimension_drift(list(temp_c ORDER BY seq), 32)
                          FROM ebl_telemetry WHERE vin = 'EV-203'),
      'soh_at_intake_vs_now', json_array(
              (SELECT soh FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 1),
              (SELECT soh FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 96)))::VARCHAR) AS recommendation;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE ebl_telemetry;
