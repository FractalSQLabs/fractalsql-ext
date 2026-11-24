#!/usr/bin/env bash
# test/coverage_run.sh -- line, function and branch coverage of the extension's own sources (src/*.c), measured with
# gcov on a `make COV=1` build while the existing suites drive it. The MCP server's coverage is separate
# (build_test.sh --coverage); this is the extension.
#
# Stages (STAGES="build gates parity edge table unit lifecycle oom report"; default all):
#   build      make COV=1 (both bands, -O0 --coverage into $COVDIR, a tmp dir off the working copy) and delete the previous run's counters
#   gates      build_test.sh gates (functional, error paths, plugins, kits) against the instrumented extension
#   parity     test/parity_diff.py on 1.5.x
#   edge       test/edge_inputs.py (every overload x awkward arguments, configured/bare/misbehaving plugin)
#   table      test/error_table.py (the table of calls with exact outcomes) and test/ledger_sql.py (the ledger through SQL)
#   unit       the header-level unit tests (redact, buf, ledger store, ed25519, fuzz replay) (test/redact_unit.c, test/buf_test.c, tests/ed25519_probe.c) built with --coverage
#   lifecycle  test/lifecycle_test.c modes against the instrumented extension
#   oom        test/oom_sweep.py: every allocation the extension makes is failed in turn (tests/oom_preload.c scoped to
#              the extension's own code), asserting a clean error and no crash
#   report     lcov capture -> totals (and coverage_html/ when genhtml is installed)
#
# Counters accumulate across stages and processes (-fprofile-update is atomic: the extension has threads). A process
# that dies on a signal writes none, so the deliberate-crash gates (06, 18) add nothing.
#
# Env: COV_MIN (threshold for lines, functions and branches; default 80), OOM_MAX_TRIALS (allocation points per statement
# in the sweep; default 80), COV_FUZZ_MUTANTS, COV_GATES (space separated gate numbers; default below), COV_LINE (DuckDB line for edge/parity; default 15).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"
STAGES="${STAGES:-build gates parity edge table unit lifecycle oom report}"
# The instrumented build, its .gcno/.gcda counters and the unit binaries live OFF the working copy: on a shared-folder VM every
# counter merge at process exit (thousands of them in the OOM sweep) is I/O on the shared mount, which is what wedged the guest.
# Sources are only read from $ROOT. COV_DIR overrides; the default is stable so STAGES=... reruns find the earlier build.
COVDIR="${COV_DIR:-${TMPDIR:-/tmp}/fsql_cov_$(id -u)/cov}"
mkdir -p "$COVDIR" || { echo "coverage: cannot create $COVDIR" >&2; exit 1; }
case "$(uname -m)" in x86_64|amd64) ARCH=amd64 ;; *) ARCH=arm64 ;; esac
case "$(uname -s)" in Darwin) PLAT="osx_$ARCH" ;; *) PLAT="linux_$ARCH" ;; esac
COVEXT="$COVDIR/fractalsql.capi.$PLAT.duckdb_extension"
# Every default-set gate whose driver runs the harness's own artifact: the SQL gates through the runner's FSQL_EXT,
# the python drivers through CAPI_DIST. Gates 46, 47, 48, 49 and 51 build or resolve their own bands, so they count
# nothing here; the parity and OOM sweeps behind them are the parity/oom stages. Gate 30 is a stub; its code is
# gate 66's. Without the 59-73 gates the sources they drive -- the index, its agents, the feature store -- never run
# against the instrumented build, and the report's floor reads as an unlikely regression when a new source lands.
GATES="${COV_GATES:-01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 22 23 24 25 26 27 28 29 30 31 32 34 59 60 61 62 63 64 65 66 67 68 69 70 71 72 73}"
LINE="${COV_LINE:-15}"
TMPROOT="${TMPDIR:-/tmp}"

has() { case " $STAGES " in *" $1 "*) return 0 ;; esac; return 1; }
say() { printf '\n== coverage: %s\n' "$*"; }

if has build; then
  say "build (make COV=1)"
  find "$COVDIR" -name '*.gcda' -delete 2>/dev/null
  nice make COV=1 OUT="$COVDIR" >"$TMPROOT/fsql_cov_build.log" 2>&1 || { cat "$TMPROOT/fsql_cov_build.log"; exit 1; }
fi
[ -f "$COVEXT" ] || { echo "no instrumented extension at $COVEXT (run the build stage)"; exit 1; }

if has gates; then
  say "gates: $GATES"
  for g in $GATES; do
    # FSQL_EXT/CAPI_DIST point every gate at the instrumented build: the SQL gates through the runner,
    # the resolver-based gates (68, 69, 72, 73) and the band_file drivers (59-61, 63-65, 67, 71) through
    # the harness's own switch, so all of their counters land in $COVDIR.
    out="$(FSQL_EXT="$COVEXT" CAPI_DIST="$COVDIR" EDGE_LINE="$LINE" nice ./build_test.sh --gate "$g" 2>&1)"
    printf '%s\n' "$out" | grep -E '^== (ALL GREEN|FAILED)' | sed "s/^/  gate $g: /"
    printf '%s\n' "$out" | grep -E '\[FAIL\]' | head -5
  done
fi

if has parity; then
  say "parity (1.5.x)"
  CAPI_DIST="$COVDIR" CAPI_LINES=15 nice python3 -I test/parity_diff.py 2>&1 | grep -E 'FAIL|^parity'
fi

if has edge; then
  say "edge inputs (default environment)"
  CAPI_DIST="$COVDIR" EDGE_LINE="$LINE" nice python3 -I test/edge_inputs.py 2>&1 | tail -3
  # The same matrix under other process environments: each one reaches code the default run cannot.
  for variant in "FSQL_AUDIT_REDACT=hash" "FSQL_AUDIT_REDACT=truncate" "EDGE_ENT=mock_enterprise_noex" "EDGE_ENT=mock_enterprise_nomm" \
                 "EDGE_ENT=mock_enterprise_none" "EDGE_ENT=mock_enterprise_empty" "FSQL_LEDGER_ANCHOR_LOG=stderr" "FSQL_LEDGER_ANCHOR_LOG=syslog" \
                 "FSQL_LEDGER_ANCHOR_LOG=bogus" "FSQL_DUCKDB_LEDGER_MAX_BYTES=0" "FSQL_DUCKDB_LEDGER_MAX_BYTES=200" \
                 "FSQL_DUCKDB_LEDGER_MAX_BYTES=abc" "FRACTALSQL_NESTED_QUERIES=off" \
                 "FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update" "FRACTALSQL_HOST_CLOSE=checkpoint"; do
    say "edge inputs ($variant)"
    env "$variant" CAPI_DIST="$COVDIR" EDGE_LINE="$LINE" EDGE_CONFIGS=configured,fail nice python3 -I test/edge_inputs.py 2>&1 | tail -2
  done
fi

if has table; then
  say "error table and ledger through SQL"
  CAPI_DIST="$COVDIR" EDGE_LINE="$LINE" nice python3 -I test/error_table.py 2>&1 | tail -3
  CAPI_DIST="$COVDIR" EDGE_LINE="$LINE" nice python3 -I test/ledger_sql.py 2>&1 | tail -3
fi

if has unit; then
  say "unit tests (--coverage)"
  mkdir -p "$COVDIR/unit"
  for t in "redact_unit:test/redact_unit.c" "buf_test:test/buf_test.c src/fsql_buf.c" "ed25519_probe:tests/ed25519_probe.c"; do
    name="${t%%:*}"; srcs="${t#*:}"
    # shellcheck disable=SC2086
    if cc -std=c11 -O0 -g --coverage -fprofile-update=atomic -Wno-unused-function -Isrc $srcs -lm -o "$COVDIR/unit/$name" 2>"$TMPROOT/fsql_cov_unit.log"; then
      "$COVDIR/unit/$name" 2>&1 | tail -1
    else echo "  FAIL $name did not build"; tail -3 "$TMPROOT/fsql_cov_unit.log"; fi
  done
  COV=1 nice test/ledger_run.sh 2>&1 | tail -2
  # the fuzz corpus through its libFuzzer entry point, with deterministic mutations (no libFuzzer needed)
  if cc -std=c11 -O0 -g --coverage -fprofile-update=atomic -Isrc test/fuzz_replay.c tests/fuzz/fuzz_t2s_parse.c src/fsql_parse.c src/fsql_buf.c -lm \
       -o "$COVDIR/unit/fuzz_replay" 2>"$TMPROOT/fsql_cov_unit.log"; then
    "$COVDIR/unit/fuzz_replay" tests/fuzz/corpus_t2s_parse "${COV_FUZZ_MUTANTS:-40}" 2>&1 | tail -1
  else echo "  FAIL fuzz_replay did not build"; tail -3 "$TMPROOT/fsql_cov_unit.log"; fi
fi

if has lifecycle; then
  say "lifecycle"
  LIFECYCLE_SKIP_PLAIN=1 CAPI_DIST="$COVDIR" nice test/lifecycle_run.sh 2>&1 | grep -E 'FAIL|^lifecycle'
fi

if has oom; then
  say "allocation-failure sweep"
  # The same sampled shape the harness's own gate 56 uses. The full sweep -- every allocation
  # point of every statement -- is thousands of trials against the instrumented build, which
  # is slow; and every trial that kills the extension costs a fresh CLI process, each merging
  # the coverage counters at exit. That is an amount of I/O that is slow on a shared folder and
  # long on any machine. The assertion is the same either way: the extension survives an
  # allocation failure.
  # A wall-clock budget caps the stage as well, so a statement that hangs under the instrumented
  # build cannot run it away.
  oom_env=(env OOM_MAX_TRIALS="${OOM_MAX_TRIALS:-12}" OOM_SAMPLE="${OOM_SAMPLE:-3}" \
                OOM_LOAD_STRIDE="${OOM_LOAD_STRIDE:-3}" OOM_BUDGET_SECONDS="${OOM_BUDGET_SECONDS:-540}" \
                CAPI_DIST="$COVDIR")
  oom_budget=$(( ${OOM_BUDGET_SECONDS:-540} + 60 ))
  tmo=""
  if command -v timeout >/dev/null 2>&1; then tmo="timeout --kill-after=10"
  elif [ -x /opt/homebrew/opt/coreutils/libexec/gnubin/timeout ]; then
    tmo="/opt/homebrew/opt/coreutils/libexec/gnubin/timeout --kill-after=10"
  fi
  if [ -n "$tmo" ]; then
    $tmo "$oom_budget" "${oom_env[@]}" nice python3 -I test/oom_sweep.py 2>&1 | tail -15
  else
    "${oom_env[@]}" nice python3 -I test/oom_sweep.py 2>&1 | tail -15
  fi
fi

if has report; then
  say "report"
  find "$COVDIR" -name '*.gcda' | grep -q . || { echo "  no .gcda produced"; exit 1; }
  summary="$(python3 -I "$HERE/gcov_summary.py" "$COVDIR" 'src/[^/]+\.(c|h)$')"
  printf '%s\n' "$summary" | grep -v '^TOTAL '
  read -r _ L_PCT F_PCT B_PCT <<<"$(printf '%s\n' "$summary" | grep '^TOTAL ')"
  MIN="${COV_MIN:-80}"; verdict=0
  for m in "lines:$L_PCT" "functions:$F_PCT" "branches:$B_PCT"; do
    if awk -v v="${m#*:}" -v t="$MIN" 'BEGIN { exit !(v + 0 >= t + 0) }'; then echo "  PASS ${m%%:*} ${m#*:}% (>= $MIN%)"
    else echo "  FAIL ${m%%:*} ${m#*:}% (< $MIN%)"; verdict=1; fi
  done
  raw="$TMPROOT/fsql_cov_raw.info"; info="$TMPROOT/fsql_cov.info"
  lcov --capture --directory "$COVDIR" --output-file "$raw" --rc branch_coverage=1 \
       --ignore-errors inconsistent,unsupported,gcov,mismatch,source,negative >"$TMPROOT/fsql_cov_lcov.log" 2>&1 \
    && lcov --extract "$raw" "$ROOT/src/*" --output-file "$info" --rc branch_coverage=1 \
       --ignore-errors inconsistent,unsupported,mismatch,empty,negative >>"$TMPROOT/fsql_cov_lcov.log" 2>&1 \
    || { echo "  (lcov capture failed: no html; see $TMPROOT/fsql_cov_lcov.log)"; exit 0; }
  if command -v genhtml >/dev/null 2>&1; then
    genhtml "$info" --output-directory "$ROOT/coverage_html" --rc branch_coverage=1 \
            --ignore-errors inconsistent,unsupported,mismatch,empty,source >"$TMPROOT/fsql_cov_genhtml.log" 2>&1 \
      && echo "  html: coverage_html/index.html"
  fi
fi
exit "${verdict:-0}"
