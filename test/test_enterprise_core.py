#!/usr/bin/env python3
"""test/test_enterprise_core.py -- the extension with an enterprise core library loaded: the REAL one when FSQL_TEST_ENTERPRISE_LIB names it
(an absolute path to libfractalsql-enterprise-*-c with its .sig beside it), otherwise the harness's mock core. Checks that only the real
library can answer (the Pareto frontier, the signature) run only with it.

With the library loaded this checks: the
gated functions are live (the Pareto frontier, the audit chain), the chain verifies, a flush in one session is restored by a load in
the next one (the ledger lives in the database file), both retention modes are accepted by the core, the signature is checked, and the
retrieval features (fractal_index_ensure, agent_use_index, recall_hybrid) behave the same with the enterprise tier active.

Env: CAPI_DIST / EDGE_LINE as in edge_inputs.py. Exit status is nonzero when any check fails."""
import json, os, re, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I drops the script dir
from harness_common import signature_policy, CLEAN_ENV, latest_cli, band_file, timeout_for, PLUGINS

LINE = os.environ.get("EDGE_LINE", "15")
CLI, EXT = latest_cli(LINE), band_file(LINE)
LIB = os.environ.get("FSQL_TEST_ENTERPRISE_LIB", "")
if not CLI or not EXT:
    print("  FAIL need a DuckDB CLI and the built extension for line " + LINE); sys.exit(1)
REAL = bool(LIB) and os.path.isfile(LIB)
if not REAL:
    LIB = PLUGINS.get("mock_enterprise", "")
    if not LIB:
        print("  FAIL no enterprise core: set FSQL_TEST_ENTERPRISE_LIB, or the mock core did not build"); sys.exit(1)
KIND = "real" if REAL else "mock"

passes = fails = 0
def check(cond, what, detail=""):
    global passes, fails
    if cond: passes += 1
    else: fails += 1; print("  FAIL %s %s" % (what, ("-- " + str(detail)[:300]) if detail else ""))

DB = os.path.join(tempfile.mkdtemp(prefix="fsql_entreal_"), "e.duckdb")

def session(sql, env_extra=None, db=None):
    """One CLI session; returns [('ok', text) | ('err', message)] per statement, in order, and stderr."""
    env = dict(CLEAN_ENV); signature_policy(env)
    env["FRACTALSQL_ENTERPRISE_LIB"] = LIB
    if not REAL or not os.path.isfile(LIB + ".sig"):
        env["FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE"] = "0"
    env.update(env_extra or {})
    stmts = [s for s in sql if s.strip()]
    script = ("LOAD '%s';\n" % EXT + "".join("SELECT '@@%d';\n%s\n" % (i, s) for i, s in enumerate(stmts))
              + "SELECT '@@%d';\nSELECT fractal_release();\n" % len(stmts))
    args = [CLI, "-unsigned", "-batch", "-csv", "-noheader"] + ([db] if db else [])
    p = subprocess.run(args, input=script, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=timeout_for(300))
    chunks, cur = {}, None
    for line in p.stdout.split("\n"):
        m = re.match(r'^@@(\d+)$', line)
        if m: cur = int(m.group(1)); chunks[cur] = []
        elif cur is not None: chunks[cur].append(line)
    errs = [l for l in p.stderr.split("\n") if "Error:" in l and "fractal_release" not in l]
    ei, results = 0, []
    for i, _ in enumerate(stmts):
        body = "\n".join(l for l in chunks.get(i, []) if l.strip())
        if body: results.append(("ok", body))
        else:
            results.append(("err", errs[ei] if ei < len(errs) else "")); ei += 1
    return results, p.stderr

def js(text):
    try: return json.loads(text.strip().strip('"').replace('""', '"'))
    except ValueError: return None

# ---------------------------------------------------------------- the gated functions are live
if REAL:
    r, _ = session(["SELECT * FROM fractal_optimize_portfolio_multimodal_pareto([0.10, 0.12]::DOUBLE[], [0.04, 0.01, 0.01, 0.03]::DOUBLE[], 1);"])
    check(r[0][0] == "ok" and "Enterprise tier" not in r[0][1], "the Pareto frontier runs with the core (it is gated without one)", r[0])
# the ledger is in memory and per connection (by design: no cross-process durability), so the round trip is one session
r, _ = session(["SELECT fractal_audit_log('decision','{\"a\":1}');", "SELECT fractal_audit_log('review','{\"a\":2}','alice');",
                "SELECT fractal_ledger_verify(2);", "SELECT fractal_ledger_flush();", "SELECT fractal_ledger_load();",
                "SELECT fractal_ledger_verify(2);", "SELECT fractal_ledger_flush();", "SELECT fractal_ledger_load();",
                "SELECT fractal_ledger_verify(2);"])
check(r[0] == ("ok", "true") and r[1] == ("ok", "true"), "audit appends succeed through the core", r[:2])
check(js(r[2][1]) == {"ok": True, "rows_verified": 2}, "the audit chain verifies with two rows", r[2])
check(r[3] == ("ok", "true"), "the ledger flushes", r[3])
check(r[4] == ("ok", "true") and js(r[5][1]) == {"ok": True, "rows_verified": 2}, "the ledger loads back and the chain is unchanged", r[4:6])
check(r[6] == ("ok", "true") and r[7] == ("ok", "true") and js(r[8][1]) == {"ok": True, "rows_verified": 2},
      "flushing and loading again does not inflate the chain", r[6:9])

# ---------------------------------------------------------------- retention modes (fade | exact) against the core
r, _ = session(["SELECT fractal_config_set('ledger_retention', 'exact');", "SELECT fractal_ledger_truth_count();",
                "SELECT fractal_config_set('ledger_retention', 'fade');", "SELECT fractal_ledger_truth_count();"])
check(r[0] == ("ok", "true") and r[1][0] == "ok", "ledger_retention exact is accepted by the core", r[:2])
check(r[2] == ("ok", "true") and r[3][0] == "ok", "...and fade again", r[2:4])
r, _ = session(["SELECT fractal_ledger_truth_count();"], {"FRACTALSQL_LEDGER_RETENTION": "exact"})
check(r[0][0] == "ok", "the exact mode set by the environment reaches the core's context", r[0])

# ---------------------------------------------------------------- QTL v2 through the REAL core: what a flush stores, and what a load puts back
# (the mock core cannot show the ledger's content, so these run only with the real library)
if REAL:
    r, _ = session(["SELECT fractal_feedback_report(2,'positive');", "SELECT fractal_feedback_report(1,'negative');",
                    "SELECT fractal_ledger_truth_count() || ',' || fractal_ledger_shadow_count();", "SELECT fractal_ledger_flush();",
                    "SELECT fractal_feedback_report(3,'negative');", "SELECT fractal_ledger_truth_count() || ',' || fractal_ledger_shadow_count();",
                    "SELECT fractal_ledger_load();", "SELECT fractal_ledger_truth_count() || ',' || fractal_ledger_shadow_count();"])
    check(r[2][0] == "ok" and r[2][1].strip('"') == "1,1", "feedback produces one truth and one shadow entry", r[2])
    check(r[5][0] == "ok" and r[5][1].strip('"') == "1,2", "a further negative feedback adds a shadow entry", r[5])
    check(r[6] == ("ok", "true") and r[7][0] == "ok" and r[7][1].strip('"') == "1,1",
          "load REPLACES the in-memory ledgers with the flushed blob (the entry added after the flush is gone)", r[6:8])
    for mode in ("fade", "exact"):
        r, _ = session(["SELECT fractal_config_set('ledger_retention','%s');" % mode, "SELECT fractal_feedback_report(2,'positive');",
                        "SELECT fractal_feedback_report(1,'negative');", "SELECT fractal_ledger_flush();", "SELECT fractal_ledger_load();",
                        "SELECT fractal_ledger_truth_count() || ',' || fractal_ledger_shadow_count();"])
        check(r[5][0] == "ok" and r[5][1].strip('"') == "1,1", "retention %s: a flush and a load keep the entries" % mode, r)
    r, _ = session(["SELECT fractal_config_set('ledger_retention','forever');"])
    check(r[0][0] == "err" and "fade, exact" in r[0][1], "an unknown ledger_retention value is refused", r[0])

# ---------------------------------------------------------------- the latch still holds with the core
r, _ = session(["SELECT fractal_lock_destructive();", "SELECT fractal_ledger_reset_hard();", "SELECT fractal_audit_log('decision','{}');",
                "SELECT fractal_ledger_verify(2);"])
check(r[0] == ("ok", "locked") and r[1][0] == "err" and "locked" in r[1][1] and r[2][0] == "err", "the destructive latch refuses a reset and an append", r[:3])

# ---------------------------------------------------------------- the signature is checked
if REAL:
    r, err = session(["SELECT fractal_ledger_flush();"], {"FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE": "1"})
    if os.path.isfile(LIB + ".sig"):
        check(r[0] == ("ok", "true"), "the signed real library is accepted when a signature is required", (r[0], err[:200]))
    bad = os.path.join(os.path.dirname(DB), "tampered.so")
    with open(LIB, "rb") as f, open(bad, "wb") as g: g.write(f.read() + b"x")
    if os.path.isfile(LIB + ".sig"):
        with open(LIB + ".sig", "rb") as f, open(bad + ".sig", "wb") as g: g.write(f.read())
        r, err = session(["SELECT fractal_ledger_flush();"], {"FRACTALSQL_ENTERPRISE_LIB": bad, "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE": "1"})
        check(r[0][0] == "err" and "signature" in (r[0][1] + err).lower(), "a tampered library is refused", (r[0], err[:200]))


# ---------------------------------------------------------------- retrieval with the enterprise tier active
VEC = lambda i: "[%s]" % ",".join(repr(round(((i * 7 + j * 3) % 11) / 11.0 + 0.01 * i, 6)) for j in range(6))
rows = ",".join("(%d,%s,'%s')" % (i, VEC(i), "even" if i % 2 == 0 else "odd") for i in range(1, 61))
RECALL = "SELECT fractal_agent_recall_hybrid('ent_docs','v',%s::DOUBLE[],NULL,NULL,5,'id');" % VEC(7)
r, _ = session(["CREATE OR REPLACE TABLE ent_docs(id INTEGER PRIMARY KEY, v DOUBLE[], grp VARCHAR);", "INSERT INTO ent_docs VALUES " + rows + ";",
                "SELECT json_extract_string(fractal_index_ensure('ent_docs','v','{\"name\":\"ent_ix\",\"vector_format\":\"FP32\",\"nlist\":4}'), '$.action');",
                "SELECT json_extract_string(fractal_index_ensure('ent_docs','v'), '$.action');"], db=DB)
if r[2][0] == "err" and "IVF" in r[2][1]:
    print("  SKIP the retrieval checks (this core does not carry the IVF index)")
else:
    check(r[2] == ("ok", "created") and r[3] == ("ok", "unchanged"), "fractal_index_ensure creates and then leaves the index (enterprise active)", r[2:4])
    off, _ = session([RECALL], db=DB)
    on, _ = session([RECALL, "SELECT coalesce(fractal_index_info('ent_ix')::JSON->>'$.last_search.used_index','none');"],
                    {"FRACTALSQL_AGENT_USE_INDEX": "on"}, db=DB)
    check(off[0][0] == "ok" and on[0][0] == "ok" and on[1] == ("ok", "true"), "recall_hybrid goes through the index with the enterprise tier active", (off[0], on))
    ids = lambda t: re.findall(r'mem_id""?:(\d+)', t)
    check(ids(off[0][1])[:1] == ids(on[0][1])[:1], "...and finds the same nearest row as the scan", (ids(off[0][1]), ids(on[0][1])))

print("enterprise core: %d checks passed, %d failed (%s core)" % (passes, fails, KIND))
sys.exit(1 if fails else 0)
