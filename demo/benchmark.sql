-- demo/benchmark.sql
--
-- A quick, reproducible benchmark for FractalSQL: Sniper Search
-- convergence, Scout Discovery's diversity advantage over plain top-K,
-- and real vectorizer throughput -- all runnable straight from the
-- demo in a couple of minutes. For the full large-scale HNSW vs.
-- Scout Discovery evaluation behind the numbers in
-- ../docs/features.md, see ../bench/ (`make bench`).
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; \
--     cat demo/benchmark.sql; } | duckdb -bail -unsigned mydb.duckdb
--
-- Notes (this build's shapes):
--   * Vector fixtures are built with DuckDB list types (float8[]) and
--     generate_series + array_agg, not CSV/JSON text -- the list is
--     what every function here reads directly.
--   * Every fixture draw comes from a row-id-derived integer LCG (see
--     the bt_lcg/bt_rand macros below), which returns a DOUBLE in
--     [0,1) -- so seeds are just arithmetic on it (e.g. bt_rand(..) *
--     1.8 - 0.9) and each seed is built directly in [-1,1) with no
--     remapping step. The draws are the same on every machine, core
--     count and DuckDB build.
--   * fractal_sfs_converge_debug(query, iterations, population,
--     diffusion_factor) is the abstract-space form, returning one
--     VARCHAR JSON document whose $.best_point key is the converged
--     point.
--   * Scout Discovery is the fractal_search_explore TABLE function over
--     a stored column, in this build -- 'bt_bench_corpus', 'emb_arr',
--     point, options -- returning one DOUBLE[] particle per row.
--
-- Safe to re-run: all tables here are dropped and recreated each time,
-- prefixed bt_bench_* so they can't collide with demo.sql's own
-- demo_* tables.
--
--
-- (Timing is omitted -- DuckDB's CLI has no per-statement
-- timing dot-command; measure latency at the harness level, e.g.
-- demo/demo-workload.sh.)

.print ================================================================
.print FractalSQL basic benchmark -- Sniper Search, Scout Discovery,
.print and vectorizer throughput, with real reproducible numbers.
.print ================================================================

-- The fixture generator: an LCG with xor-shift rounds over pure integer
-- arithmetic, so every draw is exactly the same everywhere.
--
-- random() would not do: setseed() seeds only the engine of the thread
-- that called it, and every other DuckDB worker thread runs its own
-- random() stream, so a fixture query DuckDB spreads over several
-- threads hands each row a value from a different stream -- and the
-- corpus came out different on a different machine. Deriving every draw
-- from the row id instead makes the fixture a pure function of the data,
-- which is what this benchmark's "reproducible numbers" claim needs.
-- The xor-shift rounds are not decoration: a plain LCG is AFFINE in
-- its seed, so two seeds one apart differ by a CONSTANT amount --
-- "separate" dimensions drawn from adjacent seeds came out as mirror
-- images of each other, and a 2-D walk built that way collapses onto a
-- line. The xor-shift breaks that affinity, so neighbouring seeds give
-- genuinely unrelated draws.
CREATE OR REPLACE MACRO bt_lcg(s) AS ((((s::BIGINT * 1103515245::BIGINT) + 12345) % 2147483648));
CREATE OR REPLACE MACRO bt_xs(a, sh) AS (xor(a, a >> sh));
CREATE OR REPLACE MACRO bt_mix(s) AS (bt_xs(bt_lcg(bt_xs(bt_lcg(s), 13)), 17));
CREATE OR REPLACE MACRO bt_rand(s) AS (bt_mix(s)::DOUBLE / 2147483648.0);

-- ------------------------------------------------------------------
-- Section 1: Sniper Search -- convergence latency + accuracy by dim
-- ------------------------------------------------------------------
-- iterations/population_size held constant; only the query dimension
-- changes. cosine_similarity_to_query close to 1.0 confirms SFS
-- actually converged, not just "returned something fast".

.print
.print === Section 1: Sniper Search -- convergence by dimension ===
.print (iterations=50, population_size=50 held constant)

.print
.print --- dim=8 ---
WITH q AS (
    SELECT ARRAY(SELECT bt_rand(i) * 2 - 1 FROM generate_series(1, 8) g(i))::float8[] AS query
),
r AS (
    SELECT query, fractal_sfs_converge(query, 50, 50, 2) AS best FROM q
)
SELECT
    8 AS dim,
    fractal_vector_cosine_similarity(best::FLOAT[], query::FLOAT[])
    AS cosine_similarity_to_query
FROM r;

.print
.print --- dim=32 ---
WITH q AS (
    SELECT ARRAY(SELECT bt_rand(1000 + i) * 2 - 1 FROM generate_series(1, 32) g(i))::float8[] AS query
),
r AS (
    SELECT query, fractal_sfs_converge(query, 50, 50, 2) AS best FROM q
)
SELECT
    32 AS dim,
    fractal_vector_cosine_similarity(best::FLOAT[], query::FLOAT[])
    AS cosine_similarity_to_query
FROM r;

.print
.print --- dim=128 ---
WITH q AS (
    SELECT ARRAY(SELECT bt_rand(2000 + i) * 2 - 1 FROM generate_series(1, 128) g(i))::float8[] AS query
),
r AS (
    SELECT query, fractal_sfs_converge(query, 50, 50, 2) AS best FROM q
)
SELECT
    128 AS dim,
    fractal_vector_cosine_similarity(best::FLOAT[], query::FLOAT[])
    AS cosine_similarity_to_query
FROM r;

-- ------------------------------------------------------------------
-- Section 2: Scout Discovery vs. naive top-K -- cluster diversity
-- ------------------------------------------------------------------
-- 20 synthetic clusters x 250 points in R^8 (5000 rows). Both methods
-- return K=50; we count how many of the 20 clusters each method's
-- results actually represent. This is the mode-collapse problem Scout
-- Discovery exists to fix (see README.md's comparison table): a
-- method returning near-duplicates from one cluster scores low here
-- even though every individual result is technically "close" to the
-- query. "Naive top-K" is brute-force cosine distance in plain SQL --
-- the same ranking a real ANN index would return, just unindexed.
--
-- Every returned point, from either method, gets mapped to its
-- nearest cluster center (matches ../bench/head_to_head.py's own
-- methodology) so both sides are scored the same way.

.print
.print === Section 2: Scout Discovery vs. naive top-K -- cluster diversity ===
.print 20 synthetic clusters x 250 points in R^8 (5000 rows), K=50 returned.

DROP TABLE IF EXISTS bt_bench_clusters;
DROP TABLE IF EXISTS bt_bench_corpus;
DROP SEQUENCE IF EXISTS seq_bt_bench_corpus_id;
CREATE SEQUENCE seq_bt_bench_corpus_id;
CREATE TABLE bt_bench_clusters (cluster_id int PRIMARY KEY, center float8[]);
CREATE TABLE bt_bench_corpus (id INTEGER PRIMARY KEY DEFAULT nextval('seq_bt_bench_corpus_id'), cluster_id int, emb_arr float8[]);

-- Centers spread uniformly across [-0.9, 0.9] with +/-0.1 noise per
-- point, matching ../bench/data_gen.py's own approach (centers
-- uniform in [-1, 1]^dim) rather than clustering them narrowly in the
-- middle -- a corpus that only fills the center of SFS's [-1, 1]^dim
-- operating box leaves the edges empty, and walk=0's diversity fitness
-- (maximize distance to the nearest stored point) will correctly race
-- particles to that empty space instead of spreading them across the
-- real clusters, understating the real result.
--
-- Flat CROSS JOIN + GROUP BY, not ARRAY(subquery): an uncorrelated
-- ARRAY(SELECT <draw> ... FROM generate_series(...)) -- even inside
-- a LATERAL join, as long as the subquery body never actually
-- references an outer column -- gets hoisted into an InitPlan and
-- evaluated ONCE for the whole query, not once per row. Confirmed the
-- hard way with random(): it silently made every "cluster center"
-- identical (20 rows, 1 real cluster), twice, with two different
-- subquery shapes. A flat cross join has no nested subquery to hoist at
-- all -- every base row gets its own draw, provably, and GROUP BY
-- assembles the per-cluster/per-point arrays afterward. The draws
-- themselves come from the row-id-derived LCG above, so each (cluster,
-- dimension) and each (cluster, point, dimension) has its own fixed
-- value on every machine and core count.
--
-- The trailing ORDER BY fixes the row order of each insert -- without
-- it the order comes out of DuckDB's parallel hash aggregate, and the
-- order is what the corpus scan positions (doc_id) are keyed by.
INSERT INTO bt_bench_clusters (cluster_id, center)
SELECT c.cluster_id, array_agg(bt_rand(c.cluster_id * 100 + d.dim_idx) * 1.8 - 0.9 ORDER BY d.dim_idx)
FROM generate_series(1, 20) AS c(cluster_id)
CROSS JOIN generate_series(1, 8) AS d(dim_idx)
GROUP BY c.cluster_id
ORDER BY c.cluster_id;

INSERT INTO bt_bench_corpus (cluster_id, emb_arr)
SELECT c.cluster_id,
       array_agg(c.center[d.dim_idx] + (bt_rand(10000 + c.cluster_id * 10000 + pt.point_n * 10 + d.dim_idx) - 0.5) * 0.2 ORDER BY d.dim_idx)
FROM bt_bench_clusters c
CROSS JOIN generate_series(1, 250) AS pt(point_n)
CROSS JOIN generate_series(1, 8) AS d(dim_idx)
GROUP BY c.cluster_id, pt.point_n
ORDER BY c.cluster_id, pt.point_n;

-- Query is a small fixed off-center point, NOT a literal corpus row --
-- a query sitting almost exactly on a cluster center is a known
-- adversarial case for cosine-based MMR (see the core library's
-- unit tests' header comment: near-degenerate relevance ties
-- can make even mmr_lambda=0.0 fail to escape the dominant basin).
-- Confirmed the hard way: using a literal `WHERE cluster_id = 1 ...
-- LIMIT 1` row here reproduced exactly that -- Scout collapsed to 1-2
-- of 20 clusters, same as naive top-K, instead of diversifying. The
-- origin (all zeros) doesn't work either -- cosine similarity is
-- undefined for a zero vector.
.print
.print --- naive top-K (brute-force cosine distance, plain SQL, K=50) ---
WITH q AS (
    SELECT ARRAY[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]::float8[] AS query
),
top_k AS (
    SELECT bc.emb_arr
    FROM bt_bench_corpus bc, q
    ORDER BY (
        fractal_vector_cosine_similarity(bc.emb_arr::FLOAT[], q.query::FLOAT[])
    )
    LIMIT 50
),
classified AS (
    SELECT (
        SELECT bcl.cluster_id
        FROM bt_bench_clusters bcl
        ORDER BY fractal_vector_l2_squared(bcl.center::FLOAT[], top_k.emb_arr::FLOAT[])
        LIMIT 1
    ) AS nearest_cluster
    FROM top_k
)
SELECT count(DISTINCT nearest_cluster) AS distinct_clusters_of_20 FROM classified;

-- Same query as naive top-K above (see that section's comment on why
-- it's a fixed off-center point, not a literal corpus row).
-- mmr_lambda 0.2 weights diversity more heavily than the 0.5 default.
-- On this small fixture the spread is several clusters of 20 (e.g.
-- 7-13) -- treat this section as measuring the GAP vs. naive top-K,
-- not as a headline number; ../bench/ runs the real scale evaluation.
.print
.print --- Scout Discovery (fractal_search_explore, population_size=50) ---
-- The query vector is spelled out as a literal in the table-function
-- argument: DuckDB table functions do not support lateral join column
-- parameters, so the CTE column the earlier top-K section uses cannot
-- be passed here.
--
-- The population comes back as the `particle` column, one DOUBLE[] per
-- row. Selecting it through a table alias (`... AS p` then `SELECT p`)
-- instead yields a STRUCT wrapping the vector, which no longer casts
-- to FLOAT[] -- so name the column directly.
WITH scout AS (
    SELECT particle AS emb_arr
    FROM fractal_search_explore(
        'bt_bench_corpus', 'emb_arr',
        ARRAY[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]::float8[],
        '{"population_size": 50, "iterations": 8, "walk": 0, "mmr_lambda": 0.2}'
    )
),
classified AS (
    SELECT (
        SELECT bcl.cluster_id
        FROM bt_bench_clusters bcl
        ORDER BY fractal_vector_l2_squared(bcl.center::FLOAT[], scout.emb_arr::FLOAT[])
        LIMIT 1
    ) AS nearest_cluster
    FROM scout
)
SELECT count(DISTINCT nearest_cluster) AS distinct_clusters_of_20 FROM classified;

-- ------------------------------------------------------------------
-- Section 3: vectorizer/embed throughput
-- ------------------------------------------------------------------
-- Real, end-to-end vectorizer throughput -- backfilling 50 rows
-- through your configured embedding endpoint. This number reflects
-- your embedding endpoint's own latency as much as FractalSQL's.
-- Without an endpoint configured, process_queue() marks the rows
-- failed with a clean last_error (see demo-vectorizer.sql) and the
-- timing is only meaningful with one configured.

.print
.print === Section 3: vectorizer/embed throughput ===

-- fractal_vectorizers has no FK back to bt_bench_docs, so DROP TABLE
-- alone doesn't clear the old vectorizer row -- delete it explicitly
-- first, or a re-run of this script fails on the second
-- fractal_vectorizer_create() call.
--
-- The registry tables are created on the extension's first vectorizer
-- call, so on a fresh database they do not exist yet and the DELETE
-- below would fail. The status call creates them (and is a no-op
-- afterwards) -- the same bootstrap demo/demo-vectorizer.sql uses.
SELECT count(*) AS registered_vectorizers FROM fractal_vectorizer_status();
DELETE FROM fractal_vectorizers WHERE source_table = 'bt_bench_docs';
DROP TABLE IF EXISTS bt_bench_docs;
DROP SEQUENCE IF EXISTS seq_bt_bench_docs_id;
CREATE SEQUENCE seq_bt_bench_docs_id;
CREATE TABLE bt_bench_docs (id INTEGER PRIMARY KEY DEFAULT nextval('seq_bt_bench_docs_id'), body text NOT NULL, embedding float8[]);
INSERT INTO bt_bench_docs (body)
SELECT 'benchmark document number ' || gs || ': FractalSQL runs vector search directly inside the DuckDB host process.'
FROM generate_series(1, 50) gs(gs);

SELECT fractal_vectorizer_create('bt_bench_docs', 'id', 'body', 'embedding');

.print
.print Processing 50 rows through the vectorizer (this timing includes
.print real network calls to your embedding endpoint):
SELECT fractal_vectorizer_process_queue();

.print
.print ================================================================
.print Benchmark complete. Tables left in place for inspection --
.print safe to re-run this script any time. Clean up with:
.print   SELECT id FROM fractal_vectorizers WHERE source_table = 'bt_bench_docs';
.print   SELECT fractal_vectorizer_drop(<that id>);
.print   DROP TABLE bt_bench_docs;
.print   DROP TABLE bt_bench_corpus;
.print   DROP TABLE bt_bench_clusters;
.print (one DROP TABLE per statement -- DuckDB's DROP TABLE takes a single table.)
.print ================================================================
