#!/usr/bin/env python3
"""test/ledger_sql.py -- the ledger family through the real extension and CLI, with the mock enterprise core loaded.

test/ledger_unit.c forges and damages chains at the store level; this checks what a SQL user sees: fractal_audit_log appends to
its chain, fractal_ledger_verify reports it, every head is published to the anchor log when asked, the size cap refuses an append
without damaging the chain, the one-way destructive latch refuses every destructive action (and the audit append) while the
read-only functions keep working, and a missing enterprise library is reported as such.

Each scenario is one CLI session under its own process environment (the cap and the anchor mode are read once per process).
Env: CAPI_DIST / EDGE_LINE as in edge_inputs.py. Exit status is nonzero when any check fails."""
import json, os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I drops the script dir
from harness_common import signature_policy, PLUGINS, CLEAN_ENV, latest_cli, band_file

LINE = os.environ.get("EDGE_LINE", "15")
CLI, EXT = latest_cli(LINE), band_file(LINE)
if not CLI or not EXT:
    print("  FAIL need a DuckDB CLI and the built extension for line " + LINE); sys.exit(1)
ENT = PLUGINS.get("mock_enterprise")
if not ENT:
    print("  FAIL the mock enterprise core did not build"); sys.exit(1)

passes = fails = 0
def check(cond, what, detail=""):
    global passes, fails
    if cond: passes += 1
    else: fails += 1; print("  FAIL %s %s" % (what, ("-- " + str(detail)[:300]) if detail else ""))

def session(sql, env_extra=None, enterprise=True):
    """Runs the statements, one per line, in one CLI session without -bail. Returns (per-statement results, stderr) where a result is
    ('ok', csv-ish text) or ('err', message), in statement order."""
    env = dict(CLEAN_ENV); signature_policy(env)
    if enterprise:
        env["FRACTALSQL_ENTERPRISE_LIB"] = ENT
        env["FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE"] = "0"
    env.update(env_extra or {})
    stmts = [s for s in sql if s.strip()]
    results = []
    err_all = []
    # one process per scenario, but statements are separated by a marker so each result can be attributed
    # The session ends with fractal_release(): the extension's documented host contract for a session that is
    # about to close the database. Without it the host-departure monitor closes the extension's connections from
    # its own thread while the CLI tears the database down (an access violation at exit that a release build
    # masks and a sanitizer build names). The release carries its own marker, past the checked statements, and
    # its own error (it is refused while the destructive latch is set) is not one of theirs.
    script = ("LOAD '%s';\n" % EXT + "".join("SELECT '@@%d';\n%s\n" % (i, s) for i, s in enumerate(stmts))
              + "SELECT '@@%d';\nSELECT fractal_release();\n" % len(stmts))
    p = subprocess.run([CLI, "-unsigned", "-batch", "-csv", "-noheader"], input=script, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=300)
    out = p.stdout.split("\n")
    # stdout carries the successful results between markers; errors go to stderr in order, so attribute errors by counting
    chunks, cur = {}, None
    for line in out:
        m = re.match(r'^@@(\d+)$', line)
        if m: cur = int(m.group(1)); chunks[cur] = []
        elif cur is not None: chunks[cur].append(line)
    errs = [l for l in p.stderr.split("\n") if "Error:" in l and "fractal_release" not in l]
    ei = 0
    for i, _ in enumerate(stmts):
        body = "\n".join(l for l in chunks.get(i, []) if l.strip())
        if body: results.append(("ok", body))
        else:
            results.append(("err", errs[ei] if ei < len(errs) else "")); ei += 1
    return results, p.stderr

def js(text):
    try: return json.loads(text.strip().strip('"').replace('""', '"'))
    except ValueError: return None

# ---------------------------------------------------------------- appends, verify, anchor log
r, err = session(["SELECT fractal_audit_log('decision','{\"a\":1}');",
                  "SELECT fractal_audit_log('decision','{\"a\":2}','alice');",
                  "SELECT fractal_audit_log('review','[1,2,3]','bob');",
                  "SELECT fractal_ledger_verify(2);",
                  "SELECT fractal_ledger_verify();",
                  "SELECT fractal_ledger_verify(77);",
                  "SELECT fractal_ledger_verify(NULL);",
                  "SELECT fractal_audit_log(NULL,'{}');",
                  "SELECT fractal_audit_log('decision',NULL);"],
                 {"FSQL_LEDGER_ANCHOR_LOG": "stderr"})
check(all(x[0] == "ok" and x[1] == "true" for x in r[:3]), "three audit appends succeed", r[:3])
check(js(r[3][1]) == {"ok": True, "rows_verified": 3}, "the audit chain (kind 2) verifies with three rows", r[3])
check(js(r[4][1]) == {"ok": True, "rows_verified": 0}, "the default chain (kind 1) is empty and independent", r[4])
check(js(r[5][1]) == {"ok": True, "rows_verified": 0}, "an unused kind verifies as empty", r[5])
check(r[6] == ("ok", "NULL"), "a NULL kind gives NULL (the usual NULL-in, NULL-out)", r[6])
check(r[7] == ("ok", "") or r[7][0] == "ok", "a NULL entry type gives NULL, not an error", r[7])
heads = [json.loads(l) for l in err.split("\n") if l.startswith('{"event":"ledger_head"')]
check(len(heads) == 3, "one anchor line per append", len(heads))
check([h["rows"] for h in heads] == [1, 2, 3] and all(h["kind"] == 2 for h in heads), "anchor lines carry the kind and a growing row count", heads)
check(all(re.fullmatch(r"[0-9a-f]{64}", h["hash"]) for h in heads) and len({h["hash"] for h in heads}) == 3, "every anchored head is a distinct SHA-256", heads)

# ---------------------------------------------------------------- payload validation
r, _ = session(["SELECT fractal_audit_log('decision','not json');",
                "SELECT fractal_audit_log('decision','{\"a\":');",
                "SELECT fractal_audit_log('decision','{\"_actor\":\"mallory\"}');",
                "SELECT fractal_audit_log('decision','{\"x\":{\"_actor\":1}}');",
                "SELECT fractal_audit_log('decision','{\"a\":1}','');",
                "SELECT fractal_ledger_verify(2);"])
check(r[0][0] == "err" and "well-formed JSON" in r[0][1], "a payload that is not JSON is refused", r[0])
check(r[1][0] == "err" and "well-formed JSON" in r[1][1], "a truncated JSON payload is refused", r[1])
check(r[2][0] == "err" and "_actor" in r[2][1], "the reserved _actor key cannot be forged inside a payload", r[2])
check(r[3][0] == "err" and "_actor" in r[3][1], "...nor nested one level down", r[3])
check(r[4] == ("ok", "true"), "an empty actor is accepted", r[4])
check(js(r[5][1]) == {"ok": True, "rows_verified": 1}, "refused payloads add no row", r[5])

# ---------------------------------------------------------------- the size cap
rows = ["SELECT fractal_audit_log('decision','{\"n\":%d,\"pad\":\"%s\"}');" % (i, "x" * 60) for i in range(8)]
r, err = session(rows + ["SELECT fractal_ledger_verify(2);"], {"FSQL_DUCKDB_LEDGER_MAX_BYTES": "400"})
ok_n = sum(1 for x in r[:8] if x == ("ok", "true"))
check(0 < ok_n < 8, "with a 400-byte cap some appends fit and the rest are refused", [x[0] for x in r[:8]])
check(any("ledger is full" in l for l in err.split("\n")), "the refusal says the ledger is full")
v = js(r[8][1])
check(v == {"ok": True, "rows_verified": ok_n}, "the chain that was kept still verifies, with exactly the rows that fit", (v, ok_n))
r, _ = session(rows[:3] + ["SELECT fractal_ledger_verify(2);"], {"FSQL_DUCKDB_LEDGER_MAX_BYTES": "0"})
check(js(r[3][1]) == {"ok": True, "rows_verified": 3}, "a cap of 0 means unlimited", r)

# ---------------------------------------------------------------- the destructive latch
r, _ = session(["SELECT fractal_audit_log('decision','{\"a\":1}');",
                "SELECT fractal_lock_destructive();",
                "SELECT fractal_lock_destructive();",
                "SELECT fractal_ledger_flush();", "SELECT fractal_ledger_load();", "SELECT fractal_ledger_compact();",
                "SELECT fractal_ledger_reset_soft();", "SELECT fractal_ledger_reset_hard();",
                "SELECT fractal_audit_log('decision','{\"a\":2}');",
                "SELECT fractal_ledger_verify(2);", "SELECT fractal_ledger_truth_count();", "SELECT fractal_ledger_shadow_count();"])
check(r[1] == ("ok", "locked") and r[2] == ("ok", "locked"), "the latch can be set, and setting it again is harmless", r[1:3])
for i, name in zip(range(3, 9), ["flush", "load", "compact", "reset_soft", "reset_hard", "audit_log"]):
    check(r[i][0] == "err" and "locked" in r[i][1], "after the latch, %s is refused" % name, r[i])
check(js(r[9][1]) == {"ok": True, "rows_verified": 1}, "verify still works under the latch, and the refused append added nothing", r[9])
check(r[10] == ("ok", "7") and r[11] == ("ok", "3"), "the read-only counts still work under the latch", r[10:12])

# ---------------------------------------------------------------- the enterprise library
r, _ = session(["SELECT fractal_audit_log('decision','{}');", "SELECT fractal_ledger_flush();", "SELECT fractal_ledger_truth_count();",
                "SELECT fractal_ledger_verify(2);", "SELECT fractal_lock_destructive();"], enterprise=False)
for i, name in zip(range(3), ["audit_log", "flush", "truth_count"]):
    check(r[i][0] == "err" and "Enterprise tier" in r[i][1], "without the enterprise library %s says so" % name, r[i])
check(js(r[3][1]) == {"ok": True, "rows_verified": 0}, "verify is community-side: it works with no enterprise library", r[3])
check(r[4] == ("ok", "locked"), "the latch is community-side too", r[4])
r, err = session(["SELECT fractal_ledger_flush();"], {"FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE": "1"})
check(r[0][0] == "err" and "no signature found" in err, "an unsigned enterprise library is refused (and the reason logged) when a signature is required", (r[0], err[:200]))

# ---------------------------------------------------------------- anchor log modes
r, err = session(["SELECT fractal_audit_log('decision','{}');"], {"FSQL_LEDGER_ANCHOR_LOG": "off"})
check('"ledger_head"' not in err, "anchor log 'off' publishes nothing")
r, err = session(["SELECT fractal_audit_log('decision','{}');"], {"FSQL_LEDGER_ANCHOR_LOG": "STDERR"})
check('"ledger_head"' in err, "the anchor mode is case-insensitive")
r, err = session(["SELECT fractal_audit_log('decision','{}');"], {"FSQL_LEDGER_ANCHOR_LOG": "bogus"})
check('"ledger_head"' not in err and r[0] == ("ok", "true"), "an unknown anchor mode publishes nothing and does not break the append")

print("ledger sql: %d checks passed, %d failed" % (passes, fails))
sys.exit(1 if fails else 0)
