-- demo/demo.sql
--
-- FractalSQL basic demo: Sniper/Scout search feeding LLM reasoning.
--
-- Prerequisites (see demo/README.md for the full walkthrough):
--   1. The extension built and `LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';`
--      already run in your DuckDB session.
--   2. Reasoning configured per ../docs/reasoning-setup.md -- this script
--      assumes FRACTALSQL_REASONING_PLUGIN and the plugin's own
--      FSQL_REASONING_HTTP_URL/MODEL env vars are already set before
--      duckdb starts. Any OpenAI-compatible endpoint works (Ollama,
--      Bedrock, Azure, GCP Vertex, ...) -- this script doesn't care which.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; cat demo/demo.sql; } \
--       | duckdb -bail -unsigned
--
-- Safe to re-run: the demo tables are dropped and recreated each time.
-- Nothing here is destructive to anything outside the two demo_* tables.

-- (Timing is omitted -- DuckDB's CLI has no per-statement
-- timing dot-command; measure latency at the harness level, e.g.
-- demo/demo-workload.sh.)

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

.print
.print === 1. Set up a small alerts table with something worth noticing ===
DROP TABLE IF EXISTS demo_alerts;
DROP SEQUENCE IF EXISTS seq_demo_alerts_id;
CREATE SEQUENCE seq_demo_alerts_id;
CREATE TABLE demo_alerts (
    id          INTEGER PRIMARY KEY DEFAULT nextval('seq_demo_alerts_id'),
    service     text,
    message     text,
    severity    text,
    created_at  timestamptz DEFAULT now()
);

INSERT INTO demo_alerts (service, message, severity, created_at) VALUES
    ('api-gateway',  'request latency p99 245ms',              'info',     now() - interval '55 minutes'),
    ('api-gateway',  'request latency p99 260ms',              'info',     now() - interval '50 minutes'),
    ('payments',     'transaction processed successfully',     'info',     now() - interval '45 minutes'),
    ('payments',     'transaction processed successfully',     'info',     now() - interval '40 minutes'),
    ('auth-service', '3 failed login attempts, user_id=8821',  'warning',  now() - interval '30 minutes'),
    ('auth-service', '3 failed login attempts, user_id=8821',  'warning',  now() - interval '29 minutes'),
    ('auth-service', '17 failed login attempts, user_id=8821', 'warning',  now() - interval '28 minutes'),
    ('payments',     'transaction processed successfully',     'info',     now() - interval '20 minutes'),
    ('api-gateway',  'request latency p99 4200ms',              'critical', now() - interval '10 minutes'),
    ('api-gateway',  'request latency p99 3900ms',              'critical', now() - interval  '9 minutes');

.print
.print === 2. Sniper Search: converge to a single best point ===
-- fractal_sfs_converge(stored_vector, query) is a per-row scalar over a stored
-- column -- for each row it returns that vector's cosine distance to the
-- query's converged ideal point (the best point the SFS engine computes
-- once per distinct query per scan, memoized in the session), so order a
-- small corpus by distance and take the top rows. The one-shot
-- abstract-space form -- the converged ideal point itself -- is the
-- sibling overload: fractal_sfs_converge(query, iterations), with
-- fractal_sfs_converge_debug(query, iterations, population_size,
-- diffusion_factor) as the tunable, diagnostic variant.
DROP TABLE IF EXISTS demo_points;
CREATE TABLE demo_points (label text, pt double[]);   -- plain LIST(DOUBLE) values, no CSV TEXT vectors
INSERT INTO demo_points (label, pt) VALUES
    ('a', [0.6, 0.8, 0.0]),
    ('b', [0.1, 0.2, 0.0]),
    ('c', [-0.9, 0.4, 0.0]),
    ('d', [0.0, 0.0, 1.0]);
SELECT label, fractal_sfs_converge(pt, ARRAY[0.6, 0.8, 0.0]::float8[]) AS dist
  FROM demo_points
 ORDER BY dist
 LIMIT 3;

.print
.print === 3. Ask the LLM to analyze the alerts table (real context, not a bare ping) ===
-- No JSON extension loaded in this build -- list(t) aggregates each
-- row's own STRUCT (referring to a table alias bare, not alias.col,
-- yields the row as a STRUCT in DuckDB) into a LIST(STRUCT), and the
-- ::text cast renders DuckDB's own struct/list text format. That's
-- fine here: fractal_reason's context argument is free-form text fed
-- to an LLM prompt, not something parsed back out as strict JSON.
SELECT fractal_reason(
    'summarize what happened in the last hour and flag anything that needs attention',
    (SELECT list(t)::text
       FROM (SELECT service, message, severity, created_at
               FROM demo_alerts
              WHERE created_at > now() - interval '1 hour'
              ORDER BY created_at) t)
);

.print
.print === 4. Scout Discovery feeding reasoning: search + reason in one pipeline ===
DROP TABLE IF EXISTS demo_embeddings;
DROP SEQUENCE IF EXISTS seq_demo_embeddings_id;
CREATE SEQUENCE seq_demo_embeddings_id;
CREATE TABLE demo_embeddings (id INTEGER PRIMARY KEY DEFAULT nextval('seq_demo_embeddings_id'), emb_arr float8[]);

-- The fixture generator: a two-round LCG over pure integer arithmetic,
-- so every draw is exactly the same everywhere.
--
-- random() would not do: setseed() seeds only the engine of the thread
-- that called it, and every other DuckDB worker thread runs its own
-- random() stream, so a fixture query DuckDB spreads over several
-- threads hands each row a value from a different stream -- and the
-- embedding corpus came out different on a different machine. The LCG
-- is a pure function of the row id, so the corpus is the same on every
-- machine, core count and DuckDB build.
-- The xor-shift rounds are not decoration: a plain LCG is AFFINE in its
-- seed, so two seeds one apart differ by a CONSTANT amount -- the
-- dimensions of one embedding came out mirror images of each other
-- instead of independent draws. The xor-shift breaks that affinity.
CREATE OR REPLACE MACRO dm_lcg(s) AS ((((s::BIGINT * 1103515245::BIGINT) + 12345) % 2147483648));
CREATE OR REPLACE MACRO dm_xs(a, sh) AS (xor(a, a >> sh));
CREATE OR REPLACE MACRO dm_mix(s) AS (dm_xs(dm_lcg(dm_xs(dm_lcg(s), 13)), 17));
CREATE OR REPLACE MACRO dm_rand(s) AS (dm_mix(s)::DOUBLE / 2147483648.0);

INSERT INTO demo_embeddings (emb_arr)
SELECT ARRAY[dm_rand(gs*10+1), dm_rand(gs*10+2), dm_rand(gs*10+3)]::float8[]
FROM generate_series(1, 500) gs(gs)
ORDER BY gs;

-- fractal_search_explore's options arg is plain VARCHAR (JSON-shaped
-- text parsed internally) -- no cast needed. The anchor is a small
-- nonzero point, not the origin -- cosine is undefined there (the
-- adversarial case demo/demo-business-intelligence.sql's Section 6
-- documents).
SELECT fractal_reason(
    'these are points from a 3D embedding space sampled by Scout Discovery -- describe the spread',
    (SELECT list(p)::text FROM (
        SELECT p FROM fractal_search_explore(
            'demo_embeddings', 'emb_arr', ARRAY[0.2,0.1,0]::float8[],
            '{"population_size": 10, "iterations": 8, "walk": 0}'
        ) AS p
    ) t)
);

.print
.print === Demo complete ===
.print Tables demo_alerts, demo_points and demo_embeddings were left in place
.print for you to inspect further. Clean up with:
.print   DROP TABLE demo_alerts;
.print   DROP TABLE demo_points;
.print   DROP TABLE demo_embeddings;
.print (one DROP TABLE per statement -- DuckDB's DROP TABLE takes a single table.)
