#!/usr/bin/env python3
"""test/valgrind_check.py -- helpers for test/valgrind_run.sh (build_test.sh --profile).

  valgrind_check.py slice <out.sql> <extension> [14|15|20]   write the engine slice: every default-environment parity case, each in
                                                  its own attached in-memory database, in ONE session (valgrind's start-up
                                                  cost is paid once); prints the CLI of that DuckDB line (default 1.5) to run it with
  valgrind_check.py verdict --ours <substring> [--ours <substring> ...] <valgrind.xml> [<valgrind.xml> ...]
                                                  read valgrind XML logs and decide: FAIL on any memcheck error, or any
                                                  definite/indirect leak, whose stack has a frame whose object file path
                                                  contains one of the <ours> substrings; everything else (the host's own
                                                  noise, possible leaks) is only counted. Exit 0 = pass, 1 = fail.
"""
import os, sys, xml.etree.ElementTree as ET
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I drops the script dir

LEAKS_THAT_FAIL = {"Leak_DefinitelyLost", "Leak_IndirectlyLost"}


def slice_(out, ext, line="15"):
    from harness_common import cases, latest_cli
    lines = ["LOAD '%s';" % ext, "PRAGMA threads=1;"]
    seen, n = set(), 0
    for _src, body, _expect, cenv, _diverges, _xskip in cases():
        if cenv or body in seen:                 # cases that need a special process environment are not part of the slice
            continue
        seen.add(body)
        n += 1
        lines += ["ATTACH ':memory:' AS c%d; USE c%d;" % (n, n), body.rstrip(), "USE memory; DETACH c%d;" % n]
    lines.append("SELECT fractal_release();")
    with open(out, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    cli = latest_cli(line)
    if not cli:
        sys.exit("no DuckDB %s.%s CLI found" % (line[0], line[1:]))
    print(cli)
    print("%d cases" % n, file=sys.stderr)


def verdict(xml_paths, ours):
    total = ours_n = leaks_n = 0
    bad = []
    for xml_path in xml_paths:
        try:
            root = ET.parse(xml_path).getroot()
        except (ET.ParseError, OSError) as e:
            print("  FAIL the valgrind log %s could not be read (%s)" % (os.path.basename(xml_path), e))
            return 1
        for err in root.iter("error"):
            kind = err.findtext("kind") or "?"
            total += 1
            frames = [(f.findtext("obj") or "", f.findtext("fn") or "?", f.findtext("file") or "", f.findtext("line") or "")
                      for f in err.iter("frame")]
            mine = [fr for fr in frames if any(o in fr[0] for o in ours)]
            if kind in LEAKS_THAT_FAIL or not kind.startswith("Leak_"):
                if mine:
                    ours_n += 1
                    bad.append((os.path.basename(xml_path), kind, err.findtext("what") or err.findtext("xwhat/text") or "", mine[:3]))
            else:
                leaks_n += 1
    print("  valgrind: %d report(s) in all, %d with a frame in our code, %d possible/other leak(s) ignored" % (total, ours_n, leaks_n))
    for name, kind, what, fr in bad[:12]:
        print("    FAIL [%s] %s %s" % (name, kind, what))
        for obj, fn, f, ln in fr:
            print("         at %s (%s%s)" % (fn, os.path.basename(f) or os.path.basename(obj), (":" + ln) if ln else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) >= 3 and a[0] == "slice":
        slice_(a[1], a[2], a[3] if len(a) > 3 else "15")
    elif a and a[0] == "verdict":
        ours, xmls, i = [], [], 1
        while i < len(a):
            if a[i] == "--ours" and i + 1 < len(a):
                ours.append(a[i + 1]); i += 2
            else:
                xmls.append(a[i]); i += 1
        if not ours or not xmls:
            sys.exit(__doc__)
        sys.exit(verdict(xmls, ours))
    else:
        sys.exit(__doc__)
