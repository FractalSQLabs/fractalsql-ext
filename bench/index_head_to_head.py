#!/usr/bin/env python3
"""
bench/index_head_to_head.py -- the native IVF index against the exact scan.

Metrics
    Latency        Wall time per search, milliseconds: the indexed search and the exact scan
                   (fractal_search with "use_index": false) over the same corpus.
    Recall         The fraction of the exact top-k the indexed search returns.
    Rows scanned   What the index actually read, from fractal_index_info's last_search block.
                   The point of the benchmark: an index that silently fell back to a flat scan
                   reads as many rows as the table holds, and this script says so.

Fairness
    The same corpus, the same query vectors and the same k for both sides. The index is built
    once, before the timings, and the calibration has already chosen its nprobe. The exact
    scan is the ground truth: it is the same double-precision cosine over the same rows.

Usage:
    python3 bench/index_head_to_head.py --db fractalsql_bench.duckdb \
        --table corpus --vector-col v --rows 20000 --dim 64 --queries 20 --k 10
"""
import argparse
import glob
import json
import os
import sys
import time

try:
    import duckdb
except ImportError:                                    # pragma: no cover
    print("bench/index_head_to_head.py: the duckdb python module is required", file=sys.stderr)
    sys.exit(2)


def find_extension(explicit):
    if explicit:
        return explicit
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    plat = "windows_amd64" if sys.platform == "win32" else ("osx_arm64" if sys.platform == "darwin" else "linux_amd64")
    hits = []
    for pat in (os.path.join(here, "dist", "**", "fractalsql.capi.*.duckdb_extension"),
                os.path.join(here, "dist", "**", "fractalsql.*.duckdb_extension")):
        hits += [f for f in glob.glob(pat, recursive=True) if "-legacy" not in f]
    # the build for THIS platform, if there is one; otherwise the first
    for h in hits:
        if plat in os.path.basename(h) and os.path.basename(os.path.dirname(h)) == plat:
            return h
    for h in hits:
        if plat in os.path.basename(h):
            return h
    return hits[0] if hits else None


def connect(db, ext):
    con = duckdb.connect(db, config={"allow_unsigned_extensions": "true"})
    con.execute("LOAD '%s'" % ext.replace("\\", "/"))
    return con


def timed(con, sql, params):
    t0 = time.perf_counter()
    rows = con.execute(sql, params).fetchall()
    return (time.perf_counter() - t0) * 1000.0, rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", default=":memory:", help="the DuckDB database file")
    ap.add_argument("--extension", default=None, help="the extension to load")
    ap.add_argument("--table", default="bench_corpus", help="the corpus table")
    ap.add_argument("--vector-col", default="v", help="the column holding the vectors")
    ap.add_argument("--id-col", default="id", help="the column holding the stable row id")
    ap.add_argument("--rows", type=int, default=20000, help="how many rows to generate")
    ap.add_argument("--dim", type=int, default=64, help="the dimension")
    ap.add_argument("--queries", type=int, default=20, help="how many query vectors")
    ap.add_argument("--k", type=int, default=10, help="how many neighbours")
    ap.add_argument("--nlist", type=int, default=64, help="the number of index cells")
    ap.add_argument("--format", default="FP32", help="the vector format (INT8, INT4, FP16, FP32)")
    ap.add_argument("--json", default=None, help="write the results as JSON to this file")
    args = ap.parse_args()

    ext = find_extension(args.extension)
    if not ext:
        print("bench/index_head_to_head.py: no extension found (build it first)", file=sys.stderr)
        return 2
    con = connect(args.db, ext)

    # the corpus: deterministic, clustered (so an index has something to find)
    con.execute("DROP TABLE IF EXISTS %s" % args.table)
    con.execute("CREATE TABLE %s (%s INTEGER PRIMARY KEY, v DOUBLE[])" % (args.table, args.id_col))
    # the corpus is CLUSTERED: 32 centres, each row a small offset of one of them. A clustered
    # corpus is what an IVF index is for -- a smooth manifold would be split across cell
    # boundaries and the recall would say more about the corpus than about the index.
    con.execute(
        "INSERT INTO %s SELECT i, list_transform(range(0, %d), lambda j: "
        "  sin((i %% 32) * 1.7 + j * 0.9) + ((i // 32) %% 100 - 50) / 100000.0) "
        "FROM range(1, %d) t(i)" % (args.table, args.dim, args.rows + 1))
    total = con.execute("SELECT count(*) FROM %s" % args.table).fetchone()[0]

    # the query vectors: rows of the corpus, so the exact top-k is known
    queries = con.execute("SELECT v FROM %s LIMIT %d" % (args.table, args.queries)).fetchall()

    index_name = args.table + "_idx"
    con.execute("DROP INDEX IF EXISTS %s" % index_name) if False else None
    built = con.execute(
        "SELECT fractal_index_create(?, ?, ?)",
        [args.table, args.vector_col, json.dumps({"name": index_name, "nlist": args.nlist,
                                                  "vector_format": args.format, "target_recall": 0.95})]).fetchone()[0]

    exact_sql = "SELECT doc_id::BIGINT AS id, distance FROM fractal_search(?, ?, ?::DOUBLE[], ?, '{\"use_index\":false}')"
    index_sql = "SELECT doc_id::BIGINT AS id, distance FROM fractal_search(?, ?, ?::DOUBLE[], ?, '{}')"

    idx_ms = exact_ms = 0.0
    recall_sum = 0.0
    scanned = 0
    for (q,) in queries:
        t, exact_rows = timed(con, exact_sql, [args.table, args.vector_col, q, args.k])
        exact_ms += t
        t, index_rows = timed(con, index_sql, [args.table, args.vector_col, q, args.k])
        idx_ms += t
        want = {r[0] for r in exact_rows}
        got = {r[0] for r in index_rows}
        if want:
            recall_sum += len(want & got) / float(len(want))
    info = json.loads(con.execute("SELECT fractal_index_info(?)", [index_name]).fetchone()[0])
    scanned = int(info.get("last_search", {}).get("rows_scanned", 0))

    n = max(1, len(queries))
    out = {
        "rows": total,
        "dim": args.dim,
        "k": args.k,
        "queries": len(queries),
        "indexed_ms": round(idx_ms / n, 3),
        "exact_ms": round(exact_ms / n, 3),
        "speedup": round(exact_ms / idx_ms, 2) if idx_ms else None,
        "recall": round(recall_sum / n, 4),
        "rows_scanned_by_the_index": scanned,
        "rows_scanned_fraction": round(scanned / float(total), 4) if total else None,
        "index": json.loads(built),
    }
    print(json.dumps(out, indent=2))
    if out["rows_scanned_fraction"] is not None and out["rows_scanned_fraction"] > 0.5:
        print("bench/index_head_to_head.py: WARNING the index read most of the table -- "
              "it is not really being used", file=sys.stderr)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(out, fh, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
