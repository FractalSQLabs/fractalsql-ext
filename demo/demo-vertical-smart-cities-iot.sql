-- demo/demo-vertical-smart-cities-iot.sql
--
-- Industry vertical: Smart Cities & IoT Sensor Grids.
--
-- A 400-sensor city grid (traffic/air-quality/noise, jittered 20x20
-- placement) for spatial coverage-complexity analysis, one sensor's
-- reading series carrying a deliberate regime shift (an air-quality
-- event) for DFA/drift detection, and diverse representative-zone
-- sampling across the grid.
--
-- Prerequisites: extension installed. Sections 2 and 3 dispatch reasoning
-- through the domain agents (as does section 4's preset) --
-- see ../docs/reasoning-setup.md.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; cat demo/demo-vertical-smart-cities-iot.sql; } \
--       | duckdb -bail -unsigned
--
-- Safe to re-run: vsc_* tables are dropped and recreated each time.

-- Notes:
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=smart-cities-iot ok);
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
-- 400-sensor grid (and the coverage dimension computed over it) came
-- out different on a different machine. Deriving every draw from the
-- row id instead makes the fixture a pure function of the data: the
-- same grid on every machine, core count and DuckDB build.
-- The xor-shift rounds are not decoration: a plain LCG is AFFINE in
-- its seed, so two seeds one apart differ by a CONSTANT amount --
-- "separate" dimensions drawn from adjacent seeds came out as mirror
-- images of each other, and a 2-D walk built that way collapses onto a
-- line. The xor-shift breaks that affinity, so neighbouring seeds give
-- genuinely unrelated draws.
CREATE OR REPLACE MACRO vsc_lcg(s) AS ((((s::BIGINT * 1103515245::BIGINT) + 12345) % 2147483648));
CREATE OR REPLACE MACRO vsc_xs(a, sh) AS (xor(a, a >> sh));
CREATE OR REPLACE MACRO vsc_mix(s) AS (vsc_xs(vsc_lcg(vsc_xs(vsc_lcg(s), 13)), 17));
CREATE OR REPLACE MACRO vsc_rand(s) AS (vsc_mix(s)::DOUBLE / 2147483648.0);

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 400 sensors: a jittered 20x20 grid placement (lat/lon-style x,y
-- position) plus a 3-dim reading vector [traffic, air_quality, noise].
-- A grid-like layout, not sparse random scatter, is what the box-
-- counting-based functions below need to find enough occupied-cell
-- structure across eps scales (same requirement
-- demo/demo-vertical-sovereign-edge-ai.sql's facility-grid section documents).
-- ------------------------------------------------------------------
.print
.print === 1. 400 sensors: jittered 20x20 city grid + readings ===

DROP TABLE IF EXISTS vsc_sensors;
DROP SEQUENCE IF EXISTS seq_vsc_sensors_id;
CREATE SEQUENCE seq_vsc_sensors_id;
CREATE TABLE vsc_sensors (
    id       INTEGER PRIMARY KEY DEFAULT nextval('seq_vsc_sensors_id'),
    sensor_id text,
    -- pos stays float8[] deliberately -- it's unnest()'d below into
    -- flat point-cloud input for fractal_dimension_boxcount/
    -- fractal_morphological_complexity, not read as a vector_col search
    -- corpus, so the native list type is what that flatten needs.
    pos      float8[],   -- [x, y] placement
    -- reading is float8[3], not a fractal_vector catalog type -- this
    -- port has none (see docs/api-analytics.md). It's
    -- read as a vector_col search corpus by fractal_search_explore
    -- below, a DOUBLE-based function, so float8/DOUBLE is required
    -- here regardless. Fixed-width [traffic, air_quality, noise]
    -- vector where dimension safety matters, same argument as the
    -- other updated verticals.
    reading  float8[3]
);

INSERT INTO vsc_sensors (sensor_id, pos, reading)
SELECT 'SENSOR-' || (r * 20 + c + 1),
       ARRAY[r + (vsc_rand(r * 100 + c * 2 + 1)-0.5)*0.3,
             c + (vsc_rand(r * 100 + c * 2 + 2)-0.5)*0.3]::float8[],
       ARRAY[vsc_rand(10000 + r * 100 + c * 3 + 1)*2-1,
             vsc_rand(10000 + r * 100 + c * 3 + 2)*2-1,
             vsc_rand(10000 + r * 100 + c * 3 + 3)*2-1]::float8[]
FROM generate_series(0, 19) r(r)
CROSS JOIN generate_series(0, 19) c(c);

-- ------------------------------------------------------------------
-- 2. fractal_dimension_boxcount / fractal_morphological_complexity over
-- the sensor grid's spatial layout -- coverage-density diagnostics
-- (dimension near 2.0 + moderate lacunarity means even, gap-free
-- coverage; a lower dimension or high lacunarity would flag sparse or
-- clustered deployment).
-- ------------------------------------------------------------------
.print
.print === 2. Sensor grid spatial coverage: dimension + morphological complexity ===

SELECT fractal_dimension_boxcount(
    (SELECT array_agg(v ORDER BY id, ord) FROM vsc_sensors, LATERAL unnest(pos) WITH ORDINALITY AS u(v, ord)),
    2
) AS coverage_dimension;

-- Blueprint (raw primitive), executed: the sensor grid's morphological
-- complexity (box-counting dimension + lacunarity) + drift over the
-- air-quality event series. Generalized below by the shipped
-- fractal_agent_network_coverage_alert preset, which folds both together
-- with a reasoning step.

-- The air-quality event series (240 samples; readings hover around a
-- baseline, then an event drives accumulative drift for the final 70
-- samples) -- built once here; this section's drift/report and
-- Section 3's dfa/triage read the same fixture. (A pure volatility
-- rescale would NOT work here -- the DFA exponent is scale-invariant,
-- so what the drift report reliably flags is exactly this
-- memory-structure change, hovering -> accumulating, in the recent
-- window -- the same construction demo-vertical-quant-finance.sql's
-- 300-point regime fixture documents.)
--
-- Two phases, deliberately:
--   * t <= 170 -- readings HOVER around the baseline (white noise,
--     DFA ~0.5, uncorrelated).
--   * t > 170  -- the event: readings ACCUMULATE, each sample drifting
--     further from the baseline (a trending run, DFA ~2.0).
-- The event's increments carry a small upward drift (pollution building
-- up, not just jitter), which is what makes the recent window's
-- persistence read clearly above the baseline's rather than marginally.
-- The event phase continues from the last hovering reading, so the
-- series carries no artificial level jump at t=171.
DROP TABLE IF EXISTS vsc_aq_series;
DROP TABLE IF EXISTS vsc_aq_raw;
CREATE TEMP TABLE vsc_aq_raw AS
SELECT t,
       CASE WHEN t <= 170 THEN (vsc_rand(20000 + t)-0.5)*0.02
            ELSE (vsc_rand(20000 + t)-0.5)*0.16 + 0.03 END AS step
FROM generate_series(1, 240) t(t);

CREATE TEMP TABLE vsc_aq_series AS
SELECT array_agg(x ORDER BY t) AS series
FROM (
    SELECT t,
           CASE WHEN t <= 170 THEN step
                ELSE (SELECT step FROM vsc_aq_raw WHERE t = 170)
                     + sum(CASE WHEN t > 170 THEN step ELSE 0 END)
                       OVER (ORDER BY t ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
           END AS x
    FROM vsc_aq_raw
) q;

SELECT fractal_morphological_complexity(
    (SELECT array_agg(v ORDER BY id, ord) FROM vsc_sensors, LATERAL unnest(pos) WITH ORDINALITY AS u(v, ord)),
    2
) AS coverage_complexity;
SELECT fractal_dimension_drift(
    (SELECT series FROM vsc_aq_series),
    48
) AS drift_report;
SELECT abs(fractal_dimension_drift((SELECT series FROM vsc_aq_series), 48).drift)
           AS drift_detected;

-- The shipped preset (a scalar returning one JSON document:
-- {morph_dimension, lacunarity, drift_detected, rationale}, with
-- rationale as the one folded reasoning step):
SELECT fractal_agent_network_coverage_alert(
    (SELECT array_agg(v ORDER BY id, ord) FROM vsc_sensors, LATERAL unnest(pos) WITH ORDINALITY AS u(v, ord)),
    (SELECT series FROM vsc_aq_series),
    2, 48, 0.5);

-- ------------------------------------------------------------------
-- 3. fractal_dimension_dfa / fractal_dimension_drift: sensor 112's
-- air-quality reading series carries a deliberate regime shift (an
-- event) at t=171 of 240 samples.
-- ------------------------------------------------------------------
.print
.print === 3. fractal_dimension_dfa/_drift: air-quality event detection ===

-- Blueprint (raw primitives), executed: the air-quality series' long-
-- range-correlation exponent (DFA) and its regime-change drift report --
-- both over the same shared vsc_aq_series fixture Section 2 built.
-- Generalized below by the shipped fractal_agent_regime_triage preset,
-- which runs both over the same series and reasons.
SELECT fractal_dimension_dfa(
    (SELECT series FROM vsc_aq_series)
) AS air_quality_dfa_exponent;
SELECT fractal_dimension_drift(
    (SELECT series FROM vsc_aq_series),
    48
) AS drift_report;
SELECT abs(fractal_dimension_drift((SELECT series FROM vsc_aq_series), 48).drift)
           AS drift_detected;

-- fractal_agent_regime_triage is one of the 16 NAMED domain agents, and
-- registers with the extension itself.
-- The shipped preset (a scalar returning one JSON document:
-- {dfa_exponent, drift_detected, recent_alpha, baseline_alpha,
-- rationale}, with rationale as the folded reasoning step):
SELECT fractal_agent_regime_triage(
    (SELECT series FROM vsc_aq_series),
    64, 0.5);

-- ------------------------------------------------------------------
-- 4. Scout Discovery: diverse representative sample of reading
-- profiles across the grid -- "what KINDS of zones do we actually
-- have" (quiet-residential vs. high-traffic-commercial vs. ...) rather
-- than scanning all 400 sensors by hand.
-- ------------------------------------------------------------------
.print
.print === 4. fractal_search_explore: diverse zone reading-profiles ===
.print --- raw explore form (query-agnostic -- explore samples the space) ---

-- Blueprint (raw primitive), executed: returns a diverse representative
-- set of reading-profile embeddings -- "what KINDS of zones do we have".
SELECT particle FROM fractal_search_explore(
    'vsc_sensors', 'reading', ARRAY[0,0,0]::float8[],
    '{"population_size": 6, "iterations": 8, "walk": 0}'
);

-- Productized preset: the shipped engine (a scalar returning one JSON
-- document -- an array of {item_id, score} rows, score = 1 -
-- cosine_distance) enables session-global repulsion on the shared engine
-- context, then leaves it on (the caller owns that policy). The
-- blueprint's zero query is query-agnostic (explore samples the space);
-- recommend_diverse is query-anchored (nearest-neighbor top-k), so anchor on
-- the first sensor's own reading -- the nearest result is itself (score 1)
-- and the rest are a repulsion-diverse spread. There is no SQL toggle for
-- the engine context (the registered fractal_diversify_disable() acts on
-- the ledger's own context, a different session).
.print --- Preset: fractal_agent_recommend_diverse (query-anchored) ---
SELECT fractal_agent_recommend_diverse(
    'vsc_sensors', 'reading',
    (SELECT reading::float8[] FROM vsc_sensors ORDER BY id LIMIT 1),
    6, 'id');
-- Table-function args are constant-only in DuckDB: the probe vector
-- spools through the .once/.read idiom:
.mode list
.headers off
.output vsc_tel.sql
SELECT 'SELECT doc_id, distance FROM fractal_search_telemetry(''vsc_sensors'', ''reading'', ' ||
       (SELECT reading FROM vsc_sensors ORDER BY id LIMIT 1)::VARCHAR ||
       ', 6) ORDER BY distance ASC;'
;
.output stdout
.mode box
.headers on
.read vsc_tel.sql

-- ------------------------------------------------------------------
-- 5. Reasoning: the city-ops narrative over coverage + drift is now
-- produced by the fractal_agent_network_coverage_alert preset's
-- rationale key in Section 2 (the same coverage morphological
-- complexity + air-quality drift, folded into one reasoning step).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: absorbed into the Section 2 network_coverage_alert rationale ===

-- ------------------------------------------------------------------
-- 6. Headline check: the demo's own claims, recomputed from the demo's
-- own tables and calls -- the 400-sensor grid really does cover the
-- plane evenly (box-counting dimension well above 1.5, lacunarity
-- under 2.0), and the air-quality event really does show up as a
-- memory-structure change (recent window more persistent than the
-- baseline, DFA exponent above the uncorrelated 1.0).
-- ------------------------------------------------------------------
.print
.print === 6. Headline check ===
.mode list
.headers off
SELECT 'HEADLINE kit=smart-cities-iot ' || CASE WHEN
    (SELECT count(*) FROM vsc_sensors) = 400
    AND (SELECT fractal_morphological_complexity(
            (SELECT array_agg(v ORDER BY id, ord)
               FROM vsc_sensors, LATERAL unnest(pos) WITH ORDINALITY AS u(v, ord)),
            2).dimension) > 1.5
    AND (SELECT fractal_morphological_complexity(
            (SELECT array_agg(v ORDER BY id, ord)
               FROM vsc_sensors, LATERAL unnest(pos) WITH ORDINALITY AS u(v, ord)),
            2).lacunarity) < 2.0
    AND (SELECT fractal_dimension_drift(
            (SELECT series FROM vsc_aq_series), 48).recent_alpha)
        > (SELECT fractal_dimension_drift(
            (SELECT series FROM vsc_aq_series), 48).baseline_alpha)
    AND (SELECT fractal_dimension_dfa(
            (SELECT series FROM vsc_aq_series))) > 1.0
  THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vsc_sensors;
.print (the vsc_* TEMP tables evaporate with the connection.)
.print ================================================================
