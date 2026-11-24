#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/fractalsqlabs
"""test/scripted_replies.py -- the extension against a model that answers exactly what the test scripts.

A local HTTP stub answers the vendored reasoning plugin with the next reply of the script the test wrote, so a
test chooses exactly what the extension has to parse. The scenarios:

  * the reasoning tier: the reply is handed back exactly as the model wrote it (a fenced block, a reply with
    control characters, an empty reply, a reply that is not SQL at all);
  * the embedding tier: a vector in every shape the parser takes or refuses (a well-formed array, an array with
    spaces, an empty array, a non-numeric element, a nested array, text that is not an array at all).

Env: EDGE_LINE (the DuckDB line to exercise), as in the other drivers.
"""
import glob
import json
import os
import platform
import subprocess
import sys
import threading
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
    print("scripted_replies: SKIP need a DuckDB CLI, the built extension and the vendored http plugin")
    sys.exit(0)
PLUG = plugs[0]

# The script: the first line is an epoch, then the replies, separated by the
# ASCII record separator. A new epoch starts the replies over.
SCRIPT = os.path.join(os.path.dirname(EXT) or ".", "fsql_script.txt")
_state = {"epoch": 0, "calls": 0}


def script(replies):
    """The replies the next dispatches are answered with."""
    _state["epoch"] += 1
    _state["calls"] = 0
    with open(SCRIPT, "w", encoding="utf-8") as fh:
        fh.write("%d\n" % _state["epoch"])
        fh.write("\x1e".join(replies))


def next_reply():
    """The next reply of the script, or None when the script is used up."""
    try:
        with open(SCRIPT, encoding="utf-8") as fh:
            lines = fh.read().split("\n", 1)
            replies = lines[1].split("\x1e") if len(lines) > 1 else []
    except OSError:
        return None
    i = _state["calls"]
    _state["calls"] += 1
    return replies[i] if i < len(replies) else None


def embedding_body(reply):
    """The embedding response for a scripted vector reply.

    A reply that is a JSON array of numbers is the well-formed answer; anything else is shaped so the parser
    has to refuse it (a string, an empty array, a nested array, a missing embedding)."""
    try:
        vec = json.loads(reply)
    except Exception:
        vec = reply
    if isinstance(vec, list) and all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in vec):
        return json.dumps({"data": [{"embedding": vec, "index": 0}]}).encode()
    if reply == "":
        return json.dumps({"data": []}).encode()
    if reply == "[]":
        return json.dumps({"data": [{"embedding": [], "index": 0}]}).encode()
    if reply == "[[1,2],[3,4]]":
        return json.dumps({"data": [{"embedding": [[1, 2], [3, 4]], "index": 0}]}).encode()
    if reply == "no vector":
        return json.dumps({"data": [{"embedding": "no vector", "index": 0}]}).encode()
    if reply == "[0.1,abc]":
        return json.dumps({"data": [{"embedding": "[0.1,abc]", "index": 0}]}).encode()
    return json.dumps({"data": [{"embedding": reply, "index": 0}]}).encode()


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        self.rfile.read(n)
        reply = next_reply()
        if reply is None:
            body, code = b'{"error":"the script is used up"}', 500
        elif "embeddings" in self.path:
            body, code = embedding_body(reply), 200
        else:
            body = json.dumps({"choices": [{"message": {"role": "assistant", "content": reply}}]}).encode()
            code = 200
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

passes = fails = 0


def check(cond, what, detail=""):
    global passes, fails
    if cond:
        passes += 1
    else:
        fails += 1
        print("  FAIL %s %s" % (what, ("-- " + str(detail)[:250]) if detail else ""))


def run(stmts):
    """The statements in one session; returns (returncode, stdout, stderr)."""
    script_text = ("LOAD '%s';\n" % EXT + "".join(s + "\n" for s in stmts))
    p = subprocess.run([CLI, "-unsigned", "-batch", "-csv", "-noheader"], input=script_text,
                       capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=120)
    return p.returncode, p.stdout, p.stderr


def bad(rc, err):
    """The call was refused cleanly: an error, and no crash."""
    return rc != 0 and "Error" in err and "INTERNAL" not in err


# --- the reasoning tier: the reply comes back exactly as the model wrote it ---------------------------------
for reply in ("the routing is sound",
              "```sql\nSELECT 1\n```",
              "line one\nline two",
              "  padded  ",
              "ctl\x01\x02\x1f end",
              "unicode é 日本 \U0001f600"):
    script([reply])
    rc, out, err = run(["SELECT fractal_reason('q');"])
    check(rc == 0 and reply in out, "the reasoning reply is handed back verbatim (%r)" % reply[:24],
          (rc, out[:120], err[-120:]))

# A reply the model gives when it has nothing: an empty one.
script([""])
rc, out, err = run(["SELECT fractal_reason('q');"])
check(rc == 0 or bad(rc, err), "an empty reasoning reply is answered, not a crash", (rc, out[:120], err[-120:]))

# --- the embedding tier: a vector in every shape the parser takes or refuses ---------------------------------
EMB = (("[0.1,0.2,0.3]", 3),
       ("[1]", 1),
       ("[ 0.1 , 0.2 ]", 2),
       # Over HTTP the answer is a JSON document, so a vector with trailing text is
       # not a vector with trailing text: the whole reply is malformed, and the
       # parser has to refuse it.
       ("[0.1,0.2,0.3] trailing", None),
       ("[]", None),
       ("", None),
       ("no vector", None),
       ("[0.1,abc]", None),
       ("[[1,2],[3,4]]", None))
for reply, dims in EMB:
    script([reply])
    rc, out, err = run(["SELECT fractal_embed('x');"])
    if dims is None:
        # A reply the parser refuses: the call must fail cleanly, not crash.
        check(bad(rc, err), "the embedding reply %r is refused cleanly" % reply[:24], (rc, out[:120], err[-120:]))
    else:
        check(rc == 0, "the embedding reply %r is accepted" % reply[:24], (rc, out[:120], err[-120:]))

print("scripted_replies: %d checks passed, %d failed" % (passes, fails))
sys.exit(1 if fails else 0)
