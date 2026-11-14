-- demo/demo-vertical-agentic-edge-swarm.sql
--
-- Industry vertical: Agentic Edge / Robotics Swarm Coordination.
--
-- Three independent showcases against a battery- and bandwidth-
-- constrained edge swarm:
--
--   1. Vector quantization (int8 + binary) for compressed swarm memory
--      -- each edge node has tight RAM/radio-bandwidth budgets, so
--      storing/transmitting full float8 state embeddings for every
--      peer isn't free; binary quantization + Hamming pre-filtering is
--      the standard cheap-candidate-then-rerank pattern.
--   2. fractal_agent_detect_loop ("cognitive wobble" detection) -- one
--      agent stuck oscillating between two headings (a real, common
--      edge-robotics failure mode: a local-minimum trap in a reactive
--      controller) vs. one genuinely exploring; the preset fingerprints
--      state vectors (SimHash) and streams them through Brent's cycle
--      detection, exercised here on its actual use case.
--   3. fractal_optimize_subset's value-weighted allocation for
--      battery-constrained task routing -- pick the best k tasks by
--      priority value, each bounded by its own battery-budget share.
--
-- Prerequisites: extension installed. No reasoning step in this file.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; \
--     cat demo/demo-vertical-agentic-edge-swarm.sql; } | duckdb -bail -unsigned mydb.duckdb
--
-- Notes:
--   * Every fixture here replays identically on every machine, core
--     count and DuckDB build: the wobble section's explorer trajectory
--     uses deterministic multi-frequency sinusoids, and the generated
--     fixtures use the row-id-derived integer LCG below (see the note on
--     setseed() there).
--   * fractal_state_fingerprint is direction-based (random-hyperplane
--     SimHash over the raw state vector) -- it is magnitude-invariant,
--     so a 1-dimensional state only has two possible directions and
--     any same-signed sequence collapses to one fingerprint regardless
--     of its actual values. The 2-D (dx, dy) heading state used for
--     wobble detection below exists specifically to avoid that
--     degenerate case -- a 1-D "toggle between two numbers" state
--     would give a false positive on any same-signed sequence, not
--     just a real loop (see also demo-agents.sql's section 18 note on
--     the 1-D degeneracy).
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=agentic-edge-swarm ok);
--     the build_test kit gate greps for it.
--
-- Safe to re-run: vae_* tables are dropped and recreated each time.

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
-- swarm fleet came out different on a different machine. Deriving every
-- draw from the row id instead makes the fixture a pure function of the
-- data: the same fleet on every machine, core count and DuckDB build.
-- The xor-shift rounds are not decoration: a plain LCG is AFFINE in
-- its seed, so two seeds one apart differ by a CONSTANT amount --
-- "separate" dimensions drawn from adjacent seeds came out as mirror
-- images of each other, and a 2-D walk built that way collapses onto a
-- line. The xor-shift breaks that affinity, so neighbouring seeds give
-- genuinely unrelated draws.
CREATE OR REPLACE MACRO vae_lcg(s) AS ((((s::BIGINT * 1103515245::BIGINT) + 12345) % 2147483648));
CREATE OR REPLACE MACRO vae_xs(a, sh) AS (xor(a, a >> sh));
CREATE OR REPLACE MACRO vae_mix(s) AS (vae_xs(vae_lcg(vae_xs(vae_lcg(s), 13)), 17));
CREATE OR REPLACE MACRO vae_rand(s) AS (vae_mix(s)::DOUBLE / 2147483648.0);

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 20 edge-swarm nodes, each with a 16-dim compressed state-summary
-- embedding (heading, battery, sensor-cluster activations, etc.,
-- normalized). int8 quantization (4x) for on-device storage of peer
-- state; binary quantization (32x) + Hamming distance for a cheap
-- first-pass candidate filter ahead of a full-precision re-rank --
-- exactly the pairing documented on fractal_vector_hamming_distance
-- itself. No published-algorithm citation for quantization: general
-- "compress, then Hamming/popcount filter" pattern, per this repo's
-- own THIRD-PARTY-NOTICES.md.
-- ------------------------------------------------------------------
.print
.print === 1. Vector quantization: compressed swarm-node memory ===

DROP TABLE IF EXISTS vae_nodes;
DROP SEQUENCE IF EXISTS seq_vae_nodes_id;
CREATE SEQUENCE seq_vae_nodes_id;
CREATE TABLE vae_nodes (
    id    INTEGER PRIMARY KEY DEFAULT nextval('seq_vae_nodes_id'),
    -- float4[16], not float8[] -- fixed-width state summary. This
    -- DuckDB port has no fractal_vector catalog type (see
    -- docs/api-analytics.md); its
    -- fixed-size ARRAY type gives the same dimension enforcement
    -- fractal_vector's typmod did. float4 (not float8) because every
    -- function this column feeds below is a fractal_vector_* arithmetic
    -- primitive, which takes LIST(FLOAT)/float4[] -- see that file's
    -- SQL-surface comment for the full float4-vs-float8 split.
    state float4[16]
);

-- Flat CROSS JOIN, not ARRAY(uncorrelated subquery) -- an uncorrelated
-- subquery body (one that never references the outer generate_series(1,20)
-- row) gets hoisted into a one-shot InitPlan and evaluated ONCE for the
-- whole INSERT, silently making every node's state identical despite
-- the generator being volatile. Same trap demo-vertical-quant-finance.sql's
-- own comment documents; a flat cross join has no nested subquery to
-- hoist, so every (node, dim) pair gets its own draw, provably.
--
-- The trailing ORDER BY gs is what makes the TABLE's row order -- and
-- therefore the scan position (doc_id) the search functions report --
-- the same on every machine. A GROUP BY without it hands its output to
-- the insert in whatever order DuckDB's parallel hash aggregate happens
-- to emit the groups, and that order moves with the core count.
INSERT INTO vae_nodes (id, state)
SELECT gs, array_agg(vae_rand(gs * 100 + dim) * 2 - 1 ORDER BY dim)::float4[]
FROM generate_series(1, 20) gs(gs)
CROSS JOIN generate_series(1, 16) dim(dim)
GROUP BY gs
ORDER BY gs;

.print (raw primitives -- no preset wraps these functions yet)
DROP TABLE IF EXISTS vae_quantized;
CREATE TEMP TABLE vae_quantized AS
SELECT id,
       json(fractal_vector_quantize_int8(state))->'$.scale' AS int8_scale,
       json(fractal_vector_quantize_int8(state))->'$.codes' AS int8_codes,
       fractal_vector_quantize_binary(state)           AS binary_code
FROM vae_nodes;

SELECT id, json_array_length(int8_codes::VARCHAR) AS int8_bytes, round((int8_scale::VARCHAR)::NUMERIC, 4) AS scale,
       octet_length(binary_code) AS binary_bytes
FROM vae_quantized
ORDER BY id
LIMIT 5;

.print (cheap Hamming pre-filter: nearest peers to node 1 by quantized-binary distance)
SELECT b.id, fractal_vector_hamming_distance(a.binary_code, b.binary_code) AS hamming_dist
FROM vae_quantized a, vae_quantized b
WHERE a.id = 1 AND b.id != 1
ORDER BY hamming_dist ASC
LIMIT 5;

-- ------------------------------------------------------------------
-- 2. fractal_agent_detect_loop: two agents' recent state trajectories.
-- state-fingerprint is cosine/direction-based, so magnitude alone
-- carries no signal, and this kernel has real, non-obvious
-- false-positive modes confirmed empirically while building this demo
-- -- worth documenting plainly rather than papering over with a
-- cherry-picked seed:
--   * A fixed angular step (even with noise) revisits similar
--     directions every ~2*pi/step_size samples -- a real periodicity,
--     correctly flagged.
--   * A genuine, non-periodic UNBOUNDED random walk still gets flagged
--     spuriously: its per-step L2 norm trends steadily upward (a
--     random walk's magnitude grows roughly like sqrt(t)), and the
--     kernel's secondary DFA signal reads that steady growth as high
--     persistence (alpha > 0.9) regardless of the cycle-detect result.
--   * A low state dimension (3, matching the "compressed swarm memory"
--     framing elsewhere in this file) also has a real, separate
--     collision mode: with few true directional degrees of freedom,
--     the SimHash fingerprint's random hyperplane arrangement can
--     alias two genuinely different directions to the identical
--     64-bit fingerprint over as few as 24 samples, which Brent's
--     cycle detection (correctly, per its own contract) reports as a
--     repeat -- confirmed directly against this fixture by printing
--     the raw fingerprints and finding an exact collision between two
--     non-adjacent, non-similar samples.
-- The explorer trajectory below sidesteps all three: bounded per-
-- dimension (no magnitude drift -> no false DFA persistence), a wider
-- 8-dim state (more directional resolution -> far lower incidental
-- collision odds), and deterministic multi-frequency sinusoids with
-- pairwise-incommensurate (irrational-ratio) frequencies rather than
-- random() -- guarantees no exact periodicity within any finite window
-- and, unlike a random walk, is reproducible independent of where in
-- this script's fixture generation it happens to run. Agent
-- bot-stuck below, by contrast, oscillates between two fixed headings
-- -- an exact period-2 cycle, the textbook "cognitive wobble" trap
-- this preset is built to catch.
--
-- Citations: SimHash state-fingerprint -- Charikar, M. S. (2002),
-- "Similarity estimation techniques from rounding algorithms," STOC.
-- Brent's cycle detection -- Brent, R. P. (1980), "An improved Monte
-- Carlo factorization algorithm," BIT Numerical Mathematics.
-- ------------------------------------------------------------------
.print
.print === 2. fractal_agent_detect_loop: cognitive-wobble detection ===
.print --- Preset: fractal_agent_detect_loop ---

WITH explorer_walk(t, d1, d2, d3, d4, d5, d6, d7, d8) AS (
    SELECT t,
           sin(t * 1.41421356), sin(t * 1.73205081), sin(t * 2.23606798),
           sin(t * 2.64575131), sin(t * 3.31662479), sin(t * 3.60555128),
           sin(t * 3.87298335), sin(t * 4.12310563)
    FROM generate_series(1, 24) t(t)
)
SELECT r.agent_id, r.is_loop_detected, r.dfa_exponent
FROM (SELECT fractal_agent_detect_loop(
    'bot-explorer',
    (SELECT array_agg(v ORDER BY t, ord)
       FROM explorer_walk
       CROSS JOIN LATERAL unnest(ARRAY[d1, d2, d3, d4, d5, d6, d7, d8]) WITH ORDINALITY AS u(v, ord)),
    8
) AS r);

SELECT r.agent_id, r.is_loop_detected, r.dfa_exponent
FROM (SELECT fractal_agent_detect_loop(
    'bot-stuck',
    (SELECT array_agg(v ORDER BY t, ord)
       FROM generate_series(1, 24) t(t)
       CROSS JOIN LATERAL unnest(
           CASE WHEN t % 2 = 0 THEN ARRAY[1.0, 0.0, 0.0]
                ELSE                 ARRAY[0.0, 1.0, 0.0] END
       ) WITH ORDINALITY AS u(v, ord)),
    3
) AS r);

-- The raw primitives the preset composes, exercised directly: a
-- deterministic period-2 heading log (20 cycles alternating between two
-- headings with small noise), fingerprinted per cycle with
-- fractal_state_fingerprint, then streamed through the registered
-- fractal_cycle_detect. The small noise preserves each heading's
-- direction, so the fingerprints repeat every 2 cycles and the cycle
-- detector (hamming_threshold = 0 -- this fixture's repeats are exact
-- direction repeats) flags the period immediately.
--
-- The jitter is drawn once per heading (odd/even) rather than once per
-- cycle: the fingerprint is direction-based, so a fresh sub-percent
-- jitter per cycle would occasionally flip one of the 64 SimHash bits
-- and break the exact repeat this section is about. Same jitter within a
-- heading, opposite headings point opposite ways -- an exact period-2
-- cycle.
DROP TABLE IF EXISTS vae_heading_log;
CREATE TEMP TABLE vae_heading_log AS
SELECT gs AS cycle, ARRAY[
           CASE WHEN gs % 2 = 1 THEN 0.9 + (vae_rand(10011) - 0.5) * 0.02
                ELSE -0.9 + (vae_rand(10001) - 0.5) * 0.02 END,
           CASE WHEN gs % 2 = 1 THEN 0.1 + (vae_rand(10012) - 0.5) * 0.02
                ELSE -0.1 + (vae_rand(10002) - 0.5) * 0.02 END]::float8[] AS heading
FROM generate_series(1, 20) gs(gs);
CREATE TEMP TABLE vae_heading_fp AS
SELECT cycle, fractal_state_fingerprint(heading, 64, 42.0) AS fp
FROM vae_heading_log ORDER BY cycle;

-- DuckDB binds table-function arguments with the constant binder, which
-- rejects subqueries outright, so the fingerprint list spools through
-- the .output/.read idiom. The fingerprints are BLOBs, so they travel as
-- hex -- from_hex() rebuilds each one in the generated SQL.
.mode list
.headers off
.output vae_cd.sql
SELECT 'SELECT at_index, cycle_len FROM fractal_cycle_detect([' ||
       (SELECT string_agg('from_hex(' || chr(39) || to_hex(fp) || chr(39) || ')', ', ')
          FROM (SELECT fp FROM vae_heading_fp ORDER BY cycle)) ||
       '], 0);'
;
.output stdout
.mode box
.headers on
.read vae_cd.sql

-- ------------------------------------------------------------------
-- 3. fractal_optimize_subset: 15 candidate tasks queued at an edge
-- coordinator, each with a priority VALUE and an upper-bound share of
-- the swarm's remaining shared battery budget it may consume if
-- selected. Pick the best k=5 tasks maximizing total value under that
-- per-task cap and the cardinality constraint -- the "which k tasks
-- are worth routing to the swarm right now" decision. Original work
-- (this SQL entry point's hardcoded objective, per Phase 3's own
-- THIRD-PARTY-NOTICES.md note) -- no citation.
-- ------------------------------------------------------------------
.print
.print === 3. fractal_optimize_subset: battery-constrained task routing (best 5 of 15) ===

DROP TABLE IF EXISTS vae_tasks;
DROP SEQUENCE IF EXISTS seq_vae_tasks_id;
CREATE SEQUENCE seq_vae_tasks_id;
CREATE TABLE vae_tasks (
    id            INTEGER PRIMARY KEY DEFAULT nextval('seq_vae_tasks_id'),
    task_name     text,
    priority      float8,
    battery_share float8
);

-- battery_share range chosen so the top-5 upper bounds comfortably sum
-- past 1.0 -- fractal_optimize_subset requires the k largest
-- upper_bounds to sum to >= 1.0 or no feasible k-subset exists (see
-- include/fractalsql_sql.h's own contract).
INSERT INTO vae_tasks (task_name, priority, battery_share)
SELECT 'task-' || gs,
       round((vae_rand(gs * 10 + 1) * 9 + 1)::numeric, 2)::float8,
       round((0.15 + vae_rand(gs * 10 + 2) * 0.2)::numeric, 3)::float8
FROM generate_series(1, 15) gs(gs);

-- Returns one STRUCT {score, weights} -- struct field access via
-- `.field`, and the nonzero weights walked with unnest WITH ORDINALITY
-- (ordinality is 1-based, matching the id column).
.print (raw primitive -- no preset wraps this function yet)
DROP TABLE IF EXISTS vae_route_result;
CREATE TEMP TABLE vae_route_result AS
SELECT fractal_optimize_subset(
    (SELECT array_agg(priority ORDER BY id) FROM vae_tasks),
    (SELECT array_agg(battery_share ORDER BY id) FROM vae_tasks),
    5, NULL, 0.0, 42
) AS result;

SELECT result.score AS total_value_captured FROM vae_route_result;
SELECT t.task_name, t.priority, t.battery_share, w.weight
FROM vae_route_result r
CROSS JOIN LATERAL unnest(r.result.weights) WITH ORDINALITY AS w(weight, ord)
JOIN vae_tasks t ON t.id = w.ord
WHERE w.weight > 1e-9
ORDER BY w.weight DESC;

-- ------------------------------------------------------------------
-- 4. 10 swarm agents: battery budget, task value, compressed memory
-- vector -- and the routing problem the subset optimizer is actually
-- for: route k tasks across the fleet, each agent's allocation capped
-- by its own battery fraction, so a low-battery drone can still be
-- selected but only take on a proportionally smaller share of the task.
-- ------------------------------------------------------------------
.print
.print === 4. 10 swarm agents + battery-constrained routing across them ===

-- Agent-level fields need one draw per agent; the memory vectors get one
-- draw per (agent, dim) pair via the flat cross join + array_agg (the
-- same no-hoisting pattern section 1 uses). The
-- fixed-width double[16] type is this build's native dimension guard;
-- the reference's CHECK(fractal_vector_dims(memory_vec) = 16) is kept
-- as an explicit second belt over it (cast to float4[] first, since
-- fractal_vector_dims takes LIST(FLOAT)).
DROP TABLE IF EXISTS vae_agents;
DROP SEQUENCE IF EXISTS seq_vae_agents_id;
CREATE SEQUENCE seq_vae_agents_id;
CREATE TABLE vae_agents (
    id          INTEGER PRIMARY KEY DEFAULT nextval('seq_vae_agents_id'),
    agent_id    text,
    battery_pct float8,
    task_value  float8,
    memory_vec  double[16] NOT NULL CHECK (fractal_vector_dims(memory_vec::float4[]) = 16)
);
DROP TABLE IF EXISTS vae_agent_base;
CREATE TEMP TABLE vae_agent_base AS
SELECT gs AS agent_idx,
       lpad(gs::VARCHAR, 2, '0') AS agent_tag,
       20.0 + vae_rand(1000 + gs * 10 + 1) * 75.0 AS battery_pct,
       vae_rand(1000 + gs * 10 + 2) * 10.0 AS task_value
FROM generate_series(1, 10) gs(gs);

-- The trailing ORDER BY b.agent_idx is load-bearing twice over: it fixes
-- the ORDER the rows land in the table, and -- because id comes from the
-- seq_vae_agents_id sequence, assigned in insert order -- it fixes the
-- id each agent gets. The routing section below numbers the fleet by
-- id, so without it the item order handed to the optimizer (and the
-- allocation it returns) would move with the core count.
INSERT INTO vae_agents (agent_id, battery_pct, task_value, memory_vec)
SELECT 'drone-' || b.agent_tag, b.battery_pct, b.task_value,
       array_agg(vae_rand(2000 + b.agent_idx * 100 + d.dim_idx) * 2 - 1 ORDER BY d.dim_idx)
FROM vae_agent_base b
CROSS JOIN generate_series(1, 16) d(dim_idx)
GROUP BY b.agent_idx, b.agent_tag, b.battery_pct, b.task_value
ORDER BY b.agent_idx;

SELECT count(*) AS n_agents, count(DISTINCT memory_vec) AS n_distinct_memory_vecs
FROM vae_agents;

.print --- battery-constrained routing across the fleet (k=4) ---
-- upper_bound = least(battery_pct/100, 1.0): each agent can hold at most
-- its own battery share (least() is DuckDB's scalar two-argument min --
-- min() itself is aggregate-only). The optimizer args are scalar-function
-- arguments, so CTE subqueries are legal here (only TABLE functions
-- need compile-time constants).
WITH agents AS (SELECT agent_id, battery_pct, task_value,
                       least(battery_pct / 100.0, 1.0)::float8 AS upper_bound,
                       row_number() OVER (ORDER BY id) - 1 AS item_idx
                  FROM vae_agents),
     r AS (SELECT fractal_optimize_subset(
               (SELECT array_agg(task_value ORDER BY item_idx) FROM agents),
               (SELECT array_agg(upper_bound ORDER BY item_idx) FROM agents),
               4, NULL, 0.0, 42) AS plan)
SELECT a.agent_id, a.battery_pct, a.task_value,
       uw.weight AS allocation_weight
FROM r
CROSS JOIN LATERAL unnest(r.plan.weights) WITH ORDINALITY AS uw(weight, ord)
JOIN agents a ON a.item_idx = uw.ord - 1
WHERE uw.weight > 1e-9
ORDER BY uw.weight DESC;

-- 5. Headline check -- the demo's own claims, recomputed from the demo's
-- own tables and calls: the agent stuck oscillating between two headings
-- is flagged as a loop while the genuinely exploring agent is not (and
-- neither is a DFA-persistence false positive), the heading log really is
-- a period-2 alternation, and the int8/binary quantization delivers the
-- documented 4x / 32x compression of the 16-dim float4 state.
.print
.print === 5. Headline check ===
WITH explorer_walk(t, d1, d2, d3, d4, d5, d6, d7, d8) AS (
    SELECT t,
           sin(t * 1.41421356), sin(t * 1.73205081), sin(t * 2.23606798),
           sin(t * 2.64575131), sin(t * 3.31662479), sin(t * 3.60555128),
           sin(t * 3.87298335), sin(t * 4.12310563)
    FROM generate_series(1, 24) t(t)
),
explorer_res AS (
    SELECT r.is_loop_detected, r.dfa_exponent
    FROM (SELECT fractal_agent_detect_loop(
              'bot-explorer',
              (SELECT array_agg(v ORDER BY t, ord)
                 FROM explorer_walk
                 CROSS JOIN LATERAL unnest(ARRAY[d1, d2, d3, d4, d5, d6, d7, d8])
                     WITH ORDINALITY AS u(v, ord)),
              8
          ) AS r)
),
stuck_res AS (
    SELECT r.is_loop_detected, r.dfa_exponent
    FROM (SELECT fractal_agent_detect_loop(
              'bot-stuck',
              (SELECT array_agg(v ORDER BY t, ord)
                 FROM generate_series(1, 24) t(t)
                 CROSS JOIN LATERAL unnest(
                     CASE WHEN t % 2 = 0 THEN ARRAY[1.0, 0.0, 0.0]
                          ELSE                 ARRAY[0.0, 1.0, 0.0] END
                 ) WITH ORDINALITY AS u(v, ord)),
              3
          ) AS r)
),
quant AS (
    -- vae_quantized stores the raw codes; the byte counts are derived
    -- here exactly as section 1 derives them (int8 = 1 byte/dim, binary
    -- = 1 bit/dim, against a float4[16] state's 64 bytes -> 4x / 32x).
    SELECT id,
           json_array_length(int8_codes::VARCHAR) AS int8_bytes,
           octet_length(binary_code)              AS binary_bytes
    FROM vae_quantized
)
SELECT 'HEADLINE kit=agentic-edge-swarm ' || CASE WHEN
    (SELECT is_loop_detected FROM stuck_res) = true
    AND (SELECT is_loop_detected FROM explorer_res) = false
    AND (SELECT dfa_exponent FROM stuck_res) = 0.0
    AND (SELECT dfa_exponent FROM explorer_res) < 0.9
    AND (SELECT count(*) FROM vae_heading_log) = 20
    AND (SELECT count(*) FROM vae_heading_log WHERE cycle % 2 = 1 AND heading[1] > 0) = 10
    AND (SELECT count(*) FROM vae_heading_log WHERE cycle % 2 = 0 AND heading[1] < 0) = 10
    AND (SELECT count(*) FROM quant WHERE int8_bytes = 16 AND binary_bytes = 2) = 20
  THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vae_nodes;
.print   DROP TABLE vae_tasks;
.print   DROP TABLE vae_agents;
.print (the vae_* TEMP tables evaporate with the connection; one TABLE
.print per statement -- DuckDB's DROP TABLE takes a single table.)
.print ================================================================
