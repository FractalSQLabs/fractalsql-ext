-- demo/demo-vertical-quant-finance.sql
--
-- Industry vertical: Quantitative Finance & Algorithmic Trading.
--
-- A cardinality-constrained portfolio problem (25 synthetic assets, a
-- 4-factor covariance model, optimize down to an 8-asset book) plus a
-- price series with a deliberate range-bound -> trending regime change
-- at t=240 for DFA-based regime detection -- a real, established DFA
-- application (detecting when a market series stops behaving like its
-- own recent history) -- and change-point detection to localize exactly
-- where that shift happens, rather than only characterizing the series'
-- overall scaling.
--
-- Prerequisites: extension installed. Sections 3 and 4 dispatch reasoning
-- through the domain agents (the raw blueprint forms alongside them run
-- without an endpoint) -- see ../docs/reasoning-setup.md.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; \
--     cat demo/demo-vertical-quant-finance.sql; } | duckdb -unsigned mydb.duckdb
-- (without -bail: the shipped preset calls' reasoning legs need the
-- reasoning endpoint configured -- without one the shell prints the
-- clean error and the remaining statements still run.)
--
-- Safe to re-run: vqf_* tables are dropped and recreated each time.

-- Notes:
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=quant-finance ok);
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
-- assets, the factor loadings and the price series (and with them the
-- optimiser's heaviest holding, which the headline check pins) came out
-- different on a different machine. Deriving every draw from the row
-- id instead makes the fixture a pure function of the data: the same
-- book on every machine, core count and DuckDB build.
-- The xor-shift rounds are not decoration: a plain LCG is AFFINE in
-- its seed, so two seeds one apart differ by a CONSTANT amount --
-- "separate" dimensions drawn from adjacent seeds came out as mirror
-- images of each other, and a 2-D walk built that way collapses onto a
-- line. The xor-shift breaks that affinity, so neighbouring seeds give
-- genuinely unrelated draws.
CREATE OR REPLACE MACRO vqf_lcg(s) AS ((((s::BIGINT * 1103515245::BIGINT) + 12345) % 2147483648));
CREATE OR REPLACE MACRO vqf_xs(a, sh) AS (xor(a, a >> sh));
CREATE OR REPLACE MACRO vqf_mix(s) AS (vqf_xs(vqf_lcg(vqf_xs(vqf_lcg(s), 13)), 17));
CREATE OR REPLACE MACRO vqf_rand(s) AS (vqf_mix(s)::DOUBLE / 2147483648.0);

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 25 synthetic assets, 4-factor covariance model (same construction
-- style as the core library's own portfolio-optimizer factor-model test
-- fixture): cov[i,j] = sum_f loadings[i,f]*loadings[j,f] + idio[i] on
-- the diagonal. mu is each asset's expected return.
-- ------------------------------------------------------------------
.print
.print === 1. 25 synthetic assets, 4-factor covariance model ===

DROP TABLE IF EXISTS vqf_assets;
DROP TABLE IF EXISTS vqf_loadings;
CREATE TABLE vqf_assets (asset_id int PRIMARY KEY, symbol text, mu float8, idio float8);
CREATE TABLE vqf_loadings (asset_id int, factor_id int, loading float8, PRIMARY KEY (asset_id, factor_id));

INSERT INTO vqf_assets (asset_id, symbol, mu, idio)
SELECT a, 'TICK' || a, -0.02 + vqf_rand(a * 2 + 1) * 0.17, 0.02 + vqf_rand(a * 2 + 2) * 0.06
FROM generate_series(1, 25) a(a);

INSERT INTO vqf_loadings (asset_id, factor_id, loading)
SELECT a.asset_id, f, (vqf_rand(1000 + a.asset_id * 10 + f) - 0.5) * 0.6
FROM vqf_assets a
CROSS JOIN generate_series(1, 4) f(f);

-- Flat, row-major n*n covariance array -- exactly what
-- fractal_optimize_portfolio(mu, cov, k, seed) expects.
DROP TABLE IF EXISTS vqf_cov_flat;
CREATE TEMP TABLE vqf_cov_flat AS
SELECT ai.asset_id AS i, aj.asset_id AS j,
       (SELECT sum(li.loading * lj.loading)
          FROM vqf_loadings li, vqf_loadings lj
         WHERE li.asset_id = ai.asset_id AND lj.asset_id = aj.asset_id
           AND li.factor_id = lj.factor_id)
       + CASE WHEN ai.asset_id = aj.asset_id THEN ai.idio ELSE 0 END AS cov_ij
FROM vqf_assets ai
CROSS JOIN vqf_assets aj;

SELECT count(*) AS assets, (SELECT count(*) FROM vqf_cov_flat) AS cov_entries FROM vqf_assets;

-- ------------------------------------------------------------------
-- 2. Cardinality-constrained Sharpe-ratio optimization: pick the best
-- 8 of 25 assets. ~28x faster than scipy differential_evolution at
-- near-equal quality on this problem class (validated separately,
-- see the core library's optimizer work) -- the one place the SFS
-- engine has a proven edge.
-- ------------------------------------------------------------------
.print
.print === 2. fractal_optimize_portfolio: best 8-of-25 asset book ===

-- Blueprint (raw primitive): the SFS cardinality-constrained Sharpe
-- maximizer (pick the best 8 of 25 assets). cov must be a FLATTENED
-- 1-D array of length n_assets^2, row-major -- fractal_optimize rejects
-- a 2-D matrix -- which is exactly what vqf_cov_flat's ORDER BY i, j
-- below assembles. Returns one STRUCT {sharpe, weights}; weights are a
-- 25-element list in asset_id order, mostly zero for a k=8 book.
-- Generalized by the shipped fractal_agent_rebalance_sibling preset in
-- Section 4, which runs this same optimizer, finds the nearest
-- historical allocation pattern (fractal_search_trajectory over the
-- Section 4 snapshot fixture), and reasons -- so the preset call sits
-- after that fixture is built.
DROP TABLE IF EXISTS vqf_result;
CREATE TEMP TABLE vqf_result AS
SELECT fractal_optimize_portfolio(
    (SELECT array_agg(mu ORDER BY asset_id) FROM vqf_assets),
    (SELECT array_agg(cov_ij ORDER BY i, j) FROM vqf_cov_flat),
    8, 42
) AS result;

SELECT result.sharpe AS sharpe FROM vqf_result;

.print --- the optimized 8-asset book ---
-- (Temp table + unnest WITH ORDINALITY -- the same book listing in
-- native types. asset_id is 1-based per the seed above, and ordinality
-- counts from 1 in document order.)
SELECT a.symbol, w.weight
FROM vqf_result r
CROSS JOIN LATERAL unnest(r.result.weights) WITH ORDINALITY AS w(weight, ord)
JOIN vqf_assets a ON a.asset_id = w.ord
WHERE w.weight > 1e-9
ORDER BY w.weight DESC;

-- ------------------------------------------------------------------
-- 3. A 300-point price series with a deliberate regime change at
-- t=240: range-bound (mean-reverting, stationary) for most of its
-- history, then a genuine trending run for the final 60 bars --
-- fractal_dimension_dfa's self-check pattern (white noise ~0.5, random
-- walk ~1.5) applied to something with an actual regime change baked
-- in, and fractal_dimension_drift(series, win) to detect it
-- automatically rather than eyeballing the exponent. (A pure
-- volatility rescale would NOT work here -- the DFA exponent is
-- scale-invariant, so a variance change barely moves it; what the
-- drift report reliably flags is exactly this memory-structure change,
-- mean reversion -> trend, in the recent window.)
-- ------------------------------------------------------------------
.print
.print === 3. Price series: range-bound -> trending regime change at t=240 ===

-- Two-stage fixture: raw steps first (every row's own seeded draw,
-- flat -- no subquery hoisting), then the walk-only accumulation:
-- before t=240 each bar is independent small noise (white noise,
-- DFA ~0.5); from t=240 the increments accumulate (a ~60-bar trending
-- run, DFA ~1.5).
DROP TABLE IF EXISTS vqf_price_raw;
DROP TABLE IF EXISTS vqf_price_series;
CREATE TEMP TABLE vqf_price_raw AS
SELECT t, (vqf_rand(2000 + t) - 0.5) * 0.1 AS step
FROM generate_series(1, 300) t(t);
CREATE TEMP TABLE vqf_price_series AS
SELECT array_agg(x ORDER BY t) AS series
FROM (
    SELECT t,
           CASE WHEN t < 240 THEN step
                ELSE 100.0 + sum(CASE WHEN t >= 240 THEN step END)
                       OVER (ORDER BY t ROWS BETWEEN 60 PRECEDING AND CURRENT ROW)
           END AS x
    FROM vqf_price_raw
) s;

-- Blueprint: the price series' DFA exponent (long-range correlation)
-- and its drift report (regime-change detection). The
-- fractal_agent_regime_triage preset generalizes exactly this pair.
SELECT fractal_dimension_dfa(series) AS whole_series_alpha FROM vqf_price_series;
SELECT fractal_dimension_drift(series, 64) AS drift_report FROM vqf_price_series;
SELECT abs(fractal_dimension_drift(series, 64).drift) > 0.5
           AS drift_detected FROM vqf_price_series;

-- The shipped preset (a scalar returning one JSON document:
-- {dfa_exponent, drift_detected, recent_alpha, baseline_alpha,
-- rationale}, with rationale as the folded reasoning step):
SELECT fractal_agent_regime_triage(
    (SELECT series FROM vqf_price_series),
    64, 0.5);

-- fractal_change_point_detect: DFA/drift above characterize the series'
-- OVERALL scaling behavior and flag THAT something shifted; this
-- localizes WHERE. A sliding two-sample mean/variance test over the
-- same 300-point series -- expected to land near t=240, the deliberate
-- regime boundary. Original work, not a port of a specific published
-- algorithm (e.g. not CUSUM/Page-Hinkley), so no citation.
.print
.print === 3b. fractal_change_point_detect: localizing the regime boundary ===
SELECT fractal_change_point_detect(
    (SELECT series FROM vqf_price_series),
    20, 1.5, 8
) AS boundary_indices;

-- ------------------------------------------------------------------
-- 4. fractal_search_trajectory: which of 10 historical quarterly
-- rebalance snapshots does THIS rebalance (equal-weight baseline ->
-- the optimized book from Section 2) most resemble? "What changed",
-- not "what's closest" -- the natural query shape for drift.
-- ------------------------------------------------------------------
.print
.print === 4. fractal_search_trajectory: nearest historical rebalance pattern ===

DROP TABLE IF EXISTS vqf_allocation_snapshots;
-- float8[25], not a fractal_vector catalog type -- this build has none
-- (see docs/api-analytics.md). float8/DOUBLE since alloc
-- only ever feeds fractal_search_trajectory below. Fixed width (one
-- weight per asset), same dimension-safety argument as the other
-- updated verticals. INSERT below is unchanged (::float8[] via
-- array_agg) -- the assignment cast coerces it on write.
DROP SEQUENCE IF EXISTS seq_vqf_allocation_snapshots_id;
CREATE SEQUENCE seq_vqf_allocation_snapshots_id;
CREATE TABLE vqf_allocation_snapshots (id INTEGER PRIMARY KEY DEFAULT nextval('seq_vqf_allocation_snapshots_id'), quarter text, alloc float8[25]);

-- Flat CROSS JOIN, not ARRAY(subquery) -- an uncorrelated subquery body
-- (one that never references the outer generate_series(1,10) row) gets
-- hoisted into a one-shot InitPlan and evaluated ONCE for the whole
-- INSERT, silently making every "quarter" identical. See
-- demo/benchmark.sql's own comment on this same trap. A flat cross join
-- has no nested subquery to hoist -- every (snapshot, asset) pair gets
-- its own seeded draw, provably.
CREATE TEMP TABLE vqf_snapshot_raw AS
SELECT gs AS snapshot_id, a.asset_id,
       CASE WHEN vqf_rand(3000 + gs * 100 + a.asset_id * 2 + 1) < 0.35
            THEN vqf_rand(3000 + gs * 100 + a.asset_id * 2 + 2) ELSE 0 END AS raw_val
FROM generate_series(1, 10) gs(gs)
CROSS JOIN vqf_assets a;

CREATE TEMP TABLE vqf_snapshot_sums AS
SELECT snapshot_id, GREATEST(sum(raw_val), 1e-9) AS total
FROM vqf_snapshot_raw
GROUP BY snapshot_id;

INSERT INTO vqf_allocation_snapshots (quarter, alloc)
SELECT 'Q' || r.snapshot_id || '-hist',
       array_agg(r.raw_val / s.total ORDER BY r.asset_id)
FROM vqf_snapshot_raw r
JOIN vqf_snapshot_sums s ON s.snapshot_id = r.snapshot_id
GROUP BY r.snapshot_id, s.total
ORDER BY r.snapshot_id ASC;

-- Blueprint (raw primitive), executed: the nearest historical rebalance
-- pattern to the optimized book (equal-weight baseline -> the Section 2
-- optimized weights). Generalized below by the shipped fractal_agent_
-- rebalance_sibling preset, which runs the optimizer itself, finds this
-- nearest pattern, and reasons. (id_col is the snapshot's bigint id, not
-- its text quarter label -- the engine resolves the nearest id as a
-- bigint. trajectory's doc_id is the 0-INDEXED SCAN POSITION, so the
-- snapshot rows map through row_number() over rowid - 1 -- the same
-- convention demo-agents.sql's section 13a join uses.) Table-function
-- args are constant-only in DuckDB, so the equal-weight baseline and the
-- optimizer weights roundtrip through the .once/.read spool (the
-- demo-agents.sql 13a idiom):
.mode list
.headers off
.output vqf_traj.sql
SELECT 'SELECT snap.quarter, t.distance '
       'FROM fractal_search_trajectory(''vqf_allocation_snapshots'', ''alloc'', '
       || CAST((SELECT array_agg(1.0 / 25.0 ORDER BY asset_id) FROM vqf_assets) AS VARCHAR) ||
       '::float8[], '
       || CAST((SELECT result.weights FROM vqf_result) AS VARCHAR) ||
       '::float8[], 3) t '
       'JOIN (SELECT quarter, row_number() OVER (ORDER BY rowid) - 1 AS doc_id '
       'FROM vqf_allocation_snapshots) snap ON snap.doc_id = t.doc_id '
       'ORDER BY t.distance'
;
.output stdout
.mode box
.headers on
.mode box
.read vqf_traj.sql

-- fractal_agent_rebalance_sibling is one of the 16 NAMED domain agents,
-- and registers with the extension itself. Its optimizer primitive alone
-- runs below as the blueprint (the agent runs it again over the same
-- mu/cov, folds in the nearest-historical-allocation trajectory lookup,
-- and one reasoning step):
SELECT r.sharpe, r.weights FROM (
    SELECT fractal_optimize_portfolio(
        (SELECT array_agg(mu ORDER BY asset_id) FROM vqf_assets),
        (SELECT array_agg(cov_ij ORDER BY i, j) FROM vqf_cov_flat),
        8
    ) AS r
);

-- The shipped preset (a scalar returning one JSON document:
-- {sharpe, weights, nearest_alloc_id, nearest_distance, rationale};
-- seed arg 42 pins the optimizer for reproducibility):
CREATE OR REPLACE TEMP TABLE vqf_rebal AS
SELECT fractal_agent_rebalance_sibling(
    (SELECT array_agg(mu ORDER BY asset_id) FROM vqf_assets),
    (SELECT array_agg(cov_ij ORDER BY i, j) FROM vqf_cov_flat),
    8, 'vqf_allocation_snapshots', 'alloc',
    (SELECT array_agg((1.0 / 25.0)::float8 ORDER BY asset_id) FROM vqf_assets),
    42, 5, 'id', '{}'::text) AS rebalance;
SELECT rebalance FROM vqf_rebal;

-- ------------------------------------------------------------------
-- 5. Reasoning: the regime-shift + optimized-allocation narrative is now
-- split across two preset rationales -- fractal_agent_regime_triage
-- (Section 3, the market regime shift) and fractal_agent_rebalance_sibling
-- (Section 4, the optimized book + its nearest historical pattern).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: absorbed into the Section 3 + Section 4 preset rationales ===
-- The narrative is split across the two preset rationales above; this
-- standalone closing call reasons over the rebalance findings directly:
SELECT fractal_reason('one-line rationale tying this market regime shift to the optimized 8-asset rebalance and its nearest historical pattern',
    (SELECT to_json(r)::text FROM vqf_rebal r));

-- ------------------------------------------------------------------
-- 6. Headline check: the demo's own claims, recomputed from the demo's
-- own tables and calls -- the Section 2 optimizer really does return a
-- Sharpe > 1.0 book of exactly 8 of the 25 assets (TICK14 the heaviest
-- holding), and fractal_change_point_detect really does localize the
-- deliberate t=240 regime boundary built into the Section 3 series.
--
-- The book is exact because the fixture is reproducible: it is generated
-- from the row id (see the vqf_rand macro at the top of this file), so the
-- same assets, loadings and price series -- and therefore the same book --
-- come out on every machine, core count and DuckDB build.
-- ------------------------------------------------------------------
.print
.print === 6. Headline check ===
.mode list
.headers off
SELECT 'HEADLINE kit=quant-finance ' || CASE WHEN
    (SELECT result.sharpe FROM vqf_result) > 1.0
    AND (SELECT count(*)
           FROM vqf_result r
           CROSS JOIN LATERAL unnest(r.result.weights) WITH ORDINALITY AS w(weight, ord)
          WHERE w.weight > 1e-9) = 8
    AND (SELECT a.symbol
           FROM vqf_result r
           CROSS JOIN LATERAL unnest(r.result.weights) WITH ORDINALITY AS w(weight, ord)
           JOIN vqf_assets a ON a.asset_id = w.ord
          WHERE w.weight > 1e-9
          ORDER BY w.weight DESC
          LIMIT 1) = 'TICK14'
    AND (SELECT count(*)
           FROM (SELECT fractal_change_point_detect(
                    (SELECT series FROM vqf_price_series), 20, 1.5, 8) AS cps) t
           CROSS JOIN LATERAL unnest(t.cps) WITH ORDINALITY AS b(v, ord)
          WHERE b.v = 240) = 1
  THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vqf_assets;
.print   DROP TABLE vqf_loadings;
.print   DROP TABLE vqf_allocation_snapshots;
.print (the vqf_* TEMP tables evaporate with the session; one TABLE per
.print statement -- DuckDB's DROP TABLE takes a single table.)
.print ================================================================
