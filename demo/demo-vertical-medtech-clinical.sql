-- demo/demo-vertical-medtech-clinical.sql
--
-- Industry vertical: MedTech, Clinical Telemetry & Patient Monitoring.
--
-- Synthetic patient vitals + telemetry (cohort-filtered search, current-
-- vs-baseline drift) plus the four domain-specific geometry functions on
-- small, pre-extracted geometric test fixtures (a vessel graph, a triangulated
-- mesh, a nerve fiber skeleton) -- these take PRE-EXTRACTED geometry, not
-- raw imaging data (see fractal_vascular_network/_cortical_folding/
-- _nerve_plexus_metric's own doc comments for that scope boundary).
--
-- Prerequisites: extension installed. Section 3's preset dispatches
-- reasoning through the domain agent -- see ../docs/reasoning-setup.md.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; \
--     cat demo/demo-vertical-medtech-clinical.sql; } | duckdb -unsigned mydb.duckdb
-- (without -bail: section 3's preset and the standalone fractal_reason()
-- call need the reasoning endpoint configured -- without one the shell
-- prints the clean error and the remaining statements still run.)
--
-- Safe to re-run: vmc_* tables are dropped and recreated each time.
--
-- Notes:
--   * The sepsis-watch cohort (age > 65 AND condition = 'sepsis')
--     contains the three deterministically flagged patients (ids 3, 11
--     and 27), and the Section 3 triage picks patient 19 as the cohort
--     member closest to the deteriorating-vitals pattern.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=medtech-clinical ok);
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
-- cohort, and with it the triage's nearest cohort member (which the
-- headline check pins), came out different on a different machine.
-- Deriving the fixture from the row id instead makes it a pure function
-- of the data: the same cohort on every machine, core count and DuckDB
-- build.
-- The xor-shift rounds are not decoration: a plain LCG is AFFINE in
-- its seed, so two seeds one apart differ by a CONSTANT amount --
-- "separate" dimensions drawn from adjacent seeds came out as mirror
-- images of each other, and a 2-D walk built that way collapses onto a
-- line. The xor-shift breaks that affinity, so neighbouring seeds give
-- genuinely unrelated draws.
CREATE OR REPLACE MACRO vmc_lcg(s) AS ((((s::BIGINT * 1103515245::BIGINT) + 12345) % 2147483648));
CREATE OR REPLACE MACRO vmc_xs(a, sh) AS (xor(a, a >> sh));
CREATE OR REPLACE MACRO vmc_mix(s) AS (vmc_xs(vmc_lcg(vmc_xs(vmc_lcg(s), 13)), 17));
CREATE OR REPLACE MACRO vmc_rand(s) AS (vmc_mix(s)::DOUBLE / 2147483648.0);

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 40 synthetic patients with a demographic/condition cohort and a
-- 5-dim current-vitals vector (heart rate, SpO2, systolic, diastolic,
-- temperature, each roughly normalized). One flagged "sepsis-watch"
-- cohort (age > 65 AND condition = 'sepsis') for Section 2.
-- ------------------------------------------------------------------
.print
.print === 1. 40 synthetic patients: demographics + current vitals ===

DROP TABLE IF EXISTS vmc_patients;
DROP SEQUENCE IF EXISTS seq_vmc_patients_id;
CREATE SEQUENCE seq_vmc_patients_id;
CREATE TABLE vmc_patients (
    id        INTEGER PRIMARY KEY DEFAULT nextval('seq_vmc_patients_id'),
    age       int,
    condition text,
    -- float8[5], not a fractal_vector catalog type -- this build has
    -- none (see docs/api-analytics.md). [hr_z, spo2_z,
    -- systolic_z, diastolic_z, temp_z] is a fixed, known-width vector
    -- where dimension-drift protection actually matters clinically: a
    -- malformed vitals write (wrong field count from an upstream
    -- monitor integration) should raise loudly, not silently corrupt
    -- a patient record -- DuckDB's fixed-size ARRAY enforces that the
    -- same way fractal_vector's typmod did.
    vitals    float8[5]
);

-- The INSERT below is UNCHANGED -- still literal ::float8[] values,
-- assignment-cast into the float8[5] column automatically.
INSERT INTO vmc_patients (age, condition, vitals)
SELECT
    (22 + (vmc_rand(gs * 10 + 1) * 68))::int,
    CASE WHEN vmc_rand(gs * 10 + 2) < 0.2 THEN 'sepsis'
         WHEN vmc_rand(gs * 10 + 2) < 0.4 THEN 'post-op'
         ELSE 'routine' END,
    ARRAY[vmc_rand(gs * 10 + 3) * 2 - 1, vmc_rand(gs * 10 + 4) * 2 - 1,
          vmc_rand(gs * 10 + 5) * 2 - 1, vmc_rand(gs * 10 + 6) * 2 - 1,
          vmc_rand(gs * 10 + 7) * 2 - 1]::float8[]
FROM generate_series(1, 40) gs(gs);

-- Force at least a few real hits in the cohort filter below, deterministically.
UPDATE vmc_patients SET age = 70, condition = 'sepsis'
 WHERE id IN (3, 11, 27);

-- Patient 11 is the deteriorating case the triage has to find: its
-- vitals carry the deterioration pattern (hr high, SpO2 low, systolic
-- high, diastolic high, temperature high) close to the Section 2 query
-- vector [1,-1,1,1,0.5] and to the Section 3 baseline->current delta.
-- Written out rather than left to a draw, so the headline's "exactly
-- one sharp hit, the rest clearly not" claims hold by construction.
UPDATE vmc_patients SET vitals = ARRAY[1.0, -1.0, 0.85, 0.75, 0.55]::float8[]
 WHERE id = 11;

.print
.print === 2. fractal_hybrid_clinical_search: cohort-restricted search ===
.print (cohort = age > 65 AND condition = sepsis, computed with ordinary SQL --
.print never a raw SQL predicate string, see that function's own doc comment.
.print query stays float8[] here -- vitals is also float8[5], so there is
.print no separate type-conversion step at the corpus-read boundary.)

-- The cohort-restricted hybrid search (the age>65 AND condition='sepsis'
-- sepsis-watch cohort), executed: the registered
-- fractal_hybrid_clinical_search table function directly, handed the
-- cohort's rowid list as its doc_ids allowlist. doc_ids/doc_id are
-- DuckDB's `rowid` pseudocolumn, stringified (see
-- docs/api-agency.md (the corpus scan)); rowid is the
-- stable-enough locator this build uses, and it can shift under
-- operations that rewrite the table, so treat doc_id as ephemeral.
-- Generalized by the shipped fractal_agent_patient_deterioration_triage
-- preset in Section 3, which folds this cohort search together with the
-- baseline->current drift search and a reasoning step.
-- Table-function args are constant-only in DuckDB, so the sepsis-cohort
-- id list spools through the .once/.read idiom (demo-agents.sql 6a):
.mode list
.headers off
.output vmc_hs.sql
SELECT 'SELECT p.id AS patient_id, hs.distance FROM fractal_hybrid_clinical_search(''vmc_patients'', ''vitals'', [1, -1, 1, 1, 0.5]::DOUBLE[], ' ||
       (SELECT '[' || string_agg('''' || rowid::VARCHAR || '''', ', ') || ']'
          FROM vmc_patients WHERE age > 65 AND condition = 'sepsis') ||
       ', 5) hs JOIN vmc_patients p ON p.rowid::VARCHAR = hs.doc_id ORDER BY hs.distance;'
;
.output stdout
.mode box
.headers on
.read vmc_hs.sql

-- ------------------------------------------------------------------
-- 3. fractal_search_trajectory: one patient's CURRENT vitals vs their
-- own admission BASELINE -- "what changed", the natural query shape
-- for drift/trajectory monitoring (this function's own doc comment
-- uses this exact patient-baseline example).
-- ------------------------------------------------------------------
.print
.print === 3. fractal_search_trajectory: patient drift from admission baseline ===
.print (::float8[] literals here -- there is no fractal_vector overload in
.print this build, just the one float8[]-based fractal_search_trajectory)

-- fractal_agent_patient_deterioration_triage is one of the 16 NAMED
-- domain agents, registered by the fractalsql extension itself in this
-- build. The raw-primitive form it was meant to generalize -- the
-- runnable trajectory-drift search -- stays as the blueprint:
SELECT doc_id, distance
FROM fractal_search_trajectory(
    'vmc_patients', 'vitals',
    '[0.1,0.05,0.0,0.0,0.0]'::float8[],   -- admission baseline
    '[1.4,-1.1,0.9,0.7,1.2]'::float8[],   -- current (deteriorating)
    5
);

-- The shipped preset (a scalar returning one JSON document:
-- {nearest_cohort_id, cohort_distance, drift_distance, rationale,
-- cohort_matches} -- the Section 2 cohort hybrid search, this trajectory
-- search, and one reasoning step folded together). The cohort list is
-- the sepsis-watch cohort's rowid values -- this build's row locator:
.print --- Preset: fractal_agent_patient_deterioration_triage ---
SELECT fractal_agent_patient_deterioration_triage(
    'vmc_patients', 'vitals',
    [1, -1, 1, 1, 0.5]::float8[],
    [0.1, 0.05, 0.0, 0.0, 0.0]::float8[],
    [1.4, -1.1, 0.9, 0.7, 1.2]::float8[],
    (SELECT list(rowid ORDER BY rowid) FROM vmc_patients
      WHERE age > 65 AND condition = 'sepsis'),
    5, 'id');

-- The composition's standalone reason leg -- kept raw exactly as the
-- reference composition ran it (same narrative, not a bare ping):
SELECT fractal_reason('one-line deterioration-triage rationale for this patient cohort scan');

-- ------------------------------------------------------------------
-- 4. fractal_vascular_network: a branching vessel graph -- a 28-node
-- centerline chain plus 2 branch leaves off node 10, node_coords in 3D
-- with real arc lengths from an upstream centerline trace. Needs >= 8
-- nodes AND enough of them for the internal box-counting dimension
-- estimator to find >= 3 valid eps-octaves (its own documented
-- "avg >= 3 points/occupied-cell" validity filter, same one
-- the core library's own boxcount unit tests calibrate against) -- a
-- too-small skeleton returns rc=-1, not a wrong number.
-- ------------------------------------------------------------------
.print
.print === 4. fractal_vascular_network: vessel tortuosity/branch-density/dimension ===

DROP TABLE IF EXISTS vmc_vessel;
CREATE TEMP TABLE vmc_vessel AS
SELECT
    (SELECT array_agg(v ORDER BY i, ord) FROM generate_series(0, 27) i(i)
       CROSS JOIN LATERAL unnest(ARRAY[i::float8, 0.0, 0.0]) WITH ORDINALITY AS u(v, ord))
    || ARRAY[10, 1, 0, 10, 0, 1]::float8[] AS nodes,
    (SELECT array_agg(v ORDER BY i, ord) FROM generate_series(0, 26) i(i)
       CROSS JOIN LATERAL unnest(ARRAY[i, i + 1]) WITH ORDINALITY AS u(v, ord))::int4[]
    || ARRAY[10, 28, 10, 29]::int4[] AS edges,
    (SELECT array_agg(1.02) FROM generate_series(0, 28)) AS arcs;

SELECT fractal_vascular_network(nodes, edges, arcs) FROM vmc_vessel;

-- ------------------------------------------------------------------
-- 5. fractal_cortical_folding: a unit-cube surface mesh (8 vertices,
-- 12 triangular faces) -- a "smooth" (unfolded) reference case where
-- mesh area should closely match hull area (GI ~1.0), the same known-
-- answer sanity check the core library's own cortical.c unit tests use.
-- ------------------------------------------------------------------
.print
.print === 5. fractal_cortical_folding: Gyrification Index on a reference mesh ===

SELECT fractal_cortical_folding(
    ARRAY[0,0,0, 1,0,0, 1,1,0, 0,1,0, 0,0,1, 1,0,1, 1,1,1, 0,1,1]::float8[],
    ARRAY[0,1,2, 0,2,3,   4,5,6, 4,6,7,   0,1,5, 0,5,4,
          3,2,6, 3,6,7,   0,3,7, 0,7,4,   1,2,6, 1,6,5]::int4[]
);

-- ------------------------------------------------------------------
-- 6. fractal_nerve_plexus_metric: an 80-fiber zigzag skeleton (corneal
-- confocal microscopy convention -- fiber length density, branch
-- density, box-counting dimension). Same box-counting-scale note as
-- Section 4 above -- 80 points is comfortably past the internal
-- estimator's minimum for a reliable answer.
-- ------------------------------------------------------------------
.print
.print === 6. fractal_nerve_plexus_metric: corneal nerve fiber plexus ===

DROP TABLE IF EXISTS vmc_nerve;
CREATE TEMP TABLE vmc_nerve AS
SELECT
    (SELECT array_agg(v ORDER BY i, ord) FROM generate_series(0, 79) i(i)
       CROSS JOIN LATERAL unnest(ARRAY[i::float8, 0.05 * sin(i::float8)]) WITH ORDINALITY AS u(v, ord)) AS coords,
    (SELECT array_agg(v ORDER BY i, ord) FROM generate_series(0, 78) i(i)
       CROSS JOIN LATERAL unnest(ARRAY[i, i + 1]) WITH ORDINALITY AS u(v, ord))::int4[] AS edges;

SELECT fractal_nerve_plexus_metric(coords, 2, edges) FROM vmc_nerve;

-- ------------------------------------------------------------------
-- 7. Reasoning: the cohort-search + trajectory-drift clinical narrative
-- is carried by the fractal_agent_patient_deterioration_triage preset's
-- rationale key in Section 3; the raw fractal_reason() leg above is the
-- same call the preset folds, kept standalone so the composition reads
-- in its original order. The vessel/cortical/nerve geometry primitives
-- in Sections 4-6 stay raw (domain geometry with no engine home) --
-- their own output columns are the showcase.
-- ------------------------------------------------------------------
.print
.print === 7. Reasoning: carried by the Section 3 triage rationale ===

-- ------------------------------------------------------------------
-- 8. Headline check: the kit's own claim, recomputed from the kit's
-- own table -- the sepsis-watch cohort (age > 65 AND condition =
-- 'sepsis') holds the deterministically flagged patients, and the
-- Section 3 triage picks ONE cohort member (patient 19) that matches
-- the deteriorating-patient pattern far more closely than the rest of
-- the cohort (nearest ~0.06, runner-up ~0.72; drift distance ~0.03).
--
-- The triage preset is a scalar, so it takes the cohort as a subquery
-- here exactly as Section 3 does -- its JSON result is the kit's own
-- search output, read back with the JSON reader.
-- ------------------------------------------------------------------
.print
.print === 8. Headline check ===
WITH triage AS (
    SELECT fractal_agent_patient_deterioration_triage(
               'vmc_patients', 'vitals',
               [1, -1, 1, 1, 0.5]::DOUBLE[],
               [0.1, 0.05, 0.0, 0.0, 0.0]::DOUBLE[],
               [1.4, -1.1, 0.9, 0.7, 1.2]::DOUBLE[],
               (SELECT list(rowid ORDER BY rowid) FROM vmc_patients
                 WHERE age > 65 AND condition = 'sepsis'),
               5, 'id') AS doc
),
tj AS (
    SELECT json_extract_string(doc, '$.nearest_cohort_id')::BIGINT AS nearest_id,
           json_extract_string(doc, '$.cohort_distance')::DOUBLE   AS cohort_distance,
           json_extract_string(doc, '$.drift_distance')::DOUBLE    AS drift_distance
    FROM triage
),
matched AS (
    SELECT json_extract_string(m, '$.id')::BIGINT       AS patient_id,
           json_extract_string(m, '$.distance')::DOUBLE AS distance
    FROM (SELECT unnest(from_json(json_extract(doc, '$.cohort_matches')::VARCHAR,
                                   '["JSON"]')) AS m
          FROM triage)
)
SELECT 'HEADLINE kit=medtech-clinical ' || CASE WHEN
         (SELECT count(*) FROM vmc_patients) = 40
     AND (SELECT count(*) FROM vmc_patients
           WHERE id IN (3, 11, 27) AND age = 70 AND condition = 'sepsis') = 3
     AND (SELECT count(*) FROM vmc_patients
           WHERE age > 65 AND condition = 'sepsis') >= 5
     AND (SELECT count(*) FROM matched) = 5
     AND (SELECT count(*) FROM matched
           WHERE patient_id NOT IN (SELECT id FROM vmc_patients
                                     WHERE age > 65 AND condition = 'sepsis')) = 0
     AND (SELECT count(*) FROM matched WHERE patient_id IN (3, 11, 27)) = 3
     AND (SELECT nearest_id FROM tj) = 11
     AND (SELECT count(*) FROM vmc_patients p
           WHERE p.id = (SELECT nearest_id FROM tj)
             AND p.age > 65 AND p.condition = 'sepsis') = 1
     AND (SELECT count(*) FROM matched WHERE distance < 0.1) = 1
     AND (SELECT count(*) FROM matched WHERE distance > 0.3) = 4
     AND (SELECT cohort_distance FROM tj) < 0.1
     AND (SELECT drift_distance FROM tj) > 0
     AND (SELECT drift_distance FROM tj) < 0.1
THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vmc_patients;
.print (the vmc_* TEMP tables evaporate with the connection.)
.print ================================================================
