-- demo/demo-vertical-telecom-account-anomaly-screening.sql
--
-- Industry vertical: telecom -- anomalous account-change screening (SIM
-- swap, port-out, plan change, unusual device or location changes).  A
-- general-purpose pre-commit safety check, not a fraud-specific product.
-- DOMAIN kit built on one installed agent,
-- fractal_agent_outlier_intercept, reused verbatim: it screens a
-- PROPOSED event against a history of known-anomalous change patterns,
-- exactly its designed contract (the same shape as the ADAS kit's
-- known-bad-state history, applied to account activity).
--
-- Prerequisites: extension installed.  The hand-composed screen needs no
-- model; the shipped agent returns a reasoned `reason`
-- (docs/reasoning-setup.md).
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; cat demo/demo-vertical-telecom-account-anomaly-screening.sql; } \
--       | duckdb -unsigned
--
-- Safe to re-run: taa_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * Event vectors are [sim_change, port_out, new_device, geo_jump,
--     off_hours] intensities in 0..1 as a fixed-width float8[5].
--   * Cosine distance (the default) compares the SHAPE of an event, not
--     its overall intensity: a faint version of a known pattern is
--     flagged too.  Use 'l2' when intensity should count (Section 4).
--   * fractal_search_telemetry returns the row's rowid as doc_id and takes
--     a literal query vector, so Section 2 writes the four proposed
--     events out; the shipped agent (a scalar) reads them from the table.

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. History of known-anomalous change patterns, and four proposed
-- account events awaiting commit.
-- ------------------------------------------------------------------
.print
.print === 1. Known-anomalous patterns + proposed account events ===

DROP TABLE IF EXISTS taa_known_anomalous;
DROP SEQUENCE IF EXISTS seq_taa_known_anomalous_id;
CREATE SEQUENCE seq_taa_known_anomalous_id;
CREATE TABLE taa_known_anomalous (
    id      INTEGER PRIMARY KEY DEFAULT nextval('seq_taa_known_anomalous_id'),
    pattern text,
    event   float8[5]
);
INSERT INTO taa_known_anomalous (pattern, event) VALUES
    ('SIM swap + port-out + new device',      [0.95, 0.90, 0.85, 0.10, 0.20]),
    ('SIM swap from a distant location',      [0.90, 0.05, 0.30, 0.95, 0.40]),
    ('rapid plan changes off-hours',          [0.05, 0.05, 0.10, 0.10, 0.95]),
    ('new device + location jump + port-out', [0.10, 0.80, 0.90, 0.85, 0.30]);

DROP TABLE IF EXISTS taa_proposed;
DROP SEQUENCE IF EXISTS seq_taa_proposed_id;
CREATE SEQUENCE seq_taa_proposed_id;
CREATE TABLE taa_proposed (
    id    INTEGER PRIMARY KEY DEFAULT nextval('seq_taa_proposed_id'),
    label text,
    event float8[5]
);
INSERT INTO taa_proposed (label, event) VALUES
    ('E1 swap + port-out + new handset', [0.92, 0.88, 0.80, 0.12, 0.18]),
    ('E2 routine plan upgrade',          [0.02, 0.00, 0.05, 0.00, 0.05]),
    ('E3 new handset, same city',        [0.00, 0.02, 0.70, 0.04, 0.05]),
    ('E4 faint SIM swap, far away',      [0.40, 0.02, 0.12, 0.42, 0.16]);

SELECT count(*) AS known_patterns FROM taa_known_anomalous;

-- ------------------------------------------------------------------
-- 2. Hand-composed screen: nearest known-anomalous pattern per event,
-- threshold 0.10 (cosine).
-- ------------------------------------------------------------------
.print
.print === 2. Hand-composed screen (cosine, threshold 0.10) ===

WITH hits AS (
    SELECT 1 AS pid, doc_id, distance FROM fractal_search_telemetry('taa_known_anomalous', 'event', [0.92, 0.88, 0.80, 0.12, 0.18]::float8[], 1)
    UNION ALL
    SELECT 2, doc_id, distance FROM fractal_search_telemetry('taa_known_anomalous', 'event', [0.02, 0.00, 0.05, 0.00, 0.05]::float8[], 1)
    UNION ALL
    SELECT 3, doc_id, distance FROM fractal_search_telemetry('taa_known_anomalous', 'event', [0.00, 0.02, 0.70, 0.04, 0.05]::float8[], 1)
    UNION ALL
    SELECT 4, doc_id, distance FROM fractal_search_telemetry('taa_known_anomalous', 'event', [0.40, 0.02, 0.12, 0.42, 0.16]::float8[], 1))
SELECT p.label, k.pattern AS nearest_pattern,
       round(h.distance, 4) AS distance,
       (h.distance < 0.10) AS intercepted
FROM hits h
JOIN taa_proposed p ON p.id = h.pid
JOIN taa_known_anomalous k ON k.rowid::VARCHAR = h.doc_id::VARCHAR
ORDER BY p.id;

-- ------------------------------------------------------------------
-- 3. The shipped agent (reasoning plugin for the `reason` field).
-- ------------------------------------------------------------------
.print
.print === 3. fractal_agent_outlier_intercept (cosine) ===

SELECT p.label,
       json_extract(o, '$.intercepted')   AS intercepted,
       json_extract_string(o, '$.metric') AS metric,
       json_extract_string(o, '$.reason') AS reason
FROM (SELECT id, label, fractal_agent_outlier_intercept(
               event, 'taa_known_anomalous', 'event', 0.10) AS o FROM taa_proposed) p
ORDER BY p.id;

-- ------------------------------------------------------------------
-- 4. When intensity should count: exact Euclidean distance.  E4 is a
-- faint SIM swap with a location jump -- the same shape as a known
-- pattern but at under half the intensity -- so cosine flags it while
-- l2 lets it through to a lower-severity review queue.
-- ------------------------------------------------------------------
.print
.print === 4. Same screen under exact Euclidean distance (threshold 0.30) ===

SELECT p.label, json_extract(o, '$.intercepted') AS intercepted_l2
FROM (SELECT id, label, fractal_agent_outlier_intercept(
               event, 'taa_known_anomalous', 'event', 0.30, 'l2') AS o FROM taa_proposed) p
ORDER BY p.id;

-- ------------------------------------------------------------------
-- 5. Reasoning: the justification an analyst sees next to the held
-- event (needs the reasoning plugin).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: justification for holding E1 ===

SELECT fractal_reason(
    'one-line justification for holding this account change for review',
    json_object(
      'event', (SELECT label FROM taa_proposed WHERE id = 1),
      'screen', (SELECT json_group_array(json_object('doc_id', doc_id, 'distance', distance))
                   FROM fractal_search_telemetry(
                   'taa_known_anomalous', 'event', [0.92, 0.88, 0.80, 0.12, 0.18]::float8[], 2)))::VARCHAR) AS justification;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE taa_known_anomalous, taa_proposed;
