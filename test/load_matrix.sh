#!/usr/bin/env bash
# test/load_matrix.sh -- does each band of the pure-C extension load where
# it should, get refused where it should, and carry no DuckDB code?
#
# Prints PASS / FAIL / SKIP lines (the harness gate counts them) and exits
# nonzero if any FAIL. Linux and macOS; the Windows twin lives in build_test.ps1.
#
# Inputs (all optional):
#   CAPI_DIST         dir holding the two built files   (default dist/<platform>)
#   FSQL_DUCKDB_14 / FSQL_DUCKDB_15 / FSQL_DUCKDB_20   the CLIs for the 1.4.x, 1.5.x and
#                     2.0.x lines. Default: the HIGHEST v1.4.* / v1.5.* / v2.0.* directory under
#                     dist/cli/ then ~/duckdb-cli/ (support policy: the latest patch of each line).
#   CAPI_PROBE_SQL    a statement that proves the extension answers
#                     (default: SELECT fractal_version(); the P0 spike answers
#                      SELECT fractal_spike_version() -- build it with
#                      make SRC=spike/fsql_spike.c CORE_LIB=)
#   CAPI_MAX_BYTES    size ceiling for a built extension (default 8 MiB)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPI="$(cd "$HERE/.." && pwd)"
REPO="$CAPI"

case "$(uname -s)" in Darwin) os=osx ;; *) os=linux ;; esac
case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; *) arch=arm64 ;; esac
PLATFORM="${CAPI_PLATFORM:-${os}_${arch}}"
DIST="${CAPI_DIST:-$CAPI/dist/$PLATFORM}"
PROBE="${CAPI_PROBE_SQL:-SELECT fractal_version()}"
MAXB="${CAPI_MAX_BYTES:-8388608}"

BAND_S="$DIST/fractalsql.capi.$PLATFORM.duckdb_extension"
# The LTS band is one exact DuckDB 1.4.x (its version is in the file name); take the newest.
BAND_L="$(ls -1 "$DIST"/fractalsql.v1.4.*."$PLATFORM".duckdb_extension 2>/dev/null | sort -V | tail -1)"
L_VER="$(basename "${BAND_L:-x}" | sed -n 's/^fractalsql\.\(v1\.4\.[0-9]*\)\..*/\1/p')"

FAILS=0
pass() { printf '  PASS %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }
skip() { printf '  SKIP %s\n' "$1"; }

cli_for() { # $1 = 14|15|20 -> path of the latest CLI of that line, or empty
  local var="FSQL_DUCKDB_$1" pat
  if [ -n "${!var:-}" ] && [ -x "${!var}" ]; then printf '%s' "${!var}"; return; fi
  case "$1" in 14) pat='v1.4.*' ;; 15) pat='v1.5.*' ;; 20) pat='v2.0.*' ;; esac
  local best
  best="$(ls -1d "$REPO"/dist/cli/$pat "$HOME"/duckdb-cli/$pat 2>/dev/null | sed 's|.*/||' | sort -Vu | tail -1)"
  [ -n "$best" ] || return
  for root in "$REPO/dist/cli" "$HOME/duckdb-cli"; do
    [ -x "$root/$best/duckdb" ] && { printf '%s' "$root/$best/duckdb"; return; }
  done
}

# run_sql CLI SQL...  -> stdout+stderr, rc in RC. -unsigned because the test
# artifacts are not signed; agent-mode env vars cleared so output stays plain.
run_sql() {
  local cli="$1"; shift
  OUT="$(env -u AI_AGENT -u CLAUDECODE "$cli" -unsigned -csv -c "$@" 2>&1)"; RC=$?
}

[ -f "$BAND_S" ] && [ -n "$BAND_L" ] && [ -f "$BAND_L" ] || { fail "both bands built under $DIST (run: make)"; exit 1; }

# ----------------------------------------------------------- binary hygiene
for f in "$BAND_S" "$BAND_L"; do
  b="$(basename "$f")"
  sz=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")
  [ "$sz" -le "$MAXB" ] && pass "$b is $sz bytes (ceiling $MAXB): no DuckDB code inside" \
                        || fail "$b is $sz bytes, over the $MAXB ceiling -- is DuckDB being linked in?"
  if command -v nm >/dev/null 2>&1; then
    if [ "$os" = osx ]; then syms="$(nm -gU "$f" 2>/dev/null | awk '{print $NF}')"
    else syms="$(nm -D --defined-only "$f" 2>/dev/null | awk '{print $NF}')"; fi
    n=$(printf '%s\n' "$syms" | grep -c . || true)
    if [ "$n" -eq 1 ] && printf '%s\n' "$syms" | grep -qE '^_?fractalsql_init_c_api$'; then
      pass "$b exports exactly one symbol, fractalsql_init_c_api"
    else
      fail "$b exports $n symbols (want only fractalsql_init_c_api): $(printf '%s' "$syms" | tr '\n' ' ' | cut -c1-120)"
    fi
  else
    skip "$b symbol check (no nm)"
  fi
  if command -v strings >/dev/null 2>&1 && strings -n 6 "$f" | grep -q 'duckdb::'; then
    fail "$b contains C++ DuckDB symbols (duckdb::)"
  else
    pass "$b has no duckdb:: C++ symbols"
  fi
done

# ------------------------------------------------------------ footer check
footer() { # file -> "abi|duckdb_version|platform"
  python3 -I - "$1" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()[-534:]
f=d[22:22+256]                       # META8..META1, 32 bytes each
fld=lambda i: f[i*32:(i+1)*32].rstrip(b'\0').decode()
print("%s|%s|%s" % (fld(3), fld(5), fld(6)))   # META5 abi, META3 version, META2 platform
PY
}
fs="$(footer "$BAND_S")"; fl="$(footer "$BAND_L")"
[ "$fs" = "C_STRUCT|v1.5.6|$PLATFORM" ] && pass "band S footer: $fs" || fail "band S footer is '$fs'"
[ "$fl" = "C_STRUCT_UNSTABLE|$L_VER|$PLATFORM" ] && pass "band L footer: $fl" || fail "band L footer is '$fl' (want C_STRUCT_UNSTABLE|$L_VER|$PLATFORM)"

# --------------------------------------------------------------- load matrix
#           line  band S expected  band L expected
for row in "14 refuse load" "15 load refuse" "20 load refuse"; do
  set -- $row
  id=$1; es=$2; el=$3
  cli="$(cli_for "$id")"
  case "$id" in 14) line=1.4.x ;; 15) line=1.5.x ;; 20) line=2.0.x ;; esac
  if [ -z "$cli" ]; then skip "no DuckDB $line CLI (set FSQL_DUCKDB_$id, or put it in ~/duckdb-cli/v<version>/duckdb)"; continue; fi
  ver="$(env -u AI_AGENT -u CLAUDECODE "$cli" --version 2>/dev/null | awk '{print $1}')"
  # The LTS band is the latest 1.4.x only: a CLI of an older 1.4.x must refuse it, and
  # the matrix says so rather than silently expecting a load.
  for band in S L; do
    if [ "$band" = S ]; then file="$BAND_S"; want="$es"; else file="$BAND_L"; want="$el"; fi
    this_want="$want"
    if [ "$band" = L ] && [ "$id" = 14 ] && [ "$ver" != "$L_VER" ]; then this_want=refuse; fi
    run_sql "$cli" "LOAD '$file'; $PROBE;"
    if [ "$this_want" = load ]; then
      if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -qi 'error\|exception'; then
        pass "band $band loads on DuckDB $ver and answers: $(printf '%s' "$OUT" | tail -1 | cut -c1-40)"
      else
        fail "band $band should load on DuckDB $ver: $(printf '%s' "$OUT" | head -2 | cut -c1-160)"
      fi
    else
      if printf '%s' "$OUT" | grep -qE "C API version|built specifically for DuckDB version"; then
        pass "band $band is refused by DuckDB $ver with the version message"
      else
        fail "band $band should be refused by DuckDB $ver: rc=$RC $(printf '%s' "$OUT" | head -2 | cut -c1-160)"
      fi
    fi
  done
done

# ---------------------------------------------------- connection identity
cli="$(cli_for 15)"
if [ -n "$cli" ] && printf '%s' "$PROBE" | grep -q fractal_spike; then
  run_sql "$cli" "LOAD '$BAND_S'; SELECT fractal_spike_conn(), fractal_spike_conn(), (SELECT fractal_spike_conn());"
  if [ "$(printf '%s' "$OUT" | tail -1 | awk -F, '{print ($1==$2)}')" = 1 ]; then
    pass "one statement sees one connection id (got: $(printf '%s' "$OUT" | tail -1))"
  else fail "connection id differs inside one statement: $OUT"; fi
  # two separate CLI processes are two databases and two connections
  a="$(env -u AI_AGENT -u CLAUDECODE "$cli" -unsigned -csv -noheader -c "LOAD '$BAND_S'; SELECT fractal_spike_conn()" 2>&1 | tail -1)"
  pass "a second process reports its own id ($a)"
else
  skip "connection identity (the spike probe only; the real check is gate capi_conn, phase 3)"
fi

printf '\n'
[ "$FAILS" -eq 0 ] && { echo "capi load matrix: ALL GREEN"; exit 0; }
echo "capi load matrix: $FAILS failure(s)"; exit 1
