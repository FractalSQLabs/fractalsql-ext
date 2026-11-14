<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# Lakehouse: FractalSQL on Apache Iceberg

FractalSQL runs next to the DuckDB `iceberg` extension in the same session.
Read an Iceberg table in place with `iceberg_scan()`, then search it, screen
against it, or join it with the rest of your data.

## Requirements

- DuckDB CLI or Python package, matching the extension build (see
  [getting-started.md](getting-started.md)).
- The `iceberg` extension, installed from DuckDB's extension repository:

  ```sql
  INSTALL iceberg;
  LOAD iceberg;
  ```

- The FractalSQL extension loaded with `-unsigned` (or `SET allow_unsigned_extensions = true`
  in Python), as in the other demos.

The `iceberg` extension is published for linux_amd64 across DuckDB 1.3.x,
1.4.x and 1.5.x. The bundled demo container uses 1.5.6.

## Reading a table

Point `iceberg_scan()` at the table's current metadata file:

```sql
SELECT ticket_id, segment, emb
FROM iceberg_scan('/lake/tickets.metadata.json')
LIMIT 5;
```

Scans read the snapshot named in that metadata file. To pick up new data,
point the query at the newer metadata file.

## Vector columns: the one cast to know

Iceberg stores embeddings as `list<float>` or `list<double>`. DuckDB shows them
as `FLOAT[]` or `DOUBLE[]`. FractalSQL functions take one or the other:

| Function | Argument type | `list<float>` (`FLOAT[]`) | `list<double>` (`DOUBLE[]`) |
| --- | --- | --- | --- |
| `fractal_vector_cosine_similarity` | `FLOAT[]` | works as is | cast: `CAST(emb AS FLOAT[])` |
| `fractal_search`, `fractal_search_explore` | `DOUBLE[]` | widened implicitly | works as is |
| `fractal_agent_outlier_intercept` | `DOUBLE[]` | widened implicitly | works as is |

Show the cast in your own queries, or materialize it once:

```sql
CREATE TABLE tickets AS
SELECT ticket_id, segment, CAST(emb AS FLOAT[]) AS emb
FROM iceberg_scan('/lake/tickets.metadata.json');
```

## Example: nearest tickets

```sql
SELECT ticket_id, segment,
       fractal_vector_cosine_similarity(CAST(emb AS FLOAT[]),
                                        [0.0, 1.0, 0.3, 0.0, 0.0, 0.1, 0.0, 0.0]::FLOAT[]) AS similarity
FROM iceberg_scan('/lake/tickets.metadata.json')
ORDER BY similarity DESC
LIMIT 5;
```

## Running the demo

The demo is [demo/demo-lakehouse-iceberg.sql](../demo/demo-lakehouse-iceberg.sql).
It needs a table on disk first. The fixture writer is
[demo/lakehouse/make_iceberg_fixture.py](../demo/lakehouse/make_iceberg_fixture.py)
(Python 3 with `pyiceberg`, `pyarrow` and `sqlalchemy`):

```bash
pip install pyiceberg pyarrow sqlalchemy
LAKE_DIR=/lake python3 demo/lakehouse/make_iceberg_fixture.py
```

Then run it:

```bash
{ echo "LOAD '/path/to/fractalsql.v1.5.6.linux_amd64.duckdb_extension';"; \
  cat demo/demo-lakehouse-iceberg.sql; } | duckdb -unsigned mydb.duckdb
```

The demo reads the table from `$LAKE_DIR`, or from `/lake` when the variable is not set. To keep
the table somewhere else, set `LAKE_DIR` for both steps:

```bash
export LAKE_DIR=$HOME/lake
mkdir -p "$LAKE_DIR"
python3 demo/lakehouse/make_iceberg_fixture.py
{ echo "LOAD '/path/to/fractalsql.v1.5.6.linux_amd64.duckdb_extension';"; \
  cat demo/demo-lakehouse-iceberg.sql; } | duckdb -unsigned mydb.duckdb
```

The fixture records its own location inside the table metadata, so write the fixture and run the demo
with the same `LAKE_DIR`. The examples above show the default `/lake` for readability.

With the docker demo, `lake-fixture` writes the table and `demo` runs the script:

```bash
docker compose -f docker-compose.tmp.yml --profile lake run --rm lake-fixture
docker compose -f docker-compose.tmp.yml run --rm -e DEMO_SCRIPT=/demo/demo-lakehouse-iceberg.sql demo
```

The final section calls the reasoning tier through `fractal_agent_outlier_intercept`.
It needs a configured endpoint. See [reasoning-setup.md](reasoning-setup.md).

## Notes

- For DuckLake tables, see [lakehouse-ducklake.md](lakehouse-ducklake.md).
- The commit and query comparison between the two formats is in
  [bench/README.md](../bench/README.md#lakehouse-formats-iceberg-and-ducklake).

- The fixture writer uses a SQL catalog and a local warehouse, so it runs with
  no network service. Your production tables are usually in a REST or Hive catalog.
  Read them through their metadata file path, or through a catalog connection
  supported by your DuckDB build.
- `iceberg_scan()` on a bare table directory did not resolve in our testing.
  Use the metadata JSON path.
- Iceberg does not change how FractalSQL indexes or searches. The search runs on
  the rows the scan returns, so a large table should be materialized into a
  DuckDB table before repeated searches.
