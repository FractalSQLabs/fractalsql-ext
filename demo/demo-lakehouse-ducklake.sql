-- demo/demo-lakehouse-ducklake.sql
--
-- Industry vertical: Support operations on a DuckLake table.
--
-- The same support-ticket scenario as demo-lakehouse-iceberg.sql, stored
-- as a DuckLake table: a DuckDB catalog file for metadata and Parquet files
-- for data. FractalSQL reads it through an ATTACH in the same session.
--   1. the table as DuckDB sees it, and a per-segment count
--   2. nearest-ticket lookup for a new ticket (cosine similarity)
--   3. a pre-commit safety screen against known outage states
--
-- The DuckLake table is written by demo/lakehouse/make_ducklake_fixture.sql.
-- In the docker demo the ducklake-fixture service writes it to /lake; run
-- that once before this script. To read the table from another directory,
-- set LAKE_DIR in the environment of the DuckDB process (default /lake),
-- and write the fixture to the same place.
-- The catalog file is named for the DuckDB version (tickets-1.5.ducklake, ...):
-- run the fixture writer with the same DuckDB version as this demo.
--
-- Vector type note: the embedding is DOUBLE[]. Cosine similarity takes
-- FLOAT[], so section 2 casts at the call. The outlier screen takes DOUBLE[]
-- and needs no cast.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; \
--     cat demo/demo-lakehouse-ducklake.sql; } | duckdb -unsigned mydb.duckdb
--
-- Section 3 dispatches reasoning through the domain agents. Without a
-- reasoning endpoint those statements print an error. See
-- ../docs/reasoning-setup.md.
--
-- Safe to re-run: the lakehouse_* tables are dropped and recreated each time.

INSTALL ducklake;
LOAD ducklake;

-- Where the table lives: $LAKE_DIR, or /lake when it is not set. ATTACH takes literal
-- strings, so the statement is written to a file with the directory filled in, then read.
SET VARIABLE lake_dir = coalesce(nullif(getenv('LAKE_DIR'), ''), '/lake');
-- A DuckLake catalog is only readable by the DuckDB line that wrote it (1.4.x, 1.5.x and 2.0.x each use a
-- different catalog version), so the catalog file name carries the line, e.g. tickets-1.5.ducklake.
SET VARIABLE lake_line = regexp_extract(version(), '^v?([0-9]+[.][0-9]+)', 1);
.mode list
.headers off
.output lakehouse_attach.sql
SELECT format('ATTACH ''ducklake:{0}/ducklake/tickets-{1}.ducklake'' AS lake (DATA_PATH ''{0}/ducklake/data/'', READ_ONLY);',
              getvariable('lake_dir'), getvariable('lake_line'));
.output stdout
.mode box
.headers on
.read lakehouse_attach.sql

.print === 0. Sanity check: extension and DuckLake loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. The lakehouse table as DuckDB sees it.
-- ------------------------------------------------------------------
.print === 1. The lakehouse table as DuckDB sees it ===
DESCRIBE lake.tickets;

SELECT segment, count(*) AS tickets
FROM lake.tickets
GROUP BY segment
ORDER BY segment;

-- ------------------------------------------------------------------
-- 2. Materialize the working table, then score by cosine similarity.
-- The cast a user with their own DuckLake table will need:
--   CAST(emb AS FLOAT[])  -- DOUBLE[] -> FLOAT[] for cosine similarity
-- ------------------------------------------------------------------
.print === 2. Materialize the working table, then score by cosine similarity ===
CREATE OR REPLACE TABLE lakehouse_tickets AS
SELECT ticket_id, segment, emb
FROM lake.tickets;

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
