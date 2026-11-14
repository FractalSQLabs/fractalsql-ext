-- demo/lakehouse/make_ducklake_fixture.sql
--
-- Writes the support-ticket DuckLake table used by demo-lakehouse-ducklake.sql.
-- Same scenario as make_iceberg_fixture.py: 240 tickets in four topic
-- clusters with 8-dimensional DOUBLE[] embeddings. Deterministic: the
-- per-ticket noise comes from a row-id-derived integer LCG, so every run
-- writes the same rows.
--
-- The catalog is a DuckDB file and the data is Parquet, both under $LAKE_DIR (default /lake).
-- The catalog file is named for the DuckDB version that writes it (tickets-1.5.ducklake, ...),
-- because a DuckLake catalog is only readable by the DuckDB line that created it.
-- The docker demo runs it in the ducklake-fixture service.
--
-- Run:
--   duckdb -unsigned < demo/lakehouse/make_ducklake_fixture.sql

INSTALL ducklake;
LOAD ducklake;

-- Where the table is written: $LAKE_DIR, or /lake when it is not set. ATTACH takes literal strings,
-- so the statement is written to a file with the directory filled in, then read. The directory
-- must exist, and demo-lakehouse-ducklake.sql must be run with the same LAKE_DIR: DuckLake records
-- the data path in its catalog.
SET VARIABLE lake_dir = coalesce(nullif(getenv('LAKE_DIR'), ''), '/lake');
-- A DuckLake catalog is only readable by the DuckDB line that wrote it (1.4.x, 1.5.x and 2.0.x each use a
-- different catalog version), so the catalog file name carries the line, e.g. tickets-1.5.ducklake.
SET VARIABLE lake_line = regexp_extract(version(), '^v?([0-9]+[.][0-9]+)', 1);
.mode list
.headers off
.output lake_attach.sql
SELECT format('ATTACH ''ducklake:{0}/ducklake/tickets-{1}.ducklake'' AS lake (DATA_PATH ''{0}/ducklake/data/'');',
              getvariable('lake_dir'), getvariable('lake_line'));
.output stdout
.mode duckbox
.headers on
.read lake_attach.sql

DROP TABLE IF EXISTS lake.tickets;

-- The fixture generator: an LCG with xor-shift rounds over pure integer
-- arithmetic, so every draw is exactly the same everywhere.
--
-- setseed() would not do: it seeds only the engine of the thread that
-- called it, and every other DuckDB worker thread runs its own random()
-- stream, so a fixture query DuckDB spreads over several threads hands
-- each row a value from a different stream -- and the ticket embeddings
-- came out different on a different machine. Deriving every draw from
-- the ticket id instead makes the fixture a pure function of the data.
-- The xor-shift rounds are not decoration: a plain LCG is AFFINE in
-- its seed, so two seeds one apart differ by a CONSTANT amount --
-- "separate" dimensions drawn from adjacent seeds came out as mirror
-- images of each other, and a 2-D walk built that way collapses onto a
-- line. The xor-shift breaks that affinity, so neighbouring seeds give
-- genuinely unrelated draws.
CREATE OR REPLACE MACRO vdl_lcg(s) AS ((((s::BIGINT * 1103515245::BIGINT) + 12345) % 2147483648));
CREATE OR REPLACE MACRO vdl_xs(a, sh) AS (xor(a, a >> sh));
CREATE OR REPLACE MACRO vdl_mix(s) AS (vdl_xs(vdl_lcg(vdl_xs(vdl_lcg(s), 13)), 17));
CREATE OR REPLACE MACRO vdl_rand(s) AS (vdl_mix(s)::DOUBLE / 2147483648.0);

CREATE TABLE lake.tickets AS
WITH centers AS (
    SELECT * FROM (VALUES
        ('billing',  [1.0, 0.2, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0]::DOUBLE[]),
        ('login',    [0.0, 1.0, 0.3, 0.0, 0.0, 0.1, 0.0, 0.0]::DOUBLE[]),
        ('shipping', [0.0, 0.0, 0.0, 1.0, 0.2, 0.0, 0.3, 0.0]::DOUBLE[]),
        ('outage',   [0.1, 0.0, 0.0, 0.0, 0.0, 1.0, 0.2, 0.6]::DOUBLE[])
    ) AS v(segment, c)
),
tickets AS (
    SELECT row_number() OVER (ORDER BY segment, r) AS ticket_id, segment, c
    FROM centers, range(60) AS t(r)
)
SELECT ticket_id::BIGINT AS ticket_id,
       segment,
       list_transform(c, lambda x, i: x + (vdl_rand(ticket_id * 100 + i) - 0.5) * 0.2) AS emb
FROM tickets;

SELECT segment, count(*) AS tickets FROM lake.tickets GROUP BY segment ORDER BY segment;
