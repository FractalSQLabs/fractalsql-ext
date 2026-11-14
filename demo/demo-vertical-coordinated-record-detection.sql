-- demo/demo-vertical-coordinated-record-detection.sql
--
-- Industry vertical: Coordinated-record detection: ring signatures and
-- severity-trajectory analysis. DOMAIN kit: A review desk screens new
-- submissions against known ring signatures with
-- `fractal_agent_outlier_intercept`, finds the records that moved from the
-- normal severity baseline the way a staged ring does with
-- `fractal_search_trajectory`, and measures the geographic footprint of
-- event locations with `fractal_dimension_boxcount` (organic events scatter
-- across the city; a staged ring repeats along one road).
--
--   1. fractal_agent_outlier_intercept: hold new records that match a known
--      ring signature.
--   2. fractal_search_trajectory: which open records moved the way the
--      ring's records did.
--   3. fractal_dimension_boxcount: the footprint of event locations,
--      organic vs ring.
--   4. A closing fractal_reason() writes the referral line.
--
-- Prerequisites: LOAD 'fractalsql.duckdb_extension'; (the agents ship
-- inside the extension). The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.<platform>.duckdb_extension';"; cat demo/demo-vertical-coordinated-record-detection.sql; } \
--       | duckdb -unsigned
--
-- Safe to re-run: crd_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Ring signature = [record velocity, shared provider, shared
--     representative, soft-tissue ratio, address clustering].
--   * Severity vector = [severity jump, treatment gap, bill inflation,
--     representative speed]; the three ring records (ids 5, 13, 22) share
--     one vector.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=coordinated-record-detection ok);
--     the build_test kit gate greps for it.

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

.print
.print === 1. Known ring signatures + proposed new records ===
DROP TABLE IF EXISTS crd_known;
CREATE TABLE crd_known (
    id INTEGER PRIMARY KEY,
    label text,
    vec float8[5]
);
INSERT INTO crd_known (id, label, vec) VALUES
    (1, 'staged-event ring: same provider and representative', [0.95, 0.9, 0.85, 0.1, 0.2]),
    (2, 'synthetic-severity ring: repeated minor-severity pile-up', [0.9, 0.05, 0.3, 0.95, 0.4]),
    (3, 'phantom-participant records, one address cluster', [0.05, 0.05, 0.1, 0.1, 0.95]),
    (4, 'provider-collusion ring: repeat billing', [0.1, 0.8, 0.9, 0.85, 0.3]);
DROP TABLE IF EXISTS crd_proposed;
CREATE TABLE crd_proposed (
    id INTEGER PRIMARY KEY,
    label text,
    vec float8[5]
);
INSERT INTO crd_proposed (id, label, vec) VALUES
    (1, 'P1 staged-pattern record, usual provider and representative', [0.92, 0.88, 0.8, 0.12, 0.18]),
    (2, 'P2 isolated single-party record', [0.02, 0, 0.05, 0, 0.05]),
    (3, 'P3 new provider, same city', [0, 0.02, 0.7, 0.04, 0.05]),
    (4, 'P4 faint minor-severity pattern, far away', [0.4, 0.02, 0.12, 0.42, 0.16]);

.print
.print === 2. fractal_agent_outlier_intercept (cosine, threshold 0.10) ===
DROP TABLE IF EXISTS crd_screen;
CREATE TABLE crd_screen AS
SELECT id, label, (json_extract_string(o, '$.intercepted') = 'true')::INTEGER AS intercepted, 'cosine' AS metric
FROM (SELECT id, label, fractal_agent_outlier_intercept(vec, 'crd_known', 'vec', 0.1) AS o
        FROM crd_proposed)
ORDER BY id;

SELECT id, label, intercepted, metric FROM crd_screen ORDER BY id;

.print
.print === 3. Open-record severity trajectory: who moved like the ring ===
DROP TABLE IF EXISTS crd_records;
CREATE TABLE crd_records (
    id INTEGER PRIMARY KEY,
    label text,
    vec float8[4]
);
INSERT INTO crd_records (id, label, vec) VALUES
    (1, 'REC-001', [0.05, -0.06, 0.03, -0.04]),
    (2, 'REC-002', [0.1, -0.02, 0.06, 0.02]),
    (3, 'REC-003', [0.15, 0.02, 0.09, 0.08]),
    (4, 'REC-004', [0.2, 0.06, 0, 0.14]),
    (5, 'REC-005 (ring)', [1.4, 0.9, 1.1, 1.2]),
    (6, 'REC-006', [0.05, 0.14, 0.06, -0.1]),
    (7, 'REC-007', [0.1, -0.1, 0.09, -0.04]),
    (8, 'REC-008', [0.15, -0.06, 0, 0.02]),
    (9, 'REC-009', [0.2, -0.02, 0.03, 0.08]),
    (10, 'REC-010', [0, 0.02, 0.06, 0.14]),
    (11, 'REC-011', [0.05, 0.06, 0.09, 0.2]),
    (12, 'REC-012', [0.1, 0.1, 0, -0.1]),
    (13, 'REC-013 (ring)', [1.4, 0.9, 1.1, 1.2]),
    (14, 'REC-014', [0.2, -0.1, 0.06, 0.02]),
    (15, 'REC-015', [0, -0.06, 0.09, 0.08]),
    (16, 'REC-016', [0.05, -0.02, 0, 0.14]),
    (17, 'REC-017', [0.1, 0.02, 0.03, 0.2]),
    (18, 'REC-018', [0.15, 0.06, 0.06, -0.1]),
    (19, 'REC-019', [0.2, 0.1, 0.09, -0.04]),
    (20, 'REC-020', [0, 0.14, 0, 0.02]),
    (21, 'REC-021', [0.05, -0.1, 0.03, 0.08]),
    (22, 'REC-022 (ring)', [1.4, 0.9, 1.1, 1.2]),
    (23, 'REC-023', [0.15, -0.02, 0.09, 0.2]),
    (24, 'REC-024', [0.2, 0.02, 0, -0.1]),
    (25, 'REC-025', [0, 0.06, 0.03, -0.04]),
    (26, 'REC-026', [0.05, 0.1, 0.06, 0.02]),
    (27, 'REC-027', [0.1, 0.14, 0.09, 0.08]),
    (28, 'REC-028', [0.15, -0.1, 0, 0.14]),
    (29, 'REC-029', [0.2, -0.06, 0.03, 0.2]),
    (30, 'REC-030', [0, -0.02, 0.06, -0.1]);
DROP TABLE IF EXISTS crd_traj;
CREATE TABLE crd_traj AS
SELECT row_number() OVER (ORDER BY tr.distance, p.id) AS rk, p.id, p.label AS label,
       round(tr.distance, 4) AS distance
FROM fractal_search_trajectory(
         'crd_records', 'vec',
         [0.05, 0, 0.03, 0]::float8[],    -- baseline
         [1.4, 0.9, 1.1, 1.2]::float8[],    -- current
         5) tr
JOIN crd_records p ON p.rowid::VARCHAR = tr.doc_id::VARCHAR;

SELECT rk, id, label, distance FROM crd_traj ORDER BY rk;

.print
.print === 4. Event-location topology: organic vs staged ring ===
DROP TABLE IF EXISTS crd_locations;
CREATE TABLE crd_locations (
    ent text,
    pt  int,
    x   float8,
    y   float8
);
INSERT INTO crd_locations (ent, pt, x, y)
SELECT ent, g, ((g * 37) % 100) / 100.0, CASE WHEN p1 = 1 THEN ((g * 61) % 100) / 100.0 ELSE ((g * 37) % 100) / 200.0 + 0.002 * (g % 5) END
FROM (VALUES ('organic-records', 1),
             ('staged-ring', 0)) AS s(ent, p1),
     generate_series(1, 200) AS gs(g);
DROP TABLE IF EXISTS crd_dim;
CREATE TABLE crd_dim AS
SELECT ent, round(fractal_dimension_boxcount(flatten(list([x, y] ORDER BY pt)), 2), 3) AS dim
FROM crd_locations GROUP BY ent ORDER BY ent;

SELECT ent, dim FROM crd_dim ORDER BY ent;

.print
.print === 5. Reasoning: referral ===
SELECT fractal_reason(
    'one-line referral for the suspected staged-event ring',
    json_object('held_record', (SELECT label FROM crd_screen WHERE id = 1), 'ring_records_found', (SELECT count(*) FROM crd_traj WHERE distance < 0.001), 'ring_dimension', (SELECT dim FROM crd_dim WHERE ent = 'staged-ring'))::VARCHAR) AS narrative;

-- The demo's own claims, recomputed from the demo's own tables: the
-- screen holds the staged-pattern record (P1) and the faint
-- minor-severity record (P4) and leaves the isolated single-party
-- record (P2) and the new-provider record (P3) alone; the severity
-- trajectory surfaces exactly the three ring records (ids 5, 13 and
-- 22) as the records that moved the way the ring's did; and the
-- staged ring's event locations cover a smaller area than the organic
-- records' -- one repeated stretch of road against a scattered city.
.print
.print === 6. Headline check ===
.mode list
.headers off
SELECT 'HEADLINE kit=coordinated-record-detection ' || CASE WHEN
    (SELECT intercepted FROM crd_screen WHERE id = 1) = 1
    AND (SELECT intercepted FROM crd_screen WHERE id = 2) = 0
    AND (SELECT intercepted FROM crd_screen WHERE id = 3) = 0
    AND (SELECT intercepted FROM crd_screen WHERE id = 4) = 1
    AND (SELECT count(*) FROM crd_screen) = 4
    AND (SELECT count(*) FROM crd_traj WHERE distance < 0.001) = 3
    AND (SELECT string_agg(id::VARCHAR, ',' ORDER BY id)
           FROM crd_traj WHERE distance < 0.001) = '5,13,22'
    AND (SELECT count(*) FROM crd_dim) = 2
    AND (SELECT dim FROM crd_dim WHERE ent = 'staged-ring') + 0.3
        < (SELECT dim FROM crd_dim WHERE ent = 'organic-records')
  THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE crd_known;
.print   DROP TABLE crd_proposed;
.print   DROP TABLE crd_screen;
.print   DROP TABLE crd_records;
.print   DROP TABLE crd_traj;
.print   DROP TABLE crd_locations;
.print   DROP TABLE crd_dim;
.print (one DROP per statement -- DuckDB's DROP TABLE takes exactly one table.)
