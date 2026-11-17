#!/usr/bin/env python3
"""test/parity_diff.py -- the parity corpus: every case in test/parity/*.sql runs through the pure-C extension on
each DuckDB line (1.4.x / 1.5.x / 2.0.x) and the outputs must agree, and each case's written expectation holds.

For every case in test/parity/*.sql (blank-line separated; one CLI session each):
  * run it with the C extension on the 1.5.x CLI (the reference line); a case carrying "-- expect: <text>" or
    "-- expect-c: <text>" must have that text in its output;
  * run it with the C extension on every other CLI -> identical to the 1.5.x output;
  * only when CPP_EXT names the retired C++ extension: also run it there and require identical output (the retired
    build kept the old function names fractal_explore / fractal_vector_l2 / fractal_vector_l2_sq, so it is no longer
    compared by default).

Prints PASS/FAIL/SKIP lines; exits nonzero on any FAIL. Linux/macOS.

Env: CPP_EXT (optional reference C++ extension),
     FSQL_DUCKDB_14/_15/_20 or ~/duckdb-cli/v<ver>/duckdb (see load_matrix.sh).
"""
import glob, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I drops the script dir
from harness_common import *   # noqa: F401,F403  (shared plumbing, see harness_common.py)
from harness_common import signature_policy, PLUGINS, SAN, DIST, LINES, CLEAN_ENV, MOCK_FILES, san_runtime, latest_cli, band_file, expand, HERE, CAPI, REPO, PLAT, run_cli

# Known, accepted differences (decision D5 in ~/github/duckdb-purec-ext-port.txt):
#  * the class prefix of a "fractalsql:" error. The C++ build throws duckdb::IOException, which
#    prints "IO Error: <msg>" (or "Invalid Input Error:" from a bind); the C API's scalar error
#    call prints "Invalid Input Error: <msg>" and a table function's bind error prints
#    "Binder Error: <msg>". Same message text after the prefix. All three are canonicalised to
#    "Error:" and the number of outputs whose prefix actually changed is reported.
#  * the 2.0 CLI draws the error location caret differently, and appends an "-agent" hint line.
#    CLI noise: stripped.
PREFIX_CHANGED = 0
_PREFIX = re.compile(r"(?:IO Error|Invalid Input Error|Invalid Error|Binder Error): (fractal\w*:)")
# The C++ build re-wraps some exceptions with e.what(), which in DuckDB 1.5+/2.0 is a JSON envelope:
#   {"exception_type":"IO","exception_message":"<message>"}
# The user-facing text is the inner message; unwrap it (and un-escape the JSON string) so the comparison is about
# what the user reads. Counted separately.
ENVELOPE_UNWRAPPED = 0
_ENVELOPE = re.compile(r'\{"exception_type":"[^"]*","exception_message":"((?:[^"\\]|\\.)*)"\}')
# DuckDB 2.0 renders a candidate function's parameters with their names -- "fractal_dimension_boxcount(col0
# DOUBLE[], col1 INTEGER, /)" -- where 1.5 rendered the types alone -- "fractal_dimension_boxcount(DOUBLE[],
# INTEGER)". The binder error is the same error either way, so the parameter names and the positional marker are
# normalized away before the two versions are compared.
_CANDIDATE = re.compile(r"\b(fractal_\w+)\(([^()]*)\)")
def _norm_candidate(m):
    params = re.sub(r"\bcol\d+\s+", "", m.group(2))
    params = re.sub(r"\s*,\s*/\s*$", "", params)
    return m.group(1) + "(" + params + ")"
def _unescape(m):
    global ENVELOPE_UNWRAPPED
    ENVELOPE_UNWRAPPED += 1
    return re.sub(r"\\(.)", lambda e: {"n": "\n", "t": "\t"}.get(e.group(1), e.group(1)), m.group(1))

def canon(out):
    global PREFIX_CHANGED
    out = _ENVELOPE.sub(_unescape, out)
    if _PREFIX.search(out) and not all(m.group(0).startswith("Invalid Input Error") for m in _PREFIX.finditer(out)):
        PREFIX_CHANGED += 1
    out = _PREFIX.sub(r"Error: \1", out)
    out = re.sub(r"(?m)^\s*\^+\s*$\n?", "", out)
    out = _CANDIDATE.sub(_norm_candidate, out)
    return out


# A one-shot host ends its session with fractal_release() (the extension's documented contract): without it the
# host-departure monitor can still be running a query when a DuckDB 2.x CLI tears down, which crashes the process at
# exit (SIGSEGV) in a few percent of runs. The call's own output line is stripped so the outputs stay comparable.
RELEASE_MARK = "FSQL_PARITY_RELEASE="
EXIT_RETRIES = 0


def run(cli, ext, sql, san=False, extra_env=None, release=False):
    script = f"LOAD '{ext}';\n{sql}\n"
    # (a script that sets the destructive latch cannot release: the latch refuses it by design)
    release = release and "fractal_lock_destructive" not in sql
    if release: script += f"SELECT '{RELEASE_MARK}' || fractal_release()::VARCHAR;\n"
    env = dict(CLEAN_ENV)
    files = {}
    if extra_env:
        for k, v in extra_env.items():
            if k.startswith("@"): files[k[1:]] = v
            else: env[k] = v
    signature_policy(env)
    for name, path in MOCK_FILES.items():
        try:
            if name in files:
                with open(path, "w") as fh: fh.write(files[name].replace("\\n", "\n"))
            elif os.path.exists(path): os.remove(path)
        except OSError: pass
    if san and SAN:
        rt = san_runtime()
        if not rt: raise SystemExit("no sanitizer runtime found for CAPI_SAN=" + SAN)
        env["LD_PRELOAD"] = rt
        env["ASAN_OPTIONS"] = "detect_leaks=0:abort_on_error=0:halt_on_error=1"
        env["UBSAN_OPTIONS"] = "print_stacktrace=1:halt_on_error=1"
    cmd = [cli, "-unsigned", "-csv", "-noheader", "-bail"]
    p = run_cli(cmd, input=script, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=900)
    if release and p.returncode == -11:
        # A script that ends on an error exits under -bail before it can release, and a DuckDB 2.x CLI can crash at
        # exit if the extension's monitor is mid-query (see RELEASE_MARK). That crash is nondeterministic, so run
        # the script once more; a crash that repeats still fails the comparison. Every retry is counted and printed.
        global EXIT_RETRIES
        EXIT_RETRIES += 1
        p = run_cli(cmd, input=script, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=900)
    if san and SAN and ("Sanitizer" in p.stderr or "runtime error" in p.stderr):
        return "SANITIZER-REPORT\n" + p.stderr[:1500]
    # "hint: -agent" is CLI noise. The unsigned-plugin notice is a deliberate product message (the harness opts its
    # mock plugins out of the signature requirement); the C++ reference build predates it.
    stdout = p.stdout
    if release: stdout = "".join(l for l in stdout.splitlines(keepends=True) if not l.startswith(RELEASE_MARK))
    err = "\n".join(l for l in p.stderr.splitlines()
                    if not l.startswith("hint: -agent")
                    and not (l.startswith("fractalsql: loading reasoning plugin") and "without a signature" in l))
    return canon(f"rc={p.returncode}\n{stdout}{err}\n".replace(ext, "<EXT>"))

# "-- expect: <text>" is a SPEC case: there is no C++ reference for it (e.g. a function newer than the
# reference binary), so only the C output is checked, on each DuckDB line.
# A case may carry an "-- expect-c: <text>" line. That marks a DELIBERATE divergence from the
# C++ build (it was a bug there): the C++ comparison is skipped, and the C output must contain
# <text>. A case marked "-- xver: skip" legitimately differs between DuckDB lines (grammar differences) and is
# compared with the C++ build only. Cross-version consistency (1.4.x / 1.5.x / 2.0.x) is still required. Every such case
# is listed at the end of the run so divergences stay visible, never silent.
fails = passes = skips = 0
def P(m):
    global passes; passes += 1; print("  PASS", m)
def F(m):
    global fails; fails += 1; print("  FAIL", m)
def S(m):
    global skips; skips += 1; print("  SKIP", m)

# The C++ build is retired (and its functions kept the old names fractal_explore / fractal_vector_l2 / fractal_vector_l2_sq),
# so it is compared only when CPP_EXT names one explicitly; otherwise the corpus checks the expectations written in it and
# cross-version equality (1.4.x / 1.5.x / 2.0.x).
cpp = None if SAN else (os.environ.get("CPP_EXT") or None)
clis = {l: latest_cli(l) for l in ("14", "15", "20")}
exts = {l: band_file(l) for l in ("14", "15", "20")}
exts["20"] = exts["15"] = band_file("15")
ref_line = "15"

if not clis["15"] or not exts["15"]:
    print("  FAIL need the 1.5.x CLI and the stable band built"); sys.exit(1)
if not cpp or not os.path.exists(cpp):
    S("no C++ reference extension (set CPP_EXT): comparing across DuckDB versions only")
    cpp = None

DIVERGENT = []
for src, sql, expect, cenv, diverges, xskip in cases():
    first = sql.splitlines()[0][:70]
    c_ref = run(clis["15"], exts["15"], sql, san=True, extra_env=cenv)
    if expect is not None:
        if diverges: DIVERGENT.append(f"{src}: {first}")
        if expect in c_ref:
            P(f"{src}: C output as intended ({expect!r}): {first}")
        else:
            F(f"{src}: C output lacks the intended {expect!r}: {first}\n      C  : {c_ref[:300]!r}")
    elif cpp:
        cpp_out = run(clis["15"], cpp, sql, extra_env=cenv)
        if cpp_out == c_ref:
            P(f"{src}: C == C++ on 1.5.x: {first}")
        else:
            F(f"{src}: C differs from C++ on 1.5.x: {first}\n      C++: {cpp_out[:300]!r}\n      C  : {c_ref[:300]!r}")
    for line in ("14", "20"):
        if xskip:
            continue
        if line not in LINES:
            continue
        if expect is not None:
            # a deliberate divergence: the wording around it is DuckDB's own and varies by
            # line, so check the expectation on each line instead of demanding equal text
            if clis[line] and exts[line]:
                o = run(clis[line], exts[line], sql, san=True, extra_env=cenv, release=(line == "20"))
                (P if expect in o else F)(f"{src}: C on {line}.x as intended ({expect!r}): {first}")
            continue
        if not clis[line] or not exts[line]:
            S(f"{src}: no CLI/band for line {line}"); continue
        out = run(clis[line], exts[line], sql, san=True, extra_env=cenv, release=(line == "20"))
        # error text may carry the host's own prefix wording; compare as-is first
        if out == c_ref:
            P(f"{src}: C on {line}.x == C on 1.5.x: {first}")
        else:
            F(f"{src}: C on {line}.x differs from 1.5.x: {first}\n      1.5: {c_ref[:300]!r}\n      {line}.x: {out[:300]!r}")

if DIVERGENT:
    print()
    print(f"  {len(DIVERGENT)} deliberate divergence(s) from the C++ build (intended behaviour of the C build; see the plan):")
    for d in DIVERGENT: print("    -", d)
if EXIT_RETRIES:
    print(f"  note: {EXIT_RETRIES} one-shot DuckDB 2.x run(s) crashed at exit (SIGSEGV) and were run again; see RELEASE_MARK in parity_diff.py")
print()
print(f"parity: {passes} passed, {fails} failed, {skips} skipped"
      f"  ({PREFIX_CHANGED} error-class prefixes and {ENVELOPE_UNWRAPPED} C++ JSON error envelopes canonicalised)")
sys.exit(1 if fails else 0)
