-- demo/benchmark-api-reference.sql
--
-- A coverage pass over the callable families this build registers:
-- 95 functions across 12 families (see sql/function-surface.sql for
-- the full categorized listing). This script exercises the non-agent
-- core families -- 42 of them -- grouped the same way that listing
-- groups them. Distinct from demo/benchmark.sql, which stays scoped to
-- its own narrower Sniper/Scout/vectorizer comparison (see that file's
-- own header comment) -- this one's job is coverage, not a head-to-head
-- comparison.
--
-- (The rest of the registered surface is exercised elsewhere: the
-- sixteen domain agents and the remaining agent entry points in
-- demo/demo-agents.sql, the ledger/audit functions in the enterprise
-- demos, the plain-vector math in demo/demo-fractal-vector.sql,
-- fractal_optimize_subset in demo/demo-vertical-agentic-edge-swarm.sql,
-- the portfolio/agent-family surfaces the vertical demos cover, and
-- the vectorizer status/drop pair in demo/demo-vectorizer.sql.)
--
-- Fixtures are deliberately small and reused across sections -- this is
-- a correctness-plus-latency smoke pass over the whole API surface, not
-- a scale benchmark (see ../bench/ for the real HNSW-vs-Scout scale
-- evaluation behind docs/features.md's numbers). Reasoning-dependent
-- calls (fractal_reason, fractal_text_to_sql, fractal_embed) are
-- called directly: a missing/misconfigured reasoning endpoint makes
-- those rows print the clean "reasoning plugin not configured" hint
-- instead of returning values.
--
-- Run without -bail: see the reasoning-gating note below.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; \
--     cat demo/benchmark-api-reference.sql; } | duckdb -unsigned mydb.duckdb
--
-- Safe to re-run: bmk_* tables are dropped and recreated each time.

-- (Timing is omitted -- DuckDB's CLI has no per-statement
-- timing dot-command; measure latency at the harness level, e.g.
-- demo/demo-workload.sh.)
-- The fixture generator: an LCG with xor-shift rounds over pure integer
-- arithmetic, so every draw is exactly the same everywhere.
--
-- setseed() would not do: it seeds only the engine of the thread that
-- called it, and every other DuckDB worker thread runs its own random()
-- stream, so a fixture query DuckDB spreads over several threads hands
-- each row a value from a different stream -- and the corpus, the
-- dimension fixtures and the change-point series came out different on a
-- different machine. Deriving every draw from the row id instead makes
-- each fixture a pure function of the data.
-- The xor-shift rounds are not decoration: a plain LCG is AFFINE in
-- its seed, so two seeds one apart differ by a CONSTANT amount --
-- "separate" dimensions drawn from adjacent seeds came out as mirror
-- images of each other, and a 2-D walk built that way collapses onto a
-- line. The xor-shift breaks that affinity, so neighbouring seeds give
-- genuinely unrelated draws.
CREATE OR REPLACE MACRO bmk_lcg(s) AS ((((s::BIGINT * 1103515245::BIGINT) + 12345) % 2147483648));
CREATE OR REPLACE MACRO bmk_xs(a, sh) AS (xor(a, a >> sh));
CREATE OR REPLACE MACRO bmk_mix(s) AS (bmk_xs(bmk_lcg(bmk_xs(bmk_lcg(s), 13)), 17));
CREATE OR REPLACE MACRO bmk_rand(s) AS (bmk_mix(s)::DOUBLE / 2147483648.0);

-- Reasoning-dependent calls in section 2 are exercised directly.
-- Plain DuckDB SQL has no exception-handling construct at all (no
-- procedural SQL, no try/catch around an arbitrary function call), so
-- there is nothing to wrap them in: if reasoning isn't configured, the
-- shell prints the clean error and continues (run this script WITHOUT
-- -bail, as below), so the affected rows show as errors and every
-- other section still exercises. The only calls commented out
-- entirely are the unimplemented feature-store pair in section 8 --
-- those abort the run even without -bail, so they stay out until the
-- gap closes. A host script (Python/Node/R against the duckdb client
-- library) could catch a reasoning error per call and continue --
-- not attempted in this .sql-only pass.

.print ================================================================
.print FractalSQL full-API-reference benchmark -- one pass over the
.print non-agent core families (42 of the 95 callable functions this
.print build registers), grouped by category.
.print ================================================================

-- ------------------------------------------------------------------
-- 0. Meta (2 functions)
-- ------------------------------------------------------------------
.print
.print === Meta: fractal_edition, fractal_version ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Search (3 functions)
-- ------------------------------------------------------------------
.print
.print === Search: fractal_sfs_converge, fractal_sfs_converge_debug ===

DROP TABLE IF EXISTS bmk_corpus;
DROP SEQUENCE IF EXISTS seq_bmk_corpus_id;
CREATE SEQUENCE seq_bmk_corpus_id;
CREATE TABLE bmk_corpus (id INTEGER PRIMARY KEY DEFAULT nextval('seq_bmk_corpus_id'), emb_arr float8[]);
INSERT INTO bmk_corpus (emb_arr)
SELECT ARRAY[bmk_rand(gs * 10 + 1)*2-1, bmk_rand(gs * 10 + 2)*2-1,
             bmk_rand(gs * 10 + 3)*2-1, bmk_rand(gs * 10 + 4)*2-1,
             bmk_rand(gs * 10 + 5)*2-1, bmk_rand(gs * 10 + 6)*2-1,
             bmk_rand(gs * 10 + 7)*2-1, bmk_rand(gs * 10 + 8)*2-1]::float8[]
FROM generate_series(1, 100) gs(gs);

-- Query vectors in this file are small NONZERO points, never the
-- origin -- cosine similarity is undefined for a zero vector (the
-- adversarial case demo/demo-business-intelligence.sql's Section 6
-- documents).

-- DuckDB scalar functions take positional args only (no `name => value`).
SELECT fractal_sfs_converge(ARRAY[0.6,0.8,0,0,0,0,0,0]::float8[], 30);
-- fractal_sfs_converge_debug returns a JSON-formatted VARCHAR (a plain
-- string, no native JSON type) -- printed whole here; demo/
-- demo-agents.sql's section 12a pulls one field out with json_extract().
SELECT fractal_sfs_converge_debug(ARRAY[0.6,0.8,0,0,0,0,0,0]::float8[], 10, 50, 2);

.print
.print === Search: fractal_search_explore ===
SELECT count(*) AS scout_population FROM fractal_search_explore(
    'bmk_corpus', 'emb_arr', ARRAY[0.2,0.1,0,0,0,0,0,0]::float8[],
    '{"population_size": 6, "iterations": 6, "walk": 0}'
) AS p;

-- ------------------------------------------------------------------
-- 2. Reasoning / text-to-SQL / embedding (5 functions)
-- ------------------------------------------------------------------
.print
.print === Reasoning: fractal_reason, fractal_schema_context, fractal_text_to_sql,
.print fractal_sql_agent, fractal_embed ===

SELECT fractal_reason('reply with a one-word confirmation', '{}') AS reason_result;
SELECT left(fractal_schema_context(ARRAY['bmk_corpus'], NULL), 80) AS schema_context_result;
SELECT fractal_text_to_sql('how many rows are in bmk_corpus?', ARRAY['bmk_corpus']) AS text_to_sql_result;

-- fractal_sql_agent runs the demo-business-intelligence loop
-- (generate -> execute against the listed tables -> narrate) as one
-- call -- see demo/demo-agents.sql's section 9 for the walkthrough.
SELECT * FROM fractal_sql_agent('how many rows are in bmk_corpus?',
    ['bmk_corpus'], 2, true) AS sql_agent_result;

SELECT len(fractal_embed('a short benchmark sentence')) AS embed_dim;

-- ------------------------------------------------------------------
-- 3. Vectorizer (4 functions)
-- ------------------------------------------------------------------
.print
.print === Vectorizer: fractal_vectorizer_create, fractal_vectorizer_process_queue,
.print fractal_vectorizer_pause, fractal_vectorizer_resume ===

-- The registry tables are created on the extension's first vectorizer
-- call, so on a fresh database they do not exist yet and the DELETE
-- below would fail. The status call creates them (and is a no-op
-- afterwards) -- the same bootstrap demo/demo-vectorizer.sql uses.
SELECT count(*) AS registered_vectorizers FROM fractal_vectorizer_status();
DELETE FROM fractal_vectorizers WHERE source_table = 'bmk_docs';
DROP TABLE IF EXISTS bmk_docs;
DROP SEQUENCE IF EXISTS seq_bmk_docs_id;
CREATE SEQUENCE seq_bmk_docs_id;
CREATE TABLE bmk_docs (id INTEGER PRIMARY KEY DEFAULT nextval('seq_bmk_docs_id'), body text NOT NULL, embedding float8[]);
INSERT INTO bmk_docs (body) SELECT 'benchmark document ' || gs FROM generate_series(1, 5) gs(gs);
SELECT fractal_vectorizer_create('bmk_docs', 'id', 'body', 'embedding');
SELECT fractal_vectorizer_process_queue();
-- pause: further writes to bmk_docs stop queueing, process_queue() skips
-- this vectorizer's remaining pending rows -- resume immediately after so
-- the rest of this script (and a re-run) sees normal behavior again.
-- No client-side variable capture in this CLI -- the
-- vectorizer id is re-derivable from the UNIQUE
-- (source_table, text_col, embedding_col) constraint on
-- fractal_vectorizers, so a subquery finds it instead.
SELECT fractal_vectorizer_pause((
    SELECT id FROM fractal_vectorizers
     WHERE source_table = 'bmk_docs' AND text_col = 'body' AND embedding_col = 'embedding'
));
SELECT fractal_vectorizer_resume((
    SELECT id FROM fractal_vectorizers
     WHERE source_table = 'bmk_docs' AND text_col = 'body' AND embedding_col = 'embedding'
));

-- ------------------------------------------------------------------
-- 4. Diversify / Repulsion + Feedback (7 functions)
-- ------------------------------------------------------------------
.print
.print === Diversify/Repulsion + Feedback: enable, set_params, detect_collapse,
.print explain_result, feedback_report, isolate_background, disable ===

SELECT fractal_diversify_enable();
-- Positional only: (window_n, stall_threshold, repulsion_sigma, repulsion_weight, ...);
-- NULL skips a middle field and leaves the core's current value in place.
SELECT fractal_diversify_set_params(5, NULL, 0.3, 0.5);
SELECT t.doc_id FROM generate_series(1, 6) g(g)
CROSS JOIN LATERAL fractal_search_telemetry('bmk_corpus', 'emb_arr', ARRAY[0.2,0.1,0,0,0,0,0,0]::float8[], 3) t;
SELECT fractal_detect_collapse() AS dq;
SELECT fractal_explain_result() AS diagnostics;
SELECT fractal_feedback_report(1, 'positive', 4000);
SELECT fractal_isolate_background(2);
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 5. Fractal dimension analysis (3 functions)
-- ------------------------------------------------------------------
.print
.print === Dimension analysis: fractal_dimension_dfa, _boxcount, _drift ===

SELECT fractal_dimension_dfa(
    (SELECT array_agg(cum ORDER BY t) FROM (
        SELECT t, sum((bmk_rand(1000 + t)-0.5)*0.05) OVER (ORDER BY t) AS cum FROM generate_series(1, 200) t(t)
    ) c)
) AS dfa_alpha;

-- 20x20 jittered grid -- see demo/demo-vertical-sovereign-edge-ai.sql's own
-- comment on why box-counting needs a space-filling, not scattered,
-- fixture to find >= 3 valid eps-octaves.
SELECT fractal_dimension_boxcount(
    (SELECT array_agg(v ORDER BY r, c, ord)
       FROM generate_series(0, 19) r(r)
       CROSS JOIN generate_series(0, 19) c(c)
       CROSS JOIN LATERAL unnest(ARRAY[r + (bmk_rand(3000 + r * 100 + c * 2 + 1)-0.5)*0.3,
                                      c + (bmk_rand(3000 + r * 100 + c * 2 + 2)-0.5)*0.3]) WITH ORDINALITY AS u(v, ord)),
    2
) AS boxcount_dimension;

SELECT fractal_dimension_drift(
    (SELECT array_agg(cum ORDER BY t) FROM (
        SELECT t, sum((bmk_rand(2000 + t)-0.5)*0.05) OVER (ORDER BY t) AS cum FROM generate_series(1, 100) t(t)
    ) c),
    32
) AS drift_report;

-- ------------------------------------------------------------------
-- 6. Portfolio optimization (1 function)
-- ------------------------------------------------------------------
.print
.print === Portfolio: fractal_optimize_portfolio ===

SELECT fractal_optimize_portfolio(
    ARRAY[0.05,0.08,0.03,0.12,0.07,0.01]::float8[],
    ARRAY[0.02,0,0,0,0,0, 0,0.03,0,0,0,0, 0,0,0.04,0,0,0,
          0,0,0,0.05,0,0, 0,0,0,0,0.06,0, 0,0,0,0,0,0.07]::float8[],
    2, 42
) AS allocation;

-- ------------------------------------------------------------------
-- 7. Domain-specific geometry (4 functions)
-- ------------------------------------------------------------------
.print
.print === Domain geometry: fractal_vascular_network, _cortical_folding,
.print _nerve_plexus_metric, fractal_morphological_complexity ===

-- 28-node chain + 2 branch leaves -- see demo/demo-vertical-medtech-clinical.sql
-- for why this scale (not a handful of nodes) is needed for the
-- internal box-counting step to succeed.
SELECT fractal_vascular_network(
    (SELECT array_agg(v ORDER BY i, ord) FROM generate_series(0, 27) i(i)
       CROSS JOIN LATERAL unnest(ARRAY[i::float8, 0.0, 0.0]) WITH ORDINALITY AS u(v, ord))
    || ARRAY[10, 1, 0, 10, 0, 1]::float8[],
    (SELECT array_agg(v ORDER BY i, ord) FROM generate_series(0, 26) i(i)
       CROSS JOIN LATERAL unnest(ARRAY[i, i + 1]) WITH ORDINALITY AS u(v, ord))::int4[]
    || ARRAY[10, 28, 10, 29]::int4[],
    (SELECT array_agg(1.02) FROM generate_series(0, 28))
) AS vascular;

-- Unit cube surface mesh (8 vertices, 12 faces) -- known-answer
-- reference (GI ~1.0), same fixture demo/demo-vertical-medtech-clinical.sql uses.
SELECT fractal_cortical_folding(
    ARRAY[0,0,0, 1,0,0, 1,1,0, 0,1,0, 0,0,1, 1,0,1, 1,1,1, 0,1,1]::float8[],
    ARRAY[0,1,2, 0,2,3,   4,5,6, 4,6,7,   0,1,5, 0,5,4,
          3,2,6, 3,6,7,   0,3,7, 0,7,4,   1,2,6, 1,6,5]::int4[]
) AS cortical;

SELECT fractal_nerve_plexus_metric(
    (SELECT array_agg(v ORDER BY i, ord) FROM generate_series(0, 79) i(i)
       CROSS JOIN LATERAL unnest(ARRAY[i::float8, 0.05 * sin(i::float8)]) WITH ORDINALITY AS u(v, ord)),
    2,
    (SELECT array_agg(v ORDER BY i, ord) FROM generate_series(0, 78) i(i)
       CROSS JOIN LATERAL unnest(ARRAY[i, i + 1]) WITH ORDINALITY AS u(v, ord))::int4[]
) AS nerve;

SELECT fractal_morphological_complexity(
    (SELECT array_agg(v ORDER BY r, c, ord)
       FROM generate_series(0, 19) r(r)
       CROSS JOIN generate_series(0, 19) c(c)
       CROSS JOIN LATERAL unnest(ARRAY[r + (bmk_rand(4000 + r * 100 + c * 2 + 1)-0.5)*0.3,
                                      c + (bmk_rand(4000 + r * 100 + c * 2 + 2)-0.5)*0.3]) WITH ORDINALITY AS u(v, ord)),
    2
) AS morphology;

-- ------------------------------------------------------------------
-- 8. Named feature store (2 functions) -- NOT YET IMPLEMENTED
-- ------------------------------------------------------------------
-- fractal_store_morphology / fractal_mine_topology_negatives are not
-- registered in this DuckDB build (docs/api-analytics.md
-- explicitly marks them out of scope -- no vendored core equivalent,
-- table-backed and SQL-composable, but not available yet). The two calls
-- below WILL error and abort the rest of this script if left in --
-- DuckDB SQL has no way to catch that and continue past it. Comment
-- them out to run sections 9+ until this gap is closed.
.print
.print === Feature store: fractal_store_morphology, fractal_mine_topology_negatives (SKIPPED -- not implemented) ===

-- SELECT fractal_store_morphology(gs, ARRAY[random(), random(), random()]::float8[])
-- FROM generate_series(1, 10) gs;
-- SELECT doc_id, distance FROM fractal_mine_topology_negatives(ARRAY[0.5,0.5,0.5]::float8[], 3);

-- ------------------------------------------------------------------
-- 9. Table-backed telemetry search family (4 functions)
-- ------------------------------------------------------------------
.print
.print === Telemetry search: fractal_search_telemetry, _hybrid_clinical_search,
.print _search_trajectory, fractal_cross_modal_search ===

SELECT doc_id, distance FROM fractal_search_telemetry(
    'bmk_corpus', 'emb_arr', ARRAY[0.2,0.1,0,0,0,0,0,0]::float8[], 3
);

-- The cohort is the first 20 corpus rows. The postgres port passes
-- (SELECT array_agg(ctid::text) FROM bmk_corpus WHERE id <= 20) for
-- it, but DuckDB table functions take only CONSTANT arguments -- a
-- subquery in one is a binder error ("Table function cannot contain
-- subqueries"). The cohort is therefore spelled out as the rowid
-- strings of the first 20 rows: bmk_corpus is created above with ids
-- 1..100 in insertion order, so rowid is id - 1 and rowids 0..19 are
-- exactly the id <= 20 rows. range() over a lambda is constant-folded
-- by the binder, so this is still a literal, not a correlated query.
SELECT doc_id, distance FROM fractal_hybrid_clinical_search(
    'bmk_corpus', 'emb_arr', ARRAY[0.2,0.1,0,0,0,0,0,0]::float8[],
    list_transform(range(0, 20), lambda i: i::VARCHAR)::VARCHAR[], 3
);

SELECT doc_id, distance FROM fractal_search_trajectory(
    'bmk_corpus', 'emb_arr',
    ARRAY[0.1,0.1,0,0,0,0,0,0]::float8[], ARRAY[0.6,0.5,0,0,0,0,0,0]::float8[], 3
);

DROP TABLE IF EXISTS bmk_modal;
DROP SEQUENCE IF EXISTS seq_bmk_modal_id;
CREATE SEQUENCE seq_bmk_modal_id;
CREATE TABLE bmk_modal (id INTEGER PRIMARY KEY DEFAULT nextval('seq_bmk_modal_id'), combined_vec float8[]);
INSERT INTO bmk_modal (combined_vec)
SELECT ARRAY[bmk_rand(5000 + gs * 10 + 1)*2-1, bmk_rand(5000 + gs * 10 + 2)*2-1,
             bmk_rand(5000 + gs * 10 + 3)*2-1, bmk_rand(5000 + gs * 10 + 4)*2-1]::float8[]
FROM generate_series(1, 20) gs(gs);
SELECT doc_id, distance FROM fractal_cross_modal_search(
    'bmk_modal', 'combined_vec',
    ARRAY[0.5,0.5]::float8[], ARRAY[-0.5,-0.5]::float8[], 0.5, 3
);

-- ------------------------------------------------------------------
-- 10. New analytics + vector quantization (10 functions)
-- ------------------------------------------------------------------
.print
.print === New analytics: fractal_change_point_detect, fractal_periodogram,
.print fractal_spectrogram_entropy, fractal_state_fingerprint, fractal_cycle_detect,
.print fractal_tda_persistence_diagram, fractal_vector_lp_distance,
.print _quantize_int8, _quantize_binary, _hamming_distance ===

-- Regime shift at t=50 (0.0 -> 2.0): expect a boundary near 50.
SELECT fractal_change_point_detect(
    (SELECT array_agg(CASE WHEN t < 50 THEN 0.0 ELSE 2.0 END
                        + (bmk_rand(6000 + t)-0.5)*0.1 ORDER BY t)
       FROM generate_series(1, 100) t(t)),
    16
) AS change_points;

-- Pure 8-sample-period sine: expect the top bin at freq = 0.125 (1/8).
--
-- fractal_periodogram is a DuckDB TABLE function, so -- like
-- fractal_cycle_detect below -- it takes only CONSTANT arguments and
-- cannot be handed a subquery; the series is spelled out as a
-- constant-folded list_transform over range(1, 64) instead.
SELECT freq, power FROM fractal_periodogram(
    list_transform(range(1, 64), lambda t: sin(2*pi()*t/8.0)), 4
);

-- Short-time spectral entropy of the same sine: low (an ordered tone), one
-- value per window. A plain DOUBLE[], so it feeds fractal_change_point_detect
-- directly. Window 16, hop 8 -> 7 frames.
SELECT fractal_spectrogram_entropy(
    (SELECT array_agg(sin(2*pi()*t/8.0) ORDER BY t) FROM generate_series(1, 64) t(t)),
    16, 8
) AS entropy;

SELECT fractal_state_fingerprint(ARRAY[0.1, 0.0]::float8[], 64) AS fingerprint_a;

-- Alternating A/B/A/B/A/B stream: the detector closes the period-2 cycle
-- at index 3 with cycle_len 2, then re-arms and closes another one every
-- three steps (index 6, index 9, ... on a longer stream).
--
-- DuckDB table functions accept only CONSTANT arguments -- a subquery in
-- one is a binder error ("Table function cannot contain subqueries") --
-- so the fingerprint stream is spelled out as a constant-folded
-- list_transform over range(0, 6) instead of being assembled by a query.
-- The fingerprints are the same two the postgres port builds.
SELECT at_index, cycle_len FROM fractal_cycle_detect(
    list_transform(range(0, 6), lambda i: CASE WHEN i % 2 = 0
        THEN fractal_state_fingerprint(ARRAY[0.1, 0.0]::float8[])
        ELSE fractal_state_fingerprint(ARRAY[0.0, 0.1]::float8[]) END),
    0
) AS cycles;

-- Two tight 6-point clusters in dim 2. h0_bars is the single-linkage
-- barcode: here it comes back with 10 bars, all born at 0 -- six dying
-- at 0.05 and four at 0.0707 -- and no bar outlives its own cluster,
-- because the two clusters sit ~7 units apart, far beyond the default
-- max_thresh of 1.0.
-- betti1 is the graph cycle rank: each cluster forms a complete
-- 6-point graph (15 edges) at this scale, so betti1 = 15+15-12+2 = 20
-- -- the informational over-count vs. true H1 the TDA section in
-- docs/api-analytics.md documents (the triangles are not subtracted out).
--
-- In this build fractal_tda_persistence_diagram is a SCALAR function
-- returning a STRUCT {h0_bars, betti1}, not a set-returning function
-- over an implicit row set -- so it is called in the SELECT list and
-- its fields are read off the struct.
SELECT tda.h0_bars AS h0_bars, tda.betti1 AS betti1
-- max_dim=1 asks for the graph cycle-rank estimate alongside the bars.
FROM (SELECT fractal_tda_persistence_diagram(
    ARRAY[0,0, 0.1,0, 0,0.1, 0.1,0.1, 0.05,0.05, 0.1,0.05,
          5,5, 5.1,5, 5,5.1, 5.1,5.1, 5.05,5.05, 5.1,5.05]::float8[], 2, 1, 1.0
) AS tda);

-- p=2 matches fractal_vector_l2_distance mathematically (0.1414 for these
-- vectors); p=0.5 shown for contrast (not a proper metric, use
-- explicitly). These functions take LIST(FLOAT), so bracket
-- literals cast to ::float4[] directly (see
-- docs/api-analytics.md).
SELECT
    fractal_vector_lp_distance(
        '[1,0,0]'::float4[],
        '[0.9,0.1,0]'::float4[], 2.0::float4) AS lp2_distance,
    fractal_vector_lp_distance(
        '[1,0,0]'::float4[],
        '[0.9,0.1,0]'::float4[], 0.5::float4) AS lp_half_distance;

-- 4x / 32x compression: bit i = (v[i] >= 0), so a and b differ in
-- exactly one sign bit -> Hamming distance 1.
SELECT json_extract(q8, '$.scale') AS scale,
       json_extract(q8, '$.codes') AS codes
FROM (SELECT fractal_vector_quantize_int8('[1,-2,3]'::float4[]) AS q8) t;
SELECT fractal_vector_quantize_binary('[1,-2,3]'::float4[]) AS binary_a,
       fractal_vector_quantize_binary('[1,2,3]'::float4[])  AS binary_b;
SELECT fractal_vector_hamming_distance(
    fractal_vector_quantize_binary('[1,-2,3]'::float4[]),
    fractal_vector_quantize_binary('[1,2,3]'::float4[])
) AS hamming_distance;

.print
.print ================================================================
.print Benchmark complete -- 42 of the 95 callable functions this build
.print registers (section 8's 2 feature-store functions are commented
.print out, not implemented; the domain agents, remaining agent entry
.print points, ledger/audit functions, fractal_optimize_subset, and
.print plain-vector math are
.print exercised in demo/demo-agents.sql, the enterprise demos,
.print demo/demo-fractal-vector.sql,
.print demo/demo-vertical-agentic-edge-swarm.sql, and the vertical
.print demos).
.print Tables left in place for inspection. Clean up with:
.print   DELETE FROM fractal_vectorizers WHERE source_table = 'bmk_docs';
.print   DROP TABLE bmk_corpus;
.print   DROP TABLE bmk_docs;
.print   DROP TABLE bmk_modal;
.print (one DROP TABLE per statement -- DuckDB's DROP TABLE takes
.print a single table.)
.print ================================================================
