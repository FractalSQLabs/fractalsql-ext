-- demo/demo-vertical-event-stream-anomaly-triage.sql
--
-- Industry vertical: High-frequency event-stream latency and rate anomaly
-- triage. DOMAIN kit: Four endpoints x 96 one-minute intervals of request
-- latency; one endpoint (EP-C) develops an accelerating latency ramp (a
-- timeout cascade) and a second (EP-B) has a retry-storm oscillation in its
-- request rate. `fractal_agent_anomaly_triage` flags the latency regime
-- shift, `fractal_periodogram` finds the retry-storm period, and
-- `fractal_search_trajectory` finds which endpoints' success-rate / latency
-- / timeout / fill health has moved the same way EP-C's did.
--
--   1. fractal_dimension_drift / fractal_agent_anomaly_triage: which
--      endpoint's latency changed regime.
--   2. fractal_periodogram: the dominant period of each endpoint's request
--      rate (a retry loop shows as a sharp line).
--   3. fractal_search_trajectory: endpoints whose health moved like the
--      degraded one (baseline -> current).
--   4. A closing fractal_reason() writes the triage line.
--
-- Prerequisites: LOAD 'fractalsql.duckdb_extension'; (the agents ship
-- inside the extension). The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.<platform>.duckdb_extension';"; cat demo/demo-vertical-event-stream-anomaly-triage.sql; } \
--       | duckdb -unsigned
--
-- Safe to re-run: esa_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Latency is a steady base with a small cycle; EP-C ramps quadratically
--     from interval 65.
--   * Request rate: EP-B carries a 12-interval oscillation; the others are
--     flat with a faint 7-interval ripple.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=event-stream-anomaly-triage ok);
--     the build_test kit gate greps for it.

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

.print
.print === 1. Event-stream telemetry: 4 endpoints x 96 intervals ===
DROP TABLE IF EXISTS esa_latency;
CREATE TABLE esa_latency (
    ent text,
    seq int,
    val float8
);
INSERT INTO esa_latency (ent, seq, val)
SELECT ent, g, base * (1.0 + 0.004 * (g % 8)) + CASE WHEN p2 > 0 AND g > 64 THEN base * p2 * (g - 64) * (g - 64) ELSE 0 END
FROM (VALUES ('EP-A', 42, 0),
             ('EP-B', 55, 0),
             ('EP-C', 48, 0.0024),
             ('EP-D', 61, 0)) AS s(ent, base, p2),
     generate_series(1, 96) AS gs(g);
DROP TABLE IF EXISTS esa_rate;
CREATE TABLE esa_rate (
    ent text,
    seq int,
    val float8
);
INSERT INTO esa_rate (ent, seq, val)
SELECT ent, g, base * (1.0 + 0.02 * sin(2 * pi() * g / 7.0) + p1 * sin(2 * pi() * g / 12.0))
FROM (VALUES ('EP-A', 900, 0, 0),
             ('EP-B', 800, 0.3, 0),
             ('EP-C', 950, 0, 0),
             ('EP-D', 700, 0, 0)) AS s(ent, base, p1, p2),
     generate_series(1, 96) AS gs(g);
SELECT ent, count(*) AS intervals FROM esa_latency GROUP BY ent ORDER BY ent;

.print
.print === 2. Hand-composed: latency regime drift per endpoint ===
DROP TABLE IF EXISTS esa_lprof;
CREATE TABLE esa_lprof AS
SELECT row_number() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, round(m.mean_v, 4) AS mean_v, round(m.var_v, 4) AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha, a.dj.drift AS drift, a.dj.recent_alpha AS recent_alpha, a.dj.baseline_alpha AS baseline_alpha
FROM (SELECT ent, arr, fractal_dimension_drift(arr, 32) AS dj FROM (SELECT ent, list(round(val, 5) ORDER BY seq) AS arr FROM esa_latency GROUP BY ent)) a
JOIN (SELECT ent, avg(val) AS mean_v, avg(val * val) - avg(val) * avg(val) AS var_v
        FROM esa_latency GROUP BY ent) m ON m.ent = a.ent
ORDER BY a.ent;
SELECT ent, mean_v, var_v, round(dfa_alpha, 3) AS dfa_alpha, round(drift, 4) AS drift, round(recent_alpha, 4) AS recent_alpha, round(baseline_alpha, 4) AS baseline_alpha
  FROM esa_lprof ORDER BY ent;

.print
.print === 3. fractal_agent_anomaly_triage: degraded vs healthy endpoint ===
SELECT 'EP-C (degraded)' AS entity,
       json_extract(j, '$.threat_score')          AS threat_score,
       json_extract_string(j, '$.anomaly_type')   AS anomaly_type,
       json_extract_string(j, '$.triage_summary') AS triage_summary
FROM (SELECT fractal_agent_anomaly_triage('esa_latency', 'val', 'seq', 'ent', 'EP-C', 32) AS j)
UNION ALL
SELECT 'EP-A (healthy)' AS entity,
       json_extract(j, '$.threat_score')          AS threat_score,
       json_extract_string(j, '$.anomaly_type')   AS anomaly_type,
       json_extract_string(j, '$.triage_summary') AS triage_summary
FROM (SELECT fractal_agent_anomaly_triage('esa_latency', 'val', 'seq', 'ent', 'EP-A', 32) AS j);

.print
.print === 4. Retry-storm period: fractal_periodogram on the request rate ===
DROP TABLE IF EXISTS esa_rprof_freq;
CREATE TABLE esa_rprof_freq AS
SELECT 'EP-A' AS ent, freq FROM fractal_periodogram(
    [900 * (1.0 + 0.02 * sin(2 * pi() * t / 7.0) + 0 * sin(2 * pi() * t / 12.0)) for t in range(1, 97)], 1)
UNION ALL
SELECT 'EP-B' AS ent, freq FROM fractal_periodogram(
    [800 * (1.0 + 0.02 * sin(2 * pi() * t / 7.0) + 0.3 * sin(2 * pi() * t / 12.0)) for t in range(1, 97)], 1)
UNION ALL
SELECT 'EP-C' AS ent, freq FROM fractal_periodogram(
    [950 * (1.0 + 0.02 * sin(2 * pi() * t / 7.0) + 0 * sin(2 * pi() * t / 12.0)) for t in range(1, 97)], 1)
UNION ALL
SELECT 'EP-D' AS ent, freq FROM fractal_periodogram(
    [700 * (1.0 + 0.02 * sin(2 * pi() * t / 7.0) + 0 * sin(2 * pi() * t / 12.0)) for t in range(1, 97)], 1);

DROP TABLE IF EXISTS esa_rprof;
CREATE TABLE esa_rprof AS
SELECT row_number() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, round(m.mean_v, 4) AS mean_v, round(m.var_v, 4) AS var_v, pg.freq AS freq
FROM (SELECT ent, arr FROM (SELECT ent, list(round(val, 5) ORDER BY seq) AS arr FROM esa_rate GROUP BY ent)) a
JOIN (SELECT ent, avg(val) AS mean_v, avg(val * val) - avg(val) * avg(val) AS var_v
        FROM esa_rate GROUP BY ent) m ON m.ent = a.ent
JOIN esa_rprof_freq pg ON pg.ent = a.ent
ORDER BY a.ent;
SELECT ent, mean_v, var_v, round(freq, 4) AS top_freq, round(1.0 / freq, 1) AS samples_per_cycle
  FROM esa_rprof ORDER BY ent;

.print
.print === 5. Endpoint health trajectory: who moved like EP-C ===
DROP TABLE IF EXISTS esa_health;
CREATE TABLE esa_health (
    id INTEGER PRIMARY KEY,
    label text,
    vec float8[4]
);
INSERT INTO esa_health (id, label, vec) VALUES
    (1, 'EP-01', [0.05, -0.06, 0.03, -0.04]),
    (2, 'EP-02', [0.1, -0.02, 0.06, 0.02]),
    (3, 'EP-03 (degraded)', [1.4, 0.9, 1.1, 1.2]),
    (4, 'EP-04', [0.2, 0.06, 0, 0.14]),
    (5, 'EP-05', [0, 0.1, 0.03, 0.2]),
    (6, 'EP-06', [0.05, 0.14, 0.06, -0.1]),
    (7, 'EP-07 (degraded)', [1.4, 0.9, 1.1, 1.2]),
    (8, 'EP-08', [0.15, -0.06, 0, 0.02]),
    (9, 'EP-09', [0.2, -0.02, 0.03, 0.08]),
    (10, 'EP-10', [0, 0.02, 0.06, 0.14]),
    (11, 'EP-11 (degraded)', [1.4, 0.9, 1.1, 1.2]),
    (12, 'EP-12', [0.1, 0.1, 0, -0.1]),
    (13, 'EP-13', [0.15, 0.14, 0.03, -0.04]),
    (14, 'EP-14', [0.2, -0.1, 0.06, 0.02]),
    (15, 'EP-15', [0, -0.06, 0.09, 0.08]),
    (16, 'EP-16', [0.05, -0.02, 0, 0.14]);
DROP TABLE IF EXISTS esa_traj;
CREATE TABLE esa_traj AS
SELECT row_number() OVER (ORDER BY tr.distance, p.id) AS rk, p.id, p.label AS label,
       round(tr.distance, 4) AS distance
FROM fractal_search_trajectory(
         'esa_health', 'vec',
         [0.05, 0, 0.03, 0]::float8[],    -- baseline
         [1.4, 0.9, 1.1, 1.2]::float8[],    -- current
         5) tr
JOIN esa_health p ON p.rowid::VARCHAR = tr.doc_id::VARCHAR;

SELECT rk, id, label, distance FROM esa_traj ORDER BY rk;

.print
.print === 6. Reasoning: triage line ===
-- The retry-storm endpoint is the one whose dominant request-rate
-- cycle is the LONGEST: a retry loop repeats every 12 intervals, so
-- its periodogram's dominant frequency is the lowest of the four.
SELECT fractal_reason(
    'one-line event-stream triage: which endpoint is degrading, since when, and the likely cause',
    json_object('worst_endpoint', (SELECT ent FROM esa_lprof ORDER BY drift DESC LIMIT 1), 'retry_storm_endpoint', (SELECT ent FROM esa_rprof ORDER BY freq ASC LIMIT 1), 'nearest_degraded_health', (SELECT label FROM esa_traj WHERE rk = 1))::VARCHAR) AS narrative;

-- The demo's own claims, recomputed from the demo's own tables: EP-C
-- is the one endpoint whose latency changed regime (EP-A and the
-- others stay flat), EP-B is the one whose request rate repeats on a
-- 12-interval cycle (the retry storm -- the longest cycle of the
-- four, and so the lowest dominant frequency), and the health
-- trajectory surfaces exactly the three endpoints that moved the way
-- EP-C's did.
.print
.print === 7. Headline check ===
.mode list
.headers off
SELECT 'HEADLINE kit=event-stream-anomaly-triage ' || CASE WHEN
    (SELECT count(*) FROM esa_latency) = 384
    AND (SELECT count(*) FROM esa_rate) = 384
    AND (SELECT count(*) FROM esa_lprof) = 4
    AND (SELECT drift FROM esa_lprof WHERE ent = 'EP-C') > 0.5
    AND (SELECT drift FROM esa_lprof WHERE ent = 'EP-A') < 0
    AND (SELECT ent FROM esa_lprof ORDER BY drift DESC LIMIT 1) = 'EP-C'
    AND (SELECT freq FROM esa_rprof WHERE ent = 'EP-B') > 0.07
    AND (SELECT freq FROM esa_rprof WHERE ent = 'EP-B') < 0.10
    AND abs(1.0 / (SELECT freq FROM esa_rprof WHERE ent = 'EP-B') - 12.0) < 0.05
    AND (SELECT ent FROM esa_rprof ORDER BY freq ASC LIMIT 1) = 'EP-B'
    AND (SELECT count(*) FROM esa_traj WHERE distance < 0.001) = 3
    AND (SELECT string_agg(id::VARCHAR, ',' ORDER BY id)
           FROM esa_traj WHERE distance < 0.001) = '3,7,11'
  THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE esa_latency;
.print   DROP TABLE esa_rate;
.print   DROP TABLE esa_lprof;
.print   DROP TABLE esa_rprof;
.print   DROP TABLE esa_rprof_freq;
.print   DROP TABLE esa_health;
.print   DROP TABLE esa_traj;
.print (one DROP per statement -- DuckDB's DROP TABLE takes exactly one table.)
