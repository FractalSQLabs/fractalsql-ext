#!/usr/bin/env python3
"""
bench/data_gen.py -- Generate the synthetic "Island" dataset for the
head-to-head benchmark.

Creates N points in d dimensions, organized into K Gaussian clusters.
Cluster centers are placed uniformly in [-1, 1]^d; each point is sampled
from a Gaussian around its assigned center with per-component std=sigma.
Values are clipped to [-1, 1] so they fall within FractalSQL's default
search bounds.

Writes two tables:
    bench_vectors (id int, cluster_id int, emb FLOAT[d], emb_arr DOUBLE[]
                   [, emb_fv FLOAT[d] if --with-fractal-vector])
    bench_centers (cluster_id int, center_arr DOUBLE[])

--with-fractal-vector adds an emb_fv FLOAT[d] column, populated from the
SAME underlying values as emb_arr (modulo the deliberate float8->float4
narrowing) -- one corpus backing a fair storage/latency comparison in
bench/vector_type_head_to_head.py. Default off so the existing
head_to_head.py (HNSW-vs-Scout) run is unaffected.

Builds an HNSW index (via DuckDB's `vss` extension) on bench_vectors.emb
for the HNSW comparison arm of the benchmark. `emb` is a fixed-size
ARRAY (`FLOAT[d]`) because vss's index only attaches to fixed-size array
columns; `emb_arr` stays a variable-length LIST (`DOUBLE[]`), the shape
fractal_sfs_converge/fractal_search_explore consume.

Usage:
    python3 bench/data_gen.py --db fractalsql_bench.duckdb \\
        --n 100000 --dim 768 --clusters 50
"""

import argparse
import os
import sys
import time

import duckdb
import numpy as np


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", default="fractalsql_bench.duckdb",
                    help="DuckDB database file (default: %(default)s)")
    ap.add_argument("--n", type=int, default=100_000,
                    help="number of points (default: %(default)s)")
    ap.add_argument("--dim", type=int, default=128,
                    help="vector dimension (default: %(default)s). Use --dim 768 "
                         "for realistic-embedding scale; note that HNSW index "
                         "build time and SFS fitness cost both scale linearly "
                         "with dim.")
    ap.add_argument("--clusters", type=int, default=50,
                    help="number of Gaussian clusters (default: %(default)s)")
    ap.add_argument("--sigma", type=float, default=0.05,
                    help="per-component std of intra-cluster noise "
                         "(default: %(default)s)")
    ap.add_argument("--with-fractal-vector", action="store_true",
                    help="also add an emb_fv FLOAT[dim] column, "
                         "for bench/vector_type_head_to_head.py "
                         "(default: off, keeps the existing HNSW-vs-Scout "
                         "head_to_head.py run unaffected)")
    ap.add_argument("--seed", type=int, default=42,
                    help="RNG seed (default: %(default)s)")
    args = ap.parse_args()

    # --db arrives as raw CLI text and is used both as a filesystem path
    # and as a database filename, so pin it to the current working
    # directory (symlinks resolved via realpath) before anything touches
    # it. A traversal-style argument can then neither redirect where the
    # database is written nor where it is opened.
    root = os.path.realpath(os.getcwd())
    db = os.path.realpath(args.db)
    try:
        contained = os.path.commonpath([root, db]) == root
    except ValueError:  # different drives on Windows
        contained = False
    if not contained:
        print(f"data_gen.py: --db must resolve inside {root} "
              f"(got: {args.db})", file=sys.stderr)
        return 2

    # Numeric re-cast at the point of use: --dim is CLI-supplied text that
    # feeds the f-string DDL below, and an explicit int at the use site is
    # what guarantees the interpolated piece is a number, not an
    # identifier.
    dim = int(args.dim)

    rng = np.random.default_rng(args.seed)

    print(f"Generating {args.n} points in R^{dim}, "
          f"{args.clusters} clusters, sigma={args.sigma}")
    t0 = time.perf_counter()

    # Cluster centers in [-1, 1]^dim.
    centers = rng.uniform(-1.0, 1.0, (args.clusters, dim))

    # Assign each point to a cluster, generate coords around the center,
    # and clip to the search box.
    labels  = rng.integers(0, args.clusters, size=args.n)
    noise   = rng.normal(0.0, args.sigma, (args.n, dim))
    vectors = np.clip(centers[labels] + noise, -1.0, 1.0)

    print(f"  generated in {time.perf_counter() - t0:.1f}s "
          f"({vectors.nbytes / 1e6:.1f} MB)")

    # ---- load into DuckDB -----------------------------------------------
    print(f"Connecting to {args.db} ...")
    conn = duckdb.connect(db)
    conn.execute("INSTALL vss")
    conn.execute("LOAD vss")
    # vss's HNSW index only persists to an on-disk database with this
    # flag set (still marked experimental upstream); harmless for
    # :memory: databases, where nothing is persisted anyway.
    conn.execute("SET hnsw_enable_experimental_persistence = true")

    fv_col = ", emb_fv FLOAT[%d] NOT NULL" % dim if args.with_fractal_vector else ""

    conn.execute("DROP TABLE IF EXISTS bench_vectors")
    conn.execute("DROP TABLE IF EXISTS bench_centers")
    conn.execute(f"""
        CREATE TABLE bench_vectors (
            id         INTEGER PRIMARY KEY,
            cluster_id INTEGER NOT NULL,
            emb        FLOAT[{dim}] NOT NULL,
            emb_arr    DOUBLE[]  NOT NULL{fv_col}
        )
    """)
    conn.execute("""
        CREATE TABLE bench_centers (
            cluster_id INTEGER PRIMARY KEY,
            center_arr DOUBLE[] NOT NULL
        )
    """)

    print(f"  inserting {args.clusters} cluster centers ...")
    conn.execute("BEGIN TRANSACTION")
    conn.executemany(
        "INSERT INTO bench_centers VALUES (?, ?)",
        [(i, centers[i].tolist()) for i in range(args.clusters)])
    conn.execute("COMMIT")

    print(f"  bulk-loading {args.n} vectors ...")
    t0 = time.perf_counter()
    # The corpus is handed to DuckDB as a matrix of columns rather than row
    # by row: the driver reads the whole array in one step and the list
    # columns are built in SQL. The values are the same ones a row-at-a-time
    # load wrote - the float32 columns are the float64 ones rounded to
    # float32 - so one corpus still backs a fair comparison in
    # vector_type_head_to_head.py.
    #
    # The matrix carries the row id and the cluster id alongside the
    # coordinates, so nothing depends on the order the rows come back in.
    matrix = np.empty((args.n, dim + 2), dtype=np.float64)
    matrix[:, :dim]  = vectors
    matrix[:, dim]   = labels
    matrix[:, dim + 1] = np.arange(args.n)

    # DuckDB reads a numpy array as one column per row of the matrix, so
    # the transpose is what puts the dimensions in columns.
    corpus = np.asfortranarray(matrix.T)
    conn.execute("CREATE TEMP TABLE bench_matrix AS SELECT * FROM corpus")

    names = ", ".join(f"column{i}" for i in range(dim))
    fv = f", [{names}]::FLOAT[{dim}]" if args.with_fractal_vector else ""
    cols = "(id, cluster_id, emb, emb_arr, emb_fv)" if args.with_fractal_vector \
        else "(id, cluster_id, emb, emb_arr)"
    # The whole load is one transaction. Inserted outside a transaction, every
    # row is its own commit, and the write-ahead log then keeps a partial copy
    # of the same block for each of them - which made a 100k-row load write
    # more than a hundred times the size of the data it was loading.
    conn.execute("BEGIN TRANSACTION")
    conn.execute(f"""
        INSERT INTO bench_vectors {cols}
        SELECT column{dim + 1}::INTEGER,
               column{dim}::INTEGER,
               [{names}]::FLOAT[{dim}],
               [{names}]::DOUBLE[]{fv}
        FROM bench_matrix
    """)
    conn.execute("COMMIT")
    conn.execute("DROP TABLE bench_matrix")
    print(f"    load done in {time.perf_counter() - t0:.1f}s")

    print("  building HNSW index on emb ...")
    t0 = time.perf_counter()
    # Tuned down from vss defaults (M=16, ef_construction=64) to keep demo
    # build time reasonable at 100k rows. Production deployments should
    # tune up for better recall quality.
    conn.execute("""
        CREATE INDEX bench_emb_hnsw ON bench_vectors
        USING HNSW (emb) WITH (metric = 'l2sq', ef_construction = 32, M = 8)
    """)
    print(f"    index built in {time.perf_counter() - t0:.1f}s")

    n = conn.execute("SELECT count(*) FROM bench_vectors").fetchone()[0]
    k = conn.execute("SELECT count(*) FROM bench_centers").fetchone()[0]
    print(f"\nDone. bench_vectors={n} rows, bench_centers={k} rows")

    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
