-- demo/demo-vertical-recommendation-search.sql
--
-- Industry vertical: Advanced Recommendation, Search & Discovery Engines.
--
-- A product/content catalog for diverse "you might also like" discovery,
-- a table-backed top-k telemetry search, the full stateful-diversity
-- loop (enable Diversify, search, report negative feedback on a result,
-- re-search, confirm it's avoided -- the real differentiator over plain
-- top-K or MMR: it's stateful and feedback-learning, not a one-shot
-- re-ranking heuristic), and cross-modal search (content + behavior
-- vectors, weighted).
--
-- Prerequisites: extension installed (the demos' agent calls in sections
-- 2 and 4 are retrieval-only, no LLM) -- see ../docs/reasoning-setup.md.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; \
--     cat demo/demo-vertical-recommendation-search.sql; } | duckdb -unsigned mydb.duckdb
-- (without -bail: section 6's fractal_reason call needs the reasoning
-- endpoint configured -- without one the shell prints the clean error
-- and the remaining statements still run.)
--
-- Safe to re-run: vrs_* tables are dropped and recreated each time.

-- Notes:
--   * The catalog fixture is fully deterministic: the six genre centroids
--     sit on mutually orthogonal directions and the per-item jitter comes
--     from a row-id-derived integer LCG, so the same catalog -- and the
--     same top-k telemetry list -- comes out on every machine, core count
--     and DuckDB build.
--   * The section-3 probe vector IS the strategy-games centroid, so the
--     fixed probe's top-5 telemetry rows land inside that genre by
--     construction rather than by luck.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=recommendation-search ok);
--     the build_test kit gate greps for it.

-- (Timing is omitted -- DuckDB's CLI has no per-statement
-- timing dot-command; measure latency at the harness level, e.g.
-- demo/demo-workload.sh.)
--
-- The fixture generator: an LCG with xor-shift rounds over pure integer
-- arithmetic, so every draw is exactly the same everywhere.
--
-- random() would not do: setseed() seeds only the engine of the thread
-- that called it, and every other DuckDB worker thread runs its own
-- random() stream, so a fixture query DuckDB spreads over several
-- threads hands each row a value from a different stream -- and the
-- catalog, and with it the top-5 telemetry list the headline check pins,
-- came out different on a different machine. Deriving every draw from
-- the row id instead makes the fixture a pure function of the data: the
-- same catalog on every machine, core count and DuckDB build.
-- The xor-shift rounds are not decoration: a plain LCG is AFFINE in
-- its seed, so two seeds one apart differ by a CONSTANT amount --
-- "separate" dimensions drawn from adjacent seeds came out as mirror
-- images of each other, and a 2-D walk built that way collapses onto a
-- line. The xor-shift breaks that affinity, so neighbouring seeds give
-- genuinely unrelated draws.
CREATE OR REPLACE MACRO vrs_lcg(s) AS ((((s::BIGINT * 1103515245::BIGINT) + 12345) % 2147483648));
CREATE OR REPLACE MACRO vrs_xs(a, sh) AS (xor(a, a >> sh));
CREATE OR REPLACE MACRO vrs_mix(s) AS (vrs_xs(vrs_lcg(vrs_xs(vrs_lcg(s), 13)), 17));
CREATE OR REPLACE MACRO vrs_rand(s) AS (vrs_mix(s)::DOUBLE / 2147483648.0);

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 300-item catalog, 6 genre clusters x 50 items in R^8. Centers
-- spread uniformly across [-0.9, 0.9] with per-item jitter -- matching
-- demo/benchmark.sql's own approach (narrow clustering in the box
-- center would silently understate Scout's real diversity result, per
-- that file's own load-bearing comment). Flat CROSS JOIN + GROUP BY,
-- not ARRAY(subquery) -- see demo/demo-vertical-quant-finance.sql's comment
-- on why an uncorrelated ARRAY(SELECT random() ...) silently produces
-- identical rows via InitPlan hoisting.
-- ------------------------------------------------------------------
.print
.print === 1. 300-item catalog: 6 genre clusters in R^8 ===

DROP TABLE IF EXISTS vrs_genres;
DROP TABLE IF EXISTS vrs_catalog;
-- Both DOUBLE[8], not float8[] -- fixed-width genre-centroid
-- and catalog-item embeddings, same dimension-safety argument as the
-- other updated verticals. INSERTs below are otherwise unchanged
-- (still float8[]-typed expressions), relying on the assignment cast.
DROP SEQUENCE IF EXISTS seq_vrs_catalog_id;
CREATE SEQUENCE seq_vrs_catalog_id;
CREATE TABLE vrs_genres (genre_id int PRIMARY KEY, name text, center DOUBLE[8]);
CREATE TABLE vrs_catalog (id INTEGER PRIMARY KEY DEFAULT nextval('seq_vrs_catalog_id'), genre_id int, title text, emb_arr DOUBLE[8]);

-- The six genre centroids sit on six MUTUALLY ORTHOGONAL directions --
-- six of the eight Hadamard corners of the [-0.8, 0.8]^8 cube. That is
-- as far apart as the box allows, so the clusters cannot bleed into
-- each other (narrow clustering near the box center would silently
-- understate Scout's real diversity result, per demo/benchmark.sql's
-- own load-bearing comment) -- and it lets the section-3 probe BE a
-- centroid: the strategy-games centroid is the probe vector verbatim,
-- so the top-k telemetry list provably lands inside one genre.
INSERT INTO vrs_genres (genre_id, name, center)
SELECT g, name,
       CASE g
           WHEN 1 THEN [ 0.8, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8]::DOUBLE[]
           WHEN 2 THEN [ 0.8,-0.8, 0.8,-0.8, 0.8,-0.8, 0.8,-0.8]::DOUBLE[]
           WHEN 3 THEN [ 0.8, 0.8,-0.8,-0.8, 0.8, 0.8,-0.8,-0.8]::DOUBLE[]
           WHEN 4 THEN [ 0.8,-0.8,-0.8, 0.8, 0.8,-0.8,-0.8, 0.8]::DOUBLE[]
           WHEN 5 THEN [ 0.8, 0.8, 0.8, 0.8,-0.8,-0.8,-0.8,-0.8]::DOUBLE[]
           ELSE        [ 0.8,-0.8, 0.8,-0.8,-0.8, 0.8,-0.8, 0.8]::DOUBLE[]
       END
FROM (VALUES (1,'sci-fi'),(2,'documentary'),(3,'true-crime'),
             (4,'comedy'),(5,'strategy-games'),(6,'cooking')) AS gv(g, name);

-- fractal_vector has no [n] subscript operator (unlike float8[]) --
-- cast to float8[] for the per-dimension jitter lookup, same pattern
-- as demo-vertical-maritime-defense.sql's vessel-7 UPDATE.
INSERT INTO vrs_catalog (genre_id, title, emb_arr)
SELECT gc.genre_id, gc.name || '-item-' || pt.item_n,
       array_agg((gc.center::float8[])[d.dim_idx]
                 + (vrs_rand(10000 + gc.genre_id * 1000 + pt.item_n * 10 + d.dim_idx) - 0.5) * 0.25
                 ORDER BY d.dim_idx)
FROM vrs_genres gc
CROSS JOIN generate_series(1, 50) AS pt(item_n)
CROSS JOIN generate_series(1, 8) AS d(dim_idx)
GROUP BY gc.genre_id, gc.name, pt.item_n
-- The trailing ORDER BY fixes the catalog's row order, and with it the
-- scan position (doc_id) every search result is keyed by. A GROUP BY
-- without it leaves the order to DuckDB's parallel hash aggregate, and
-- that order moves with the core count -- which would move the top-k
-- list and the item the headline pins.
ORDER BY gc.genre_id, pt.item_n;

SELECT count(*) AS items, count(DISTINCT genre_id) AS genres FROM vrs_catalog;

-- ------------------------------------------------------------------
-- 2. Scout Discovery: diverse "you might also like" -- a spread across
-- distinct genre basins, not K near-duplicates from one genre.
-- ------------------------------------------------------------------
.print
.print === 2. fractal_search_explore: diverse recommendations ===
.print --- raw explore form (query-agnostic -- explore samples the space) ---

-- Blueprint (raw primitive): returns a diverse spread of representative
-- catalog embeddings across distinct genre basins (not K near-duplicates
-- from one genre). Anchor is a small nonzero point -- cosine is undefined
-- at the origin.
SELECT particle FROM fractal_search_explore(
    'vrs_catalog', 'emb_arr', ARRAY[0.2,0.1,0,0,0,0,0,0]::float8[],
    '{"population_size": 6, "iterations": 8, "walk": 0}'
);

-- Productized preset: the shipped engine (a scalar returning one JSON
-- document -- an array of {item_id, score} rows, score = 1 -
-- cosine_distance) enables session-global repulsion on the shared engine
-- context, then leaves it on (the caller owns that policy). The
-- blueprint's anchor samples the space broadly; recommend_diverse is
-- query-anchored, so anchor on the first catalog item's own embedding.
.print --- Preset: fractal_agent_recommend_diverse (query-anchored) ---
-- There is no SQL toggle for the engine context (the registered
-- fractal_diversify_disable() acts on the ledger's own context, a
-- different session). Repulsion doesn't disturb the section-3 telemetry
-- top-k below: those top-k lists are deliberately literal, ground-truth
-- nearest rows (see section 4's scoping note).
SELECT fractal_agent_recommend_diverse(
    'vrs_catalog', 'emb_arr',
    (SELECT emb_arr::float8[] FROM vrs_catalog ORDER BY id LIMIT 1),
    6, 'id');
-- Table-function args are constant-only in DuckDB: the probe vector
-- spools through the .once/.read idiom:
.mode list
.headers off
.output vrs_tel.sql
SELECT 'SELECT doc_id, distance FROM fractal_search_telemetry(''vrs_catalog'', ''emb_arr'', ' ||
       (SELECT emb_arr FROM vrs_catalog ORDER BY id LIMIT 1)::VARCHAR ||
       ', 6) ORDER BY distance ASC;'
;
.output stdout
.mode box
.headers on
.read vrs_tel.sql

-- ------------------------------------------------------------------
-- 3. fractal_search_telemetry: real top-k rows (doc_id + distance) --
-- the primitive fractal_search_explore/fractal_search don't provide on
-- their own (see that function's own doc comment).
-- ------------------------------------------------------------------
.print
.print === 3. fractal_search_telemetry: top-5 nearest catalog items ===

-- Table functions take compile-time constants in DuckDB (no subquery
-- parameters), so the probe below is a literal -- and it is the
-- strategy-games centroid verbatim (see Section 1), so this fixed
-- probe's top-5 rows land inside that genre by construction.
SELECT c.title, t.distance
FROM fractal_search_telemetry('vrs_catalog', 'emb_arr',
                              ARRAY[0.8,0.8,0.8,0.8,-0.8,-0.8,-0.8,-0.8]::float8[], 5) t
JOIN vrs_catalog c ON c.rowid::text = t.doc_id
ORDER BY t.distance;

-- ------------------------------------------------------------------
-- 4. Diversify/Repulsion session state: enable it, report NEGATIVE
-- feedback on a result, and confirm the session picks it up.
--
-- fractal_diversify_enable()'s own doc comment scopes this to
-- "fractal_search results" specifically -- fractal_search_telemetry's
-- top_k (and hybrid_clinical_search/search_trajectory/cross_modal_
-- search, which all share it) is deliberately a literal, ground-truth
-- "k nearest REAL rows to this query" list, not repulsion-adjusted --
-- that's what makes it trustworthy for the doc_id/distance pairs the
-- rest of this demo joins back to real catalog rows. Repulsion state
-- from fractal_isolate_background is real (see the diagnostics below),
-- but today it only steers fractal_search()'s own single converged
-- point in the abstract [-1,1]^dim space, not this table-backed top-k
-- list -- so re-running the SAME fractal_search_telemetry query below
-- correctly returns the SAME top result, not a different one.
-- ------------------------------------------------------------------
.print
.print === 4. Diversify/Repulsion: session-level feedback state ===

-- Blueprint (raw primitive), executed: the stateful diversify/repulsion
-- audit cycle -- enable repulsion, set params, warm the D_q rolling
-- window with varied queries, report negative feedback on the audit
-- target (fractal_isolate_background on its scan_pos -- scan_pos IS the
-- handle; doc_id is the rowid stringified (the join above), a different
-- concept from the core engine's own internal result_handle), read back
-- the real diversity_quotient + session diagnostics, and disable.
-- Generalized below by the shipped fractal_agent_feedback_audit preset,
-- which runs this whole audit cycle self-contained (and self-disables
-- diversify, unlike recommend_diverse). These registered calls act on
-- the ledger's own context, a different session than the agent's shared
-- engine context below.
SELECT fractal_diversify_enable();
SELECT fractal_diversify_set_params(5, NULL, 0.3, 0.5);  -- positional; NULL leaves a field at its current value

-- Warm the D_q rolling window with 8 varied queries. The CLI has no
-- variable capture, so the .once/.read spool trick materializes the
-- literal vectors (the demo-agents.sql 12a/13a idiom):
.mode list
.headers off
.output vrs_warm.sql
SELECT 'SELECT count(*) AS window_warmed FROM fractal_search_telemetry(''vrs_catalog'', ''emb_arr'', [' ||
       printf('%.2f,0.20,-0.20,0.10,0.20,0.10,-0.20,0.10]::float8[], 3);',
              0.80 + g * 0.025)
FROM generate_series(0, 7) AS g(g);
.output stdout
.headers on
.mode box
.read vrs_warm.sql

-- Negative feedback on the audit target: the k=1 telemetry top result.
-- The capture step spools its scan_pos into the isolate call:
.mode list
.headers off
.output vrs_isolate.sql
SELECT 'SELECT fractal_isolate_background(' || CAST(scan_pos AS VARCHAR) || ');'
FROM fractal_search_telemetry('vrs_catalog', 'emb_arr',
                              ARRAY[0.8,0.8,0.8,0.8,-0.8,-0.8,-0.8,-0.8]::float8[], 1);
.output stdout
.headers on
.mode box
.read vrs_isolate.sql

SELECT fractal_detect_collapse() AS diversity_quotient;
SELECT fractal_explain_result()  AS diagnostics;
SELECT fractal_diversify_disable();

-- The shipped preset (a scalar returning one JSON document
-- {diversity_quotient, explanation}; the whole audit cycle
-- self-contained, incl. self-disabling diversify on its own engine
-- context):
SELECT fractal_agent_feedback_audit(
    'vrs_catalog', 'emb_arr',
    (SELECT center::float8[] FROM vrs_genres WHERE genre_id = 3),
    'vrs_genres', 'center', 8, 3);

-- ------------------------------------------------------------------
-- 5. Cross-modal search: content embedding + behavior embedding,
-- weighted (weighted CONCATENATION, not a blend -- each modality keeps
-- its own dimensions; vector_col must already be stored in this
-- combined shape).
-- ------------------------------------------------------------------
.print
.print === 5. fractal_cross_modal_search: content + behavior, weighted ===

DROP TABLE IF EXISTS vrs_modal_items;
-- DOUBLE[8] vectors -- matches fractal_cross_modal_search's
-- FLOAT[]/DOUBLE[]-typed vector overload below.
DROP SEQUENCE IF EXISTS seq_vrs_modal_items_id;
CREATE SEQUENCE seq_vrs_modal_items_id;
CREATE TABLE vrs_modal_items (id INTEGER PRIMARY KEY DEFAULT nextval('seq_vrs_modal_items_id'), title text, combined_vec DOUBLE[8]);
INSERT INTO vrs_modal_items (title, combined_vec)
SELECT 'modal-item-' || gs,
       ARRAY[vrs_rand(100000 + gs * 10 + 1) * 2 - 1, vrs_rand(100000 + gs * 10 + 2) * 2 - 1,
             vrs_rand(100000 + gs * 10 + 3) * 2 - 1, vrs_rand(100000 + gs * 10 + 4) * 2 - 1,   -- content (4d)
             vrs_rand(100000 + gs * 10 + 5) * 2 - 1, vrs_rand(100000 + gs * 10 + 6) * 2 - 1,
             vrs_rand(100000 + gs * 10 + 7) * 2 - 1, vrs_rand(100000 + gs * 10 + 8) * 2 - 1]  -- behavior (4d)
FROM generate_series(1, 60) gs(gs);

SELECT m.title, t.distance
FROM fractal_cross_modal_search(
    'vrs_modal_items', 'combined_vec',
    '[0.6,0.6,-0.6,0.0]'::DOUBLE[],   -- content query
    '[0.2,-0.2,0.2,0.2]'::DOUBLE[],   -- behavior query
    0.7, 5
) t
JOIN vrs_modal_items m ON m.id = t.doc_id + 1
ORDER BY t.distance;

-- ------------------------------------------------------------------
-- 6. Reasoning: explain the recommendation set in plain language.
-- ------------------------------------------------------------------
.print
.print === 6. Reasoning over the recommendation set ===

-- The query vector here is a fixed nonzero anchor (a table function's
-- parameters are compile-time constants in DuckDB -- no subquery -- and
-- cosine is undefined at the origin). Each result's doc_id is DuckDB's
-- rowid pseudocolumn, stringified -- the same join convention the
-- section-3 top-k list above uses.
SELECT fractal_reason(
    'each item is a catalog title with a distance score from a diverse discovery search -- explain what kind of viewer/listener would want this mix and why the spread across genres matters',
    (SELECT list(t)::text FROM (
        SELECT c.title, c.genre_id, gt.distance
        FROM fractal_search_telemetry('vrs_catalog', 'emb_arr',
                                      ARRAY[0.8,0.8,0.8,0.8,-0.8,-0.8,-0.8,-0.8]::float8[], 8) gt
        JOIN vrs_catalog c ON c.rowid::text = gt.doc_id
    ) t)
);

-- ------------------------------------------------------------------
-- 7. Headline check: the demo's own claims, recomputed from the demo's
-- own tables and calls -- the catalog really is 300 items in 6 genre
-- clusters, the Section 3 fixed probe's top-5 telemetry rows are all
-- real strategy-games catalog rows led by strategy-games-item-22, and
-- the Section 5 cross-modal top hit is modal-item-52.
--
-- The item names are exact because the fixture is reproducible: the
-- centroids are fixed and the per-item jitter comes from the row-id LCG
-- above, so the same catalog -- and the same leader -- comes out on
-- every machine, core count and DuckDB build.
--
-- The probe IS the strategy-games centroid, so the top-5 landing
-- inside that genre is structural, not a lucky draw: the check also
-- pins the separation margin (the nearest item of any OTHER genre sits
-- at distance ~0.93, the nearest strategy-games item at ~0.003).
-- ------------------------------------------------------------------
.print
.print === 7. Headline check ===
.mode list
.headers off
SELECT 'HEADLINE kit=recommendation-search ' || CASE WHEN
    (SELECT count(*) FROM vrs_catalog) = 300
    AND (SELECT count(DISTINCT genre_id) FROM vrs_catalog) = 6
    AND (SELECT count(*)
           FROM fractal_search_telemetry('vrs_catalog', 'emb_arr',
                     ARRAY[0.8,0.8,0.8,0.8,-0.8,-0.8,-0.8,-0.8]::float8[], 5) t
           JOIN vrs_catalog c ON c.rowid::text = t.doc_id
           JOIN vrs_genres g ON g.genre_id = c.genre_id
          WHERE g.name = 'strategy-games') = 5
    AND (SELECT max(t.distance)
           FROM fractal_search_telemetry('vrs_catalog', 'emb_arr',
                     ARRAY[0.8,0.8,0.8,0.8,-0.8,-0.8,-0.8,-0.8]::float8[], 5) t) < 0.01
    AND (SELECT min(t.distance)
           FROM fractal_search_telemetry('vrs_catalog', 'emb_arr',
                     ARRAY[0.8,0.8,0.8,0.8,-0.8,-0.8,-0.8,-0.8]::float8[], 300) t
           JOIN vrs_catalog c ON c.rowid::text = t.doc_id
           JOIN vrs_genres g ON g.genre_id = c.genre_id
          WHERE g.name <> 'strategy-games') > 0.9
    AND (SELECT c.title
           FROM fractal_search_telemetry('vrs_catalog', 'emb_arr',
                     ARRAY[0.8,0.8,0.8,0.8,-0.8,-0.8,-0.8,-0.8]::float8[], 5) t
           JOIN vrs_catalog c ON c.rowid::text = t.doc_id
          ORDER BY t.distance
          LIMIT 1) = 'strategy-games-item-22'
    AND (SELECT count(*)
           FROM fractal_cross_modal_search('vrs_modal_items', 'combined_vec',
                     '[0.6,0.6,-0.6,0.0]'::DOUBLE[],
                     '[0.2,-0.2,0.2,0.2]'::DOUBLE[], 0.7, 5) t
           JOIN vrs_modal_items m ON m.id = t.doc_id + 1) = 5
    AND (SELECT m.title
           FROM fractal_cross_modal_search('vrs_modal_items', 'combined_vec',
                     '[0.6,0.6,-0.6,0.0]'::DOUBLE[],
                     '[0.2,-0.2,0.2,0.2]'::DOUBLE[], 0.7, 5) t
           JOIN vrs_modal_items m ON m.id = t.doc_id + 1
          ORDER BY t.distance
          LIMIT 1) = 'modal-item-52'
  THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vrs_genres;
.print   DROP TABLE vrs_catalog;
.print   DROP TABLE vrs_modal_items;
.print (one DROP per statement -- DuckDB's DROP TABLE takes exactly one
.print table. The vrs_warm.sql / vrs_isolate.sql spool files from
.print Section 4 live in the current directory, overwritten each run.)
.print ================================================================
