-- demo/demo-vertical-biotech-genomics.sql
--
-- Industry vertical: Biotech & Genomics (single-cell transcriptomics /
-- structural motif analysis).
--
-- A synthetic point cloud standing in for a low-dimensional scRNA-seq
-- embedding (e.g. a UMAP/PCA projection): two well-separated cell-type
-- populations plus a small bridging ring -- the "does this point cloud
-- have interesting topological structure -- clusters, loops" question,
-- which is exactly what a persistence diagram answers. Lp distance is
-- shown separately as the generic point-to-point metric this domain
-- uses at different p (L1/Manhattan for robust feature comparison,
-- L2/Euclidean for raw coordinate distance) rather than being
-- hardcoded to one norm.
--
-- Prerequisites: extension installed. No reasoning step in this file.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; \
--     cat demo/demo-vertical-biotech-genomics.sql; } | duckdb -bail -unsigned mydb.duckdb
--
-- Notes:
--   * The cluster fixtures are reproducible on every machine, core count
--     and DuckDB build: their coordinates come from the row-id-derived
--     integer LCG below, and the topological structure (the two
--     clusters, the ring) is built to be robust to that noise.
--   * points arrives as a flat, row-major LIST(DOUBLE):
--     [p0.x, p0.y, p0.z, p1.x, p1.y, p1.z, ...] for dim=3, exactly what
--     fractal_tda_persistence_diagram(points, dim, max_dim, max_thresh)
--     expects (flat CSV TEXT carried the same shape; the native list is
--     this build's equivalent).
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=biotech-genomics ok);
--     the build_test kit gate greps for it.
--
-- *** SCOPE NOTE (carried verbatim from this function's own doc comment
-- in docs/api-analytics.md -- read this before
-- treating betti1 as a full TDA result): h0_bars (birth/death pairs)
-- is an EXACT, complete 0-dimensional persistence computation --
-- single-linkage clustering is mathematically equivalent to 0-dim
-- persistent homology of the Vietoris-Rips filtration. betti1
-- (requested via max_dim=1) is the bare 1-skeleton GRAPH's cycle rank
-- (edges minus vertices plus connected components), NOT full
-- simplicial H1 of the Vietoris-Rips complex -- it over-counts true
-- H1 whenever a filled triangle exists in the point cloud. A full
-- simplicial computation (what Ripser/GUDHI compute via
-- boundary-matrix reduction) is out of scope here. Treat betti1 here
-- as "how many independent cycles exist in the neighbor graph at this
-- threshold", a useful but strictly weaker signal than true H1 -- not
-- as a drop-in replacement for a real TDA library's loop count. ***
--
-- Safe to re-run: vbg_* tables are dropped and recreated each time.

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
-- point cloud came out different on a different machine. Deriving every
-- draw from the row id instead makes the fixture a pure function of the
-- data: the same cloud on every machine, core count and DuckDB build.
-- The xor-shift rounds are not decoration: a plain LCG is AFFINE in
-- its seed, so two seeds one apart differ by a CONSTANT amount --
-- "separate" dimensions drawn from adjacent seeds came out as mirror
-- images of each other, and a 2-D walk built that way collapses onto a
-- line. The xor-shift breaks that affinity, so neighbouring seeds give
-- genuinely unrelated draws.
CREATE OR REPLACE MACRO vbg_lcg(s) AS ((((s::BIGINT * 1103515245::BIGINT) + 12345) % 2147483648));
CREATE OR REPLACE MACRO vbg_xs(a, sh) AS (xor(a, a >> sh));
CREATE OR REPLACE MACRO vbg_mix(s) AS (vbg_xs(vbg_lcg(vbg_xs(vbg_lcg(s), 13)), 17));
CREATE OR REPLACE MACRO vbg_rand(s) AS (vbg_mix(s)::DOUBLE / 2147483648.0);

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. scRNA-seq-style point cloud: two well-separated cell-type cluster
-- shapes in a 3D embedding plus points bridging them in a rough ring --
-- deliberately built so both H0 (two clusters merging at some
-- threshold) and the graph-cycle-rank betti1 (the bridging ring) have
-- real, non-degenerate structure to find.
-- ------------------------------------------------------------------
.print
.print === 1. Synthetic scRNA-seq embedding: two clusters + a bridging ring ===

DROP TABLE IF EXISTS vbg_cells;
DROP SEQUENCE IF EXISTS seq_vbg_cells_id;
CREATE SEQUENCE seq_vbg_cells_id;
CREATE TABLE vbg_cells (
    id        INTEGER PRIMARY KEY DEFAULT nextval('seq_vbg_cells_id'),
    cell_type text,
    -- double[3], not CSV TEXT -- this build's fixed-width ARRAY type
    -- gives the same write-time dimension enforcement the reference's
    -- CHECK(fractal_vector_dims(coord) = 3) did; that CHECK is kept
    -- below as an explicit second belt over it (cast to float4[]
    -- first, since fractal_vector_dims takes LIST(FLOAT) -- see
    -- docs/api-analytics.md).
    coord     double[3] NOT NULL CHECK (fractal_vector_dims(coord::float4[]) = 3)
);

-- Cluster A, centered at (0,0,0). Kept small (8 points) deliberately --
-- see the betti1 note in Section 2: any cluster whose own internal
-- spread falls entirely inside the chosen threshold becomes a
-- near-complete subgraph, and a complete graph's cycle rank grows
-- combinatorially with point count (C(n,2)-(n-1)), which would swamp
-- the ring's real signal if the clusters were large.
INSERT INTO vbg_cells (cell_type, coord)
SELECT 'T-cell-like',
       ARRAY[vbg_rand(gs * 10 + 1) * 0.6,
             vbg_rand(gs * 10 + 2) * 0.6,
             vbg_rand(gs * 10 + 3) * 0.6]::double[]
FROM generate_series(1, 8) gs(gs);

-- Cluster B, centered at (6,6,0) -- far enough that H0 sees two
-- components at any reasonable threshold before the bridge is added.
INSERT INTO vbg_cells (cell_type, coord)
SELECT 'B-cell-like',
       ARRAY[6.0 + vbg_rand(1000 + gs * 10 + 1) * 0.6,
             6.0 + vbg_rand(1000 + gs * 10 + 2) * 0.6,
             vbg_rand(1000 + gs * 10 + 3) * 0.6]::double[]
FROM generate_series(1, 8) gs(gs);

-- 6-point bridging ring: a rough circle in the plane connecting the
-- two clusters (centered midway between them, radius 3.2), spaced so
-- consecutive points are close (graph edges form at the threshold used
-- below) but the ring as a whole encloses a gap -- the graph-cycle-rank
-- source.
INSERT INTO vbg_cells (cell_type, coord)
SELECT 'transitional',
       ARRAY[3.0 + 3.2 * cos(g * 2 * pi() / 6.0),
             3.0 + 3.2 * sin(g * 2 * pi() / 6.0),
             0.0]::double[]
FROM generate_series(0, 5) g(g);

SELECT count(*) AS n_cells FROM vbg_cells;

-- ------------------------------------------------------------------
-- 2. fractal_tda_persistence_diagram: topology of the embedding. H0
-- bars show the clusters/ring merging into fewer components as the
-- threshold grows (a real, exact single-linkage result). max_thresh=3.3
-- is chosen just above the ring's own point spacing (~3.2) and its
-- shortest links into each cluster, so the ring bridges A and B and
-- closes its own 6-point cycle -- but stays below the much larger A-to-B
-- direct distance (~8.5), so the bridge runs through the ring, not a
-- direct shortcut.
--
-- betti1 will read noticeably higher than "1 loop": each cluster's
-- internal spread (~0.5) is well inside 3.3, so every cluster becomes a
-- near-complete subgraph on its own points, and a complete graph's cycle
-- rank grows combinatorially (C(n,2)-(n-1) per cluster) -- this is
-- exactly the scope note's over-counting behavior in practice, not a
-- bug: betti1 is the raw 1-skeleton graph's cycle rank, and a densely-
-- sampled cluster IS full of graph cycles at any threshold wide enough
-- to connect it, even though it isn't a topological "loop" in any
-- meaningful sense. A real TDA library's full H1 (via boundary-matrix
-- reduction) would correctly collapse a filled-in cluster's cycles away;
-- this primitive deliberately doesn't attempt that -- read betti1 here
-- as "how connected the neighbor graph is", not "how many real loops
-- exist in the data".
--
-- Citation: Edelsbrunner, H., Letscher, D., & Zomorodian, A. (2002).
-- "Topological persistence and simplification." Discrete &
-- Computational Geometry, 28(4), 511-533.
-- ------------------------------------------------------------------
.print
.print === 2. fractal_tda_persistence_diagram: cluster + loop structure ===

-- fractal_tda_persistence_diagram is a scalar here returning
-- STRUCT(h0_bars STRUCT(birth, death)[], betti1 BIGINT) -- a single
-- struct-valued call, not a multi-column out-parameter set, so the
-- fields are read through `.field` access below -- see
-- docs/api-analytics.md. The flat row-major point
-- list is assembled from the native coord lists.
WITH pts AS (SELECT array_agg(c.coord[d] ORDER BY c.id, d) AS flat
             FROM vbg_cells c CROSS JOIN generate_series(1, 3) d(d))
SELECT fractal_tda_persistence_diagram((SELECT flat FROM pts), 3, 1, 3.3::float8, 32) AS diagram;

.print --- H0 bar count and betti1 (graph cycle rank), read separately ---
-- (The corresponding json_extract pair lands here as len(h0_bars) / a
-- plain struct field access on the native return -- same values, no
-- JSON decode.)
WITH pts AS (SELECT array_agg(c.coord[d] ORDER BY c.id, d) AS flat
             FROM vbg_cells c CROSS JOIN generate_series(1, 3) d(d)),
     d AS (SELECT fractal_tda_persistence_diagram((SELECT flat FROM pts), 3, 1, 3.3::float8, 32) AS dj)
SELECT len(d.dj.h0_bars)  AS n_h0_bars,
       d.dj.betti1        AS betti1_graph_cycle_rank
FROM d;

-- ------------------------------------------------------------------
-- 3. fractal_vector_lp_distance: pairwise distance between the two
-- cluster centroids at p=1 (Manhattan -- robust to per-feature
-- outliers, a common choice for noisy expression-derived features) and
-- p=2 (Euclidean -- raw embedding distance). p must be > 0; the
-- triangle inequality only holds for p >= 1, a property of Lp spaces
-- themselves (not an approximation in this implementation) -- both
-- values used here are >= 1. Never substitute this silently for the
-- vector index's native <-> distance as a default; use it explicitly,
-- as here.
--
-- Lp distance is a standard, widely-used metric family, not attributed
-- to a single originating paper -- no citation, per this repo's own
-- THIRD-PARTY-NOTICES.md.
-- ------------------------------------------------------------------
.print
.print === 3. fractal_vector_lp_distance: cluster centroids, p=1 vs p=2 ===

-- Centroids averaged per coordinate over the native coord lists. Cast
-- to float4[] after averaging: fractal_vector_lp_distance is a
-- fractal_vector_* arithmetic primitive taking LIST(FLOAT).
DROP TABLE IF EXISTS vbg_centroids;
CREATE TEMP TABLE vbg_centroids AS
SELECT cell_type,
       array_agg(mean ORDER BY d)::float4[] AS centroid
FROM (
    SELECT c.cell_type, d, avg(c.coord[d]) AS mean
    FROM vbg_cells c
    CROSS JOIN generate_series(1, 3) d(d)
    WHERE c.cell_type IN ('T-cell-like', 'B-cell-like')
    GROUP BY c.cell_type, d
) m
GROUP BY cell_type;

SELECT fractal_vector_lp_distance(
           (SELECT centroid::VARCHAR FROM vbg_centroids WHERE cell_type = 'T-cell-like')::FLOAT[],
           (SELECT centroid::VARCHAR FROM vbg_centroids WHERE cell_type = 'B-cell-like')::FLOAT[],
           1.0) AS centroid_distance_l1_manhattan;
SELECT fractal_vector_lp_distance(
           (SELECT centroid::VARCHAR FROM vbg_centroids WHERE cell_type = 'T-cell-like')::FLOAT[],
           (SELECT centroid::VARCHAR FROM vbg_centroids WHERE cell_type = 'B-cell-like')::FLOAT[],
           2.0::FLOAT) AS centroid_distance_l2_euclidean;

-- 4. Headline check -- the demo's own claims, recomputed from the demo's
-- own tables and calls: at threshold 3.3 the whole embedding is ONE
-- connected component (22 cells -> 21 H0 bars), the graph cycle rank is
-- far above the single bridging ring's one loop (each dense cluster
-- alone contributes 21 cycles -- the scope note's over-counting, not a
-- bug), and the two cell-type centroids are well separated (farther
-- apart under L1 than under L2).
.print
.print === 4. Headline check ===
WITH pts AS (SELECT array_agg(c.coord[d] ORDER BY c.id, d) AS flat
             FROM vbg_cells c CROSS JOIN generate_series(1, 3) d(d)),
     dj AS (SELECT fractal_tda_persistence_diagram((SELECT flat FROM pts), 3, 1, 3.3::float8, 32) AS d)
SELECT 'HEADLINE kit=biotech-genomics ' || CASE WHEN
    (SELECT count(*) FROM vbg_cells) = 22
    AND (SELECT count(*) FROM vbg_cells WHERE cell_type = 'T-cell-like') = 8
    AND (SELECT count(*) FROM vbg_cells WHERE cell_type = 'B-cell-like') = 8
    AND (SELECT count(*) FROM vbg_cells WHERE cell_type = 'transitional') = 6
    AND (SELECT len(d.h0_bars) FROM dj) = 21
    AND (SELECT d.betti1 FROM dj) > 21
    AND fractal_vector_lp_distance(
            (SELECT centroid::VARCHAR FROM vbg_centroids WHERE cell_type = 'T-cell-like')::FLOAT[],
            (SELECT centroid::VARCHAR FROM vbg_centroids WHERE cell_type = 'B-cell-like')::FLOAT[],
            1.0)
        > fractal_vector_lp_distance(
            (SELECT centroid::VARCHAR FROM vbg_centroids WHERE cell_type = 'T-cell-like')::FLOAT[],
            (SELECT centroid::VARCHAR FROM vbg_centroids WHERE cell_type = 'B-cell-like')::FLOAT[],
            2.0::FLOAT)
    AND fractal_vector_lp_distance(
            (SELECT centroid::VARCHAR FROM vbg_centroids WHERE cell_type = 'T-cell-like')::FLOAT[],
            (SELECT centroid::VARCHAR FROM vbg_centroids WHERE cell_type = 'B-cell-like')::FLOAT[],
            2.0::FLOAT) > 6.0
  THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vbg_cells;
.print (vbg_centroids is a TEMP table -- it evaporates with the
.print connection.)
.print ================================================================