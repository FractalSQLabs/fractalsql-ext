#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/fractalsqlabs
"""test/id_emission.py -- how the domain agents write a row's id into their JSON result.

The id column is the caller's data, so what an agent writes must never become JSON structure and must never be
altered: an id is written as a JSON number only when the WHOLE text is one (RFC 8259: no leading zero, a digit
after '.', a digit in an exponent), otherwise as a string carrying the text exactly, with every control
character, quote and backslash escaped.

A local stub answers the embedding call and fails the reasoning call, and the agent runs in its
partial-reasoning mode, so what comes back is the half the agent did compute -- the id.

Env: EDGE_LINE (the DuckDB line to exercise, as in the other drivers).
"""
import csv, glob, io, json, math, os, platform, subprocess, sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness_common import latest_cli, band_file

LINE = os.environ.get("EDGE_LINE", "15")
CLI, EXT = latest_cli(LINE), band_file(LINE)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if sys.platform == "win32":
    plugs = sorted(glob.glob(os.path.join(ROOT, "include", "windows-*", "fractalsql-reasoning-http.dll")))
elif sys.platform == "darwin":
    plugs = sorted(glob.glob(os.path.join(ROOT, "include", "darwin-*", "fractalsql-reasoning-http.dylib")))
else:
    plugs = sorted(glob.glob(os.path.join(ROOT, "include", "linux-" + ("aarch64" if platform.machine() in ("aarch64", "arm64") else "x86_64"), "fractalsql-reasoning-http.so")))
if not CLI or not EXT or not plugs:
    print("id_emission: SKIP need a DuckDB CLI, the built extension and the vendored http plugin")
    sys.exit(0)
PLUG = plugs[0]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        self.rfile.read(n)
        if "embeddings" in self.path:
            body = json.dumps({"data": [{"embedding": [1.0, 0.1, 0.0], "index": 0}]}).encode()
            code = 200
        else:
            body = b'{"error":"model unavailable"}'
            code = 500
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


srv = HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
port = srv.server_address[1]
env = dict(os.environ,
           FRACTALSQL_REASONING_PLUGIN=PLUG,
           FSQL_REASONING_HTTP_URL="http://127.0.0.1:%d/v1/chat/completions" % port,
           FSQL_REASONING_HTTP_EMBED_URL="http://127.0.0.1:%d/v1/embeddings" % port,
           FSQL_REASONING_HTTP_MODEL="m", FSQL_REASONING_HTTP_EMBED_MODEL="e",
           FSQL_REASONING_HTTP_ALLOW_PLAINTEXT="1",
           FRACTALSQL_REASONING_REQUIRE_SIGNATURE="0", FSQL_REASONING_REQUIRE_SIGNATURE="0")

HEADING = "[" + ",".join("%.4f" % (math.sin(i * 0.37) + (i % 7) * 0.05) for i in range(64)) + "]::DOUBLE[]"
BASE = "[0.1,0.1,0.1,0.1]::DOUBLE[]"
CUR = "[0.7,-0.4,-0.8,0.9]::DOUBLE[]"

# (the id text, is it a JSON number?)
IDS = (("42", True), ("0", True), ("-0", True), ("-7", True), ("10.5", True), ("-0.25", True), ("1e5", True),
       ("1E-3", True), ("2.5e+10", True), ("0.5", True),
       ("007", False), ("00", False), ("-", False), ("+5", False), (".5", False), ("1.", False), ("1e", False),
       ("1e+", False), ("0x10", False), ("12abc", False), ("abc", False), (" 5", False), ("5 ", False), ("", False),
       ("true", False), ("null", False), ("NaN", False), ("Infinity", False),
       ('{"x":1', False), ('["a"', False), ('quote " and backslash \\', False), ("tab\there", False),
       ("line\nbreak", False), ("cr\rhere", False), ("back\bspace and form\ffeed", False),
       ("ctl\x01\x02\x1f end", False), ("slash / and unicode é 日本 😀", False),
       ("-" + "9" * 400, True), ("1" + "0" * 400, True))

passes = fails = 0


def safe(t):
    """The text under test may hold characters a Windows console (cp1252) cannot print: show them escaped.

    Printing it raw kills the driver, and the report of the defect goes with it."""
    return str(t).encode("ascii", "backslashreplace").decode("ascii")


def check(cond, what, detail=""):
    global passes, fails
    if cond:
        passes += 1
    else:
        fails += 1
        print("  FAIL %s %s" % (safe(what), ("-- " + safe(detail)[:250]) if detail else ""))


def run(stmts):
    script = "LOAD '%s';\n%s\nSELECT fractal_release();\n" % (EXT, "\n".join(stmts))
    p = subprocess.run([CLI, "-unsigned", "-batch", "-csv", "-noheader"], input=script,
                       capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=120)
    return p.stdout, p.stderr


def ask(text):
    """The agent's answer for a row whose id is `text`: the id half of its JSON result."""
    # decode() gives the bytes as they are: a blob cast to a string would come back escaped.
    hexed = "" if text is None else text.encode("utf-8").hex()
    out, err = run([
        "SELECT fractal_config_set('agent_partial_reasoning_fail','on');",
        "CREATE TABLE trk(id TEXT, cur DOUBLE[]);",
        "INSERT INTO trk VALUES (%s, %s);" % ("NULL" if text is None else "decode(from_hex('%s'))" % hexed, BASE),
        "SELECT fractal_agent_track_anomaly('trk','cur',%s,%s,%s,5,'id');" % (BASE, CUR, HEADING),
    ])
    if not out.strip():
        return None, (out, err)
    # The agent's answer is the last row; the rows before it are the setup's output.
    rows = [r[0] for r in csv.reader(io.StringIO(out)) if r]
    for row in reversed(rows):
        if row.startswith("{"):
            return row, (out, err)
    return None, (out, err)


for text, as_number in IDS:
    raw, detail = ask(text)
    if raw is None:
        check(False, "id %r: the agent answers" % text[:40], detail)
        continue
    try:
        got = json.loads(raw)["nearest_fleet_id"]
    except Exception as e:
        check(False, "id %r: the result is valid JSON" % text[:40], (e, raw[:160]))
        continue
    if as_number:
        check(isinstance(got, (int, float)) and not isinstance(got, bool),
              "id %r is written as a JSON number" % text[:40], (got, raw[:160]))
    elif text == "":
        check(got == "", "the empty id is written as the empty string", (got, raw[:160]))
    else:
        check(got == text, "id %r is written as the same string" % text[:40], (got, raw[:160]))

# An id that is the empty string is written as null here: the empty id and a
# missing one are not told apart, and that is this host's contract (the
# error-table gate pins it). sqlite writes the empty string instead.
raw, detail = ask("")
check(raw is not None and json.loads(raw)["nearest_fleet_id"] == "",
      "the empty id is written as the empty string", detail)

raw, detail = ask(None)
check(raw is not None and json.loads(raw)["nearest_fleet_id"] is None,
      "a NULL id is written as null", detail)

print("id_emission: %d checks passed, %d failed" % (passes, fails))
sys.exit(1 if fails else 0)
