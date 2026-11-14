#!/usr/bin/env python3
"""test/harness_common.py -- shared plumbing for the capi test drivers (parity_diff.py,
edge_inputs.py): locating the DuckDB CLIs and the built extension bands, compiling the harness's mock
plugins, the sanitizer preload, and the mock reasoning plugin's canned-answer files. Importing this
module compiles the mocks once into a temp dir (PLUGINS)."""
import glob, hashlib, os, platform, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CAPI = os.path.dirname(HERE)
REPO = CAPI
sysname = platform.system()
osn = {"Darwin": "osx", "Windows": "windows"}.get(sysname, "linux")
arch = "amd64" if platform.machine().lower() in ("x86_64", "amd64") else "arm64"
PLAT = f"{osn}_{arch}"
# Windows: the DuckDB CLI is duckdb.exe, plugins are DLLs, and the harness's gcc-style compiler (MinGW/clang) is named by FSQL_CC,
# as in build_test.ps1. The mock plugins fopen the literal "/tmp/..." paths, which resolve to <drive>:\tmp: make sure it exists.
EXE = ".exe" if osn == "windows" else ""
SOEXT = ".dll" if osn == "windows" else ".so"
CC = os.environ.get("FSQL_CC") or "gcc"
if osn == "windows":
    os.makedirs("/tmp", exist_ok=True)
# CAPI_SAN=address|undefined: test the sanitizer build (make SAN=...) with the matching runtime
# preloaded into the (uninstrumented) DuckDB CLI. Any sanitizer report fails the case.
SAN = os.environ.get("CAPI_SAN", "")
DIST = os.environ.get("CAPI_DIST", os.path.join(CAPI, "dist", ("san-" + SAN) if SAN else PLAT))
# Which DuckDB lines to exercise. Under a sanitizer, cross-version equality is already established by the
# plain run (gate 47), so only 1.5.x is run to keep the gate inside its time budget; CAPI_LINES overrides.
LINES = os.environ.get("CAPI_LINES", "15" if SAN else "14,15,20").split(",")
def san_runtime():
    lib = {"address": "libasan.so", "undefined": "libubsan.so"}[SAN]
    out = subprocess.run([CC, "-print-file-name=" + lib], capture_output=True, text=True, encoding="utf-8", errors="replace").stdout.strip()
    return os.path.realpath(out) if os.path.exists(out) else None

def latest_cli(line):
    var = os.environ.get("FSQL_DUCKDB_" + line)
    if var and os.access(var, os.X_OK):
        return stage(var)
    pat = {"14": "v1.4.*", "15": "v1.5.*", "20": "v2.0.*"}[line]
    best = None
    for root in (os.path.join(REPO, "dist", "cli"), os.path.expanduser("~/duckdb-cli")):
        for d in glob.glob(os.path.join(root, pat)):
            exe = os.path.join(d, "duckdb" + EXE)
            if os.access(exe, os.X_OK):
                key = tuple(int(x) for x in os.path.basename(d)[1:].split("."))
                if best is None or key > best[0]:
                    best = (key, exe)
    return stage(best[1]) if best else None

def band_file(line):
    if line == "14":
        c = sorted(glob.glob(os.path.join(DIST, f"fractalsql.v1.4.*.{PLAT}.duckdb_extension")),
                   key=lambda p: [int(x) for x in re.findall(r"v1\.4\.(\d+)", p)])
        return stage(c[-1]) if c else None
    p = os.path.join(DIST, f"fractalsql.capi.{PLAT}.duckdb_extension")
    return stage(p) if os.path.exists(p) else None

# ---- the staging area ---------------------------------------------------
# The CLI, the extension it loads and the directory it runs in are staged on a
# native filesystem. A working copy that lives on a host folder shared into the
# machine is a FUSE mount: it is slow, and a failure inside it takes the
# guest's filesystem with it, so the heavy I/O of a gate run (loading the
# extension, the engine's spill and temp files, the vectorizer's store, the
# ledger) happens off the share instead. The corpus and the mock sources are
# still read from the working copy -- those are small, read-once reads.
#
# CAPI_STAGE_DIR chooses the directory; CAPI_NO_STAGE=1 keeps every path where
# it is (the old behaviour).
STAGE = None
def stage_dir():
    global STAGE
    if STAGE is None:
        if os.environ.get("CAPI_NO_STAGE") == "1":
            STAGE = ""
        else:
            tmpbase = None
            if osn == "windows":
                # The mock plugins open the literal "/tmp/..." paths, which a native process resolves against ITS current
                # drive. This script writes those files with the same literal paths, so the CLI has to run on this
                # process's drive (D: on GitHub's runners), not on the drive of the user temp directory.
                tmpbase = os.path.join(os.path.splitdrive(os.getcwd())[0] + os.sep, "tmp")
                os.makedirs(tmpbase, exist_ok=True)
            STAGE = os.environ.get("CAPI_STAGE_DIR") or tempfile.mkdtemp(prefix="capi-stage-", dir=tmpbase)
    return STAGE

# What each staged source looked like when it was copied, so a rebuilt artefact
# is copied again instead of being served from the copy of the old one.
_STAGED = {}
def _fingerprint(path):
    st = os.stat(path)
    return (st.st_mtime_ns, st.st_size)

def _is_executable(path):
    # On Windows there is no execute bit -- os.access(X_OK) answers "it is
    # there" for every file -- so the name decides.
    if os.name == "nt":
        return path.lower().endswith(".exe")
    return os.access(path, os.X_OK)

def stage(path):
    """A copy of `path` on the native filesystem, and the path to use in its place."""
    d = stage_dir()
    if not path or not d:
        return path
    src = os.path.abspath(path)
    # The digest names the staged DIRECTORY, never the file: the extension's
    # file name is what the engine derives the init symbol from ("fractalsql.capi.*"
    # -> fractalsql_init_c_api), so the staged extension keeps its own name.
    tag = hashlib.md5(src.encode("utf-8", "replace")).hexdigest()[:8]
    try:
        mark = _fingerprint(path)
        executable = _is_executable(path)
        # On Windows the CLI is a DLL that loads duckdb.dll from beside it, and
        # the extension DLL resolves the same import, so it is staged with its
        # siblings -- into a directory of its own, so two CLI versions cannot
        # overwrite each other's. Everywhere else the CLI is one file, and only
        # that file is copied: its directory holds the whole of /usr/local/bin.
        with_siblings = executable and os.name == "nt"
        if with_siblings:
            home = os.path.join(d, tag + "-cli")
        else:
            # one directory per source: the CLIs of different DuckDB lines are all called "duckdb", so
            # sharing a directory would make each copy overwrite the last
            home = os.path.join(d, tag)
        out = os.path.join(home, os.path.basename(path))
        if _STAGED.get(src) != mark or not os.path.exists(out):
            os.makedirs(home, exist_ok=True)
            if with_siblings:
                for sib in os.listdir(os.path.dirname(path)):
                    s = os.path.join(os.path.dirname(path), sib)
                    if os.path.isfile(s):
                        shutil.copy2(s, os.path.join(home, sib))
            else:
                shutil.copy2(path, out)
            _STAGED[src] = mark
        if executable:
            try:
                os.chmod(out, os.stat(out).st_mode | 0o111)
            except OSError:
                pass
        return out
    except OSError:
        return path

def run_cli(cmd, **kw):
    """Runs the staged CLI with its working directory on the native filesystem."""
    d = stage_dir()
    if d:
        kw.setdefault("cwd", d)
    # One engine worker per CLI process instead of one per CPU (FSQL_HARNESS_THREADS=0 keeps the default): the harness starts
    # thousands of CLIs and the default pools drive a small host's load average to several times its CPU count.
    t = os.environ.get("FSQL_HARNESS_THREADS", "1")
    if t not in ("", "0") and isinstance(cmd, (list, tuple)) and cmd and "duckdb" in os.path.basename(str(cmd[0])).lower():
        cmd = [cmd[0], "-cmd", "SET threads=%s" % t] + list(cmd[1:])
    return subprocess.run(cmd, **kw)

CLEAN_ENV = {k: v for k, v in os.environ.items() if k not in ("AI_AGENT", "CLAUDECODE")}
# Same opt-outs the harness uses for its (unsigned) mock plugins; the product default refuses an unsigned plugin
# (a detached .sig beside it is required unless FSQL_REASONING_REQUIRE_SIGNATURE=0).
CLEAN_ENV.setdefault("FSQL_REASONING_ALLOW_UNVERIFIED", "1")

def signature_policy(env):
    """The corpus (written against the C++ reference build) opts a case out of signature checking with
    FSQL_REASONING_ALLOW_UNVERIFIED=1 / FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1, and leaves them unset or 0 to test the
    refusals. The pure-C extension's core spells the opt-outs FSQL_REASONING_REQUIRE_SIGNATURE=0 and
    FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0; derive them from the case's own setting so every case keeps its
    meaning. (The mock plugins are unsigned test doubles.) Returns env."""
    for old, new in (("FSQL_REASONING_ALLOW_UNVERIFIED", "FSQL_REASONING_REQUIRE_SIGNATURE"),
                     ("FSQL_ENTERPRISE_ALLOW_UNVERIFIED", "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE")):
        if env.get(old) == "1": env[new] = "0"
        else: env.pop(new, None)
    return env

# The harness's mock reasoning plugins (tests/*.c), compiled once. A case selects one with
#   -- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
PLUGINS = {}
def build_plugins():
    import tempfile
    d = os.path.realpath(tempfile.mkdtemp(prefix="capi-mocks-"))
    for name in ("mock_reasoning_plugin", "mock_embed_plugin", "retry_reasoning_plugin",
                 "think_reasoning_plugin", "evil_lying_length_plugin", "evil_embed_plugin"):
        src = os.path.join(REPO, "tests", name + ".c")
        if not os.path.exists(src): continue
        out = os.path.join(d, name + SOEXT)
        r = subprocess.run([CC, "-shared", "-fPIC", "-std=c99", "-I" + os.path.join(REPO, "include"), src, "-o", out],
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
        if r.returncode == 0: PLUGINS[name] = out
def build_mock_enterprise():
    src = os.path.join(CAPI, "test", "mock_enterprise.c")
    d = os.path.realpath(tempfile.mkdtemp(prefix="capi-ent-"))
    for name, flags in (("mock_enterprise", []), ("mock_enterprise_noex", ["-DNO_EX"]),
                        ("mock_enterprise_nomm", ["-DNO_MM"]), ("mock_enterprise_none", ["-DNO_EX", "-DNO_MM"])):
        out = os.path.join(d, name + SOEXT)
        r = subprocess.run([CC, "-shared", "-fPIC", "-std=c99"] + flags + ["-I" + os.path.join(REPO, "include"), src, "-o", out],
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
        if r.returncode == 0: PLUGINS[name] = out
    # a loadable library that exports none of the enterprise symbols ("not a FractalSQL Enterprise core library")
    empty_src = os.path.join(d, "mock_enterprise_empty.c")
    with open(empty_src, "w") as fh: fh.write("int fsql_mock_not_an_enterprise_core(void) { return 0; }\n")
    out = os.path.join(d, "mock_enterprise_empty" + SOEXT)
    if subprocess.run([CC, "-shared", "-fPIC", empty_src, "-o", out], capture_output=True).returncode == 0:
        PLUGINS["mock_enterprise_empty"] = out
import tempfile
build_plugins()
build_mock_enterprise()
def expand(v):
    return re.sub(r"\$\{(\w+)\}", lambda m: PLUGINS.get(m.group(1), "/nonexistent/" + m.group(1)), v)


# The mock reasoning plugin answers from fixed files; a case sets them with
#   -- file: sql=SELECT 1            (the canned GENERATE answer; \n is a newline)
#   -- file: review=PASS ok          (the critique round's answer)
#   -- file: fail=rc                 (make the plugin misbehave: rc|empty|garbage|embed-rc|embed-empty|embed-bad)
# Both files are rewritten (or removed) before every run so cases cannot leak into each other.
MOCK_FILES = {"sql": "/tmp/fractalsql_bt_sql.txt", "review": "/tmp/fractalsql_bt_review.txt",
              "fail": "/tmp/fractalsql_bt_fail.txt"}
import atexit
def _clean_mock_files():
    for p in MOCK_FILES.values():
        try: os.remove(p)
        except OSError: pass
atexit.register(_clean_mock_files)

# The parity corpus: one (file, sql, expect, env, diverges, xskip) tuple per blank-line separated case in test/parity/*.sql.
def cases():
    for f in sorted(glob.glob(os.path.join(HERE, "parity", "*.sql"))):
        text = open(f).read()
        for blk in re.split(r"\n\s*\n", text):
            lines = blk.splitlines()
            expect = None
            diverges = False
            cenv = {}
            xskip = False
            for l in lines:
                if re.match(r"\s*--\s*xver:\s*skip", l): xskip = True
                m = re.match(r"\s*--\s*expect(-c)?:\s*(.*)$", l)
                if m: expect = m.group(2); diverges = bool(m.group(1))
                m = re.match(r"\s*--\s*env:\s*(\w+)=(.*)$", l)
                if m: cenv[m.group(1)] = expand(m.group(2).strip())
                m = re.match(r"\s*--\s*file:\s*(\w+)=(.*)$", l)
                if m: cenv["@" + m.group(1)] = m.group(2)
            body = expand("\n".join(l for l in lines if not l.strip().startswith("--")).strip())
            if body:
                yield os.path.basename(f), body, expect, cenv, diverges, xskip
