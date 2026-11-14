-- demo/demo-vertical-v2x-warranty-triage.sql
--
-- Industry vertical: connected-vehicle (V2X) diagnostics -- routing an
-- incoming trouble-code event to the right repair workflow and recalling
-- similar historical warranty claims.  AGENTIC kit: two installed agents
-- are chained, shown hand-composed first and then as the shipped
-- one-call agents.
--
--   1. fractal_agent_route_task -- matches the incoming telemetry event
--      to the best-capable sub-agent / repair workflow under a token
--      budget, exactly its designed contract.
--   2. fractal_agent_recall_hybrid -- fuses a strict metadata filter
--      (component) with drift-vector search to recall similar historical
--      claims; a two-predicate cohort (model year AND component) is shown
--      with fractal_hybrid_clinical_search.
--   3. A closing fractal_reason() produces the dispatch + claim-context
--      summary.
--
-- Prerequisites: extension installed.  route_task and the closing summary
-- are reasoning-bearing (docs/reasoning-setup.md); recall_hybrid is pure
-- retrieval and the hand-composed sections need no model at all.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; cat demo/demo-vertical-v2x-warranty-triage.sql; } \
--       | duckdb -unsigned
--
-- Safe to re-run: v2x_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * Capability and claim vectors are float8[]; the DTC event embedding
--     shares the capability table's 3 dimensions.  In production the
--     embeddings come from your embedding endpoint (see
--     docs/vectorizer-setup.md); here they are hand-placed so the routing
--     and recall answers are readable.
--   * Row locators: fractal_search_telemetry / _hybrid_clinical_search
--     return DuckDB's rowid as doc_id, and the hybrid search takes its
--     cohort as a list of rowid strings.  A table function takes literal
--     arguments, so Section 3's cohort is written out (Section 1 prints
--     it from the table so you can see it matches); the agents are
--     scalars and read everything from the tables.

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Repair-workflow capability table and the historical claims table.
-- ------------------------------------------------------------------
.print
.print === 1. Capability table + historical warranty claims ===

DROP TABLE IF EXISTS v2x_capabilities;
DROP SEQUENCE IF EXISTS seq_v2x_capabilities_id;
CREATE SEQUENCE seq_v2x_capabilities_id;
CREATE TABLE v2x_capabilities (
    id       INTEGER PRIMARY KEY DEFAULT nextval('seq_v2x_capabilities_id'),
    workflow text,
    emb      float8[3]
);
INSERT INTO v2x_capabilities (workflow, emb) VALUES
    ('battery-thermal-service',  [0.90, 0.10, 0.10]),
    ('powertrain-inverter-swap', [0.10, 0.90, 0.10]),
    ('adas-sensor-recalibration',[0.10, 0.10, 0.90]),
    ('software-ota-reflash',     [0.50, 0.50, 0.50]);

DROP TABLE IF EXISTS v2x_claims;
DROP SEQUENCE IF EXISTS seq_v2x_claims_id;
CREATE SEQUENCE seq_v2x_claims_id;
CREATE TABLE v2x_claims (
    id         INTEGER PRIMARY KEY DEFAULT nextval('seq_v2x_claims_id'),
    vin        text,
    model_year int,
    component  text,
    note       text,
    drift_vec  float8[4]
);
INSERT INTO v2x_claims (vin, model_year, component, note, drift_vec) VALUES
    ('VIN-A01', 2023, 'battery-pack', 'coolant pump intermittent, pack temp spike on fast charge', [0.80, 0.60, 0.10, 0.10]),
    ('VIN-A02', 2023, 'battery-pack', 'cell imbalance after winter, SoH below threshold',          [0.70, 0.20, 0.60, 0.10]),
    ('VIN-A03', 2024, 'battery-pack', 'pack temp spike on fast charge, coolant valve stuck',       [0.82, 0.58, 0.12, 0.08]),
    ('VIN-A04', 2024, 'battery-pack', 'contactor chatter at low state of charge',                  [0.20, 0.10, 0.90, 0.30]),
    ('VIN-B01', 2023, 'inverter',     'inverter overtemp derate under tow load',                   [0.55, 0.85, 0.10, 0.20]),
    ('VIN-B02', 2024, 'inverter',     'phase current ripple, NVH complaint',                       [0.15, 0.30, 0.20, 0.90]),
    ('VIN-C01', 2023, 'adas-sensor',  'forward radar misalignment after windshield replacement',   [0.10, 0.20, 0.30, 0.70]),
    ('VIN-C02', 2024, 'adas-sensor',  'camera calibration drift, lane-keep disengages',            [0.12, 0.18, 0.28, 0.75]);

SELECT component, count(*) AS claims FROM v2x_claims GROUP BY component ORDER BY component;

.print --- the 2024 battery-pack cohort as rowids (used literally in Section 3) ---
SELECT list(rowid::VARCHAR ORDER BY rowid) AS cohort_rowids
  FROM v2x_claims WHERE model_year = 2024 AND component = 'battery-pack';

-- ------------------------------------------------------------------
-- 2. Step 1, hand-composed: route the incoming event.  The DTC event is
-- a battery thermal fault -- its embedding sits nearest the battery-
-- thermal workflow.  confidence = 1/(1+distance).
-- ------------------------------------------------------------------
.print
.print === 2. Step 1 (hand-composed): route the incoming DTC event ===

SELECT c.workflow                              AS routed_to,
       round(1.0 / (1.0 + t.distance), 4)      AS confidence,
       1000 - 150                              AS remaining_budget   -- budget less one routing decision
FROM fractal_search_telemetry('v2x_capabilities', 'emb', [0.85, 0.15, 0.12]::float8[], 1) t
JOIN v2x_capabilities c ON c.rowid::VARCHAR = t.doc_id::VARCHAR;

.print --- the shipped agent: same composition, one call (reasoning plugin) ---
SELECT json_extract_string(j, '$.routed_to')                 AS routed_to,
       round(json_extract(j, '$.confidence')::double, 4)     AS confidence,
       json_extract(j, '$.remaining_budget')                 AS remaining_budget,
       json_extract_string(j, '$.rationale')                 AS rationale
FROM (SELECT fractal_agent_route_task(
    [0.85, 0.15, 0.12]::float8[], 'v2x_capabilities', 'emb', 'workflow', 1000) AS j);

-- ------------------------------------------------------------------
-- 3. Step 2, hand-composed: two-predicate cohort (model year 2024 AND
-- battery pack), then a vector search restricted to it -- the cohort a
-- single (filter_col, filter_val) pair cannot express.
-- ------------------------------------------------------------------
.print
.print === 3. Step 2 (hand-composed): similar 2024 battery-pack claims ===

SELECT c.vin, c.model_year, c.note, round(h.distance, 4) AS distance
FROM fractal_hybrid_clinical_search(
         'v2x_claims', 'drift_vec', [0.80, 0.60, 0.10, 0.10]::float8[],
         ['2', '3'], 3) h
JOIN v2x_claims c ON c.rowid::VARCHAR = h.doc_id::VARCHAR
ORDER BY h.distance;

-- ------------------------------------------------------------------
-- 4. Step 2, productized: fractal_agent_recall_hybrid with a strict
-- metadata filter (component = 'battery-pack'); pure retrieval, no
-- model.  mem_id / content are the real claim id and note.
-- ------------------------------------------------------------------
.print
.print === 4. Step 2 (shipped agent): fractal_agent_recall_hybrid ===

SELECT json_extract(m, '$.mem_id')              AS mem_id,
       json_extract_string(m, '$.content')      AS content
FROM (SELECT unnest(from_json(fractal_agent_recall_hybrid(
    'v2x_claims', 'drift_vec', [0.80, 0.60, 0.10, 0.10]::float8[],
    'component', 'battery-pack', 3, 'id', 'note'), '["JSON"]')) AS m);

-- ------------------------------------------------------------------
-- 5. Reasoning: the dispatch + claim-context summary (needs the
-- reasoning plugin).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: dispatch + claim-context summary ===

SELECT fractal_reason(
    'one-line dispatch recommendation plus warranty context for this connected-vehicle fault',
    json_object(
      'routing', json(fractal_agent_route_task([0.85, 0.15, 0.12]::float8[],
                         'v2x_capabilities', 'emb', 'workflow', 1000)),
      'similar_claims', json(fractal_agent_recall_hybrid('v2x_claims', 'drift_vec',
                              [0.80, 0.60, 0.10, 0.10]::float8[],
                              'component', 'battery-pack', 3, 'id', 'note')))::VARCHAR) AS summary;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE v2x_capabilities, v2x_claims;
