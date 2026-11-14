#!/usr/bin/env bash
# demo/run_demo.sh
#
# Runs every demo/*.sql content demo inside the DuckDB demo container, in
# one pass: the "docker compose up -d; pull a model; run_demo.sh" button
# for a from-scratch look at everything in demo/, instead of running each
# file by hand or pasting one LOAD line per file.
#
# Usage (inside the demo container, matching docs/docker-demo.md's
# `docker compose exec` invocation style):
#   docker compose exec demo /demo/run_demo.sh
#   docker compose exec demo /demo/run_demo.sh --quiet
#   docker compose exec demo /demo/run_demo.sh --only demo-vertical-fleet-logistics.sql
#   docker compose exec demo /demo/run_demo.sh --skip demo-agents.sql,enterprise-stress.sql
#   docker compose exec demo /demo/run_demo.sh --include-response-modes
#
# Scope: this is specifically the demo image's workflow (docker/
# Dockerfile.demo). It assumes /opt/fractalsql/init.sql exists there (the
# image writes it: it LOADs iceberg, ducklake, then the extension file)
# and /demo/*.sql (the demo/ directory is mounted read-only at /demo).
# A bare host install has no /opt/fractalsql: point FSQL_DEMO_INIT at an
# init file whose only job is the LOAD of the built extension, or run
# demos manually per each file's own header.
#
# TWO THINGS THIS SCRIPT DOES THAT THE FILES THEMSELVES CANNOT:
#
# 1. ONE DATABASE FOR THE WHOLE PASS. Several demos are cross-file by
#    design: response-modes.sql reads the demo_alerts table demo.sql
#    creates, and text-to-sql-spike-2/3/4 read the spike_candidates
#    table text-to-sql-spike-1-generate.sql creates. A fresh transient
#    database per file breaks those links, so the pass runs against one
#    database file, removed at the start of the pass so every run starts
#    from the same clean state. Override with FSQL_DEMO_DB.
#
# 2. A WRITABLE WORKING DIRECTORY. The demos spool generated SQL through
#    the .output/.read idiom, which writes into the CURRENT DIRECTORY --
#    and the demo directory is a read-only mount in the container
#    (./demo:/demo:ro). The pass therefore runs each file from a
#    writable work directory, passing the demo file by absolute path.
#    The spooled files are left there for inspection. Override with
#    FSQL_DEMO_WORK_DIR.
#
# Reasoning-dependent sections need a model pulled first (docs/docker-
# demo.md step 2); without one, those calls fail with a clean
# model-not-found error and this script counts that file as a non-zero
# exit result, same as any other failure -- it does not special-case or
# hide that (same stance demo-workload.sh's own header takes).
#
# FOUR FILES RUN WITHOUT -bail AND ARE JUDGED BY THEIR ERROR COUNT:
# demo-agents.sql, enterprise-qtl-audit.sql, enterprise-stress.sql and
# demo-vertical-periodicity-portfolio-selection.sql call
# enterprise-tier-gated functions, which print the documented activation
# error when no enterprise library is configured. With -bail the shell
# would stop at that first error and the rest of the file would never
# run -- so these four run WITHOUT it: the shell carries on, the file
# finishes, and the runner then asserts the log's error count against
# the expected number (expected_error_count below). A new, unexpected
# error therefore fails the file instead of hiding behind the first
# one. Every other file still runs with -bail, so its first error stops
# it and a non-zero exit IS a failure.
#
# The expected counts are for a COMMUNITY build. With an enterprise
# library configured (FRACTALSQL_ENTERPRISE_LIB set in the environment)
# the gated calls succeed instead of printing the activation error, and
# those four files expect 0.
#
# demo/response-modes.sql is SKIPPED BY DEFAULT: unlike every other file
# here, it is explicitly NOT meant to run in one pass --
# FSQL_REASONING_HTTP_RESPONSE_MODE is an env-var-only setting read once
# at plugin init, so switching modes needs a process restart with a new
# environment, not just a new SQL statement (see the file's own header).
# Running it through the main loop anyway would silently produce a
# misleading failure for the json-mode section, since neither code nor
# json mode would actually be engaged. Pass --include-response-modes to
# exercise it properly instead: each of its three modes then runs as a
# SEPARATE process with the matching env var set, mirroring what the
# file's header instructs a human to do by hand. That logic duplicates
# response-modes.sql's three SELECT statements inline below (same SQL,
# not a re-read of the file) -- keep both in sync if that file's SQL
# changes.
#
# CHECKPOINTS. The pass runs every file against ONE database file, one process per file. A process
# that exits with a write-ahead log still pending leaves it for the next one to replay, and DuckDB
# 1.4.x and 1.5.x cannot replay the log of the foreign-key / COMMENT ON schema that
# demo-text-to-sql.sql creates -- the next file then fails to open the database. Each process is
# therefore started with checkpoint_threshold at 1KB, so every commit is checkpointed and nothing is
# left to replay. FSQL_DEMO_CHECKPOINT_THRESHOLD overrides the value; set it to the empty string to
# leave DuckDB's own default (16MB) in place.
#
# demo/demo-workload.sh is NOT part of this: that is a separate
# concurrent load/stress tool (p50/p95/p99 latency under sustained
# load), not a content demo -- see its own header.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT="${FSQL_DEMO_INIT:-/opt/fractalsql/init.sql}"
DUCKDB="${DUCKDB_BIN:-duckdb}"
LOG_DIR="${FSQL_DEMO_RUN_LOG_DIR:-/tmp/fractalsql_demo_run}"
TIMEOUT_SECS="${FSQL_DEMO_RUN_TIMEOUT:-300}"
CKPT="${FSQL_DEMO_CHECKPOINT_THRESHOLD-1KB}"
# Every process starts with this (see CHECKPOINTS in the header).
PRE=()
[[ -n "$CKPT" ]] && PRE=(-cmd "SET checkpoint_threshold='${CKPT}';")

# One database for the whole pass, and a writable working directory for
# the demos' .output/.read spool files -- see the header for why both.
WORK_DIR="${FSQL_DEMO_WORK_DIR:-${LOG_DIR}/work}"
DB="${FSQL_DEMO_DB:-${WORK_DIR}/fractalsql_demo.db}"

QUIET=0
ONLY=""
SKIP=""
INCLUDE_RESPONSE_MODES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet)                  QUIET=1 ;;
    --only)                   ONLY="$2"; shift ;;
    --skip)                   SKIP="$2"; shift ;;
    --include-response-modes) INCLUDE_RESPONSE_MODES=1 ;;
    -h|--help)
      sed -n '2,84p' "$0"; exit 0 ;;
    *) echo "run_demo.sh: unknown arg: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

if [[ ! -f "$INIT" ]]; then
  echo "run_demo.sh: expected an init file at $INIT whose job is to LOAD" >&2
  echo "the extension (the demo image ships it at /opt/fractalsql/init.sql)." >&2
  echo "Run this inside the demo container -- docker compose exec demo" >&2
  echo "/demo/run_demo.sh -- or point FSQL_DEMO_INIT at your own init file." >&2
  exit 2
fi

if command -v timeout >/dev/null 2>&1; then
  run_timeout() { timeout "$TIMEOUT_SECS" "$@"; }
else
  run_timeout() { "$@"; }
fi

mkdir -p "$LOG_DIR" "$WORK_DIR"
# Absolute paths from here on: the per-file run happens with the working
# directory changed to $WORK_DIR, so a relative $LOG_DIR would write the
# logs (and the redirections inside the subshell) to the wrong place.
LOG_DIR="$(cd "$LOG_DIR" && pwd)"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
# Resolve the database path against THIS script's directory (the demos
# are addressed the same way), so it does not matter that the per-file
# run happens from $WORK_DIR.
case "$DB" in
  /*) ;;
  *) DB="$(pwd)/$DB" ;;
esac

# Start every pass from the same clean state: the database file is
# removed, and the spool files from a previous pass are cleared out of
# the work directory so a stale .sql file can never be .read in place of
# a freshly spooled one.
rm -f "$DB" "$DB.wal" "$DB.tmp"
find "$WORK_DIR" -maxdepth 1 -type f -name '*.sql' -delete 2>/dev/null || true

# response-modes.sql is handled separately below, never through the
# main loop (see this script's own header for why).
ALWAYS_SKIP="response-modes.sql"

IFS=',' read -r -a only_list <<< "$ONLY"
IFS=',' read -r -a skip_list <<< "$SKIP"

should_run() {
  local base="$1"
  [[ "$base" == "$ALWAYS_SKIP" ]] && return 1
  if [[ -n "$ONLY" ]]; then
    for o in "${only_list[@]}"; do [[ "$base" == "$o" ]] && return 0; done
    return 1
  fi
  for s in "${skip_list[@]}"; do [[ -n "$s" && "$base" == "$s" ]] && return 1; done
  return 0
}

pass=0
fail=0
failed_files=()

# How many error lines a file's log must contain, on a COMMUNITY build
# (no enterprise library configured). The four enterprise-gated demos
# print the documented activation error once per gated call; every other
# file is expected to be error-free. With FRACTALSQL_ENTERPRISE_LIB set,
# the gated calls succeed and those four files expect 0.
expected_error_count() {
  local base="$1"
  if [[ -n "${FRACTALSQL_ENTERPRISE_LIB:-}" ]]; then
    case "$base" in
      demo-agents.sql|enterprise-qtl-audit.sql|enterprise-stress.sql|\
      demo-vertical-periodicity-portfolio-selection.sql) echo 0; return ;;
    esac
  fi
  case "$base" in
    demo-agents.sql)                                   echo 2 ;;
    enterprise-qtl-audit.sql)                          echo 11 ;;
    enterprise-stress.sql)                             echo 27 ;;
    demo-vertical-periodicity-portfolio-selection.sql) echo 1 ;;
    *)                                                  echo 0 ;;
  esac
}

# Errors reach the log in two shapes: the extension's own failures print
# a one-line JSON object ({"exception_type":...}), and the shell's own
# failures print a "<Kind> Error: ..." line. Both are counted, so an
# unexpected failure of either kind is caught.
count_errors() {
  local n
  n="$(grep -c -E '^\{"exception_type"|^[A-Za-z][A-Za-z ]*Error:' "$1" 2>/dev/null || true)"
  echo "${n:-0}"
}

for sqlfile in "$HERE"/*.sql; do
  base="$(basename "$sqlfile")"
  should_run "$base" || continue
  [[ "$QUIET" -eq 1 ]] || echo "=== $base ==="
  log="$LOG_DIR/$base.log"
  expected="$(expected_error_count "$base")"
  if [[ "$expected" -gt 0 ]]; then
    # No -bail here: an intentional activation error must not stop the
    # file, and the error count is what decides pass/fail.
    ( cd "$WORK_DIR" && run_timeout "$DUCKDB" -unsigned ${PRE[@]+"${PRE[@]}"} -init "$INIT" \
           "$DB" < "$sqlfile" > "$log" 2>&1 )
    got="$(count_errors "$log")"
    if [[ "$got" -eq "$expected" ]]; then
      pass=$((pass + 1))
      [[ "$QUIET" -eq 1 ]] || echo "  ok ($log, $got expected error(s))"
    else
      fail=$((fail + 1))
      failed_files+=("$base")
      [[ "$QUIET" -eq 1 ]] || echo "  expected $expected error(s), got $got -- see $log"
    fi
  elif ( cd "$WORK_DIR" && run_timeout "$DUCKDB" -unsigned -bail ${PRE[@]+"${PRE[@]}"} -init "$INIT" \
         "$DB" < "$sqlfile" > "$log" 2>&1 )
  then
    pass=$((pass + 1))
    [[ "$QUIET" -eq 1 ]] || echo "  ok ($log)"
  else
    fail=$((fail + 1))
    failed_files+=("$base")
    [[ "$QUIET" -eq 1 ]] || echo "  exit != 0 -- see $log"
  fi
done

if [[ "$INCLUDE_RESPONSE_MODES" -eq 1 ]]; then
  [[ "$QUIET" -eq 1 ]] || echo "=== response-modes.sql (text/code/json, each its own process + env) ==="
  for mode in text code json; do
    log="$LOG_DIR/response-modes.$mode.log"
    case "$mode" in
      text)
        # Same SQL as response-modes.sql's MODE: text section -- keep in
        # sync with that file if it changes.
        sql="SELECT fractal_reason('summarize what happened in demo_alerts in one sentence', (SELECT list(t)::text FROM (SELECT service, message, severity, created_at FROM demo_alerts) t));"
        ;;
      code)
        sql="SELECT fractal_reason('write a SQL query that selects all rows from demo_alerts where severity is critical');"
        ;;
      json)
        sql="SELECT fractal_reason('return a JSON object with keys critical_count, warning_count, and info_count summarizing the severities present', (SELECT list(t)::text FROM (SELECT severity FROM demo_alerts) t));"
        ;;
    esac
    if ( cd "$WORK_DIR" && printf '%s\n' "$sql" | \
         FSQL_REASONING_HTTP_RESPONSE_MODE="$mode" \
         run_timeout "$DUCKDB" -unsigned -bail ${PRE[@]+"${PRE[@]}"} -init "$INIT" "$DB" > "$log" 2>&1 )
    then
      pass=$((pass + 1))
      [[ "$QUIET" -eq 1 ]] || echo "  $mode: ok ($log)"
    else
      fail=$((fail + 1))
      failed_files+=("response-modes.sql:$mode")
      [[ "$QUIET" -eq 1 ]] || echo "  $mode: exit != 0 -- see $log"
    fi
  done
elif [[ "$QUIET" -eq 1 ]]; then
  :
else
  echo "(skipped response-modes.sql -- needs demo_alerts from demo.sql plus a"
  echo " per-mode process restart; pass --include-response-modes to run it"
  echo " properly, or see the file's own header to run it by hand)"
fi

echo
echo "=== $pass ok, $fail failed, logs in $LOG_DIR ==="
if [[ "$fail" -gt 0 ]]; then
  echo "Failed files (read the log before assuming a bug -- see this script's"
  echo "own header for the files that error by design):"
  printf '  %s\n' "${failed_files[@]}"
fi

exit 0