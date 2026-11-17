"""test/test_duckdb.py -- version pin + SQL-surface self-checks for the
fractalsql-ext extension, run by the build_test harness and useful on
its own:

    python3 test/test_duckdb.py
    python3 test/test_duckdb.py --fractalsql-ext /path/to/fractalsql.duckdb_extension

Loads the built extension into a DuckDB connection (python `duckdb` module
preferred; falls back to a reduced CLI-driven mode when only a `duckdb`
CLI is available, since some of the STRUCT-returning probes are easier to
parse in-process) and asserts:

  * edition/version pins (2.0.1 / Community),
  * fractal_search self-distance < 1e-6,
  * the B1-B7 analytic function contracts from the port plan
    (change-point, periodogram, TDA, state fingerprint, cycle detect,
    optimize subset, vector quartet) with their exact error substrings,
  * fractal_agent_detect_loop fixtures (period-2 toggle flagged, varied
    states clear, ragged-log error, 3-arity call),
  * fractal_agent_outlier_intercept cosine/l2/unknown behavior,
  * fractal_search_telemetry doc_id=rowid joins and k-range errors.

Python floor: 3.6 (install containers run system python on RHEL 8) --
no `from __future__ import annotations`, no PEP 604 unions, no builtin
generic subscripts.
"""
import argparse
import json
import os
import glob
import sys

EXPECTED_VERSION = "2.0.1"
EXPECTED_EDITION = "Community"


def find_extension():
    """dist/ first (matches install-test.yml), then build/ for native
    dev builds; honors --fractalsql-ext."""
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for base in ("dist", "build"):
        hits = sorted(
            p for p in glob.glob(os.path.join(repo_root, base, "**",
                                              "*.duckdb_extension"),
                                 recursive=True)
            if "-legacy" not in os.path.basename(p)
        )
        if hits:
            return hits[0]
    return None


def expect_error(conn, fn, *substrings):
    """Assert conn executing fn raises and that stderr/exception text
    carries every substring. User-visible error text is the contract."""
    try:
        fn()
    except Exception as e:
        text = str(e)
        for s in substrings:
            if s not in text:
                raise AssertionError(
                    "error text missing %r: got %r" % (s, text))
        return
    raise AssertionError("expected an error, but the call succeeded")


def scalar(conn, sql):
    return conn.execute(sql).fetchone()[0]


def check_version_edition(conn):
    edition = scalar(conn, "SELECT fractal_edition()")
    version = scalar(conn, "SELECT fractal_version()")
    assert edition == EXPECTED_EDITION, (
        "edition %r != %r" % (edition, EXPECTED_EDITION))
    assert version == EXPECTED_VERSION, (
        "version %r != %r (re-pin EXPECTED_VERSION when bumping)" % (
            version, EXPECTED_VERSION))
    print("ok: edition=%s version=%s" % (edition, version))


def check_search_self_distance(conn):
    d = scalar(conn, "SELECT fractal_search("
                     "[0.6, 0.8, 0.0]::DOUBLE[], [0.6, 0.8, 0.0]::DOUBLE[])")
    assert d is not None and abs(d) < 1e-6, "self-distance %r >= 1e-6" % (d,)
    print("ok: self-distance %.2e < 1e-6" % abs(d))


def make_vectors(conn):
    conn.execute("CREATE OR REPLACE TABLE bt_vectors AS SELECT "
                 "i AS id, [i * 0.1, 0.2, 0.3]::DOUBLE[] AS emb "
                 "FROM range(1, 21) t(i)")


def check_telemetry(conn):
    make_vectors(conn)
    rows = conn.execute(
        "SELECT doc_id, distance, scan_pos "
        "FROM fractal_search_telemetry('bt_vectors', 'emb', "
        "[0.1, 0.2, 0.3]::DOUBLE[], 3)").fetchall()
    assert len(rows) == 3, "expected 3 rows, got %d" % len(rows)
    # On a real table doc_id is the rowid string; scan_pos is the
    # 0-indexed scan position (0 for the best row on a fresh table).
    doc_id, distance, scan_pos = rows[0]
    joined = conn.execute(
        "SELECT cast(emb AS VARCHAR) FROM bt_vectors "
        "WHERE rowid::VARCHAR = ?", [doc_id]).fetchall()
    assert len(joined) == 1, \
        "doc_id %r joined to %d rows (rowid contract broken)" % (doc_id,
                                                                len(joined))
    assert scan_pos == 0, "first row must have scan_pos 0, got %r" % (
        scan_pos,)
    # k range errors:
    expect_error(conn,
                 lambda: conn.execute(
                     "SELECT * FROM fractal_search_telemetry('bt_vectors', "
                     "'emb', [0.1, 0.2, 0.3]::DOUBLE[], 0)").fetchall(),
                 "fractalsql: k 0 out of range")
    print("ok: telemetry doc_id=rowid join, scan_pos 0, k range error")


def make_state_log(spec, n):
    """Build a flattened state log. Both fixtures use ONE-HOT 2-dim
    states so the two toggle states stay distinguishable by direction
    (a same-signed scalar stream would collapse to one fingerprint
    and false-positive):
      'toggle' repeats [1,0] / [0,1] (period 2), n states, n_bits 64;
      'vary' walks n distinct unit-norm directions (constant L2-norm
        trajectory, so the DFA check won't flag it, only fingerprints
        can)."""
    import math
    states = []
    for i in range(n):
        if spec == "toggle":
            v = [1.0, 0.0] if i % 2 == 0 else [0.0, 1.0]
        elif spec == "vary":
            # The 16-direction spread, verbatim from the reference gate
            # fixture (unit norms, distinct directions).
            dirs = [(1.0, 0.0), (0.8, 0.6), (0.6, 0.8), (0.0, 1.0),
                    (0.6, -0.8), (0.8, -0.6), (-0.6, 0.8), (-0.8, 0.6),
                    (-1.0, 0.0), (-0.8, -0.6), (-0.6, -0.8), (0.0, -1.0),
                    (0.28, 0.96), (0.96, 0.28), (-0.28, 0.96), (-0.96, 0.28)]
            v = list(dirs[i])
        else:  # vary32: a different genuine 32-direction spread; the
               # default n_bits keeps all 32 fingerprints distinct.
            theta = 2.0 * math.pi * i / 32.0
            v = [math.cos(theta), math.sin(theta)]
        states.extend(v)
    return states


def list_to_sql(values):
    return "[" + ", ".join("%.17g" % float(v) for v in values) + "]::DOUBLE[]"


def check_detect_loop(conn):
    # Period-2 one-hot toggle must be flagged (6-arity: n_bits=64,
    # seed=42.0, hamming_threshold=0 -- the wrapper defaults); 16 states
    # so the DFA step has its full floor too.
    r = conn.execute(
        "SELECT fractal_agent_detect_loop('ag', %s, 2, 64, 42.0, 0)"
        % list_to_sql(make_state_log("toggle", 16))).fetchone()[0]
    assert r["is_loop_detected"] is True, \
        "period-2 toggle must be flagged: %r" % (r,)
    assert r["agent_id"] == "ag"

    # 16 distinct directions over the wrapper defaults must clear.
    r = conn.execute(
        "SELECT fractal_agent_detect_loop('ag', %s, 2)"
        % list_to_sql(make_state_log("vary", 16))).fetchone()[0]
    assert r["is_loop_detected"] is False, \
        "16 distinct directions must clear: %r" % (r,)

    # 32 distinct-direction states at the default n_bits must clear too.
    s32 = conn.execute(
        "SELECT fractal_agent_detect_loop('ag', %s, 2)"
        % list_to_sql(make_state_log("vary32", 32))).fetchone()[0]
    assert s32["is_loop_detected"] is False, \
        "32 distinct directions must clear: %r" % (s32,)

    # 3-arity call (wrapper defaults for n_bits/seed/threshold):
    s3 = conn.execute(
        "SELECT fractal_agent_detect_loop('ag', %s, 2)"
        % list_to_sql(make_state_log("vary", 16))).fetchone()[0]
    assert set(s3.keys()) == {"agent_id", "dfa_exponent",
                              "is_loop_detected"}

    # Short log: a 2-state log clears the ">= 2 states" floor but is far
    # below the DFA's minimum, so the answer is best-effort, not an
    # error: dfa_exponent stays 0.0 and no cycle is flagged.
    s_short = conn.execute(
        "SELECT fractal_agent_detect_loop('ag', %s, 2)"
        % list_to_sql(make_state_log("toggle", 2))).fetchone()[0]
    assert s_short["dfa_exponent"] == 0.0, \
        "short log DFA must decline to 0.0: %r" % (s_short,)
    assert s_short["is_loop_detected"] is False, \
        "short log must not flag a cycle: %r" % (s_short,)

    # Ragged log (length not a multiple of dim):
    expect_error(conn,
                 lambda: conn.execute(
                     "SELECT fractal_agent_detect_loop('ag', %s, 3)"
                     % list_to_sql([0.1, 0.2])).fetchall(),
                 "not a multiple of dim")
    print("ok: detect_loop fixtures (toggle flagged, distinct clear, "
          "3-arity, short log best-effort, ragged error)")


def make_history(conn):
    """bt_badstate table for outlier_intercept: known-bad embeddings."""
    conn.execute("CREATE OR REPLACE TABLE bt_badstate AS SELECT "
                 "[0.99, 0.0, 0.0]::DOUBLE[] AS emb FROM range(0, 5) t(i)")


def check_outlier_intercept(conn):
    # The reference gate's boundary fixtures: a two-row bad-state table
    # (near-parallel probe intercepted under cosine at threshold 0.5;
    # small-magnitude probe allowed under l2 at threshold 0.8).
    make_history(conn)
    out = scalar(conn,
                 "SELECT fractal_agent_outlier_intercept("
                 "[0.95, 0.05, 0.0]::DOUBLE[], 'bt_badstate', 'emb', 0.5)")
    doc = json.loads(out)
    assert "intercepted" in doc and "metric" in doc and "reason" in doc, \
        "outlier_intercept JSON keys missing: %r" % (doc,)
    assert doc["metric"] == "cosine", doc
    assert doc["intercepted"] is True, \
        "cosine 0.5 must intercept a near-parallel probe: %r" % (doc,)

    out2 = scalar(conn,
                  "SELECT fractal_agent_outlier_intercept("
                  "[0.05, 0.0, 0.0]::DOUBLE[], 'bt_badstate', 'emb', 0.8, "
                  "'l2')")
    doc2 = json.loads(out2)
    assert doc2["metric"] == "l2", doc2
    assert doc2["intercepted"] is False, \
        "l2 0.8 must allow a small-magnitude probe: %r" % (doc2,)

    expect_error(conn,
                 lambda: conn.execute(
                     "SELECT fractal_agent_outlier_intercept("
                     "[0.6, 0.8, 0.0]::DOUBLE[], 'bt_badstate', 'emb', "
                     "0.5, 'chebyshev')").fetchall(),
                 "metric must be 'cosine' or 'l2'")
    print("ok: outlier_intercept cosine/l2/unknown")


def check_change_point(conn):
    # 40-point step, window 10, threshold 1.0 -> at least one index.
    series = [0.0] * 20 + [5.0] * 20
    r = scalar(conn, "SELECT fractal_change_point_detect(%s, 10, 1.0)"
               % list_to_sql(series))
    assert len(r) >= 1, "step change must yield indices, got %r" % (r,)
    assert all(isinstance(v, int) for v in r)

    expect_error(conn,
                 lambda: conn.execute(
                     "SELECT fractal_change_point_detect(%s, 0, 1.0)"
                     % list_to_sql(series)).fetchall(),
                 "win must be > 0")
    print("ok: change_point_detect indices + window error")


def check_periodogram(conn):
    # 32 points of a full cycle -> rows back.
    series = [0.5 * (2.0 * 3.141592653589793 * i / 32.0) for i in range(32)]
    rows = conn.execute("SELECT freq, power FROM fractal_periodogram("
                        "%s)" % list_to_sql(series)).fetchall()
    assert len(rows) > 0, "periodogram returned no rows"
    expect_error(conn,
                 lambda: conn.execute(
                     "SELECT * FROM fractal_periodogram("
                     "%s, 0)" % list_to_sql(series)).fetchall(),
                 "max_peaks out of range")
    print("ok: periodogram rows + max_peaks error")


def check_tda(conn):
    # 8-point square ring at threshold 2.5 -> the STRUCT surface
    # (h0_bars list + integer betti1); graph cycle rank, not H1.
    r = scalar(conn, "SELECT fractal_tda_persistence_diagram("
               "[0.0,0.0, 1.0,0.0, 1.0,1.0, 0.0,1.0, 0.0,0.0, 1.0,0.0, "
               "1.0,1.0, 0.0,1.0]::DOUBLE[], 2, 1, 2.5)")
    assert isinstance(r["betti1"], int), \
        "betti1 must be an integer, got %r" % (r,)
    assert isinstance(r["h0_bars"], list) and len(r["h0_bars"]) >= 1
    for bar in r["h0_bars"]:
        assert set(bar.keys()) == {"birth", "death"}, bar
    # Validation error:
    expect_error(conn,
                 lambda: conn.execute(
                     "SELECT fractal_tda_persistence_diagram("
                     "[0.0,0.0]::DOUBLE[], 3, 1, 1.0)").fetchall(),
                 "invalid input")
    print("ok: tda_persistence_diagram STRUCT surface + validation error")


def check_state_fingerprint(conn):
    blob = scalar(conn, "SELECT fractal_state_fingerprint("
                  "[0.1, 0.2, 0.3]::DOUBLE[])")
    # Default n_bits (128) -> a 16-byte blob.
    assert len(blob) == 16, "64-bit fingerprint must be 16 bytes, got %d" % (
        len(blob),)
    expect_error(conn,
                 lambda: conn.execute(
                     "SELECT fractal_state_fingerprint("
                     "[0.1, 0.2, 0.3]::DOUBLE[], 0)").fetchall(),
                 "n_bits out of range")
    print("ok: state_fingerprint 16-byte blob + n_bits error")


def check_cycle_detect(conn):
    blob = scalar(conn, "SELECT fractal_state_fingerprint("
                  "[0.1, 0.2]::DOUBLE[])")
    fps = [blob, blob, blob, blob]
    # SimHash of identical states is identical, so a loop is flagged
    # immediately; assert the detected row exists with cycle_len > 0.
    rows = conn.execute("SELECT at_index, cycle_len "
                        "FROM fractal_cycle_detect(?::BLOB[])", [fps])
    got = rows.fetchall()
    assert got, "cycle_detect returned no rows"
    cycle = got[0][1]
    assert cycle > 0, "identical-state stream must report a cycle, got %r" % (
        got[0],)
    print("ok: cycle_detect table function (identical-state stream)")


def check_spectrogram_entropy(conn):
    # Fixture contract from the reference gates: a steady tone reads LOW
    # (Hann spreads it over a few bins), a constant frame reports exactly
    # 0.0 (never NaN), and defaults are window 64, hop 32, max_frames 4096.
    rows = conn.execute(
        "SELECT fractal_spectrogram_entropy("
        "(SELECT list(0.5 + 0.5 * sin(2.0 * pi() * i / 8.0) ORDER BY i) "
        "FROM range(0, 64) t(i))) AS ent").fetchone()[0]
    assert rows is not None and len(rows) == 1,         "64 samples, window 64 -> exactly one frame, got %r" % (rows,)
    tone = rows[0]
    assert 0.0 <= tone <= 1.0 and tone < 0.6,         "a steady tone must read low entropy, got %r" % (tone,)
    const = conn.execute(
        "SELECT fractal_spectrogram_entropy("
        "(SELECT list(2.0 ORDER BY i) FROM range(0, 64) t(i)))").fetchone()[0]
    assert const is not None and abs(const[0]) == 0.0,         "constant frame must report exactly 0.0, got %r" % (const,)
    print("ok: spectrogram_entropy tone low, constant-frame 0.0")


def check_ledger_lock(conn, ext):
    # fractal_lock_destructive() is a one-way latch, per connection.
    import duckdb as _dm
    # On a fresh connection the destructive functions fail with the
    # enterprise-gate error (the enterprise tier is not loaded).
    expect_error(conn,
                 lambda: conn.execute("SELECT fractal_ledger_flush()").fetchall(),
                 "requires the FractalSQL Enterprise tier")
    assert conn.execute("SELECT fractal_lock_destructive()").fetchone()[0] == "locked"
    # After the latch the lock error fires BEFORE the enterprise
    # resolution, so a locked connection refuses identically on a
    # community build.
    expect_error(conn,
                 lambda: conn.execute("SELECT fractal_ledger_flush()").fetchall(),
                 "destructive ledger operations are locked on this connection")
    expect_error(conn,
                 lambda: conn.execute(
                     "SELECT fractal_ledger_reset_hard()").fetchall(),
                 "destructive ledger operations are locked on this connection")
    # The latch is per connection: a second connection's state is clean.
    conn2 = _dm.connect(config={"allow_unsigned_extensions": "true"})
    conn2.execute("LOAD '%s'" % os.path.abspath(ext))
    expect_error(conn2,
                 lambda: conn2.execute("SELECT fractal_ledger_flush()").fetchall(),
                 "requires the FractalSQL Enterprise tier")
    conn2.close()
    print("ok: ledger one-way lock (latch, pre-gate ordering, per connection)")


def check_optimize_subset(conn):
    # 10 items, pick k=3, value-weighted allocation. Bounds must pass
    # the core contract: the sum of the k largest upper bounds >= 1.0.
    items = list_to_sql([float(i + 1) for i in range(10)])
    bounds = list_to_sql([0.5] * 10)
    r = scalar(conn, "SELECT fractal_optimize_subset(%s, %s, 3)" % (
        items, bounds))
    weights = r["weights"]
    assert len(weights) == 10
    assert abs(sum(weights) - 1.0) < 1e-3, \
        "weights must sum to ~1, got %r" % (sum(weights),)
    assert r["score"] > 0
    expect_error(conn,
                 lambda: conn.execute(
                     "SELECT fractal_optimize_subset(%s, %s, 0)"
                     % (items, bounds)).fetchall(),
                 "k must satisfy")
    print("ok: optimize_subset STRUCT + k error")


def check_lp_distance(conn):
    # The fractal_vector_* set takes LIST(FLOAT) -- the only family on
    # FLOAT in this port (search/analytics/cognition take DOUBLE).
    a = "[1.0, 0.0]::FLOAT[]"
    b = "[0.0, 1.0]::FLOAT[]"
    d2 = scalar(conn, "SELECT fractal_vector_lp_distance(%s, %s, 2.0)" % (a, b))
    # p=2 matches the L2 mathematically but not bit-for-bit (pow-based
    # accumulation over float32) -- assert within float32 noise, not
    # double-equality.
    assert abs(d2 - 2.0 ** 0.5) < 1e-6, "lp p=2 must match L2, got %r" % (d2,)
    expect_error(conn,
                 lambda: conn.execute(
                     "SELECT fractal_vector_lp_distance(%s, %s, 0.0)"
                     % (a, b)).fetchall(),
                 "p must be > 0")
    print("ok: lp_distance p=2 == L2 + p>0 error")


def check_quantize_int8(conn):
    out = scalar(conn, "SELECT fractal_vector_quantize_int8("
                 "[0.5, -0.5, 1.0]::FLOAT[])")
    doc = json.loads(out)
    assert doc["scale"] > 0 and len(doc["codes"]) == 3, doc
    print("ok: quantize_int8 JSON {scale, codes}")


def check_quantize_binary_and_hamming(conn):
    blob = scalar(conn, "SELECT fractal_vector_quantize_binary("
                  "[0.5, -0.5, 1.0, -1.0]::FLOAT[])")
    # 4 dims -> 1 byte
    assert len(blob) == 1
    # 9 dims -> 2 bytes; 2 dims -> 1 byte: a REAL length mismatch (the
    # error text is the contract).
    expect_error(conn,
                 lambda: conn.execute(
                     "SELECT fractal_vector_hamming_distance("
                     "fractal_vector_quantize_binary("
                     "[0.5, -0.5, 1.0, -1.0, 0.5, -0.5, 1.0, -1.0, 0.5]::FLOAT[]), "
                     "fractal_vector_quantize_binary("
                     "[0.5, -0.5]::FLOAT[]))").fetchall(),
                 "non-empty and the same length")
    print("ok: quantize_binary packed length + hamming length error")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fractalsql-ext", default=None,
                    help="path to the built .duckdb_extension")
    args = ap.parse_args()

    ext = args.fractalsql_ext or find_extension()
    if ext is None:
        print("SKIP: no *.duckdb_extension under dist/ or build/ -- build "
              "first (./build.sh / make build) or pass --fractalsql-ext")
        return 0

    try:
        import duckdb as duckdb_mod
    except ImportError:
        # CLI fallback: only the scalar-safe probes run through the CLI
        # (the full harness covers gates). Reduce scope rather than fail
        # the whole suite on a missing pip module.
        print("duckdb python module not installed -- running reduced "
              "CLI-mode checks")
        return cli_mode(ext)

    # allow_unsigned_extensions must be set at connect time: the runtime
    # SET form is rejected on an already-open database ("Cannot change
    # allow_unsigned_extensions setting while database is running").
    conn = duckdb_mod.connect(
        config={"allow_unsigned_extensions": "true"})
    conn.execute("LOAD '%s'" % os.path.abspath(ext))

    check_version_edition(conn)
    check_search_self_distance(conn)
    check_telemetry(conn)
    check_detect_loop(conn)
    check_outlier_intercept(conn)
    check_change_point(conn)
    check_periodogram(conn)
    check_tda(conn)
    check_state_fingerprint(conn)
    check_cycle_detect(conn)
    check_optimize_subset(conn)
    check_spectrogram_entropy(conn)
    check_ledger_lock(conn, ext)
    check_lp_distance(conn)
    check_quantize_int8(conn)
    check_quantize_binary_and_hamming(conn)
    print("test_duckdb.py: all checks passed (%s)" % os.path.basename(ext))
    return 0


def cli_mode(ext):
    """Reduced probe set through a duckdb CLI binary (no python module
    needed). Struct-returning probes stay CLI-mode-out; the build_test
    gates cover the full SQL surface."""
    import subprocess
    import shutil
    cli = shutil.which("duckdb") or os.environ.get("FSQL_DUCKDB")
    if cli is None or not os.path.exists(cli):
        print("SKIP: no duckdb CLI on PATH, no FSQL_DUCKDB override")
        return 0
    sql = ("LOAD '%s';" % os.path.abspath(ext),
           "SELECT fractal_edition();",
           "SELECT fractal_version();",
           "SELECT fractal_search([0.6, 0.8, 0.0]::DOUBLE[], "
           "[0.6, 0.8, 0.0]::DOUBLE[]);")
    out = subprocess.run(
        [cli, "-bail", "-unsigned", "-c", "; ".join(sql)],
        capture_output=True, text=True, universal_newlines=True)
    if out.returncode != 0:
        print("FAIL: CLI mode rc=%d\n%s" % (out.returncode, out.stderr))
        return 1
    assert EXPECTED_VERSION in out.stdout, "version pin missing in CLI mode"
    assert "Community" in out.stdout, "edition pin missing in CLI mode"
    print("cli-mode ok (version + edition + self-search)")
    return 0


if __name__ == "__main__":
    sys.exit(main())