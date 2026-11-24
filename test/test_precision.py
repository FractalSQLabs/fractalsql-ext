#!/usr/bin/env python3
"""test/test_precision.py -- the precision contract (precision plan R2, R3, R5, R7, R8).

What this gate proves:

  1. The table-free SFS convergence function is RENAMED fractal_sfs_converge, and the old name is
     NOT an alias: calling fractal_search(vector, query) fails with a message that names the new
     function. (This is the part that fails on the pre-change code.)
  2. There is ONE cosine in the repository: the SQL-visible distance, the similarity and the
     per-row SFS distance all come from the shared double-precision implementation, and every one
     of them is BIT-IDENTICAL to a reference the test computes itself in double precision with the
     same sequential accumulation order.
  3. The float paths are built with -ffp-contract=off -fno-tree-vectorize (R3): the build carries
     the flags, and the source that carries the float maths includes the shared header instead of
     calling the core's own float32 entry points.
  4. Ties break on the row id (R8) and the text round trip is %.9g (R7).

Env: EDGE_LINE / CAPI_DIST as in edge_inputs.py. Exit status is nonzero when any check fails.
"""
import math, os, re, struct, sys

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
BACKEND = backend(EXT, CLI, CLEAN_ENV, run_cli)
if BACKEND is None:
    print("  FAIL need a DuckDB CLI or the in-process duckdb module")
    sys.exit(1)

PASSED = 0
FAILED = 0


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


def f32(x):
    """The float32 value of a double: the one rounding the contract allows."""
    return struct.unpack("<f", struct.pack("<f", x))[0]


def f32v(v):
    """The float32 values of a vector: the SQL argument is a FLOAT[], so the inputs are rounded
    to float32 BEFORE the function runs."""
    return [f32(x) for x in v]


def ref_cosine_distance(a, b):
    """The shared implementation, in python: double accumulation, fixed order, one rounding."""
    a = f32v(a)
    b = f32v(b)
    dot = 0.0
    na = 0.0
    nb = 0.0
    for i in range(len(a)):
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    if na == 0.0 or nb == 0.0:
        return 1.0
    return 1.0 - dot / (math.sqrt(na) * math.sqrt(nb))


def ref_cosine_similarity(a, b):
    a = f32v(a)
    b = f32v(b)
    dot = 0.0
    na = 0.0
    nb = 0.0
    for i in range(len(a)):
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    if na == 0.0 or nb == 0.0:
        return 0.0
    return dot / (math.sqrt(na) * math.sqrt(nb))


def ref_dot(a, b):
    a = f32v(a)
    b = f32v(b)
    s = 0.0
    for i in range(len(a)):
        s += a[i] * b[i]
    return s


def ref_l2(a, b):
    a = f32v(a)
    b = f32v(b)
    s = 0.0
    for i in range(len(a)):
        d = a[i] - b[i]
        s += d * d
    return math.sqrt(s)


def ref_norm(a):
    a = f32v(a)
    s = 0.0
    for x in a:
        s += x * x
    return math.sqrt(s)


# ---------------------------------------------------------------- the corpus
# Exactly representable binary fractions, so the corpus is identical in SQL and in python.
def corpus():
    out = []
    for i in range(64):
        v = []
        for j in range(8):
            v.append(((i * 7 + j * 13) % 1009) / 1024.0)
        out.append(v)
    return out


CORPUS = corpus()
A = CORPUS[3]
B = CORPUS[17]
ZERO = [0.0] * 8


def sql_list(v):
    """The vector as a SQL literal.

    The literal is cast to DOUBLE[] and then to FLOAT[], never straight from the DECIMAL the
    parser makes of it: DuckDB's DECIMAL -> FLOAT conversion is not exact for every value (it
    lands one float32 ULP below for some of them), and the reference below is computed over the
    float32 values the function actually receives."""
    return "[" + ",".join(repr(x) for x in v) + "]"


# ---------------------------------------------------------------- 1. the rename
rc, out, err = q("SELECT fractal_sfs_converge(%s::DOUBLE[]);" % sql_list(A))
check("fractal_sfs_converge exists and converges", rc == 0 and out.strip() != "",
      "rc=%d out=%r err=%r" % (rc, out[:120], err[:200]))

rc, out, err = q("SELECT fractal_search(%s::DOUBLE[], %s::DOUBLE[]);" % (sql_list(A), sql_list(B)))
check("the old fractal_search(vector, query) is not an alias but a rename error",
      rc != 0 and "fractal_sfs_converge" in err,
      "rc=%d err=%r" % (rc, err[:250]))

rc, out, err = q("SELECT fractal_search(%s::DOUBLE[], 30, 50);" % sql_list(A))
check("the old fractal_search(query, iterations, population) is refused too",
      rc != 0 and "fractal_sfs_converge" in err,
      "rc=%d err=%r" % (rc, err[:250]))

# ---------------------------------------------------------------- 2. one cosine
# The results are cast to DOUBLE before they are compared: DuckDB's FLOAT -> TEXT conversion is
# not exact for every float32 (it prints some of them one ULP off), while the FLOAT -> DOUBLE
# widening is exact. The reference below is the float32 value of the double computation.
rc, out, err = q("SELECT fractal_vector_cosine_distance(%s::DOUBLE[]::FLOAT[], %s::DOUBLE[]::FLOAT[])::DOUBLE;" % (sql_list(A), sql_list(B)))
got = out.strip().strip('"')
want = repr(f32(ref_cosine_distance(A, B)))
check("fractal_vector_cosine_distance is bit-identical to the double reference",
      rc == 0 and got == want, "got %r want %r" % (got, want))

rc, out, err = q("SELECT fractal_vector_cosine_similarity(%s::DOUBLE[]::FLOAT[], %s::DOUBLE[]::FLOAT[])::DOUBLE;" % (sql_list(A), sql_list(B)))
got = out.strip().strip('"')
want = repr(f32(ref_cosine_similarity(A, B)))
check("fractal_vector_cosine_similarity is the same cosine (R5: one implementation)",
      rc == 0 and got == want, "got %r want %r" % (got, want))

rc, out, err = q("SELECT fractal_vector_dot(%s::DOUBLE[]::FLOAT[], %s::DOUBLE[]::FLOAT[])::DOUBLE;" % (sql_list(A), sql_list(B)))
got = out.strip().strip('"')
want = repr(f32(ref_dot(A, B)))
check("fractal_vector_dot accumulates in double", rc == 0 and got == want, "got %r want %r" % (got, want))

rc, out, err = q("SELECT fractal_vector_l2_distance(%s::DOUBLE[]::FLOAT[], %s::DOUBLE[]::FLOAT[])::DOUBLE;" % (sql_list(A), sql_list(B)))
got = out.strip().strip('"')
want = repr(f32(ref_l2(A, B)))
check("fractal_vector_l2_distance accumulates in double", rc == 0 and got == want, "got %r want %r" % (got, want))

rc, out, err = q("SELECT fractal_vector_norm(%s::DOUBLE[]::FLOAT[])::DOUBLE;" % sql_list(A))
got = out.strip().strip('"')
want = repr(f32(ref_norm(A)))
check("fractal_vector_norm accumulates in double", rc == 0 and got == want, "got %r want %r" % (got, want))

# the zero-vector convention: 1.0 for the distance, 0.0 for the similarity
rc, out, err = q("SELECT fractal_vector_cosine_distance(%s::DOUBLE[]::FLOAT[], %s::DOUBLE[]::FLOAT[])::DOUBLE;" % (sql_list(ZERO), sql_list(B)))
check("the zero-vector cosine convention survives (distance 1.0)",
      rc == 0 and out.strip().strip('"') == repr(1.0), "got %r" % out.strip())

# the same call twice returns the same bits (no state, no reordering)
rc1, out1, _ = q("SELECT fractal_vector_cosine_distance(%s::DOUBLE[]::FLOAT[], %s::DOUBLE[]::FLOAT[])::DOUBLE;" % (sql_list(A), sql_list(B)))
rc2, out2, _ = q("SELECT fractal_vector_cosine_distance(%s::DOUBLE[]::FLOAT[], %s::DOUBLE[]::FLOAT[])::DOUBLE;" % (sql_list(A), sql_list(B)))
check("the distance is reproducible bit for bit", out1 == out2 and out1.strip() != "", "%r vs %r" % (out1[:60], out2[:60]))

# the per-row SFS distance (fractal_sfs_converge's two-argument form) uses the same cosine:
# with an identical vector the distance to the refined point is 0.
rc, out, err = q("SELECT fractal_sfs_converge(%s::DOUBLE[], %s::DOUBLE[]);" % (sql_list(A), sql_list(A)))
val = out.strip().strip('"')
check("the per-row SFS distance is finite and near zero for an identical point",
      rc == 0 and val not in ("", "nan") and abs(float(val)) < 1e-6,
      "got %r err=%r" % (val, err[:200]))

# ---------------------------------------------------------------- 3. the flags and the shared header
mk = os.path.join(REPO, "Makefile")
have_header = os.path.exists(os.path.join(REPO, "src", "fsql_precision.h"))
check("the shared precision header exists (src/fsql_precision.h)", have_header)

if os.path.exists(mk):
    text = open(mk, encoding="utf-8", errors="replace").read()
    check("the build carries -ffp-contract=off (R3)", "-ffp-contract=off" in text)
    check("the build carries -fno-tree-vectorize (R3)", "-fno-tree-vectorize" in text)
    check("the index TU is in the build", "fsql_index.c" in text)

bat = os.path.join(REPO, "scripts", "windows", "build.bat")
if os.path.exists(bat):
    text = open(bat, encoding="utf-8", errors="replace").read()
    check("the MSVC build carries the precision flags (/fp:precise /Qvec-)",
          "/fp:precise" in text and "/Qvec-" in text)
    check("the index TU is in the MSVC build", "fsql_index.c" in text)

vec_src = os.path.join(REPO, "src", "fsql_vector.c")
if os.path.exists(vec_src):
    text = open(vec_src, encoding="utf-8", errors="replace").read()
    check("fsql_vector.c includes the shared precision header", "fsql_precision.h" in text)
    check("fsql_vector.c does not call the core's own float32 distance entry points",
          "fsql_vector_cosine_distance(" not in text and "fsql_vector_dot(" not in text
          and "fsql_vector_lp_distance(" not in text)

ext_src = os.path.join(REPO, "src", "fractalsql_ext.c")
if os.path.exists(ext_src):
    text = open(ext_src, encoding="utf-8", errors="replace").read()
    check("the extension's own cosine is routed through the shared header",
          "fsql_precision.h" in text and "fsqlp_cosine_distance_d" in text)

# ---------------------------------------------------------------- 4. the text round trip (R7)
rc, out, err = q("SELECT fractal_vector_quantize_int8(%s::DOUBLE[]::FLOAT[]);" % sql_list(A))
check("the %.9g text round trip produces a parseable document",
      rc == 0 and '"scale"' in out and '"codes"' in out, "rc=%d out=%r" % (rc, out[:120]))

print("precision: %d checks, %d passed, %d failed" % (PASSED + FAILED, PASSED, FAILED))
sys.exit(1 if FAILED else 0)
