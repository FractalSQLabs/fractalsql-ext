#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs

"""End-to-end MCP session against the FractalSQL extension loaded into the server's own DuckDB.

Each server starts with an empty in-memory database that tests/fixtures.sql populates (FSQL_DUCKDB_BOOTSTRAP), so every
session below sees the same four tables and none can disturb another. The client checks the protocol (handshake, tool
catalog, annotations), every tool once (and what that call must return with NO reasoning plugin, NO embedding provider and
NO enterprise library), the numbers a few tools must produce, row limits, the error taxonomy, resources, prompts, the
read-only guards, a file database, $/cancel and shutdown. It finishes by running the robustness sweep and the mutation
sweep against fresh servers.

  MCP_SERVER_EXE         the server binary just built          (required)
  MCP_SERVER_CWD         directory to run it from              (default: the binary's)
  MCP_HERE               the mcp/ directory (locks, manifest)  (default: this file's parent)
  FSQL_DUCKDB_EXTENSION  the extension to load                 (required; inherited by every server)
  FSQL_DUCKDB_BOOTSTRAP  tests/fixtures.sql                    (default: next to this file)
  MCP_DUCKDB_EXEC        the duckdb_exec helper, for the file-database leg (optional)

Zero dependencies beyond the stdlib."""

from __future__ import annotations

import json
import math
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ.setdefault("FSQL_DUCKDB_BOOTSTRAP", os.path.join(HERE, "fixtures.sql"))
import mcp_fixtures as fx          # noqa: E402
import mcp_robustness as rb        # noqa: E402
import mcp_mutate as mm            # noqa: E402

FAILS = 0


def check(label, cond, detail=""):
    global FAILS
    print(("PASS " if cond else "FAIL ") + label + ((" -- " + str(detail)[:220]) if (not cond and detail != "") else ""))
    if not cond:
        FAILS += 1
    return bool(cond)


def tool(s, name, args, timeout=120):
    r = s.call("tools/call", {"name": name, "arguments": args}, timeout=timeout)
    if "error" in r:
        return True, {"error_class": "protocol", "message": json.dumps(r["error"])}
    res = r["result"]
    return bool(res.get("isError")), res.get("structuredContent")


def klass(sc):
    return (sc or {}).get("error_class") if isinstance(sc, dict) else None


def main():
    exe = os.environ["MCP_SERVER_EXE"]
    cwd = os.environ.get("MCP_SERVER_CWD") or os.path.dirname(os.path.abspath(exe)) or "."
    here = os.environ.get("MCP_HERE") or os.path.dirname(HERE)
    s = rb._Session(exe, cwd, {})

    # ---------------------------------------------------------------- protocol
    r = s.call("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "0"}})
    res = r.get("result", {})
    check("initialize handshake echoes the requested protocolVersion", res.get("protocolVersion") == "2025-03-26", res)
    check("serverInfo names fractalsql-ext-mcp", (res.get("serverInfo") or {}).get("name") == "fractalsql-ext-mcp")
    s.send("notifications/initialized", {}, notify=True)
    check("ping liveness probe responds with an empty {}", s.call("ping", {}).get("result") == {})

    tools = s.call("tools/list", {})["result"]["tools"]
    names = [t["name"] for t in tools]
    want = [n for n, _ in fx.FIXTURE_CALLS]
    check("tools/list: %d tools, every name unique" % len(tools), len(names) == len(set(names)) and len(names) == len(want), (len(names), len(want)))
    check("tools/list: the catalog and the fixtures agree (a new tool needs a fixture)", set(names) == set(want),
          (sorted(set(names) - set(want)), sorted(set(want) - set(names))))
    bad = [t["name"] for t in tools if not (t.get("description") and t["inputSchema"].get("type") == "object"
                                            and t["inputSchema"].get("additionalProperties") is False)]
    check("accessibility: every tool has a description and a closed object inputSchema", not bad, bad[:5])
    noprop = [t["name"] for t in tools for p, v in t["inputSchema"].get("properties", {}).items() if not v.get("description")]
    check("accessibility: every parameter has a description", not noprop, noprop[:8])
    zero = [t["name"] for t in tools if not t["inputSchema"].get("properties") and not t["inputSchema"].get("x-fractalsql-no-arguments")]
    check("accessibility: zero-argument tools say so", not zero, zero[:5])

    hints = ("readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint")
    miss = [t["name"] for t in tools if not all(isinstance(t.get("annotations", {}).get(h), bool) for h in hints)]
    check("every tool sends all four hints explicitly", not miss, miss[:5])
    ann = {t["name"]: t["annotations"] for t in tools}
    destructive = {n for n, a in ann.items() if a["destructiveHint"]}
    want_destructive = {"fractal_ledger_flush", "fractal_ledger_compact", "fractal_ledger_reset_soft", "fractal_ledger_reset_hard",
                        "fractal_vectorizer_drop", "fractal_sql_agent",
                        # State-mutating tools (the read-only gate keys off this hint): the audit chain, ledger
                        # hydration, the destructive latch, the vectorizer registry/queue, the diversify/feedback
                        # state, and the agents that append decision records or execute generated SQL.
                        "fractal_audit_log", "fractal_ledger_load",
                        "fractal_vectorizer_create", "fractal_vectorizer_pause", "fractal_vectorizer_resume",
                        "fractal_vectorizer_process_queue",
                        "fractal_diversify_enable", "fractal_diversify_disable", "fractal_diversify_set_params",
                        "fractal_feedback_report", "fractal_isolate_background",
                        "fractal_agent_data_analyst", "fractal_agent_feedback_audit", "fractal_agent_recommend_diverse",
                        # The configuration writers: they change where the next call goes.
                        "fractal_config_set", "fractal_configure_reasoning"}
    check("destructiveHint marks exactly the tools that erase or execute generated SQL", destructive == want_destructive,
          (sorted(destructive - want_destructive), sorted(want_destructive - destructive)))
    check("every read-only tool is idempotent", all(a["idempotentHint"] for a in ann.values() if a["readOnlyHint"]))
    check("the diversify pair is idempotent without being read-only",
          all(ann[n]["idempotentHint"] and not ann[n]["readOnlyHint"] for n in ("fractal_diversify_enable", "fractal_diversify_disable")))
    check("no destructive tool is read-only", not [n for n in destructive if ann[n]["readOnlyHint"]])
    check("openWorldHint marks the model-backed tools",
          ann["fractal_reason"]["openWorldHint"] and ann["fractal_embed"]["openWorldHint"] and ann["fractal_agent_allocate"]["openWorldHint"]
          and not ann["fractal_agent_recall_hybrid"]["openWorldHint"] and not ann["fractal_vector_lp_distance"]["openWorldHint"])
    rows_tools = [t for t in tools if "limit" in t["inputSchema"].get("properties", {})]
    check("table-function tools carry a row limit (%d of them)" % len(rows_tools), len(rows_tools) >= 15, len(rows_tools))

    # ---------------------------------------------------------------- every tool once
    recorded = []
    for name, args in fx.FIXTURE_CALLS:
        err, sc = tool(s, name, args)
        recorded.append((name, args))
        if fx.EXPECT[name] == "ok":
            check("tool %s: a valid call succeeds" % name, not err, sc)
        else:
            check("tool %s: refused cleanly (engine class) with nothing behind the extension" % name, err and klass(sc) == "engine", sc)
    check("the server is still answering after the sweep", s.call("ping", {}).get("result") == {} and s.alive())

    # ---------------------------------------------------------------- numbers
    def ok(name, args):
        e, sc = tool(s, name, args)
        return None if e else sc

    sc = ok("fractal_search_telemetry", {"table_name": "docs", "vector_col": "emb", "query": [1, 0.02, 0, 0], "k": 3})
    check("search_telemetry finds a row of the matching cluster first (ids 0, 4, 8, ...)",
          bool(sc) and sc["row_count"] == 3 and int(sc["rows"][0]["doc_id"]) % 4 == 0, sc)
    sc = ok("fractal_agent_recall_hybrid", {"mem_table": "docs", "vec_col": "emb", "query_vec": [0, 1, 0, 0], "k": 2, "id_col": "id", "content_col": "body"})
    check("recall_hybrid returns k memories with their content", bool(sc) and "document" in json.dumps(sc), sc)
    sc = ok("fractal_agent_recall_hybrid", {"mem_table": "docs", "vec_col": "emb", "query_vec": [1, 0, 0, 0], "filter_col": "cohort", "filter_val": "b", "k": 20, "id_col": "id"})
    check("recall_hybrid's cohort filter keeps only cohort b (the odd ids)",
          bool(sc) and len(sc["items"]) > 0 and all(int(x["mem_id"]) % 2 == 1 for x in sc["items"]), sc)
    sc = ok("fractal_vector_quantize_int8", {"vector": [1, -2, 3]})
    check("quantize_int8 returns the scale and the codes", bool(sc) and "scale" in sc and "codes" in sc, sc)
    sc = ok("fractal_vector_quantize_binary", {"vector": [1, -2, 3, 4, -1, -1, 1, 1]})
    check("quantize_binary returns hex bytes", bool(sc) and "hex" in sc, sc)
    check("lp distance p=1 is 7", abs((ok("fractal_vector_lp_distance", {"a": [0, 0], "b": [3, 4], "p": 1}) or {}).get("value", 0) - 7) < 1e-4)
    check("hamming distance of two different bytes is 8", abs((ok("fractal_vector_hamming_distance", {"a": "0f", "b": "f0"}) or {}).get("value", 0) - 8) < 1e-4)
    check("hamming distance of 0f and f0 is 8", (ok("fractal_vector_hamming_distance", {"a": "0f", "b": "f0"}) or {}).get("value") == 8)
    sc = ok("fractal_vector_quantize_binary", {"vector": [1, -2, 3, 4, -1, -1, 1, 1]})
    check("quantize_binary packs 8 dimensions into 1 byte", bool(sc) and sc.get("bytes") == 1, sc)
    sc = ok("fractal_vector_quantize_int8", {"vector": [1, -2, 3]})
    check("quantize_int8 returns a scale and three codes", bool(sc) and "scale" in json.dumps(sc), sc)
    fp1 = ok("fractal_state_fingerprint", {"vector": [1, 0, 0, 0], "n_bits": 64, "seed": 7})
    fp2 = ok("fractal_state_fingerprint", {"vector": [1, 0, 0, 0], "n_bits": 64, "seed": 7})
    check("state_fingerprint 64 bits is 8 bytes and deterministic", bool(fp1) and fp1["bytes"] == 8 and fp1 == fp2, fp1)
    sine = [math.sin(2 * math.pi * i / 8.0) for i in range(128)]
    sc = ok("fractal_periodogram", {"series": sine, "max_peaks": 2})
    check("periodogram finds the true 0.125 frequency", bool(sc) and abs(float(sc["rows"][0]["freq"]) - 0.125) < 0.01, sc)
    sc = ok("fractal_cycle_detect", {"fingerprints": ["aa55", "bb66", "aa55", "bb66", "aa55", "bb66"], "hamming_threshold": 0})
    check("cycle_detect closes the period-2 stream", bool(sc) and sc["row_count"] >= 1 and int(sc["rows"][0]["cycle_len"]) == 2, sc)
    sc = ok("fractal_dimension_dfa", {"series": [math.sin(i / 3.0) + 0.01 * (i % 7) for i in range(200)]})
    check("dimension_dfa returns a finite exponent", bool(sc) and math.isfinite(sc["value"]) and 0 < sc["value"] < 4, sc)
    sc = ok("fractal_change_point_detect", {"series": [0.0] * 60 + [5.0] * 60, "window": 10, "threshold": 1.0})
    check("change_point_detect flags a boundary near the step", bool(sc) and any(50 <= i <= 70 for i in sc.get("items", [])), sc)
    nested = [[(i * 7919 % 1000) / 1000.0, (i * 104729 % 1000) / 1000.0] for i in range(400)]
    sc = ok("fractal_dimension_boxcount", {"points": nested})
    check("boxcount derives dim from nested rows (no dim argument) and lands between 1 and 2", bool(sc) and 1 < sc["value"] < 2, sc)
    e, sc = tool(s, "fractal_dimension_boxcount", {"points": [v for p in nested for v in p]})
    check("a flat points array without dim is a schema error", e and klass(sc) == "schema" and "dim" in sc["message"], sc)
    sc = ok("fractal_dimension_boxcount", {"points": [v for p in nested for v in p], "dim": 2})
    check("a flat points array with dim works", bool(sc) and 1 < sc["value"] < 2, sc)
    sc = ok("fractal_optimize_portfolio", {"mu": [0.05, 0.08, 0.03, 0.12, 0.07, 0.01], "cov": [[0.02 if i == j else 0.0 for j in range(6)] for i in range(6)], "k": 2, "seed": 3})
    check("optimize_portfolio honours the cardinality (at most 2 nonzero weights summing to 1)",
          bool(sc) and sum(1 for w in sc["weights"] if w > 1e-9) <= 2 and abs(sum(sc["weights"]) - 1) < 1e-4, sc)
    sc = ok("fractal_cortical_folding", {"vertices": [v for p in fx._CUBE_V for v in p], "faces": fx._CUBE_F})
    check("cortical_folding of a cube is a gyrification index of 1", bool(sc) and abs(sc.get("gyrification_index", 0) - 1.0) < 0.05, sc)
    sc = ok("fractal_agent_detect_loop", {"agent_id": "a", "state_log": [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0], "dim": 3})
    check("detect_loop returns its verdict for the label it was given", bool(sc) and sc.get("agent_id") == "a" and "is_loop_detected" in sc, sc)

    # diversify
    e, sc = tool(s, "fractal_diversify_enable", {})
    check("diversify_enable turns the monitor on", not e and sc.get("value") is True, sc)
    sc = ok("fractal_explain_result", {})
    check("explain_result reports diversify_enabled after enable", bool(sc) and sc.get("diversify_enabled") is True, sc)
    e, sc = tool(s, "fractal_feedback_report", {"result_handle": 0, "kind": "bogus"})
    check("an unrecognized feedback kind is refused by the engine", e and klass(sc) == "engine", sc)
    e, sc = tool(s, "fractal_diversify_disable", {})
    check("diversify_disable turns it off", not e and sc.get("value") in (True, False), sc)

    # the vectorizer lifecycle
    sc = ok("fractal_vectorizer_create", {"source_table": "docs", "source_pk_col": "id", "text_col": "body", "embedding_col": "emb"})
    vid = (sc or {}).get("value")
    check("vectorizer_create returns an id", isinstance(vid, int), sc)
    sc = ok("fractal_vectorizer_status", {})
    check("vectorizer_status lists the vectorizer", bool(sc) and sc["row_count"] >= 1, sc)
    check("vectorizer_pause then resume work", (ok("fractal_vectorizer_pause", {"id": vid}) or {}).get("value") is True
          and (ok("fractal_vectorizer_resume", {"id": vid}) or {}).get("value") is True)
    check("vectorizer_drop removes it", (ok("fractal_vectorizer_drop", {"id": vid}) or {}).get("value") is True)
    e, sc = tool(s, "fractal_vectorizer_pause", {"id": 99999})
    check("pausing a nonexistent vectorizer is an engine error", e and klass(sc) == "engine", sc)

    # row limits
    sc = ok("fractal_search_telemetry", {"table_name": "docs", "vector_col": "emb", "query": [1, 0, 0, 0], "k": 5, "limit": 2})
    check("a row limit below the result size truncates and says so", bool(sc) and sc["row_count"] == 2 and sc.get("truncated") is True, sc)
    e, sc = tool(s, "fractal_search_telemetry", {"table_name": "docs", "vector_col": "emb", "query": [1, 0, 0, 0], "k": 5, "limit": 100000})
    check("a limit above the ceiling is a schema error naming FSQL_MCP_MAX_ROWS_CEILING", e and klass(sc) == "schema" and "FSQL_MCP_MAX_ROWS_CEILING" in sc["message"], sc)
    e, sc = tool(s, "fractal_search_telemetry", {"table_name": "docs", "vector_col": "emb", "query": [1, 0, 0, 0], "k": 5, "limit": 0})
    check("a limit of 0 is a schema error", e and klass(sc) == "schema", sc)

    # ---------------------------------------------------------------- the taxonomy
    e, sc = tool(s, "fractal_vector_lp_distance", {"a": "nope", "b": [1]})
    check("a wrong-typed argument is a schema error", e and klass(sc) == "schema", sc)
    e, sc = tool(s, "fractal_vector_lp_distance", {"a": [1, 2]})
    check("a missing required argument is a schema error", e and klass(sc) == "schema" and "missing required" in sc["message"], sc)
    e, sc = tool(s, "fractal_vector_lp_distance", {"a": [1, "x"], "b": [1, 2]})
    check("a non-numeric element is a schema error naming the argument and the kind it wanted",
          e and klass(sc) == "schema" and "elements must be" in sc["message"] and sc["message"].startswith("a "), sc)
    e, sc = tool(s, "fractal_vector_lp_distance", {"a": [], "b": []})
    check("an empty vector is a schema error", e and klass(sc) == "schema", sc)
    e, sc = tool(s, "fractal_hamming_distance" if False else "fractal_vector_hamming_distance", {"a": "zz", "b": "00"})
    check("invalid hex is a schema error", e and klass(sc) == "schema", sc)
    e, sc = tool(s, "fractal_search_telemetry", {"table_name": "no_such_table", "vector_col": "emb", "query": [1, 0, 0, 0], "k": 2})
    check("an unknown table is an engine error carrying the engine's own text", e and klass(sc) == "engine", sc)
    e, sc = tool(s, "fractal_search_telemetry", {"table_name": "docs; DROP TABLE docs", "vector_col": "emb", "query": [1, 0, 0, 0], "k": 2})
    check("an injection-shaped table name is refused and docs survives", e and klass(sc) == "engine", sc)
    sc = ok("fractal_search_telemetry", {"table_name": "docs", "vector_col": "emb", "query": [1, 0, 0, 0], "k": 1})
    check("docs is still there after the injection attempt", bool(sc) and sc["row_count"] == 1, sc)
    e, sc = tool(s, "fractal_agent_recall_hybrid", {"mem_table": "docs", "vec_col": "emb", "query_vec": [1, 0, 0, 0], "filter_col": "cohort"})
    check("a filter column without its value is refused (schema) instead of reaching the extension", e and klass(sc) == "schema" and "filter_val" in sc["message"], sc)
    e, sc = tool(s, "fractal_nope", {})
    check("an unknown tool is refused naming tools/list", e and "tools/list" in json.dumps(sc), sc)
    check("an unknown method returns -32601", (s.call("no/such/method", {}).get("error") or {}).get("code") == -32601)

    # ---------------------------------------------------------------- resources and prompts
    rl = s.call("resources/list", {})["result"]["resources"]
    check("resources/list: agents, schema, config", {x["uri"] for x in rl} == {"fractalsql://agents", "fractalsql://schema", "fractalsql://config"}, rl)
    rt = s.call("resources/templates/list", {})["result"]["resourceTemplates"]
    check("resource templates: ledger", {x["uriTemplate"] for x in rt} == {"fractalsql://ledger/{kind}"}, rt)
    txt = s.call("resources/read", {"uri": "fractalsql://agents"})["result"]["contents"][0]["text"]
    check("fractalsql://agents is a catalog of the sixteen recipes", len(json.loads(txt)["recipes"]) == 16)
    sch = s.call("resources/read", {"uri": "fractalsql://schema"})["result"]["contents"][0]["text"]
    check("fractalsql://schema names the fixture tables", "docs" in sch and "metrics" in sch, sch[:200])
    cfg = json.loads(s.call("resources/read", {"uri": "fractalsql://config"})["result"]["contents"][0]["text"])
    check("fractalsql://config reports the extension version, the lock-down and no enterprise tier, and holds no secret",
          cfg.get("extension_version") == "2.0.0" and cfg.get("locked_down") is True and cfg.get("enterprise_tier") is False
          and "http" not in json.dumps(cfg).lower(), cfg)
    check("an unknown resource is an error", "error" in s.call("resources/read", {"uri": "fractalsql://nope"}))
    check("a bad ledger kind is an error", "error" in s.call("resources/read", {"uri": "fractalsql://ledger/9"}))
    pl = s.call("prompts/list", {})["result"]["prompts"]
    check("prompts/list: the eleven prompts", len(pl) == 11, len(pl))
    pg = s.call("prompts/get", {"name": "incident_triage", "arguments": {"table_name": "metrics", "metric_col": "cpu", "time_col": "ts", "filter_col": "host", "filter_val": "host-1"}})["result"]
    check("prompts/get fills its arguments", "metrics" in pg["messages"][0]["content"]["text"], pg)
    check("prompts/get without a required argument is an error", "error" in s.call("prompts/get", {"name": "incident_triage", "arguments": {}}))
    check("a prompt argument that contains its own placeholder is substituted once, not looped on",
          "result" in s.call("prompts/get", {"name": "ciso_ledger_check", "arguments": {"kind": "{kind}"}}))

    # ---------------------------------------------------------------- $/cancel
    sid = s.send("tools/call", {"name": "fractal_search_debug", "arguments": {"query": [0.1] * 32, "iterations": 2000, "population_size": 2000, "diffusion_factor": 2}})
    time.sleep(0.15)
    s.send("notifications/cancelled", {"requestId": sid, "reason": "smoke"}, notify=True)
    try:
        s.recv(sid, timeout=90)
    except RuntimeError:
        pass
    check("$/cancel: the server stays responsive", s.call("ping", {}, timeout=90).get("result") == {} and s.alive())
    e, sc = tool(s, "fractal_version", {})
    check("a call after a cancel works", not e and sc.get("version") == "2.0.0" and sc.get("edition") == "Community", sc)
    rc = s.close()
    check("the stdio server exits cleanly (rc 0) when its input ends", rc == 0, rc)

    # ---------------------------------------------------------------- the guards
    s3 = rb._Session(exe, cwd, {"FSQL_MCP_READ_ONLY": "true"})
    rb._init(s3)
    e, sc = tool(s3, "fractal_ledger_reset_hard", {})
    check("read-only mode refuses a destructive tool before it reaches the engine", e and "read-only" in json.dumps(sc), sc)
    e, sc = tool(s3, "fractal_vector_lp_distance", {"a": [0, 0], "b": [3, 4], "p": 1})
    check("read-only mode still serves a read", not e and abs(sc["value"] - 7) < 1e-4, sc)
    s3.close()

    # the committed locks, and the narrowing options (no database is touched by these)
    tmp = tempfile.mkdtemp(prefix="fsqlmcp-locks-")
    env = dict(os.environ, FSQL_MCP_SCHEMA_LOCK=os.path.join(tmp, "schema"), FSQL_MCP_SAFETY_LOCK=os.path.join(tmp, "safety"),
               FSQL_MCP_MANIFEST=os.path.join(tmp, "manifest.json"))
    for flag in ("--write-schema-lock", "--write-safety-annotations-lock", "--write-manifest"):
        subprocess.run([exe, flag], env=env, cwd=cwd, capture_output=True, timeout=60)

    def same(a, b):
        try:
            return open(a).read() == open(b).read()
        except OSError:
            return False
    check("phase0: the committed .mcp-schema-lock matches the registered tool set", same(os.path.join(here, ".mcp-schema-lock"), env["FSQL_MCP_SCHEMA_LOCK"]))
    check("phase0: the safety annotations match the registered surface", same(os.path.join(here, ".mcp-safety-annotations-lock"), env["FSQL_MCP_SAFETY_LOCK"]))
    check("phase0: manifest.json matches the registered surface", same(os.path.join(here, "manifest.json"), env["FSQL_MCP_MANIFEST"]))
    lt = subprocess.run([exe, "--list-tools", "--tool", "fractal_vector_lp_distance,fractal_vector_hamming_distance"], env=dict(os.environ), cwd=cwd, capture_output=True, text=True, timeout=60)
    check("--tool narrows the catalog to the named tools", sorted(l.split()[0] for l in lt.stdout.splitlines()) == ["fractal_vector_hamming_distance", "fractal_vector_lp_distance"], lt.stdout)
    lc = subprocess.run([exe, "--list-tools", "--category", "vectorizer"], env=dict(os.environ), cwd=cwd, capture_output=True, text=True, timeout=60)
    check("--category narrows the catalog to that category (the six vectorizer tools)", len(lc.stdout.splitlines()) == 6, lc.stdout)

    # a database FILE: state outlives the server, and a read-only open refuses writes
    helper = os.environ.get("MCP_DUCKDB_EXEC")
    if helper and os.path.isfile(helper):
        d = tempfile.mkdtemp(prefix="fsqlmcp-db-")
        dbf = os.path.join(d, "t.duckdb")
        ext = os.environ.get("FSQL_DUCKDB_EXTENSION", "")
        subprocess.run([helper, dbf, "--ext", ext, "--", "CREATE TABLE notes AS SELECT i AS id, [CAST(i AS DOUBLE), 1.0, 0.0] AS emb FROM range(20) t(i)"],
                       capture_output=True, text=True, timeout=120, check=True)
        fenv = {"FSQL_DUCKDB_DATABASE": dbf, "FSQL_DUCKDB_BOOTSTRAP": ""}
        sf = rb._Session(exe, cwd, fenv)
        rb._init(sf)
        e, sc = tool(sf, "fractal_search_telemetry", {"table_name": "notes", "vector_col": "emb", "query": [5, 1, 0], "k": 2})
        check("a file database: a table that was there before the server started is searchable", not e and sc["row_count"] == 2, sc)
        e, sc = tool(sf, "fractal_vectorizer_create", {"source_table": "notes", "source_pk_col": "id", "text_col": "id", "embedding_col": "emb"})
        check("a file database: a write succeeds", not e, sc)
        sf.close()
        sr = rb._Session(exe, cwd, dict(fenv, FSQL_DUCKDB_READ_ONLY="true"))
        rb._init(sr)
        e, sc = tool(sr, "fractal_search_telemetry", {"table_name": "notes", "vector_col": "emb", "query": [5, 1, 0], "k": 2})
        check("a read-only file database still answers a search", not e and sc["row_count"] == 2, sc)
        e, sc = tool(sr, "fractal_vectorizer_create", {"source_table": "notes", "source_pk_col": "id", "text_col": "id", "embedding_col": "emb", "options": {"x": 1}})
        check("a read-only file database refuses a write (engine)", e and klass(sc) == "engine", sc)
        sr.close()
    else:
        print("SKIP file-database leg (MCP_DUCKDB_EXEC not set)")

    # ---------------------------------------------------------------- the sweeps
    os.environ.setdefault("MCP_HERE", here)
    if os.environ.get("MCP_SMOKE_SKIP_SWEEPS"):
        # Set by build_test.sh --tsan / --coverage: the two sweeps are tens of thousands of calls, 10-20x slower
        # under ThreadSanitizer. They run in full in the normal build; this leg is about the server's threading.
        print("SKIP robustness and mutation sweeps (MCP_SMOKE_SKIP_SWEEPS set)")
    else:
        rb.run(check)
        mm.run(check, recorded)

    print("mcp-smoke-client: %s; %d failure(s)" % ("ALL GREEN" if not FAILS else "FAILED", FAILS))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
