<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# FractalSQL benchmark: HNSW vs Scout Mode

Head-to-head comparison of DuckDB's `vss` extension HNSW index against
FractalSQL's `fractal_search_explore` (Scout Mode, `walk=0`). Measures search
latency and island recall on a synthetic Gaussian-cluster dataset.

## Prerequisites

- A built `fractalsql.duckdb_extension`, needed only by
  `head_to_head.py` (run `./build.sh` from the repo root first; the
  script autodetects it under `dist/` or `build/`, or pass
  `--fractalsql-ext /path/to/fractalsql.duckdb_extension`)
- Python 3.9+
- Network access the first time you run a script, so DuckDB can
  `INSTALL vss` (a core extension maintained by the DuckDB team, not part
  of this repo)

## Setup

```bash
pip install -r bench/requirements.txt
```

## Run the benchmark

```bash
python3 bench/data_gen.py                # ~20s to populate 100k rows and index them
python3 bench/head_to_head.py            # ~10s for 5 queries
```

## What you should see

The output is a per-query table followed by an average. This example is
from an actual run, not a hand-written estimate:

```
Benchmark: 100000 stored vectors, 50 clusters, dim=128
  HNSW: ef_search=40, LIMIT 50
  Scout: population=50, iterations=8, mdn=2, walk=0.0 (brute-force relevance scan + MMR), col=emb_arr

qi  anchor      |       HNSW ms   HNSW recall    |     Scout ms   Scout recall
------------------------------------------------------------------------------
 0  cluster  23 |      238.3      1 / 50     |     1048.7      5 / 50
 1  cluster  25 |       57.6      1 / 50     |     1077.1      8 / 50
 2  cluster  37 |       48.2      1 / 50     |     1012.4      4 / 50
 3  cluster  47 |       50.0      1 / 50     |     1003.1      7 / 50
 4  cluster   1 |       58.8      1 / 50     |     1033.3      7 / 50

Averages over 5 queries:
  HNSW:     90.6 ms   recall  1.0 / 50
  Scout:  1034.9 ms   recall  6.2 / 50
  Scout is 11.4x slower and discovers 6.2x more distinct clusters
```

The run behind that block: DuckDB 1.5.6 in a Linux container on an AMD
Ryzen 5 5500, with the corpus and the database on a docker volume. The
first HNSW query pays for a cold index read; the other four are the
steady-state numbers.

The shape of the result will vary run to run, but the pattern is robust:
HNSW finds 1 cluster in tens of milliseconds; Scout Mode finds 4-8
clusters at about a second. This is the intended comparison: different
algorithms solving different problems.

The head-to-head above runs at `data_gen.py`'s own default, `d=128`. The
Scaling notes table below uses `d=768` instead (a common real embedding
width), which is most of why its per-query times are higher at the same N
(Scout's cost is O(N x D)): at 100,000 vectors, Scout takes 1.03 seconds at
`d=128` and 5.93 seconds at `d=768`. Both scaling rows were measured on
the machine described above.

## Scaling notes

The SFS fitness is `min over stored_set of ||candidate - v||^2`, evaluated
brute-force. Per-fitness cost is O(N x D), and SFS makes ~2500 evaluations
in a population=50, iterations=8 run. That scales roughly linearly with the
stored-set size; the first two rows below are measured directly. The third
is a linear extrapolation, not measured, so treat it as a rough order of
magnitude, not a promise:

| N (stored vectors) | Approx per-query Scout time at d=768 |
| ------------------- | ------------------------------------- |
| 10 000              | ~0.72 seconds (measured)              |
| 100 000 (default)   | ~5.93 seconds (measured)              |
| 1 000 000           | ~60 seconds (extrapolated)            |

HNSW is approximately N-independent in comparison. For production use
beyond ~100k vectors, Scout Mode is best applied to curated sub-corpora
where diversity matters more than scan throughput.

## Aggregate form vs the table-function form

Scout Mode has two entry points, both registered in this build:

- `fractal_search_explore(column, query[, options])` -- the aggregate, which
  scans whatever table the surrounding `FROM` clause provides and
  returns `LIST(LIST(DOUBLE))`:

  ```sql
  SELECT UNNEST(fractal_search_explore(emb_arr, ?::DOUBLE[], ?)) AS p
  FROM bench_vectors;
  ```

- `fractal_search_explore('table', 'column', query, options)` -- the
  table function, which scans a named table/column directly
  (same Scout options JSON).

`head_to_head.py` uses the aggregate form. The two produce the same
Scout result set over the same data; see
[docs/api-discovery.md](../docs/api-discovery.md) for the options both
accept.

## Tuning

`head_to_head.py` exposes a few knobs:

```
--n-queries        number of queries to average (default 5)
--top-k            #results per method, also SFS population_size (50)
--sfs-iter         SFS generations (default 8)
--sfs-mdn          diffusion factor (default 2)
--hnsw-ef-search   vss hnsw_ef_search (default 40)
--seed             query-selection RNG seed
```

`data_gen.py` exposes the dataset shape:

```
--n        total points (default 100000)
--dim      vector dimension (default 128)
--clusters number of Gaussian islands (default 50)
--sigma    intra-cluster std (default 0.05)
```

## FLOAT[dim] vs DOUBLE[] at scale

A second, unrelated benchmark: on-disk storage size and bulk-insert
throughput for `FLOAT[dim]` (fixed-size array, what the `vss` HNSW index
attaches to) vs `DOUBLE[]` (variable-length list, what
`fractal_sfs_converge`/`fractal_search_explore` consume), at `data_gen.py`'s real
scale rather than a hand-picked single row. Distinct from the
HNSW-vs-Scout comparison above.

```bash
python3 bench/vector_type_head_to_head.py
```

Reports two numbers: on-disk bytes/row (via a checkpointed file-size
delta, `FLOAT[dim]` vs `DOUBLE[]`) and bulk-insert throughput for both
column types.

The custom `fractal_vector` SQL type comparison (a search-latency
overload comparison plus a peak-backend-RSS regression
tripwire) has no equivalent in this build: there is no custom `fractal_vector` type
here (the `fractal_vector_*` functions operate on plain `LIST(FLOAT)`
values, so there's no second storage type with its own search overload to
compare against), and DuckDB is embedded in-process rather than
client-server, so there's no separate backend PID to sample RSS from.

`vector_type_head_to_head.py`'s own knobs:

```
--n     row count for both sub-benchmarks (default 20000 -- smaller
        than the full corpus; both arms are O(n) by design, so a
        subset is representative)
--dim   vector dimension (default 128)
```

## Lakehouse formats: Iceberg and DuckLake

`lakehouse_bench.py` writes the same support-ticket rows (8-dimensional
`DOUBLE[]` embeddings) as an Apache Iceberg table and as a DuckLake table, one
append per commit, then runs the same top-10 cosine query over each. The
Iceberg writer is pyiceberg with a local file catalog. The DuckLake writer is the
`ducklake` extension with a DuckDB catalog file. Both read back through DuckDB
with the FractalSQL extension loaded.

```bash
python3 -m venv bench/.venv && bench/.venv/bin/pip install duckdb==1.5.6 pyiceberg pyarrow sqlalchemy
bench/.venv/bin/python bench/lakehouse_bench.py \
    --fractalsql-ext dist/amd64/fractalsql.v1.5.6.linux_amd64.duckdb_extension \
    --commits 50 --rows 1000 --out bench/lakehouse_results_50x1000.json
```

Results from one run on this setup:

- CPU: AMD Ryzen 5 5500, 2 vCPUs, 7.8 GB RAM, local SSD
- DuckDB 1.5.6, `ducklake` and `iceberg` extensions from the DuckDB extension repository
- pyiceberg 0.12.0, local file catalog; DuckLake DuckDB-file catalog
- query median of 7 runs after one warm-up; the native column is the same query over a materialized DuckDB table

| Workload | Format | Commit ms (median) | Commit ms (last 10) | Data files | Data MB | Catalog KB | Top-10 cosine ms (median) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 50 x 1,000 rows | Iceberg | 91.3 | 104.5 | 201 | 5.5 | 20.5 | 117.4 |
| 50 x 1,000 rows | DuckLake | 26.6 | 35.5 | 50 | 3.5 | 3944.4 | 62.4 |
| 500 x 200 rows | Iceberg | 457.0 | 749.9 | 2,001 | 113.0 | 20.5 | 892.2 |
| 500 x 200 rows | DuckLake | 33.3 | 30.3 | 500 | 7.2 | 3944.4 | 103.0 |

Raw output: [lakehouse_results_50x1000.json](lakehouse_results_50x1000.json),
[lakehouse_results_500x200.json](lakehouse_results_500x200.json).

What the numbers show here:

- **Commits.** The Iceberg commit time grows with the number of commits, from
  a 91 ms median at 50 commits to 750 ms for the last 10 at 500 commits. The
  DuckLake commit stays near 30 ms in both runs.
- **Files.** Iceberg wrote about four files per commit (201 files for 50
  commits, 2,001 for 500). DuckLake wrote one Parquet file per commit, and its
  metadata lives in the catalog file.
- **Queries.** The Iceberg query went from 117 ms to 892 ms when the table grew
  from 50k to 100k rows across 10 times the files. DuckLake went from 62 ms to
  103 ms, in line with the row count. The native DuckDB table was about 3
  times faster than DuckLake and 6 to 27 times faster than Iceberg.

What these numbers do not show:

- They come from one machine and one run per workload. Re-run them on your
  hardware before you quote them.
- The catalog is a local file for Iceberg and a local DuckDB file for
  DuckLake. External-SQL or REST catalog backends are not measured.
- Commit times are wall time on a local disk. Object storage adds latency to
  both formats.
- Only the append path is measured. Deletes, schema changes, compaction and
  time travel are not included.

The demo tables for these formats are documented in
[docs/lakehouse-iceberg.md](../docs/lakehouse-iceberg.md) and
[docs/lakehouse-ducklake.md](../docs/lakehouse-ducklake.md).

## Index and precision benchmarks

* `bench/index_head_to_head.py` -- the native IVF index against the exact scan: the latency of
  both, the recall of the indexed search, and **how many rows the index actually read** (a
  benchmark that silently ran flat is reported as such).
* `bench/precision_agreement.py` -- the precision contract, measured: every SQL-visible distance
  is recomputed here, in python, with the same double accumulation and the same single rounding,
  and the two are compared **bit for bit**. A one-ULP disagreement is a failure.

```
python3 bench/index_head_to_head.py --db bench.duckdb --rows 20000 --dim 64 --queries 20 --k 10
python3 bench/precision_agreement.py --vectors 64 --dim 32
```

* `bench/scale_sweep.sh [db-file]` -- runs `head_to_head.py` over a range of corpus sizes on both the `DOUBLE[]` and `FLOAT[dim]` columns, one line per size.
* `bench/load_fractalsql.py` -- the helper the scripts use to load the local, unsigned extension build into a DuckDB connection (DuckDB extensions are loaded by path).
