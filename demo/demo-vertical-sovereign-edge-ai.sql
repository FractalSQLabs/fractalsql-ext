-- demo/demo-vertical-sovereign-edge-ai.sql
--
-- Industry vertical: Sovereign, Edge & Autonomous Systems AI.
--
-- FractalSQL's whole story fits this vertical natively: search,
-- reasoning, and optimization all run in-process inside the same DuckDB
-- process -- no external vector-DB service, no cloud API call required
-- for search/optimization, and even fractal_reason() can point at a
-- fully local model (see ../docs/reasoning-setup.md's air-gapped
-- guidance) for environments where a network call out is unacceptable.
-- This script: a fleet of 50 edge-compute nodes, finding the best node
-- for a workload (Sniper), a diverse representative sample of the fleet
-- (Scout), and fractal_optimize_portfolio repurposed as a general
-- on-device black-box resource allocator (its own doc comment already
-- frames it as a generic cardinality-constrained optimizer, not
-- finance-specific).
--
-- Prerequisites: extension installed. Sections 3-6 dispatch reasoning
-- through the domain agents (the raw forms alongside them run without an
-- endpoint) -- see ../docs/reasoning-setup.md.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; cat demo/demo-vertical-sovereign-edge-ai.sql; } \
--       | duckdb -unsigned mydb.duckdb
-- (without -bail: section 6's fractal_reason call and the shipped
-- presets' reasoning legs need the reasoning endpoint configured --
-- without one the shell prints the clean error and the remaining
-- statements still run.)
--
-- Notes:
--   * The fleet's fixtures come from a deterministic integer generator
--     (see the vse_rand macro below), so the fleet replays identically
--     on every machine, core count and DuckDB build; the section-5
--     optimizer is additionally pinned by its seed argument.
--   * The fractal_agent_schedule_workload / _recommend_diverse /
--     _allocate presets are shipped compositions over the primitives
--     (telemetry refinement; explore + scores; the optimizer) -- see
--     demo-agents.sql for the pattern.
--   * The deployment grid is flattened into one array via an
--     ORDINALITY unnest pass (the boxcount fixture's shape matches
--     demo/demo-vertical-smart-cities-iot.sql's grid construction).
--   * telemetry doc_id is the row's rowid stringified (with the raw
--     0-indexed scan position alongside as scan_pos); the telemetry
--     joins below resolve doc_id back through the rowid order.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=sovereign-edge-ai ok);
--     the build_test kit gate greps for it.
--
-- Safe to re-run: vse_* tables are dropped and recreated each time.

-- (Timing is omitted -- DuckDB's CLI has no per-statement
-- timing dot-command; measure latency at the harness level, e.g.
-- demo/demo-workload.sh.)

-- The fixture generator: an LCG with xor-shift rounds over pure integer
-- arithmetic, so every draw is exactly the same everywhere.
--
-- random() would not do: setseed() seeds only the engine of the thread
-- that called it, and every other DuckDB worker thread runs its own
-- random() stream. The section-2 grid below is a 400-cell query, so
-- DuckDB spreads it over several threads, each row draws from a
-- different stream, and how many draws land in each stream depends on
-- the machine's core count -- the fleet, and with it the allocation the
-- headline check pins, came out different on a different machine.
-- Pinning threads=1 hides that here, but the numbers would still move
-- with the DuckDB version, whose RNG is not a stable contract. Deriving
-- the fixture from the row id instead makes it a pure function of the
-- data: the same fleet on every machine, and an expectation a reader
-- can reproduce.
-- The xor-shift rounds are not decoration: a plain LCG is AFFINE in
-- its seed, so two seeds one apart differ by a CONSTANT amount --
-- "separate" dimensions drawn from adjacent seeds came out as mirror
-- images of each other, and a 2-D walk built that way collapses onto a
-- line. The xor-shift breaks that affinity, so neighbouring seeds give
-- genuinely unrelated draws.
CREATE OR REPLACE MACRO vse_lcg(s) AS ((((s::BIGINT * 1103515245::BIGINT) + 12345) % 2147483648));
CREATE OR REPLACE MACRO vse_xs(a, sh) AS (xor(a, a >> sh));
CREATE OR REPLACE MACRO vse_mix(s) AS (vse_xs(vse_lcg(vse_xs(vse_lcg(s), 13)), 17));
CREATE OR REPLACE MACRO vse_rand(s) AS (vse_mix(s)::DOUBLE / 2147483648.0);

.print === 0. Sanity check: extension + edition loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 50 edge-compute nodes with a 5-dim resource-capability vector:
-- [cpu_free, mem_free, gpu_avail, net_headroom, battery] each roughly
-- normalized to [-1,1] (1 = plenty of headroom).
-- ------------------------------------------------------------------
.print
.print === 1. 50 edge-compute nodes: resource-capability vectors ===

DROP TABLE IF EXISTS vse_nodes;
-- float8[5], not a fractal_vector catalog type -- this build has none
-- (see docs/api-analytics.md). float8/DOUBLE since
-- capability only ever feeds fractal_search_telemetry below, and
-- there's only the one DOUBLE-based overload in this build anyway (no
-- dual float8[]/fractal_vector corpus dispatch to exercise).
DROP SEQUENCE IF EXISTS seq_vse_nodes_id;
CREATE SEQUENCE seq_vse_nodes_id;
CREATE TABLE vse_nodes (id INTEGER PRIMARY KEY DEFAULT nextval('seq_vse_nodes_id'), node_name text, capability float8[5]);
INSERT INTO vse_nodes (node_name, capability)
SELECT 'edge-node-' || gs,
       ARRAY[vse_rand(gs * 10 + 1), vse_rand(gs * 10 + 2), vse_rand(gs * 10 + 3),
             vse_rand(gs * 10 + 4), vse_rand(gs * 10 + 5)]::float8[]
FROM generate_series(1, 50) gs(gs);

-- ------------------------------------------------------------------
-- 2. fractal_dimension_boxcount over the physical facility layout: a
-- 20x20 grid of candidate rack positions with small placement jitter --
-- a spatial-complexity signal for constrained-compute monitoring, the
-- spatial sibling of DFA's own time-series complexity signal. Needs
-- enough SPACE-FILLING points for the internal box-counting estimator
-- to find >= 3 valid eps-octaves (same validity filter as
-- demo/demo-vertical-medtech-clinical.sql's vessel/nerve fixtures) -- a
-- sparse or purely random scatter (like the 50-node capability table
-- above) is too sparse for this filter, a physical grid isn't.
-- ------------------------------------------------------------------
.print
.print === 2. fractal_dimension_boxcount: facility deployment-grid density ===
.print (dimension near 2.0 means the deployment fills the available floor
.print space; a lower number would flag a sparse or corner-clustered rollout)

SELECT fractal_dimension_boxcount(
    (SELECT array_agg(v ORDER BY r, c, ord)
       FROM generate_series(0, 19) r(r)
       CROSS JOIN generate_series(0, 19) c(c)
       CROSS JOIN LATERAL unnest(
           ARRAY[r + (vse_rand(r * 100 + c * 2 + 1) - 0.5) * 0.3,
                 c + (vse_rand(r * 100 + c * 2 + 2) - 0.5) * 0.3]
       ) WITH ORDINALITY AS u(v, ord)),
    2
) AS deployment_grid_dimension;

-- ------------------------------------------------------------------
-- 3. Sniper Search: converge toward the ideal node profile for a
-- GPU-heavy inference workload (high GPU, high mem, moderate CPU).
-- fractal_search_telemetry then maps that ideal profile to a REAL node
-- to actually schedule onto.
-- ------------------------------------------------------------------
.print
.print === 3. Sniper Search: ideal node profile for a GPU-inference workload ===

-- Blueprint (raw primitives): refine the workload vector with
-- fractal_sfs_converge_debug (the "sniper search" in the abstract [-1,1]^5
-- space, with documented [iterations, population, diffusion] options --
-- one JSON-formatted VARCHAR whose $.best_fit is the converged cosine
-- fit and $.best_point the refined profile), or the plain fractal_sfs_converge
-- convergence, then map that profile to a REAL node with
-- fractal_search_telemetry. Positional args, not `=>`. Generalized by
-- the shipped fractal_agent_schedule_workload preset (a scalar returning
-- one JSON document: {assigned_node, confidence, rationale} -- both
-- steps folded together with one reasoning step):
SELECT fractal_sfs_converge(ARRAY[0.3, 0.6, 0.9, 0.2, 0.0]::float8[], 50) AS ideal_profile;

.print --- sniper: refine the ideal node profile (fractal_sfs_converge_debug) ---
SELECT json_extract(fractal_sfs_converge_debug(ARRAY[0.3, 0.6, 0.9, 0.2, 0.0]::float8[], 50, 50, 2),
                    '$.best_fit')   AS best_fit,
       json_extract(fractal_sfs_converge_debug(ARRAY[0.3, 0.6, 0.9, 0.2, 0.0]::float8[], 50, 50, 2),
                    '$.best_point') AS refined_profile;
-- (Feeding $.best_point through to the telemetry step below needs the
-- .once/.read spool trick -- DuckDB table functions take compile-time
-- constants only; see demo/demo-agents.sql's section 12a for the full
-- two-stage composition.)

SELECT n.node_name, t.distance
FROM fractal_search_telemetry('vse_nodes', 'capability',
                              ARRAY[0.3, 0.6, 0.9, 0.2, 0.0]::float8[], 3) t
JOIN vse_nodes n ON n.rowid::text = t.doc_id
ORDER BY t.distance;

SELECT fractal_agent_schedule_workload(
    ARRAY[0.3, 0.6, 0.9, 0.2, 0.0]::float8[],
    'vse_nodes', 'capability', 'id', 50, 50, 5, '{}'::text);

-- ------------------------------------------------------------------
-- 4. Scout Discovery: a diverse representative sample of the fleet's
-- distinct capability profiles -- useful for capacity planning ("what
-- KINDS of nodes do we actually have") without scanning all 50 by hand.
-- ------------------------------------------------------------------
.print
.print === 4. Scout Discovery: diverse fleet capability profiles ===
.print --- raw explore form (query-agnostic -- explore samples the space) ---

-- Blueprint (raw primitive), executed: returns a diverse representative
-- set of the fleet's distinct capability-profile embeddings.
SELECT particle FROM fractal_search_explore(
    'vse_nodes', 'capability', ARRAY[0.2,0.1,0,0,0]::float8[],
    '{"population_size": 6, "iterations": 8, "walk": 0}'
);

-- Productized preset: the shipped engine (a scalar returning one JSON
-- document -- an array of {item_id, score} rows, score = 1 -
-- cosine_distance) enables session-global repulsion on the shared engine
-- context, then leaves it on (the caller owns that policy). The blueprint's
-- small nonzero anchor samples the space broadly; recommend_diverse
-- is query-anchored, so anchor on the first node's own capability vector.
-- There is no SQL toggle for the engine context (the registered
-- fractal_diversify_disable() below acts on the ledger's own context, a
-- different session); the section-5 allocator doesn't read that state,
-- so it is unaffected here.
.print --- Preset: fractal_agent_recommend_diverse (query-anchored) ---
SELECT fractal_agent_recommend_diverse(
    'vse_nodes', 'capability',
    (SELECT capability::float8[] FROM vse_nodes ORDER BY id LIMIT 1),
    6, 'id');
-- Table-function args are constant-only in DuckDB: the probe vector
-- spools through the .once/.read idiom:
.mode list
.headers off
.output vse_tel.sql
SELECT 'SELECT doc_id, distance FROM fractal_search_telemetry(''vse_nodes'', ''capability'', ' ||
       (SELECT capability FROM vse_nodes ORDER BY id LIMIT 1)::VARCHAR ||
       ', 6) ORDER BY distance ASC;'
;
.output stdout
.mode box
.headers on
.read vse_tel.sql
-- The disable below is the executed enable/disable cycle counterpart --
-- the raw explore above doesn't toggle state, but the preset leaves the
-- ledger-reachable engine repulsion on (the caller owns that policy),
-- so reset it before the section-5 allocator runs:
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 5. fractal_optimize_portfolio as a general on-device black-box
-- resource allocator: which 6 of these 50 nodes should a distributed
-- job land on, maximizing an "efficiency Sharpe" over expected
-- throughput (mu) vs. contention risk (cov, higher between nodes on
-- the same rack/subnet)? Cardinality-constrained, NP-hard in general --
-- exactly the ruggedness class this SFS-backed optimizer targets (see
-- that function's own doc comment).
-- ------------------------------------------------------------------
.print
.print === 5. fractal_optimize_portfolio: pick 6-of-50 nodes for a distributed job ===

DROP TABLE IF EXISTS vse_throughput;
CREATE TABLE vse_throughput (node_id int PRIMARY KEY, expected_throughput float8, rack int);
INSERT INTO vse_throughput (node_id, expected_throughput, rack)
SELECT id, 0.4 + vse_rand(1000 + id) * 0.6, ((id - 1) / 10) FROM vse_nodes;

DROP TABLE IF EXISTS vse_contention_flat;
CREATE TEMP TABLE vse_contention_flat AS
SELECT a.node_id AS i, b.node_id AS j,
       CASE WHEN a.node_id = b.node_id THEN 0.05
            WHEN a.rack = b.rack THEN 0.06
            ELSE 0.005 END AS c_ij
FROM vse_throughput a
CROSS JOIN vse_throughput b;

-- Blueprint (raw primitive), executed: the SFS cardinality-constrained
-- Sharpe maximizer over expected-throughput (mu) vs. contention risk
-- (cov), pinned with the raw primitive's seed arg -- its {sharpe,
-- weights} output feeds Section 6's standalone reason leg below:
SELECT r.sharpe, r.weights FROM (
    SELECT fractal_optimize_portfolio(
        (SELECT array_agg(expected_throughput ORDER BY node_id) FROM vse_throughput),
        (SELECT array_agg(c_ij ORDER BY i, j) FROM vse_contention_flat),
        6, 7
    ) AS r
);

-- Productized preset: the shipped agent runs the same optimizer and
-- reasons a placement rationale over its {sharpe, weights} output (one
-- JSON document: {allocation, sharpe, rationale}). (The agent does not
-- expose the raw primitive's seed arg -- it searches with its own seed,
-- so it lands on a different, equally reproducible 6-of-50 set than the
-- seeded call above.)
SELECT fractal_agent_allocate(
    (SELECT array_agg(expected_throughput ORDER BY node_id) FROM vse_throughput),
    (SELECT array_agg(c_ij ORDER BY i, j) FROM vse_contention_flat),
    6,
    '{"job": "distributed-inference", "vertical": "sovereign-edge"}'::text);

-- ------------------------------------------------------------------
-- 6. Reasoning: narrate the placement decision. Runs against whatever
-- endpoint fractalsql.http_url points at -- a fully local model on a
-- LAN-only host demonstrates the air-gapped-capable story this
-- vertical cares about (see ../docs/reasoning-setup.md).
-- ------------------------------------------------------------------
.print
.print === 6. Reasoning over the placement decision ===

-- The standalone reason leg -- the same call the shipped
-- fractal_agent_allocate preset above folds (its rationale key), kept
-- raw so the composition reads in its original order. The context is
-- the section-5 seeded optimizer output ({sharpe, weights} as text):
SELECT fractal_reason(
    'given this cardinality-constrained node allocation (sharpe + weights per node), explain the placement decision and any risk from rack co-location',
    (SELECT CAST(r AS VARCHAR) FROM (
        SELECT fractal_optimize_portfolio(
            (SELECT array_agg(expected_throughput ORDER BY node_id) FROM vse_throughput),
            (SELECT array_agg(c_ij ORDER BY i, j) FROM vse_contention_flat),
            6, 7
        ) AS r
    ))
);

-- ------------------------------------------------------------------
-- 7. Headline check: the demo's own claims, recomputed from the demo's
-- own tables and calls -- the fleet really is 50 nodes, the Section 3
-- GPU-inference profile really does map to edge-node-42, and the
-- Section 5 seeded allocator really does land the distributed job on
-- exactly 6 of the 50 nodes (edge-node-12 the heaviest).
--
-- The node set and the heaviest node are exact because the fixture is
-- reproducible: it is generated from the row id (see the vse_rand macro
-- at the top of this file), so the same fleet -- and therefore the same
-- allocation -- comes out on every machine, core count and DuckDB build.
-- ------------------------------------------------------------------
.print
.print === 7. Headline check ===
.mode list
.headers off
WITH opt AS (
    SELECT fractal_optimize_portfolio(
               (SELECT array_agg(expected_throughput ORDER BY node_id) FROM vse_throughput),
               (SELECT array_agg(c_ij ORDER BY i, j) FROM vse_contention_flat),
               6, 7) AS res
),
picked AS (
    SELECT w.ord AS node_id, w.weight
    FROM opt o
    CROSS JOIN LATERAL unnest(o.res.weights) WITH ORDINALITY AS w(weight, ord)
    WHERE w.weight > 1e-9
)
SELECT 'HEADLINE kit=sovereign-edge-ai ' || CASE WHEN
    (SELECT count(*) FROM vse_nodes) = 50
    AND (SELECT count(*) FROM vse_throughput) = 50
    AND (SELECT n.node_name
           FROM fractal_search_telemetry('vse_nodes', 'capability',
                     ARRAY[0.3,0.6,0.9,0.2,0.0]::float8[], 3) t
           JOIN vse_nodes n ON n.rowid::text = t.doc_id
          ORDER BY t.distance
          LIMIT 1) = 'edge-node-42'
    AND (SELECT count(*) FROM picked) = 6
    AND (SELECT round(sum(weight), 9) FROM picked) = 1.0
    AND (SELECT string_agg(node_id::VARCHAR, ',' ORDER BY node_id) FROM picked)
        = '2,12,19,30,37,47'
    AND (SELECT n.node_name
           FROM picked p
           JOIN vse_nodes n ON n.id = p.node_id
          ORDER BY p.weight DESC
          LIMIT 1) = 'edge-node-12'
  THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vse_nodes;
.print   DROP TABLE vse_throughput;
.print (one DROP per statement -- DuckDB's DROP TABLE takes exactly one
.print table. The vse_contention_flat TEMP table evaporates with the
.print connection.)
.print ================================================================
