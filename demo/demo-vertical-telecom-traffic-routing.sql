-- demo/demo-vertical-telecom-traffic-routing.sql
--
-- Industry vertical: telecom -- dynamic traffic and bandwidth dispatch to
-- the best-capable network node under a capacity budget.  DOMAIN kit
-- built on one installed agent, fractal_agent_route_task, reused
-- verbatim: it matches each incoming request to the best-capable node
-- under a token budget, exactly its designed contract.
--
-- Scope note: this is nearest-capable-node dispatch, not multi-hop
-- rerouting around a failed node (graph routing is a different problem).
-- Load awareness comes from routing over a table of only the nodes that
-- still have headroom.
--
-- Prerequisites: extension installed.  The hand-composed routing needs no
-- model; the shipped agent returns a reasoned rationale
-- (docs/reasoning-setup.md).
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; cat demo/demo-vertical-telecom-traffic-routing.sql; } \
--       | duckdb -unsigned
--
-- Safe to re-run: ttr_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * Vectors are [bandwidth, latency_sensitivity, loss_tolerance,
--     region_affinity] as float8[4].  A request vector says what the
--     session needs; a node vector says what the node is good at.
--   * The agent reads a table by name through its own connection, so the
--     available-nodes set is a regular table (a TEMP table is invisible
--     to it), recreated each time it changes.
--   * fractal_search_telemetry returns the row's rowid as doc_id and takes
--     a literal query vector, so Section 2 writes the five request vectors
--     out; the agent (a scalar) reads them from the table.

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Network nodes (capability vector + current load) and five
-- incoming session requests.
-- ------------------------------------------------------------------
.print
.print === 1. Nodes and incoming requests ===

DROP TABLE IF EXISTS ttr_nodes;
DROP SEQUENCE IF EXISTS seq_ttr_nodes_id;
CREATE SEQUENCE seq_ttr_nodes_id;
CREATE TABLE ttr_nodes (
    id        INTEGER PRIMARY KEY DEFAULT nextval('seq_ttr_nodes_id'),
    node      text,
    capacity  int,        -- sessions
    node_load int,        -- sessions now
    caps      float8[4]
);
INSERT INTO ttr_nodes (node, capacity, node_load, caps) VALUES
    ('edge-core-east',   400, 120, [0.95, 0.20, 0.10, 0.90]),   -- bulk bandwidth, east region
    ('edge-lowlat-west', 150,  60, [0.30, 0.95, 0.15, 0.10]),   -- low latency, west region
    ('edge-mobile-hub',  250, 200, [0.50, 0.50, 0.85, 0.50]),   -- loss-tolerant mobile traffic
    ('edge-backup-west', 200,  20, [0.55, 0.55, 0.40, 0.15]);   -- general purpose, west

DROP TABLE IF EXISTS ttr_requests;
DROP SEQUENCE IF EXISTS seq_ttr_requests_id;
CREATE SEQUENCE seq_ttr_requests_id;
CREATE TABLE ttr_requests (
    id    INTEGER PRIMARY KEY DEFAULT nextval('seq_ttr_requests_id'),
    label text,
    need  float8[4]
);
INSERT INTO ttr_requests (label, need) VALUES
    ('R1 bulk video backhaul, east',     [0.90, 0.15, 0.10, 0.85]),
    ('R2 cloud-gaming session, west',    [0.35, 0.92, 0.12, 0.12]),
    ('R3 mobile handover burst',         [0.45, 0.50, 0.88, 0.45]),
    ('R4 enterprise VPN, west',          [0.50, 0.60, 0.30, 0.12]),
    ('R5 software update fan-out, east', [0.92, 0.10, 0.20, 0.88]);

SELECT node, capacity, node_load, round(100.0 * node_load / capacity) AS pct_loaded FROM ttr_nodes;

-- ------------------------------------------------------------------
-- 2. Hand-composed dispatch: nearest node by capability, per request.
-- confidence = 1/(1+distance).
-- ------------------------------------------------------------------
.print
.print === 2. Hand-composed dispatch: nearest capable node per request ===

WITH hits AS (
    SELECT 1 AS rid, doc_id, distance FROM fractal_search_telemetry('ttr_nodes', 'caps', [0.90, 0.15, 0.10, 0.85]::float8[], 1)
    UNION ALL
    SELECT 2, doc_id, distance FROM fractal_search_telemetry('ttr_nodes', 'caps', [0.35, 0.92, 0.12, 0.12]::float8[], 1)
    UNION ALL
    SELECT 3, doc_id, distance FROM fractal_search_telemetry('ttr_nodes', 'caps', [0.45, 0.50, 0.88, 0.45]::float8[], 1)
    UNION ALL
    SELECT 4, doc_id, distance FROM fractal_search_telemetry('ttr_nodes', 'caps', [0.50, 0.60, 0.30, 0.12]::float8[], 1)
    UNION ALL
    SELECT 5, doc_id, distance FROM fractal_search_telemetry('ttr_nodes', 'caps', [0.92, 0.10, 0.20, 0.88]::float8[], 1))
SELECT r.label, n.node AS routed_to,
       round(1.0 / (1.0 + h.distance), 4) AS confidence
FROM hits h
JOIN ttr_requests r ON r.id = h.rid
JOIN ttr_nodes n ON n.rowid::VARCHAR = h.doc_id::VARCHAR
ORDER BY r.id;

-- ------------------------------------------------------------------
-- 3. The shipped agent, one call per request, under a 1000-token budget
-- (reasoning plugin for the rationale).  remaining_budget shows each
-- routing decision's cost.
-- ------------------------------------------------------------------
.print
.print === 3. fractal_agent_route_task (budget 1000) ===

SELECT r.label,
       json_extract_string(a, '$.routed_to')        AS routed_to,
       round(json_extract(a, '$.confidence')::double, 4) AS confidence,
       json_extract(a, '$.remaining_budget')        AS remaining_budget,
       json_extract_string(a, '$.rationale')        AS rationale
FROM (SELECT id, label, fractal_agent_route_task(need, 'ttr_nodes', 'caps', 'node', 1000) AS a
        FROM ttr_requests) r
ORDER BY r.id;

-- ------------------------------------------------------------------
-- 4. Load awareness: edge-mobile-hub is at 80% load.  Route over only
-- the nodes with headroom (below 75% loaded) and R3 is re-homed.
-- ------------------------------------------------------------------
.print
.print === 4. Route over nodes with headroom (< 75% loaded) ===

DROP TABLE IF EXISTS ttr_available;
CREATE TABLE ttr_available AS
SELECT node, caps FROM ttr_nodes WHERE 100.0 * node_load / capacity < 75 ORDER BY id;

SELECT r.label, json_extract_string(a, '$.routed_to') AS routed_to
FROM (SELECT id, label, fractal_agent_route_task(need, 'ttr_available', 'caps', 'node', 1000) AS a
        FROM ttr_requests) r
ORDER BY r.id;

-- ------------------------------------------------------------------
-- 5. Reasoning: the dispatch summary (needs the reasoning plugin).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: dispatch summary ===

SELECT fractal_reason(
    'one-line summary of how these session requests were dispatched and why one was re-homed',
    (SELECT string_agg(r.label || ' -> ' || json_extract_string(r.a, '$.routed_to'), '; ' ORDER BY r.id)
       FROM (SELECT id, label, fractal_agent_route_task(need, 'ttr_available', 'caps', 'node', 1000) AS a
               FROM ttr_requests) r)) AS summary;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE ttr_nodes, ttr_requests, ttr_available;
