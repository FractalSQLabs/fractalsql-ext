<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# Lakehouse: FractalSQL on DuckLake

DuckLake keeps table metadata in a SQL catalog and data in Parquet files.
This page covers reading a DuckLake table with FractalSQL in the same
session. For Apache Iceberg, see [lakehouse-iceberg.md](lakehouse-iceberg.md).

## Requirements

- DuckDB CLI or Python package, matching the extension build (see
  [getting-started.md](getting-started.md)).
- The `ducklake` extension, from DuckDB's extension repository:

  ```sql
  INSTALL ducklake;
  LOAD ducklake;
  ```

- The FractalSQL extension loaded with `-unsigned`, as in the other demos.

The `ducklake` extension is published for linux_amd64 on DuckDB 1.4.4 and
1.5.6, which is what the demo container and the benchmark use.

## Attaching a table

```sql
ATTACH 'ducklake:/lake/ducklake/tickets.ducklake' AS lake
  (DATA_PATH '/lake/ducklake/data/', READ_ONLY);

SELECT ticket_id, segment, emb
FROM lake.tickets
LIMIT 5;
```

`ducklake:<file>` names the catalog. `DATA_PATH` is where the Parquet files
live. Both must match the values used when the table was written.

## Vector columns

DuckLake stores whatever type the writer used. A `DOUBLE[]` column reads back
as `DOUBLE[]`. FractalSQL functions take `FLOAT[]` (cosine similarity) or
`DOUBLE[]` (search, explore, outlier screen), the same as with Iceberg. See
the table in [lakehouse-iceberg.md](lakehouse-iceberg.md#vector-columns-the-one-cast-to-know).

```sql
CREATE TABLE tickets AS
SELECT ticket_id, segment, CAST(emb AS FLOAT[]) AS emb
FROM lake.tickets;
```

## Writing the demo table

The demo writes a 240-row table with [demo/lakehouse/make_ducklake_fixture.sql](../demo/lakehouse/make_ducklake_fixture.sql).
It needs no Python:

```bash
mkdir -p /lake/ducklake/data
duckdb -unsigned < demo/lakehouse/make_ducklake_fixture.sql
```

The table goes under `$LAKE_DIR`, or `/lake` when the variable is not set. To keep it somewhere else, set
`LAKE_DIR` for the writer and for the demo:

```bash
export LAKE_DIR=$HOME/lake
mkdir -p "$LAKE_DIR/ducklake/data"
duckdb -unsigned < demo/lakehouse/make_ducklake_fixture.sql
```

Use the same value when you run the demo. DuckLake stores the data directory in its catalog, so attaching
the table with a different `DATA_PATH` is refused. The `ATTACH` examples above show the default `/lake`.

**The catalog file is named for the DuckDB version that wrote it.** A DuckLake catalog is only readable by
the DuckDB line that created it: 1.4.x, 1.5.x and 2.0.x each use a different catalog version, and a newer
extension refuses an older catalog unless you opt in to migrating it. The fixture writer and the demo
therefore both derive the file name from `version()`, giving `tickets-1.4.ducklake`, `tickets-1.5.ducklake`
or `tickets-2.0.ducklake` next to a shared `data/` directory. Run the writer with the same DuckDB version you
will run the demo with; to support several versions from one directory, run it once per version. (The Docker
demo needs nothing extra: the fixture service and the demo run the same DuckDB.)

For your own table, the same applies: `ATTACH` it with the DuckDB line that created it, or migrate it once
with the `AUTOMATIC_MIGRATION` option.

With the docker demo:

```bash
docker compose -f docker-compose.tmp.yml --profile lake run --rm ducklake-fixture
docker compose -f docker-compose.tmp.yml run --rm -e DEMO_SCRIPT=/demo/demo-lakehouse-ducklake.sql demo
```

The walkthrough is [demo/demo-lakehouse-ducklake.sql](../demo/demo-lakehouse-ducklake.sql).
Its final section calls the reasoning tier and needs a configured endpoint.
See [reasoning-setup.md](reasoning-setup.md).

## Commit cost and storage

DuckLake writes one Parquet file per insert and keeps metadata in the catalog,
so commits stay flat as the table grows. Iceberg writes new metadata files on
every commit. The measured comparison, and what it does not cover, is in
[bench/README.md](../bench/README.md#lakehouse-formats-iceberg-and-ducklake).

## When to use which

- **DuckLake** when DuckDB is the main engine and the catalog can be a DuckDB
  file or a database you already run.
- **Iceberg** when other engines such as Spark, Trino or cloud warehouses
  must read the same tables.
