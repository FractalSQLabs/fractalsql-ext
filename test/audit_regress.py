#!/usr/bin/env python3
"""test/audit_regress.py -- regression tests for the security findings that are reachable from SQL.

  DK-01  FRACTALSQL_REASONING_PLUGIN is copied before the tier environment is rewritten, into a bounded buffer: a path longer than the
         buffer is a clean error naming the limit, not a truncated or dangling path handed to the signature check and dlopen
  DK-02  a .sig that cannot be read (a directory in its place) is refused, with no read from a stream left indeterminate
  DK-05  fractal_vectorizer_create takes 3 to 5 arguments; any other arity is a bind error, never a write past the argument array
Each call runs in its own CLI process (environment variables are read once per process).
Env: CAPI_DIST / EDGE_LINE as in edge_inputs.py. Exit status is nonzero when a check fails."""
import os, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I drops the script dir
from harness_common import signature_policy, PLUGINS, CLEAN_ENV, MOCK_FILES, latest_cli, band_file, run_cli, timeout_for

LINE = os.environ.get("EDGE_LINE", "15")
CLI, EXT = latest_cli(LINE), band_file(LINE)
if not CLI or not EXT:
    print("  FAIL need a DuckDB CLI and the built extension for line " + LINE); sys.exit(1)
passes = fails = 0
def check(cond, what, detail=""):
    global passes, fails
    if cond: passes += 1
    else: fails += 1; print("  FAIL %s %s" % (what, ("-- " + str(detail)[:300]) if detail else ""))

def run(sql, extra=None):
    env = dict(CLEAN_ENV); signature_policy(env)
    env.update({"FRACTALSQL_REASONING_PLUGIN": PLUGINS.get("mock_reasoning_plugin", "")})
    if extra: env.update(extra)
    script = "LOAD '%s';\nSELECT '@@START';\n%s\nSELECT '@@END';\n" % (EXT, sql if sql.endswith(";") else sql + ";")
    p = run_cli([CLI, "-unsigned", "-csv", "-noheader"], input=script, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=timeout_for(120))
    return p.returncode, p.stdout, " ".join(l for l in p.stderr.split("\n") if l.strip())

# DK-01 ---------------------------------------------------------------------------------------------------------------------------
with open(MOCK_FILES["sql"], "w") as fh: fh.write("SELECT 1;")
rc, out, err = run("SELECT fractal_reason('hello');", {"FRACTALSQL_REASONING_PLUGIN": "/" + "p" * 3000})
check("too long" in err + out, "DK-01 an over-long FRACTALSQL_REASONING_PLUGIN is a clean error that names the limit", (rc, out[-200:], err))
check(rc in (0, 1), "DK-01 the over-long path did not crash the CLI (rc=%s)" % rc)
rc, out, err = run("SELECT fractal_reason('hello');")
check("too long" not in err + out, "DK-01 a normal-length plugin path is not refused", (rc, err))

# DK-02 ---------------------------------------------------------------------------------------------------------------------------
d = tempfile.mkdtemp(prefix="fsql_dk02_")
plug = os.path.join(d, "plugin.so")
with open(plug, "wb") as fh: fh.write(b"\x7fELF-not-a-real-plugin")
os.mkdir(plug + ".sig")                       # a directory where the 64-byte signature should be: fopen succeeds, every read fails
env = {"FRACTALSQL_REASONING_PLUGIN": plug, "FSQL_REASONING_REQUIRE_SIGNATURE": "1", "FSQL_REASONING_ALLOW_UNVERIFIED": "0"}
rc, out, err = run("SELECT fractal_reason('hello');", env)
check(rc in (0, 1) and ("signature" in err.lower() or "sig" in err.lower() or "verify" in err.lower() or "refus" in err.lower()),
      "DK-02 an unreadable .sig is refused (no crash, a signature-class error)", (rc, out[-120:], err))

# DK-05 ---------------------------------------------------------------------------------------------------------------------------
for n in (2, 6):
    args = ",".join("'x'" for _ in range(n))
    rc, out, err = run("SELECT fractal_vectorizer_create(%s);" % args)
    check(rc in (0, 1) and ("No function matches" in err or "Binder Error" in err or "Candidate functions" in err or "arguments" in err),
          "DK-05 fractal_vectorizer_create with %d arguments is a bind error" % n, (rc, err))

print("audit_regress: %d checks passed, %d failed" % (passes, fails))
sys.exit(1 if fails else 0)
