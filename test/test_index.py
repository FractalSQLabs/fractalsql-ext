#!/usr/bin/env python3
"""test/test_index.py -- the native IVF index: the SQL surface, the indexed search, and the proof
that the index is ACTUALLY USED.

What this gate proves:

  1. The index SQL surface exists and behaves: fractal_index_create / _rebuild / _drop / _info and
     fractal_index_candidates, and fractal_sfs_converge as the indexed (table) search. (This is the part
     that fails on the pre-change code: none of them exist.)
  2. The indexed search returns the SAME columns as fractal_search_telemetry (doc_id, distance,
     scan_pos) and its distances are EXACT: every returned row's distance equals the double-precision
     cosine of that row, recomputed by the test itself. The index never returns an approximate
     distance.
  3. THE INDEX WAS ACTUALLY USED: fractal_index_info reports the rows the index scanned, and that
     number is far below the table's row count. A search that silently fell back to a flat scan
     fails here.
  4. The delta: a row committed after the build is found by the indexed search (the "committed rows
     only" rule), and fractal_index_info reports the index as stale.
  5. A rebuild keeps the index usable and moves the generation pointer; a drop removes it.

If the vendored core does not carry the IVF symbols (the weak-symbol guard reports it), the gate
SKIPS with that message instead of failing: the SQL surface is still there on every platform.

Env: EDGE_LINE / CAPI_DIST as in edge_inputs.py. Exit status is nonzero when any check fails.
"""
import json, math, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I drops the script dir
from harness_common import CLEAN_ENV, latest_cli, band_file, run_cli
from fsql_test_backend import backend

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
LINE = os.environ.get("EDGE_LINE", "15")
CLI, EXT = latest_cli(LINE), band_file(LINE)
if not EXT:
    # the extension may live under another name (a development build): look for it
    import glob
    for pat in ("dist/**/fractalsql.capi.*.duckdb_extension", "dist/**/fractalsql.*.duckdb_extension"):
        found = [f for f in glob.glob(os.path.join(REPO, pat), recursive=True) if "-legacy" not in f]
        if found:
            EXT = found[0]
            break
if not EXT:
    print("  FAIL need the built extension (dist/**/fractalsql*.duckdb_extension)")
    sys.exit(1)
import tempfile
_DBDIR = tempfile.mkdtemp(prefix="fsql_index_test_")
BACKEND = backend(EXT, CLI, CLEAN_ENV, run_cli, os.path.join(_DBDIR, "index.duckdb"))   # one shared database across the CLI calls
if BACKEND is None:
    print("  FAIL need a DuckDB CLI or the in-process duckdb module")
    sys.exit(1)

PASSED = 0
FAILED = 0
SKIPPED = False

DIM = 8
NTIGHT = 25        # the tight rows with the smallest offset are the exact neighbours (i %% 5 == 0)
NROWS = 2000
NOIVF = "does not carry the IVF index"


def check(name, ok, detail=""):
    global PASSED, FAILED
    if ok:
        PASSED += 1
        print("ok: " + name)
    else:
        FAILED += 1
        print("  FAIL %s%s" % (name, (": " + detail) if detail else ""))


def q(sql, prelude=""):
    """Runs one statement; returns (rc, stdout, stderr)."""
    return BACKEND.run(sql, prelude)


# ---------------------------------------------------------------- the corpus
QUERY = [0.5, 0.25, 0.75, 0.125, 0.375, 0.625, 0.875, 0.0]


def generic(i):
    return [((i * 7 + j * 13) % 1009) / 1024.0 for j in range(DIM)]


def tight(i):
    """The near-duplicates of the query: the rows the exact search must return first.
    The offset is never zero, so no tight row is identical to the query: the row committed after
    the build (whose distance rounds to exactly 0.0) is then unambiguously the closest. Every tight
    row points in the SAME direction, so the twenty of them are one cluster and the k-means keeps
    them in one cell -- which is what the recall check is about."""
    d = (1.0 + (i % 5) * 0.01) / 65536.0
    return [QUERY[j] + d for j in range(DIM)]


CORPUS = [tight(i) for i in range(NTIGHT)] + [generic(i) for i in range(NTIGHT, NROWS)]


def ref_cosine_distance(a, b):
    dot = na = nb = 0.0
    for i in range(len(a)):
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    if na == 0.0 or nb == 0.0:
        return 1.0
    return 1.0 - dot / (math.sqrt(na) * math.sqrt(nb))


EXACT = sorted(range(1, NROWS + 1), key=lambda i: (ref_cosine_distance(CORPUS[i - 1], QUERY), i))


def sql_list(v):
    return "[" + ",".join(repr(float(x)) for x in v) + "]"


PRELUDE = (
    "CREATE OR REPLACE TABLE corpus(id INTEGER PRIMARY KEY, v DOUBLE[]);\n"
    "DELETE FROM corpus;\n"
    + "INSERT INTO corpus VALUES "
    + ",".join("(%d,%s)" % (i + 1, sql_list(CORPUS[i])) for i in range(NROWS))
    + ";\n"
)

# ---------------------------------------------------------------- the surface
rc, out, err = q("SELECT fractal_index_info('no_such_index');")
check("fractal_index_info exists and reports an unknown index",
      rc != 0 and "no such index" in err, "rc=%d err=%r" % (rc, err[:200]))

rc, out, err = q("SELECT count(*) FROM fractal_index_candidates('corpus','v',%s::DOUBLE[],'{}');" % sql_list(QUERY), PRELUDE)
# before the index exists the call must fail with "no index on this table and column": that IS the
# proof that the function is registered
check("fractal_index_candidates exists",
      (rc == 0) or ("no index" in err), "rc=%d err=%r" % (rc, err[:250]))

rc, out, err = q("SELECT count(*) FROM fractal_search('corpus','v',%s::DOUBLE[],5,'{}');" % sql_list(QUERY), PRELUDE)
check("fractal_sfs_converge is the indexed (table) search", rc == 0, "rc=%d err=%r" % (rc, err[:250]))

rc, out, err = q("DESCRIBE SELECT * FROM fractal_search('corpus','v',%s::DOUBLE[],5,'{}');" % sql_list(QUERY), PRELUDE)
header_ok = "doc_id" in out and "distance" in out and "scan_pos" in out
check("the indexed search returns the same columns as fractal_search_telemetry",
      rc == 0 and header_ok, "rc=%d out=%r err=%r" % (rc, out[:200], err[:200]))

# ---------------------------------------------------------------- the build
rc, out, err = q("SELECT fractal_index_create('corpus','v','{\"name\":\"corpus_idx\",\"nlist\":16,\"vector_format\":\"FP32\"}');", PRELUDE)
if rc != 0 and NOIVF in err:
    print("index: SKIPPED -- " + err.strip().split("\n")[0])
    sys.exit(0)
check("fractal_index_create builds the index", rc == 0 and "corpus_idx" in out, "rc=%d out=%r err=%r" % (rc, out[:200], err[:250]))

rc, out, err = q("SELECT (fractal_index_info('corpus_idx')::JSON->>'$.rows_indexed')::BIGINT;")
check("fractal_index_info reports the indexed row count", rc == 0 and out.strip() == str(NROWS),
      "rc=%d out=%r err=%r" % (rc, out[:120], err[:200]))

rc, out, err = q("SELECT (fractal_index_info('corpus_idx')::JSON->>'$.format');")
check("fractal_index_info reports the vector format", rc == 0 and out.strip() == "FP32", "got %r" % out.strip())

rc, out, err = q("SELECT (fractal_index_info('corpus_idx')::JSON->>'$.generation')::BIGINT;")
generation = int(out.strip()) if rc == 0 and out.strip() else 0
check("fractal_index_info reports the generation", rc == 0 and generation >= 1, "got %r" % out.strip())

# ---------------------------------------------------------------- the indexed search
rc, out, err = q("SELECT doc_id, distance FROM fractal_search('corpus','v',%s::DOUBLE[],5,'{}');" % sql_list(QUERY))
rows = []
for line in out.strip().split("\n"):
    if not line.strip():
        continue
    parts = line.split(",")
    if len(parts) >= 2:
        try:
            rows.append((int(parts[0]), float(parts[1])))
        except ValueError:
            pass
check("the indexed search returns k rows", rc == 0 and len(rows) == 5, "rc=%d rows=%r err=%r" % (rc, rows, err[:250]))

if rows:
    ids = [r[0] for r in rows]
    want_ids = EXACT[:5]
    overlap = len(set(ids) & set(want_ids))
    check("the indexed search finds the exact neighbours (recall >= 4 of 5)", overlap >= 4,
          "got %r want a subset of %r" % (ids, want_ids))
    exact_dist = all(abs(r[1] - ref_cosine_distance(CORPUS[r[0] - 1], QUERY)) < 1e-9 for r in rows)
    check("every returned distance is EXACT (the index never returns an approximate distance)", exact_dist,
          "rows=%r" % (rows,))
    ordered = all(rows[i][1] <= rows[i + 1][1] for i in range(len(rows) - 1))
    check("the results are ordered by distance", ordered, "rows=%r" % (rows,))
    ties = [i for i in range(1, len(rows)) if rows[i][1] == rows[i - 1][1]]
    tie_ok = True
    for i in ties:
        if rows[i][0] < rows[i - 1][0]:
            tie_ok = False
    check("ties break on the row id (R8)", tie_ok, "rows=%r" % (rows,))

# ---------------------------------------------------------------- the index was ACTUALLY used
# last_search is the connection's own record of its latest search, so the search and the read of it run in one process
# (the search is the prelude; the last line of the output is the read).
LAST_SEARCH = "SELECT count(*) FROM fractal_search('corpus','v',%s::DOUBLE[],5,'{}');" % sql_list(QUERY)
rc, out, err = q("SELECT (fractal_index_info('corpus_idx')::JSON->>'$.last_search.used_index');", LAST_SEARCH)
last = out.strip().split("\n")[-1] if out.strip() else ""
check("the last search used the index", rc == 0 and last == "true", "got %r err=%r" % (out.strip(), err[:200]))

rc, out, err = q("SELECT (fractal_index_info('corpus_idx')::JSON->>'$.last_search.rows_scanned')::BIGINT;", LAST_SEARCH)
last = out.strip().split("\n")[-1] if out.strip() else ""
scanned = int(last) if rc == 0 and last else -1
check("the index scanned far fewer rows than the table holds (the index was really used)",
      rc == 0 and 0 < scanned < NROWS // 4,
      "rows_scanned=%r of %d" % (out.strip(), NROWS))

# ---------------------------------------------------------------- the delta
DELTA = [QUERY[0] + 1e-9] + QUERY[1:]
rc, out, err = q("INSERT INTO corpus VALUES (%d,%s);" % (NROWS + 1, sql_list(DELTA)))
check("a row committed after the build is accepted", rc == 0, "rc=%d err=%r" % (rc, err[:200]))

rc, out, err = q("SELECT doc_id, distance FROM fractal_search('corpus','v',%s::DOUBLE[],3,'{}');" % sql_list(QUERY))
first = out.strip().split("\n")[0] if out.strip() else ""
check("the indexed search finds the row committed after the build (the delta)",
      rc == 0 and first.startswith(str(NROWS + 1)), "got %r err=%r" % (first, err[:250]))

rc, out, err = q("SELECT (fractal_index_info('corpus_idx')::JSON->>'$.has_delta');")
check("fractal_index_info reports the delta", rc == 0 and out.strip() == "true", "got %r" % out.strip())

rc, out, err = q("SELECT (fractal_index_info('corpus_idx')::JSON->>'$.stale');")
check("fractal_index_info reports the index as stale", rc == 0 and out.strip() == "true", "got %r" % out.strip())

# ---------------------------------------------------------------- the catalog, the verdict, refresh and the ids option
rc, out, err = q("SELECT name||'|'||table_name||'|'||vector_col||'|'||rows||'|'||rows_now||'|'||stale||'|'||status FROM fractal_index_list();")
check("fractal_index_list has one row per index with table, column, rows, rows now, stale and status",
      rc == 0 and out.strip() == "corpus_idx|corpus|v|%d|%d|true|stale" % (NROWS, NROWS + 1), "rc=%d out=%r err=%r" % (rc, out.strip(), err[:200]))

rc, out, err = q("SELECT (fractal_index_info('corpus_idx')::JSON->>'$.status')||'|'||(fractal_index_info('corpus_idx')::JSON->>'$.rows_added_since_build')"
                 "||'|'||(fractal_index_info('corpus_idx')::JSON->>'$.advice[0]');")
check("rows added since the build make the verdict stale and the advice says refresh",
      rc == 0 and out.strip().startswith("stale|1|refresh:"), "got %r err=%r" % (out.strip(), err[:200]))

rc, out, err = q("SELECT (fractal_index_info('corpus_idx')::JSON->>'$.generation')::BIGINT;")
gen_before_refresh = int(out.strip()) if rc == 0 and out.strip().isdigit() else -1
rc, out, err = q("SELECT (r::JSON->>'$.added')||'|'||(r::JSON->>'$.rows')||'|'||(r::JSON->>'$.generation')||'|'||(r::JSON->>'$.refreshed') FROM (SELECT fractal_index_refresh('corpus_idx') AS r);")
check("fractal_index_refresh folds the added row in and writes the next generation",
      rc == 0 and out.strip() == "1|%d|%d|true" % (NROWS + 1, gen_before_refresh + 1), "got %r err=%r" % (out.strip(), err[:250]))

rc, out, err = q("SELECT (i::JSON->>'$.has_delta')||'|'||(i::JSON->>'$.stale')||'|'||(i::JSON->>'$.rows_indexed')||'|'||(i::JSON->>'$.generation')||'|'||(i::JSON->>'$.rows_added_since_build') FROM (SELECT fractal_index_info('corpus_idx') AS i);")
check("after a refresh nothing is stale", rc == 0 and out.strip() == "false|false|%d|%d|0" % (NROWS + 1, gen_before_refresh + 1), "got %r err=%r" % (out.strip(), err[:200]))

rc, out, err = q("SELECT count(DISTINCT generation) FROM fractal_index_cells WHERE name = 'corpus_idx';")
check("a refresh leaves one generation of cells behind", rc == 0 and out.strip() == "1", "got %r" % out.strip())

# last_search is per-connection state, so the search runs as the prelude of the very call that reads it
LAST = ("SELECT (fractal_index_info('corpus_idx')::JSON->'$.last_search'->>'$.used_index')||'|'||"
        "(fractal_index_info('corpus_idx')::JSON->'$.last_search'->>'$.rows_scanned');")
rc, out, err = q(LAST, "SELECT doc_id FROM fractal_search('corpus','v',%s::DOUBLE[],3,'{}');" % sql_list(QUERY))
lines = out.strip().split("\n") if out.strip() else []
first, last = (lines[0], lines[-1]) if lines else ("", "")
used, _, scanned_after = last.partition("|")
check("the refreshed row is found first, served from the cells (the index scanned far fewer rows than the table)",
      rc == 0 and first == str(NROWS + 1) and used == "true" and scanned_after.isdigit() and int(scanned_after) < NROWS // 4,
      "first=%r last_search=%r err=%r" % (first, last, err[:200]))

rc, out, err = q("SELECT (r::JSON->>'$.added')||'|'||(r::JSON->>'$.refreshed')||'|'||(r::JSON->>'$.generation') FROM (SELECT fractal_index_refresh('corpus_idx') AS r);")
check("a refresh with nothing to add changes nothing", rc == 0 and out.strip() == "0|false|%d" % (gen_before_refresh + 1), "got %r err=%r" % (out.strip(), err[:200]))
rc, out, err = q("SELECT fractal_index_refresh('no_such_index');")
check("refresh of an unknown index is refused", rc != 0 and "no index named" in err, "rc=%d err=%r" % (rc, err[:200]))

# the ids option: a short set is scanned exactly, a long one goes through the index and is filtered
def restricted(idset, k):
    return [i for i in EXACT_ALL if i in idset][:k]
CORPUS_ALL = CORPUS + [DELTA]
EXACT_ALL = sorted(range(1, NROWS + 2), key=lambda i: (ref_cosine_distance(CORPUS_ALL[i - 1], QUERY), i))
small = [5, 77, 100, 200, 300, NROWS + 1]
rc, out, err = q("SELECT doc_id FROM fractal_search('corpus','v',%s::DOUBLE[],4,'{\"ids\":%s}') ORDER BY distance, doc_id::BIGINT;" % (sql_list(QUERY), json.dumps(small)))
got = [int(x) for x in out.split()] if rc == 0 else []
check("ids with a short set returns the nearest of those rows (exactly)", got == restricted(set(small), 4), "got %r want %r err=%r" % (got, restricted(set(small), 4), err[:200]))
rc, out, err = q(LAST, "SELECT doc_id FROM fractal_search('corpus','v',%s::DOUBLE[],4,'{\"ids\":%s}');" % (sql_list(QUERY), json.dumps(small)))
check("ids with a short set reads only those rows", rc == 0 and out.strip().split("\n")[-1] == "false|%d" % len(small), "got %r err=%r" % (out.strip()[-60:], err[:200]))
rc, out, err = q("SELECT count(*) FROM fractal_search('corpus','v',%s::DOUBLE[],4,'{\"ids\":[]}');" % sql_list(QUERY))
check("ids with an empty set returns no rows", rc == 0 and out.strip() == "0", "got %r err=%r" % (out.strip(), err[:200]))
rc, out, err = q("SELECT count(*) FROM fractal_search('corpus','v',%s::DOUBLE[],4,'{\"ids\":[-5,1000000000]}');" % sql_list(QUERY))
check("ids that are not rows are ignored", rc == 0 and out.strip() == "0", "got %r err=%r" % (out.strip(), err[:200]))
big = [i for i in range(1, NROWS + 2) if i % 10 != 0] + [10 ** 6 + i for i in range(4200)]   # most rows, so the index's shortlist still has k left
rc, out, err = q("SELECT doc_id FROM fractal_search('corpus','v',%s::DOUBLE[],5,'{\"ids\":%s}');" % (sql_list(QUERY), json.dumps(big)))
got = [int(x) for x in out.split()] if rc == 0 else []
want = restricted(set(big), 5)
check("ids with a long set returns rows from the set and agrees with the exact answer",
      len(got) == 5 and all(g % 10 != 0 for g in got) and len(set(got) & set(want)) >= 4, "got %r want %r err=%r" % (got, want, err[:200]))
rc, out, err = q(LAST, "SELECT doc_id FROM fractal_search('corpus','v',%s::DOUBLE[],5,'{\"ids\":%s}');" % (sql_list(QUERY), json.dumps(big)))
check("ids with a long set used the index", rc == 0 and out.strip().split("\n")[-1].startswith("true|"), "got %r err=%r" % (out.strip()[-60:], err[:200]))
tiny = [3, 4, 5]
rc, out, err = q("SELECT doc_id FROM fractal_search('corpus','v',%s::DOUBLE[],5,'{\"ids\":%s}') ORDER BY distance, doc_id::BIGINT;" % (sql_list(QUERY), json.dumps(tiny + [10 ** 6 + i for i in range(4200)])))
got = [int(x) for x in out.split()] if rc == 0 else []
rc2, out2, err2 = q(LAST, "SELECT doc_id FROM fractal_search('corpus','v',%s::DOUBLE[],5,'{\"ids\":%s}');" % (sql_list(QUERY), json.dumps(tiny + [10 ** 6 + i for i in range(4200)])))
check("when the index leaves fewer than k rows the set is scanned exactly", got == restricted(set(tiny), 5) and out2.strip().split("\n")[-1].startswith("false|"), "got %r last=%r" % (got, out2.strip()[-60:]))
for label, bad in (("a string", '"1,2"'), ("an object", '{"a":1}'), ("a non-integer item", '["x"]')):
    rc, out, err = q("SELECT * FROM fractal_search('corpus','v',%s::DOUBLE[],3,'{\"ids\":%s}');" % (sql_list(QUERY), bad.replace('"', '\\"')))
    check("ids %s is refused" % label, rc != 0 and "ids must be a JSON array" in err, "rc=%d err=%r" % (rc, err[:200]))

# the catalog outlives the table it indexes: a dropped table is orphaned, not an error
rc, out, err = q("CREATE OR REPLACE TABLE orph(id INTEGER PRIMARY KEY, v DOUBLE[]); INSERT INTO orph SELECT i, [sin(i), cos(i), sin(i*2), cos(i*3)] FROM range(1, 61) t(i);"
                 " SELECT fractal_index_create('orph','v','{\"name\":\"orph_ix\",\"vector_format\":\"FP32\"}'); DROP TABLE orph;")
rc, out, err = q("SELECT status FROM fractal_index_list() WHERE name = 'orph_ix';")
check("an index whose table was dropped is listed as orphaned (the list does not fail)", rc == 0 and out.strip() == "orphaned", "got %r err=%r" % (out.strip(), err[:200]))
rc, out, err = q("SELECT (i::JSON->>'$.status')||'|'||((i::JSON->>'$.advice[0]') LIKE '%no longer exist%') FROM (SELECT fractal_index_info('orph_ix') AS i);")
check("an orphaned index says the table is gone and recommends dropping it", rc == 0 and out.strip() == "orphaned|true", "got %r err=%r" % (out.strip(), err[:200]))
q("SELECT fractal_index_drop('orph_ix');")

# degraded: INT8 codes on tight clusters cannot reach the recall target, and the build's own calibration says so
# The 64 coordinates are built with list(... ORDER BY j) rather than list_transform(range(...), j -> ...):
# the arrow lambda is deprecated and rejected by DuckDB 2.x, while the aggregate form is accepted by
# every DuckDB line this gate runs on. The values are the same, in the same order.
rc, out, err = q("CREATE OR REPLACE TABLE tight(id INTEGER PRIMARY KEY, v DOUBLE[]);"
                 " INSERT INTO tight SELECT i, list(sin(((i % 20) + 1) * j * 0.37) + 0.05 * sin(i * j * 12.9898 + j) ORDER BY j) FROM range(1, 1201) t(i), range(1, 65) g(j) GROUP BY i;"
                 " SELECT fractal_index_create('tight','v','{\"name\":\"tight8\",\"vector_format\":\"INT8\"}');"
                 " SELECT fractal_index_create('tight','v','{\"name\":\"tight32\",\"vector_format\":\"FP32\"}');")
rc, out, err = q("SELECT (i::JSON->>'$.status')||'|'||((i::JSON->>'$.advice[0]') LIKE '%calibration reached recall%FP32%') FROM (SELECT fractal_index_info('tight8') AS i);")
check("an INT8 index whose calibration missed its target is degraded, and the advice names FP32", rc == 0 and out.strip() == "degraded|true", "got %r err=%r" % (out.strip(), err[:200]))
rc, out, err = q("SELECT fractal_index_info('tight32')::JSON->>'$.status';")
check("the same data as FP32 reaches its target and is ready", rc == 0 and out.strip() == "ready", "got %r err=%r" % (out.strip(), err[:200]))
q("SELECT fractal_index_drop('tight8'); SELECT fractal_index_drop('tight32'); DROP TABLE tight;")

# ---------------------------------------------------------------- agent_use_index
# The nearest-row agents scan exactly by default; with the key on and an index on the table and column they search through it.
# The agents reason after the search, so the mock reasoning plugin the build gate compiles is loaded for these calls.
MOCK = os.environ.get("FSQL_TEST_MOCK_REASONING", "")
PLUG = ("SELECT fractal_config_set('reasoning_plugin', '%s');\n" % MOCK.replace("'", "''")) if MOCK else ""
ROUTE = "fractal_agent_route_task(%s::DOUBLE[], 'corpus', 'v', 'id', 100, 10)" % sql_list(QUERY)
ROUTED = "SELECT (%s::JSON->>'$.routed_to') || '|' || (%s::JSON->>'$.confidence');" % (ROUTE, ROUTE)
USED = "SELECT coalesce(fractal_index_info('corpus_idx')::JSON->>'$.last_search.used_index', 'none');"
if not MOCK:
    print("ok: (agent_use_index checks skipped: no mock reasoning plugin given in FSQL_TEST_MOCK_REASONING)")
else:
    rc, out, err = q(USED, PLUG + "SELECT %s;" % ROUTE)
    last = out.strip().split("\n")[-1] if out.strip() else ""
    check("agent_use_index off (the default): route_task scans exactly and never touches the index",
          rc == 0 and last != "true", "got %r err=%r" % (out.strip()[-80:], err[:200]))
    rc, off_out, err = q(ROUTED, PLUG)
    off_val = off_out.strip().split("\n")[-1] if off_out.strip() else ""
    rc, out, err = q(USED, PLUG + "SELECT fractal_config_set('agent_use_index','on');\nSELECT %s;" % ROUTE)
    last = out.strip().split("\n")[-1] if out.strip() else ""
    check("agent_use_index on: route_task searches through the index", rc == 0 and last == "true",
          "got %r err=%r" % (out.strip()[-120:], err[:250]))
    rc, on_out, err = q(ROUTED, PLUG + "SELECT fractal_config_set('agent_use_index','on');")
    on_val = on_out.strip().split("\n")[-1] if on_out.strip() else ""
    check("through the index route_task returns the same capability and the same exact confidence",
          rc == 0 and on_val == off_val and "|" in on_val, "on=%r off=%r err=%r" % (on_val, off_val, err[:200]))
# recall_hybrid goes through the index too: with no filter the nearest rows come from the index; a filter's cohort becomes the search's
# ids set, which is scanned exactly (so it returns the scan's rows, and the index is not recorded as used)
RECALL = "fractal_agent_recall_hybrid('corpus', 'v', %s::DOUBLE[], %s, %s, 5, 'id')"
q("ALTER TABLE corpus ADD COLUMN grp VARCHAR; UPDATE corpus SET grp = CASE WHEN id % 2 = 0 THEN 'even' ELSE 'odd' END;")


def mem_ids(text):
    return [int(x) for x in re.findall(r'mem_id""?:(\d+)', text)]


stmt = "SELECT %s;" % (RECALL % (sql_list(QUERY), "NULL", "NULL"))
rc, off_out, err = q(stmt)
off_ids = mem_ids(off_out)
check("recall_hybrid scans exactly by default", rc == 0 and len(off_ids) == 5, "rc=%d out=%r err=%r" % (rc, off_out[-120:], err[:200]))
rc, on_out, err = q(stmt, "SELECT fractal_config_set('agent_use_index','on');")
on_ids = mem_ids(on_out)
check("recall_hybrid through the index returns the nearest row and k rows",
      rc == 0 and len(on_ids) == 5 and on_ids[0] == off_ids[0], "on=%r off=%r err=%r" % (on_ids, off_ids, err[:200]))
rc, out, err = q(USED, "SELECT fractal_config_set('agent_use_index','on');\nSELECT %s;" % (RECALL % (sql_list(QUERY), "NULL", "NULL")))
last = out.strip().split("\n")[-1] if out.strip() else ""
check("recall_hybrid really went through the index (fractal_index_info records the search)", rc == 0 and last == "true",
      "got %r err=%r" % (out.strip()[-120:], err[:250]))
fstmt = "SELECT %s;" % (RECALL % (sql_list(QUERY), "'grp'", "'even'"))
rc, foff, err = q(fstmt)
rc2, fon, err2 = q(fstmt, "SELECT fractal_config_set('agent_use_index','on');")
check("recall_hybrid with a filter through the index returns the same rows as the scan, all from the cohort",
      rc == 0 and rc2 == 0 and sorted(mem_ids(fon)) == sorted(mem_ids(foff)) and len(mem_ids(fon)) == 5 and all(i % 2 == 0 for i in mem_ids(fon)),
      "on=%r off=%r err=%r" % (mem_ids(fon), mem_ids(foff), (err + err2)[:200]))
rc, out, err = q("SELECT fractal_config_set('agent_use_index','maybe');")
check("agent_use_index accepts only on or off", rc != 0 and "agent_use_index" in err, "rc=%d err=%r" % (rc, err[:200]))
# the on/off config keys take the same spellings on every host, and the plugin reads 1
rc, out, err = q("SELECT fractal_config_get('http_allow_plaintext');", "SELECT fractal_config_set('http_allow_plaintext','on');")
check("http_allow_plaintext 'on' is stored the way the plugin reads it (1)", rc == 0 and out.strip().split("\n")[-1] == "1", "got %r err=%r" % (out.strip(), err[:200]))
rc, out, err = q("SELECT fractal_config_set('http_allow_plaintext','sometimes');")
check("http_allow_plaintext refuses a value that is not on or off", rc != 0 and "http_allow_plaintext" in err, "rc=%d err=%r" % (rc, err[:200]))

# ---------------------------------------------------------------- the exact fallback
rc, out, err = q("SELECT doc_id, distance FROM fractal_search('corpus','v',%s::DOUBLE[],3,'{\"use_index\":false}');" % sql_list(QUERY))
first = out.strip().split("\n")[0] if out.strip() else ""
check("with use_index=false the search is an exact scan", rc == 0 and first.startswith(str(NROWS + 1)),
      "got %r err=%r" % (first, err[:250]))

# ---------------------------------------------------------------- rebuild and drop
rc, out, err = q("SELECT fractal_index_rebuild('corpus_idx');")
check("fractal_index_rebuild rebuilds the index", rc == 0 and "corpus_idx" in out, "rc=%d err=%r" % (rc, err[:250]))

rc, out, err = q("SELECT (fractal_index_info('corpus_idx')::JSON->>'$.generation')::BIGINT;")
check("the rebuild moved the generation pointer", rc == 0 and int(out.strip()) > generation,
      "got %r (was %r)" % (out.strip(), generation))

rc, out, err = q("SELECT doc_id FROM fractal_search('corpus','v',%s::DOUBLE[],5,'{}');" % sql_list(QUERY))
check("the rebuilt index still answers", rc == 0 and out.strip() != "", "rc=%d err=%r" % (rc, err[:250]))

rc, out, err = q("SELECT fractal_index_drop('corpus_idx');")
check("fractal_index_drop drops the index", rc == 0 and out.strip() == "1", "rc=%d out=%r" % (rc, out.strip()))

rc, out, err = q("SELECT fractal_index_info('corpus_idx');")
check("a dropped index is gone", rc != 0 and "no such index" in err, "rc=%d err=%r" % (rc, err[:200]))

# ---------------------------------------------------------------- every vector_format: build, recall, exact distances, really used
# INT8 and INT4 keep a compressed code and re-check the shortlist against the table; FP16 and FP32 keep (almost) the whole vector. The recall
# floors are the ones each format can promise at every cell; the distances are exact for all four.
TRUTH10 = EXACT[:10]
for fmt, floor in (("INT8", 0.60), ("INT4", 0.50), ("FP16", 0.98), ("FP32", 0.99)):
    name = "fm_" + fmt
    rc, out, err = q("SELECT fractal_index_create('corpus','v','{\"name\":\"%s\",\"nlist\":16,\"vector_format\":\"%s\"}');" % (name, fmt), PRELUDE)
    check("a %s index builds" % fmt, rc == 0 and name in out, "rc=%d out=%r err=%r" % (rc, out[:160], err[:200]))
    if rc != 0:
        continue
    rc, out, err = q("SELECT (fractal_index_info('%s')::JSON->>'$.format') || '|' || (fractal_index_info('%s')::JSON->>'$.rows_indexed');" % (name, name))
    check("%s: fractal_index_info reports the format and the rows" % fmt, rc == 0 and out.strip() == "%s|%d" % (fmt, NROWS), "got %r" % out.strip())
    # every cell probed: the recall floor, and every returned distance is the exact cosine
    rc, out, err = q("SELECT doc_id, distance FROM fractal_search('corpus','v',%s::DOUBLE[],10,'{\"index\":\"%s\",\"nprobe\":16}');" % (sql_list(QUERY), name))
    got = []
    for line in out.strip().split("\n"):
        parts = line.split(",")
        if len(parts) >= 2:
            try:
                got.append((int(parts[0]), float(parts[1])))
            except ValueError:
                pass
    hit = len({d for d, _ in got} & set(TRUTH10)) / 10.0
    check("%s: recall@10 at every cell is at least %.2f (got %.2f)" % (fmt, floor, hit), rc == 0 and hit >= floor, "rc=%d err=%r" % (rc, err[:200]))
    check("%s: every returned distance is the exact cosine" % fmt,
          len(got) == 10 and all(abs(d - ref_cosine_distance(CORPUS[i - 1], QUERY)) < 1e-9 for i, d in got), got[:3])
    # few cells probed: the index, not a flat scan, did the work
    rc, out, err = q("SELECT count(*) FROM fractal_search('corpus','v',%s::DOUBLE[],10,'{\"index\":\"%s\",\"nprobe\":2}');"
                     "SELECT (fractal_index_info('%s')::JSON->>'$.last_search.used_index') || '|' || (fractal_index_info('%s')::JSON->>'$.last_search.rows_scanned');"
                     % (sql_list(QUERY), name, name, name))
    lines = [x for x in out.strip().split("\n") if x.strip()]
    used = lines[-1].split("|") if lines else []
    check("%s: a search at nprobe 2 goes through the index and scans fewer rows than the table" % fmt,
          rc == 0 and len(used) == 2 and used[0] == "true" and 0 < int(used[1]) < NROWS, "rc=%d out=%r err=%r" % (rc, out[:200], err[:150]))
    q("SELECT fractal_index_drop('%s');" % name)

print("index: %d checks, %d passed, %d failed" % (PASSED + FAILED, PASSED, FAILED))
sys.exit(1 if FAILED else 0)
