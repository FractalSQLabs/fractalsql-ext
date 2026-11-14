-- demo/demo-vertical-maritime-defense.sql
--
-- Industry vertical: Maritime, Aviation & Defense (AIS & Radar Tracking).
--
-- A synthetic AIS-style vessel fleet (30 vessels, lat/lon/speed/heading
-- track vectors) with one vessel given a deliberate course deviation --
-- fractal_search_trajectory's "current vs. baseline" delta search is a
-- direct fit for track-deviation detection ("what changed"), and DFA's
-- scaling exponent on a heading-change series is a real fit for
-- maneuvering-pattern irregularity (smooth transit vs. erratic track).
--
-- Prerequisites: extension installed. Sections 2 and 4 dispatch reasoning
-- through the domain agents (section 3's preset runs retrieval-only) --
-- see ../docs/reasoning-setup.md.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; \
--     cat demo/demo-vertical-maritime-defense.sql; } | duckdb -unsigned mydb.duckdb
-- (without -bail: section 4's preset and the standalone fractal_reason()
-- call need the reasoning endpoint configured -- without one the shell
-- prints the clean error and the remaining statements still run.)
--
-- Safe to re-run: vmd_* tables are dropped and recreated each time.
--
-- Notes:
--   * MMSI-100000007 (vessel 7) is the deliberate course deviation: its
--     current track vector sits ~1.44 (L2) off its baseline -- a speed
--     drop plus a course change -- while every other vessel stays inside
--     the ~0.08 noise band.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=maritime-defense ok);
--     the build_test kit gate greps for it.

-- (Timing is omitted -- DuckDB's CLI has no per-statement
-- timing dot-command; measure latency at the harness level, e.g.
-- demo/demo-workload.sh.)

-- The fixture generator: an LCG with xor-shift rounds over pure integer
-- arithmetic, so every draw is exactly the same everywhere.
--
-- random() would not do: setseed() seeds only the engine of the thread
-- that called it, and every other DuckDB worker thread runs its own
-- random() stream, so a fixture query DuckDB spreads over several
-- threads hands each row a value from a different stream -- and the
-- fleet, and with it the trajectory search and the headline check that
-- pins its winner, came out different on a different machine. Deriving
-- the fixture from the row id instead makes it a pure function of the
-- data: the same fleet on every machine, core count and DuckDB build.
-- The xor-shift rounds are not decoration: a plain LCG is AFFINE in
-- its seed, so two seeds one apart differ by a CONSTANT amount --
-- "separate" dimensions drawn from adjacent seeds came out as mirror
-- images of each other, and a 2-D walk built that way collapses onto a
-- line. The xor-shift breaks that affinity, so neighbouring seeds give
-- genuinely unrelated draws.
CREATE OR REPLACE MACRO vmd_lcg(s) AS ((((s::BIGINT * 1103515245::BIGINT) + 12345) % 2147483648));
CREATE OR REPLACE MACRO vmd_xs(a, sh) AS (xor(a, a >> sh));
CREATE OR REPLACE MACRO vmd_mix(s) AS (vmd_xs(vmd_lcg(vmd_xs(vmd_lcg(s), 13)), 17));
CREATE OR REPLACE MACRO vmd_rand(s) AS (vmd_mix(s)::DOUBLE / 2147483648.0);

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 30 vessels, each with a BASELINE track vector (their filed/typical
-- route: [lat_norm, lon_norm, speed_norm, heading_norm]) and a CURRENT
-- track vector. Vessel 7 gets a deliberate large deviation (course
-- change + speed drop -- a classic "gone dark then reappeared off
-- track" pattern); everyone else's current stays close to baseline
-- (normal transit noise).
-- ------------------------------------------------------------------
.print
.print === 1. 30 vessels: baseline vs. current AIS track vectors ===

DROP TABLE IF EXISTS vmd_vessels;
DROP SEQUENCE IF EXISTS seq_vmd_vessels_id;
CREATE SEQUENCE seq_vmd_vessels_id;
CREATE TABLE vmd_vessels (
    id       INTEGER PRIMARY KEY DEFAULT nextval('seq_vmd_vessels_id'),
    mmsi     text,
    -- float8[4], not a fractal_vector catalog type -- this build has
    -- none (see docs/api-analytics.md). float8/DOUBLE
    -- since these only ever feed fractal_search_trajectory below.
    -- Fixed-width AIS track state ([lat_norm, lon_norm, speed_norm,
    -- heading_norm]), same dimension-safety argument as vitals in
    -- demo-vertical-medtech-clinical.sql.
    baseline float8[4],
    current  float8[4]
);

-- float8[] has no built-in elementwise +/- operator either, so
-- baseline and current are built from the same per-dimension base
-- values directly rather than via array arithmetic -- the INSERT
-- below is otherwise UNCHANGED from the original (still literal
-- ::float8[] values), relying on the same assignment-cast coercion
-- demo-vertical-medtech-clinical.sql's INSERT does.
--
-- The id is written out rather than left to the column's DEFAULT
-- nextval: a sequence hands out its values in the order the rows are
-- physically inserted, and DuckDB does not insert them in the order
-- generate_series produces them. The id is this demo's handle on a
-- vessel -- "vessel 7" means the row whose id is 7 -- so it is
-- written from the same series that names the vessel, and the two
-- always agree.
INSERT INTO vmd_vessels (id, mmsi, baseline, current)
SELECT gs, 'MMSI-' || (100000000 + gs),
       ARRAY[b1, b2, b3, b4]::float8[],
       ARRAY[b1 + (vmd_rand(gs*10+5)-0.5)*0.05, b2 + (vmd_rand(gs*10+6)-0.5)*0.05,
             b3 + (vmd_rand(gs*10+7)-0.5)*0.1,  b4 + (vmd_rand(gs*10+8)-0.5)*0.1]::float8[]
FROM generate_series(1, 30) gs(gs),
     LATERAL (SELECT vmd_rand(gs*10+1), vmd_rand(gs*10+2),
                     vmd_rand(gs*10+3), vmd_rand(gs*10+4)) AS bl(b1, b2, b3, b4);

-- Vessel 7's deliberate deviation: large heading/speed change from
-- baseline. Explicit ::float8[] cast before per-element subscripting
-- for consistency with the other verticals, even though baseline is
-- already a float8[4] array.
UPDATE vmd_vessels
   SET current = ARRAY[(baseline::float8[])[1] + 0.6, (baseline::float8[])[2] - 0.5,
                        (baseline::float8[])[3] - 0.9, (baseline::float8[])[4] + 0.8]::float8[]
 WHERE id = 7;

-- ------------------------------------------------------------------
-- 2. fractal_search_trajectory: current vs. baseline DELTA for the
-- flagged vessel -- which stored tracks does this deviation most
-- resemble? "What changed", not "what's closest" -- see that
-- function's own doc comment. flagged.baseline/flagged.current are
-- plain float8[4] values -- only one fractal_search_trajectory
-- overload exists in this build.
-- ------------------------------------------------------------------
-- ------------------------------------------------------------------
-- doc_id here is DuckDB's `rowid` pseudocolumn, stringified (see
-- docs/api-agency.md (the corpus scan)). rowid is the
-- stable-enough locator this build uses; it can shift under operations
-- that rewrite the table, so treat doc_id as ephemeral -- map doc_id
-- back to mmsi via a direct rowid predicate rather than assuming
-- doc_id + 1 = id.
.print
.print === 2. Vessel 7's deviation vs. the fleet (fractal_search_trajectory) ===

-- The current-vs-baseline DELTA search for vessel 7's deviation.
-- Generalized by the shipped fractal_agent_track_anomaly preset in
-- Section 4, which folds this trajectory search together with the
-- heading-change DFA exponent and a reasoning step (the preset resolves
-- the trajectory doc_id, a 0-indexed scan position, through the rowid
-- order, the same mapping this raw form uses).
-- Table-function args are constant-only in DuckDB, so vessel 7's
-- baseline/current pair spools through the .once/.read idiom:
.mode list
.headers off
.output vmd_traj.sql
SELECT 'SELECT v.mmsi, t.distance FROM fractal_search_trajectory(''vmd_vessels'', ''current'', ' ||
       (SELECT baseline FROM vmd_vessels WHERE id = 7)::VARCHAR ||
       ', ' || (SELECT current FROM vmd_vessels WHERE id = 7)::VARCHAR ||
       ', 5) t JOIN (SELECT mmsi, row_number() OVER (ORDER BY rowid) - 1 AS doc_id FROM vmd_vessels) v ON v.doc_id = t.doc_id ORDER BY t.distance;'
;
.output stdout
.mode box
.headers on
.read vmd_traj.sql

-- ------------------------------------------------------------------
-- 3. fractal_search_telemetry / fractal_search_explore: nearest-track
-- lookup (who's near a contact-of-interest position) and diverse-track
-- clustering (representative traffic patterns across the whole fleet).
--
-- doc_id here is DuckDB's `rowid` pseudocolumn, stringified (see
-- docs/api-agency.md (the corpus scan)). rowid is the
-- stable-enough locator this build uses; it can shift under operations
-- that rewrite the table, so treat doc_id as ephemeral.
-- ------------------------------------------------------------------
.print
.print === 3. Nearest vessels to a contact position, and diverse fleet traffic patterns ===

.print Nearest vessels to a contact-of-interest position:
SELECT v.mmsi, t.distance
FROM fractal_search_telemetry('vmd_vessels', 'current',
                              ARRAY[0.2, 0.2, 0.5, 0.0]::float8[], 5) t
JOIN vmd_vessels v ON v.rowid::text = t.doc_id
ORDER BY t.distance;

.print
.print Diverse representative traffic patterns across the fleet:
.print --- raw explore form (query-agnostic -- explore samples the space) ---

-- Blueprint (raw primitive): returns a diverse representative set of the
-- fleet's traffic-pattern embeddings.
SELECT particle FROM fractal_search_explore(
    'vmd_vessels', 'current', ARRAY[0,0,0,0]::float8[],
    '{"population_size": 6, "iterations": 8, "walk": 0}'
);

-- Productized preset: the shipped engine (a scalar returning one JSON
-- document -- an array of {item_id, score} rows, score = 1 -
-- cosine_distance) enables session-global repulsion on the shared engine
-- context, then leaves it on (the caller owns that policy). The raw
-- explore above is query-agnostic (explore samples the space);
-- recommend_diverse is query-anchored, so anchor on the first vessel's
-- own current vector. The registered disable below resets the ledger's
-- own context (a different session from the engine ctx).
.print --- recommend_diverse composition (query-anchored, repulsion on) ---
SELECT fractal_agent_recommend_diverse(
    'vmd_vessels', 'current',
    (SELECT current::float8[] FROM vmd_vessels ORDER BY id LIMIT 1),
    6, 'id');
-- DuckDB binds table-function arguments with the constant binder, which
-- rejects subqueries outright, so the anchor vector spools through the
-- .output/.read idiom (the same contract as demo-agents.sql 13a):
.mode list
.headers off
.output vmd_tel.sql
SELECT 'SELECT doc_id, distance FROM fractal_search_telemetry(''vmd_vessels'', ''current'', ' ||
       (SELECT current FROM vmd_vessels ORDER BY id LIMIT 1)::VARCHAR ||
       ', 6) ORDER BY distance ASC;'
;
.output stdout
.mode box
.headers on
.read vmd_tel.sql
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 4. fractal_dimension_dfa: maneuvering-pattern irregularity. A smooth
-- transit heading series (vessel on a steady course) vs. vessel 7's
-- erratic heading series (evasive/anomalous maneuvering) -- DFA's
-- alpha separates the two: near-random-walk (smooth, ~1.3-1.5) vs.
-- much rougher/anti-persistent behavior for erratic maneuvering.
-- ------------------------------------------------------------------
.print
.print === 4. fractal_dimension_dfa: heading-change series, normal vs. flagged vessel ===

.print Normal vessel (smooth heading drift over 120 samples):
SELECT fractal_dimension_dfa(
    (SELECT array_agg(cum ORDER BY t) FROM (
        SELECT t, sum(step) OVER (ORDER BY t) AS cum
          FROM (SELECT t, (vmd_rand(t * 4 + 1) - 0.5) * 0.03 AS step FROM generate_series(1, 120) t(t)) s
    ) c)
) AS normal_vessel_alpha;

.print
.print Vessel 7 (erratic heading swings over the same window):
-- The flagged vessel's heading-change DFA exponent -- the raw-primitive
-- leg of the composition. Generalized below by the
-- fractal_agent_track_anomaly preset, which folds this together with the
-- Section 2 trajectory search and a reasoning step. (The normal-vessel
-- DFA above stays raw -- a comparison baseline the engine, which takes a
-- single heading series, has no home for.)
SELECT fractal_dimension_dfa(
    (SELECT array_agg(cum ORDER BY t) FROM (
        SELECT t, sum(step) OVER (ORDER BY t) AS cum
          FROM (SELECT t,
                       (vmd_rand(t * 4 + 2) - 0.5) * (CASE WHEN t BETWEEN 60 AND 90 THEN 0.35 ELSE 0.03 END) AS step
                  FROM generate_series(1, 120) t(t)) s
    ) c)
) AS heading_series_dfa_exponent;

-- The composition's raw trajectory leg -- the same search the shipped
-- preset folds in (a scalar returning one JSON document:
-- {nearest_fleet_id, trajectory_distance, dfa_exponent, rationale}, with
-- rationale as the one folded reasoning step):
-- Same spool idiom for the preset's raw trajectory leg:
.mode list
.headers off
.output vmd_traj2.sql
SELECT 'SELECT doc_id, distance FROM fractal_search_trajectory(''vmd_vessels'', ''current'', ' ||
       (SELECT baseline FROM vmd_vessels WHERE id = 7)::VARCHAR ||
       ', ' || (SELECT current FROM vmd_vessels WHERE id = 7)::VARCHAR ||
       ', 5);'
;
.output stdout
.mode box
.headers on
.read vmd_traj2.sql
SELECT fractal_dimension_dfa(
    (SELECT array_agg(cum ORDER BY t) FROM (
        SELECT t, sum(step) OVER (ORDER BY t) AS cum
          FROM (SELECT t,
                       (vmd_rand(t * 4 + 2) - 0.5) * (CASE WHEN t BETWEEN 60 AND 90 THEN 0.35 ELSE 0.03 END) AS step
                  FROM generate_series(1, 120) t(t)) s
    ) c)
) AS heading_series_dfa_exponent;

-- The composition's standalone reason leg -- kept raw exactly as the
-- composition ran it (same narrative, not a bare ping):
SELECT fractal_reason('one-line track-anomaly read for this vessel');

-- The shipped preset folds both raw forms above into one reasoning
-- step (same fixtures):
SELECT fractal_agent_track_anomaly(
    'vmd_vessels', 'current',
    (SELECT baseline::float8[] FROM vmd_vessels WHERE id = 7),
    (SELECT current::float8[]  FROM vmd_vessels WHERE id = 7),
    (SELECT array_agg(cum ORDER BY t) FROM (
        SELECT t, sum(step) OVER (ORDER BY t) AS cum
          FROM (SELECT t,
                       (vmd_rand(t * 4 + 2) - 0.5) * (CASE WHEN t BETWEEN 60 AND 90 THEN 0.35 ELSE 0.03 END) AS step
                  FROM generate_series(1, 120) t(t)) s
    ) c),
    5, 'id');

-- ------------------------------------------------------------------
-- 5. Reasoning: the "does vessel 7's track need attention?" narrative is
-- carried by the fractal_agent_track_anomaly preset's rationale key in
-- Section 4 (the same trajectory deviation + heading DFA, folded into
-- one reasoning step). The raw fractal_reason() leg above is the same
-- call the preset folds -- kept standalone so the composition reads in
-- its original three-leg order.
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: carried by the Section 4 track_anomaly rationale ===

-- ------------------------------------------------------------------
-- 6. Headline check: the kit's own claims, recomputed from the kit's
-- own table and the kit's own search -- vessel 7 (MMSI-100000007) is
-- the fleet's ONE large baseline-to-current track deviation (a course
-- change plus a speed drop), every other vessel stays inside the
-- normal-transit noise band, and the Section 2 trajectory delta search
-- picks vessel 7 out of the fleet by a wide margin.
--
-- The delta that search queries with is the deviation itself --
-- (0.6, -0.5, -0.9, 0.8) -- exactly what Section 1's UPDATE writes onto
-- vessel 7's baseline. Table-function args are constant-only in
-- DuckDB, so it is spelled out here as a literal (Section 2 spools the
-- same vector pair through the .output/.read idiom).
-- ------------------------------------------------------------------
.print
.print === 6. Headline check ===
WITH drift AS (
    SELECT id, mmsi,
           sqrt(pow(("current"::float8[])[1] - (baseline::float8[])[1], 2)
              + pow(("current"::float8[])[2] - (baseline::float8[])[2], 2)
              + pow(("current"::float8[])[3] - (baseline::float8[])[3], 2)
              + pow(("current"::float8[])[4] - (baseline::float8[])[4], 2)) AS drift_l2
    FROM vmd_vessels
),
traj AS (
    SELECT v.mmsi, t.distance
    FROM fractal_search_trajectory('vmd_vessels', 'current',
                                   [0, 0, 0, 0]::float8[],
                                   [0.6, -0.5, -0.9, 0.8]::float8[], 5) t
    JOIN (SELECT mmsi, row_number() OVER (ORDER BY rowid) - 1 AS pos FROM vmd_vessels) v
      ON v.pos = t.doc_id
)
SELECT 'HEADLINE kit=maritime-defense ' || CASE WHEN
         (SELECT count(*) FROM vmd_vessels) = 30
     AND (SELECT count(*) FROM drift WHERE drift_l2 > 0.5) = 1
     AND (SELECT id FROM drift WHERE drift_l2 > 0.5) = 7
     AND (SELECT mmsi FROM drift WHERE id = 7) = 'MMSI-100000007'
     AND (SELECT drift_l2 FROM drift WHERE id = 7) > 1.0
     AND (SELECT max(drift_l2) FROM drift WHERE id <> 7) < 0.2
     AND (SELECT count(*) FROM traj) = 5
     AND (SELECT count(*) FROM traj WHERE mmsi = 'MMSI-100000007') = 1
     AND (SELECT mmsi FROM traj ORDER BY distance LIMIT 1) = 'MMSI-100000007'
     AND (SELECT min(distance) FROM traj) < 0.3
     AND (SELECT distance FROM traj ORDER BY distance LIMIT 1 OFFSET 1) > 0.5
THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vmd_vessels;
.print ================================================================
