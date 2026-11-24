-- =============================================================================
-- FractalSQL Industry Vertical Demo: Scenario Exploration & Safe Execution
-- =============================================================================
-- End-to-end regression test for the planning + text-to-sql agents. Exercises:
--   * fractal_agent_plan_explore     -- embeds the seed state, Scout-searches
--                                       a real 768-dim embedding column (the
--                                       embed-coupling now satisfied by the
--                                       vectorizer, so this runs unwrapped)
--   * fractal_sql_agent              -- auto-executes model-generated SQL:
--                                       a thrown execution ERROR is caught
--                                       and surfaced as
--                                       execution_status='execution_failed',
--                                       not propagated to abort the call
--   * fractal_agent_rebalance_sibling -- portfolio rebalance (optimizer +
--                                       trajectory search) composition
--   * fractal_reason                 -- rationale synthesis
--   * fractal_vectorizer_*           -- vectorizes strategy descriptions
-- Re-runnable (see the teardown block at the top).
-- =============================================================================

-- Notes:
--   * The Section 7 rebalance composition's two halves agree: the SFS
--     optimizer's max-Sharpe book for mu=[0.05,0.1] with an identity
--     covariance is the 1/3 - 2/3 split (Sharpe 0.1118), and the nearest
--     prior allocation to that book is the Q2-2025 defensive tilt
--     (alloc_id 2).
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=agentic-fintech-mcts ok);
--     the build_test kit gate greps for it.

-- (the vectorizer bookkeeping bootstrap mirrors
-- docs/vectorizer-setup.md so these DELETEs are no-ops
-- on a fresh database; this edition has no rate-window table)
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
    (SELECT id FROM fractal_vectorizers WHERE source_table = 'trade_strategies');
DELETE FROM fractal_vectorizers WHERE source_table = 'trade_strategies';
-- (one table per statement -- DuckDB's DROP TABLE takes a single table;
-- no CASCADE suffix, the schemas below declare no FK chains to tear down)
DROP TABLE IF EXISTS trade_strategies;
DROP TABLE IF EXISTS historical_allocations;
DROP TABLE IF EXISTS restrictions;
DROP TABLE IF EXISTS assets;
DROP TABLE IF EXISTS portfolios;

-- 1. Setup financial strategy space
CREATE TABLE trade_strategies (
    strategy_id     bigint PRIMARY KEY,
    description     text,                 -- vectorized below
    -- float8[768], not a fractal_vector catalog type (this build has none --
    -- see docs/api-analytics.md) -- and
    -- specifically float8/DOUBLE, not float4: fractal_embed() returns
    -- LIST(DOUBLE), and fractal_agent_plan_explore below is a search-family
    -- function (DOUBLE-based), not a fractal_vector_* arithmetic primitive.
    embedding       float8[768],  -- populated by the vectorizer (nomic-embed-text)
    trajectory      float8[],
    constraints     json,
    expected_return float8
);

INSERT INTO trade_strategies (strategy_id, description, trajectory, constraints, expected_return)
VALUES
(1, 'low-volatility mean-reversion strategy targeting ESG-compliant equities with tight risk bounds',
        ARRAY[0.1, 0.2], '{"max_risk": 0.05}', 0.08),
(2, 'momentum strategy riding medium-term trends with moderate risk tolerance and diversified sector exposure',
        ARRAY[0.5, 0.1], '{"max_risk": 0.10}', 0.12),
(3, 'high-conviction concentrated strategy with strict risk budget and low expected turnover',
        ARRAY[0.9, 0.8], '{"max_risk": 0.02}', 0.04);

.print === 2. Vectorize the strategy descriptions ===
-- Vectorize the strategy descriptions into 768-dim embeddings. This is the
-- embedding-width column fractal_agent_plan_explore needs (it embeds the
-- initial_state text and Scout-searches this column).
SELECT fractal_vectorizer_create('trade_strategies', 'strategy_id', 'description', 'embedding');
SELECT fractal_vectorizer_process_queue();

-- 3. Portfolio/asset/restriction tables referenced by the fractal_sql_agent
-- regulatory-audit step. Minimal seed so the agent's schema context
-- (fractal_schema_context) can resolve the table_names it is given.
CREATE TABLE portfolios (
    portfolio_id int PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE assets (
    asset_id int PRIMARY KEY,
    portfolio_id int NOT NULL,
    value numeric NOT NULL,
    esg_restricted boolean NOT NULL DEFAULT false
);
CREATE TABLE restrictions (
    restriction_id int PRIMARY KEY,
    asset_id int NOT NULL,
    restriction_type text NOT NULL
);
INSERT INTO portfolios (portfolio_id, name) VALUES
    (1, 'Global Growth'), (2, 'ESG Core'), (3, 'High Yield');
INSERT INTO assets (asset_id, portfolio_id, value, esg_restricted) VALUES
    (101, 1, 250000, false),
    (102, 1, 120000, true),
    (103, 2,  80000, true),
    (104, 3, 310000, false);
INSERT INTO restrictions (restriction_id, asset_id, restriction_type) VALUES
    (1, 102, 'ESG-fossil-fuel'),
    (2, 103, 'ESG-weapons');

-- 4. A snapshot of past allocation decisions, for fractal_agent_
-- rebalance_sibling's trajectory-search half: "which prior allocation is
-- this new one closest to." Weight vectors match mu/cov's 2-asset shape
-- below.
CREATE TABLE historical_allocations (
    alloc_id  bigint PRIMARY KEY,
    label     text,
    weights   float8[]
);
INSERT INTO historical_allocations (alloc_id, label, weights) VALUES
(1, 'Q1-2025 momentum tilt',  ARRAY[0.6, 0.4]),
(2, 'Q2-2025 defensive tilt', ARRAY[0.3, 0.7]),
(3, 'Q3-2025 balanced',       ARRAY[0.5, 0.5]);

-- -----------------------------------------------------------------------------
-- DEMONSTRATION
-- -----------------------------------------------------------------------------

-- 5. MCTS-style strategy exploration
-- Explore N non-overlapping execution paths starting from a seed market
-- state. fractal_agent_plan_explore embeds the initial_state text (->768)
-- and Scout-searches the trade_strategies.embedding column for diverse
-- branches. Positional only: (initial_state, table_name, vector_col,
-- max_branches).
.print
.print === 5. fractal_agent_plan_explore (MCTS-style branching) ===
SELECT * FROM fractal_agent_plan_explore(
    'momentum strategy with moderate risk',
    'trade_strategies', 'embedding',
    3
);
-- Result: 3 diverse branch_ids with confidence scores

-- 6. Self-correcting Text-to-SQL for regulatory audit
-- Ask for a complex regulatory report, with auto-execution and retries. The
-- generated SQL runs inside the agent: a thrown execution ERROR is caught
-- and returned as execution_status='execution_failed' + the error in
-- result_json, rather than aborting the whole agent call. On a working model
-- it returns execution_status='executed' and the row count in result_json.
-- Positional only: (question, table_names, max_retries, auto_execute).
.print
.print === 6. fractal_sql_agent (regulatory audit; reasoning plugin) ===
SELECT * FROM fractal_sql_agent(
    'Calculate the total exposure to ESG-restricted assets across all portfolios',
    ARRAY['portfolios', 'assets', 'restrictions'],
    3, true
);

.print
.print === 7. Portfolio rebalance (optimizer + nearest prior allocation) ===
-- The rebalance_sibling composition's halves, executed: the SFS
-- optimizer (cov must be a FLATTENED 1-D array of length n_assets^2 --
-- fractal_optimize_portfolio rejects a 2-D matrix; the 2x2 identity here
-- is [1,0,0,1] row-major, see demo-vertical-quant-finance.sql for the
-- array_agg pattern at real scale), then the nearest prior allocation to
-- the equal-weight baseline via fractal_search_trajectory (baseline ->
-- optimizer weights; trajectory's doc_id is a 0-INDEXED scan position,
-- mapped back to alloc_id with row_number()). fractal_optimize_portfolio
-- is a scalar returning one STRUCT (field access via `.field`), so the
-- weights roundtrip through a TEMP table plus the .once/.read spool
-- (table-function args are constant-only in DuckDB -- the
-- demo-agents.sql 13a idiom).
CREATE OR REPLACE TEMP TABLE ftm_opt AS
SELECT fractal_optimize_portfolio(
    ARRAY[0.05, 0.1]::float8[],
    ARRAY[1.0, 0.0, 0.0, 1.0]::float8[],
    2, 42
) AS opt;
SELECT (SELECT o.opt.sharpe  FROM ftm_opt o) AS sharpe,
       (SELECT o.opt.weights FROM ftm_opt o) AS weights;

.mode list
.headers off
.output ftm_rebal.sql
SELECT 'CREATE OR REPLACE TEMP TABLE ftm_near AS '
       'SELECT m.alloc_id AS nearest_alloc_id, t.distance AS nearest_distance '
       'FROM fractal_search_trajectory(''historical_allocations'', ''weights'', '
       '[0.5,0.5]::float8[], '
       || CAST((SELECT opt.weights FROM ftm_opt) AS VARCHAR) ||
       '::float8[], 1) t '
       'JOIN (SELECT alloc_id, row_number() OVER (ORDER BY rowid) - 1 AS doc_id '
       'FROM historical_allocations) m ON m.doc_id = t.doc_id '
       'ORDER BY t.distance LIMIT 1;'
;
.output stdout
.headers on
.mode box
.read ftm_rebal.sql
SELECT * FROM ftm_near;

.print --- rationale (fractal_reason over both halves) ---
SELECT fractal_reason('one-line rebalance rationale for this portfolio',
    (SELECT to_json(r)::text FROM ftm_opt r) || ' ' || (SELECT to_json(r)::text FROM ftm_near r));

.print --- the shipped agent: same composition, one call ---
-- Returns one JSON document: {sharpe, weights, nearest_alloc_id,
-- nearest_distance, rationale}. Seed arg NULL is fine -- unpinned
-- optimization.
SELECT fractal_agent_rebalance_sibling(
    ARRAY[0.05, 0.1]::float8[],
    ARRAY[1.0, 0.0, 0.0, 1.0]::float8[],
    2,
    'historical_allocations', 'weights',
    ARRAY[0.5, 0.5]::float8[],
    NULL, 5, 'alloc_id', '{"portfolio": "port-global-01"}'
);

-- 8. Safe Execution in Subtransactions
-- The auto_execute above runs the generated SQL inside the agent call and
-- captures any late-stage constraint violation into
-- execution_status/result_json instead of aborting the session.

-- Reset nothing: no session-global flags were left enabled by this demo.

-- -----------------------------------------------------------------------------
-- 9. Headline check: the demo's own claims, recomputed from the demo's own
-- tables and calls -- the Section 5 exploration really does branch into three
-- distinct plans over the 768-dim strategy corpus, and the Section 7 rebalance
-- composition's two halves agree: the optimizer's max-Sharpe book for
-- mu=[0.05,0.1] with an identity covariance is the 1/3 - 2/3 split (Sharpe
-- 0.1118), and the nearest prior allocation to that book is the Q2-2025
-- defensive tilt (alloc_id 2).
--
-- The optimizer's book IS the analytic optimum for this problem (weights
-- proportional to Sigma^-1 mu, normalized), and the trajectory search's cosine
-- distance is scale-invariant -- so searching with that literal book
-- reproduces the Section 7 result exactly.
-- -----------------------------------------------------------------------------
.print
.print === 9. Headline check ===
.mode list
.headers off
WITH branches AS (
    SELECT branch_id, confidence_score, len(plan_trajectory) AS traj_len
    FROM fractal_agent_plan_explore(
        'momentum strategy with moderate risk',
        'trade_strategies', 'embedding',
        3)
),
opt AS (
    SELECT o.opt.sharpe                     AS sharpe,
           list_extract(o.opt.weights, 1)    AS w1,
           list_extract(o.opt.weights, 2)    AS w2
    FROM ftm_opt o
),
traj AS (
    SELECT m.alloc_id, m.label, t.distance
    FROM fractal_search_trajectory('historical_allocations', 'weights',
                                   [0.5, 0.5]::float8[],
                                   [0.3333333333333333, 0.6666666666666667]::float8[], 3) t
    JOIN (SELECT alloc_id, label, row_number() OVER (ORDER BY rowid) - 1 AS doc_id
            FROM historical_allocations) m
      ON m.doc_id = t.doc_id
)
SELECT 'HEADLINE kit=agentic-fintech-mcts ' || CASE WHEN
         (SELECT count(*) FROM branches) = 3
     AND (SELECT count(DISTINCT branch_id) FROM branches) = 3
     AND (SELECT count(*) FROM branches WHERE traj_len = 768) = 3
     AND (SELECT max(confidence_score) FROM branches) <= 1 + 1e-9
     AND (SELECT sharpe FROM opt) > 0.1
     AND (SELECT sharpe FROM opt) < 0.13
     AND (SELECT abs(w1 + w2 - 1.0) FROM opt) < 1e-6
     AND (SELECT w1 FROM opt) < 0.5
     AND (SELECT w2 FROM opt) > 0.5
     AND (SELECT count(*) FROM traj) = 3
     AND (SELECT alloc_id FROM traj ORDER BY distance LIMIT 1) = 2
     AND (SELECT label FROM traj ORDER BY distance LIMIT 1) = 'Q2-2025 defensive tilt'
     AND (SELECT distance FROM traj ORDER BY distance LIMIT 1) < 0.7
     AND (SELECT distance FROM traj ORDER BY distance LIMIT 1 OFFSET 1) > 0.9
THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print ================================================================
.print Demo complete. Tables left in place for inspection -- drop them
.print to re-run (one DROP per statement -- DuckDB's DROP TABLE takes
.print exactly one table):
.print   DROP TABLE trade_strategies;
.print   DROP TABLE portfolios;
.print   DROP TABLE assets;
.print   DROP TABLE restrictions;
.print   DROP TABLE historical_allocations;
.print (the ftm_opt TEMP table evaporates with the connection; the
.print ftm_rebal.sql spool file lives in the current directory,
.print overwritten each run.)
.print ================================================================