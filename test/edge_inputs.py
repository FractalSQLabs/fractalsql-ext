#!/usr/bin/env python3
"""test/edge_inputs.py -- edge-input matrix for every registered fractal* function.

For each overload in duckdb_functions() it builds calls that vary ONE argument at a time through a
pool of awkward values (NULL, empty, huge, NaN, negative, malformed JSON, ...) while the others hold a
plausible value, plus an all-NULL call and an all-typical call. Each function runs in its own CLI
session (state a call leaves behind cannot mask the next function) without -bail, so every statement
executes whether or not the one before it raised.

What is asserted: no statement may crash the process, trip a sanitizer, or surface a DuckDB INTERNAL
error. Ordinary errors are the expected outcome for most of these inputs and are not failures. The
point is branch coverage of the argument-validation and error paths, and a robustness floor.

Configurations (each a full pass over the catalog):
  configured   mock reasoning plugin + mock enterprise core loaded (the deep paths)
  bare         nothing configured (the NOT_CONFIGURED / activation-error paths)
Then a short pass with the mock plugin set to misbehave (rc / empty / garbage / embed-*), driving the
agents, text_to_sql and the vectorizer through their outage and bad-reply handling.

Env: CAPI_SAN / CAPI_DIST / CAPI_LINES as in parity_diff.py; EDGE_MAX_OVERLOADS limits the sweep (debug).
Exit status is nonzero when any function crashed or reported INTERNAL.
"""
import json, os, re, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I drops the script dir
from harness_common import (signature_policy, PLUGINS, SAN, DIST, CLEAN_ENV, MOCK_FILES, san_runtime, latest_cli, band_file, run_cli, timeout_for)

LINE = os.environ.get("EDGE_LINE", "15")
CLI = latest_cli(LINE)
EXT = band_file(LINE)
if not CLI or not EXT:
    print("  FAIL need a DuckDB CLI and the built extension for line " + LINE); sys.exit(1)

PRELUDE = """
CREATE TABLE docs (id INTEGER PRIMARY KEY, label VARCHAR, v DOUBLE[]);
INSERT INTO docs VALUES (1,'a',[0.1,0.2,0.3]),(2,'b',[0.9,0.1,0.0]),(3,'c',[0.0,0.8,0.5]),(4,'d',[0.3,0.3,0.3]);
CREATE TABLE telemetry (ts INTEGER, host VARCHAR, cpu DOUBLE);
INSERT INTO telemetry SELECT i, 'h1', sin(i * 0.37) + (i % 7) * 0.05 FROM range(60) t(i);
"""

# plausible values per type (several, so different overloads get a sensible context)
TYPICAL = {
    "VARCHAR": ["'docs'", "'{\"a\":1}'", "'v'", "'id'", "'cpu'", "'ts'", "'host'"],
    "DOUBLE": ["0.5"], "FLOAT": ["0.5::FLOAT"], "INTEGER": ["3"], "BIGINT": ["3::BIGINT"], "BOOLEAN": ["true"],
    "DOUBLE[]": ["[0.1, 0.2, 0.3]::DOUBLE[]"], "FLOAT[]": ["[0.1, 0.2, 0.3]::FLOAT[]"],
    "BIGINT[]": ["[1, 2, 3]::BIGINT[]"], "VARCHAR[]": ["['a', 'b']::VARCHAR[]"],
    "BLOB": ["'\\x00\\x01'::BLOB"], "BLOB[]": ["['\\x00\\x01'::BLOB]::BLOB[]"],
}
# awkward values: the argument under test cycles through these
POOL = {
    "VARCHAR": ["NULL::VARCHAR", "''", "' '", "'{'", "'[]'", "'{\"a\":'", "'it''s'", "'x;DROP TABLE docs'",
                "'SELECT 1'", "'nope'", "repeat('x', 5000)", "'üñï'", "'-1'", "'1e400'"],
    "DOUBLE": ["NULL::DOUBLE", "0.0", "-1.0", "1e308", "-1e308", "'NaN'::DOUBLE", "'Infinity'::DOUBLE", "1e-320"],
    "FLOAT": ["NULL::FLOAT", "0.0::FLOAT", "-1.0::FLOAT", "'NaN'::FLOAT", "'-Infinity'::FLOAT"],
    "INTEGER": ["NULL::INTEGER", "0", "-1", "1", "2147483647", "-2147483648", "100000"],
    "BIGINT": ["NULL::BIGINT", "0::BIGINT", "-1::BIGINT", "9223372036854775807::BIGINT"],
    "BOOLEAN": ["NULL::BOOLEAN", "false"],
    "DOUBLE[]": ["NULL::DOUBLE[]", "[]::DOUBLE[]", "[NULL]::DOUBLE[]", "[1.0]::DOUBLE[]", "['NaN'::DOUBLE, 1.0]::DOUBLE[]",
                 "[1e308, -1e308, 1e308]::DOUBLE[]", "[0.0, 0.0, 0.0]::DOUBLE[]", "list_transform(range(300), lambda x: x * 0.01)::DOUBLE[]"],
    "FLOAT[]": ["NULL::FLOAT[]", "[]::FLOAT[]", "[NULL]::FLOAT[]", "['NaN'::FLOAT]::FLOAT[]", "[0.0, 0.0]::FLOAT[]"],
    "BIGINT[]": ["NULL::BIGINT[]", "[]::BIGINT[]", "[NULL]::BIGINT[]", "[-1, 0, 9223372036854775807]::BIGINT[]"],
    "VARCHAR[]": ["NULL::VARCHAR[]", "[]::VARCHAR[]", "[NULL]::VARCHAR[]", "['']::VARCHAR[]"],
    "BLOB": ["NULL::BLOB", "''::BLOB", "'\\xFF'::BLOB", "'\\x00'::BLOB", "repeat('\\xAB', 3000)::BLOB"],
    "BLOB[]": ["NULL::BLOB[]", "[]::BLOB[]", "[NULL]::BLOB[]"],
}
NULLS = {t: v[0] for t, v in POOL.items()}

def catalog():
    p = run_cli([CLI, "-unsigned", "-json", "-c",
                 f"LOAD '{EXT}'; SELECT function_name, function_type, parameter_types FROM duckdb_functions() "
                 "WHERE function_name LIKE 'fractal%' ORDER BY 1,2,3;"],
                capture_output=True, text=True, encoding="utf-8", errors="replace", env=CLEAN_ENV)
    rows = json.loads(p.stdout)
    byname = {}
    for r in rows:
        pt = r["parameter_types"]
        pt = json.loads(pt) if isinstance(pt, str) else pt
        byname.setdefault(r["function_name"], []).append((r["function_type"], pt))
    return byname

def stmt(name, kind, args):
    call = f"{name}({', '.join(args)})"
    return f"SELECT * FROM {call};" if kind == "table" else f"SELECT {call};"

# VARCHAR arguments by position: the catalog gives no parameter names (col0, col1, ...), so each recipe lists
# the fixture names a function with a (table, column, ...) shape would plausibly take, in order, so that the
# table, vector-column and id-column arguments are consistent and the call gets past its validation and runs.
RECIPES = [
    ["docs", "v", "id", "label", "v", "id", "label", "v"],
    ["telemetry", "cpu", "ts", "host", "cpu", "ts", "host", "cpu"],
    ["docs", "id", "v", "label", "id", "v", "label", "id"],
    ["telemetry", "ts", "cpu", "host", "ts", "cpu", "host", "ts"],
    ["docs", "label", "v", "id", "label", "v", "id", "label"],
    ["{\"a\":1}"] * 8,
    ["v"] * 8,
]

def typical_args(types, ti):
    out, vpos = [], 0
    for t in types:
        if t == "VARCHAR":
            out.append("'%s'" % RECIPES[ti % len(RECIPES)][vpos].replace("'", "''")); vpos += 1
        else:
            out.append(TYPICAL[t][0])
    return out

def statements(name, overloads, depth):
    out = []
    for kind, types in overloads:
        if any(t not in TYPICAL for t in types):
            continue
        for ti in range(len(RECIPES) if depth == "full" else 1):
            typ = typical_args(types, ti)
            out.append(stmt(name, kind, typ))
            out.append(stmt(name, kind, [NULLS[t] for t in types]))
            if depth == "bare":
                break
            if ti >= 2 and depth == "full":
                continue   # only the first typical rotations get the full single-arg sweep
            for i, t in enumerate(types):
                for bad in POOL[t]:
                    a = list(typ); a[i] = bad
                    out.append(stmt(name, kind, a))
    # drop duplicates, keep order
    seen = set(); res = []
    for s in out:
        if s not in seen: seen.add(s); res.append(s)
    return res

def env_for(cfg):
    env = dict(CLEAN_ENV)
    if cfg in ("configured", "fail"):
        env["FRACTALSQL_REASONING_PLUGIN"] = PLUGINS.get("mock_embed_plugin", "")
        env["FRACTALSQL_ENTERPRISE_LIB"] = PLUGINS.get(os.environ.get("EDGE_ENT", "mock_enterprise"), "")   # or a variant lacking symbols
        env["FSQL_ENTERPRISE_ALLOW_UNVERIFIED"] = "1"
        env["FSQL_REASONING_HTTP_EMBED_URL"] = "https://embed.invalid/v1/embeddings"
    return signature_policy(env)

BAD = re.compile(r"INTERNAL Error|Sanitizer|runtime error:|Segmentation fault|Assertion .* failed|FATAL Error|"
                 r"terminate called|\*\*\* stack smashing|double free|corrupted")
def run_script(sql, env):
    if SAN:
        rt = san_runtime()
        env = dict(env, LD_PRELOAD=rt, ASAN_OPTIONS="detect_leaks=0:abort_on_error=0:halt_on_error=1",
                   UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1")
    # The extension's documented host contract: a session that is about to close the database ends with
    # fractal_release(), so the extension closes the connections it keeps for nested queries on this thread,
    # while the database is still alive. Without it the host-departure monitor closes them from its own thread
    # at the same moment the CLI tears the database down: an access violation at exit that a release build
    # masks (the engine's SEH handler turns the fault into an ordinary error) and a sanitizer build names.
    script = f"LOAD '{EXT}';\n{sql}\nSELECT fractal_release();\n"
    p = run_cli([CLI, "-unsigned", "-csv", "-noheader"], input=script,
                capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=timeout_for(900))
    out = p.stdout + p.stderr
    if "destructive latch is set" in out and (BAD.search(out) or p.returncode < 0 or p.returncode >= 128):
        # fractal_release() is refused while the destructive latch is set (fractal_lock_destructive), so the
        # extension's connections stay open and the monitor would still close them during the teardown -- the
        # race the release above avoids. Run the session with the monitor off, the extension's documented
        # FRACTALSQL_HOST_CLOSE=off policy: the connections then live until the process exits and the teardown
        # has nothing left to race.
        p = run_cli([CLI, "-unsigned", "-csv", "-noheader"], input=script,
                    capture_output=True, text=True, encoding="utf-8", errors="replace",
                    env=dict(env, FRACTALSQL_HOST_CLOSE="off"), timeout=timeout_for(900))
    return p

def check(name, stmts, env, label):
    """Run the statements as one session. A crash or INTERNAL report is bisected to the offending statement."""
    p = run_script(PRELUDE + "\n".join(stmts) + "\n", env)
    out = p.stdout + p.stderr
    if p.returncode < 0 or p.returncode >= 128 or BAD.search(out):
        offenders = []
        for s in stmts:
            q = run_script(PRELUDE + s + "\n", env)
            if q.returncode < 0 or q.returncode >= 128 or BAD.search(q.stdout + q.stderr):
                offenders.append((s[:160], q.returncode, (q.stderr or q.stdout)[-200:]))
                if len(offenders) >= 3: break
        return offenders or [("(session)", p.returncode, out[-300:])]
    return []

def set_files(**files):
    for k, path in MOCK_FILES.items():
        try:
            if k in files:
                open(path, "w").write(files[k])
            elif os.path.exists(path):
                os.remove(path)
        except OSError:
            pass

fails = 0
total_stmts = 0
t0 = time.time()
cat = catalog()
names = sorted(cat)
limit = int(os.environ.get("EDGE_MAX_OVERLOADS", "0") or 0)
print(f"edge inputs: {len(names)} functions, DuckDB line {LINE}.x" + (f", sanitizer={SAN}" if SAN else ""))

def sweep(cfg, depth, only=None, fail_mode=None):
    global fails, total_stmts
    set_files(**({"fail": fail_mode + "\n"} if fail_mode else {}))
    env = env_for(cfg)
    n = 0
    for name in names:
        if only and not only(name):
            continue
        stmts = statements(name, cat[name], depth)
        if not stmts:
            continue
        total_stmts += len(stmts)
        bad = check(name, stmts, env, cfg)
        n += 1
        if bad:
            fails += 1
            print(f"  FAIL [{cfg}{'/' + fail_mode if fail_mode else ''}] {name}")
            for s, rc, tail in bad:
                print(f"       rc={rc}  {s}\n       {tail.strip()[-200:]!r}")
        if limit and n >= limit:
            break
    print(f"  PASS [{cfg}{'/' + fail_mode if fail_mode else ''}] {n} functions swept ({depth})" if True else "")

# EDGE_CONFIGS=configured,bare,fail (default all); a coverage run repeats the matrix under other process environments
# (FSQL_AUDIT_REDACT, EDGE_ENT=<mock enterprise variant>, FRACTALSQL_NESTED_QUERIES, ...) to reach their branches.
CONFIGS = os.environ.get("EDGE_CONFIGS", "configured,bare,fail").split(",")
if "configured" in CONFIGS: sweep("configured", "full")
if "bare" in CONFIGS: sweep("bare", "bare")
AGENTISH = lambda n: re.search(r"agent|reason|embed|vectorizer|text_to_sql|sql_agent|explore|hybrid|rag|plan_|cross_modal|detect_loop|schema_context", n)
for mode in (("rc", "empty", "garbage", "embed-rc", "embed-empty", "embed-bad") if "fail" in CONFIGS else ()):
    sweep("fail", "bare", only=AGENTISH, fail_mode=mode)
set_files()

print()
print(f"edge inputs: {total_stmts} statements in {time.time() - t0:.0f}s, {fails} function sweep(s) with a crash or INTERNAL error")
sys.exit(1 if fails else 0)
