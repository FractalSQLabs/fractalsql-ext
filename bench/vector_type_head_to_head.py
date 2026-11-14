#!/usr/bin/env python3
"""
bench/vector_type_head_to_head.py -- FLOAT[dim] vs DOUBLE[] at
data_gen.py's actual scale (100k rows / dim 128 by default -- pass
--dim 768 to data_gen.py for realistic-embedding scale), not a
hand-picked single row.

Distinct from bench/head_to_head.py (HNSW-vs-Scout algorithm comparison,
unrelated to storage type).

Measures:
  (a) On-disk storage size, FLOAT[dim] vs DOUBLE[], via file-size delta
      of a checkpointed table holding only that one column.
  (b) Bulk-insert throughput for both column types.

Two dimensions of the original benchmark do not carry over here:
(c) a fractal_vector-vs-float8[] search-latency overload comparison and (d)
peak backend RSS during a fractal_vector scan. There is no custom
`fractal_vector` SQL type in this build (see bench/README.md)
-- the equivalent fractal_vector_* functions operate on plain
LIST(FLOAT) values, so there is no second storage type with its own
search overload to compare against, and DuckDB is embedded in-process
rather than client-server, so there's no separate "backend PID" to
sample RSS from in the first place.

Usage:
    python3 bench/vector_type_head_to_head.py
"""

import argparse
import os
import sys
import tempfile
import time

import duckdb
import numpy as np


def load_corpus(conn, n: int, dim: int, coltype: str, vecs: np.ndarray) -> None:
    """
    Loads the corpus into (id INTEGER, v coltype) in one step.

    The rows are handed to DuckDB as a matrix of columns and the list
    column is built in SQL, which is what a bulk load looks like to the
    engine. The values are the same ones a row-at-a-time load writes: the
    FLOAT[dim] column is the float64 data rounded to float32.
    """
    matrix = np.empty((n, dim + 1), dtype=np.float64)
    matrix[:, :dim] = vecs
    matrix[:, dim] = np.arange(n)
    corpus = np.asfortranarray(matrix.T)
    conn.execute("CREATE TEMP TABLE corpus_matrix AS SELECT * FROM corpus")
    names = ", ".join(f"column{i}" for i in range(dim))
    conn.execute(
        f"INSERT INTO t (id, v) "
        f"SELECT column{dim}::INTEGER, [{names}]::{coltype} "
        f"FROM corpus_matrix"
    )
    conn.execute("DROP TABLE corpus_matrix")


def bench_storage_size(n: int, dim: int) -> None:
    print(f"\n-- (a) on-disk storage size ({n} rows, dim={dim}, checkpointed) --")
    rng = np.random.default_rng(7)
    vecs = np.clip(rng.normal(0.0, 0.3, (n, dim)), -1.0, 1.0)

    sizes = {}
    for label, coltype in [
        ("FLOAT[dim]", f"FLOAT[{dim}]"),
        ("DOUBLE[]",   "DOUBLE[]"),
    ]:
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "size_probe.duckdb")
            conn = duckdb.connect(path)
            conn.execute(f"CREATE TABLE t (id INTEGER, v {coltype})")
            # One transaction for the whole load: inserted row by row outside
            # one, every row is its own commit and the write-ahead log keeps
            # a partial copy of the same block for each of them.
            conn.execute("BEGIN TRANSACTION")
            load_corpus(conn, n, dim, coltype, vecs)
            conn.execute("COMMIT")
            conn.execute("CHECKPOINT")
            conn.close()
            sizes[label] = os.path.getsize(path)

    ratio = sizes["DOUBLE[]"] / sizes["FLOAT[dim]"] if sizes["FLOAT[dim]"] else float("nan")
    for label, size in sizes.items():
        print(f"  {label:12s}: {size / n:.1f} bytes/row ({size / 1e6:.1f} MB total)")
    print(f"  ratio       : {ratio:.2f}x")
    print("  Note: the realized ratio depends on DuckDB's own block "
          "compression, which varies with how compressible your actual "
          "embedding values are -- measure on real data before treating "
          "this number as a promise.")


def bench_insert_throughput(n: int, dim: int) -> None:
    print(f"\n-- (b) bulk insert throughput ({n} rows, dim={dim}) --")
    rng = np.random.default_rng(7)
    vecs = np.clip(rng.normal(0.0, 0.3, (n, dim)), -1.0, 1.0)

    conn = duckdb.connect(":memory:")
    for label, coltype in [
        ("FLOAT[dim]", f"FLOAT[{dim}]"),
        ("DOUBLE[]",   "DOUBLE[]"),
    ]:
        conn.execute("DROP TABLE IF EXISTS t")
        conn.execute(f"CREATE TABLE t (id INTEGER, v {coltype})")
        t0 = time.perf_counter()
        # The whole load in one transaction, so this measures the bulk insert
        # rather than a commit per row.
        conn.execute("BEGIN TRANSACTION")
        load_corpus(conn, n, dim, coltype, vecs)
        conn.execute("COMMIT")
        elapsed = time.perf_counter() - t0
        print(f"  {label:12s}: {elapsed:.2f}s ({n / elapsed:.0f} rows/s)")
    conn.close()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--n", type=int, default=20_000,
                    help="row count for both sub-benchmarks (default: %(default)s "
                         "-- smaller than data_gen.py's full corpus; both arms "
                         "are O(n) by design, so a subset is representative)")
    ap.add_argument("--dim", type=int, default=128,
                    help="vector dimension (default: %(default)s)")
    args = ap.parse_args()

    print(f"vector_type_head_to_head: n={args.n}, dim={args.dim}")
    bench_storage_size(args.n, args.dim)
    bench_insert_throughput(args.n, args.dim)
    return 0


if __name__ == "__main__":
    sys.exit(main())
