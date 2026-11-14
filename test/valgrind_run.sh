#!/usr/bin/env bash
# test/valgrind_run.sh -- build_test.sh --profile: valgrind memcheck over the extension (Linux only).
#
# What it adds to the sanitizer cells: uninitialised reads (MemorySanitizer cannot be used, the host is not
# instrumented) and leaks (the sanitizer runs set detect_leaks=0), on the unmodified release build.
#
# Targets:
#   units    test/redact_unit, test/buf_test, test/ledger_unit, tests/ed25519_probe and the fuzz-corpus replay, built -O0 -g
#   engine   the DuckDB 1.5.x CLI loading the release extension (dist/linux_<arch>) and running every default-
#            environment parity case (test/parity/*.sql) in one session, threads=1
#   mcp      the MCP server's own code (mcp/src, C++): its standalone probes (vectors, sanitize, db, concurrency), which
#            load libduckdb and the extension in-process. Needs the libduckdb of the CLI's version (see FSQL_LIBDUCKDB_DIR).
#   server   the running MCP server, started under valgrind and driven by mcp/tests/mcp_smoke_client.py (JSON-RPC over stdio:
#            every tool, the protocol, the lock files; ~190 checks)
#
# Verdict (test/valgrind_check.py): FAIL on any memcheck error or definite/indirect leak whose stack has a frame in
# our code (the extension, or the unit binary); the host's own reports and possible leaks are counted, not failed.
# SKIP (exit 0) when not on Linux or valgrind is missing.
#
# Env: PROFILE_KEEP=1 keeps the logs directory; PROFILE_ONLY=units|engine|mcp|server runs one target; PROFILE_LINES="15 14 20" runs the engine slice on those DuckDB lines (default 15 only); FSQL_LIBDUCKDB_DIR names a
# directory holding duckdb.h and libduckdb.so for the mcp target (default: the cache build_test.sh fills, else the CLI's own).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"
say() { printf '\n== profile: %s\n' "$*"; }
[ "$(uname -s)" = Linux ] || { echo "  SKIP profile: valgrind runs on Linux only"; exit 0; }
command -v valgrind >/dev/null 2>&1 || { echo "  SKIP profile: valgrind is not installed"; exit 0; }
case "$(uname -m)" in x86_64|amd64) PLAT=linux_amd64 ;; *) PLAT=linux_arm64 ;; esac
ONLY="${PROFILE_ONLY:-}"
W="$(mktemp -d "${TMPDIR:-/tmp}/fsql_profile_XXXXXX")"
trap '[ "${PROFILE_KEEP:-0}" = 1 ] || rm -rf "$W"' EXIT
FAILS=0
VG=(valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite,indirect,possible --track-origins=yes
    --num-callers=40 --fair-sched=yes --xml=yes)

run_target() {   # label, ours-substring, cmd...   (stdin is passed through)
  local label="$1" ours="$2"; shift 2
  local xml="$W/$label.xml" log="$W/$label.log"
  timeout 1500 nice "${VG[@]}" --xml-file="$xml" "$@" >"$log" 2>&1
  local rc=$?
  if [ ! -s "$xml" ]; then echo "  FAIL $label: valgrind produced no report (rc=$rc; see $log)"; FAILS=$((FAILS + 1)); return; fi
  if python3 -I "$HERE/valgrind_check.py" verdict --ours "$ours" "$xml"; then echo "  PASS $label"
  else echo "  FAIL $label (logs in $W)"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1; fi
}

if [ -z "$ONLY" ] || [ "$ONLY" = units ]; then
  say "units"
  mkdir -p "$W/u"
  build() { cc -std=c11 -O0 -g -Wno-unused-function -Isrc "$@" -lm 2>"$W/u/cc.log" || { echo "  FAIL a unit binary did not build"; tail -3 "$W/u/cc.log"; FAILS=$((FAILS + 1)); return 1; }; }
  build test/redact_unit.c -o "$W/u/redact_unit" && run_target redact_unit "$W/u/" "$W/u/redact_unit"
  build test/buf_test.c src/fsql_buf.c -o "$W/u/buf_test" && run_target buf_test "$W/u/" "$W/u/buf_test"
  build test/ledger_unit.c -o "$W/u/ledger_unit" && run_target ledger_unit "$W/u/" "$W/u/ledger_unit"
  build tests/ed25519_probe.c -o "$W/u/ed25519_probe" && run_target ed25519_probe "$W/u/" "$W/u/ed25519_probe"
  build test/fuzz_replay.c tests/fuzz/fuzz_t2s_parse.c src/fsql_parse.c src/fsql_buf.c -o "$W/u/fuzz_replay" \
    && run_target fuzz_replay "$W/u/" "$W/u/fuzz_replay" tests/fuzz/corpus_t2s_parse 3
fi

if [ -z "$ONLY" ] || [ "$ONLY" = engine ]; then
  nice make >"$W/make.log" 2>&1 || { echo "  FAIL the extension did not build (see $W/make.log)"; PROFILE_KEEP=1; exit 1; }
  for LN in ${PROFILE_LINES:-15}; do
    say "engine (DuckDB ${LN:0:1}.${LN:1}.x CLI + the release extension)"
    case "$LN" in
      14) EXT="$(ls -1 "$ROOT"/dist/"$PLAT"/fractalsql.v1.4.*."$PLAT".duckdb_extension 2>/dev/null | sort -V | tail -1)" ;;
      *)  EXT="$ROOT/dist/$PLAT/fractalsql.capi.$PLAT.duckdb_extension" ;;
    esac
    [ -f "$EXT" ] || { echo "  FAIL no extension for DuckDB line $LN at $EXT"; FAILS=$((FAILS + 1)); continue; }
    CLI="$(python3 -I "$HERE/valgrind_check.py" slice "$W/slice$LN.sql" "$EXT" "$LN" 2>"$W/slice$LN.err")" \
      || { echo "  SKIP engine $LN: $(cat "$W/slice$LN.err")"; continue; }
    echo "  $(cat "$W/slice$LN.err"); $CLI"
    export FSQL_REASONING_REQUIRE_SIGNATURE=0
    # the script is fed on stdin: run_target passes it through
    run_target "engine_$LN" "fractalsql." "$CLI" -unsigned -batch -csv < "$W/slice$LN.sql"
  done
fi

# the libduckdb the MCP targets build against: FSQL_LIBDUCKDB_DIR, else the cache build_test.sh fills (made from the CLI's own
# libduckdb.so and the vendored header if absent). Sets LIBDIR, EXT and CLI; returns 1 (with a SKIP line) when there is none.
mcp_setup() {
  nice make >"$W/make.log" 2>&1 || { echo "  FAIL the extension did not build (see $W/make.log)"; PROFILE_KEEP=1; exit 1; }
  EXT="$ROOT/dist/$PLAT/fractalsql.capi.$PLAT.duckdb_extension"
  CLI="$(python3 -I "$HERE/valgrind_check.py" slice "$W/slice-mcp.sql" "$EXT" 2>/dev/null)" || CLI=""
  LIBDIR="${FSQL_LIBDUCKDB_DIR:-}"
  if [ -z "$LIBDIR" ] && [ -n "$CLI" ]; then
    local VER A
    VER="$("$CLI" -noheader -list -c 'SELECT version()' 2>/dev/null | tr -d '\r' | tail -1)"
    case "$PLAT" in linux_amd64) A=amd64 ;; *) A=arm64 ;; esac
    LIBDIR="${XDG_CACHE_HOME:-$HOME/.cache}/fractalsql/libduckdb-$VER-$A"
    if [ ! -f "$LIBDIR/duckdb.h" ] && [ -f "$(dirname "$CLI")/libduckdb.so" ] && [ -f "$ROOT/vendor/duckdb-$VER/duckdb.h" ]; then
      mkdir -p "$LIBDIR" && cp "$ROOT/vendor/duckdb-$VER/duckdb.h" "$LIBDIR/duckdb.h" && cp "$(dirname "$CLI")/libduckdb.so" "$LIBDIR/libduckdb.so" || rm -rf "$LIBDIR"
    fi
  fi
  if [ -z "$LIBDIR" ] || [ ! -f "$LIBDIR/duckdb.h" ]; then
    echo "  SKIP mcp: no libduckdb for the CLI's version (set FSQL_LIBDUCKDB_DIR to a directory with duckdb.h and libduckdb.so)"; return 1
  fi
  CXX="$(command -v g++ || command -v c++ || command -v clang++)"
  mkdir -p "$W/mcp"
  export LD_LIBRARY_PATH="$LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" FSQL_DUCKDB_EXTENSION="$EXT" FSQL_REASONING_REQUIRE_SIGNATURE=0
}

if [ -z "$ONLY" ] || [ "$ONLY" = mcp ]; then
  say "mcp (the MCP server's probes, C++, libduckdb + the extension in-process)"
  if mcp_setup; then
    if ! nice make -C "$ROOT/mcp" probes CXX="$CXX" CXXFLAGS="-O1 -g" DUCKDB_DIR="$LIBDIR" BUILD="$W/mcp/build" >"$W/mcp/make.log" 2>&1; then
      echo "  FAIL the MCP probes did not build (see $W/mcp/make.log)"; tail -5 "$W/mcp/make.log"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1
    else
      for p in vectors_probe sanitize_probe db_probe concurrency_probe; do
        run_target "mcp_$p" "$W/mcp/" "$W/mcp/build/$p"
      done
    fi
  fi
fi

# The running server: the smoke client (JSON-RPC over stdio; every tool called, the protocol, the lock files) drives a server
# that is started under valgrind by a wrapper script (every process the client starts gets its own log). The client's slow
# sweeps are skipped (MCP_SMOKE_SKIP_SWEEPS=1).
if [ -z "$ONLY" ] || [ "$ONLY" = server ]; then
  say "server (the running MCP server under valgrind, driven by mcp/tests/mcp_smoke_client.py)"
  if mcp_setup; then
    if ! nice make -C "$ROOT/mcp" CXX="$CXX" CXXFLAGS="-O1 -g" DUCKDB_DIR="$LIBDIR" BUILD="$W/mcp/sbuild" OUT="$W/mcp/srv" >"$W/mcp/smake.log" 2>&1 \
       || ! nice make -C "$ROOT/mcp" probes CXX="$CXX" CXXFLAGS="-O1 -g" DUCKDB_DIR="$LIBDIR" BUILD="$W/mcp/sbuild" >>"$W/mcp/smake.log" 2>&1; then
      echo "  FAIL the MCP server did not build (see $W/mcp/smake.log)"; tail -5 "$W/mcp/smake.log"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1
    else
      mkdir -p "$W/mcp/slogs"
      {
        echo '#!/bin/sh'
        echo "exec nice valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite,indirect,possible --track-origins=yes \\"
        echo "  --num-callers=40 --fair-sched=yes --xml=yes --xml-file='$W/mcp/slogs/server.%p.xml' '$W/mcp/srv' \"\$@\""
      } > "$W/mcp/srv-valgrind.sh"
      chmod +x "$W/mcp/srv-valgrind.sh"
      out="$(env MCP_SERVER_EXE="$W/mcp/srv-valgrind.sh" MCP_SERVER_CWD="$ROOT" MCP_HERE="$ROOT/mcp" MCP_DUCKDB_EXEC="$W/mcp/sbuild/duckdb_exec" \
             MCP_SMOKE_SKIP_SWEEPS=1 FSQL_DUCKDB_ALLOW_UNSIGNED=true ASAN_OPTIONS=detect_leaks=0 \
             timeout 3000 python3 "$ROOT/mcp/tests/mcp_smoke_client.py" 2>&1)"
      rc=$?
      printf '%s\n' "$out" > "$W/mcp/smoke.log"
      echo "  smoke client: $(grep -c '^ *PASS' <<< "$out") checks passed, $(grep -c '^ *FAIL' <<< "$out") failed (exit $rc)"
      if [ "$rc" -ne 0 ]; then
        echo "  (the checks run under valgrind's slowdown: a failure here may be a client timeout, see $W/mcp/smoke.log)"
        grep -E '^ *FAIL' <<< "$out" | head -5
        FAILS=$((FAILS + 1)); PROFILE_KEEP=1
      fi
      # shellcheck disable=SC2206
      logs=("$W"/mcp/slogs/server.*.xml)
      if [ -e "${logs[0]}" ]; then
        if python3 -I "$HERE/valgrind_check.py" verdict --ours "$W/mcp/" --ours "fractalsql." "${logs[@]}"; then echo "  PASS server (${#logs[@]} server process(es))"
        else echo "  FAIL server (logs in $W)"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1; fi
      else echo "  FAIL server: no valgrind logs were written"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1; fi
    fi
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "profile: all targets clean"; else echo "profile: $FAILS target(s) failed"; fi
[ "${PROFILE_KEEP:-0}" = 1 ] && echo "  logs kept in $W"
exit "$FAILS"
