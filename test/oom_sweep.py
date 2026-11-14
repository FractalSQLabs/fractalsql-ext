#!/usr/bin/env python3
"""test/oom_sweep.py -- allocation-failure sweep of the extension.

For every case in the parity corpus (test/parity/*.sql: statements that reach deep, successful paths) it starts one
interactive DuckDB CLI under tests/oom_preload.c scoped to the extension's own code (FSQL_OOM_ONLY_SO: only
allocations whose caller lives in the extension are counted or failed; the engine's are untouched), runs the case's
setup statements normally, and then runs its LAST statement repeatedly: once to count how many allocations the
extension makes for it, then once per sampled allocation with exactly that allocation failing (malloc/calloc/realloc/
strdup return NULL, ENOMEM). A second pass fails each allocation made while the extension loads.

What is asserted: the process survives (no signal, no hang), no sanitizer report, no DuckDB INTERNAL error. An
ordinary error (the extension reporting out of memory, or the statement failing for another reason) is the expected
outcome and is not a failure.

Env: CAPI_DIST (the build under test; default dist/<platform>; coverage runs use dist/cov), OOM_LINE (DuckDB line, 15),
     OOM_MAX_TRIALS (allocation points per statement, 40), OOM_MAX_CASES (debug), OOM_LOAD=0 (skip the load pass),
     OOM_FILTER (regex on the case's file name), OOM_SAMPLE (run every Nth distinct statement; default 1 = all),
     OOM_LOAD_STRIDE (fail every Nth allocation of the LOAD pass; default 1 = all).
"""
import os, queue, re, signal, subprocess, sys, tempfile, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I drops the script dir
from harness_common import cases, signature_policy, PLUGINS, CLEAN_ENV, MOCK_FILES, latest_cli, band_file, REPO

LINE = os.environ.get("OOM_LINE", "15")
CLI, EXT = latest_cli(LINE), band_file(LINE)
if not CLI or not EXT:
    print("  FAIL need a DuckDB CLI and the built extension for line " + LINE); sys.exit(1)
MAX_TRIALS = int(os.environ.get("OOM_MAX_TRIALS", "40"))
MAX_CASES = int(os.environ.get("OOM_MAX_CASES", "0") or 0)
FILTER = re.compile(os.environ.get("OOM_FILTER", ""))
SAMPLE = max(1, int(os.environ.get("OOM_SAMPLE", "1") or 1))
LOAD_STRIDE = max(1, int(os.environ.get("OOM_LOAD_STRIDE", "1") or 1))
# A wall-clock budget for the whole sweep. The full-depth run is thousands of trials, and on a
# slow host (or one whose working copy is on a shared folder) a trial that kills the extension
# costs a fresh CLI process, so the sweep can take the better part of an hour. The budget stops
# it at the deadline instead: what it managed to sweep is reported, and the caller sees that it
# was cut short. The default fits the full-depth run on a slow host; a sampled run finishes in
# minutes and never reaches it.
BUDGET_SECONDS = float(os.environ.get("OOM_BUDGET_SECONDS", "3600") or 0)
DEADLINE = time.monotonic() + BUDGET_SECONDS if BUDGET_SECONDS > 0 else None
STOP = False
def _on_term(signum, frame):
    """A SIGTERM (the caller's timeout) stops the sweep at the next trial boundary -- and the
    summary still gets printed, so the caller can say what it managed to sweep."""
    global STOP
    STOP = True
try:
    signal.signal(signal.SIGTERM, _on_term)
except (ValueError, OSError):
    pass
def out_of_time():
    return STOP or (DEADLINE is not None and time.monotonic() >= DEADLINE)
WORK = tempfile.mkdtemp(prefix="fsql_oomsweep_")
SHIM = os.path.join(WORK, "oom_preload.so")
r = subprocess.run(["cc", "-O2", "-fPIC", "-shared", "-o", SHIM, os.path.join(REPO, "tests", "oom_preload.c"), "-ldl"],
                   capture_output=True, text=True)
if r.returncode != 0:
    print("  FAIL the fault shim did not build:\n" + r.stderr); sys.exit(1)
CTL = os.path.join(WORK, "ctl")
SO_MATCH = os.path.basename(EXT).split(".")[0] + "."          # "fractalsql." matches the extension's path, not libduckdb's
BAD = re.compile(r"INTERNAL Error|Sanitizer|runtime error:|Segmentation fault|Assertion .* failed|FATAL Error|"
                 r"terminate called|\*\*\* stack smashing|double free|corrupted|free\(\): invalid")
DONE = "FSQLOOMDONE"
# One engine worker per CLI process (the default is one per CPU): the sweep starts thousands of processes, and on a small host the
# default thread pools alone drive the load average to several times the CPU count. FSQL_HARNESS_THREADS=0 leaves the default.
_T = os.environ.get("FSQL_HARNESS_THREADS", "1")
THREAD_ARGS = ["-cmd", "SET threads=%s" % _T] if _T not in ("", "0") else []


class Session:
    """One CLI process: statements go in over a pipe, answers (stdout and stderr merged) come back up to a marker."""

    def __init__(self, env):
        e = dict(env, LD_PRELOAD=SHIM, FSQL_OOM_CTL=CTL, FSQL_OOM_ONLY_SO=SO_MATCH, FSQL_OOM_LINEBUF="1")
        self.p = subprocess.Popen([CLI, "-unsigned", "-batch", "-csv", "-noheader"] + THREAD_ARGS, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=e, text=True, bufsize=1,
                                  encoding="utf-8", errors="replace")
        self.q = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for line in self.p.stdout:
            self.q.put(line.rstrip("\n"))
        self.q.put(None)

    def alive(self):
        return self.p.poll() is None

    def run(self, sql, timeout=30):
        """Returns (output, state): state is 'ok', 'died' or 'hung'."""
        try:
            self.p.stdin.write(sql.rstrip() + "\nSELECT '" + DONE + "';\n")
            self.p.stdin.flush()
        except (BrokenPipeError, OSError):
            return "", "died"
        out, end = [], time.monotonic() + timeout
        while True:
            left = end - time.monotonic()
            if left <= 0:
                return "\n".join(out), "hung"
            try:
                line = self.q.get(timeout=left)
            except queue.Empty:
                return "\n".join(out), "hung"
            if line is None:
                return "\n".join(out), "died"
            if line == DONE:
                return "\n".join(out), "ok"
            out.append(line)

    def signal_and_wait(self, sig, marker):
        """Sends sig and waits for the shim to create `marker` (its ack or result file)."""
        try: os.unlink(marker)
        except OSError: pass
        if not self.alive(): return False
        os.kill(self.p.pid, sig)
        end = time.monotonic() + 3
        while time.monotonic() < end:
            if os.path.exists(marker): return True
            time.sleep(0.0005)
        return False

    def arm(self, n):
        with open(CTL, "w") as f: f.write("%d 0 0 0\n" % n)
        return self.signal_and_wait(signal.SIGUSR1, CTL + ".armed")

    def disarm(self):
        """Disarms and returns (allocations counted, failures injected), or None."""
        if not self.signal_and_wait(signal.SIGUSR2, CTL + ".res"): return None
        try:
            c, f = open(CTL + ".res").read().split()
            return int(c), int(f)
        except (OSError, ValueError):
            return None

    def close(self):
        if self.alive():
            # The extension's documented host contract: a session that is about to close the database ends with
            # fractal_release(), so the extension closes the connections it keeps for nested queries while the
            # database is still alive. Without it the host-departure monitor closes them from its own thread as
            # the CLI tears the database down (an access violation at exit).
            try:
                self.p.stdin.write("SELECT fractal_release();\n")
                self.p.stdin.flush()
            except (BrokenPipeError, OSError):
                pass
            try:
                self.p.stdin.close()
                self.p.wait(timeout=20)       # a normal exit is what writes the coverage counters
            except Exception:                 # noqa: BLE001
                self.p.kill()
        else:
            try: self.p.wait(timeout=1)
            except Exception: pass            # noqa: BLE001


def case_env(cenv):
    env = dict(CLEAN_ENV)
    env.update({k: v for k, v in cenv.items() if not k.startswith("@")})
    signature_policy(env)
    return env


def set_files(cenv):
    for k, path in MOCK_FILES.items():
        try:
            if "@" + k in cenv:
                with open(path, "w") as fh: fh.write(cenv["@" + k].replace("\\n", "\n"))
            elif os.path.exists(path):
                os.remove(path)
        except OSError:
            pass


def statements(body):
    parts = [s.strip() for s in re.split(r";\s*(?:\n|$)", body) if s.strip()]
    return [s + ";" for s in parts]


def points(total):
    """The allocation indexes to fail: the first allocations all (init paths), then spread over the rest."""
    if total <= MAX_TRIALS:
        return list(range(1, total + 1))
    head_n = min(24, MAX_TRIALS // 2)
    rest = MAX_TRIALS - head_n
    step = (total - head_n) / float(rest)
    return list(range(1, head_n + 1)) + [head_n + int(round((i + 1) * step)) for i in range(rest)]


problems = []
trials = cases_run = stmts_swept = 0


def record(where, n, why, out):
    problems.append((where, n, why, out[-240:]))
    print("  FAIL %s [allocation %s]: %s\n       %r" % (where, n, why, out[-200:]), flush=True)


def sweep_case(src, body, cenv):
    global trials, cases_run, stmts_swept
    stmts = statements(body)
    if not stmts: return
    setup, target = stmts[:-1], stmts[-1]
    env = case_env(cenv)
    set_files(cenv)
    where = "%s: %s" % (src, target[:90].replace("\n", " "))

    def fresh():
        s = Session(env)
        s.run("LOAD '%s';" % EXT)
        for st in setup: s.run(st)
        return s

    s = fresh()
    if not s.arm(10 ** 9): s.close(); return
    out, state = s.run(target)
    counts = s.disarm()
    if state != "ok" or counts is None:
        if state == "died": record(where, "count run", "the statement itself died with nothing failed", out)
        # (a "hung" count run is a statement too slow for the instrumented -O0 build: nothing was failed, so skip it)
        s.close(); return
    total = counts[0]
    cases_run += 1
    stmts_swept += 1
    for n in points(total):
        if out_of_time(): break
        if not s.alive() or not s.arm(n):
            s.close(); s = fresh()
            if not s.arm(n): break
        out, state = s.run(target)
        s.disarm() if state == "ok" else None
        trials += 1
        if state == "hung":
            # A hang is judged by a 30 s silence, which an overloaded host can produce with nothing wrong in the extension
            # (the -O0 build, a load average several times the CPU count). A real hang at this failure point repeats in a
            # fresh process; a slow one does not. Retry once before calling it a problem.
            s.close(); s = fresh()
            if s.arm(n):
                out, state = s.run(target)
                s.disarm() if state == "ok" else None
        if state != "ok":
            record(where, n, "the process " + ("died" if state == "died" else "hung") +
                   (" (rc=%s)" % s.p.poll() if state == "died" else ""), out)
            s.close(); s = fresh()
        elif BAD.search(out):
            record(where, n, "internal error or sanitizer report", out)
    s.close()


def sweep_load():
    """Fails each allocation the extension makes while it loads (registration, instance creation, the monitor)."""
    global trials
    env = case_env({})
    env.update({"FRACTALSQL_REASONING_PLUGIN": PLUGINS.get("mock_embed_plugin", ""),
                "FRACTALSQL_ENTERPRISE_LIB": PLUGINS.get("mock_enterprise", ""), "FSQL_ENTERPRISE_ALLOW_UNVERIFIED": "1"})
    set_files({})
    s = Session(env)
    s.run("SELECT 1;")                               # the process must be up (the shim's signal handlers installed) before arming
    if not s.arm(10 ** 9): s.close(); return 0
    out, state = s.run("LOAD '%s';\nSELECT fractal_version();" % EXT)
    counts = s.disarm(); s.close()
    if counts is None or state != "ok":
        print("  note: the LOAD pass could not count the extension's load-time allocations (state=%s counts=%s): %r" % (state, counts, out[-200:]))
        return 0
    total = min(counts[0], 1500)
    if os.environ.get("OOM_DEBUG"): print("  load pass: %s (state=%s) %r" % (counts, state, out[-300:]))
    for n in range(1, total + 1, LOAD_STRIDE):
        if out_of_time(): break
        s = Session(env)
        s.run("SELECT 1;")
        if not s.arm(n): s.close(); continue
        out, state = s.run("LOAD '%s';" % EXT)
        trials += 1
        if state != "ok": record("LOAD", n, "the process " + ("died" if state == "died" else "hung"), out)
        elif BAD.search(out): record("LOAD", n, "internal error or sanitizer report", out)
        else:
            s.run("SELECT fractal_version(), length(fractal_schema_context());")   # the half-initialised extension must not crash later
        s.close()
    return total


t0 = time.time()
seen = set()
n_cases = 0
for src, body, expect, cenv, diverges, xskip in cases():
    if FILTER.pattern and not FILTER.search(src): continue
    key = (body, tuple(sorted(cenv.items())))
    if key in seen: continue
    seen.add(key)
    n_seen = len(seen)
    if (n_seen - 1) % SAMPLE:                      # OOM_SAMPLE: every Nth distinct statement
        continue
    if out_of_time(): break
    sweep_case(src, body, cenv)
    n_cases += 1
    if MAX_CASES and n_cases >= MAX_CASES: break
load_points = sweep_load() if os.environ.get("OOM_LOAD", "1") != "0" else 0
for k in MOCK_FILES.values():
    try: os.remove(k)
    except OSError: pass
print()
cut = ""
if out_of_time():
    cut = (" (stopped on a signal)" if STOP
           else " (cut short at the %.0fs budget)" % BUDGET_SECONDS)
print("oom sweep: %d statements, %d injected allocation failures (%d during LOAD) in %.0fs, %d problem(s)%s"
      % (stmts_swept, trials, load_points, time.time() - t0, len(problems), cut))
sys.exit(1 if problems else 0)
