#!/usr/bin/env bash
# test/ledger_run.sh -- builds test/ledger_unit.c and runs it in each of its environments (the size cap and the anchor log are
# read once per process, so each needs its own run). SAN=address|undefined builds it with that sanitizer; COV=1 with --coverage.
# Prints one line per run and "ledger: N failure(s)"; exits nonzero on any failure.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/fsql_ledger_XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
flags=(-std=c11 -O1 -g -Wall -Wextra -I"$ROOT/src")
[ -n "${SAN:-}" ] && flags+=(-fsanitize="$SAN" -fno-sanitize-recover=all -fno-omit-frame-pointer)
[ "${COV:-0}" = 1 ] && flags+=(--coverage -fprofile-update=atomic)
env -u LD_PRELOAD cc "${flags[@]}" "$HERE/ledger_unit.c" -o "$OUT/ledger_unit" 2>"$OUT/cc.log" || { echo "  FAIL ledger_unit did not build"; tail -5 "$OUT/cc.log"; echo "ledger: 1 failure(s)"; exit 1; }
# LeakSanitizer does not exist on macOS: asking for it there makes the ASan runtime itself refuse to start.
LEAKS=1; [ "$(uname -s)" = Darwin ] && LEAKS=0
fails=0
run() {   # run LABEL VAR=value... -- mode
  local label="$1"; shift
  local envs=() mode
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift; mode="$1"
  out="$(env ASAN_OPTIONS=detect_leaks=$LEAKS ${envs[@]+"${envs[@]}"} "$OUT/ledger_unit" "$mode" 2>&1)"; rc=$?   # ${a[@]+...}: an empty array is an unbound variable under set -u in macOS bash 3.2
  if [ "$rc" -eq 0 ]; then echo "  PASS ledger $label: $(tail -1 <<< "$out")"
  else
    detail="$(grep -E 'FAIL|ERROR|runtime error' <<< "$out" | head -3 | tr '\n' ' ')"
    [ -n "$detail" ] || detail="$(tail -5 <<< "$out" | tr '\n' ' ')"
    echo "  FAIL ledger $label (rc=$rc): ${detail:-no output}"; fails=$((fails + 1)); fi
}
run default -- default
run cap FSQL_DUCKDB_LEDGER_MAX_BYTES=100 -- cap
run nocap FSQL_DUCKDB_LEDGER_MAX_BYTES=0 -- nocap
run badcap FSQL_DUCKDB_LEDGER_MAX_BYTES=abc -- badcap
run anchor FSQL_LEDGER_ANCHOR_LOG=stderr -- anchor
echo "ledger: $fails failure(s)"
[ "$fails" -eq 0 ]
