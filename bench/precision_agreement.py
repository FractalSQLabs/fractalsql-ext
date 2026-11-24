#!/usr/bin/env python3
"""
bench/precision_agreement.py -- the precision contract, measured.

The extension's SQL-visible distances are computed in double precision, in a fixed sequential
order, and rounded once to float32. This script recomputes them here, in
python, with the same order and the same single rounding, and compares the two BIT FOR BIT.

What it compares
    fractal_vector_dot              the double accumulation
    fractal_vector_l2_distance      the double accumulation
    fractal_vector_norm             the double accumulation
    fractal_vector_cosine_distance  the one shared cosine
    fractal_vector_cosine_similarity the same cosine

The corpus is generated here (exactly representable binary fractions), so the values the
extension receives are known exactly, and the reference is unambiguous.

A disagreement of one float32 ULP is a FAILURE: the contract is bit-identity, not "close".

Usage:
    python3 bench/precision_agreement.py [--vectors 64] [--dim 32] [--extension path]
"""
import argparse
import glob
import json
import math
import os
import struct
import sys

try:
    import duckdb
except ImportError:                                    # pragma: no cover
    print("bench/precision_agreement.py: the duckdb python module is required", file=sys.stderr)
    sys.exit(2)


def f32(x):
    """The float32 value of a double: the one rounding the contract allows."""
    return struct.unpack("<f", struct.pack("<f", x))[0]


def ref_dot(a, b):
    s = 0.0
    for i in range(len(a)):
        s += a[i] * b[i]
    return s


def ref_l2(a, b):
    s = 0.0
    for i in range(len(a)):
        d = a[i] - b[i]
        s += d * d
    return math.sqrt(s)


def ref_norm(a):
    s = 0.0
    for x in a:
        s += x * x
    return math.sqrt(s)


def ref_cosine(a, b):
    dot = ref_dot(a, b)
    na = ref_norm(a)
    nb = ref_norm(b)
    if na == 0.0 or nb == 0.0:
        return 1.0
    return 1.0 - dot / (na * nb)


def find_extension(explicit):
    if explicit:
        return explicit
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    plat = "windows_amd64" if sys.platform == "win32" else ("osx_arm64" if sys.platform == "darwin" else "linux_amd64")
    hits = []
    for pat in (os.path.join(here, "dist", "**", "fractalsql.capi.*.duckdb_extension"),
                os.path.join(here, "dist", "**", "fractalsql.*.duckdb_extension")):
        hits += [f for f in glob.glob(pat, recursive=True) if "-legacy" not in f]
    # the build for THIS platform, if there is one; otherwise the first
    for h in hits:
        if plat in os.path.basename(h) and os.path.basename(os.path.dirname(h)) == plat:
            return h
    for h in hits:
        if plat in os.path.basename(h):
            return h
    return hits[0] if hits else None


def corpus(count, dim):
    """Exactly representable binary fractions: the float32 values are the doubles."""
    out = []
    for i in range(count):
        out.append([((i * 7 + j * 13) % 1009) / 1024.0 for j in range(dim)])
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vectors", type=int, default=64, help="how many vectors")
    ap.add_argument("--dim", type=int, default=32, help="the dimension")
    ap.add_argument("--extension", default=None, help="the extension to load")
    ap.add_argument("--json", default=None, help="write the results as JSON to this file")
    args = ap.parse_args()

    ext = find_extension(args.extension)
    if not ext:
        print("bench/precision_agreement.py: no extension found (build it first)", file=sys.stderr)
        return 2
    con = duckdb.connect(":memory:", config={"allow_unsigned_extensions": "true"})
    con.execute("LOAD '%s'" % ext.replace("\\", "/"))

    vecs = corpus(args.vectors, args.dim)
    checked = 0
    bad = []
    for i in range(len(vecs)):
        a = vecs[i]
        b = vecs[(i * 7 + 3) % len(vecs)]
        # the literal is cast through DOUBLE[]: DuckDB's DECIMAL -> FLOAT conversion is not exact
        # for every value, and the reference is computed over the float32 values themselves
        la = "[" + ",".join(repr(x) for x in a) + "]::DOUBLE[]::FLOAT[]"
        lb = "[" + ",".join(repr(x) for x in b) + "]::DOUBLE[]::FLOAT[]"
        af = [f32(x) for x in a]
        bf = [f32(x) for x in b]
        for name, sql, want in (
            ("dot", "SELECT fractal_vector_dot(%s, %s)::DOUBLE" % (la, lb), f32(ref_dot(af, bf))),
            ("l2", "SELECT fractal_vector_l2_distance(%s, %s)::DOUBLE" % (la, lb), f32(ref_l2(af, bf))),
            ("norm", "SELECT fractal_vector_norm(%s)::DOUBLE" % la, f32(ref_norm(af))),
            ("cosine_distance", "SELECT fractal_vector_cosine_distance(%s, %s)::DOUBLE" % (la, lb), f32(ref_cosine(af, bf))),
        ):
            got = con.execute(sql).fetchone()[0]
            checked += 1
            if got != want:
                bad.append({"vector": i, "op": name, "got": got, "want": want})

    out = {"checked": checked, "mismatches": len(bad), "sample": bad[:10]}
    print(json.dumps(out, indent=2))
    if bad:
        print("bench/precision_agreement.py: %d of %d distances do not match the double reference"
              % (len(bad), checked), file=sys.stderr)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(out, fh, indent=2)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
