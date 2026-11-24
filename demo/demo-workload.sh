#!/usr/bin/env bash
# demo/demo-workload.sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# A production-shaped mixed workload against a local DuckDB deployment --
# concurrent simulated users, each issuing a realistic MIX of calls
# (mostly cheap search, occasionally expensive reasoning) sustained
# over real wall-clock time, with p50/p95/p99 latency per operation
# type at the end.
#
# This answers a different question than demo.sql/benchmark.sql do.
# Those prove the pipeline is CORRECT (right answer, one call at a
# time). This proves it HOLDS UP -- concurrent load, sustained
# duration, a realistic operation mix, not a single-shot demo. Neither
# one substitutes for the other.
#
# Shape note: all N simulated users share ONE process and one Python
# `duckdb` module, one Connection family against the same
# DatabaseInstance -- DuckDB files are single-writer at the OS level,
# so an N-process CLI shape cannot hold write access for the insert
# and vectorizer ops. The threads are still real concurrency: DuckDB
# interleaves them across its own connection pool, and the op mix /
# percentile report below are the same harness logic.
#
# Baseline hardware assumption: a self-hosted, air-gapped deployment on
# modest 2016+-era hardware with an 8-16GB GPU running the reasoning
# model locally (not a cloud GPU) -- reasoning/text-to-sql latency
# numbers from this script are only meaningful in that context. Point
# --http-url at real hardware in that class to get a real baseline;
# the number this script cannot manufacture for you is "is my hardware
# in that class" -- that's on you to confirm separately.
#
# Usage:
#   ./demo/demo-workload.sh
#   ./demo/demo-workload.sh --duration 300 --concurrency 10
#   ./demo/demo-workload.sh --reasoning-plugin /path/to/fractalsql-reasoning-http.so
#   ./demo/demo-workload.sh --http-url http://127.0.0.1:11434/v1 --model gpt-oss:20b
#
# --reasoning-plugin / --http-url / --model: configure the reasoning
# plugin and/or endpoint for this run (process-environment config, so
# the driver exports it once for the whole run). Nothing on disk is
# edited, so there is nothing to revert on exit. Without them,
# reason/text-to-sql/embed calls fail cleanly and get counted as
# failures in the summary, same as any other error under load would
# be -- this script does not hide that, it's a real signal about
# what's actually working right now.
#
# Env overrides:
#   WORKLOAD_DURATION      seconds per run (default 120)
#   WORKLOAD_CONCURRENCY   concurrent simulated users (default 5)
#   WORKLOAD_DB            throwaway DuckDB file (default:
#                          /tmp/fractalsql_demo_workload_<pid>.duckdb)
#   FSQL_EXT               extension path (default: newest
#                          dist/**/fractalsql.*.duckdb_extension built
#                          here)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

DURATION="${WORKLOAD_DURATION:-120}"
CONCURRENCY="${WORKLOAD_CONCURRENCY:-5}"
DB="${WORKLOAD_DB:-/tmp/fractalsql_demo_workload_$$.duckdb}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)         DURATION="$2"; shift ;;
    --concurrency)      CONCURRENCY="$2"; shift ;;
    --reasoning-plugin) REASONING_PLUGIN="$2"; shift ;;
    --http-url)         HTTP_URL="$2"; shift ;;
    --model)            MODEL="$2"; shift ;;
    -h|--help)
      sed -n '2,42p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# --------------------------------------------------------------------
# Extension path: the built artifact under dist/ (its name carries the
# pinned DuckDB version, so glob for it). --extension via FSQL_EXT
# overrides.
# --------------------------------------------------------------------
EXT="${FSQL_EXT:-}"
if [[ -z "$EXT" ]]; then
    EXT="$(ls -t dist/*/fractalsql.*.duckdb_extension dist/*.duckdb_extension 2>/dev/null | head -1 || true)"
fi
if [[ ! -e "$EXT" ]]; then
    echo "extension not found: $EXT (set FSQL_EXT or run the build first)" >&2
    exit 1
fi

if ! python3 -c 'import duckdb' >/dev/null 2>&1; then
    echo "python3 with the duckdb package is required (pip install duckdb)" >&2
    exit 1
fi

# Config reaches the reasoning plugin through its process environment
# (this build has no per-connection config function); the workload
# driver reads those same variables.
export WORKLOAD_DURATION="$DURATION" WORKLOAD_CONCURRENCY="$CONCURRENCY" \
       WORKLOAD_DB="$DB" FSQL_BT_EXT="$EXT"
[[ -n "${REASONING_PLUGIN:-}" ]] && export FRACTALSQL_REASONING_PLUGIN="$REASONING_PLUGIN"
[[ -n "${HTTP_URL:-}" ]]         && export FSQL_REASONING_HTTP_URL="$HTTP_URL"
[[ -n "${MODEL:-}" ]]            && export FSQL_REASONING_HTTP_MODEL="$MODEL"

Y="\033[33m"; Z="\033[0m"
log() { printf "%b\n" "$*"; return 0; }

log "Setting up workload schema (200 customers, ~1000 orders, 300 documents, 5000 vectors)..."

rm -f "$DB"

# --------------------------------------------------------------------
# The driver carries the whole harness: setup, seeds, workers, the
# vectorizer drain cadence, and the p50/p95/p99 aggregation. Written
# to a temp file so the worker threads import it as one module.
# --------------------------------------------------------------------
DRIVER="$PWD/.demoworkload_$$"

cat > "$DRIVER" <<'DRIVER_EOF'
#!/usr/bin/env python3
# demo-workload driver: seeded schema, op mix, worker/scheduler
# split and nearest-rank percentile report -- the reference harness
# for latency comparisons in this repo.
# Timing is measured around each call (the CLI has no .timer analog in
# this build), failures counted per op, nothing hidden.
import os, random, threading, time

import duckdb

DURATION = int(os.environ.get("WORKLOAD_DURATION", "120"))
CONCURRENCY = int(os.environ.get("WORKLOAD_CONCURRENCY", "5"))
DB = os.environ["WORKLOAD_DB"]
EXT = os.environ["FSQL_BT_EXT"]

random.seed(20260930)
lock = threading.Lock()
results = []          # (op, ok, latency_ms)
stop_at = time.time() + DURATION
next_doc_id = [1000]  # beyond seeded ids; scheduler/worker inserts

REASON_PROMPTS = [
    "summarize the current customer status distribution in one sentence",
    "what pattern, if any, is notable in recent order activity",
    "suggest one thing worth double-checking about billing data quality",
]
T2S_QUESTIONS = [
    "how many active customers are there?",
    "what is the total value of paid orders?",
    "which customers have refunded orders?",
    "how many orders were placed in the last 30 days?",
]
EMBED_TEXTS = [
    "a customer reported a billing discrepancy on their latest invoice",
    "quarterly infrastructure review shows stable database latency",
    "new release adds diverse retrieval to the search API",
]

con = duckdb.connect(DB, config={"allow_unsigned_extensions": "true"})
con.execute("LOAD '%s'" % EXT.replace("'", "''"))

# --- schema + seed shapes (200/1000/300/5000) ---
con.execute("CREATE TABLE wl_customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, status TEXT NOT NULL)")
con.execute("""INSERT INTO wl_customers (id, name, status)
    SELECT n, 'customer_' || n, CASE WHEN (n % 137) / 137.0 < 0.75 THEN 'active' ELSE 'churned' END
    FROM range(1, 201) t(n)""")
con.execute("""CREATE TABLE wl_orders (id INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES wl_customers(id),
    total_cents INTEGER NOT NULL, status TEXT NOT NULL, placed_at DATE NOT NULL)""")
con.execute("""INSERT INTO wl_orders
    SELECT n, 1 + (n * 71) % 200, 500 + (n * 353) % 20000,
           CASE WHEN (n % 101) / 101.0 < 0.2 THEN 'pending'
                WHEN (n % 101) / 101.0 < 0.8 THEN 'paid' ELSE 'refunded' END,
           today() - INTERVAL (( n % 90 ) * 26) HOUR
    FROM range(1, 1001) t(n)""")
con.execute("CREATE TABLE wl_documents (id INTEGER PRIMARY KEY, body TEXT NOT NULL, emb DOUBLE[])")
con.execute("""INSERT INTO wl_documents (id, body)
    SELECT n,
        CASE (n % 8)
            WHEN 0 THEN 'Quarterly infrastructure review: database latency remained within SLA across all regions.'
            WHEN 1 THEN 'Customer escalation notes: billing discrepancy resolved after reconciling the March invoice.'
            WHEN 2 THEN 'Release notes: the search API now supports diverse retrieval alongside nearest-neighbor lookup.'
            WHEN 3 THEN 'Incident postmortem: a connection pool exhaustion event was traced to a retry storm.'
            WHEN 4 THEN 'Onboarding guide: new team members should start with the architecture overview document.'
            WHEN 5 THEN 'Security review: rotated API credentials for all third-party integrations this cycle.'
            WHEN 6 THEN 'Product feedback summary: users requested clearer error messages on failed imports.'
            ELSE 'Capacity planning: projected storage growth suggests a review is needed within two quarters.'
        END || ' (doc ' || n || ')'
    FROM range(1, 301) t(n)""")
# 5000 x 128-dim vectors; deterministic per-(n,i) values so every run
# stresses the same corpus.
con.execute("""CREATE TABLE wl_vectors (id INTEGER PRIMARY KEY, emb DOUBLE[])""")
con.execute("""INSERT INTO wl_vectors
    SELECT n, list(round(sin((n * (k.i * 7 + 3)) * 0.0137), 4))
    FROM range(1, 5001) v(n), range(1, 129) k(i)
    GROUP BY n""")
# A fixed 128-dim query point kept for the scouts and snipers (per-call
# random points would measure list construction, not search).
SCOUT_OPTS = '{"population_size": 20, "iterations": 8, "walk": 0}'
SCOUT_QUERY = con.execute(
    "SELECT list(round(random(), 4)) FROM range(128)").fetchone()[0]
scout_sql = "SELECT * FROM fractal_search_explore('wl_vectors', 'emb', %s, %s)" % (
    repr(list(SCOUT_QUERY)), repr(SCOUT_OPTS))
sniper_sql = "SELECT fractal_sfs_converge(%s, 30, 30, 2)" % repr(list(SCOUT_QUERY))

# --- vectorizer: one registered vectorizer, drained before the run ---
vz_id = con.execute(
    "SELECT fractal_vectorizer_create('wl_documents', 'id', 'body', 'emb')").fetchone()[0]
con.execute("SELECT fractal_vectorizer_process_queue(500)")
print("registered vectorizer id %d (backfill complete)" % vz_id)

def timed(op, sql, params=None):
    c = con.cursor()
    t0 = time.perf_counter()
    try:
        rows = c.execute(sql, params or []).fetchall()
        ms = (time.perf_counter() - t0) * 1000.0
        with lock:
            results.append((op, rows is not None, ms))
    except Exception:
        with lock:
            results.append((op, False, (time.perf_counter() - t0) * 1000.0))
    finally:
        c.close()
    return None

def run_worker(wid):
    while time.time() < stop_at:
        r = random.randint(0, 99)
        if r < 40:
            op = "sniper"
            timed(op, sniper_sql)
        elif r < 55:
            op = "scout"
            timed(op, scout_sql)
        elif r < 70:
            op = "embed"
            timed(op, "SELECT fractal_embed(?)",
                  [EMBED_TEXTS[random.randint(0, len(EMBED_TEXTS) - 1)]])
        elif r < 80:
            op = "insert"
            with lock:
                next_doc_id[0] += 1
                doc_id = next_doc_id[0]
            timed(op,
                  "INSERT INTO wl_documents (id, body) VALUES (?, ?)",
                  [doc_id, "workload-generated note from worker %d at %d" % (wid, int(time.time()))])
        elif r < 90:
            op = "t2s"
            timed(op, "SELECT fractal_text_to_sql(?)",
                  [T2S_QUESTIONS[random.randint(0, len(T2S_QUESTIONS) - 1)]])
        else:
            op = "reason"
            timed(op, "SELECT fractal_reason(?)",
                  [REASON_PROMPTS[random.randint(0, len(REASON_PROMPTS) - 1)]])

def run_scheduler():
    # The vectorizer queue is persistent state here, so the scheduler
    # only ingests new documents and drains on a fixed cadence -- the
    # standard cron stand-in (see docs/vectorizer-setup.md).
    while time.time() < stop_at:
        time.sleep(5)
        with lock:
            next_doc_id[0] += 1
            doc_id = next_doc_id[0]
        timed("sched",
              "INSERT INTO wl_documents (id, body) VALUES (?, ?)",
              [doc_id, "scheduler-ingested note at %d" % int(time.time())])
        timed("sched", "SELECT fractal_vectorizer_process_queue(50)")

threads = []
for w in range(1, CONCURRENCY + 1):
    threads.append(threading.Thread(target=run_worker, args=(w,)))
threads.append(threading.Thread(target=run_scheduler))
for t in threads:
    t.start()
for t in threads:
    t.join()

# --- aggregate: nearest-rank percentiles, per op ---
def percentile(sorted_vals, p):
    n = len(sorted_vals)
    if n == 0:
        return "-"
    idx = max(1, (p * n + 99) // 100)
    idx = min(idx, n)
    return sorted_vals[idx - 1]

print("================================================================")
print("Results (%d workers x %ds)" % (CONCURRENCY, DURATION))
print("================================================================")
print("%-8s %8s %8s %10s %10s %10s" % ("op", "calls", "failed", "p50 ms", "p95 ms", "p99 ms"))
total_calls = total_failed = 0
for op in ("sniper", "scout", "embed", "insert", "t2s", "reason"):
    rows = [x for x in results if x[0] == op]
    if not rows:
        continue
    ok_ms = sorted(x[2] for x in rows if x[1])
    n = len(rows)
    nf = sum(1 for x in rows if not x[1])
    print("%-8s %8d %8d %10s %10s %10s" % (
        op, n, nf, percentile(ok_ms, 50), percentile(ok_ms, 95), percentile(ok_ms, 99)))
    total_calls += n
    total_failed += nf
print()
print("Total: %d calls, %d failed, %d calls/sec aggregate throughput" % (
    total_calls, total_failed, total_calls // DURATION))
if total_failed == 0:
    print("No failures under this load.")
else:
    print("%d calls failed -- if reasoning wasn't configured, that's expected" % total_failed)
    print("for reason/text-to-sql/embed; anything else is a real problem worth digging into.")
print("================================================================")
DRIVER_EOF

python3 "$DRIVER"

rc=$?
rm -f "$DRIVER"
if [[ "$rc" -ne 0 ]]; then
    log "${Y}workload driver exited with an error ($rc) -- see the trace above${Z}"
    exit "$rc"
fi
log "Workload DB left in place at $DB for inspection; remove it when done."