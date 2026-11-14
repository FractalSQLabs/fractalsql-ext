#!/usr/bin/env bash
# bench/scale_sweep.sh -- HNSW (vss) vs FractalSQL Scout at a range of
# small-to-medium corpus sizes, both on the DOUBLE[] column (emb_arr) and
# the FLOAT[dim] column (emb_fv), dim=128 fixed.
#
# Regenerates bench_vectors at each N via data_gen.py --with-fractal-vector,
# then runs head_to_head.py --quiet twice per N (once per storage column).
# Prints one line per (N, column) combination so the whole sweep reads as
# a single table you can eyeball for the latency/recall crossover trend.
#
# Usage:
#   bench/scale_sweep.sh [db-file]
#
# db-file defaults to fractalsql_bench.duckdb, same as the other
# bench/ scripts.

set -euo pipefail

DB="${1:-fractalsql_bench.duckdb}"
DIM=128
SIZES=(500 1000 2000 5000 20000 50000)

cd "$(dirname "$0")/.."

for n in "${SIZES[@]}"; do
  echo "=== n=$n dim=$DIM ===" >&2
  python3 bench/data_gen.py --db "$DB" --n "$n" --dim "$DIM" \
      --with-fractal-vector >&2
  python3 bench/head_to_head.py --db "$DB" --quiet --vector-col emb_arr
  python3 bench/head_to_head.py --db "$DB" --quiet --vector-col emb_fv
done
