#!/usr/bin/env python3
"""test/test_unicode.py -- text in and out of the extension keeps its characters.

Accented Latin, CJK, right-to-left text, emoji (skin tone, flag, joined sequences), combining marks and JSON-special characters go
through fractal_chunk_text and a table round trip. Checks: one chunk holds the whole text unchanged, chunk offsets are character
offsets, chunks joined back give the text, the output is strict UTF-8 JSON, and stored text comes back byte for byte.
Env: EDGE_LINE as in test_index.py. Exit status is nonzero when a check fails."""
import json, os, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness_common import CLEAN_ENV, latest_cli, band_file, run_cli
from fsql_test_backend import backend

LINE = os.environ.get("EDGE_LINE", "15")
CLI, EXT = latest_cli(LINE), band_file(LINE)
if not EXT:
    import glob
    REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    found = [f for f in glob.glob(os.path.join(REPO, "dist/**/fractalsql.capi.*.duckdb_extension"), recursive=True) if "-legacy" not in f]
    EXT = found[0] if found else None
if not EXT:
    print("  FAIL need the built extension"); sys.exit(1)
B = backend(EXT, CLI, CLEAN_ENV, run_cli, os.path.join(tempfile.mkdtemp(prefix="fsql_uni_"), "u.duckdb"))
CASES = {
    "latin": "Crème brûlée à la façon de São Paulo, naïve café, Ångström, straße",
    "cjk": "日本語のテキストと中文汉字、한국어 문장입니다",
    "rtl": "مرحبا بالعالم שלום עולם",
    "emoji": "😀👍🏽🇯🇵 👨‍👩‍👧‍👦 ok 🧪",
    "combining": "é ñ ạ̈ end",
    "specials": "quote \" backslash \\ tab\t newline\n ctrl \x01\x1f slash / <tag> &amp;    ",
}
passes = fails = 0
def check(cond, what, detail=""):
    global passes, fails
    if cond: passes += 1
    else: fails += 1; print("  FAIL %s %s" % (what, ("-- " + str(detail)[:250]) if detail else ""))
def lit(t): return "decode(from_hex('%s'))" % t.encode("utf-8").hex()
def chunks(t, size, ov, mode="fixed"):
    rc, out, err = B.run("SELECT hex(fractal_chunk_text(%s, %d, %d, '%s'));" % (lit(t), size, ov, mode))
    if rc != 0: raise RuntimeError(err[:200])
    return json.loads(bytes.fromhex(out.strip().strip('"')).decode("utf-8"))
B.run("CREATE OR REPLACE TABLE t(id INTEGER, body VARCHAR);")
for i, (name, text) in enumerate(CASES.items()):
    n = len(text)
    try:
        one = chunks(text, 100000, 0)
        check(len(one) == 1 and one[0]["text"] == text and one[0]["start"] == 0 and one[0]["end"] == n, name + ": one chunk holds the whole text", one)
        for size, ov in ((5, 0), (7, 3), (1, 0)):
            ch = chunks(text, size, ov)
            check(all(x["text"] == text[x["start"]:x["end"]] for x in ch), "%s: size %d overlap %d offsets are character offsets" % (name, size, ov))
            check(all(len(x["text"]) <= size for x in ch), "%s: size %d chunks are at most %d characters" % (name, size, size))
            if ov == 0: check("".join(x["text"] for x in ch) == text, "%s: size %d chunks join back to the text" % (name, size))
        for mode in ("paragraph", "sentence"):
            check(len(chunks(text, 100000, 0, mode)) >= 1, name + ": " + mode + " mode answers")
    except Exception as e:
        check(False, name + ": chunk_text output is strict UTF-8 JSON", e)
    B.run("INSERT INTO t VALUES (%d, %s);" % (i, lit(text)))
    rc, out, err = B.run("SELECT hex(body), length(body) FROM t WHERE id=%d;" % i)
    hx, ln = out.strip().split(",")
    check(rc == 0 and bytes.fromhex(hx.strip('"')) == text.encode("utf-8") and int(ln) == n, name + ": a table round trip returns the same characters", out)
print("unicode: %d checks passed, %d failed" % (passes, fails)); sys.exit(1 if fails else 0)
