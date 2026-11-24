#!/usr/bin/env python3
"""test/kit_mutation.py -- the demo kits' own statements, with their literal arguments replaced one at a time.

The kits call every agent and function with arguments that are valid for it, which gets past argument validation into the real work;
the edge matrix does the opposite (awkward arguments, but not valid enough to get deep). This takes each kit statement that calls a
fractal* function and runs it again with ONE literal (a string or a number) swapped for an awkward value (NULL, empty, an empty or
unterminated JSON document, zero, a negative, a huge number, a long string, text where a number was, a number where text was), after
running the kit's earlier statements so the state the statement expects exists. Mutated statements only read (SELECT / WITH), so
nothing they do changes the state the next one sees.

What is asserted: the process survives (a crash, abort or sanitizer report fails the run) and every statement returns or raises.
An ordinary SQL error is the expected outcome for most mutations. Kits run in parallel processes.
Env: FSQL_EXT (the extension, default ./fractalsql.so), MUT_MAX (variants per statement, default 24), MUT_FILTER (regex on the kit file
name), MUT_WORKERS (default 4), MUT_SEED, MUT_MODE (both|arity|literal, default both). Exit status is nonzero when a kit crashed."""
import os, random, re, shutil, subprocess, sys, tempfile, threading, time
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness_common import latest_cli, band_file, build_plugins, PLUGINS, CC, SOEXT

LINE = os.environ.get("EDGE_LINE", "15")
CLI = latest_cli(LINE)
# The band the engine under test loads; the gate points at it, and the harness
# finds it when the gate runs on its own.
EXT = os.environ.get("FSQL_BT_EXT") or band_file(LINE)
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
MAXV = int(os.environ.get("MUT_MAX", "24")); WORKERS = int(os.environ.get("MUT_WORKERS", "4"))
FILTER = re.compile(os.environ.get("MUT_FILTER", "")); SEED = int(os.environ.get("MUT_SEED", "1"))
os.environ.setdefault("FSQL_REASONING_REQUIRE_SIGNATURE", "0"); os.environ.setdefault("FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE", "0")
SQLFILE = "/tmp/fractalsql_bt_sql.txt"
LIT = re.compile(r"'(?:[^']|'')*'|(?<![\w.])-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?(?![\w.])")
STR_POOL = ["NULL", "''", "'{}'", "'[]'", "'{\"a\":'", "'x'", "'0'", "-1", "0", "1e308", "printf('%.*c', 4000, 'x')", "'[1,2'", "x'00'"]
NUM_POOL = ["NULL", "0", "-1", "1", "2147483647", "1e308", "-1e308", "'x'", "''", "0.0", "9223372036854775807", "'[]'", "1e-300"]

try:
    import duckdb
except ImportError:
    # The pip duckdb package may live in the user site-packages, which an
    # isolated run (python3 -I) does not look at.
    import site
    sys.path.append(site.getusersitepackages())
    try:
        import duckdb
    except ImportError:
        print("  FAIL the pip duckdb package is needed to run the kit statements"); sys.exit(1)


def statements(text):
    """The statements of a script: a statement ends at a semicolon that is not inside a string."""
    out, buf, q = [], "", None
    for line in text.split("\n"):
        if not buf and line.lstrip().startswith("."): continue
        if not buf and (not line.strip() or line.lstrip().startswith("--")): continue
        buf += line + "\n"
        i = 0
        while i < len(line):
            c = line[i]
            if q:
                if c == q: q = None
            elif c in "'\"": q = c
            i += 1
        if q is None and buf.rstrip().endswith(";"):
            out.append(buf.strip()); buf = ""
    if buf.strip(): out.append(buf.strip())
    return out


from concurrent.futures import ProcessPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
MAXV = int(os.environ.get("MUT_MAX", "24")); WORKERS = int(os.environ.get("MUT_WORKERS", "4"))
FILTER = re.compile(os.environ.get("MUT_FILTER", "")); SEED = int(os.environ.get("MUT_SEED", "1"))
os.environ.setdefault("FSQL_REASONING_REQUIRE_SIGNATURE", "0"); os.environ.setdefault("FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE", "0")
SQLFILE = "/tmp/fractalsql_bt_sql.txt"
LIT = re.compile(r"'(?:[^']|'')*'|(?<![\w.])-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?(?![\w.])")
STR_POOL = ["NULL", "''", "'{}'", "'[]'", "'{\"a\":'", "'x'", "'0'", "-1", "0", "1e308", "printf('%.*c', 4000, 'x')", "'[1,2'", "x'00'"]
NUM_POOL = ["NULL", "0", "-1", "1", "2147483647", "1e308", "-1e308", "'x'", "''", "0.0", "9223372036854775807", "'[]'", "1e-300"]


def call_spans(st):
    """(open, close, [(a, b), ...]) for every fractal* call in the statement: the offsets of its parentheses and of each top-level argument."""
    out = []
    for m in re.finditer(r"\bfractal\w*\s*\(", st):
        i = m.end(); depth = 1; start = i; args = []; q = None
        while i < len(st) and depth:
            c = st[i]
            if q:
                if c == q:
                    if st[i + 1:i + 2] == q: i += 1
                    else: q = None
            elif c in "'\"": q = c
            elif c in "([": depth += 1
            elif c in ")]":
                depth -= 1
                if depth == 0:
                    if st[start:i].strip(): args.append((start, i))
                    break
            elif c == "," and depth == 1: args.append((start, i)); start = i + 1
            i += 1
        if depth == 0: out.append((m.end() - 1, i, args))
    return out


def arity_mutants(st):
    """The same statement with one call's argument COUNT changed (trailing arguments dropped, an extra one added) or one argument NULLed."""
    out = []
    for o, c, args in call_spans(st):
        n = len(args)
        for keep in range(0, n):                                         # drop the trailing arguments: the optional-argument defaults
            end = args[keep - 1][1] if keep else o + 1
            out.append(st[:end] + st[c:] if keep else st[:o + 1] + st[c:])
        out.append(st[:c] + (", NULL" if n else "NULL") + st[c:])       # one more than the function takes
        out.append(st[:c] + (", NULL, NULL, NULL" if n else "NULL") + st[c:])
        for a, b in args:                                                 # each argument NULL
            out.append(st[:a] + " NULL " + st[b:])
    return out


def mutants(st, rng):
    if os.environ.get("MUT_MODE", "both") != "literal":
        pre = arity_mutants(st)
    else:
        pre = []
    if os.environ.get("MUT_MODE", "both") == "arity": return pre
    lits = [m for m in LIT.finditer(st)]
    cand = []
    for m in lits:
        pool = STR_POOL if m.group(0).startswith("'") else NUM_POOL
        for v in pool:
            if v != m.group(0): cand.append((m.start(), m.end(), v))
    rng.shuffle(cand)
    return pre + [st[:a] + v + st[b:] for a, b, v in cand[:MAXV]]


def run_kit(path):
    name = os.path.basename(path); rng = random.Random(SEED + sum(map(ord, name)))
    work = tempfile.mkdtemp(prefix="fsql_mut_")
    mocks = {}
    for m, src in (("mock_reasoning_plugin", os.path.join(ROOT, "tests", "mock_reasoning_plugin.c")),
                   ("mock_embed_plugin", os.path.join(ROOT, "tests", "mock_embed_plugin.c")),
                   ("mock_enterprise", os.path.join(ROOT, "test", "mock_enterprise.c"))):
        if not os.path.exists(src): continue
        # The harness's own conventions: the compiler it resolved (FSQL_CC) and the
        # platform's library suffix (.dll on Windows, .so elsewhere) -- a hardcoded
        # "cc" and ".so" do not exist on Windows.
        out = os.path.join(work, m + SOEXT)
        if subprocess.run([CC, "-shared", "-fPIC", "-std=c99", "-I" + os.path.join(ROOT, "include"), src, "-o", out],
                          capture_output=True).returncode == 0: mocks[m] = out
    if "mock_enterprise" in mocks: os.environ["FRACTALSQL_ENTERPRISE_LIB"] = mocks["mock_enterprise"]
    c = duckdb.connect(":memory:", config={"allow_unsigned_extensions": "true", "threads": "1"})
    c.execute("LOAD '%s'" % EXT.replace("'", "''"))
    if "mock_reasoning_plugin" in mocks:
        c.execute("SELECT fractal_config_set('reasoning_plugin', '%s')" % mocks["mock_reasoning_plugin"])
    ran = 0
    for st in statements(open(path, encoding="utf-8", errors="replace").read()):
        # The kit loads the extension itself; this driver loads the band under test, so
        # the kit's own LOAD (which names the repository's .so) is dropped.
        if re.match(r"(?is)\s*load\b", st): continue
        timer = threading.Timer(20, c.interrupt); timer.start()
        try: c.execute(st).fetchall()
        except Exception: pass
        finally: timer.cancel()
        if re.match(r"(?is)\s*(select|with)\b", st) and re.search(r"\bfractal\w*\s*\(", st):
            for mu in mutants(st, rng):
                timer = threading.Timer(10, c.interrupt); timer.start()
                try: c.execute(mu).fetchall()
                except Exception: pass
                finally: timer.cancel()
                ran += 1
    c.close(); shutil.rmtree(work, ignore_errors=True)
    return name, ran


if __name__ == "__main__":
    if not CLI or not EXT:
        print("kit mutation: SKIP need a DuckDB CLI and the built extension"); sys.exit(0)
    kits = sorted(os.path.join(ROOT, "demo", f) for f in os.listdir(os.path.join(ROOT, "demo"))
                  if f.endswith(".sql") and FILTER.search(f))
    t0 = time.time(); total = crashed = 0
    with open(SQLFILE, "w") as f: f.write("SELECT 1")
    with ProcessPoolExecutor(max_workers=WORKERS) as ex:
        futs = [(k, ex.submit(run_kit, k)) for k in kits]
        for k, fu in futs:
            try: name, n = fu.result(); total += n
            except Exception as e:
                crashed += 1; print("  FAIL %s: %s" % (os.path.basename(k), e))
    print("kit mutation: %d kits, %d mutated statements in %.0fs, %d crashed" % (len(kits), total, time.time() - t0, crashed))
    sys.exit(1 if crashed else 0)
