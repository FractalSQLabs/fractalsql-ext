-- demo/demo-vertical-fleet-logistics.sql
--
-- Industry vertical: Autonomous Fleet Management & Last-Mile Delivery.
--
-- A 40-vehicle delivery fleet with route-embedding vectors, one vehicle
-- running a deliberately-detouring route. Diverse depot-coverage
-- clustering, a cohort-restricted search (today's route-3 vehicles
-- only), current-vs-baseline detour detection, and GPS-trace
-- complexity via box-counting.
--
-- Prerequisites: extension installed (sections 0-4 need nothing else).
-- Sections 2 and 5 call fractal_reason() via the domain agents, which
-- register with the extension itself (no separate agents extension) --
-- see ../docs/reasoning-setup.md.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; cat demo/demo-vertical-fleet-logistics.sql; } \
--       | duckdb -bail -unsigned
--
-- Safe to re-run: vfl_* tables are dropped and recreated each time.
--
-- Notes:
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=fleet-logistics ok);
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
-- fleet came out different on a different machine. Deriving every draw
-- from the row id instead makes the fixture a pure function of the data:
-- the same fleet on every machine, core count and DuckDB build.
-- The xor-shift rounds are not decoration: a plain LCG is AFFINE in
-- its seed, so two seeds one apart differ by a CONSTANT amount --
-- "separate" dimensions drawn from adjacent seeds came out as mirror
-- images of each other, and a 2-D walk built that way collapses onto a
-- line. The xor-shift breaks that affinity, so neighbouring seeds give
-- genuinely unrelated draws.
CREATE OR REPLACE MACRO vfl_lcg(s) AS ((((s::BIGINT * 1103515245::BIGINT) + 12345) % 2147483648));
CREATE OR REPLACE MACRO vfl_xs(a, sh) AS (xor(a, a >> sh));
CREATE OR REPLACE MACRO vfl_mix(s) AS (vfl_xs(vfl_lcg(vfl_xs(vfl_lcg(s), 13)), 17));
CREATE OR REPLACE MACRO vfl_rand(s) AS (vfl_mix(s)::DOUBLE / 2147483648.0);

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 40 delivery vehicles across 4 routes, each with a BASELINE route
-- vector (planned stop sequence, embedded) and a CURRENT route vector
-- (today's actual telemetry). Vehicle 5 gets a deliberate large
-- detour; everyone else's current stays close to baseline (normal
-- traffic/timing noise).
-- ------------------------------------------------------------------
.print
.print === 1. 40 delivery vehicles: baseline vs. current route vectors ===

DROP TABLE IF EXISTS vfl_vehicles;
DROP SEQUENCE IF EXISTS seq_vfl_vehicles_id;
CREATE SEQUENCE seq_vfl_vehicles_id;
CREATE TABLE vfl_vehicles (
    id       INTEGER PRIMARY KEY DEFAULT nextval('seq_vfl_vehicles_id'),
    van_id   text,
    route_no int,
    -- float8[4], not a fractal_vector catalog type -- this build has
    -- none (see docs/api-analytics.md). float8/DOUBLE,
    -- not float4: only fed to fractal_search_trajectory/
    -- fractal_agent_* below, never a fractal_vector_* arithmetic
    -- primitive. Fixed-width for the same dimension-safety reason as
    -- demo-vertical-medtech-clinical.sql's vitals and demo-vertical-
    -- maritime-defense.sql's baseline/current.
    baseline float8[4],
    current  float8[4]
);

-- INSERT is UNCHANGED (still literal ::float8[] values) -- the
-- assignment cast handles coercion into the float8[4] columns
-- automatically, same as the other two updated verticals.
--
-- The id is written out rather than left to the column's DEFAULT
-- nextval: a sequence hands out its values in the order the rows are
-- physically inserted, and DuckDB does not insert them in the order
-- generate_series produces them. The id is this demo's handle on a
-- van -- "van 5" means the row whose id is 5 -- so it is written from
-- the same series that names the van, and the two always agree.
INSERT INTO vfl_vehicles (id, van_id, route_no, baseline, current)
SELECT gs, 'VAN-' || gs, ((gs - 1) % 4) + 1,
       ARRAY[b1, b2, b3, b4]::float8[],
       ARRAY[b1 + (vfl_rand(gs*10+5)-0.5)*0.06, b2 + (vfl_rand(gs*10+6)-0.5)*0.06,
             b3 + (vfl_rand(gs*10+7)-0.5)*0.06, b4 + (vfl_rand(gs*10+8)-0.5)*0.06]::float8[]
FROM generate_series(1, 40) gs(gs),
     LATERAL (SELECT vfl_rand(gs*10+1)*2-1, vfl_rand(gs*10+2)*2-1,
                     vfl_rand(gs*10+3)*2-1, vfl_rand(gs*10+4)*2-1) AS bl(b1, b2, b3, b4);

-- Vehicle 5's deliberate detour: current route vector far from its
-- plan. fractal_vector has no [n] subscript operator -- cast to
-- float8[] for the per-element arithmetic (same pattern as
-- demo-vertical-maritime-defense.sql's vessel-7 UPDATE), then let the
-- assignment cast coerce the result back on write.
UPDATE vfl_vehicles
   SET current = ARRAY[(baseline::float8[])[1] - 0.7, (baseline::float8[])[2] + 0.6,
                        (baseline::float8[])[3] + 0.5, (baseline::float8[])[4] - 0.4]::float8[]
 WHERE id = 5;

-- ------------------------------------------------------------------
-- 2. Scout Discovery: diverse route/zone clustering across the fleet --
-- depot coverage planning ("what KINDS of routes are actually running
-- today") without scanning all 40 by hand.
-- ------------------------------------------------------------------
.print
.print === 2. Diverse route/zone clustering ===
.print --- raw explore form (query-agnostic -- explore samples the space) ---

-- Blueprint (raw primitive): returns a diverse representative set of
-- route/zone-cluster embeddings across the fleet. The enable/disable
-- pair below brackets this section's calls on the registered ledger
-- context (a different session from the shared engine ctx -- see the
-- recommendation-search vertical's section 4 scoping note; the telemetry
-- top-k below stays a literal, repulsion-unadjusted nearest list either
-- way).
SELECT fractal_diversify_enable();
SELECT particle FROM fractal_search_explore(
    'vfl_vehicles', 'current', ARRAY[0,0,0,0]::float8[],
    '{"population_size": 6, "iterations": 8, "walk": 0}'
);

-- Productized preset (the recommend_diverse composition): real vehicle
-- ids + scores (1 - cosine_distance) with session-global repulsion
-- enabled, then we restore the session so the section-3 cohort search
-- below sees the same diversify-off state as before (the composition
-- leaves diversify on -- the caller owns that policy). The raw explore
-- above is query-agnostic; the telemetry form is query-anchored, so
-- anchor on the first vehicle's own current vector.
.print --- recommend_diverse composition (query-anchored, repulsion on) ---
SELECT fractal_agent_recommend_diverse(
    'vfl_vehicles', 'current',
    (SELECT current::float8[] FROM vfl_vehicles ORDER BY id LIMIT 1),
    6, 'id');
-- Table-function args are constant-only in DuckDB: the probe vector
-- spools through the .once/.read idiom:
.mode list
.headers off
.output vfl_tel.sql
SELECT 'SELECT doc_id, distance FROM fractal_search_telemetry(''vfl_vehicles'', ''current'', ' ||
       (SELECT current FROM vfl_vehicles ORDER BY id LIMIT 1)::VARCHAR ||
       ', 6) ORDER BY distance ASC;'
;
.output stdout
.mode box
.headers on
.read vfl_tel.sql
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 3. Cohort-restricted search: "today's route-3 vehicles only" --
-- fractal_search_telemetry's table_name argument is a plain text table
-- name, so a cohort filter composes by searching a filtered temp table
-- instead (the same cohort-then-search shape
-- fractal_hybrid_clinical_search uses internally for its doc_ids
-- allowlist, without needing that clinically-named function here).
-- ------------------------------------------------------------------
.print
.print === 3. Cohort-restricted search: route-3 vehicles only ===

-- doc_id here is DuckDB's `rowid` pseudocolumn, stringified (see
-- docs/api-agency.md (the corpus scan)). rowid is the
-- stable-enough locator this build uses; it can shift under operations
-- that rewrite the table, so treat doc_id as ephemeral.
--
-- A real table, not TEMP: the agent surfaces scan the corpus through a
-- side connection, which cannot see the connection-private TEMP schema.
DROP TABLE IF EXISTS vfl_route3_cohort;
CREATE TABLE vfl_route3_cohort AS
SELECT * FROM vfl_vehicles WHERE route_no = 3;

SELECT v.van_id, t.distance
FROM fractal_search_telemetry('vfl_route3_cohort', 'current',
                              ARRAY[0.3, -0.3, 0.2, 0.1]::float8[], 5) t
JOIN vfl_route3_cohort v ON v.rowid::text = t.doc_id
ORDER BY t.distance;

-- ------------------------------------------------------------------
-- 4. fractal_search_trajectory: current vs. baseline DELTA for vehicle
-- 5 -- detour detection, "what changed" not "what's closest".
-- flagged.baseline/flagged.current are plain float8[4] values -- only
-- one fractal_search_trajectory overload exists in this build.
--
-- Unlike section 3, this scans the FULL vfl_vehicles table -- which
-- includes vehicle 5's own relocated tuple (its detour UPDATE in
-- section 1 moved it to scan last). doc_id + 1 = id would mislabel
-- whichever row now happens to have that id; map via rowid order
-- instead.
-- ------------------------------------------------------------------
.print
.print === 4. Vehicle 5's detour vs. the fleet (fractal_search_trajectory) ===

-- The current-vs-baseline DELTA search for vehicle 5's detour --
-- "what changed" not "what's closest". This scans the FULL vfl_vehicles
-- table (which includes vehicle 5's own relocated tuple -- its detour
-- UPDATE in section 1 moved it to scan last). trajectory's doc_id is the
-- 0-INDEXED scan position, so the fleet rows map through the
-- row_number() rowid order -- doc_id + 1 = id would mislabel whichever
-- row now happens to have that id. Generalized by the shipped
-- fractal_agent_detour_classify preset in Section 5, which folds this
-- trajectory search together with the GPS-trace box-counting complexity
-- and a reasoning step.
-- Table-function args are constant-only in DuckDB, so vehicle 5's
-- baseline/current pair spools through the .once/.read idiom:
.mode list
.headers off
.output vfl_traj.sql
SELECT 'SELECT v.van_id, t.distance FROM fractal_search_trajectory(''vfl_vehicles'', ''current'', ' ||
       (SELECT baseline FROM vfl_vehicles WHERE id = 5)::VARCHAR ||
       ', ' || (SELECT current FROM vfl_vehicles WHERE id = 5)::VARCHAR ||
       ', 5) t JOIN (SELECT van_id, row_number() OVER (ORDER BY rowid) - 1 AS doc_id FROM vfl_vehicles) v ON v.doc_id = t.doc_id ORDER BY t.distance;'
;
.output stdout
.mode box
.headers on
.read vfl_traj.sql

-- ------------------------------------------------------------------
-- 5. fractal_dimension_boxcount: GPS-trace complexity for vehicle 5's
-- detoured route (a 2D wandering path, 200 samples) -- a smooth planned
-- route would trace a near-straight path (dimension close to 1); a
-- detour with backtracking/wandering pushes it higher.
-- ------------------------------------------------------------------
.print
.print === 5. Vehicle 5's GPS-trace complexity (box counting) ===

-- Raw primitive: the GPS trace's box-counting complexity -- a smooth
-- planned route would trace a near-straight path (dimension close to 1);
-- a detour with backtracking/wandering pushes it higher. (The
-- trajectory half of this preset's composition ran in Section 4.)
SELECT fractal_dimension_boxcount(
    (SELECT array_agg(cum ORDER BY t, ord) FROM (
        SELECT t, ord, sum(step) OVER (PARTITION BY ord ORDER BY t) AS cum
        FROM generate_series(1, 200) t(t)
        CROSS JOIN LATERAL (VALUES (1, (vfl_rand(t*10+1)-0.5)*0.3), (2, (vfl_rand(t*10+2)-0.5)*0.3)) AS s(ord, step)
    ) c),
    2
) AS gps_trace_dimension;

-- The shipped preset (a scalar returning one JSON document:
-- {nearest_fleet_id, trajectory_distance, trace_complexity, rationale},
-- with rationale as the one folded reasoning step; it re-runs the
-- trajectory search and the GPS trace with their own fresh randomness):

SELECT fractal_agent_detour_classify(
    'vfl_vehicles', 'current',
    (SELECT baseline::float8[] FROM vfl_vehicles WHERE id = 5),
    (SELECT current::float8[]  FROM vfl_vehicles WHERE id = 5),
    (SELECT array_agg(cum ORDER BY t, ord) FROM (
        SELECT t, ord, sum(step) OVER (PARTITION BY ord ORDER BY t) AS cum
        FROM generate_series(1, 200) t(t)
        CROSS JOIN LATERAL (VALUES (1, (vfl_rand(t*10+1)-0.5)*0.3), (2, (vfl_rand(t*10+2)-0.5)*0.3)) AS s(ord, step)
    ) c),
    5, 'id', 2);

-- ------------------------------------------------------------------
-- 6. Reasoning: the dispatch narrative for vehicle 5 is now produced by
-- the fractal_agent_detour_classify preset's rationale key in Section 5 (the same trajectory deviation + GPS-trace complexity,
-- folded into one reasoning step).
-- ------------------------------------------------------------------
.print
.print === 6. Reasoning: absorbed into the Section 5 detour_classify rationale ===

-- ------------------------------------------------------------------
-- 7. Headline check: the kit's own claims, recomputed from the kit's
-- own tables -- VAN-5 is the fleet's one large baseline-to-current
-- detour (every other vehicle stays inside the noise band), and the
-- route-3 cohort search returns route-3 vans only.
-- ------------------------------------------------------------------
.print
.print === 7. Headline check ===
WITH drift AS (
    SELECT id, van_id, route_no,
           sqrt(pow(("current"::float8[])[1] - (baseline::float8[])[1], 2)
              + pow(("current"::float8[])[2] - (baseline::float8[])[2], 2)
              + pow(("current"::float8[])[3] - (baseline::float8[])[3], 2)
              + pow(("current"::float8[])[4] - (baseline::float8[])[4], 2)) AS drift_l2
    FROM vfl_vehicles
),
cohort_hits AS (
    SELECT t.doc_id, t.distance
    FROM fractal_search_telemetry('vfl_route3_cohort', 'current',
                                  ARRAY[0.3, -0.3, 0.2, 0.1]::float8[], 5) t
)
SELECT 'HEADLINE kit=fleet-logistics ' || CASE WHEN
         (SELECT count(*) FROM vfl_vehicles) = 40
     AND (SELECT count(*) FROM drift WHERE drift_l2 > 0.5) = 1
     AND (SELECT id FROM drift WHERE drift_l2 > 0.5) = 5
     AND (SELECT van_id FROM drift WHERE id = 5) = 'VAN-5'
     AND (SELECT min(drift_l2) FROM drift WHERE id = 5) > 1.0
     AND (SELECT max(drift_l2) FROM drift WHERE id <> 5) < 0.2
     AND (SELECT count(*) FROM vfl_route3_cohort) = 10
     AND (SELECT count(*) FROM vfl_route3_cohort WHERE route_no <> 3) = 0
     AND (SELECT count(*) FROM vfl_vehicles WHERE route_no = 3) = 10
     AND (SELECT count(*) FROM cohort_hits) = 5
     AND (SELECT count(DISTINCT doc_id) FROM cohort_hits) = 5
     AND (SELECT count(*) FROM cohort_hits h
           JOIN vfl_route3_cohort c ON c.rowid::VARCHAR = h.doc_id
           JOIN vfl_vehicles v ON v.id = c.id
          WHERE v.route_no <> 3) = 0
THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vfl_vehicles;
.print (the vfl_* TEMP tables evaporate with the connection.)
.print ================================================================
