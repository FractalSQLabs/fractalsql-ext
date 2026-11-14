#!/usr/bin/env python3
"""
bench/lakehouse_bench.py -- commit cost, storage footprint, and query
latency for an Apache Iceberg table and a DuckLake table holding the same
support-ticket rows.

Workload
    N commits of R rows each. Every row is an id, a segment, and an
    8-dimensional embedding stored as DOUBLE[] (the common shape from
    embedding pipelines). Each commit appends one batch.

Metrics
    commit_ms_median   median wall time per commit, all commits
    commit_ms_last10   median wall time of the last 10 commits
    files              data and metadata files on disk after the last commit
    bytes              total bytes on disk under the table's directory
    query_ms_median    median wall time of a top-10 cosine query over the
                       whole table, read through the format's own scan
    native_ms_median   the same query over a native DuckDB table holding the
                       same rows, for comparison

Iceberg writes with pyiceberg (SQL catalog, local warehouse). DuckLake
writes with the DuckDB ducklake extension (DuckDB catalog file, local data
path). Both read back through DuckDB with the FractalSQL extension loaded.

Usage:
    python3 bench/lakehouse_bench.py \\
        --fractalsql-ext dist/amd64/fractalsql.v1.5.6.linux_amd64.duckdb_extension \\
        --commits 50 --rows 1000 --out bench/lakehouse_results.json
"""
import argparse
import json
import os
import random
import shutil
import statistics
import tempfile
import time

import duckdb
import pyarrow as pa
from pyiceberg.catalog.sql import SqlCatalog
from pyiceberg.schema import Schema
from pyiceberg.types import DoubleType, ListType, LongType, NestedField, StringType

DIM = 8
CENTERS = {
    "billing": [1.0, 0.2, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0],
    "login": [0.0, 1.0, 0.3, 0.0, 0.0, 0.1, 0.0, 0.0],
    "shipping": [0.0, 0.0, 0.0, 1.0, 0.2, 0.0, 0.3, 0.0],
    "outage": [0.1, 0.0, 0.0, 0.0, 0.0, 1.0, 0.2, 0.6],
}
QUERY = [0.0, 1.0, 0.3, 0.0, 0.0, 0.1, 0.0, 0.0]
TOP_K = 10


def make_batch(rng, first_id, rows):
    names = list(CENTERS)
    ids, segs, vecs = [], [], []
    for i in range(rows):
        seg = names[rng.randrange(len(names))]
        ids.append(first_id + i)
        segs.append(seg)
        vecs.append([c + rng.gauss(0.0, 0.08) for c in CENTERS[seg]])
    return pa.table({
        "ticket_id": pa.array(ids, pa.int64()),
        "segment": segs,
        "emb": pa.array(vecs, pa.list_(pa.float64())),
    })


def dir_stats(path):
    files, total = 0, 0
    for root, _, names in os.walk(path):
        for n in names:
            files += 1
            total += os.path.getsize(os.path.join(root, n))
    return files, total


def timed(fn):
    t0 = time.perf_counter()
    fn()
    return (time.perf_counter() - t0) * 1000.0


def median(xs):
    return round(statistics.median(xs), 3) if xs else None


def query_sql(source):
    return (
        "SELECT ticket_id, segment, "
        "fractal_vector_cosine_similarity(CAST(emb AS FLOAT[]), "
        f"{QUERY}::FLOAT[]) AS sim FROM {source} "
        f"ORDER BY sim DESC LIMIT {TOP_K}"
    )


def run_iceberg(work, commits, rows, seed):
    root = os.path.join(work, "iceberg")
    wh = os.path.join(root, "wh")
    os.makedirs(wh)
    catalog = SqlCatalog("bench", uri="sqlite:///" + os.path.join(root, "catalog.db"),
                         warehouse="file://" + wh)
    catalog.create_namespace("bench")
    schema = Schema(
        NestedField(1, "ticket_id", LongType(), required=False),
        NestedField(2, "segment", StringType(), required=False),
        NestedField(3, "emb", ListType(4, DoubleType(), element_required=False), required=False),
    )
    table = catalog.create_table("bench.tickets", schema=schema)
    rng = random.Random(seed)
    times = []
    for c in range(commits):
        batch = make_batch(rng, c * rows + 1, rows)
        times.append(timed(lambda: table.append(batch)))
    files, total = dir_stats(wh)
    cat_bytes = os.path.getsize(os.path.join(root, "catalog.db"))
    latest = table.metadata_location.replace("file://", "")
    return times, files, total, cat_bytes, latest


def run_ducklake(work, commits, rows, seed):
    lake_dir = os.path.join(work, "ducklake")
    os.makedirs(os.path.join(lake_dir, "data"))
    catalog_file = os.path.join(lake_dir, "tickets.ducklake")
    conn = duckdb.connect()
    conn.execute("INSTALL ducklake; LOAD ducklake;")
    conn.execute(f"ATTACH 'ducklake:{catalog_file}' AS lake (DATA_PATH '{lake_dir}/data/')")
    rng = random.Random(seed)
    times = []
    first = True
    for c in range(commits):
        batch = make_batch(rng, c * rows + 1, rows)
        conn.register("batch", batch)
        sql = ("CREATE TABLE lake.tickets AS SELECT * FROM batch" if first
               else "INSERT INTO lake.tickets SELECT * FROM batch")
        times.append(timed(lambda: conn.execute(sql)))
        conn.unregister("batch")
        first = False
    conn.execute("DETACH lake")
    files, total = dir_stats(os.path.join(lake_dir, "data"))
    cat_bytes = os.path.getsize(catalog_file)
    return times, files, total, cat_bytes, catalog_file


def query_ms(conn, sql, runs):
    conn.execute(sql).fetchall()  # warm-up
    return [timed(lambda: conn.execute(sql).fetchall()) for _ in range(runs)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fractalsql-ext", required=True)
    ap.add_argument("--commits", type=int, default=50)
    ap.add_argument("--rows", type=int, default=1000)
    ap.add_argument("--runs", type=int, default=7)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--workdir", default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    if args.workdir:
        work = os.path.abspath(args.workdir)
        shutil.rmtree(work, ignore_errors=True)
        os.makedirs(work)
    else:
        work = tempfile.mkdtemp(prefix="fsql_lakehouse_")
    ext = os.path.abspath(args.fractalsql_ext)

    results = {"commits": args.commits, "rows_per_commit": args.rows,
               "total_rows": args.commits * args.rows, "dim": DIM,
               "duckdb": duckdb.__version__, "formats": {}}

    ice_times, ice_files, ice_bytes, ice_cat, ice_meta = run_iceberg(work, args.commits, args.rows, args.seed)
    dl_times, dl_files, dl_bytes, dl_cat, dl_catalog = run_ducklake(work, args.commits, args.rows, args.seed)

    conn = duckdb.connect(config={"allow_unsigned_extensions": "true"})
    conn.execute("INSTALL iceberg; LOAD iceberg; INSTALL ducklake; LOAD ducklake;")
    conn.execute(f"LOAD '{ext}'")
    conn.execute(f"ATTACH 'ducklake:{dl_catalog}' AS lake (DATA_PATH '{os.path.dirname(dl_catalog)}/data/', READ_ONLY)")

    ice_q = query_ms(conn, query_sql(f"iceberg_scan('{ice_meta}')"), args.runs)
    dl_q = query_ms(conn, query_sql("lake.tickets"), args.runs)
    conn.execute(f"CREATE OR REPLACE TABLE native AS SELECT * FROM iceberg_scan('{ice_meta}')")
    native_q = query_ms(conn, query_sql("native"), args.runs)

    results["formats"]["iceberg"] = {
        "commit_ms_median": median(ice_times),
        "commit_ms_last10": median(ice_times[-10:]),
        "files": ice_files, "data_bytes": ice_bytes, "catalog_bytes": ice_cat,
        "query_ms_median": median(ice_q),
    }
    results["formats"]["ducklake"] = {
        "commit_ms_median": median(dl_times),
        "commit_ms_last10": median(dl_times[-10:]),
        "files": dl_files, "data_bytes": dl_bytes, "catalog_bytes": dl_cat,
        "query_ms_median": median(dl_q),
    }
    results["native_query_ms_median"] = median(native_q)

    print(json.dumps(results, indent=2))
    if args.out:
        with open(args.out, "w") as f:
            json.dump(results, f, indent=2)
            f.write("\n")
    if not args.workdir:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
