#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/fractalsqlabs
"""test/ledger_payloads.py -- what fractal_audit_log writes into the chain for every shape of entry type, payload and actor.

The ledger entry is built from the caller's text, so whatever that text holds must never break the JSON or the
chain: an object payload gets the actor inside it, an array, a scalar, a string or anything else is wrapped as
{"value": ...}; the entry type and the actor name are escaped. Each entry must be accepted or refused cleanly, and
the chain must still verify.

Env: EDGE_LINE (the DuckDB line to exercise), FSQL_ENTERPRISE_CORE (the mock core, built here when it is not given).
"""
import glob, json, os, platform, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness_common import latest_cli, band_file

LINE = os.environ.get("EDGE_LINE", "15")
CLI, EXT = latest_cli(LINE), band_file(LINE)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if not CLI or not EXT:
    print("ledger_payloads: SKIP need a DuckDB CLI and the built extension")
    sys.exit(0)

WORK = os.path.realpath(os.path.join(os.environ.get("TMPDIR", "/tmp"), "fsql_ledgerpl_%d" % os.getpid()))
os.makedirs(WORK, exist_ok=True)
CORE = os.environ.get("FSQL_ENTERPRISE_CORE")
if not CORE:
    CC = os.environ.get("FSQL_CC") or "cc"
    ext = ".dll" if platform.system() == "Windows" else ".so"
    CORE = os.path.join(WORK, "mock_enterprise" + ext)
    r = subprocess.run([CC, "-shared", "-fPIC", "-std=c99", "-I" + os.path.join(ROOT, "include"),
                        os.path.join(ROOT, "test", "mock_enterprise.c"), "-o", CORE],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("  FAIL the mock enterprise core did not build:\n" + r.stderr)
        sys.exit(1)

# The mock core is unsigned, so the opt-out has to be in force before the extension is loaded.
env = dict(os.environ, FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE="0",
           FRACTALSQL_ENTERPRISE_LIB=CORE)
passes = fails = 0


def check(cond, what, detail=""):
    global passes, fails
    if cond:
        passes += 1
    else:
        fails += 1
        print("  FAIL %s %s" % (what, ("-- " + str(detail)[:250]) if detail else ""))


def lit(text):
    """A SQL literal for the text under test: the single quotes are doubled, everything else is the bytes."""
    return "'" + str(text).replace("'", "''") + "'"


def one(sql_text):
    """One statement in a fresh session; returns (ok, output)."""
    script = ("LOAD '%s';\n" % EXT +
              "SELECT fractal_config_set('enterprise_lib', %s);\n" % lit(CORE) +
              sql_text + "\n")
    p = subprocess.run([CLI, "-unsigned", "-batch", "-csv", "-noheader"], input=script,
                       capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=120)
    return p.returncode == 0, (p.stdout + p.stderr).strip()


ESC = "q\" b\\ bs\b ff\f nl\n cr\r tab\t c1\x01 c1f\x1f end"
PAYLOADS = (("an object", '{"n":1}', True), ("an object with spaces round it", '   {"n":1}   ', True),
            ("an object with tabs, newlines and returns round it", '\t\n\r {"n":1} \r\n\t', True),
            ("an object with whitespace inside the braces only", '{ \t\n\r }', True),
            ("an empty object", '{}', True), ("a nested object", '{"a":{"b":[1,2,{"c":null}]}}', True),
            ("an array", '[1,2,3]', True), ("an array with spaces round it", '  [1,2]  ', True),
            ("a string", '"text"', True), ("a number", '12', True), ("true", 'true', True),
            ("null", 'null', True), ("an object that is not closed", '{"a":1', False),
            ("braces with no members", '{ "a" }', False), ("plain text", 'not json', False),
            ("only whitespace", ' \t\n', False), ("the empty string", '', False),
            ("an object with a control character in a string", '{"a":"x\\ny"}', True))

n = 0
for what, payload, good in PAYLOADS:
    n += 1
    ok, r = one("SELECT fractal_audit_log(%s, %s);" % (lit("type.%d" % n), lit(payload)))
    if good:
        check(ok, "audit_log accepts %s" % what, r)
    else:
        check(not ok and "Error" in r, "audit_log answers for %s (accepted or refused cleanly)" % what, r)

for what, etype in (("a quote", 'a"b'), ("a backslash", "a\\b"), ("every escape and control character", ESC),
                     ("a long type", "t" * 300), ("a unicode type", "tipo é 日本 \U0001f600")):
    ok, r = one("SELECT fractal_audit_log(%s, '{\"k\":1}');" % lit(etype))
    check(ok or "Error" in r, "audit_log takes an entry type with %s" % what, r)

for what, actor in (("a quote", 'who "x"'), ("every escape and control character", ESC),
                    ("an empty name", ""), ("a long name", "n" * 400)):
    one("SELECT fractal_set_actor(%s);" % lit(actor))
    ok, r = one("SELECT fractal_audit_log('actor.test', '{\"a\":1}');")
    check(ok or "Error" in r, "audit_log with an actor name that is %s" % what, r)

for what, args in (("a NULL type", (None, '{}')), ("a NULL payload", ("t", None)),
                   ("an integer type", (5, '{}')), ("an integer payload", ("t", 5)),
                   ("both NULL", (None, None))):
    t, p = args
    ok, r = one("SELECT fractal_audit_log(%s, %s);" % (lit(t) if t is not None else "NULL",
                                                        lit(p) if p is not None else "NULL"))
    check(ok or "Error" in r, "audit_log answers for %s" % what, r)

ok, r = one("SELECT fractal_ledger_verify(1);")
check(ok, "the chain still verifies after all of it", r)

print("ledger_payloads: %d checks passed, %d failed" % (passes, fails))
sys.exit(1 if fails else 0)
