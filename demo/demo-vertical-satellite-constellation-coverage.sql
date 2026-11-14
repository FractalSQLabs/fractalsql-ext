-- demo/demo-vertical-satellite-constellation-coverage.sql
--
-- Industry vertical: space and satellite communications -- constellation
-- coverage monitoring.  DOMAIN kit built on two installed agents:
--
--   * fractal_agent_network_coverage_alert -- spatial morphology of the
--     constellation's footprint grid (box-counting dimension + lacunarity)
--     plus drift of a link-quality telemetry series, flagging coverage
--     gaps and dead zones.  This is the COVERAGE-GAP angle only; orbital
--     drift and collision detection are a different problem and are not
--     covered here.
--   * fractal_agent_schedule_workload -- a secondary branch that models
--     launch-manifest / payload-slot scheduling as a resource-allocation
--     problem (vector-refine + nearest-slot match).
--
-- Prerequisites: extension installed.  Section 2 and the hand-composed
-- nearest-slot match need no model; the shipped agents and the closing
-- narrative are reasoning-bearing (docs/reasoning-setup.md).
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; cat demo/demo-vertical-satellite-constellation-coverage.sql; } \
--       | duckdb -unsigned
--
-- Safe to re-run: scc_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture: jitter and noise come from integer
--     arithmetic and an LCG in recursive CTEs, not random().
--   * The footprint grid is a 20 x 20 lattice of footprint centers (400
--     points, flat interleaved x,y).  The morphology estimator needs a
--     few hundred points for a stable answer, which is why the grid is
--     this size.  The degraded constellation loses an 8 x 8 block of
--     footprints (a dead zone), which raises lacunarity (gappiness).
--   * The link-quality series is 96 samples with a regime change at 49:
--     a stable carrier followed by a fast oscillation as a relay degrades.
--   * fractal_search_telemetry returns the row's rowid as doc_id and takes
--     a literal query vector; the agents are scalars returning one JSON
--     document each.

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Footprint grids: a healthy 20 x 20 lattice and a degraded copy
-- missing an 8 x 8 block (rows 6-13, columns 6-13).
-- ------------------------------------------------------------------
.print
.print === 1. Footprint lattices: healthy (400) vs degraded (336) ===

DROP TABLE IF EXISTS scc_footprints;
CREATE TABLE scc_footprints (
    r int, c int, x float8, y float8
);
INSERT INTO scc_footprints (r, c, x, y)
SELECT r, c, c + 0.06 * (((r * 7 + c * 13) % 10) - 5) / 5.0,
             r + 0.06 * (((r * 11 + c * 3) % 10) - 5) / 5.0
FROM generate_series(0, 19) AS rr(r), generate_series(0, 19) AS cc(c)
ORDER BY r, c;

SELECT count(*) AS healthy_footprints,
       count(*) FILTER (WHERE NOT (r BETWEEN 6 AND 13 AND c BETWEEN 6 AND 13)) AS degraded_footprints
  FROM scc_footprints;

-- ------------------------------------------------------------------
-- 2. Hand-composed: morphology of each lattice.  The dead zone shows up
-- as higher lacunarity in the degraded constellation.
-- ------------------------------------------------------------------
.print
.print === 2. Morphology: healthy vs degraded constellation ===

SELECT 'healthy' AS constellation,
       round(m.dimension, 3)  AS dimension,
       round(m.lacunarity, 3) AS lacunarity
FROM (SELECT fractal_morphological_complexity(
        (SELECT list(v ORDER BY r, c, ord)
           FROM scc_footprints f, LATERAL unnest([round(f.x, 4), round(f.y, 4)]) WITH ORDINALITY AS u(v, ord)),
        2) AS m) h
UNION ALL
SELECT 'degraded',
       round(m.dimension, 3),
       round(m.lacunarity, 3)
FROM (SELECT fractal_morphological_complexity(
        (SELECT list(v ORDER BY r, c, ord)
           FROM scc_footprints f, LATERAL unnest([round(f.x, 4), round(f.y, 4)]) WITH ORDINALITY AS u(v, ord)
          WHERE NOT (f.r BETWEEN 6 AND 13 AND f.c BETWEEN 6 AND 13)),
        2) AS m) d;

-- ------------------------------------------------------------------
-- 3. The shipped agent on the degraded constellation: morphology plus
-- link-quality drift plus a reasoned coverage alert (reasoning plugin).
-- ------------------------------------------------------------------
.print
.print === 3. fractal_agent_network_coverage_alert (degraded constellation) ===

WITH RECURSIVE n(t, x) AS (
       SELECT 1, 4242::bigint UNION ALL
       SELECT t + 1, (x * 1103515245 + 12345) % 2147483648 FROM n WHERE t < 96),
     s AS (SELECT t,
                  CASE WHEN t < 49
                       THEN 4.0 + 1.5 * sin(t * 0.31) + ((((x // 65536) % 1000) - 500) / 1250.0)
                       ELSE 4.0 + 3.0 * sin(t * 1.4)  + ((((x // 65536) % 1000) - 500) / 2500.0)
                  END AS v FROM n),
     r AS (SELECT fractal_agent_network_coverage_alert(
              (SELECT list(v ORDER BY r, c, ord)
                 FROM scc_footprints f, LATERAL unnest([round(f.x, 4), round(f.y, 4)]) WITH ORDINALITY AS u(v, ord)
                WHERE NOT (f.r BETWEEN 6 AND 13 AND f.c BETWEEN 6 AND 13)),
              (SELECT list(round(v, 4) ORDER BY t) FROM s),
              2, 48, 0.5) AS j)
SELECT round(json_extract(j, '$.morph_dimension')::double, 3) AS morph_dimension,
       round(json_extract(j, '$.lacunarity')::double, 3)      AS lacunarity,
       json_extract(j, '$.drift_detected')                    AS drift_detected,
       json_extract_string(j, '$.rationale')                  AS rationale
FROM r;

-- ------------------------------------------------------------------
-- 4. Secondary branch: launch-manifest scheduling.  Each launch slot
-- has a capability vector [mass_margin, plane_A, plane_B, plane_C,
-- rideshare]; a replacement-satellite payload is placed on the nearest
-- slot.  Vector-refine + nearest-node match, one call.
-- ------------------------------------------------------------------
.print
.print === 4. Launch-slot scheduling: fractal_agent_schedule_workload ===

DROP TABLE IF EXISTS scc_slots;
CREATE TABLE scc_slots (id int PRIMARY KEY, capability float8[5]);
INSERT INTO scc_slots VALUES
    (1, [0.9, 0.8, 0.0, 0.0, 0.1]),    -- heavy lift, plane A
    (2, [0.5, 0.0, 0.9, 0.1, 0.4]),    -- medium lift, plane B
    (3, [0.3, 0.0, 0.1, 0.9, 0.9]),    -- rideshare, plane C
    (4, [0.6, 0.1, 0.8, 0.1, 0.2]);    -- medium lift, plane B

.print --- hand-composed: nearest slot to the replacement payload ---
SELECT s.id AS assigned_slot, round(1.0 / (1.0 + t.distance), 4) AS confidence
FROM fractal_search_telemetry('scc_slots', 'capability', [0.5, 0.0, 0.85, 0.1, 0.35]::float8[], 1) t
JOIN scc_slots s ON s.rowid::VARCHAR = t.doc_id::VARCHAR;

.print --- the shipped agent: same composition plus refinement, one call (reasoning plugin) ---
SELECT json_extract_string(j, '$.assigned_node')           AS assigned_slot,
       round(json_extract(j, '$.confidence')::double, 4)   AS confidence,
       json_extract_string(j, '$.rationale')               AS rationale
FROM (SELECT fractal_agent_schedule_workload(
    [0.5, 0.0, 0.85, 0.1, 0.35]::float8[], 'scc_slots', 'capability', 'id', 30, 50) AS j);

-- ------------------------------------------------------------------
-- 5. Reasoning: the combined narrative (needs the reasoning plugin).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: coverage gap and replacement-launch narrative ===

SELECT fractal_reason(
    'one-line summary of this constellation coverage gap and the launch slot chosen to fill it',
    json_object(
      'nearest_slot', (SELECT json_group_array(json_object('doc_id', doc_id, 'distance', distance))
                         FROM fractal_search_telemetry(
            'scc_slots', 'capability', [0.5, 0.0, 0.85, 0.1, 0.35]::float8[], 1)))::VARCHAR) AS narrative;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE scc_footprints, scc_slots;
