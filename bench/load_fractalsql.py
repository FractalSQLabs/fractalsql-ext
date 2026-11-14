"""
bench/load_fractalsql.py -- shared helper to LOAD the local, unsigned
fractalsql build into a DuckDB connection.

DuckDB extensions aren't distro-packaged; there's no `CREATE EXTENSION`.
The bench scripts LOAD the .duckdb_extension built by build.sh directly
by path, same as test/smoke_test.sql and the install-test.yml CI job.
"""

# PEP 563: the `str | None` annotation below uses PEP 604 union syntax, which
# evaluates at definition time without this import and raises TypeError on the
# README-advertised Python 3.9 floor (the import makes the annotations lazy).
from __future__ import annotations

import glob
import os

import duckdb


# DuckDB 1.1 and later refuse to change this setting while a database is
# running, so it has to be handed over when the connection is opened.
CONNECT_CONFIG = {"allow_unsigned_extensions": "true"}


def connect(db_path: str = ":memory:"):
    """
    Opens a DuckDB connection that is allowed to LOAD the local, unsigned
    fractalsql build. Use this instead of duckdb.connect() in any script
    that loads the extension.
    """
    return duckdb.connect(db_path, config=CONNECT_CONFIG)


def load_fractalsql_extension(conn, ext_path: str | None = None) -> str:
    """
    LOADs the fractalsql extension into `conn`. If `ext_path` is None,
    autodetects the first non-legacy build: dist/ first (matches
    install-test.yml's own `find dist/... -name '*.duckdb_extension'
    -not -name '*-legacy*'` convention), then build/ for native dev
    builds. Raises RuntimeError with a clear message if nothing is
    found or the file doesn't exist.

    Returns the resolved path actually loaded.
    """
    if ext_path is None:
        repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        candidates = sorted(
            p for p in glob.glob(os.path.join(repo_root, "dist", "**",
                                               "*.duckdb_extension"),
                                  recursive=True)
            if "-legacy" not in os.path.basename(p)
        )
        if not candidates:
            # Native dev builds (CMake Makefile / scripts\windows\build.bat)
            # land in build/, not dist/; fall back there.
            candidates = sorted(
                p for p in glob.glob(os.path.join(repo_root, "build", "**",
                                                  "*.duckdb_extension"),
                                     recursive=True)
                if "-legacy" not in os.path.basename(p)
            )
        if not candidates:
            raise RuntimeError(
                "no *.duckdb_extension found under dist/ or build/ -- run "
                "./build.sh (dist/) or 'make build' / scripts\\windows\\build.bat "
                "(build/) first, or pass "
                "--fractalsql-ext /path/to/fractalsql.duckdb_extension")
        ext_path = candidates[0]

    if not os.path.isfile(ext_path):
        raise RuntimeError(f"fractalsql extension not found at {ext_path}")

    # The setting can only be changed before a database is running, so a
    # connection that was opened without it cannot LOAD an unsigned build.
    allowed = conn.execute(
        "SELECT current_setting('allow_unsigned_extensions')"
    ).fetchone()[0]
    if not allowed:
        raise RuntimeError(
            "allow_unsigned_extensions is off on this connection - open it "
            "with load_fractalsql.connect() so the setting is passed at "
            "connect time"
        )

    conn.execute(f"LOAD '{ext_path}'")
    return ext_path
