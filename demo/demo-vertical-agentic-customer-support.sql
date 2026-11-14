-- =============================================================================
-- FractalSQL Industry Vertical Demo: Stateful Session & Churn Drift
-- =============================================================================
-- End-to-end regression test for the trajectory-forecast agent. Exercises:
--   * fractal_agent_trajectory_predict  -- reads the baseline vector (by
--     PK = baseline_id) and the latest vector (max PK) from the table,
--     derives dim from the data, computes a real delta, and searches the
--     corpus for the nearest predicted state -- it runs unwrapped on the
--     3-dim state_vector column here.
--   * fractal_search_explore            -- pure-C Scout search on a literal vector
--   * fractal_agent_recall_hybrid       -- hybrid memory recall composition
--   * fractal_agent_recommend_diverse   -- repulsion-guided diverse recommendations
--   * fractal_diversify_enable
-- Re-runnable (DROP at the top).
-- =============================================================================

-- Notes:
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=agentic-customer-support ok);
--     the build_test kit gate greps for it.

-- (Three separate DROPs -- DuckDB's DROP TABLE takes exactly one table
-- and has no comma-list or CASCADE suffix; these tables share no FK
-- chains, so nothing depends on drop order.)
DROP TABLE IF EXISTS customer_sessions;
DROP TABLE IF EXISTS customer_playbook;
DROP TABLE IF EXISTS product_catalog;

-- 1. Setup customer session telemetry -- a single customer (cust-abc) drifting
-- from onboarding toward churn across five sessions. session_id is the PK the
-- trajectory_predict agent resolves the baseline row by; the latest row (max
-- PK, session_id = 103) is "current", and baseline_id (100) is "baseline".
CREATE TABLE customer_sessions (
    session_id        bigint PRIMARY KEY,
    customer_id       text,
    state_vector      float8[],
    sentiment_score    float8,
    last_interaction  timestamp
);

INSERT INTO customer_sessions (session_id, customer_id, state_vector, sentiment_score, last_interaction)
VALUES
(100, 'cust-abc', ARRAY[0.1, 0.1, 0.1], 0.8, now() - interval '30 days'),
(101, 'cust-abc', ARRAY[0.3, 0.15, 0.1], 0.6, now() - interval '20 days'),
(102, 'cust-abc', ARRAY[0.6, 0.2, 0.1], 0.4, now() - interval '10 days'),
(103, 'cust-abc', ARRAY[0.8, 0.2, 0.1], 0.2, now());

-- 2. A playbook of past churn-recovery cases: what worked (or didn't) for
-- other customers whose state vector, at the point of intervention, looked
-- like this. fractal_agent_recall_hybrid searches this by real vector
-- similarity against session 103's current state.
CREATE TABLE customer_playbook (
    case_id       bigint PRIMARY KEY,
    customer_id   text,
    state_vector  float8[],
    resolution    text
);

INSERT INTO customer_playbook (case_id, customer_id, state_vector, resolution) VALUES
(1, 'cust-def', ARRAY[0.75, 0.22, 0.12], 'Escalated to a retention specialist with a loyalty discount; saved'),
(2, 'cust-ghi', ARRAY[0.30, 0.10, 0.05], 'Proactive check-in call resolved early-stage frustration'),
(3, 'cust-jkl', ARRAY[0.82, 0.18, 0.09], 'Offered a downgrade path instead of cancellation; saved'),
(4, 'cust-mno', ARRAY[0.05, 0.05, 0.05], 'No intervention needed, healthy customer');

-- 3. A retention-offer catalog for recommend_diverse to pick a diverse,
-- non-redundant set of interventions from.
CREATE TABLE product_catalog (
    item_id  bigint PRIMARY KEY,
    name     text,
    emb      float8[]
);

INSERT INTO product_catalog (item_id, name, emb) VALUES
(1, 'Loyalty Discount 20%',      ARRAY[0.80, 0.20, 0.10]),
(2, 'Free Premium Upgrade',      ARRAY[0.75, 0.25, 0.15]),
(3, 'Dedicated Support Line',    ARRAY[0.60, 0.30, 0.20]),
(4, 'Downgrade to Basic Plan',   ARRAY[0.40, 0.10, 0.05]),
(5, 'Early Renewal Bonus',       ARRAY[0.20, 0.10, 0.10]);

-- -----------------------------------------------------------------------------
-- DEMONSTRATION
-- -----------------------------------------------------------------------------

-- 4. Enable stateful diversification to avoid repeating failed scripts
.print === 4. Enable stateful diversification ===
SELECT fractal_diversify_enable();

-- 5. Forecast trajectory drift toward churn
-- The REAL installed agent: searches the corpus for the nearest predicted
-- state to the delta between the baseline session (100) and the latest
-- session (103). Returns a real predicted_state_vector (length 3, derived
-- from the data) and a projected_drift_delta.
.print
.print === 5. fractal_agent_trajectory_predict (baseline = onboarding) ===
SELECT * FROM fractal_agent_trajectory_predict(
    'customer_sessions', 'state_vector',
    100,  -- baseline_id (onboarding)
    5     -- forecast steps
);

-- 6. Hybrid Memory Recall (the recall_hybrid composition)
-- Recall past playbook cases whose state vector, at intervention time, was
-- close to this customer's current drifting state (session 103) -- the
-- registered fractal_hybrid_clinical_search table function directly. doc_id
-- is the row's rowid, stringified (the join below).
.print
.print === 6. Hybrid memory recall over the playbook ===
-- Table-function args are constant-only in DuckDB, so the cohort
-- spools through the .once/.read idiom (demo-agents.sql 6a/13a):
.mode list
.headers off
.output vcs_hs.sql
SELECT 'SELECT m.case_id AS mem_id, m.resolution AS content FROM fractal_hybrid_clinical_search(''customer_playbook'', ''state_vector'', [0.8, 0.2, 0.1]::DOUBLE[], ' ||
       (SELECT '[' || string_agg('''' || rowid::VARCHAR || '''', ', ') || ']'
          FROM customer_playbook) ||
       ', 5) hs JOIN customer_playbook m ON m.rowid::text = hs.doc_id ORDER BY hs.distance;'
;
.output stdout
.mode box
.headers on
.read vcs_hs.sql
.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_recall_hybrid(
    'customer_playbook', 'state_vector',
    ARRAY[0.8, 0.2, 0.1]::float8[],
    NULL, NULL,   -- no cohort filter: search the whole playbook
    5, 'case_id', 'resolution'
);

-- 7. Repulsion-guided intervention
-- Scout Discovery over the session states: the most diverse
-- (non-redundant) recovery strategies for this customer's current state.
.print
.print === 7. Scout Discovery over the session states ===
SELECT particle FROM fractal_search_explore(
    'customer_sessions', 'state_vector',
    ARRAY[0.8, 0.2, 0.1]::float8[],
    '{"population_size": 5}'
);

-- 8. Diverse Recommendations (the recommend_diverse composition)
-- Repulsion-diverse top-k retention offers for this customer's current
-- state. item_id is the REAL catalog id; score is 1 - cosine_distance
-- (real, from the primitive).
.print
.print === 8. Repulsion-diverse retention offers ===
SELECT m.item_id       AS item_id,
       m.name          AS name,
       1.0 - t.distance AS score
FROM fractal_search_telemetry('product_catalog', 'emb',
                              ARRAY[0.8, 0.2, 0.1]::float8[], 5) t
JOIN product_catalog m ON m.rowid::text = t.doc_id
ORDER BY t.distance;
.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_recommend_diverse(
    'product_catalog', 'emb',
    ARRAY[0.8, 0.2, 0.1]::float8[],
    5, 'item_id'
);

-- Reset the session-global diversify flag enabled in section 4.
SELECT fractal_diversify_disable();

-- 9. Headline check -- the demo's own claims, recomputed from the demo's
-- own tables and calls: the trajectory agent forecasts the churn-drifted
-- state [0.8, 0.2, 0.1] (session 103, the max-PK row) with a small but
-- non-zero drift delta, the hybrid recall surfaces playbook case 3 (the
-- downgrade path) as the nearest past case for that state, and the offer
-- set leads with the two direction-identical catalog items (1 and 4).
.print
.print === 9. Headline check ===
WITH traj AS (
    SELECT predicted_state_vector, projected_drift_delta
    FROM fractal_agent_trajectory_predict('customer_sessions', 'state_vector', 100, 5)
),
mem AS (
    SELECT row_number() OVER () AS rk,
           json_extract_string(m, '$.mem_id') AS mem_id
    FROM (SELECT unnest(from_json(fractal_agent_recall_hybrid(
              'customer_playbook', 'state_vector', [0.8, 0.2, 0.1]::float8[],
              NULL, NULL, 5, 'case_id', 'resolution'), '["JSON"]')) AS m)
),
offers AS (
    SELECT m.item_id, t.distance
    FROM fractal_search_telemetry('product_catalog', 'emb',
                                  [0.8, 0.2, 0.1]::float8[], 5) t
    JOIN product_catalog m ON m.rowid::text = t.doc_id
)
SELECT 'HEADLINE kit=agentic-customer-support ' || CASE WHEN
    (SELECT predicted_state_vector FROM traj)
        = (SELECT state_vector FROM customer_sessions WHERE session_id = 103)
    AND (SELECT projected_drift_delta FROM traj) > 0
    AND (SELECT projected_drift_delta FROM traj) < 0.05
    AND (SELECT count(*) FROM mem) = 4
    AND (SELECT mem_id FROM mem ORDER BY rk LIMIT 1) = '3'
    AND (SELECT string_agg(mem_id, ',' ORDER BY mem_id) FROM mem) = '1,2,3,4'
    AND (SELECT count(*) FROM offers) = 5
    AND (SELECT count(*) FROM offers WHERE distance < 1e-6) = 2
    AND (SELECT min(item_id) FROM offers WHERE distance < 1e-6) = 1
    AND (SELECT max(item_id) FROM offers WHERE distance < 1e-6) = 4
    AND (SELECT max(session_id) FROM customer_sessions) = 103
    AND (SELECT sentiment_score FROM customer_sessions WHERE session_id = 103)
        = (SELECT min(sentiment_score) FROM customer_sessions)
  THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print ================================================================
.print Demo complete. Tables left in place for inspection -- drop them
.print to re-run:
.print   DROP TABLE customer_sessions;
.print   DROP TABLE customer_playbook;
.print   DROP TABLE product_catalog;
.print (one DROP per statement -- DuckDB's DROP TABLE takes exactly one
.print table.)
.print ================================================================
