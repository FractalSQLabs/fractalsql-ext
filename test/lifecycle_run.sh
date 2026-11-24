#!/usr/bin/env bash
# test/lifecycle_run.sh -- can a file database that has the extension loaded be closed and reopened
# like any other? Builds test/lifecycle_test.c against libduckdb for each DuckDB line and runs it in the
# modes that must be clean (release, nopool, race), plus `plain` for the nested-query functions.
#
# The extension keeps connections open to run SQL on the caller's database, and a live connection keeps the
# host's database instance alive. A host-departure monitor (fsql_duck.c) notices that every client connection
# has closed and releases the pool, so `plain` (no fractal_release() call at all) must close cleanly too.
# Modes: see lifecycle_test.c. Every mode is asserted.
#
# Prints PASS / FAIL / SKIP lines and exits nonzero on any FAIL. Linux (it reads /proc/self/fd).
#
# Inputs (optional):
#   CAPI_DIST                       dir holding the built extensions (default dist/<platform>)
#   FSQL_LIBDUCKDB_14/_15/_20       the libduckdb.so directory for a line; default: the libduckdb.so next to
#                                   the highest v1.4.* / v1.5.* / v2.0.* CLI under dist/cli/ then ~/duckdb-cli/
#   CAPI_LIFECYCLE_ROUNDS           rounds per mode (default 3; 1 on a host with 4 CPUs or fewer)
#   CAPI_DEPARTRACE_ROUNDS          departrace rounds (default 15; 5 on a host with 4 CPUs or fewer)
#   FSQL_LIFECYCLE_FULL=1           skip the small-host defaults and the CPU pin below (use on a build machine)
#   FSQL_LOAD_MAX                   load guard: wait before each run while the 1-minute load average is above this
#                                   (default 1.5 x CPUs, at least 2)
#   FSQL_LOAD_WAIT                  seconds the guard waits for the load to drop before failing (default 300)
#   CAPI_LIFECYCLE_MODES            run only these modes (space-separated), e.g. "parallel" (default: all of them)
#   CAPI_LIFECYCLE_SAN              address | thread: build the extension (make SAN=...) and this test with that
#                                   sanitizer and run every mode under it. Thread runs with ASLR off (setarch -R):
#                                   TSan cannot map its shadow memory under some kernels' ASLR layouts. libduckdb is
#                                   not instrumented, so only races whose access is in the extension count.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPI="$(cd "$HERE/.." && pwd)"; REPO="$CAPI"
[ "$(uname -s)" = Linux ] || { echo "  SKIP lifecycle: Linux only"; exit 0; }
case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; *) arch=arm64 ;; esac
PLATFORM="linux_${arch}"
SAN="${CAPI_LIFECYCLE_SAN:-}"
DIST="${CAPI_DIST:-$CAPI/dist/$PLATFORM}"
RUN_PREFIX=""
if [ -n "$SAN" ]; then
  case "$SAN" in address|thread) ;; *) echo "  FAIL lifecycle: CAPI_LIFECYCLE_SAN must be address or thread"; exit 1 ;; esac
  nice make -C "$CAPI" SAN="$SAN" >/dev/null 2>&1 || { echo "  FAIL lifecycle: the $SAN extension did not build"; exit 1; }
  DIST="$CAPI/dist/san-$SAN"
  [ "$SAN" = thread ] && RUN_PREFIX="setarch $(uname -m) -R"
fi
# The sanitizer runtime keeps freed memory in a quarantine and hands it back to the OS lazily. On a
# small host that retained set is a large part of the resident set, and the run swaps itself to a
# crawl (or takes the machine down with it). Capping the quarantine and releasing eagerly keeps the
# footprint down; it hides nothing -- LeakSanitizer still reports what is live at exit.
# LeakSanitizer does not exist on macOS: asking for it there makes the ASan runtime itself refuse to start.
SAN_LEAKS=1; [ "$(uname -s)" = Darwin ] && SAN_LEAKS=0
SAN_ASAN_OPTS="detect_leaks=$SAN_LEAKS:quarantine_size_mb=64:thread_local_quarantine_size_kb=256:allocator_release_to_os_interval_ms=0"
# Small hosts (a 2-CPU VM): DuckDB starts one worker per CPU in every database and the extension adds a monitor
# thread, so the 9-database `multi` mode and the sanitizer runs can push the load average to 10x the CPU count.
# Fewer rounds, one CPU left free for the rest of the system, lowest I/O priority, and a load guard between runs.
NCPU="$(nproc 2>/dev/null || echo 1)"
PIN=""
if [ "${FSQL_LIFECYCLE_FULL:-0}" != 1 ]; then
  if [ "$NCPU" -le 4 ]; then
    export CAPI_LIFECYCLE_ROUNDS="${CAPI_LIFECYCLE_ROUNDS:-1}" CAPI_DEPARTRACE_ROUNDS="${CAPI_DEPARTRACE_ROUNDS:-5}"
  fi
  if [ "$NCPU" -gt 1 ] && command -v taskset >/dev/null 2>&1; then PIN="taskset -c 0-$((NCPU - 2))"; fi
  command -v ionice >/dev/null 2>&1 && PIN="ionice -c3 $PIN"
fi
ROUNDS="${CAPI_LIFECYCLE_ROUNDS:-3}"
LOAD_MAX="${FSQL_LOAD_MAX:-$(awk -v n="$NCPU" 'BEGIN{m=n*1.5; if(m<2)m=2; print m}')}"
LOAD_WAIT="${FSQL_LOAD_WAIT:-300}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/fsql_lifecycle_XXXXXX")"
# CAPI_LIFECYCLE_KEEP_LOGS=1 keeps the per-run logs, so a sanitizer report can be read in full
# (the failure message points at them). The default still cleans up.
if [ "${CAPI_LIFECYCLE_KEEP_LOGS:-0}" = 1 ]; then
  trap 'echo "  logs kept in $OUT"' EXIT
else
  trap 'rm -rf "$OUT"' EXIT
fi
fails=0
P() { echo "  PASS $*"; }
F() { echo "  FAIL $*"; fails=$((fails + 1)); }
S() { echo "  SKIP $*"; }

# load_guard: block until the 1-minute load average is at or below LOAD_MAX, so one run never starts on top of the
# previous one's tail. Fails the whole script (instead of stacking more load) if it does not settle in LOAD_WAIT s.
load_guard() {
  local waited=0 la
  while :; do
    la="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0)"
    awk -v l="$la" -v m="$LOAD_MAX" 'BEGIN{exit !(l<=m)}' && return 0
    [ "$waited" -ge "$LOAD_WAIT" ] && { F "lifecycle: load guard: load average stayed at $la (limit $LOAD_MAX) for ${LOAD_WAIT}s; stopped before adding more"; echo "lifecycle: $fails failure(s)"; exit 1; }
    sleep 5; waited=$((waited + 5))
  done
}

libdir_for() {   # $1 = line (14|15|20)
  local v="FSQL_LIBDUCKDB_$1"; [ -n "${!v:-}" ] && { echo "${!v}"; return; }
  local pat best="" root d
  case "$1" in 14) pat='v1.4.*' ;; 15) pat='v1.5.*' ;; 20) pat='v2.0.*' ;; esac
  for root in "$REPO/dist/cli" "$HOME/duckdb-cli"; do
    for d in $(ls -d "$root"/$pat 2>/dev/null | sort -V); do [ -f "$d/libduckdb.so" ] && best="$d"; done
    [ -n "$best" ] && break
  done
  echo "$best"
}

# TSan mode: libduckdb is not instrumented, so its own lock-free internals produce reports that are not ours. Count a
# report only when one of its racing accesses is in the extension's own code (src/fsql_*.c, fractalsql_ext.c).
tsan_ours() {   # $1 = log; prints the number of reports with an access in the extension
  python3 -I - "$1" <<'PYEOF'
import re, sys
n = 0
for rep in open(sys.argv[1], errors="replace").read().split("WARNING: ThreadSanitizer")[1:]:
    rep = rep.split("SUMMARY:")[0].split("\n", 1)[-1]     # drop the ": data race (pid=..)" header so the first access is read too
    for blk in re.split(r"\n\s*\n", rep):
        if re.match(r"\s*(Write|Read|Previous write|Previous read|Atomic)", blk):
            fr = re.findall(r"#\d+ (\S+) (\S+?:\d+)?", blk)
            # An access made through a sanitizer interceptor (free, delete, memcpy...) has the interceptor as frame #0 and its
            # caller as frame #1: skip the interceptor frames, so a race in a free() or memcpy() the extension itself makes counts.
            # operator new/delete/delete[] are C++ runtime calls: C code cannot make them, so such an access is libduckdb's own
            # (libduckdb has no frame pointers, so the unwinder can drop its frames and leave the extension looking like the caller).
            if re.search(r"^\s*#0 operator (new|delete)", blk, re.M): continue
            fr = [f for f in fr if "libsanitizer" not in (f[1] or "")]
            if fr and re.search(r"src/fsql|fractalsql_ext\.c", fr[0][1] or ""):
                n += 1
                break
print(n)
PYEOF
}

for line in 14 15 20; do
  lib="$(libdir_for "$line")"
  if [ -z "$lib" ]; then S "lifecycle ${line}.x: no libduckdb.so (set FSQL_LIBDUCKDB_$line)"; continue; fi
  if [ "$line" = 14 ]; then
    ext="$(ls "$DIST"/fractalsql.v1.4.*."$PLATFORM".duckdb_extension 2>/dev/null | sort -V | tail -1)"; hdr="$(ls -d "$CAPI"/vendor/duckdb-v1.4.* | sort -V | tail -1)"
  else
    ext="$DIST/fractalsql.capi.$PLATFORM.duckdb_extension"; hdr="$CAPI/vendor/duckdb-v1.5.6"
  fi
  if [ ! -f "$ext" ]; then S "lifecycle ${line}.x: extension not built"; continue; fi
  bin="$OUT/lc$line"
  if ! cc -std=c11 -O1 ${SAN:+-g -fsanitize=$SAN} -Wno-format-truncation -I"$hdr" "$HERE/lifecycle_test.c" -L"$lib" -lduckdb -lpthread -Wl,-rpath,"$lib" -o "$bin" 2>"$OUT/cc.log"; then
    F "lifecycle ${line}.x: the test did not build ($(head -c 200 "$OUT/cc.log"))"; continue
  fi
  # The per-mode budget. A sanitizer build pays the instrumented overhead on
  # every statement, so a mode that fits the budget uninstrumented -- the
  # nine-database "multi" mode especially -- can overrun it instrumented, and
  # a timeout there is a budget, not a defect.
  budget=240
  [ -n "$SAN" ] && budget=900
  for mode in ${CAPI_LIFECYCLE_MODES:-release nopool race plain defaults churn alias checkpoint off departrace thaw multi parallel}; do
    rounds="$ROUNDS"
    case "$mode" in defaults) rounds=1 ;; departrace) rounds="${CAPI_DEPARTRACE_ROUNDS:-15}" ;; esac
    log="$OUT/$line.$mode.log"
    load_guard
    # a hang must fail the run, not stall it
    if ASAN_OPTIONS="$SAN_ASAN_OPTS" TSAN_OPTIONS="exitcode=0" nice timeout "$budget" $PIN $RUN_PREFIX "$bin" "$ext" "$OUT/t$line.db" "$mode" "$rounds" >"$log" 2>&1 \
       && { [ "$SAN" != thread ] || [ "$(tsan_ours "$log")" = 0 ]; }; then
      P "lifecycle ${line}.x $mode: closes cleanly ($(grep -c '^  PASS' "$log") checks over $rounds rounds)"
    else
      rc=$?
      why="$(grep -m3 '^  FAIL' "$log" | tr '\n' ' ')"
      [ "$SAN" = thread ] && [ "$(tsan_ours "$log")" != 0 ] && why="$why ThreadSanitizer: $(tsan_ours "$log") race(s) with an access in the extension (see the log: rerun with the log kept)"
      # Name what the sanitizer found. Its own summary line says what it is -- a data race, a
      # lock-order inversion (a potential deadlock), a use-after-free -- and without it the message
      # is only "a crash, a hang or a sanitizer report?", which leaves the reader guessing. A
      # lock-order inversion also explains a run that never returns: ThreadSanitizer holds the
      # process when it reports one, so the run has to be timed out.
      san_summary="$(grep -m2 '^SUMMARY: ThreadSanitizer' "$log" | tr '\n' ' ' | cut -c1-300)"
      [ -n "$san_summary" ] && why="$why $san_summary"
      [ -n "$why" ] || why="no FAIL line (a crash, a hang or a sanitizer report?): $(tail -n 6 "$log" | tr '\n' ' ' | cut -c1-600)"
      F "lifecycle ${line}.x $mode (exit $rc): $why"
    fi
  done
  # One-shot CLI processes (a script, `duckdb db -c ...`): the process exits within milliseconds of closing its
  # database, before the monitor's grace period, and touching libduckdb during process teardown is not safe (an
  # exit-time checkpoint was tried and crashed). So a short-lived host ends its session with fractal_release(), or
  # runs with FRACTALSQL_NESTED_QUERIES=off; both leave no .wal. Without either the run must still exit cleanly.
  cli="$lib/duckdb"
  if [ -z "$SAN" ] && [ -x "$cli" ]; then
    for variant in release off plain; do
      # LIFECYCLE_SKIP_PLAIN=1 (the -O0 gcov build): the slow build makes the documented 2.x one-shot exit race likely
      [ "$variant" = plain ] && [ "${LIFECYCLE_SKIP_PLAIN:-0}" = 1 ] && [ "$line" = 20 ] && continue
      bad=0; walleft=0
      for i in 1 2 3 4 5 6 7 8; do
        rm -f "$OUT/cli.db" "$OUT/cli.db.wal"
        case "$variant" in
          release) env_pfx="X=1";                           mid_sql="SELECT length(fractal_schema_context());"; tail_sql="SELECT fractal_release();" ;;
          off)     env_pfx="FRACTALSQL_NESTED_QUERIES=off"; mid_sql="SELECT fractal_version();";             tail_sql="SELECT 1;" ;;
          plain)   env_pfx="X=1";                           mid_sql="SELECT length(fractal_schema_context());"; tail_sql="SELECT 1;" ;;
        esac
        load_guard
        env "$env_pfx" FSQL_REASONING_REQUIRE_SIGNATURE=0 nice timeout 60 $PIN "$cli" -unsigned "$OUT/cli.db" \
          -c "LOAD '$ext'; CREATE TABLE t AS SELECT range i FROM range(1000); $mid_sql $tail_sql" >/dev/null 2>&1 || bad=$((bad + 1))
        [ -e "$OUT/cli.db.wal" ] && walleft=$((walleft + 1))
      done
      if [ "$bad" -ne 0 ]; then F "lifecycle ${line}.x cli-$variant: $bad of 8 one-shot runs exited nonzero"
      elif [ "$variant" != plain ] && [ "$walleft" -ne 0 ]; then F "lifecycle ${line}.x cli-$variant: $walleft of 8 one-shot runs left a .wal"
      else P "lifecycle ${line}.x cli-$variant: 8 one-shot CLI runs exit cleanly$([ "$variant" != plain ] && printf ' and leave no .wal')"
      fi
    done
  fi
done
echo "lifecycle: $fails failure(s)"
[ "$fails" -eq 0 ]
