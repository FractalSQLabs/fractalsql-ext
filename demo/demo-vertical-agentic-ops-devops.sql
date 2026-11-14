-- =============================================================================
-- FractalSQL Industry Vertical Demo: Autonomous Incident Triage & Self-Healing
-- =============================================================================
-- End-to-end regression test for the embed-coupled agents. Exercises:
--   * fractal_agent_detect_loop   -- period-2 loop detection via SimHash +
--                                    Brent's cycle detection (the state_hash
--                                    toggle, one-hot encoded into
--                                    2-dimensional directions, flags via the
--                                    fingerprint-cycle check even though its
--                                    DFA alpha is 0)
--   * fractal_search_agent        -- runs on the real 768-dim embedding
--                                    column (a wrong column type is a clean
--                                    ERROR, not a backend crash)
--   * fractal_rag_agent           -- retrieve-then-reason over the corpus
--   * fractal_dimension_drift     -- non-degenerate drifting latency series
--   * fractal_agent_route_task, fractal_agent_outlier_intercept,
--     fractal_agent_anomaly_triage -- task routing, outlier interception,
--     and drift+reason threat triage agents
-- Re-runnable: tear down a prior run's vectorizer rows first (the
-- vectorizer config persists in the fractal_vectorizers table; clearing it
-- makes a re-run's fractal_vectorizer_create succeed), then drop the demo
-- tables. The bookkeeping bootstrap mirrors the vectorizer surfaces' own
-- IF NOT EXISTS schema so the DELETEs are no-ops on a fresh database.
-- =============================================================================

-- Notes:
--   * bot-deploy-01's state_hash is a clean 12345 <-> 67890 period-2 toggle:
--     the fingerprint-cycle check flags it (is_loop_detected = true) even
--     though its DFA exponent is 0, the incident routes to the root-cause
--     analyzer, the proposed state matches known-bad state 1 (intercepted),
--     and the latency series really does drift.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=agentic-ops-devops ok);
--     the build_test kit gate greps for it.

CREATE SEQUENCE IF NOT EXISTS fractal_vectorizer_id_seq START 1;
CREATE TABLE IF NOT EXISTS fractal_vectorizers (
  id BIGINT PRIMARY KEY,
  source_table VARCHAR NOT NULL,
  source_pk_col VARCHAR NOT NULL,
  text_col VARCHAR NOT NULL,
  embedding_col VARCHAR NOT NULL,
  options VARCHAR NOT NULL DEFAULT '{}',
  enabled BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (source_table, text_col, embedding_col)
);
CREATE TABLE IF NOT EXISTS fractal_vectorizer_queue (
  vectorizer_id BIGINT NOT NULL,
  pk_value VARCHAR NOT NULL,
  status VARCHAR NOT NULL DEFAULT 'pending',
  enqueued_at TIMESTAMP NOT NULL DEFAULT now(),
  started_at TIMESTAMP,
  error VARCHAR
);
DELETE FROM fractal_vectorizer_queue WHERE vectorizer_id IN
    (SELECT id FROM fractal_vectorizers WHERE source_table = 'incident_logs');
DELETE FROM fractal_vectorizers WHERE source_table = 'incident_logs';
-- (one table per statement -- DuckDB's DROP TABLE takes a single table)
DROP TABLE IF EXISTS incident_logs;
DROP TABLE IF EXISTS agent_capabilities;
DROP TABLE IF EXISTS known_bad_states;

-- 1. Setup synthetic incident telemetry
CREATE TABLE incident_logs (
    id          bigint PRIMARY KEY,
    agent_id    text,
    state_hash  bigint,        -- period-2 loop indicator (12345 / 67890)
    latency_ms  float8,        -- drifting metric -> fractal_dimension_drift
    body        text,           -- human-readable event line, vectorized below
    -- float8[768]: this build has no fractal_vector catalog type (see
    -- docs/api-analytics.md), and fractal_embed() returns
    -- LIST(DOUBLE), so this needs float8/DOUBLE, not float4.
    embedding   float8[768],  -- populated by the vectorizer (nomic-embed-text)
    event_ts    timestamp,
    payload     text
);

-- Simulate a deployment bot stuck in an infinite retry loop: the state_hash
-- toggles 12345<->67890 every cycle (a clean period-2 sequence -- detect_loop
-- flags it via the short-period check, even though its DFA alpha is
-- ~0.1, well below the 0.9 threshold). The latency_ms series is a genuinely
-- drifting (non-degenerate) signal -- a baseline ~50ms for the first 64 cycles,
-- then a +30ms step-up over the most recent 32 cycles (the loop degrading
-- latency) -- so fractal_dimension_drift succeeds with a 32-point recent
-- window (DFA needs the recent window large enough; window=16 is too small).
-- The body text is what the vectorizer embeds for search_agent / rag_agent.
INSERT INTO incident_logs (id, agent_id, state_hash, latency_ms, body, event_ts, payload)
SELECT gs, 'bot-deploy-01',
       CASE WHEN gs % 2 = 1 THEN 12345 ELSE 67890 END,
       50.0 + (gs % 8)::float8 * 1.3 + CASE WHEN gs > 64 THEN 30.0 ELSE 0.0 END,
       CASE WHEN gs % 2 = 1
            THEN 'bot-deploy-01 retrying authentication: identity service refused connection (attempt ' || gs || ')'
            ELSE 'bot-deploy-01 health check completed: all subsystems nominal (cycle ' || gs || ')'
       END,
       now() - (96 - gs) * interval '1 second',
       CASE WHEN gs % 2 = 1 THEN '{"event": "retry_auth"}'
            ELSE '{"event": "check_health"}' END
FROM generate_series(1, 96) AS gs(gs);

-- A few healthy logs from a second bot (ids 97-99, outside bot-deploy-01's range).
INSERT INTO incident_logs (id, agent_id, state_hash, latency_ms, body, event_ts, payload)
VALUES
(97, 'bot-deploy-02', 11111, 42.0, 'bot-deploy-02 deployed configuration v2.3 successfully', now(), '{"event": "init"}'),
(98, 'bot-deploy-02', 22222, 45.0, 'bot-deploy-02 applied rolling update to worker pool',    now(), '{"event": "config"}'),
(99, 'bot-deploy-02', 33333, 48.0, 'bot-deploy-02 deployment finalized, rollout green',      now(), '{"event": "deploy"}');

-- 2. Vectorize the incident body text into 768-dim embeddings. The vectorizer
-- backfills the already-inserted rows into its queue, then process_queue embeds
-- them in batches (default batch_size=100 rows per pass; nomic-embed-text ->
-- 768 dims). Without an endpoint configured, process_queue marks the rows
-- failed with a clean last_error (see demo-vectorizer.sql). This is the
-- embedding-width column the embed-coupled agents (search_agent, rag_agent) need.
.print === 2. Vectorize the incident body text ===
SELECT fractal_vectorizer_create('incident_logs', 'id', 'body', 'embedding');
-- (process_queue claims at most batch_size=100 queue ids per pass, so
-- the 96+3-row queue drains in one pass; the drain pass below returns 0.)
.print --- pass 1 (the 99-row backfill queue) ---
SELECT fractal_vectorizer_process_queue();   -- returns the number of rows embedded
.print --- drain pass (the remainder -- expect 0) ---
SELECT fractal_vectorizer_process_queue();

-- 3. Setup capabilities map for routing
CREATE TABLE agent_capabilities (
    capability_name text PRIMARY KEY,
    embedding float8[]
);

INSERT INTO agent_capabilities (capability_name, embedding)
VALUES
('root-cause-analyzer', ARRAY[0.1, 0.2, 0.3]),
('rollback-executor', ARRAY[0.9, 0.8, 0.7]);

-- A small library of known-bad deployment states for
-- fractal_agent_outlier_intercept to screen proposed actions against.
CREATE TABLE known_bad_states (
    state_id     bigint PRIMARY KEY,
    description  text,
    state_vec    float8[]
);
INSERT INTO known_bad_states (state_id, description, state_vec) VALUES
(1, 'auth-service unreachable, retry storm',  ARRAY[0.5, 0.5, 0.5]),
(2, 'disk pressure cascading restarts',       ARRAY[0.9, 0.1, 0.2]);

-- -----------------------------------------------------------------------------
-- DEMONSTRATION
-- -----------------------------------------------------------------------------

-- 4. Loop Detection via SimHash-fingerprinted cycle detection + DFA
-- (current implementation: fractal_agent_detect_loop fingerprints real state
-- vectors and streams them through Brent's cycle detector, rather than an
-- exact-hash period scan). fsql_state_fingerprint is a cosine/direction-
-- based SimHash (consistent with this whole extension's cosine-distance
-- search functions) -- it is invariant to magnitude, so a raw scalar
-- state_hash cast to a 1-dimensional vector would collapse to just its
-- sign (both 12345 and 67890 are positive, so EVERY same-signed sequence
-- would false-positive as "looping", not only a genuine toggle). Each
-- state_hash is instead one-hot encoded into a 2-dimensional direction
-- (12345 -> [1,0], 67890 -> [0,1]) so the two states are genuinely
-- distinguishable by direction. The state_hash sequence is a clean
-- 12345<->67890 period-2 toggle, so this one-hot direction toggles
-- cleanly too. Its DFA exponent over the L2-norm trajectory is 0 (a
-- one-hot vector's norm never changes), well below the 0.9 threshold, so
-- the DFA signal alone would NOT flag it -- but the fingerprint-cycle
-- check does (a clean period-2 toggle closes the cycle detector's
-- Hamming-0 checkpoint immediately). Result: is_loop_detected = true.
.print
.print === 4. fractal_agent_detect_loop (period-2 state toggle, one-hot directions) ===
-- fractal_agent_detect_loop is a SCALAR function returning a STRUCT, so
-- it is called in the select list, not in FROM (a scalar has no table
-- form). The struct's fields are then projected by name.
SELECT r.agent_id, r.is_loop_detected, r.dfa_exponent
FROM (SELECT fractal_agent_detect_loop(
    'bot-deploy-01',
    (SELECT array_agg(v ORDER BY event_ts, dim)
       FROM incident_logs, LATERAL (VALUES
           ((state_hash = 12345)::int::float8, 1),
           ((state_hash = 67890)::int::float8, 2)
       ) AS onehot(v, dim)
      WHERE agent_id = 'bot-deploy-01'),
    2
) AS r);

-- 5. Task Routing (the route_task composition)
-- Real nearest-capability search over agent_capabilities.embedding via
-- fractal_search_telemetry -- the raw primitive the agent composes;
-- doc_id is the row's rowid, stringified, resolved back to the named
-- capability by the direct rowid join; confidence is 1/(1+distance)
-- (real).
.print
.print === 5. Task routing over the capability map ===
SELECT m.capability_name    AS routed_to,
       1.0 / (1.0 + t.distance) AS confidence,
       1000                     AS remaining_budget
FROM fractal_search_telemetry('agent_capabilities', 'embedding',
                              ARRAY[0.15, 0.25, 0.35]::float8[], 1) t
JOIN agent_capabilities m ON m.rowid::text = t.doc_id
ORDER BY t.distance
LIMIT 1;
.print --- rationale (fractal_reason) ---
SELECT fractal_reason('one-line rationale for this task routing decision');
.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_route_task(
    ARRAY[0.15, 0.25, 0.35]::float8[],
    'agent_capabilities', 'embedding', 'capability_name',
    1000
);

-- 6. Outlier Interception (the outlier_intercept composition)
-- Real cosine distance to the nearest known_bad_states row. This
-- state_vec matches state_id 1 exactly (distance 0), so intercepted =
-- true.
.print
.print === 6. Outlier interception (state matches a known-bad state) ===
SELECT (t.distance < 0.8)  AS intercepted,
       printf('nearest bad state distance %.4f vs threshold 0.8', t.distance) AS reason
FROM fractal_search_telemetry('known_bad_states', 'state_vec',
                              ARRAY[0.5, 0.5, 0.5]::float8[], 1) t
LIMIT 1;
.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_outlier_intercept(
    ARRAY[0.5, 0.5, 0.5]::float8[],
    'known_bad_states', 'state_vec',
    0.8
);

-- 7. Threat Triage on the drifting latency metric (the anomaly_triage
-- composition: the latency_ms series is a non-degenerate step-up signal
-- with a 32-point recent window, so fractal_dimension_drift succeeds --
-- window=16 would be too small for DFA on the recent window and return
-- rc=-1).
.print
.print === 7. Threat triage on the drifting latency metric ===
SELECT abs(dj.drift)     AS threat_score,
       'vector_drift'    AS anomaly_type,
       dj.recent_alpha   AS recent_alpha,
       dj.baseline_alpha AS baseline_alpha
FROM (SELECT fractal_dimension_drift(
           (SELECT array_agg(latency_ms ORDER BY event_ts)
              FROM incident_logs WHERE agent_id = 'bot-deploy-01'),
           32) AS dj);
.print --- triage_summary (fractal_reason over the drift result) ---
SELECT fractal_reason(
    'one-line triage for this anomaly-detection drift report',
    (SELECT CAST(fractal_dimension_drift(
         (SELECT array_agg(latency_ms ORDER BY event_ts)
            FROM incident_logs WHERE agent_id = 'bot-deploy-01'),
         32) AS VARCHAR))
);
.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_anomaly_triage('incident_logs', 'latency_ms', 'event_ts', 'agent_id', 'bot-deploy-01', 32);

-- 8. Localized Root-Cause Synthesis via Search Agent
-- Embeds the query (->768 for nomic-embed-text) and runs a diverse Scout
-- search over the incident_logs.embedding column, then reasons over the
-- retrieved context. (A wrong column type is a clean ERROR, not a
-- backend crash.) Positional only: (query, table_name, vector_col,
-- pop_size, iterations).
.print
.print === 8. fractal_search_agent (root-cause synthesis; reasoning plugin) ===
SELECT * FROM fractal_search_agent(
    'Why is bot-deploy-01 looping on auth?',
    'incident_logs', 'embedding',
    10, 5
);

-- 9. RAG Agent: retrieve-then-reason over the incident corpus.
-- Registered as a 4-arg table function (query, table, vector_col, and
-- a 4th VARCHAR the current implementation declares but doesn't read
-- yet -- pass '' until that's wired up; flagged for the src/ owner).
.print
.print === 9. fractal_rag_agent (retrieve-then-reason; reasoning plugin) ===
SELECT * FROM fractal_rag_agent(
    'What events led to the auth retry loop on bot-deploy-01?',
    'incident_logs', 'embedding', ''
);

-- -----------------------------------------------------------------------------
-- 10. Headline check: the demo's own claims, recomputed from the demo's own
-- tables and calls -- the period-2 retry loop is flagged (is_loop_detected =
-- true) even though its DFA exponent is 0, the incident routes to the
-- root-cause analyzer with high confidence, the proposed state matches
-- known-bad state 1 (intercepted), and the drifting latency metric really
-- does drift.
--
-- The routing and interception searches are re-run over the whole capability
-- map / known-bad library (k = 2, so both rows come back) and ordered by
-- distance here, so the pick is a property of the vectors rather than of the
-- search's own top-k tie-break.
-- -----------------------------------------------------------------------------
.print
.print === 10. Headline check ===
.mode list
.headers off
WITH loop AS (
    SELECT r.is_loop_detected, r.dfa_exponent
    FROM (SELECT fractal_agent_detect_loop(
        'bot-deploy-01',
        (SELECT array_agg(v ORDER BY event_ts, dim)
           FROM incident_logs, LATERAL (VALUES
               ((state_hash = 12345)::int::float8, 1),
               ((state_hash = 67890)::int::float8, 2)
           ) AS onehot(v, dim)
          WHERE agent_id = 'bot-deploy-01'),
        2
    ) AS r)
),
route AS (
    SELECT m.capability_name    AS routed_to,
           1.0 / (1.0 + t.distance) AS confidence
    FROM fractal_search_telemetry('agent_capabilities', 'embedding',
                                  ARRAY[0.15, 0.25, 0.35]::float8[], 2) t
    JOIN agent_capabilities m ON m.rowid::text = t.doc_id
),
bad AS (
    SELECT b.state_id, b.description, t.distance
    FROM fractal_search_telemetry('known_bad_states', 'state_vec',
                                  ARRAY[0.5, 0.5, 0.5]::float8[], 2) t
    JOIN known_bad_states b ON b.rowid::text = t.doc_id
),
drift AS (
    SELECT dj.drift, dj.recent_alpha, dj.baseline_alpha
    FROM (SELECT fractal_dimension_drift(
               (SELECT array_agg(latency_ms ORDER BY event_ts)
                  FROM incident_logs WHERE agent_id = 'bot-deploy-01'),
               32) AS dj)
)
SELECT 'HEADLINE kit=agentic-ops-devops ' || CASE WHEN
         (SELECT count(*) FROM incident_logs) = 99
     AND (SELECT count(*) FROM incident_logs WHERE agent_id = 'bot-deploy-01') = 96
     AND (SELECT count(*) FROM incident_logs WHERE embedding IS NOT NULL) = 99
     AND (SELECT is_loop_detected FROM loop) = true
     AND (SELECT abs(dfa_exponent) FROM loop) < 1e-9
     AND (SELECT count(*) FROM route) = 2
     AND (SELECT routed_to FROM route ORDER BY confidence DESC LIMIT 1) = 'root-cause-analyzer'
     AND (SELECT confidence FROM route ORDER BY confidence DESC LIMIT 1) > 0.9
     AND (SELECT count(*) FROM bad) = 2
     AND (SELECT state_id FROM bad ORDER BY distance LIMIT 1) = 1
     AND (SELECT description FROM bad ORDER BY distance LIMIT 1) = 'auth-service unreachable, retry storm'
     AND (SELECT distance FROM bad ORDER BY distance LIMIT 1) < 0.8
     AND (SELECT abs(distance) FROM bad ORDER BY distance LIMIT 1) < 0.01
     AND (SELECT drift FROM drift) < 0
     AND (SELECT abs(drift) FROM drift) > 0.1
     AND (SELECT recent_alpha FROM drift) < (SELECT baseline_alpha FROM drift)
THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print ================================================================
.print Demo complete. Tables left in place for inspection -- drop them
.print to re-run (one DROP per statement -- DuckDB's DROP TABLE takes
.print exactly one table):
.print   DROP TABLE incident_logs;
.print   DROP TABLE agent_capabilities;
.print   DROP TABLE known_bad_states;
.print (the vectorizer rows are cleared by the teardown DELETEs at the
.print top of the script on each re-run.)
.print ================================================================