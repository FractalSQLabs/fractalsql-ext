"""test/fsql_test_backend.py -- the two ways a gate driver can reach the extension.

The CLIs are the harness's normal path (one process per statement, so a crash in one statement
cannot disturb another). Where no CLI is available -- a developer's machine, a container without the
CLI -- the in-process `duckdb` module is used instead: the same extension, the same SQL, in one
connection. Both report (rc, stdout, stderr) so the drivers do not care which one ran.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I drops the script dir

from harness_common import timeout_for, SAN, san_runtime  # noqa: E402  (the path insert above has to come first)


_SAN_RUNTIME = None


def san_env(env):
    """CAPI_SAN set (a sanitizer cell): the CLI under test is the stock binary hosting a -fsanitize=address or
    -fsanitize=undefined extension, so its runtime is preloaded into every CLI call -- and the instrumented mock
    plugins the drivers load join the resident runtime. Same contract as parity_diff.py and edge_inputs.py."""
    global _SAN_RUNTIME
    if SAN:
        if _SAN_RUNTIME is None:
            _SAN_RUNTIME = san_runtime()
        if _SAN_RUNTIME:
            env.setdefault("LD_PRELOAD", _SAN_RUNTIME)
            env.setdefault("ASAN_OPTIONS", "detect_leaks=0:abort_on_error=0:halt_on_error=1")
            env.setdefault("UBSAN_OPTIONS", "print_stacktrace=1:halt_on_error=1")
    return env


class CliBackend(object):
    """One CLI process per statement. With `db` (a database file) the processes share one database, so a gate that
    builds state in one statement and reads it in the next sees it; without it each process is a fresh in-memory one."""

    name = "cli"

    def __init__(self, cli, ext, clean_env, run_cli, db=None):
        self.db = db
        self.cli = cli
        self.ext = ext
        self.clean_env = clean_env
        self.run_cli = run_cli

    def run(self, sql, prelude=""):
        script = "LOAD '%s';\n%s\n%s\nSELECT fractal_release();\n" % (self.ext, prelude, sql)
        env = san_env(dict(self.clean_env))
        p = self.run_cli([self.cli, "-unsigned", "-csv", "-noheader", "-bail"] + ([self.db] if self.db else []), input=script,
                         capture_output=True, text=True, encoding="utf-8", errors="replace",
                         env=env, timeout=timeout_for(300))
        out = p.stdout
        # the script ends with SELECT fractal_release(), which prints one "true"; it is not part of the statement's result
        if p.returncode == 0 and out.endswith("true\n"):
            out = out[:-len("true\n")]
        return p.returncode, out, p.stderr


class PyBackend(object):
    """The in-process duckdb module."""

    name = "python"

    def __init__(self, ext):
        import duckdb
        self.con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
        self.con.execute("LOAD '%s'" % ext.replace("\\", "/"))

    def run(self, sql, prelude=""):
        try:
            if prelude:
                self.con.execute(prelude)
            rows = self.con.execute(sql).fetchall()
            out = "\n".join(",".join("" if v is None else str(v) for v in r) for r in rows)
            return 0, out, ""
        except Exception as e:                     # noqa: BLE001 - the message is the contract
            return 1, "", str(e)


def backend(ext, cli=None, clean_env=None, run_cli=None, db=None):
    """The CLI when there is one, the in-process module otherwise. None when neither is available."""
    if cli and run_cli:
        return CliBackend(cli, ext, clean_env or {}, run_cli, db)
    try:
        import duckdb  # noqa: F401
    except ImportError:
        return None
    return PyBackend(ext)
