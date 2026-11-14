-- demo/demo-agents.sql
--
-- =============================================================================
-- FractalSQL Agents validation demo
-- =============================================================================
-- End-to-end validation of the sixteen domain agents registered by the
-- fractalsql extension itself (docs/api-agency.md):
--   * fractal_agent_anomaly_triage            -- drift + reason
--   * fractal_agent_allocate                  -- optimize_portfolio + reason
--   * fractal_agent_route_task                -- telemetry search + reason
--   * fractal_agent_outlier_intercept         -- telemetry/l2 search + reason
--   * fractal_agent_recall_hybrid             -- cohort hybrid search (no LLM)
--   * fractal_agent_recommend_diverse         -- diversify + telemetry (no LLM)
--   * fractal_agent_data_analyst              -- fractal_sql_agent + reason
--   * fractal_agent_patient_deterioration_triage -- hybrid + trajectory + reason
--   * fractal_agent_feedback_audit            -- diversify + feedback + D_q (no LLM)
--   * fractal_agent_schedule_workload         -- fractal_search + telemetry + reason
--   * fractal_agent_rebalance_sibling         -- optimize_portfolio + trajectory + reason
--   * fractal_agent_detour_classify           -- trajectory + boxcount + reason
--   * fractal_agent_track_anomaly             -- trajectory + dfa + reason
--   * fractal_agent_network_coverage_alert    -- morphology + drift + reason
--   * fractal_agent_regime_triage             -- dfa + drift + reason
--   * fractal_agent_diverse_portfolios        -- optimize_portfolio_multimodal + reason
--
-- Return shape (this build): every agent is a SCALAR function returning
-- one VARCHAR holding a JSON document -- one object per call for most
-- agents, a JSON array of objects for the three multi-row engines
-- (recall_hybrid, recommend_diverse, diverse_portfolios). Every value
-- inside is a REAL primitive result, not a literal: threat_score is the
-- computed drift; sharpe and weights are the optimizer's own output;
-- routed_to/assigned_node are real nearest names and confidence is
-- 1/(1+distance); mem_id/item_id/content are real recalled rows;
-- feedback_audit's diversity_quotient is the real D_q; detour/track/
-- coverage/regime carry the real box-counting, DFA, morphology, and drift
-- numbers. Parse fields downstream if needed (json_extract -- DuckDB's
-- core JSON functions are bundled) or read the whole document.
--
-- Below, each agent appears first as its REFERENCE COMPOSITION over the
-- primitives it wraps -- inline blueprint sections, same as the
-- demo-vertical-agentic-*.sql demos -- then "the shipped agent: same
-- composition, one call" over the same fixture. Values will not match
-- the blueprint's own output exactly where an engine draws its own
-- randomness (the optimizer's default seed, the fixtures' random rows)
-- -- the point is that the shipped function performs the same
-- composition as the blueprint above it, not that it reproduces the
-- identical numbers.
--
-- Locator conventions in the blueprints (this build's table-function
-- search primitives return one row per hit, not one JSON string):
--   * fractal_search_telemetry / fractal_hybrid_clinical_search return
--     doc_id = the row's REAL rowid (stringified; it degrades to the
--     0-indexed scan position only when the relation has no rowid),
--     plus scan_pos. The blueprints resolve doc_id with a plain rowid
--     join.
--   * fractal_search_trajectory's doc_id is the 0-INDEXED scan
--     position -- not the rowid -- so its blueprint maps back to the
--     named row key with row_number() OVER (ORDER BY rowid) - 1.
--
-- Two session-state notes:
--   * The shipped agents run their searches on ONE shared process-wide
--     engine context (DuckDB scalar functions have no per-session core
--     ctx). The REGISTERED diversify/isolate/collapse/explain functions
--     act on the ledger's own context instead -- a different session
--     (see demo/enterprise-qtl-audit.sql). Sections 7a and 11a execute
--     their blueprints' session-state legs with those registered
--     ledger-context calls: real enable/params/warmup/isolate/D_q
--     toggles on the ledger context, the closest runnable equivalent of
--     the shipped agent's engine-context cycle. Section order still
--     matters on the shared engine ctx:
--     recommend_diverse (7) enables diversify there and leaves it on
--     (the caller owns disabling; feedback_audit disables it at its own
--     end), which is why 7 runs before 11.
--   * fractal_agent_diverse_portfolios is enterprise tier: it composes
--     the registered fractal_optimize_portfolio_multimodal[_pareto]
--     table functions and surfaces their enterprise-gate error. Plain
--     DuckDB SQL has no exception-catching expression (see
--     demo/enterprise-qtl-audit.sql's header note), so a community run
--     prints the clean activation error at section 13c and the shell
--     carries on to the next section.
--
-- Prerequisites:
--   1. LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';
--   2. Reasoning configured -- the 13 cognition agents dispatch to the
--      chat tier; the 3 retrieval/analytics agents need no endpoint. See
--      docs/reasoning-setup.md. Confirm before running:
--        SELECT fractal_reason('reply with a short confirmation');
--
-- Run WITHOUT -bail (the enterprise-tier call at section 13c errors and
-- the shell continues on a community build; the reasoning-gated shipped
-- calls print their clean hint the same way):
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; \
--     cat demo/demo-agents.sql; } | duckdb -unsigned
--
-- Re-runnable: the fixture tables are dropped and recreated at the top
-- of their sections (the blueprint layer's agents_demo_* TEMP tables
-- evaporate with the connection).
-- =============================================================================

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- 1. Setup: a drifting metric time series for one host.
-- A baseline ~50 for the first 48 rows then a +30 step-up, 96 points, so
-- fractal_dimension_drift's 32-point recent window has a real regime change
-- to detect (DFA needs the recent window large enough; a window of 16 is
-- too small and returns rc=-1). A second host makes the host filter
-- meaningful.
DROP TABLE IF EXISTS agents_demo_logs;
CREATE TABLE agents_demo_logs (metric float8, ts timestamptz, host text);
INSERT INTO agents_demo_logs (metric, ts, host)
SELECT 50.0 + (gs % 8)::float8 * 1.3 + CASE WHEN gs > 48 THEN 30.0 ELSE 0.0 END,
       now() - (96 - gs) * interval '1 second', 'host-1'
FROM generate_series(1, 96) AS gs(gs);
INSERT INTO agents_demo_logs VALUES
    (10, now(), 'host-2'),
    (11, now() + interval '1 min', 'host-2');

-- 2. fractal_agent_anomaly_triage (happy path).
-- threat_score is the REAL drift exponent (fractal_dimension_drift ran over
-- host-1's 96-point series); anomaly_type is the literal 'vector_drift'
-- label; triage_summary is the REAL reasoning output over the drift result.
.print
.print === 2a. anomaly_triage blueprint (host-1, 32-pt recent window) ===
WITH d AS (SELECT fractal_dimension_drift(
               (SELECT list(metric ORDER BY ts)
                  FROM agents_demo_logs WHERE host = 'host-1'), 32) AS j)
SELECT abs(j.drift)          AS threat_score,
       'vector_drift'        AS anomaly_type,
       j.recent_alpha        AS recent_alpha,
       j.baseline_alpha      AS baseline_alpha
FROM d;

.print --- triage_summary (fractal_reason over the drift result) ---
SELECT fractal_reason(
    'one-line triage for this anomaly-detection drift report',
    (SELECT j::text FROM (SELECT fractal_dimension_drift(
         (SELECT list(metric ORDER BY ts)
            FROM agents_demo_logs WHERE host = 'host-1'), 32) AS j)));

.print
.print --- 2b. the shipped agent: same composition, one call ---
SELECT fractal_agent_anomaly_triage(
    'agents_demo_logs', 'metric', 'ts', 'host', 'host-1', 32);

-- 2c. anomaly_triage empty-series guard (interactive only -- not in the
-- re-runnable path because it raises an ERROR). Uncomment to confirm it
-- rejects cleanly:
-- SELECT fractal_agent_anomaly_triage(
--     'agents_demo_logs', 'metric', 'ts', 'host', 'no-such-host', 32);
-- Expect: fractal_agent_anomaly_triage: no rows in agents_demo_logs.metric ...

-- 3. fractal_agent_allocate (happy path).
-- allocation is the REAL optimizer document {sharpe, weights}; sharpe (a
-- top-level key) is the REAL risk-adjusted return. cov is the 2x2 identity
-- flattened to a row-major 4-element list, the shape
-- fractal_optimize_portfolio reads.
.print
.print === 3a. allocate blueprint (2 assets, cardinality=1) ===
-- allocation is the REAL optimizer document {sharpe, weights}; sharpe is
-- the REAL risk-adjusted return. cov is the 2x2 identity flattened to a
-- row-major 4-element list, the shape fractal_optimize_portfolio reads.
WITH opt AS (SELECT fractal_optimize_portfolio(
    [0.05, 0.1]::float8[], [1.0, 0.0, 0.0, 1.0]::float8[], 1, 42) AS o)
SELECT o.sharpe  AS sharpe,
       o.weights AS weights
FROM opt;

.print --- rationale (fractal_reason over the optimizer's output) ---
SELECT fractal_reason(
    'justify this 2-asset portfolio allocation in one line',
    (SELECT o::text FROM (SELECT fractal_optimize_portfolio(
        [0.05, 0.1]::float8[], [1.0, 0.0, 0.0, 1.0]::float8[], 1, 42) AS o)));

.print
.print === 3b. the shipped agent: same composition, one call ===
SELECT fractal_agent_allocate(
    [0.05, 0.1]::float8[],
    [1.0, 0.0, 0.0, 1.0]::float8[],
    1,
    '{"portfolio": "agents-demo"}');

-- 4. fractal_agent_route_task (happy path).
-- The agent finds the nearest capability row in agents_demo_caps via the
-- telemetry search and routes: routed_to is the REAL capability name,
-- confidence is 1/(1+distance), remaining_budget is budget - cost_per_route.
DROP TABLE IF EXISTS agents_demo_caps;
CREATE TABLE agents_demo_caps (capability_name text, emb float8[]);
INSERT INTO agents_demo_caps VALUES
    ('root-cause-analyzer', [0.1, 0.2, 0.3]),
    ('capacity-autoscaler', [0.9, 0.8, 0.7]),
    ('incident-pager',      [0.3, 0.3, 0.9]);

.print
.print === 4a. route_task blueprint (task near root-cause-analyzer) ===
WITH t AS (SELECT doc_id, distance
             FROM fractal_search_telemetry('agents_demo_caps', 'emb',
                  [0.11, 0.21, 0.31]::float8[], 1))
SELECT m.capability_name   AS routed_to,
       1.0 / (1.0 + t.distance) AS confidence,
       1000                AS remaining_budget
FROM t
JOIN agents_demo_caps m ON m.rowid::VARCHAR = t.doc_id;

.print --- rationale (fractal_reason over the routing result) ---
SELECT fractal_reason('one-line rationale for this task routing decision');

.print
.print === 4b. the shipped agent: same composition, one call ===
SELECT fractal_agent_route_task(
    [0.11, 0.21, 0.31]::float8[],
    'agents_demo_caps', 'emb', 'capability_name', 1000);

-- 4c. route_task empty-table guard (interactive only -- raises an ERROR).
-- Uncomment to confirm it rejects cleanly: delete the table's rows first
-- (DELETE FROM agents_demo_caps;), then:
-- SELECT fractal_agent_route_task(
--     [0.1,0.2,0.3], 'agents_demo_caps', 'emb', 'capability_name', 1000);
-- Expect: fractal_agent_route_task: no capability rows in agents_demo_caps

-- 5. fractal_agent_outlier_intercept.
-- Screens a proposed action's state vector against known-bad states. Uses
-- ORTHOGONAL vectors for the "far" case, because cosine distance ignores
-- magnitude: [0.1,0.1,0.1] vs [0.9,0.9,0.9] are parallel (distance 0), not
-- far. A far probe must point a different direction -- here [0,1,0] vs bad
-- [1,0,0] has distance 1 > 0.5, so intercepted=false.
DROP TABLE IF EXISTS agents_demo_badstates;
CREATE TABLE agents_demo_badstates (emb float8[]);
INSERT INTO agents_demo_badstates VALUES
    ([1.0, 0.0, 0.0]),
    ([0.9, 0.1, 0.0]);

.print
.print === 5a. outlier_intercept blueprint (near a bad state) ===
-- distance-vs-threshold over the REAL nearest-distance the telemetry
-- search returns (doc_id here is the row's rowid, stringified).
WITH d AS (SELECT distance FROM
             fractal_search_telemetry('agents_demo_badstates', 'emb',
                 [0.95, 0.05, 0.0]::float8[], 1) LIMIT 1)
SELECT (distance < 0.5) AS intercepted
FROM d;

.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_outlier_intercept(
    [0.95, 0.05, 0.0]::float8[], 'agents_demo_badstates', 'emb', 0.5);

.print
.print === 5b. outlier_intercept blueprint (orthogonal/far) ===
WITH d AS (SELECT distance FROM
             fractal_search_telemetry('agents_demo_badstates', 'emb',
                 [0.0, 1.0, 0.0]::float8[], 1) LIMIT 1)
SELECT (distance < 0.5) AS intercepted
FROM d;

.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_outlier_intercept(
    [0.0, 1.0, 0.0]::float8[], 'agents_demo_badstates', 'emb', 0.5);

.print
.print === 5c. outlier_intercept blueprint (l2: magnitude counts) ===
-- Same check under the agent's 'l2' metric, where magnitude matters:
-- [0.05,0,0] sits ~0.85 (real L2, fractal_vector_l2_distance) away from bad
-- [1,0,0] and is allowed under the same threshold, even though cosine
-- would call it parallel.
SELECT (fractal_vector_l2_distance([0.05, 0.0, 0.0]::float4[], emb::float4[]) < 0.5) AS intercepted
FROM (SELECT emb FROM agents_demo_badstates
       ORDER BY fractal_vector_l2_distance(emb::float4[], [0.05, 0.0, 0.0]::float4[]) LIMIT 1);

.print --- the shipped agent: same composition, one call (metric arg 5) ---
SELECT fractal_agent_outlier_intercept(
    [0.05, 0.0, 0.0]::float8[], 'agents_demo_badstates', 'emb', 0.5, 'l2');

-- 6. fractal_agent_recall_hybrid (happy path).
-- Pure retrieval: no LLM step. The "hybrid" is the cohort -- a strict SQL
-- filter (customer_id) mapped to the rows' locators, then the search
-- restricts the vector recall to that cohort. The document is a JSON array
-- of {mem_id, content} rows: mem_id is the REAL session_id from each
-- matching row, content is the REAL row text.
DROP TABLE IF EXISTS agents_demo_mem;
CREATE TABLE agents_demo_mem (
    session_id    bigint,
    customer_id   text,
    state_vector  float8[],
    content       text
);
INSERT INTO agents_demo_mem VALUES
    (1001, 'cust-a', [0.2, 0.2, 0.2], 'resolved churn via loyalty upgrade'),
    (1002, 'cust-a', [0.8, 0.8, 0.8], 'escalated billing dispute to agent'),
    (1003, 'cust-b', [0.5, 0.5, 0.5], 'refunded a duplicate charge');

.print
.print === 6a. recall_hybrid blueprint (cust-a cohort, k=2) ===
-- Table-function args are constant-only in DuckDB, so the cust-a cohort
-- id list spools through the .once/.read idiom (same contract as the
-- later 13a sections in this file):
.mode list
.headers off
.output agents_hs.sql
SELECT 'WITH hs AS (SELECT doc_id, distance FROM fractal_hybrid_clinical_search(''agents_demo_mem'', ''state_vector'', [0.18, 0.22, 0.2]::DOUBLE[], ' ||
       (SELECT '[' || string_agg('''' || rowid::VARCHAR || '''', ', ') || ']'
          FROM agents_demo_mem WHERE customer_id = 'cust-a') ||
       ', 2)) SELECT m.session_id AS mem_id, m.content AS content FROM hs JOIN agents_demo_mem m ON m.rowid::VARCHAR = hs.doc_id ORDER BY hs.distance;'
;
.output stdout
.mode box
.headers on
.read agents_hs.sql

.print
.print --- 6b. the shipped agent: same composition, one call ---
SELECT fractal_agent_recall_hybrid(
    'agents_demo_mem', 'state_vector', [0.18, 0.22, 0.2]::float8[],
    'customer_id', 'cust-a', 2, 'session_id', 'content');

-- 6c. recall_hybrid no-rows guard (interactive only -- raises an ERROR).
-- Uncomment to confirm it rejects cleanly:
-- SELECT fractal_agent_recall_hybrid(
--     'agents_demo_mem', 'state_vector', [0.1,0.1,0.1],
--     'customer_id', 'no-such-customer', 5, 'session_id', 'content');
-- Expect: fractal_agent_recall_hybrid: filter matched no rows in agents_demo_mem

-- 7. fractal_agent_recommend_diverse (happy path).
-- Pure retrieval: no LLM step. Enables session-global repulsion on the
-- shared engine context so the search avoids recently-rejected items, then
-- returns a repulsion-diverse top-k as a JSON array of {item_id, score}
-- rows: item_id is the REAL catalog id, score is 1-cosine_distance. The
-- diversify-enable is a shared side effect; feedback_audit (section 11)
-- disables it at its own end, and there is no SQL toggle for the engine
-- context (the registered fractal_diversify_disable() acts on the ledger's
-- own context, a different session).
DROP TABLE IF EXISTS agents_demo_catalog;
CREATE TABLE agents_demo_catalog (id bigint, emb float8[]);
INSERT INTO agents_demo_catalog VALUES
    (10, [0.1, 0.0, 0.0]),
    (20, [0.0, 1.0, 0.0]),
    (30, [0.0, 0.0, 1.0]);

.print
.print === 7a. recommend_diverse blueprint (query near item 10, k=3) ===
-- The retrieval half is the telemetry top-k below. The repulsion half
-- (the shipped agent's fsql_diversify_enable + params on the SHARED
-- ENGINE context before its search -- avoiding recently-rejected items)
-- has a registered ledger-context equivalent, executed here: a real
-- enable on the ledger context (a different session from the engine
-- ctx -- see the header's session-state note; section 11a runs the full
-- audit cycle and disables it again).
SELECT fractal_diversify_enable();
WITH t AS (SELECT doc_id, distance
             FROM fractal_search_telemetry('agents_demo_catalog', 'emb',
                  [0.12, 0.01, 0.0]::float8[], 3))
SELECT m.id               AS item_id,
       1.0 - t.distance   AS score
FROM t
JOIN agents_demo_catalog m ON m.rowid::VARCHAR = t.doc_id;

.print
.print === 7b. the shipped agent: same composition, one call
.print     (diversify enabled on the shared engine ctx, left on;
.print     feedback_audit in section 11 restores the off state) ===
SELECT fractal_agent_recommend_diverse(
    'agents_demo_catalog', 'emb', [0.12, 0.01, 0.0]::float8[], 3, 'id');

-- =============================================================================
-- Sections 9-17. Same real-output contract as the first seven.
-- =============================================================================

-- 9. fractal_agent_data_analyst (horizontal NL->SQL->reason).
-- Composes the registered fractal_sql_agent table function (auto_execute on:
-- NL->SQL->run, with execution failures captured into result_json), then
-- reasons over the result. generated_sql is the agent's real generated
-- statement; result_json is the real executed row count (or a captured
-- execution-failure reason); analysis is the real reasoning read.
-- The horizontal catch-all -- no vertical demo is wired to it.
-- The shipped agent only runs the statement it generated when the caller
-- asks it to (the last argument); it generates and validates it either way.
DROP TABLE IF EXISTS agents_demo_data;
CREATE TABLE agents_demo_data (id int PRIMARY KEY, category text, amount float8);
INSERT INTO agents_demo_data VALUES
    (1, 'hardware', 1200.00),
    (2, 'software',  800.50),
    (3, 'hardware',  450.25);

.print
.print === 9a. data_analyst blueprint (NL: total spend per category) ===
-- The composition's engine leg is the registered fractal_sql_agent table
-- function directly (auto_execute positional true: NL -> SQL -> run, with
-- execution failures captured into execution_status rather than raised).
SELECT *
FROM fractal_sql_agent('total amount spent per category in agents_demo_data',
                       ['agents_demo_data'], 2, true);

.print --- analysis (fractal_reason over the result) ---
SELECT fractal_reason('one-line read of this SQL analysis result');

.print
.print === 9b. the shipped agent: same composition, one call ===
.print     (the last argument opts in to running the generated statement:
.print      1 = run it, 0 = only generate and validate it) ===
SELECT fractal_agent_data_analyst(
    'total amount spent per category in agents_demo_data',
    ['agents_demo_data'], 2, '{}', true);

-- 10. fractal_agent_patient_deterioration_triage (medtech).
-- Composes a cohort-restricted hybrid search with a baseline->current drift
-- search, then reasons. The cohort is the caller's list of row locators --
-- the two-predicate cohort (age>65 AND condition='sepsis') that
-- recall_hybrid's single (filter_col, filter_val) cannot express. The list
-- is the cohort's rowid values (this build's locator for the doc_id the
-- search uses). nearest_cohort_id is the real nearest patient (resolved
-- via that id column); cohort_distance/drift_distance are real; rationale
-- is the real reasoning output; cohort_matches is the full ordered
-- hit-distance array.
DROP TABLE IF EXISTS agents_demo_patients;
CREATE TABLE agents_demo_patients (
    id int PRIMARY KEY, age int, condition text, vitals float8[]);
INSERT INTO agents_demo_patients VALUES
    (1, 72, 'sepsis',    [0.90, -0.80, 0.70, 0.60]),
    (2, 64, 'sepsis',    [0.10,  0.10, 0.10, 0.10]),
    (3, 78, 'pneumonia', [0.20,  0.20, 0.20, 0.20]),
    (4, 81, 'sepsis',    [0.85, -0.75, 0.65, 0.55]);

.print
.print === 10a. patient_deterioration_triage blueprint (age>65 sepsis cohort) ===
-- The cohort is the caller-built two-predicate filter (age>65 AND
-- condition='sepsis') that a single (filter_col, filter_val) cannot
-- express, handed to the hybrid search as the cohort's rowid list.
-- DuckDB binds table-function arguments with the constant binder, which
-- rejects subqueries outright, so the cohort list spools through the
-- .output/.read idiom (the same contract as sections 6a and 13a).
.mode list
.headers off
.output agents_pt.sql
SELECT 'WITH hs AS (SELECT doc_id, distance FROM fractal_hybrid_clinical_search(''agents_demo_patients'', ''vitals'', [0.9, -0.8, 0.7, 0.6]::float8[], ' ||
       (SELECT '[' || string_agg('''' || rowid::VARCHAR || '''', ', ') || ']'
          FROM agents_demo_patients WHERE age > 65 AND condition = 'sepsis') ||
       ', 5)), tr AS (SELECT doc_id, distance FROM fractal_search_trajectory(''agents_demo_patients'', ''vitals'', [0.1, 0.1, 0.1, 0.1]::float8[], [0.95, -0.85, 0.75, 0.65]::float8[], 5)) SELECT (SELECT m.id FROM hs JOIN agents_demo_patients m ON m.rowid::VARCHAR = hs.doc_id ORDER BY hs.distance LIMIT 1) AS nearest_cohort_id, (SELECT min(distance) FROM hs) AS cohort_distance, (SELECT min(distance) FROM tr) AS drift_distance, (SELECT count(*) FROM agents_demo_patients WHERE age > 65 AND condition = ''sepsis'') AS cohort_matches;'
;
.output stdout
.mode box
.headers on
.read agents_pt.sql

.print --- rationale (fractal_reason over the cohort scan) ---
SELECT fractal_reason('one-line triage rationale for this patient cohort scan');

.print
.print === 10b. the shipped agent: same composition, one call (explicit two-predicate cohort) ===
SELECT fractal_agent_patient_deterioration_triage(
    'agents_demo_patients', 'vitals',
    [0.9, -0.8, 0.7, 0.6]::float8[],
    [0.1, 0.1, 0.1, 0.1]::float8[],
    [0.95, -0.85, 0.75, 0.65]::float8[],
    (SELECT list(rowid ORDER BY rowid) FROM agents_demo_patients
      WHERE age > 65 AND condition = 'sepsis'),
    5, 'id');

-- 11. fractal_agent_feedback_audit (pure analytics, NO LLM).
-- A self-contained audit cycle: enables session-global repulsion, warms the
-- D_q rolling window with varied queries from a warmup table, reports
-- negative feedback on the audit target (the k=1 scan position -- the
-- scan position IS the feedback handle), then reads back the real
-- diversity_quotient (NOT NaN once the window is warm) and the diagnostic
-- document. Self-disables diversify (unlike recommend_diverse, which
-- leaves it on), so the section order above is safe to re-run.
-- The fixture generator for every section below: a two-round LCG over
-- pure integer arithmetic, so every draw is exactly the same everywhere.
--
-- random() would not do: setseed() seeds only the engine of the thread
-- that called it, and every other DuckDB worker thread runs its own
-- random() stream, so a fixture query DuckDB spreads over several
-- threads hands each row a value from a different stream -- and these
-- fixtures came out different on a different machine. The LCG is a PURE
-- FUNCTION of its argument, so unlike a stream it does not care how many
-- times it is called, in what order, or on which thread: a row's value
-- is the same however the query is scheduled. (That also means a CASE
-- with two arms cannot share a seed -- the two arms below use different
-- seed bases so they stay two different draws.)
--
-- The xor-shift rounds are not decoration. A plain LCG is AFFINE in its
-- seed: two seeds one apart differ by a CONSTANT amount, so a pair of
-- "independent" dimensions drawn from adjacent seeds came out as mirror
-- images of each other. Section 14's GPS trace is a 2-D random walk, and
-- with mirrored dimensions its point cloud was a straight line, which
-- fractal_dimension_boxcount() rejects as a degenerate bounding box.
-- The xor-shift breaks that affinity, so neighbouring seeds now give
-- genuinely unrelated draws and the walk is a real walk.
CREATE OR REPLACE MACRO ag_lcg(s) AS ((((s::BIGINT * 1103515245::BIGINT) + 12345) % 2147483648));
CREATE OR REPLACE MACRO ag_xs(a, sh) AS (xor(a, a >> sh));
CREATE OR REPLACE MACRO ag_mix(s) AS (ag_xs(ag_lcg(ag_xs(ag_lcg(s), 13)), 17));
CREATE OR REPLACE MACRO ag_rand(s) AS (ag_mix(s)::DOUBLE / 2147483648.0);

DROP TABLE IF EXISTS agents_demo_fcatalog;
DROP TABLE IF EXISTS agents_demo_fwarmup;
CREATE TABLE agents_demo_fcatalog (id bigint PRIMARY KEY, emb float8[]);
INSERT INTO agents_demo_fcatalog
SELECT gs, [ag_rand(gs*10+1)*2-1, ag_rand(gs*10+2)*2-1, ag_rand(gs*10+3)*2-1]
FROM generate_series(1, 20) AS gs(gs)
ORDER BY gs;
CREATE TABLE agents_demo_fwarmup (center float8[]);
INSERT INTO agents_demo_fwarmup
SELECT [ag_rand(1000+g*10+1)*2-1, ag_rand(1000+g*10+2)*2-1, ag_rand(1000+g*10+3)*2-1]
FROM generate_series(1, 8) AS g(g)
ORDER BY g;

.print
.print === 11a. feedback_audit composition (warmup -> isolate -> D_q) ===
-- The cycle, as the shipped agent performs it on the shared engine
-- context, executed here with the registered ledger-context
-- equivalents (see the header's session-state note): (1) enable
-- repulsion + the audit defaults; (2) warm the D_q rolling window with
-- 8 varied queries (the same count the shipped agent draws from the
-- warmup table, every error swallowed); (3) report negative feedback on
-- the audit target -- the k=1 telemetry search's scan_pos IS the
-- feedback handle; (4) read back the real diversity_quotient
-- (fractal_detect_collapse -- NOT NaN once the window is warm) and the
-- diagnostic document (fractal_explain_result); (5) disable diversify
-- (the shipped agent self-disables at its own end).
SELECT fractal_diversify_enable();
SELECT fractal_diversify_set_params(8, NULL, 0.3, 0.5);  -- positional: window_n=8, repulsion_sigma=0.3, repulsion_weight=0.5

-- (2) Warm the D_q rolling window with 8 varied queries. The warmup
-- rows are drawn from the LCG above and table-function args are constant-only in
-- DuckDB, so the executed window-warming telemetry queries are spooled
-- as 8 varied literal vectors (.once/.read -- the 12a/13a idiom):
.mode list
.headers off
.output agents_demo_warm.sql
SELECT 'SELECT count(*) AS window_warmed FROM fractal_search_telemetry(''agents_demo_fcatalog'', ''emb'', [' ||
       printf('%.2f,%.2f,%.2f]::float8[], 3);', 0.9 - g * 0.1,
              0.5 + g * 0.05, (g - 3) * 0.1)
FROM generate_series(0, 7) AS g(g);
.output stdout
.headers on
.mode box
.read agents_demo_warm.sql

-- (3) Negative feedback on the audit target: the k=1 telemetry scan's
-- scan_pos IS the feedback handle; the CLI has no variable capture, so
-- the .once/.read spool trick materializes it (same idiom as 12a/13a):
.mode list
.headers off
.output agents_demo_iso.sql
SELECT 'SELECT fractal_isolate_background(' || CAST(scan_pos AS VARCHAR) || ');'
FROM fractal_search_telemetry('agents_demo_fcatalog', 'emb',
                              [0.5, 0.5, 0.5]::float8[], 1);
.output stdout
.headers on
.mode box
.read agents_demo_iso.sql

-- (4) Read back the real D_q + session diagnostics:
SELECT fractal_detect_collapse() AS diversity_quotient;
SELECT fractal_explain_result()  AS diagnostics;
-- (5) Disable diversify again:
SELECT fractal_diversify_disable();

.print
.print === 11b. the shipped agent: same composition, one call
.print     (self-contained: enables + disables diversify) ===
SELECT fractal_agent_feedback_audit(
    'agents_demo_fcatalog', 'emb', [0.5, 0.5, 0.5]::float8[],
    'agents_demo_fwarmup', 'center', 8, 3);

-- 12. fractal_agent_schedule_workload (sovereign-edge).
-- Refines the task vector with fractal_search (the "sniper search" in the
-- [-1,1]^dim space), finds the nearest node via the telemetry search, and
-- reasons. assigned_node is the real node id; confidence is
-- 1/(1+distance); rationale is the real reasoning output. Like route_task
-- but with the fractal_search refinement step route_task lacks.
DROP TABLE IF EXISTS agents_demo_nodes;
CREATE TABLE agents_demo_nodes (id int PRIMARY KEY, capability float8[]);
INSERT INTO agents_demo_nodes VALUES
    (1, [0.9, 0.1, 0.0, 0.0, 0.0]),
    (2, [0.0, 0.0, 0.9, 0.1, 0.0]),
    (3, [0.1, 0.0, 0.0, 0.0, 0.9]);

.print
.print === 12a. schedule_workload blueprint (inference task -> nearest node) ===
-- Step 1 refines the task vector with the Sniper-search refinement
-- (fractal_search_debug's $.best_point IS the refined vector -- the same
-- key the shipped agent composes on); step 2 finds the nearest node via
-- the telemetry search. Table-function args are constant-only in DuckDB,
-- so the refined point is spooled through the .once/.read trick (same
-- idiom demo-business-intelligence.sql uses; the mode/headers toggles
-- put a bare SQL line in the spool file) rather than a subquery.
.mode list
.headers off
.output agents_demo_sched.sql
SELECT 'SELECT m.id AS assigned_node, 1.0 / (1.0 + t.distance) AS confidence '
       'FROM fractal_search_telemetry(''agents_demo_nodes'', ''capability'', '
       || CAST(json_extract(fractal_search_debug([0.8, 0.1, 0.0, 0.0, 0.1]::float8[],
       30, 50, 2), '$.best_point') AS VARCHAR) ||
       '::float8[], 5) t JOIN agents_demo_nodes m ON m.rowid::VARCHAR = t.doc_id;'
;
.output stdout
.headers on
.mode box
.read agents_demo_sched.sql

.print --- rationale (fractal_reason over the assignment) ---
SELECT fractal_reason('one-line rationale for this workload assignment');

.print
.print === 12b. the shipped agent: same composition, one call ===
SELECT fractal_agent_schedule_workload(
    [0.8, 0.1, 0.0, 0.0, 0.1]::float8[],
    'agents_demo_nodes', 'capability', 'id', 30, 50, 5);

-- 13. fractal_agent_rebalance_sibling (quant-finance).
-- Runs the cardinality-constrained Sharpe maximizer
-- (fractal_optimize_portfolio), uses the weights as the trajectory search's
-- "current" vector, finds the nearest historical allocation pattern, and
-- reasons. sharpe/weights are the real optimizer output; nearest_alloc_id
-- is the real trajectory nearest (resolved via the id column);
-- nearest_distance is real. cov is a flattened row-major 4x4. A NULL seed
-- keeps the optimizer's default (random) seed; a supplied bigint seed
-- pins it for reproducibility.
DROP TABLE IF EXISTS agents_demo_alloc;
CREATE TABLE agents_demo_alloc (id bigint PRIMARY KEY, alloc float8[]);
INSERT INTO agents_demo_alloc VALUES
    (1, [0.25, 0.25, 0.25, 0.25]),
    (2, [0.40, 0.30, 0.20, 0.10]),
    (3, [0.10, 0.20, 0.30, 0.40]);

.print
.print === 13a. rebalance_sibling blueprint (4 assets, cardinality=4) ===
-- Step 1 runs the cardinality-constrained Sharpe maximizer directly
-- (with a fixed seed for reproducibility); step 2 uses the optimizer's
-- weights as the trajectory search's "current" vector to find the
-- nearest historical allocation pattern (trajectory's doc_id is the
-- 0-indexed scan position, hence the row_number() mapping). Table
-- function args are constant-only, so the weights roundtrip through a
-- TEMP table plus the .once/.read spool.
CREATE OR REPLACE TEMP TABLE agents_demo_opt AS
SELECT fractal_optimize_portfolio([0.05, 0.10, 0.15, 0.20]::float8[],
       [0.04, 0.0, 0.0, 0.0,
        0.0, 0.09, 0.0, 0.0,
        0.0, 0.0, 0.16, 0.0,
        0.0, 0.0, 0.0, 0.25]::float8[], 4, 42) AS opt;

.print --- optimizer document (REAL sharpe / weights) ---
SELECT (SELECT o.opt.sharpe  FROM agents_demo_opt o) AS sharpe,
       (SELECT o.opt.weights FROM agents_demo_opt o) AS weights;

.mode list
.headers off
.output agents_demo_rebal.sql
SELECT 'SELECT m.id AS nearest_alloc_id, t.distance AS nearest_distance '
       'FROM fractal_search_trajectory(''agents_demo_alloc'', ''alloc'', '
       '[0.25,0.25,0.25,0.25]::float8[], '
       || CAST((SELECT opt.weights FROM agents_demo_opt) AS VARCHAR) ||
       '::float8[], 1) t '
       'JOIN (SELECT id, row_number() OVER (ORDER BY rowid) - 1 AS doc_id '
       'FROM agents_demo_alloc) m ON m.doc_id = t.doc_id '
       'ORDER BY t.distance LIMIT 1;'
;
.output stdout
.headers on
.mode box
.read agents_demo_rebal.sql

.print --- rationale (fractal_reason over the rebalance) ---
SELECT fractal_reason('one-line rebalance rationale for this portfolio');

.print
.print === 13b. the shipped agent: same composition, one call (baseline = the equal-weight row) ===
SELECT fractal_agent_rebalance_sibling(
    [0.05, 0.10, 0.15, 0.20]::float8[],
    [0.04, 0.0, 0.0, 0.0,
     0.0, 0.09, 0.0, 0.0,
     0.0, 0.0, 0.16, 0.0,
     0.0, 0.0, 0.0, 0.25]::float8[],
    4, 'agents_demo_alloc', 'alloc',
    [0.25, 0.25, 0.25, 0.25]::float8[], NULL, 5, 'id');

-- 13c. fractal_agent_diverse_portfolios (enterprise tier). Companion to
-- fractal_agent_allocate (Engine B, above): same 4-asset mu/cov, but
-- returns several structurally distinct good portfolios via
-- fractal_optimize_portfolio_multimodal instead of one, as a JSON array of
-- {candidate_id, sharpe, weights, rationale} rows with one shared
-- rationale across them. objective_mode defaults to 'sharpe'; 'pareto'
-- composes the _pareto variant and nests each row's weights with
-- per-candidate return/risk. The seed argument (arg 7) is accepted for
-- signature compatibility and ignored.
.print
.print === 13c-1. diverse_portfolios blueprint (4 assets, cardinality=2,
.print     enterprise tier) ===
.print '(expected on the community build: the clean enterprise-tier hint'
.print ' from the composed multimodal table function AND from the agent)'
SELECT *
FROM fractal_optimize_portfolio_multimodal(
    [0.05, 0.10, 0.15, 0.20]::float8[],
    [0.04, 0.0,  0.0,  0.0,
     0.0,  0.09, 0.0,  0.0,
     0.0,  0.0,  0.16, 0.0,
     0.0,  0.0,  0.0,  0.25]::float8[],
    2, n_restarts = 6);

.print
.print === 13c-2. the shipped agent: same composition, one call (also
.print     enterprise-gated; objective_mode 'pareto' would compose the
.print     _pareto table function) ===
SELECT fractal_agent_diverse_portfolios(
    [0.05, 0.10, 0.15, 0.20]::float8[],
    [0.04, 0.0,  0.0,  0.0,
     0.0,  0.09, 0.0,  0.0,
     0.0,  0.0,  0.16, 0.0,
     0.0,  0.0,  0.0,  0.25]::float8[],
    2, 6);

-- 14. fractal_agent_detour_classify (fleet-logistics).
-- Combines the route-deviation trajectory search (current vs baseline
-- across the fleet) with the GPS trace's box-counting complexity, then
-- reasons. nearest_fleet_id is the real trajectory nearest (resolved via
-- the id column); trajectory_distance is real; trace_complexity is the
-- real box-counting dimension of the GPS trace; rationale is the real
-- reasoning output. Vehicle 1 has a deliberate detour.
DROP TABLE IF EXISTS agents_demo_vehicles;
CREATE TABLE agents_demo_vehicles (id int PRIMARY KEY, baseline float8[], current float8[]);
INSERT INTO agents_demo_vehicles
SELECT gs, [b1, b2, b3, b4], [b1+0.05, b2+0.05, b3+0.05, b4+0.05]
FROM generate_series(1, 8) AS gs(gs),
     LATERAL (SELECT ag_rand(2000 + gs*10+1)*2-1, ag_rand(2000 + gs*10+2)*2-1,
                     ag_rand(2000 + gs*10+3)*2-1, ag_rand(2000 + gs*10+4)*2-1) AS bl(b1, b2, b3, b4)
ORDER BY gs;
UPDATE agents_demo_vehicles
   SET current = [(baseline[1]::float8)-0.7, (baseline[2]::float8)+0.6,
                  (baseline[3]::float8)+0.5, (baseline[4]::float8)-0.4]
 WHERE id = 1;

.print
.print === 14a. detour_classify blueprint (vehicle 1 detour + GPS trace) ===
-- Vehicle 1's UPDATE sets each current component to baseline + a fixed
-- offset, so its delta (current - baseline) is the constant [-0.7, 0.6,
-- 0.5, -0.4] -- which is exactly the delta vector the trajectory search
-- runs the fleet against (searched as zero-baseline -> delta-current).
-- The GPS trace runs through fractal_dimension_boxcount as its own
-- 2-D random walk (boxcount needs >= 3 valid eps-octaves, which a
-- scattered handful of points cannot give it).
SELECT m.id AS nearest_fleet_id, tr.distance AS trajectory_distance
FROM fractal_search_trajectory('agents_demo_vehicles', 'current',
         [0.0, 0.0, 0.0, 0.0]::float8[],
         [-0.7, 0.6, 0.5, -0.4]::float8[], 5) tr
JOIN (SELECT id, row_number() OVER (ORDER BY rowid) - 1 AS doc_id
        FROM agents_demo_vehicles) m ON m.doc_id = tr.doc_id
ORDER BY tr.distance LIMIT 1;

SELECT fractal_dimension_boxcount((SELECT array_agg(cum ORDER BY t, ord) FROM (
         SELECT t, ord, sum(step) OVER (PARTITION BY ord ORDER BY t) AS cum
           FROM generate_series(1, 100) AS t(t)
          CROSS JOIN LATERAL (VALUES (1, (ag_rand(3000 + t*10+1)-0.5)*0.3),
                              (2, (ag_rand(3000 + t*10+2)-0.5)*0.3)) AS s(ord, step)
     ) c), 2) AS trace_complexity;

.print --- rationale (fractal_reason over the detour scan) ---
SELECT fractal_reason('one-line detour classification for this fleet scan');

.print
.print === 14b. the shipped agent: same composition, one call (fresh GPS trace -- own randomness) ===
SELECT fractal_agent_detour_classify(
    'agents_demo_vehicles', 'current',
    (SELECT baseline::float8[] FROM agents_demo_vehicles WHERE id = 1),
    (SELECT current::float8[]  FROM agents_demo_vehicles WHERE id = 1),
    (SELECT array_agg(cum ORDER BY t, ord) FROM (
         SELECT t, ord, sum(step) OVER (PARTITION BY ord ORDER BY t) AS cum
           FROM generate_series(1, 100) AS t(t)
          CROSS JOIN LATERAL (VALUES (1, (ag_rand(4000 + t*10+1)-0.5)*0.3),
                              (2, (ag_rand(4000 + t*10+2)-0.5)*0.3)) AS s(ord, step)
     ) c),
    5, 'id', 2);

-- 15. fractal_agent_track_anomaly (maritime/cybersecurity).
-- Combines the track-deviation trajectory search with the heading-change
-- series' DFA exponent, then reasons. nearest_fleet_id is the real
-- trajectory nearest; trajectory_distance is real; dfa_exponent is the
-- real DFA exponent (may be -1 for an insufficient window -- passed
-- through); rationale is the real reasoning output. Vessel 1 has a
-- deliberate track deviation.
DROP TABLE IF EXISTS agents_demo_tracks;
CREATE TABLE agents_demo_tracks (id int PRIMARY KEY, baseline float8[], current float8[]);
INSERT INTO agents_demo_tracks
SELECT gs, [b1, b2, b3, b4], [b1+0.04, b2+0.04, b3+0.04, b4+0.04]
FROM generate_series(1, 8) AS gs(gs),
     LATERAL (SELECT ag_rand(5000 + gs*10+1)*2-1, ag_rand(5000 + gs*10+2)*2-1,
                     ag_rand(5000 + gs*10+3)*2-1, ag_rand(5000 + gs*10+4)*2-1) AS bl(b1, b2, b3, b4)
ORDER BY gs;
UPDATE agents_demo_tracks
   SET current = [(baseline[1]::float8)+0.6, (baseline[2]::float8)-0.5,
                  (baseline[3]::float8)-0.9, (baseline[4]::float8)+0.8]
 WHERE id = 1;

.print
.print === 15a. track_anomaly blueprint (vessel 1 deviation + heading DFA) ===
-- Same delta mechanics as 14a: vessel 1's update sets current to
-- baseline + [0.6, -0.5, -0.9, 0.8], so that constant delta is what the
-- trajectory search runs the fleet against. The heading-change series
-- runs through fractal_dimension_dfa (the burst between t=40 and t=60
-- shows up as the recent-window regime change).
SELECT m.id AS nearest_fleet_id, tr.distance AS trajectory_distance
FROM fractal_search_trajectory('agents_demo_tracks', 'current',
         [0.0, 0.0, 0.0, 0.0]::float8[],
         [0.6, -0.5, -0.9, 0.8]::float8[], 5) tr
JOIN (SELECT id, row_number() OVER (ORDER BY rowid) - 1 AS doc_id
        FROM agents_demo_tracks) m ON m.doc_id = tr.doc_id
ORDER BY tr.distance LIMIT 1;

SELECT fractal_dimension_dfa((SELECT array_agg(cum ORDER BY t) FROM (
         SELECT t, sum(step) OVER (ORDER BY t) AS cum
           FROM (SELECT t, (ag_rand(6000 + t)-0.5) *
                   (CASE WHEN t BETWEEN 40 AND 60 THEN 0.35 ELSE 0.03 END) AS step
                   FROM generate_series(1, 120) AS t(t)) s
     ) c)) AS dfa_exponent;

.print --- rationale (fractal_reason over the track scan) ---
SELECT fractal_reason('one-line anomaly read for this maritime track scan');

.print
.print === 15b. the shipped agent: same composition, one call (fresh heading series -- own randomness) ===
SELECT fractal_agent_track_anomaly(
    'agents_demo_tracks', 'current',
    (SELECT baseline::float8[] FROM agents_demo_tracks WHERE id = 1),
    (SELECT current::float8[]  FROM agents_demo_tracks WHERE id = 1),
    (SELECT array_agg(cum ORDER BY t) FROM (
         SELECT t, sum(step) OVER (ORDER BY t) AS cum
           FROM (SELECT t,
                        (ag_rand(7000 + t)-0.5) * (CASE WHEN t BETWEEN 40 AND 60 THEN 0.35
                                               ELSE 0.03 END) AS step
                   FROM generate_series(1, 120) AS t(t)) s
     ) c),
    5, 'id');

-- 16. fractal_agent_network_coverage_alert (smart-cities).
-- Combines the sensor grid's spatial morphology (40 points, matching the
-- smart-cities vertical's 20x20 grid shape) with the telemetry series'
-- regime-change drift, then reasons. The drift field is recent_alpha -
-- baseline_alpha (a SIGNED numeric); drift_detected is |drift| >
-- drift_threshold. morph_dimension/lacunarity are real; drift_detected is
-- a real boolean; rationale is the real reasoning output.
.print
.print === 16a. network_coverage_alert blueprint (20x20 grid + step-up drift) ===
-- The sensor grid's spatial morphology (400 points, >= the ~256 the
-- morphology estimator needs for its valid eps-octaves) via
-- fractal_morphological_complexity, plus the telemetry series'
-- regime-change drift via fractal_dimension_drift (the drift field is
-- recent_alpha - baseline_alpha, a SIGNED numeric).
WITH g AS (SELECT fractal_morphological_complexity(
                (SELECT array_agg(v ORDER BY id, ord) FROM (
                     SELECT r*20 + c AS id, ord, v
                       FROM generate_series(0, 19) AS r(r)
                      CROSS JOIN generate_series(0, 19) AS c(c)
                      CROSS JOIN LATERAL unnest([r + (ag_rand(8000 + r*100 + c*2 + 1)-0.5)*0.3,
                                                 c + (ag_rand(8000 + r*100 + c*2 + 2)-0.5)*0.3]) WITH ORDINALITY AS u(v, ord)
                 ) g) , 2) AS m)
SELECT g.m.dimension   AS morph_dimension,
       g.m.lacunarity  AS lacunarity
FROM g;

SELECT fractal_dimension_drift(
    (SELECT array_agg(v ORDER BY t) FROM (
         SELECT t, CASE WHEN t < 48 THEN 4.0 + 1.5*sin(t*0.31) + (ag_rand(10000 + t)-0.5)*0.8
                        ELSE 4.0 + 3.0*sin(t*1.4)  + (ag_rand(60000 + t)-0.5)*0.4 END AS v
           FROM generate_series(1, 96) AS t(t)) s), 48) AS drift;

.print --- rationale (fractal_reason over the coverage scan) ---
SELECT fractal_reason('one-line coverage alert for this sensor-grid scan');

.print
.print === 16b. the shipped agent: same composition, one call (fresh grid
.print     + series -- own randomness; the agent computes drift itself,
.print     so it takes the raw series, not the drift struct) ===
SELECT fractal_agent_network_coverage_alert(
    (SELECT array_agg(v ORDER BY id, ord) FROM (
         SELECT r*20 + c AS id, ord, v
           FROM generate_series(0, 19) AS r(r)
          CROSS JOIN generate_series(0, 19) AS c(c)
          CROSS JOIN LATERAL unnest([r + (ag_rand(9000 + r*100 + c*2 + 1)-0.5)*0.3,
                                     c + (ag_rand(9000 + r*100 + c*2 + 2)-0.5)*0.3]) WITH ORDINALITY AS u(v, ord)
     ) g),
    (SELECT array_agg(v ORDER BY t) FROM (
         SELECT t, CASE WHEN t < 48 THEN 4.0 + 1.5*sin(t*0.31) + (ag_rand(11000 + t)-0.5)*0.8
                        ELSE 4.0 + 3.0*sin(t*1.4)  + (ag_rand(61000 + t)-0.5)*0.4 END AS v
           FROM generate_series(1, 96) AS t(t)) s),
    2, 48, 0.5);

-- 17. fractal_agent_regime_triage (general-purpose).
-- Runs DFA (long-range-correlation exponent) and drift (regime-change
-- drift + recent/baseline alphas) over a single series, then reasons. The
-- array-in shape fits any one series (no per-row time/metric table,
-- unlike anomaly_triage). drift_detected is |drift| > drift_threshold;
-- dfa_exponent may be -1. All numeric keys are real; rationale is the
-- real reasoning output.
.print
.print === 17a. regime_triage blueprint (96-pt step-up series) ===
-- DFA (long-range-correlation exponent) plus the drift struct (regime
-- drift + recent/baseline alphas) over the same fixture series.
WITH s AS (SELECT fractal_dimension_dfa(
               (SELECT array_agg(v ORDER BY t) FROM (
                    SELECT t, CASE WHEN t < 48 THEN 4.0 + 1.5*sin(t*0.31) + (ag_rand(12000 + t)-0.5)*0.8
                                   ELSE 4.0 + 3.0*sin(t*1.4)  + (ag_rand(62000 + t)-0.5)*0.4 END AS v
                      FROM generate_series(1, 96) AS t(t)) s)) AS dfa),
d AS (SELECT fractal_dimension_drift(
           (SELECT array_agg(v ORDER BY t) FROM (
                SELECT t, CASE WHEN t < 48 THEN 4.0 + 1.5*sin(t*0.31) + (ag_rand(13000 + t)-0.5)*0.8
                               ELSE 4.0 + 3.0*sin(t*1.4)  + (ag_rand(63000 + t)-0.5)*0.4 END AS v
                   FROM generate_series(1, 96) AS t(t)) s), 64) AS dj)
SELECT s.dfa                   AS dfa_exponent,
       d.dj.drift              AS drift,
       d.dj.recent_alpha       AS recent_alpha,
       d.dj.baseline_alpha     AS baseline_alpha
FROM s, d;

.print --- rationale (fractal_reason over the regime read) ---
SELECT fractal_reason('one-line regime triage for this series');

.print
.print === 17b. the shipped agent: same composition, one call (fresh series -- own randomness) ===
SELECT fractal_agent_regime_triage(
    (SELECT array_agg(v ORDER BY t) FROM (
         SELECT t, CASE WHEN t < 48 THEN 4.0 + 1.5*sin(t*0.31) + (ag_rand(14000 + t)-0.5)*0.8
                        ELSE 4.0 + 3.0*sin(t*1.4)  + (ag_rand(64000 + t)-0.5)*0.4 END AS v
           FROM generate_series(1, 96) AS t(t)) s),
    64, 0.5);

-- --------------------------------------------------------------------
-- 18. Installed agent tier: trajectory_predict + detect_loop. Two
-- table/scalar functions the shipped composites sit next to, exercised
-- directly on the same fixtures (not blueprints -- these ARE the
-- registered engines).
--   * fractal_agent_trajectory_predict(table, vector_col, baseline_id,
--     forecast_steps) -> TABLE(predicted_state_vector DOUBLE[],
--     projected_drift_delta DOUBLE, risk_threshold_exceeded BOOLEAN):
--     reads the baseline row (baseline_id matched against the table's
--     primary key), the latest row, and searches the corpus for the
--     nearest state to their delta. forecast_steps is accepted for
--     signature compatibility (the forecast itself is a single-step
--     nearest-predicted-state lookup regardless; see the registration
--     comment in docs/api-agency.md).
--   * fractal_agent_detect_loop(agent_id, state LIST, dim [, n_bits,
--     seed, hamming_threshold]) -> STRUCT(agent_id, dfa_exponent,
--     is_loop_detected): SimHash-fingerprints the state sequence and
--     streams the fingerprints through Brent's cycle detector. The
--     fixture below is a DETERMINISTIC 4-D periodic state log (a
--     multi-frequency sinusoid), so the fingerprint repeats and the
--     detector flags it -- a genuine positive, not a false one. (A
--     one-dim fingerprint is a degenerate case -- see
--     demo-vertical-agentic-edge-swarm.sql's fixture note.)
-- --------------------------------------------------------------------
.print
.print === 18. Installed agent tier: trajectory_predict + detect_loop ===
SELECT * FROM fractal_agent_trajectory_predict('agents_demo_vehicles',
    'current', 1, 8) AS forecast;

-- state_log is FLAT -- n_states * dim doubles, row-major -- not a list
-- of per-state vectors, so flatten() collapses the per-state lists into
-- one row-major array (the same convention as the vertical demo's
-- array_agg(v ORDER BY t, ord)).
SELECT fractal_agent_detect_loop(
    'agents-demo-loop',
    (SELECT flatten(list([0.1*sin(t*0.7), 0.1*cos(t*0.7),
                          0.1*sin(t*0.7 + 1.0), 0.1*cos(t*0.7 + 1.0)]))
       FROM generate_series(1, 64) AS t(t)),
    4) AS loop_scan;

-- 19. Closing narrative -- fractal_reason over the real computed results.
-- Same closing pattern as demo.sql and every vertical demo: one final
-- reasoning call that synthesizes a human-readable read over the real
-- analytics the cognition agents just produced.
.print
.print === 19. Closing narrative: fractal_reason over the agent results ===
SELECT fractal_reason(
    'Synthesize a one-paragraph ops brief across the sixteen agents: the '
    'anomaly-triage threat_score, the allocation sharpe, the route_task '
    'routed_to/confidence, the outlier_intercept decision, the patient-'
    'deterioration cohort/drift distances, the schedule_workload assignment, the '
    'rebalance sharpe/weights, the diverse-portfolios candidate sharpes, the '
    'detour/track distances and trace/DFA complexity, and the coverage/regime '
    'drift_detected flags above, and what each implies for the on-call engineer.',
    struct_pack(
        source := 'demo-agents.sql',
        engines := ['fractal_agent_anomaly_triage',
                    'fractal_agent_allocate',
                    'fractal_agent_route_task',
                    'fractal_agent_outlier_intercept',
                    'fractal_agent_recall_hybrid',
                    'fractal_agent_recommend_diverse',
                    'fractal_agent_data_analyst',
                    'fractal_agent_patient_deterioration_triage',
                    'fractal_agent_feedback_audit',
                    'fractal_agent_schedule_workload',
                    'fractal_agent_rebalance_sibling',
                    'fractal_agent_diverse_portfolios',
                    'fractal_agent_detour_classify',
                    'fractal_agent_track_anomaly',
                    'fractal_agent_network_coverage_alert',
                    'fractal_agent_regime_triage']
    )::text
);

-- Belt-and-suspenders session-state reset: 11a's closing disable already
-- ends the ledger-context diversify state, and the shipped feedback_audit
-- (11b) self-disables on the shared engine context.
SELECT fractal_diversify_disable();

-- Cleanup: drop the demo tables (one per statement -- DuckDB's DROP
-- TABLE takes exactly one table). The agent functions are registered by
-- the extension and go away only when it unloads; re-running the demo
-- recreates everything. The blueprint layer's agents_demo_opt TEMP
-- table evaporates with the connection; the agents_demo_sched.sql /
-- agents_demo_warm.sql / agents_demo_iso.sql / agents_demo_rebal.sql
-- spool files live in the current directory, overwritten each run.
.print
.print ================================================================
.print Demo complete. Dropping the demo tables (one per statement --
.print DuckDB's DROP TABLE takes exactly one table):
.print ================================================================

DROP TABLE agents_demo_logs;
DROP TABLE agents_demo_caps;
DROP TABLE agents_demo_badstates;
DROP TABLE agents_demo_mem;
DROP TABLE agents_demo_catalog;
DROP TABLE agents_demo_data;
DROP TABLE agents_demo_patients;
DROP TABLE agents_demo_fcatalog;
DROP TABLE agents_demo_fwarmup;
DROP TABLE agents_demo_nodes;
DROP TABLE agents_demo_alloc;
DROP TABLE agents_demo_vehicles;
DROP TABLE agents_demo_tracks;

.print ================================================================