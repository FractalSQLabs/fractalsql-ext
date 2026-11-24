#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""agent_partial_reasoning_fail on DuckDB: off (the default) an agent raises when its reasoning step fails; on it keeps the computed half and
reports reasoning_step_failed. A local HTTP stub answers embeddings and fails every chat call, so the data step succeeds and only the
reasoning step fails.

usage: test_partial_reasoning.py   (env: CAPI_DIST / EDGE_LINE as in edge_inputs.py; the vendored fractalsql-reasoning-http.so is used)
"""
import glob, json, os, platform, subprocess, sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I drops the script dir
from harness_common import latest_cli, band_file

LINE = os.environ.get("EDGE_LINE", "15")
CLI, EXT = latest_cli(LINE), band_file(LINE)
if sys.platform == "win32":
    plugs = sorted(glob.glob(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "include", "windows-*", "fractalsql-reasoning-http.dll")))
elif sys.platform == "darwin":
    plugs = sorted(glob.glob(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "include", "darwin-*", "fractalsql-reasoning-http.dylib")))
else:
    plugs = sorted(glob.glob(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "include", "linux-" + ("aarch64" if platform.machine() in ("aarch64", "arm64") else "x86_64"), "fractalsql-reasoning-http.so")))
if not CLI or not EXT or not plugs:
    print("  SKIP need a DuckDB CLI, the built extension and the vendored http plugin"); sys.exit(0)
PLUG = plugs[0]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); self.rfile.read(n)
        if "embeddings" in self.path:
            body = json.dumps({"data": [{"embedding": [1.0, 0.1, 0.0], "index": 0}]}).encode(); code = 200
        else:
            body = b'{"error":"model unavailable"}'; code = 500
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)


srv = HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
port = srv.server_address[1]
env = dict(os.environ, FRACTALSQL_REASONING_PLUGIN=PLUG, FSQL_REASONING_HTTP_URL="http://127.0.0.1:%d/v1/chat/completions" % port,
           FSQL_REASONING_HTTP_EMBED_URL="http://127.0.0.1:%d/v1/embeddings" % port, FSQL_REASONING_HTTP_MODEL="m",
           FSQL_REASONING_HTTP_EMBED_MODEL="e", FSQL_REASONING_HTTP_ALLOW_PLAINTEXT="1", FRACTALSQL_REASONING_REQUIRE_SIGNATURE="0",
           FSQL_REASONING_REQUIRE_SIGNATURE="0")
for k in ("FRACTALSQL_AGENT_PARTIAL_REASONING_FAIL",):
    env.pop(k, None)
fails = []


def run(stmts):
    script = "LOAD '%s';\n%s\nSELECT fractal_release();\n" % (EXT, "\n".join(stmts))
    p = subprocess.run([CLI, "-unsigned", "-batch", "-csv", "-noheader"], input=script, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=120)
    return p.stdout, p.stderr


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)[:300]))
    if not cond: fails.append(name)


SETUP = ["CREATE TABLE pr_docs(id INTEGER, body VARCHAR, emb DOUBLE[]);",
         "INSERT INTO pr_docs VALUES (1,'a',[1.0,0.1,0.0]),(2,'b',[0.0,1.0,0.0]),(3,'c',[0.0,0.0,1.0]);"]
RAG = "SELECT answer, source_row_ids FROM fractal_rag_agent('q','pr_docs','emb','{}');"
ROUTE = "SELECT fractal_agent_route_task([1.0,0.1,0.0]::DOUBLE[],'pr_docs','emb','body',500);"
out, err = run(SETUP + [RAG])
check("rag_agent raises when the reasoning step fails (default off)", "reasoning" in err.lower() and "reasoning_step_failed" not in out, (out, err))
out, err = run(SETUP + ["SELECT fractal_config_set('agent_partial_reasoning_fail','on');", RAG])
check("rag_agent with the key on keeps the retrieval half and marks the failure", "reasoning_step_failed" in out and "[" in out, (out, err))
out, err = run(SETUP + ["SELECT fractal_config_set('agent_partial_reasoning_fail','off');", RAG])
check("setting the key back to off raises again", "reasoning" in err.lower() and "reasoning_step_failed" not in out, (out, err))
out, err = run(SETUP + ["SELECT fractal_config_set('agent_partial_reasoning_fail','sometimes');"])
check("a value that is not on/off is refused", "agent_partial_reasoning_fail" in err or "must be" in err, (out, err))
out, _ = run(["SELECT fractal_config_keys();"])
check("fractal_config_keys lists the key as a bool", '"agent_partial_reasoning_fail","type":"bool"' in out.replace('""', '"'), out)
out, err = run(SETUP + [ROUTE])
check("a domain agent (route_task) raises when the reasoning step fails (default off)", "reasoning" in err.lower() and "reasoning_step_failed" not in out, (out, err))
out, err = run(SETUP + ["SELECT fractal_config_set('agent_partial_reasoning_fail','on');", ROUTE])
check("a domain agent with the key on keeps its computed half and marks the failure", "reasoning_step_failed" in out, (out, err))
print("failed: %d" % len(fails))
sys.exit(1 if fails else 0)
