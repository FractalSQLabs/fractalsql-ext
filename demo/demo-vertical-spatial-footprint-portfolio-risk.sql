-- demo/demo-vertical-spatial-footprint-portfolio-risk.sql
--
-- Industry vertical: Spatial footprint analysis: box-counting dimension and
-- portfolio risk optimization. DOMAIN kit: Three districts' parcel
-- footprints (a dense grid, a single arterial strip and a two-corridor
-- district) measured with `fractal_dimension_boxcount`: the lower the
-- dimension the more linear the frontage and the more a valuation depends
-- on a few corridors. Six asset classes x 64 months of index values feed
-- `fractal_dimension_dfa` and `fractal_optimize_portfolio` (pick 3 classes
-- for the renewal push; the accelerating one is flagged), and Scout
-- (`fractal_search_explore`) selects six deliberately different comparable
-- parcels so the reviewer sees the spread of the market, not six
-- near-twins.
--
--   1. fractal_dimension_boxcount: the spatial footprint of each district's
--      parcels.
--   2. fractal_dimension_dfa + fractal_optimize_portfolio: 3-of-6 asset
--      classes, risk = variance x DFA exponent.
--   3. fractal_search_explore (Scout): six diverse comparable parcels
--      around the subject property.
--   4. A closing fractal_reason() writes the reviewer's note.
--
-- Prerequisites: LOAD 'fractalsql.duckdb_extension'; (the agents ship
-- inside the extension). The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.<platform>.duckdb_extension';"; cat demo/demo-vertical-spatial-footprint-portfolio-risk.sql; } \
--       | duckdb -unsigned
--
-- Safe to re-run: sfp_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Parcel vector = [foot traffic, zoning intensity, transit access, macro
--     sensitivity].
--   * The index series for class 'class-d' accelerates from month 41.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=spatial-footprint-portfolio-risk ok);
--     the build_test kit gate greps for it.

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

.print
.print === 1. Parcel footprints: three districts ===
DROP TABLE IF EXISTS sfp_parcels;
CREATE TABLE sfp_parcels (
    ent text,
    pt  int,
    x   float8,
    y   float8
);
INSERT INTO sfp_parcels (ent, pt, x, y)
SELECT ent, g, ((g * 37) % 100) / 100.0, CASE WHEN p1 = 0 THEN ((g * 61) % 100) / 100.0 WHEN p1 = 1 THEN ((g * 37) % 100) / 330.0 + 0.002 * (g % 5) ELSE CASE WHEN g % 2 = 0 THEN ((g * 37) % 100) / 400.0 ELSE 0.8 + ((g * 37) % 100) / 500.0 END END
FROM (VALUES ('dense-grid', 0),
             ('linear-strip', 1),
             ('dual-corridor', 2)) AS s(ent, p1),
     generate_series(1, 200) AS gs(g);
DROP TABLE IF EXISTS sfp_dim;
CREATE TABLE sfp_dim AS
SELECT ent, round(fractal_dimension_boxcount(flatten(list([x, y] ORDER BY pt)), 2), 3) AS dim
FROM sfp_parcels GROUP BY ent ORDER BY ent;

SELECT ent, dim FROM sfp_dim ORDER BY ent;

.print
.print === 2. Asset classes: 6 classes x 64 months of index value ===
DROP TABLE IF EXISTS sfp_index;
CREATE TABLE sfp_index (
    ent text,
    seq int,
    val float8
);
INSERT INTO sfp_index (ent, seq, val)
SELECT ent, g, base * (1.0 + 0.06 * ((g + p1) % 7) / 7.0) + CASE WHEN p2 > 0 AND g > 40 THEN p2 * (g - 40) * (g - 40) ELSE 0 END
FROM (VALUES ('class-a', 120, 1, 0),
             ('class-b', 95, 2, 0),
             ('class-c', 140, 3, 0),
             ('class-d', 110, 4, 0.45),
             ('class-e', 160, 5, 0),
             ('class-f', 85, 6, 0)) AS s(ent, base, p1, p2),
     generate_series(1, 64) AS gs(g);
DROP TABLE IF EXISTS sfp_prof;
CREATE TABLE sfp_prof AS
SELECT row_number() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, round(m.mean_v, 4) AS mean_v, round(m.var_v, 4) AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha
FROM (SELECT ent, arr FROM (SELECT ent, list(round(val, 5) ORDER BY seq) AS arr FROM sfp_index GROUP BY ent)) a
JOIN (SELECT ent, avg(val) AS mean_v, avg(val * val) - avg(val) * avg(val) AS var_v
        FROM sfp_index GROUP BY ent) m ON m.ent = a.ent
ORDER BY a.ent;
SELECT ent, mean_v, var_v, round(dfa_alpha, 3) AS dfa_alpha
  FROM sfp_prof ORDER BY ent;
DROP TABLE IF EXISTS sfp_result;
CREATE TABLE sfp_result AS
SELECT fractal_optimize_portfolio(
    (SELECT list(round(p.mean_v / 100.0, 4) ORDER BY p.pid) FROM sfp_prof p),
    (SELECT list(CASE WHEN a.pid = b.pid THEN round(a.var_v * a.dfa_alpha / 100.0, 4) ELSE 0::float8 END
                 ORDER BY a.pid, b.pid)
       FROM sfp_prof a CROSS JOIN sfp_prof b),
    3, 42) AS rj;

SELECT round(rj.sharpe, 4) AS sharpe FROM sfp_result;

.print --- the chosen entries (weight > 0; weights are in ent order) ---
SELECT p.ent, round(w.weight, 4) AS weight
FROM sfp_result r,
     LATERAL (SELECT unnest(r.rj.weights) AS weight, generate_subscripts(r.rj.weights, 1) AS ord) w
JOIN sfp_prof p ON p.pid = w.ord
WHERE w.weight > 0
ORDER BY w.weight DESC;
.print --- asset classes flagged for review (DFA exponent > 1.2) ---
SELECT ent, round(dfa_alpha, 3) AS dfa_alpha
  FROM sfp_prof WHERE dfa_alpha > 1.2 ORDER BY dfa_alpha DESC;

.print
.print === 3. Scout (diversity-first): six comparable parcels ===
DROP TABLE IF EXISTS sfp_comps;
CREATE TABLE sfp_comps (
    id INTEGER PRIMARY KEY,
    label text,
    zone text,
    c1 float8,
    c2 float8,
    c3 float8,
    c4 float8,
    vec float8[4]
);
INSERT INTO sfp_comps (id, label, zone, c1, c2, c3, c4, vec) VALUES
    (1, 'PARCEL-01 zone-arterial', 'zone-arterial', 0.2013, 0.8387, 0.3313, 0.3687, [0.2013, 0.8387, 0.3313, 0.3687]),
    (2, 'PARCEL-02 zone-outer', 'zone-outer', 0.3626, 0.2374, 0.8726, 0.5974, [0.3626, 0.2374, 0.8726, 0.5974]),
    (3, 'PARCEL-03 zone-campus', 'zone-campus', 0.5739, 0.6361, 0.2639, 0.2261, [0.5739, 0.6361, 0.2639, 0.2261]),
    (4, 'PARCEL-04 zone-core', 'zone-core', 0.9352, 0.1348, 0.2052, 0.8548, [0.9352, 0.1348, 0.2052, 0.8548]),
    (5, 'PARCEL-05 zone-arterial', 'zone-arterial', 0.1465, 0.8335, 0.2465, 0.3335, [0.1465, 0.8335, 0.2465, 0.3335]),
    (6, 'PARCEL-06 zone-outer', 'zone-outer', 0.3078, 0.2322, 0.9378, 0.5622, [0.3078, 0.2322, 0.9378, 0.5622]),
    (7, 'PARCEL-07 zone-campus', 'zone-campus', 0.6691, 0.6309, 0.1791, 0.1909, [0.6691, 0.6309, 0.1791, 0.1909]),
    (8, 'PARCEL-08 zone-core', 'zone-core', 0.8804, 0.1296, 0.2704, 0.8196, [0.8804, 0.1296, 0.2704, 0.8196]),
    (9, 'PARCEL-09 zone-arterial', 'zone-arterial', 0.2417, 0.8283, 0.3117, 0.4483, [0.2417, 0.8283, 0.3117, 0.4483]),
    (10, 'PARCEL-10 zone-outer', 'zone-outer', 0.253, 0.227, 0.853, 0.527, [0.253, 0.227, 0.853, 0.527]),
    (11, 'PARCEL-11 zone-campus', 'zone-campus', 0.6143, 0.6257, 0.2443, 0.1557, [0.6143, 0.6257, 0.2443, 0.1557]),
    (12, 'PARCEL-12 zone-core', 'zone-core', 0.9756, 0.1244, 0.1856, 0.7844, [0.9756, 0.1244, 0.1856, 0.7844]),
    (13, 'PARCEL-13 zone-arterial', 'zone-arterial', 0.1869, 0.8231, 0.3769, 0.4131, [0.1869, 0.8231, 0.3769, 0.4131]),
    (14, 'PARCEL-14 zone-outer', 'zone-outer', 0.3482, 0.2218, 0.9182, 0.6418, [0.3482, 0.2218, 0.9182, 0.6418]),
    (15, 'PARCEL-15 zone-campus', 'zone-campus', 0.5595, 0.6205, 0.1595, 0.1205, [0.5595, 0.6205, 0.1595, 0.1205]),
    (16, 'PARCEL-16 zone-core', 'zone-core', 0.9208, 0.1192, 0.2508, 0.7492, [0.9208, 0.1192, 0.2508, 0.7492]),
    (17, 'PARCEL-17 zone-arterial', 'zone-arterial', 0.2821, 0.8179, 0.2921, 0.3779, [0.2821, 0.8179, 0.2921, 0.3779]),
    (18, 'PARCEL-18 zone-outer', 'zone-outer', 0.2934, 0.2166, 0.9834, 0.6066, [0.2934, 0.2166, 0.9834, 0.6066]),
    (19, 'PARCEL-19 zone-campus', 'zone-campus', 0.6547, 0.6153, 0.2247, 0.2353, [0.6547, 0.6153, 0.2247, 0.2353]),
    (20, 'PARCEL-20 zone-core', 'zone-core', 0.866, 0.114, 0.166, 0.714, [0.866, 0.114, 0.166, 0.714]),
    (21, 'PARCEL-21 zone-arterial', 'zone-arterial', 0.2273, 0.8127, 0.3573, 0.3427, [0.2273, 0.8127, 0.3573, 0.3427]),
    (22, 'PARCEL-22 zone-outer', 'zone-outer', 0.3886, 0.2114, 0.8986, 0.5714, [0.3886, 0.2114, 0.8986, 0.5714]),
    (23, 'PARCEL-23 zone-campus', 'zone-campus', 0.5999, 0.6101, 0.2899, 0.2001, [0.5999, 0.6101, 0.2899, 0.2001]),
    (24, 'PARCEL-24 zone-core', 'zone-core', 0.9612, 0.1088, 0.2312, 0.8288, [0.9612, 0.1088, 0.2312, 0.8288]);
DROP TABLE IF EXISTS sfp_scout;
CREATE TABLE sfp_scout AS
SELECT row_number() OVER () AS ord, particle AS p
FROM fractal_search_explore(
         'sfp_comps', 'vec', [0.7, 0.5, 0.6, 0.3]::float8[],
         '{"population_size": 6, "iterations": 8, "mmr_lambda": 0.15}');

DROP TABLE IF EXISTS sfp_picks;
CREATE TABLE sfp_picks AS
SELECT t.ord, s.id, s.label, s.zone
FROM sfp_scout t
JOIN sfp_comps s ON abs(s.c1 - t.p[1]) < 1e-6 AND abs(s.c2 - t.p[2]) < 1e-6 AND abs(s.c3 - t.p[3]) < 1e-6 AND abs(s.c4 - t.p[4]) < 1e-6
ORDER BY t.ord;

SELECT ord, id, label, zone FROM sfp_picks ORDER BY ord;
.print --- coverage: zones represented in the six comparables ---
SELECT count(DISTINCT zone) AS zones_covered_of_4 FROM sfp_picks;

.print
.print === 4. Reasoning: reviewer's note ===
SELECT fractal_reason(
    'one-line reviewer''s note: the corridor-dependence of the footprint and the asset class to review',
    json_object('most_linear_district', (SELECT ent FROM sfp_dim ORDER BY dim LIMIT 1), 'review_class', (SELECT ent FROM sfp_prof ORDER BY dfa_alpha DESC LIMIT 1))::VARCHAR) AS narrative;

.print
.print === 5. Headline check ===
.mode list
.headers off
SELECT 'HEADLINE kit=spatial-footprint-portfolio-risk ' || CASE WHEN (SELECT dim FROM sfp_dim WHERE ent = 'linear-strip') + 0.3 < (SELECT dim FROM sfp_dim WHERE ent = 'dense-grid') AND (SELECT dfa_alpha FROM sfp_prof WHERE ent = 'class-d') > 1.2 AND (SELECT count(*) FROM sfp_picks) = 6 AND (SELECT count(DISTINCT zone) FROM sfp_picks) >= 3 THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE sfp_parcels, sfp_dim, sfp_index, sfp_prof, sfp_result, sfp_comps, sfp_picks, sfp_scout;
