-- demo/demo-lakehouse-iceberg.sql
--
-- Industry vertical: Support operations on a lakehouse table.
--
-- Support tickets live in an Iceberg table, one row per ticket with an
-- 8-dimensional embedding stored as list<double>. This demo reads that
-- table in place with the DuckDB iceberg extension and runs FractalSQL
-- on top of it:
--   1. nearest-ticket lookup for a new ticket (cosine similarity)
--   2. a pre-commit safety screen that intercepts a proposed action
--      when its state is close to a known outage pattern
--
-- The Iceberg table is written by demo/lakehouse/make_iceberg_fixture.py.
-- In the docker demo the lake-fixture service writes it to /lake; run
-- that once before this script. To read the table from another directory,
-- set LAKE_DIR in the environment of the DuckDB process (default /lake),
-- and run the fixture script with the same LAKE_DIR.
--
-- Vector type note: iceberg list<double> arrives as DOUBLE[]. Cosine
-- similarity takes FLOAT[], so section 2 casts at the call. The outlier
-- screen takes DOUBLE[] and needs no cast.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; \
--     cat demo/demo-lakehouse-iceberg.sql; } | duckdb -unsigned mydb.duckdb
--
-- Section 4 dispatches reasoning through the domain agents. Without a
-- reasoning endpoint those two statements print an error. See
-- ../docs/reasoning-setup.md.
--
-- Safe to re-run: lakehouse_* tables are dropped and recreated each time.

INSTALL iceberg;
LOAD iceberg;

-- Where the table lives: $LAKE_DIR, or /lake when it is not set.
SET VARIABLE lake_dir = coalesce(nullif(getenv('LAKE_DIR'), ''), '/lake');

.print === 0. Sanity check: extension and Iceberg loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Scan the Iceberg table in place. Nothing is copied yet.
-- ------------------------------------------------------------------
.print === 1. The lakehouse table as DuckDB sees it ===
DESCRIBE SELECT * FROM iceberg_scan(getvariable('lake_dir') || '/tickets.metadata.json');

SELECT segment, count(*) AS tickets
FROM iceberg_scan(getvariable('lake_dir') || '/tickets.metadata.json')
GROUP BY segment
ORDER BY segment;

-- ------------------------------------------------------------------
-- 2. Materialize the working set. The DOUBLE[] column is kept as-is for
-- the outlier screen; the FLOAT[] cast for cosine is shown on its own.
-- ------------------------------------------------------------------
.print === 2. Materialize the working table, then score by cosine similarity ===
CREATE OR REPLACE TABLE lakehouse_tickets AS
SELECT ticket_id, segment, body, emb
FROM iceberg_scan(getvariable('lake_dir') || '/tickets.metadata.json');

-- The cast a user with their own Iceberg table will need:
--   CAST(emb AS FLOAT[])  -- list<double> -> FLOAT[] for cosine similarity
SELECT ticket_id, segment,
       fractal_vector_cosine_similarity(CAST(emb AS FLOAT[]),
                                        [0.0, 1.0, 0.3, 0.0, 0.0, 0.1, 0.0, 0.0]::FLOAT[]) AS similarity
FROM lakehouse_tickets
ORDER BY similarity DESC
LIMIT 5;

-- ------------------------------------------------------------------
-- 3. A new ticket arrives. Which existing tickets does it look like?
-- The embedding below sits in the login cluster.
-- ------------------------------------------------------------------
.print === 3. Nearest tickets to a new login-style ticket ===
WITH q AS (
    SELECT CAST([0.05, 0.95, 0.3, 0.0, 0.0, 0.12, 0.0, 0.0] AS FLOAT[]) AS qv
)
SELECT t.segment, count(*) AS neighbours, round(avg(s.sim), 4) AS mean_similarity
FROM (
    SELECT ticket_id, segment,
           fractal_vector_cosine_similarity(CAST(emb AS FLOAT[]), q.qv) AS sim
    FROM lakehouse_tickets, q
    ORDER BY sim DESC
    LIMIT 20
) AS s
JOIN lakehouse_tickets AS t USING (ticket_id)
GROUP BY t.segment
ORDER BY neighbours DESC;

-- ------------------------------------------------------------------
-- 4. Safety screen. The outage tickets are the known-bad states. A
-- proposed automated action is intercepted when its state sits within
-- the threshold of an outage ticket. Uses the DOUBLE[] column directly.
-- ------------------------------------------------------------------
.print === 4. Pre-commit screen against known outage states ===
CREATE OR REPLACE TABLE lakehouse_outage_states AS
SELECT ticket_id, emb FROM lakehouse_tickets WHERE segment = 'outage';

-- Proposed action state close to the outage cluster: intercepted.
SELECT fractal_agent_outlier_intercept(
    [0.1, 0.0, 0.0, 0.0, 0.0, 1.0, 0.25, 0.55]::DOUBLE[],
    'lakehouse_outage_states', 'emb', 0.2);

-- Proposed action in the billing cluster: allowed.
SELECT fractal_agent_outlier_intercept(
    [1.0, 0.2, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0]::DOUBLE[],
    'lakehouse_outage_states', 'emb', 0.2);
