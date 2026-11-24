#!/bin/bash
#
# fractalsql-ext build_test -- the 33-gate confidence harness.
#
# Drives the built fractalsql.v*.duckdb_extension through the DuckDB CLI
# (and the Python duckdb driver where a pip `duckdb` package is present),
# with the tests/*.c reasoning-ABI fixture plugins compiled on the fly.
# Every gate below exists because something in this extension's surface
# could regress invisibly; the gate numbers are stable across releases so
# CI logs stay comparable.
#
# Gate map (duckdb):
#
#   01  build            locate/validate the extension artifact (release
#                        mode does NOT build; use build.sh/docker or
#                        build_test.ps1 for that). In --asan/--ubsan the
#                        cell is built natively under dist/<san>/ (see
#                        the flags below), plus an instrumentedness probe
#   02  smoke            fractal_version()/fractal_edition() =
#                        2.0.0/"Community", fractal_sfs_converge convergence,
#                        fractal_sfs_converge_debug's best_point JSON
#   03  schema_context   fractal_schema_context(): PK / NOT NULL / FK
#                        rendering + 0-arg auto-discovery
#   04  text_to_sql      SELECT-only allowlist end to end: stacked,
#                        DDL, DELETE, modifying-CTE (a parse error by
#                        construction here), bad column (analyze
#                        failure), EXPLAIN tier; never executes
#   05  evil_overread    evil_nonterminating_plugin's guard-page
#                        response: the GENERATE path and bare
#                        fractal_reason() must survive it (REVIEW has
#                        no dispatch site in this build)
#   06  crash_recovery   evil_crash_plugin kills the duckdb process in
#                        the middle of a call; the on-disk database
#                        must reopen cleanly afterwards with the
#                        pre-crash committed canary intact
#   07  evil_lying_length  plugin claims a 32 MiB summary_len over an
#                        8-byte allocation; the response guard refuses
#                        before any read
#   08  authz            [SKIP in the duckdb build] -- there is no
#                        authorizer hook to deny rows at introspection
#                        time; the neighboring boundaries live in
#                        gates 09/16
#   09  path_security    FRACTALSQL_REASONING_PLUGIN path validation:
#                        relative and traversal plugin paths rejected
#                        with "failed to load reasoning plugin",
#                        canonical path loads and works
#   10  dos_and_injection  fractal_schema_context()'s 512-cap fires on
#                        an oversized table_names[] list; injection-
#                        shaped names never reach SQL; table survives
#   11  scout            fractal_search_explore's population returns
#                        and disperses across distinct points + the
#                        options-JSON overload
#   12  soak             S x I threaded stress via the python duckdb
#                        driver -- every query returns exactly, every
#                        INSERT lands exactly once, DB responsive after
#   13  siu_mode         FSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=
#                        select_insert_update widens INSERT/UPDATE;
#                        DELETE/DDL stay rejected; nothing executes
#   14  retry            retry_reasoning_plugin: attempt 1 rejected,
#                        attempt 2 succeeds, and the attempt-1
#                        rejection reason is threaded into the
#                        attempt-2 GENERATE prompt
#   15  embed            fractal_embed dispatch (canned 3-dim vector),
#                        the plugin/endpoint config error ladder, the
#                        over-limit embed response (16385 floats), the
#                        full vectorizer create/backfill/process/
#                        status/write-back cycle, duplicate-create and
#                        injection-shaped source_table, pause/resume
#   16  embed_authz      vectorizer create-time validation: no-PK /
#                        composite-PK / nonexistent source tables;
#                        the authorizer driver half is skipped (gate
#                        08's reason)
#   17  embed_soak       100-doc queue drained by repeated
#                        process_queue(batch=20): exactly-once
#                        processing, done=100/failed=0, last call 0
#   18  embed_crash      the CLI process dies mid-process_queue; the
#                        persisted queue status and gate 15's write-
#                        back embeddings must survive
#   19  sfs_bounds       vector parse bounds: empty vector, over-
#                        arena (4097 > cap) query, explore dim
#                        mismatch, options bounds; nothing executes
#   20  api_func         fractal_reason canary + NULL pass-through,
#                        text_to_sql NULL, lenient explore options,
#                        process_queue bounds + the staged stale-reclaim
#                        (a 7200s-old 'processing' claim is reclaimed;
#                        a fresh claim is left alone)
#   21  fuzz_smoke       the seeded mutation fuzzer over
#                        tests/fuzz_corpus/: every mutant is fed to the
#                        CLI as ordinary SQL (the CLI must never die
#                        abnormally) AND handed to fractal_text_to_sql()
#                        as a model reply (the SELECT-only allowlist
#                        must still refuse anything that is not a
#                        single SELECT)
#   22  v2_functions     the analytics/portfolio/geometry/telemetry/
#                        trajectory/vector-math surface end to end
#   23  agents           the six Universal Agents (search/rag/sql,
#                        plan_explore, trajectory_predict, detect_loop,
#                        telemetry/hybrid/cross_modal/explain_result)
#   24  enterprise       the dormant enterprise surface rejects
#                        cleanly (ledger_flush/audit_log), and a
#                        configured-but-unloadable enterprise LIB
#                        surfaces the loader error, a distinct message
#   25  enterprise_stress  [runs against the real enterprise core when FSQL_TEST_ENTERPRISE_LIB names one, else the mock core;
#                        see the driver for the in-process concurrency
#                        and churn scope this port keeps]
#   26  enterprise_signature  load-boundary ordering: the missing-lib
#                        error carries the loader detail when a path is
#                        configured and the clean dormant-tier message
#                        when none is (signature refusals: gate 32)
#   27  think            think-tier env forwarding through CHAT and
#                        GENERATE, and EMBED must NOT see them
#   28  review_isolation  per-tier RESPONSE_MODE isolation: T2S's
#                        GENERATE runs under the hard-forced "code"
#                        mode; the CHAT tier must not inherit it (the
#                        REVIEW half of the original gate is re-aimed
#                        -- this build's text_to_sql pipeline dispatches
#                        GENERATE only). Also per-tier endpoint
#                        isolation: the EMBED tier points the extension's
#                        own configuration at the embeddings endpoint,
#                        and a CHAT tier that loads afterwards must
#                        still reach the chat endpoint
#   29  domain_agents    three of the sixteen registered Domain Agent
#                        engines across the three composition shapes:
#                        anomaly_triage (table + drift + reason),
#                        recall_hybrid (pure retrieval, cohort filter,
#                        no LLM), regime_triage (array-in + dfa/drift
#                        + reason), and outlier_intercept's metric arg
#   30  feature_store    covered by gate 66 (store_morphology / mine_topology_negatives)
#   31  ledger_chain     the ledger's community-vs-enterprise gate
#                        posture: audit_log/flush/load gated,
#                        fractal_ledger_verify() runs with NO
#                        enterprise lib at all (chain state is
#                        in-memory per connect, so the storage-layer
#                        row surgery has no target and gate 26 owns
#                        the load boundary instead)
#   32  enterprise_signature_real  Ed25519 detached-signature check of
#                        the enterprise library: primitive vectors +
#                        refusal cases (missing / invalid / wrong-size)
#   33  tsan_ledger_concurrent  [SKIP] -- not a separate gate here: the
#                        extension's ThreadSanitizer run is gate 51 (the
#                        `thread` cell), which drives the shared state from
#                        many threads, including the `parallel` mode
#   34  kits             the 15 newest demo/demo-vertical-*.sql starter kits
#                        (ev-battery .. rf-spectrum-sensing)
#                        each run start to finish in a fresh in-memory
#                        database against the mock reasoning plugin: zero
#                        SQL errors (one allowed for scenario-planning,
#                        whose plan_explore step needs an embedding
#                        endpoint), no NaN/inf, and the kit's headline
#                        result reproduced
#   35  mcp_probes       the MCP server (mcp/, a C++17 program that links libduckdb and loads this
#                        extension): build it, then the unit probes -- the DuckDB error
#                        classification, parameter binding (lists, NULLs, empty lists, large values),
#                        the lock-down (no file access, no INSTALL/LOAD, settings frozen), interrupt,
#                        argument coercion, the concurrency caps, secret redaction
#   36  mcp_smoke        a full MCP session over stdio: handshake, the 106-tool catalog and its
#                        annotations, every tool once, the numbers the tools must produce, row
#                        limits, the error taxonomy, resources, prompts, read-only mode, a database
#                        file (persisted and opened read-only), $/cancel, shutdown, then the
#                        robustness and mutation sweeps
#   37  mcp_https        the MCP HTTP transport over TLS: fail-fast misconfiguration, TLS-only,
#                        bearer token, a full authenticated tool call
#   38  mcp_cli          the MCP server started in every way its command line, environment and
#                        database settings allow, and a connection killed under it
#   39  mcp_db_probe     the DuckDB connection layer on its own (binding kinds, decoding, lock-down)
#   40  mcp_concurrency_probe  the per-class concurrency caps on their own
#   41  mcp_faults       (--fault only, Linux) the server under an allocation/file/socket fault shim,
#                        one call failed
#                        at a time; this is also the extension's allocation-failure injection
#   42  mcp_fuzz         (--fuzz only) libFuzzer + ASan over the JSON-RPC front door and the argument coercion
#   43  recall_hybrid_filter  the four-argument fractal_agent_recall_hybrid form must error, not crash
#                        (needs an extension built from the fixed source: rebuild dist/)
#   46  capi_matrix      the pure-C extension: builds
#                        both bands (stable C_STRUCT for DuckDB 1.5.6+/2.0.x, C_STRUCT_UNSTABLE for
#                        the latest 1.4.x) and checks each loads where it should and is refused where it should
#                        across the latest 1.4.x / 1.5.x / 2.0.x CLIs, that no DuckDB code is inside, and that
#                        only the entry point is exported. Seconds, not a DuckDB compile.
#                        CLIs: FSQL_DUCKDB_14/_15/_20, else the highest v1.4.*/v1.5.*/v2.0.* under dist/cli/ or ~/duckdb-cli/.
#   47  capi_parity      the parity corpus (test/parity_diff.py): every case in test/parity/*.sql runs through
#                        the extension on the 1.5.x CLI (output checked against the case's written
#                        expectation, when it has one) and on the 1.4.x and 2.0.x CLIs (must match 1.5.x).
#                        Error-class prefixes ("IO Error:" vs "Invalid Input Error:") are normalised and
#                        counted. The retired C++ build is compared only when CPP_EXT names one.
#   48  capi_sanitize    the pure-C extension under AddressSanitizer and UBSan: the buffer layer's unit test
#                        plus the whole parity corpus run against the instrumented extension on the 1.4.x,
#                        1.5.x and 2.0.x CLIs with the sanitizer runtime preloaded; any report fails.
#   49  capi_lifecycle   a file database with the pure-C extension loaded closes like any other. The extension
#                        keeps connections to run SQL on the caller's database, which would pin the host's
#                        database for the life of the process; a host-departure monitor releases them when
#                        every client connection has closed. Asserted, per DuckDB line: with no call at all
#                        the process holds no descriptor afterwards, the shutdown checkpoint ran (no .wal)
#                        and the file reopens in-process; also after fractal_release(), with nested queries
#                        off, with clients reconnecting inside the grace period (pool kept), with a client
#                        arriving while the release is being verified (release abandoned, query waits then
#                        succeeds), at the grace boundary, with queries in flight, checkpoint-only and
#                        monitor-off policies, and 9 databases on concurrent threads (no thread left behind).
#                        The `parallel` mode has 8 connections to one database call the extension at once while
#                        the host scans on several threads: pure functions (which must always succeed), the
#                        domain-agent engine, the ledger, config get/set (setenv/getenv) and the lazy enterprise
#                        check (which may report an error but must never crash or hang).
#                        Built against libduckdb for the 1.4.x, 1.5.x and 2.0.x lines (libduckdb.so next to
#                        each CLI).
#   51  capi_lifecycle_san  gate 49's modes under AddressSanitizer+LeakSanitizer and under ThreadSanitizer (one
#                        round each, Linux). Fails on any memory error or leak, and on any data race with an
#                        access in the extension's own code (libduckdb is not instrumented, so its own internal
#                        reports are not counted; a race in a free()/memcpy() the extension itself makes is).
#                        (gates 35-43 need libduckdb: FSQL_LIBDUCKDB_DIR, or it is fetched for the
#                        extension's DuckDB version; under --asan/--ubsan the server is built instrumented
#                        and its output is checked for sanitizer reports; 41 skips there)
#   52  fuzz_parse      (--fuzz only) libFuzzer + ASan + UBSan over the extension's OWN parser for a model's
#                        reply (src/fsql_parse.c): the reply is untrusted input, so the code that turns it into
#                        SQL is attack surface. The target carries no DuckDB, so unlike gate 42 this needs no
#                        libduckdb, no OpenSSL and no MCP server.
#   53  capi_edge        the edge-input matrix (test/edge_inputs.py), default environment: every registered function x
#                        awkward arguments (NULL, empty, huge, NaN, malformed JSON, ...) with the mock plugin configured,
#                        bare, and misbehaving; no crash and no DuckDB INTERNAL error (about 11,700 statements, under a minute)
#   54  error_table      test/error_table.py: a table of ~100 calls, each with the outcome it must produce (the error
#                        message, a value, or NULL): bounds, dimensions, identifiers, options, config keys, the 4 MiB caps
#   55  ledger_integrity the ledger store and its verifier (test/ledger_unit.c: chains built by hand and damaged in every
#                        way the check must notice, the size cap, the anchor log, allocation failure; ASan/UBSan under
#                        --asan/--ubsan) and the ledger through SQL with the mock enterprise core (test/ledger_sql.py)
#   56  capi_oom         allocation-failure sweep, quick form (test/oom_sweep.py with a sampled corpus, about 2.5 minutes): every
#                        allocation the extension makes while running a statement is failed in turn (tests/oom_preload.c,
#                        scoped to the extension); the process must survive with a clean error. Linux; skipped under
#                        --asan/--ubsan (a sanitizer runtime and the fault shim cannot both interpose the allocator)
#   57  capi_oom_full    (--fault only) the same sweep at full depth (every distinct statement, 40 failure points each,
#                        every allocation of LOAD; about 20 minutes)
#   --gate mcp           gates 35-40 (plus 41 with --fault)
#
# Gate sets:
#
#   (default)        01 02 03 .. 20 22 .. 32 34 .. 40 43   (33 is --tsan-only and
#                                                   21 FUZZ-only, 41 is FAULT-only)
#   --quick          01 02                     pre-push smoke
#   --fuzz           21 42                      the seeded mutation fuzzer
#   --fault          the default set plus 41 57 the fault gates: the MCP server under an
#                                              allocation/file/socket fault shim, and the
#                                              full-depth allocation-failure sweep over
#                                              tests/fuzz_corpus/
#   --asan/--ubsan   the default set on the native sanitizer cell under
#                                              dist/<san>/; gates 12/25
#                                              skip (their pip-duckdb
#                                              host cannot be
#                                              instrumented), and any
#                                              sanitizer report in
#                                              captured CLI output
#                                              fails its gate
#   --kit <name>     run ONE vertical demo kit (demo/demo-vertical-<name>.sql)
#                    against the mock reasoning plugin and print its raw
#                    output; the same mode as build_test.ps1 -Kit
#
# Usage:
#
#   ./build_test.sh              # full gate matrix
#   ./build_test.sh --quick      # gates 01 02
#   ./build_test.sh --gate 6     # one gate (leading zero optional)
#   ./build_test.sh --list       # print the gate matrix, exit 0
#   ./build_test.sh --kit ev-battery-lifecycle   # one kit, printed
#   ./build_test.sh --asan       # full matrix on the ASan-instrumented
#                                #   cell, built natively into dist/asan
#   ./build_test.sh --ubsan      # ditto for UBSan
#
# Environment:
#
#   FSQL_DUCKDB              path to the duckdb CLI (default: PATH;
#                            asan/ubsan: dist/<san>/duckdb)
#   FSQL_EXT                 explicit path to the built extension file
#                            (.duckdb_extension); otherwise resolved
#                            from dist/ (gate 01). Pointing FSQL_EXT and
#                            FSQL_DUCKDB at a SANITIZER CELL (an
#                            instrumented CLI and extension under
#                            dist/asan, dist/ubsan, dist/windows-asan or
#                            dist/windows-ubsan) turns the sanitizer
#                            report assertions on, exactly as --asan /
#                            --ubsan do: a report in any captured CLI
#                            output fails that gate.
#   FSQL_CC                  cc/gcc/clang for the tests/*.c fixture
#                            plugins (default: PATH; probed in order)
#   FSQL_PYTHON              python3/python that has the pip `duckdb`
#                            package installed (default: PATH probe)
#   BTROOT                   override for the root the fixture plugins'
#                            hardcoded /tmp/... contracts resolve to
#                            (Windows: pinned to <drive>:/tmp)
#   FSQL_TEST_TIMEOUT_MULT   scales the crash-recovery poll windows in
#                            gates 06/18 (default 1)
#   FSQL_EVIL_SQL_FILE       evil_nonterminating_plugin's canned SQL
#                            source (set automatically per gate)
#   FSQL_ASAN_OPTIONS        full override of the harness's default
#                            ASAN_OPTIONS (applied in --asan mode)
#   FSQL_UBSAN_OPTIONS       full override of the harness's default
#                            UBSAN_OPTIONS (applied in --ubsan mode)
#   FSQL_ASAN_DETECT_LEAKS   1 turns LeakSanitizer on in --asan mode
#                            (default 0: the stock CLI's own shutdown
#                            allocations would be reported as leaks)
#   FSQL_FUZZ_ITERS          number of mutants gate 21 generates
#                            (default 120)
#   FSQL_FUZZ_TIME           wall-clock budget for gate 21, in seconds
#                            (default 60); the loop stops early when it
#                            is reached
#   FSQL_FUZZ_TIMEOUT_MS     wall-clock budget for ONE mutant, in
#                            milliseconds (default 20000); a mutant that
#                            outruns it is killed and counted as a hang,
#                            not a crash
#   FSQL_FUZZ_SEED           seed for the deterministic mutation PRNG
#                            (default 20260930; the same seed always
#                            produces the same mutants)
#   FSQL_FUZZ_CC             (unused here; kept for option parity)
#
# Release mode never builds: gate 01 locates the artifact that build.sh
# (docker) or scripts\windows\build.bat produced under dist/ -- or honors FSQL_EXT.
# Sanitizer modes build their cell natively with make SAN=... (-fsanitize on the
# extension only) and stage the stock DuckDB CLI of the same version
# beside it; the sanitizer runtime is preloaded into that CLI. Every later
# gate drives the artifact through the duckdb CLI.
#
# ---------------------------------------------------------------

# ----------------------------------------------------------------
# Machinery: argument parsing, environment, fixture plumbing.
# ----------------------------------------------------------------

set -uo pipefail
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"

# Resource fence. Run the whole harness inside a transient cgroup scope so no gate (a sanitizer build, the 9-database `multi`
# lifecycle mode, an OOM sweep) can take the host down: memory is capped (swap off, so it OOM-kills inside the fence instead of
# thrashing the guest), CPU leaves one core free, and the group sits at low CPU weight. Needs Linux + systemd --user; anywhere
# else, or with FSQL_NO_CGROUP=1, it is skipped. Tune with FSQL_MEM_MAX (e.g. 3G; default 55% of RAM) and FSQL_CPU_QUOTA
# (percent of one CPU; default (CPUs-1)*100).
if [ -z "${FSQL_FENCED:-}" ] && [ "${FSQL_NO_CGROUP:-0}" != 1 ] && [ "$(uname -s)" = Linux ] \
   && command -v systemd-run >/dev/null 2>&1 && systemctl --user is-system-running >/dev/null 2>&1; then
  _ncpu="$(nproc 2>/dev/null || echo 1)"
  _memkb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
  _mem="${FSQL_MEM_MAX:-$(( _memkb * 55 / 100 / 1024 ))M}"
  _cpu="${FSQL_CPU_QUOTA:-$(( (_ncpu > 1 ? _ncpu - 1 : 1) * 100 ))%}"
  case "$_cpu" in *%) ;; *) _cpu="$_cpu%" ;; esac
  export FSQL_FENCED=1
  exec systemd-run --user --scope --quiet -p MemoryMax="$_mem" -p MemorySwapMax=0 -p CPUQuota="$_cpu" -p CPUWeight=20 \
    -p TasksMax=4096 -- "$0" "$@"
fi
cd "$HERE"
# Test fixtures load unsigned mock reasoning plugins; the product default (a valid signature required) is bypassed explicitly here.
export FSQL_REASONING_REQUIRE_SIGNATURE="${FSQL_REASONING_REQUIRE_SIGNATURE:-0}"
ORIG_ARGV=("$@")

# On MSYS/Git Bash pin BTROOT to the /<drive>/tmp view of <drive>:\tmp (the drive the checkout is on) so the shell
# tools, the duckdb CLI and the fixture plugins all agree on one root.
IS_MSYS=0
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) IS_MSYS=1 ;;
esac
if [ "${IS_MSYS}" = 1 ]; then
  # The fixture plugins open the literal path /tmp/..., which a native Windows process resolves against ITS current
  # drive. So the root has to sit on the drive the checkout is on (D: on GitHub's runners), not always C:.
  drive="c"
  if command -v cygpath >/dev/null 2>&1; then
    drive="$(cygpath -m "$PWD" | cut -c1 | tr '[:upper:]' '[:lower:]')"
  fi
  BTROOT="${BTROOT:-/${drive}/tmp}"
else
  BTROOT="${BTROOT:-/tmp}"
fi
mkdir -p "$BTROOT" 2>/dev/null
# Resolve symlinks on POSIX (pwd -P): the reasoning-plugin loader rejects any plugin path where realpath(path) != path (a
# defence against symlink pivots), and on macOS /tmp is a symlink to /private/tmp. On MSYS keep the /c/tmp view as it is.
if [ "${IS_MSYS}" = 1 ]; then
  BTROOT="$(cd "$BTROOT" 2>/dev/null && pwd || printf '%s' "$BTROOT")"
else
  BTROOT="$(cd "$BTROOT" 2>/dev/null && pwd -P || printf '%s' "$BTROOT")"
fi
BTROOTW="$BTROOT"
PLUGSUF=".so"
if [ "${IS_MSYS}" = 1 ]; then
  BTROOTW="$(cygpath -m "$BTROOT")"     # mixed form: C:/tmp
  PLUGSUF=".dll"
fi

# The five hardcoded file contracts the C fixture plugins share with
# this script: the canned SQL the mock plugin returns (and the RESPONSE_
# MODE it observed at init), the retry plugin's dumped GENERATE prompt,
# the think plugin's dumped env, and the two evil plugins' trigger file.
SQLTXT="$BTROOT/fractalsql_bt_sql.txt"
EVILTRIG="$BTROOT/fractalsql_bt_evil_trigger_call.txt"
RETRYPROMPT="$BTROOT/fractalsql_bt_retry_prompt.txt"
THINKDUMP="$BTROOT/fractalsql_bt_think_dump.txt"
REVIEWDUMP="$BTROOT/fractalsql_bt_review_env_dump.txt"
REVIEWTXT="$BTROOT/fractalsql_bt_review.txt"
REVIEWPROMPT="$BTROOT/fractalsql_bt_review_prompt.txt"

# One run at a time per machine. Those fixture files live at a fixed path and
# a run removes them when it ends, so a second run overlapping this one
# deletes this run's canned replies mid-gate -- and the mock plugin answers a
# valid default when its reply file is gone, which reads like a real answer.
# The lock is a directory no other run may create; it holds the owner's pid, so
# a lock left behind by a killed run is taken over rather than waited on. The
# name is shared with the other hosts that use the same fixture files.
LOCKDIR="$BTROOT/fractalsql_bt.lock.d"
LOCK_HELD=0
acquire_run_lock() {
  local i p
  for i in $(seq 1 20); do
    if mkdir "$LOCKDIR" 2>/dev/null; then
      printf '%s\n' "$$" > "$LOCKDIR/pid" 2>/dev/null || true
      printf 'pid %s started %s\n' "$$" "$(date '+%Y-%m-%d %H:%M:%S')" > "$LOCKDIR/owner" 2>/dev/null || true
      LOCK_HELD=1
      return 0
    fi
    p="$(cat "$LOCKDIR/pid" 2>/dev/null || echo 0)"
    # ps sees another user's process too (kill -0 does not), and a pid file
    # that is not written yet reads as 0: neither is a dead owner.
    if [ "$p" != "0" ] && [ "$p" != "$$" ] && ! ps -p "$p" > /dev/null 2>&1; then
      rm -rf "$LOCKDIR" 2>/dev/null || true     # the owner is gone: take it over
      continue
    fi
    sleep 1
  done
  return 1
}
release_run_lock() {
  [ "$LOCK_HELD" = 1 ] || return 0
  rm -rf "$LOCKDIR" 2>/dev/null || true
  LOCK_HELD=0
}

# Mutable run state.
PDIR=""       PDIRW=""      PDIRSEP="/"
EXT=""        EXTW=""
DB=""         DBW=""
DUCKDB=""     DUCKDBW=""
PY="";                      CC="";  CCNAME=""
FAILED=0      GATES_RAN=0   SETUP_DONE="" STALE_ARTIFACT=0
SQLQ_OUT=""   SQLQ_RC=0
MOCK=""       MOCKEMB=""    RETRYPLUG=""   THINKPLUG=""
EVILNT=""     CRASHPLUG=""  EVILLEN=""     EVOLEMB=""
BADLIB=""
SAN_MODE=""   SAN_EXEMPT=""
# What the MCP server (gates 35-43) is built as: asan/ubsan follow SAN_MODE; --tsan builds ONLY the server under
# ThreadSanitizer, --mcp-coverage ONLY the server with gcov (line, function and branch coverage of mcp/src, gates
# 35-40). --coverage runs that and then the extension's own sources (src/*.c) with test/coverage_run.sh, a gcov build
# of the pure-C extension. Plain --coverage is the quick pass (build, gates 01-34, the error table and the ledger through
# SQL, the header unit tests, the report: minutes); --coverage --fault adds the heavy stages (the parity corpus, the
# edge-input matrix, the lifecycle modes and the allocation-failure sweep). --src-coverage alone always runs every stage
# (about an hour). Each fails below 80% lines, functions or branches.
# --profile: valgrind memcheck (test/valgrind_run.sh), Linux only. The unit binaries, then the DuckDB 1.5.x CLI loading the
# release extension and running every default-environment parity case in one session. Fails on a memcheck error or a
# definite/indirect leak with a frame in our code; the host's own reports and possible leaks are counted, not failed.
# It adds what the sanitizer cells cannot: uninitialised reads and leaks on the unmodified release build.
MCP_KIND=""
COVERAGE_ALL=0
TIMEOUT_MULT="${FSQL_TEST_TIMEOUT_MULT:-1}"
# The wall-clock budget for ONE fuzz mutant, in milliseconds. A mutant
# can turn into an unbounded query (a recursive CTE, a cross-product
# blow-up), and a fuzzer that can hang the harness is a fuzzer that
# never finishes. Overridable with FSQL_FUZZ_TIMEOUT_MS.
FZ_TIMEOUT_MS=20000
[ -n "${FSQL_FUZZ_TIMEOUT_MS:-}" ] && FZ_TIMEOUT_MS="$FSQL_FUZZ_TIMEOUT_MS"
FZ_TIMEOUT_SEC=$(( (FZ_TIMEOUT_MS + 999) / 1000 ))

cleanup() {
  [ -n "$PDIR" ] && rm -rf "${PDIR:?fractalsql_bt scratch dir}" 2>/dev/null || true
  rm -f "${SQLTXT:?bt contract file}" "${EVILTRIG:?bt contract file}" \
        "${RETRYPROMPT:?bt contract file}" "${THINKDUMP:?bt contract file}" \
        "${REVIEWDUMP:?bt contract file}" 2>/dev/null
  release_run_lock
}
trap cleanup EXIT INT TERM

# Output shape: "  [PASS] <label>" lines under one "== Gate NN: title"
# banner, so the two harness ports stay mirrorable.
pass() { printf '  \033[0;32m[PASS]\033[0m %s\n' "$1"; }
fail() { printf '  \033[0;31m[FAIL]\033[0m %s\n' "$1"; FAILED=$((FAILED + 1)); }
skip() { printf '  \033[0;36m[SKIP]\033[0m %s\n' "$1"; }
die()  { printf 'build_test: %s\n' "$*" >&2; exit 2; }

# usage(): the file's doc header (lines 4 through the closing rule)
# doubles as the help text. Scanned to the first top rule line rather
# than a fixed range so the docs cannot drift out of the help output.
usage() { awk 'NR >= 4 && /^# ---/ {exit} NR >= 4 {print}' "$0"; }

# Mixed-form (windows-friendly) path for tool arguments.
wpath() {
  if [ "${IS_MSYS}" = 1 ]; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# awk-based float check so gate 02 needs no python.
num_abs_lt_1e6() {
  awk -v v="$1" 'BEGIN{exit !((v+0==v) && (v > -1e-6) && (v < 1e-6))}'
}

# san_report <output>: did the process emit a sanitizer report? Applied
# to every captured CLI invocation when the artifacts under test are
# instrumented (see SAN_CHECK); a report in a gate's output fails that
# gate even when the rc happens to be 0.
san_report() {
  printf '%s' "$1" | grep -Eq 'AddressSanitizer|LeakSanitizer|UndefinedBehaviorSanitizer|runtime error:'
}

# san_artifacts_instrumented: do the resolved artifacts live in a
# sanitizer cell? The cell directories are the harness's own naming, so
# the answer is decidable from the paths alone.
san_artifacts_instrumented() {
  local p
  for p in "${EXT:-}" "${DUCKDB:-}"; do
    case "$p" in
      */dist/asan/*|*/dist/ubsan/*|*/dist/windows-asan/*|*/dist/windows-ubsan/*) return 0 ;;
    esac
  done
  return 1
}

# san_posture: are the artifacts under test instrumented? Two ways
# that can be true, and the report assertions follow the ARTIFACTS
# rather than the mode -- what matters is whether a sanitizer report in
# the captured output would be visible, not who built the binary.
#
#   --asan/--ubsan      the POSIX cell: the extension carries the
#                       sanitizer and the harness preloads the runtime
#                       into a stock CLI.
#   an explicit pair    FSQL_DUCKDB + FSQL_EXT naming a CLI and an
#                       extension that are already instrumented (the
#                       Windows posture, where the CLI itself carries
#                       the runtime and there is nothing to preload).
san_posture() {
  [ -n "$SAN_MODE" ] && return 0
  san_artifacts_instrumented
}

# san_options: the sanitizer options for the artifacts under test. The
# POSIX cell sets them in san_preload, where it also preloads the
# runtime; when the harness is handed an already instrumented pair
# there is no runtime to preload, but the options still apply.
san_options() {
  [ -n "$SAN_MODE" ] && return 0
  san_artifacts_instrumented || return 0
  case "$EXT" in
    */dist/windows-asan/*)
      # The same container-overflow exemption the Windows harness uses:
      # the check fires inside DuckDB's own teardown on Windows native.
      export ASAN_OPTIONS="${FSQL_ASAN_OPTIONS:-detect_container_overflow=0}"
      ;;
  esac
  case "$EXT" in
    */dist/windows-ubsan/*)
      export UBSAN_OPTIONS="${FSQL_UBSAN_OPTIONS:-print_stacktrace=1:report_error_type=1}"
      ;;
  esac
}

# expect_err <want> <rc> <output> <label>
#   rc must be nonzero (and not a crash) and output must contain want.
expect_err() {
  local want="$1" rc="$2" out="$3" label="$4"
  if san_posture && [ -z "$SAN_EXEMPT" ] && san_report "$out"; then
    fail "$label"
    printf '      sanitizer report in output (expected error "%s"): %.900s\n' "$want" "$out"
    return 1
  fi
  if [ "$rc" -ge 128 ]; then
    fail "$label"
    printf '      expected error "%s", got rc=%d (signal death): %.900s\n' "$want" "$rc" "$out"
    return 1
  fi
  if [ "$rc" -eq 0 ]; then
    fail "$label"
    printf '      expected error "%s", got rc=0: %.900s\n' "$want" "$out"
    return 1
  fi
  if printf '%s' "$out" | grep -qF -- "$want"; then
    pass "$label"; return 0
  fi
  fail "$label"
  printf '      expected error "%s", got rc=%d: %.900s\n' "$want" "$rc" "$out"
  return 1
}

# expect_ok <rc> <output> <label> [<want>]
expect_ok() {
  local rc="$1" out="$2" label="$3" want="${4:-}"
  if [ "$rc" -ge 128 ]; then
    fail "$label"
    printf '      rc=%d (signal death): %.900s\n' "$rc" "$out"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    fail "$label"
    printf '      rc=%d: %.900s\n' "$rc" "$out"
    return 1
  fi
  if [ -n "$want" ] && ! printf '%s' "$out" | grep -qF -- "$want"; then
    fail "$label"
    printf '      expected output containing "%s": %.900s\n' "$want" "$out"
    return 1
  fi
  pass "$label"; return 0
}

# crashed <rc>: a signal death shows up as a high rc (128+N after a
# POSIX kill; the native NTSTATUS code, e.g. 0xC0000005, on Windows).
crashed() {
  [ "${1:-0}" -ge 128 ]
}

# expect_survive <rc> <output> <label>: the evil fixture must NOT kill
# the process; the exact returned/error payload is not asserted here.
expect_survive() {
  local rc="$1" out="$2" label="$3"
  if crashed "$rc"; then
    fail "$label"
    printf '      rc=%d (signal death): %.900s\n' "$rc" "$out"
    return 1
  fi
  pass "$label"; return 0
}

# Sanitizer cells build natively (no docker, Linux and macOS alike). The
# extension is compiled here with -fsanitize through make, and the stock
# DuckDB CLI of the same version is staged beside it under dist/<san>/.
# The CLI is not instrumented: san_preload puts the sanitizer runtime in
# front of it, the same way the sqlite harness drives its sanitized
# extension. FSQL_EXT and FSQL_DUCKDB skip the matching half.
san_host_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    arm64|aarch64) echo arm64 ;;
    *) die "unsupported host arch $(uname -m) for the ${SAN_MODE} cell" ;;
  esac
}

build_san_cell() {
  local arch ver sanname plat bdir zip
  arch="$(san_host_arch)"
  ver="${DUCKDB_VERSION:-v1.5.6}"
  case "$SAN_MODE" in
    asan)  sanname=address ;;
    ubsan) sanname=undefined ;;
  esac
  mkdir -p "dist/${SAN_MODE}"

  if [ -z "${FSQL_EXT:-}" ]; then
    # The pure-C extension: `make SAN=...` writes the instrumented build to dist/san-<sanitizer>/. No DuckDB source is
    # compiled, so this takes seconds. Stage it under the per-DuckDB-version name the later gates look for. DuckDB
    # 1.4.x gets its own band file; 1.5.6 and 2.0.0 share the stable-band file.
    command -v make >/dev/null 2>&1 && command -v cc >/dev/null 2>&1 \
      || die "make and a C compiler are required to build the ${SAN_MODE} cell (or set FSQL_EXT)"
    echo "build_test: building the ${SAN_MODE} extension (make SAN=${sanname})"
    nice make -C "$HERE" SAN="$sanname" >"$BTROOT/fractalsql_bt_san_build.log" 2>&1 \
      || die "make SAN=${sanname} failed (see $BTROOT/fractalsql_bt_san_build.log)"
    plat="linux_${arch}"
    [ "$(uname -s)" = Darwin ] && plat="osx_${arch}"
    case "$ver" in
      v1.4.*) bdir="$(ls -1 "dist/san-${sanname}"/fractalsql.v1.4.*.duckdb_extension 2>/dev/null | sort -V | tail -1)" ;;
      *)      bdir="dist/san-${sanname}/fractalsql.capi.${plat}.duckdb_extension" ;;
    esac
    [ -f "$bdir" ] || die "make SAN=${sanname} did not produce an extension for DuckDB ${ver}"
    rm -f "dist/${SAN_MODE}"/fractalsql.*.duckdb_extension
    cp "$bdir" "dist/${SAN_MODE}/fractalsql.${ver}.${plat}.duckdb_extension" \
      || die "could not stage the ${SAN_MODE} extension"
  fi

  if [ -z "${FSQL_DUCKDB:-}" ]; then
    local cli_os=linux cli_arch="$arch"
    [ "$(uname -s)" = Darwin ] && { cli_os=osx; cli_arch=universal; }
    echo "build_test: staging the stock DuckDB ${ver} CLI for the ${SAN_MODE} cell (${cli_os}-${cli_arch})"
    bash "$HERE/scripts/fetch_duckdb.sh" cli "$ver" "$cli_os" "$cli_arch" "$BTROOT/fractalsql_bt_cli" \
      || die "could not download the DuckDB ${ver} CLI (${cli_os}-${cli_arch})"
    cp "$BTROOT/fractalsql_bt_cli/duckdb" "dist/${SAN_MODE}/duckdb" \
      && chmod +x "dist/${SAN_MODE}/duckdb" \
      || die "could not unpack the DuckDB ${ver} CLI"
    # The stock macOS CLI is signed with the hardened runtime, and dyld ignores DYLD_INSERT_LIBRARIES for a hardened binary: the
    # sanitizer runtime would never be preloaded ("Interceptors are not working... loaded too late"). An ad-hoc re-signature
    # without --options runtime drops the hardened flag on this local copy (the release CLI itself is untouched).
    if [ "$(uname -s)" = Darwin ] && command -v codesign >/dev/null 2>&1; then
      codesign --force --sign - "dist/${SAN_MODE}/duckdb" >/dev/null 2>&1 \
        || echo "build_test: warning: could not re-sign the staged CLI; the ${SAN_MODE} runtime may not preload" >&2
    fi
    rm -rf "$BTROOT/fractalsql_bt_cli"
  fi
}

ensure_san_cell() {
  [ -n "$SAN_MODE" ] || return 0
  build_san_cell
}

# Preload the sanitizer runtime into the stock CLI and every process the
# harness spawns beneath it. ASan insists on being first-loaded, so this
# runs before any CLI invocation. Leak detection stays off by default:
# the stock CLI's own shutdown allocations would be reported as leaks.
san_preload() {
  [ -n "$SAN_MODE" ] || return 0
  local rt cc_bin
  cc_bin="${FSQL_CC:-$(command -v cc 2>/dev/null || command -v clang 2>/dev/null || command -v gcc 2>/dev/null || true)}"
  [ -n "$cc_bin" ] || die "no C compiler to locate the ${SAN_MODE} runtime (set FSQL_CC)"
  if [ "$(uname -s)" = Darwin ]; then
    rt="$("$cc_bin" -print-file-name="libclang_rt.${SAN_MODE}_osx_dynamic.dylib")"
    export DYLD_INSERT_LIBRARIES="$rt${DYLD_INSERT_LIBRARIES:+:$DYLD_INSERT_LIBRARIES}"
  else
    if [ "$SAN_MODE" = asan ]; then rt="$("$cc_bin" -print-file-name=libasan.so)"
    else rt="$("$cc_bin" -print-file-name=libubsan.so)"; fi
    export LD_PRELOAD="$rt${LD_PRELOAD:+:$LD_PRELOAD}"
  fi
  [ -f "$rt" ] || die "${SAN_MODE} runtime not found ($rt); install the ${SAN_MODE} runtime for $cc_bin"
  if [ "$SAN_MODE" = asan ]; then
    export ASAN_OPTIONS="${FSQL_ASAN_OPTIONS:-detect_leaks=${FSQL_ASAN_DETECT_LEAKS:-0}:detect_odr_violation=0:print_summary=1:print_stacktrace=1}"
  else
    export UBSAN_OPTIONS="${FSQL_UBSAN_OPTIONS:-print_stacktrace=1:report_error_type=1}"
  fi
}

# probe the toolchain; python-with-duckdb is optional (gates 12/25).
find_toolchain() {
  ensure_san_cell
  san_preload
  if [ -n "${FSQL_DUCKDB:-}" ]; then
    DUCKDB="$(command -v "$FSQL_DUCKDB" 2>/dev/null || printf '%s' "$FSQL_DUCKDB")"
  elif [ -n "$SAN_MODE" ]; then
    # sanitizer modes default to the CLI staged by build_san_cell
    # staged into dist/<san>/
    DUCKDB="$(ls -1t "$HERE/dist/${SAN_MODE}/duckdb" 2>/dev/null | head -1 || true)"
  else
    DUCKDB="$(command -v duckdb 2>/dev/null || true)"
  fi
  if [ -z "$DUCKDB" ]; then
    if [ -n "$SAN_MODE" ]; then
      die "no duckdb CLI under dist/${SAN_MODE}/duckdb (run ./build_test.sh --${SAN_MODE} to stage it, or set FSQL_DUCKDB)"
    fi
    die "no duckdb CLI on PATH (set FSQL_DUCKDB, or install one; see docs/getting-started.md)"
  fi
  DUCKDBW="$(wpath "$DUCKDB")"
  if ! printf 'SELECT 1;\n' | "$DUCKDB" -batch -unsigned >/dev/null 2>&1; then
    die "$DUCKDB is not a working duckdb CLI"
  fi
  # the CLI's major version: a couple of gates assert on grammar that
  # changed between the DuckDB lines (a modifying CTE is a parse error
  # on 1.x and a legal statement on 2.x).
  DUCKDB_MAJOR="$(printf '%s\n' "$("$DUCKDB" --version 2>/dev/null | head -1)" | sed -n 's/^v\([0-9][0-9]*\)\..*/\1/p')"
  DUCKDB_MAJOR="${DUCKDB_MAJOR:-1}"

  if [ -n "${FSQL_CC:-}" ]; then
    CCNAME="$FSQL_CC"
  else
    CCNAME=""
    for c in cc gcc clang; do
      if command -v "$c" >/dev/null 2>&1; then CCNAME="$c"; break; fi
    done
  fi
  [ -n "$CCNAME" ] || die "no C compiler found for the tests/*.c fixture plugins (set FSQL_CC)"
  CC="$(command -v "$CCNAME" 2>/dev/null || printf '%s' "$CCNAME")"

  if [ -n "${FSQL_PYTHON:-}" ]; then
    PY="$(command -v "$FSQL_PYTHON" 2>/dev/null || printf '%s' "$FSQL_PYTHON")"
  else
    PY="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
  fi
  # the drivers require the pip duckdb package; probe and downgrade to
  # a clean [SKIP] when absent rather than failing late.
  if [ -n "$PY" ] && ! "$PY" -c 'import duckdb' >/dev/null 2>&1; then
    PY=""
  fi
  # The pip duckdb package is a separate build of the engine: the
  # python-driver gates open the harness's database file with it and
  # load the built extension into it, so it has to be the same DuckDB
  # major as the CLI under test. A 1.x driver can neither read a 2.x
  # database file (storage format) nor load a 2.x-built extension
  # (ABI), so those gates are skipped -- loudly, and with the reason --
  # when the two majors differ.
  PY_DUCKDB_MAJOR=""
  if [ -n "$PY" ]; then
    PY_DUCKDB_MAJOR="$("$PY" -c 'import duckdb; print(duckdb.__version__)' 2>/dev/null | head -1 | sed -n 's/^\([0-9][0-9]*\)\..*/\1/p')"
  fi
}

# The candidate extension files for DuckDB version $1, newest first. A function of its own: macOS's bash 3.2 cannot parse a
# `case` inside a <( ) substitution (the `)` of a pattern ends the substitution).
resolve_ext_candidates() {
  local v="$1"
  { ls -1t dist/*/fractalsql."${v}".*.duckdb_extension 2>/dev/null
    if [[ "$v" != v1.4.* ]]; then ls -1t dist/*/fractalsql.capi.*.duckdb_extension 2>/dev/null; fi
  } | grep -vE '^dist/(asan|ubsan|san-[a-z]+|cov|unit|lifecycle|windows[^/]*)/'
}

# newest dist/ artifact wins; only called when FSQL_EXT is unset. In
# sanitizer modes the artifact resolves from dist/<san>/ instead; those
# test cells are excluded from every release-mode candidate list -- a
# release CLI cannot LOAD an instrumented extension (unresolved
# __asan_init at dlopen).
resolve_ext_raw() {
  local cand=""
  if [ -n "$SAN_MODE" ]; then
    printf '%s' "$(ls -1t "dist/${SAN_MODE}"/fractalsql.*.duckdb_extension 2>/dev/null | head -1 || true)"
    return
  fi
  # The build under test the run named itself (a --gate or --coverage cell): it wins over every candidate,
  # including the newest dist/ artifact, so the resolver-based gates load what this run is actually reporting on.
  if [ -n "${FSQL_EXT:-}" ] && [ -f "$FSQL_EXT" ]; then printf '%s' "$FSQL_EXT"; return; fi
  # Version-aware first: the extension has two bands (the 1.4 band loads on exactly one DuckDB 1.4.N, the stable band
  # on 1.5.6 and 2.0.0), so "the newest file" can be one the CLI under test refuses to load. Ask the CLI which
  # DuckDB it is, take that version's own cell, else (not for 1.4.x) the stable-band file. A file without the C
  # entry point is a leftover from the retired C++ build (dist/amd64/ still holds some under the same names): skip it.
  local ver="" f
  if [ -n "${DUCKDB:-}" ]; then
    ver="$("$DUCKDB" -noheader -list -c 'SELECT version()' 2>/dev/null | tr -d '\r' | tail -1)"
  fi
  case "$ver" in
    v[0-9]*)
      while IFS= read -r f; do
        [ -f "$f" ] || continue
        if grep -aq fractalsql_init_c_api "$f"; then cand="$f"; break; fi
      done < <(resolve_ext_candidates "$ver")
      ;;
  esac
  if [ -z "$cand" ] && [ "${IS_MSYS}" = 1 ]; then
    cand="$(ls -1t dist/windows/fractalsql.*.duckdb_extension 2>/dev/null | head -1 || true)"
  fi
  if [ -z "$cand" ]; then
    cand="$(ls -1t dist/*/fractalsql.*.duckdb_extension 2>/dev/null \
            | grep -vE '^dist/(asan|ubsan|san-[a-z]+|cov|unit|lifecycle|windows[^/]*)/' | head -1 || true)"
  fi
  if [ -z "$cand" ]; then
    cand="$(ls -1t dist/fractalsql.*.duckdb_extension 2>/dev/null | head -1 || true)"
  fi
  printf '%s' "$cand"
}

# resolve_ext_raw's answer, made absolute: several gates run the CLI from another directory, where a relative path
# no longer resolves ("Extension ... not found").
resolve_ext() {
  local p; p="$(resolve_ext_raw)"
  case "$p" in
    "") ;;
    /*|[A-Za-z]:*) ;;
    *) [ -f "$p" ] && p="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")" ;;
  esac
  printf '%s' "$p"
}

# sqlq_env [K=V ...] -- <sql...>
#   env pairs BEFORE the terminating "--", SQL statement arguments after
#   it. The extension is LOADed first, once per invocation. Two
#   transport rules the DuckDB CLI forces here:
#   - each positional argument is its own SQL script, so statements are
#     joined with newlines into one script (a split INSERT would die
#     with "syntax error at end of input");
#   - the joined script is piped through STDIN rather than one giant
#     argv element: gate 19's 4097-element list literal overflows the
#     OS command-line size limit on Windows and fails to exec elsewhere.
#   -noheader because the 1.5 shell prints the derived column name (the
#   rewritten expression text) even in -batch -list mode, which broke
#   every numeric gate check that parses the first output line.
#   stdout is the CLI output; rc is the CLI rc; SQLQ_OUT/SQLQ_RC mirror
#   both so callers can inspect without re-running.
sqlq_env() {
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    if [ -n "$1" ]; then envs+=("$1"); fi
    shift
  done
  if [ "${1:-}" = "--" ]; then shift; fi
  if [ -z "$EXTW" ]; then
    die "sqlq: no extension resolved yet (gate 01 must run before the fixture gates)"
  fi
  local out rc sqlfile
  sqlfile="$(mktemp "${TMPDIR:-/tmp}/fsql_bt_XXXXXX.sql")"
  {
    printf "LOAD '%s';\n" "$EXTW"
    for s in "$@"; do printf '%s\n' "$s"; done
    # The extension's own contract: "Call [fractal_release()] as the last
    # statement of a session that is about to close a file database." It closes
    # the connections the extension holds open for nested queries, so the
    # host's own teardown (shutdown checkpoint, file unlock) can run. It also
    # joins the extension's host-departure monitor thread, which otherwise
    # keeps polling the database while the CLI tears it down -- that race
    # kills the CLI at exit with a hard crash. The harness drives a file
    # database, so every session here is such a session. The call prints a
    # boolean; its line is trimmed back off the output below.
    printf 'SELECT fractal_release();\n'
  } > "$sqlfile"
  # ${envs[@]+"${envs[@]}"} not "${envs[@]-}": with the "-" default, an
  # empty but declared array expands to one empty word on some bash
  # builds (Git Bash's 5.3.9 measured here), which env then rejects with
  # "env: '': No such file or directory". The "+" idiom expands to zero
  # words on an empty array in every bash >= 4.
  # -bail stops the CLI at the first error, and that is what gives an
  # error-path gate its nonzero exit on the 1.4/1.5 lines. The 2.x shell
  # reports the error and exits nonzero either way, so the flag is dropped
  # there: the script then runs to its end, and the release call appended
  # above gets its chance to close the extension's pool before the CLI
  # tears the database down. Without it the extension's host-departure
  # monitor is still polling when that teardown starts, and the race
  # crashes the host -- an access violation at exit, which the sanitizer
  # cells report and the release build hides behind the error the gate was
  # already expecting.
  bail_flag="-bail"
  if [ "${DUCKDB_MAJOR:-1}" -ge 2 ]; then bail_flag=""; fi
  out="$(env ${envs[@]+"${envs[@]}"} "$DUCKDB" $bail_flag -batch -list -noheader -unsigned "$DBW" \
              < "$sqlfile" 2>&1)"
  rc=$?
  rm -f "$sqlfile"
  # The release is the last statement of the script and prints a boolean, so
  # its line is the last line of the output: drop it, the gates assert on the
  # output of their own statements. (A gate statement that itself answers
  # "true" keeps its own line -- only the last one goes.)
  if [ "$out" = "true" ]; then
    out=""
  else
    out="$(printf '%s\n' "$out" | sed '${/^true$/d;}')"
  fi
  # sanitizer sweep: a report fails the surrounding gate even when the
  # CLI rc is 0. SAN_EXEMPT marks the two deliberate-crash invocations
  # (gates 06/18).
  if san_posture && [ -z "$SAN_EXEMPT" ] && san_report "$out"; then
    [ "$rc" -eq 0 ] && rc=86
    out="${out}
      ==== sanitizer report detected in CLI output"
  fi
  SQLQ_OUT="$out"
  SQLQ_RC="$rc"
  printf '%s' "$out"
  return "$rc"
}
sqlq() { sqlq_env -- "$@"; }

# bt_setup: build the fixture schema in a fresh $DB, autocommitted, and
# leave bt_orders empty so the never-executes checks have a baseline.
bt_setup() {
  rm -f "${DB:?bt database path}" "${DB:?bt database path}.wal"
  sqlq_env -- \
    "CREATE TABLE bt_customers(id INTEGER PRIMARY KEY, name VARCHAR NOT NULL, email VARCHAR);" \
    "CREATE TABLE bt_orders(id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES bt_customers(id), amount DOUBLE, created_at TIMESTAMP);" \
    "CREATE TABLE bt_explore(id INTEGER, x DOUBLE, y DOUBLE, z DOUBLE, w DOUBLE, embedding DOUBLE[]);" \
    "INSERT INTO bt_explore " \
    "SELECT i, " \
    "    CAST(1 + (i*7919) % 5 AS DOUBLE), " \
    "    CAST(1 + (i*104729) % 3 AS DOUBLE), " \
    "    CAST(i + 0.5 AS DOUBLE), " \
    "    CAST((i % 4) * 0.01 + 0.05 AS DOUBLE), " \
    "    [CAST(1 + (i*7919) % 5 AS DOUBLE), CAST(1 + (i*104729) % 3 AS DOUBLE), " \
    "     CAST(i + 0.5 AS DOUBLE), CAST((i % 4) * 0.01 + 0.05 AS DOUBLE)] " \
    "FROM generate_series(1, 60) AS g(i);" \
    "CREATE TABLE bt_telemetry(id INTEGER, vec DOUBLE[]);" \
    "INSERT INTO bt_telemetry VALUES " \
    " (1, [0.6, 0.8, 0.0, 0.0]), (2, [0.0, 1.0, 0.0, 0.0]), (3, [0.8, 0.6, 0.0, 0.0]), (4, [0.0, 0.6, 0.0, 0.8])," \
    " (5, [0.0, 0.0, 1.0, 0.0]), (6, [0.7, 0.7, 0.0, 0.0]), (7, [1.0, 0.0, 0.0, 0.0]), (8, [0.9, 0.1, 0.0, 0.0]);" \
    "CREATE TABLE bt_corpus(id INTEGER, doc VARCHAR, emb DOUBLE[]);" \
    "INSERT INTO bt_corpus VALUES " \
    " (1, 'doc-1', [1.0, 0.0, 0.0, 0.0]), (2, 'doc-2', [0.0, 1.0, 0.0, 0.0]), (3, 'doc-3', [0.0, 0.0, 1.0, 0.0])," \
    " (4, 'doc-4', [0.0, 0.0, 0.0, 1.0]), (5, 'doc-5', [1.0, 0.0, 0.0, 0.0]), (6, 'doc-6', [0.0, 1.0, 0.0, 0.0]);" \
    "CREATE TABLE bt_traj(id INTEGER PRIMARY KEY, vec DOUBLE[]);" \
    "INSERT INTO bt_traj VALUES " \
    " (1, [0.0, 0.0, 0.0, 0.0]), (2, [0.1, 0.0, 0.0, 0.0]), (3, [0.2, 0.0, 0.0, 0.0])," \
    " (4, [0.3, 0.0, 0.0, 0.0]), (5, [0.4, 0.0, 0.0, 0.0]);" \
    "CREATE TABLE bt_soak(worker INTEGER, it INTEGER, tag VARCHAR);"
  if [ "$SQLQ_RC" -ne 0 ]; then
    printf '%s\n' "$SQLQ_OUT" >&2
    die "fixture setup failed"
  fi
}

# compile the tests/*.c fixture plugins into $PDIR (best effort; the
# POSIX-only evil_nonterminating fixture is expected to fail to compile
# on Windows, and have_plugin reports what actually made it). The
# plugins are dlopen'ed by the CLI, so in sanitizer modes they compile
# with the matching -fsanitize flags and join the resident runtime.
compile_plugins() {
  mkdir -p "${PDIR:?fractalsql_bt scratch dir}"
  local -a sanflags=()
  if [ "$SAN_MODE" = "asan" ]; then
    sanflags=(-fsanitize=address -g)
  elif [ "$SAN_MODE" = "ubsan" ]; then
    sanflags=(-fsanitize=undefined -g)
  fi
  local name src out
  for name in mock_reasoning_plugin mock_embed_plugin retry_reasoning_plugin \
              think_reasoning_plugin evil_nonterminating_plugin evil_crash_plugin \
              evil_lying_length_plugin evil_embed_plugin; do
    src="tests/$name.c"
    out="${PDIR:?fractalsql_bt scratch dir}/$name$PLUGSUF"
    [ -f "$src" ] || continue
    if ! "$CC" -shared -fPIC -std=c99 ${sanflags[@]+"${sanflags[@]}"} \
          -I"$HERE/include" "$src" -o "$out" 2>"$out.build.log"; then
      echo "      note: could not compile $src (see $out.build.log)" >&2
      rm -f "${out:?plugin artifact path}"
    fi
  done
}

have_plugin() {
  [ -n "$1" ] && [ -f "$PDIR/$1$PLUGSUF" ]
}

# pj <name>: native-form plugin path for env vars (backslashes where
# the platform wants them).
pj() {
  printf '%s%s%s%s' "$PDIRW" "${PDIRSEP:?PDIRSEP unset}" "$1" "$PLUGSUF"
}

# py_run <script.py> [args...]: run a python driver with FSQL_BT_DB /
# FSQL_BT_EXT pointing at the harness database and extension.
py_run() {
  FSQL_BT_DB="$DBW" FSQL_BT_EXT="$EXTW" "$PY" "$@"
}

# ----------------------------------------------------------------
# Options.
# ----------------------------------------------------------------

MODE="full"
FAULT=0
# The fault gates. A fault gate injects an allocation, file or socket failure and proves the
# server survives it, so it needs a fault shim (Linux only) and cannot run under a sanitizer
# (the shim and the sanitizer runtime cannot both interpose the allocator). They are
# deliberately NOT in the default set and not in CI: --fault is a local, on-demand run.
FAULT_GATES=(41 57)
REBUILD=0
ONE_GATE=""
LIST_ONLY=""
ONE_KIT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --quick)   MODE="quick" ;;
    --fuzz)    MODE="fuzz" ;;
    --rebuild) REBUILD=1 ;;                              # build the extension first (make) when the artifact is missing or older than src/
    --fault)   FAULT=1 ;;                                # the default set plus the fault gates (41: the MCP server under a fault shim, 57: the full-depth allocation-failure sweep)
    --gate)    ONE_GATE="${2:---gate needs an argument}"; shift ;;
    --gate=*)  ONE_GATE="${1#--gate=}" ;;
    --kit)     ONE_KIT="${2:---kit needs an argument}"; shift ;;
    --kit=*)   ONE_KIT="${1#--kit=}" ;;
    --list)    LIST_ONLY=1 ;;
    --asan)    [ -z "$SAN_MODE" ] || die "--asan and --ubsan are mutually exclusive"; SAN_MODE="asan" ;;
    --ubsan)   [ -z "$SAN_MODE" ] || die "--asan and --ubsan are mutually exclusive"; SAN_MODE="ubsan" ;;
    --tsan)     MCP_KIND="tsan" ;;
    --coverage)     MCP_KIND="cov"; COVERAGE_ALL=1 ;;   # MCP server gates, then the extension's sources (quick stages; with --fault every stage)
    --mcp-coverage) MCP_KIND="cov" ;;                    # the MCP server only (gates 35-40, a few minutes)
    --src-coverage) exec "$HERE/test/coverage_run.sh" ;; # the extension's sources only, every stage (about an hour)
    --profile)      exec "$HERE/test/valgrind_run.sh" ;; # valgrind memcheck over the extension and the MCP server (Linux; about 14 minutes)
    -h|--help) usage; exit 0 ;;
    -*)        usage >&2; die "unknown option: $1" ;;
    *)         usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done
if [ -n "$MCP_KIND" ] && [ -n "$SAN_MODE" ]; then
  die "--tsan and --coverage are for the MCP server and cannot be combined with --asan/--ubsan"
fi
# --asan on macOS needs the sanitizer runtime preloaded into the stock DuckDB CLI (DYLD_INSERT_LIBRARIES), which dyld ignores
# for a hardened-runtime binary and strips through SIP-protected helpers; the harness then dies at fixture setup with "Interceptors
# are not working". An ad-hoc re-signature of the CLI did not fix it on a GitHub macOS runner. --ubsan does not need the preload and
# works. Skip --asan on macOS cleanly; FSQL_FORCE_DARWIN_ASAN=1 tries it anyway.
if [ "$(uname -s)" = Darwin ] && [ "$SAN_MODE" = asan ] && [ "${FSQL_FORCE_DARWIN_ASAN:-0}" != 1 ]; then
  echo "build_test: --asan is not supported on macOS with the stock DuckDB CLI (use --ubsan here; Linux covers --asan). Skipped. FSQL_FORCE_DARWIN_ASAN=1 tries it anyway."
  exit 0
fi
if [ "$MCP_KIND" = tsan ] && [ "$(uname -s)" != Linux ]; then die "--tsan is Linux-only here (it uses setarch -R)"; fi
[ -n "$SAN_MODE" ] && MCP_KIND="$SAN_MODE"
MCP_ALIAS=""
if [ "$ONE_GATE" = "mcp" ]; then
  MCP_ALIAS=1; ONE_GATE=""
elif [ -n "$ONE_GATE" ]; then
  ONE_GATE="$(printf '%02d' "$((10#$ONE_GATE))" 2>/dev/null)" || ONE_GATE=""
fi

# ----------------------------------------------------------------
# Gates.
# ----------------------------------------------------------------

# ext_stale_source ARTIFACT: prints the newest file under src/ that is MEASURABLY newer than the artifact (more than a minute, which absorbs timestamp
# granularity) and returns 0; returns 1 when the artifact is current. This is what keeps the gates from testing yesterday's binary against today's source.
ext_stale_source() {
  local ext="$1" ext_t src_t newest
  [ -f "$ext" ] && [ -d "$HERE/src" ] || return 1
  ext_t="$(stat -c %Y "$ext" 2>/dev/null || stat -f %m "$ext" 2>/dev/null)" || return 1
  newest="$(find "$HERE/src" -type f \( -name '*.c' -o -name '*.h' \) -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1)"
  [ -n "$newest" ] || return 1
  src_t="${newest%%.*}"
  [ "$src_t" -gt $((ext_t + 60)) ] || return 1
  printf '%s\n' "${newest#* }"
}

gate_01() {
  # Locate/validate the extension artifact. This harness deliberately
  # does NOT build (release mode): use build.sh (docker) or build_test.ps1
  # first. Sanitizer modes build their cell via build_san_cell.
  # Sanitizer modes resolve from dist/<san>/ -- the native test cell.
  if [ -n "${FSQL_EXT:-}" ]; then
    if [ ! -f "$FSQL_EXT" ]; then
      fail "FSQL_EXT=$FSQL_EXT does not exist"
      return
    fi
    EXT="$FSQL_EXT"
    pass "artifact from FSQL_EXT: $EXT"
  else
    EXT="$(resolve_ext)"
    # --rebuild: build the extension first when the artifact is missing or older than the sources. A fresh artifact is left alone, a
    # sanitizer cell is excluded (build_san_cell builds its own) and so is an artifact named by FSQL_EXT.
    if [ "$REBUILD" -eq 1 ] && [ -z "$SAN_MODE" ] && { [ -z "$EXT" ] || [ ! -f "$EXT" ] || ext_stale_source "$EXT" >/dev/null; }; then
      echo "  rebuilding the extension (make) -- the artifact is missing or older than src/"
      nice make -C "$HERE" -s >"$BTROOT/fractalsql_bt_rebuild.log" 2>&1 || { tail -20 "$BTROOT/fractalsql_bt_rebuild.log"; fail "--rebuild: make failed (see $BTROOT/fractalsql_bt_rebuild.log)"; return; }
      EXT="$(resolve_ext)"
    fi
    if [ -z "$EXT" ] || [ ! -f "$EXT" ]; then
      if [ -n "$SAN_MODE" ]; then
        fail "no fractalsql.*.duckdb_extension under dist/${SAN_MODE}/ (run ./build_test.sh --${SAN_MODE} to build it)"
      else
        fail "no fractalsql extension under dist/ that loads on the duckdb CLI in use (run make, or build.sh, first)"
      fi
      return
    fi
    pass "artifact located: $EXT"
    if [ -z "$SAN_MODE" ]; then
      if newest="$(ext_stale_source "$EXT")"; then
        fail "stale artifact: $(basename "$EXT") is older than $newest -- run ./build_test.sh --rebuild (or make) before the gates, or point FSQL_EXT at a fresh one"
        STALE_ARTIFACT=1
      fi
    fi
  fi
  # Absolute, whichever way it was found: several gates run the CLI from another directory, where a relative
  # path no longer resolves ("Extension ... not found").
  case "$EXT" in
    /*|[A-Za-z]:*) ;;
    *) EXT="$(cd "$(dirname "$EXT")" && pwd)/$(basename "$EXT")" ;;
  esac
  case "$EXT" in
    *duckdb_extension*) pass "artifact name matches a duckdb extension file" ;;
    *) fail "$EXT does not look like a duckdb extension file" ;;
  esac
  EXTW="$(wpath "$EXT")"
  # The DuckDB floor is 1.4+: the loader-based C++ entry point is the
  # only one the extension exports. The pre-1.4 "fractalsql_init" symbol
  # must be gone from the artifact -- it is not a substring of the
  # loader-based name, so a plain byte scan is decisive.
  if grep -aq "fractalsql_init_c_api" "$EXT"; then
    # the pure-C extension: DuckDB's C extension API entry point, <name>_init_c_api
    pass "the C extension API entry point (fractalsql_init_c_api) is in the artifact"
  elif grep -aq "fractalsql_duckdb_cpp_init" "$EXT"; then
    fail "this artifact is the retired C++ build, which these gates no longer test -- build the C extension (make, or build.sh) and point FSQL_EXT at it, or unset FSQL_EXT"
  else
    fail "no entry point (fractalsql_init_c_api) in the artifact"
  fi
  # (the C extension's own entry point, fractalsql_init_c_api, is not the pre-1.4 symbol)
  # portable (BSD grep on macOS has no -P): every fractalsql_init* name in the file must begin with the C API entry point's name (the old `(?!_c_api)` lookahead)
  if LC_ALL=C grep -ao 'fractalsql_init[A-Za-z0-9_]*' "$EXT" | grep -qv '^fractalsql_init_c_api'; then
    fail "the pre-1.4 entry point (fractalsql_init) is still in the artifact"
  else
    pass "the pre-1.4 entry point (fractalsql_init) is gone from the artifact"
  fi
  # sanitizer modes: the extension must carry the sanitizer's undefined
  # symbols (it was built with -fsanitize). The CLI is the stock build,
  # reached through san_preload, so it is not checked here.
  if [ -n "$SAN_MODE" ]; then
    local symprefix
    if [ "$SAN_MODE" = "asan" ]; then symprefix="__asan_"; else symprefix="__ubsan_"; fi
    if nm -u "$EXT" 2>/dev/null | grep -F "$symprefix" >/dev/null; then
      pass "sanitizer instrumented extension verified (${symprefix}* undefined symbols)"
    else
      fail "--${SAN_MODE} selected but the extension is not ${SAN_MODE}-instrumented (no ${symprefix}* symbols)"
      printf '      rebuild it with ./build_test.sh --%s, or check FSQL_EXT\n' "$SAN_MODE"
    fi
  fi
}

gate_02() {
  local r rc
  r=$(sqlq "SELECT fractal_version();"); rc=$?
  expect_ok "$rc" "$r" "fractal_version() reports 2.0.2" "2.0.2"
  r=$(sqlq "SELECT fractal_edition();"); rc=$?
  expect_ok "$rc" "$r" "fractal_edition() reports Community" "Community"
  # smoke search: identical points converge onto the query point itself
  r=$(sqlq "SELECT fractal_sfs_converge([0.6, 0.8, 0.0, 0.0]::DOUBLE[], [0.6, 0.8, 0.0, 0.0]::DOUBLE[]);"); rc=$?
  if [ "$rc" -eq 0 ] && num_abs_lt_1e6 "$r"; then
    pass "fractal_sfs_converge converges on an identical point (|d| < 1e-6)"
  else
    fail "fractal_sfs_converge convergence smoke"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
  fi
  r=$(sqlq "SELECT fractal_sfs_converge_debug([0.6, 0.8, 0.0, 0.0]::DOUBLE[], 30, 50, 2);"); rc=$?
  expect_ok "$rc" "$r" "fractal_sfs_converge_debug reports best_point" "best_point"
  # The CI smoke test (test/smoke_test.sql) is self-checking: every
  # assertion calls error(), which -bail turns into a non-zero exit.
  # Run the file itself rather than a copy of its checks, so the two
  # cannot drift apart.
  if [ -f test/smoke_test.sql ]; then
    r=$(sqlq "$(cat test/smoke_test.sql)"); rc=$?
    if [ "$rc" -eq 0 ]; then
      pass "test/smoke_test.sql runs clean"
    else
      fail "test/smoke_test.sql"
      printf '      got rc=%d: %.900s\n' "$rc" "$r"
    fi
  else
    fail "test/smoke_test.sql is missing"
  fi
}

gate_03() {
  local r rc
  r=$(sqlq "SELECT fractal_schema_context();"); rc=$?
  expect_ok "$rc" "$r" "0-arg auto-discovery renders both fixture tables" "TABLE bt_orders:"
  if printf '%s\n' "$r" | grep -qF "  id INTEGER PRIMARY KEY"; then
    pass "primary key annotation rendered"
  else
    fail "primary key annotation missing from the rendering"
    printf '      got: %.900s\n' "$r"
  fi
  if printf '%s\n' "$r" | grep -qF "  name VARCHAR NOT NULL"; then
    pass "NOT NULL annotation rendered"
  else
    fail "NOT NULL annotation missing from the rendering"
    printf '      got: %.900s\n' "$r"
  fi
  if printf '%s\n' "$r" | grep -qF "FOREIGN KEYS:" \
     && printf '%s\n' "$r" | grep -qF "bt_orders(customer_id) -> bt_customers(id)"; then
    pass "foreign key rendered as bt_orders(customer_id) -> bt_customers(id)"
  else
    fail "foreign key rendering missing"
    printf '      got: %.900s\n' "$r"
  fi
  r=$(sqlq "SELECT fractal_schema_context(['bt_orders']);"); rc=$?
  if [ "$rc" -eq 0 ] \
     && printf '%s\n' "$r" | grep -qF "TABLE bt_orders:" \
     && ! printf '%s\n' "$r" | grep -qF "TABLE bt_customers:"; then
    pass "table_names[] scoping returns only the requested table"
  else
    fail "table_names[] scoping"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
  fi
  r=$(sqlq "SELECT fractal_schema_context(['bt_customers'], 'bt_customers');"); rc=$?
  expect_ok "$rc" "$r" "list + query_hint arity accepted" "TABLE bt_customers:"
  # a database with no visible tables has no schema to describe: that
  # is reported, not rendered as an empty description
  local emptydb="$PDIR/bt_empty.db"
  rm -f "$emptydb" "${emptydb}.wal"
  r=$("$DUCKDB" -bail -batch -list -noheader -unsigned "$(wpath "$emptydb")" \
        < <(printf "LOAD '%s';\nSELECT fractal_schema_context();\n" "$EXTW") 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s\n' "$r" | grep -qF "no visible tables found"; then
    pass "a table-less database reports 'no visible tables found'"
  else
    fail "table-less database schema_context"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
  fi
  rm -f "$emptydb" "${emptydb}.wal"
}

gate_04() {
  local r rc
  T2S_ENV=("FRACTALSQL_REASONING_PLUGIN=$(pj mock_reasoning_plugin)")
  local canned happy="SELECT id, name FROM bt_customers WHERE id = 1"
  t2s_expect "$happy" "$happy" ok   "happy path returns the canned SELECT (schema-scoped prompt)"
  t2s_expect "SELECT 1; SELECT 2" "expected exactly one SQL statement, found 2" err "stacked statements rejected at the allowlist"
  t2s_expect "CREATE TABLE bt_dos(a INTEGER)" 'statement type "CREATE" is not permitted' err "DDL rejected under the SELECT-only allowlist"
  t2s_expect "DELETE FROM bt_orders" 'statement type "DELETE" is not permitted' err "DELETE rejected under the SELECT-only allowlist"
  t2s_expect "INSERT INTO bt_orders VALUES (1)" 'statement type "INSERT" is not permitted' err "INSERT rejected under the SELECT-only allowlist"
  # A modifying CTE must never come back through the allowlist. 1.x's
  # grammar has no such statement, so the candidate is refused by the
  # parser; 2.x's grammar has one, so the allowlist refuses it instead
  # (the outer statement is a SELECT, and the DELETE hides in the CTE).
  if [ "${DUCKDB_MAJOR:-1}" -ge 2 ]; then
    t2s_expect "WITH d AS (DELETE FROM bt_orders RETURNING *) SELECT * FROM d" "data-modifying CTE" err "modifying CTE refused by the allowlist"
  else
    t2s_expect "WITH d AS (DELETE FROM bt_orders RETURNING *) SELECT * FROM d" "SQL does not parse" err "modifying CTE is a parse error under duckdb's grammar"
  fi
  t2s_expect "EXPLAIN SELECT 1" 'statement type "EXPLAIN" is not permitted' err "EXPLAIN rejected under the SELECT-only allowlist"
  t2s_expect "this is not sql at all ##" "is not permitted" err "non-SQL prose refused on its first keyword"
  t2s_expect "123 not a keyword" "statement is empty or does not start with" err "a candidate that does not start with a keyword is refused"
  t2s_expect "SELECT no_such_column FROM bt_orders" "SQL does not parse" err "unknown column surfaces from the EXPLAIN step"
  # A SELECT of a state-changing extension function is a SELECT to the statement-type check and would still write: the
  # candidate may not call one, in any spelling DuckDB's parser accepts (a comment or a quoted name before the
  # parenthesis; a dollar-quoted string, which DuckDB reads as one string, so a lone quote inside it opens nothing).
  t2s_expect "SELECT fractal_audit_log('x', '{}')" "changes state" err "a state-changing function is refused"
  t2s_expect "SELECT fractal_audit_log /* c */ ('x', '{}')" "changes state" err "a comment before the parenthesis does not hide the call"
  t2s_expect 'SELECT "fractal_audit_log"('"'"'x'"'"', '"'"'{}'"'"')' "changes state" err "a quoted identifier does not hide the call"
  t2s_expect "SELECT \$\$ ' \$\$ , fractal_audit_log('x', '{}')" "changes state" err "a lone quote inside a dollar-quoted string does not hide the call"
  t2s_expect "SELECT \$t\$ ' \$t\$ , fractal_ledger_flush()" "changes state" err "a tagged dollar-quoted string does not hide the call"
  t2s_expect "SELECT \$\$fractal_audit_log('x')\$\$ AS s" "-" ok "a denied name inside a dollar-quoted string is only text"
  r=$(sqlq "SELECT count(*) FROM bt_orders;"); rc=$?
  expect_ok "$rc" "$r" "fractal_text_to_sql never executes (bt_orders still empty)" "0"

  # the exhausted loop names the attempt count, the last rejection, and
  # quotes the rejected candidate back
  printf 'DROP TABLE bt_orders' > "$SQLTXT"
  r=$(sqlq_env ${T2S_ENV[@]+"${T2S_ENV[@]}"} -- "SELECT fractal_text_to_sql('give me the orders data');"); rc=$?
  expect_err "exhausted 3 attempt(s), last rejection:" "$rc" "$r" "the exhausted loop names the attempt count and the last rejection"
  expect_err "Last candidate SQL: DROP TABLE bt_orders" "$rc" "$r" "the exhausted loop quotes the rejected candidate back"

  # a reply that carries no SQL at all: the loop reports the empty
  # candidate rather than the generic rejection
  printf '   ' > "$SQLTXT"
  r=$(sqlq_env ${T2S_ENV[@]+"${T2S_ENV[@]}"} -- "SELECT fractal_text_to_sql('give me the orders data');"); rc=$?
  expect_err "the model response contained no SQL" "$rc" "$r" "a reply with no SQL at all is reported as such"

  # a fenced block is extracted from ANYWHERE in the reply, not only
  # from its first line
  printf 'Here is the query you asked for:\n\n```sql\nSELECT id FROM bt_customers\n```\n\nHope that helps.' > "$SQLTXT"
  r=$(sqlq_env ${T2S_ENV[@]+"${T2S_ENV[@]}"} -- "SELECT fractal_text_to_sql('give me the orders data');"); rc=$?
  expect_ok "$rc" "$r" 'a fenced ```sql block is extracted from anywhere in the reply' "SELECT id FROM bt_customers"

  # the critique round (opt-in, off by default). With no critique file
  # the verdict can never be a PASS, so the loop exhausts and reports
  # the verdict.
  rm -f "$REVIEWTXT"
  printf 'SELECT 1' > "$SQLTXT"
  r=$(sqlq_env ${T2S_ENV[@]+"${T2S_ENV[@]}"} "FRACTALSQL_TEXT_TO_SQL_USE_REVIEW=on" -- "SELECT fractal_text_to_sql('give me the orders data');"); rc=$?
  expect_err "exhausted 3 attempt(s), last review verdict:" "$rc" "$r" "the critique round exhausts the loop when the verdict is not a PASS"
  # with a PASS critique the candidate stands
  printf 'PASS - the query answers the request' > "$REVIEWTXT"
  r=$(sqlq_env ${T2S_ENV[@]+"${T2S_ENV[@]}"} "FRACTALSQL_TEXT_TO_SQL_USE_REVIEW=on" -- "SELECT fractal_text_to_sql('give me the orders data');"); rc=$?
  expect_ok "$rc" "$r" "the critique round accepts a PASS verdict" "SELECT 1"
  if [ -f "$REVIEWPROMPT" ] && grep -qF "Original request: give me the orders data" "$REVIEWPROMPT"; then
    pass "the critique prompt carries the original request"
  else
    fail "the critique prompt does not carry the original request"
    printf '      got: %.900s\n' "$(cat "$REVIEWPROMPT" 2>/dev/null)"
  fi
  # the round is off unless it is switched on
  rm -f "$REVIEWTXT"
  r=$(sqlq_env ${T2S_ENV[@]+"${T2S_ENV[@]}"} -- "SELECT fractal_text_to_sql('give me the orders data');"); rc=$?
  expect_ok "$rc" "$r" "the critique round is off by default" "SELECT 1"

  # the question cap: one input over the 4 MiB bound is refused before
  # any dispatch
  r=$(sqlq_env ${T2S_ENV[@]+"${T2S_ENV[@]}"} -- "SELECT fractal_text_to_sql(repeat('x', 4194305));"); rc=$?
  expect_err "exceeds the 4 MiB input cap" "$rc" "$r" "a question over the 4 MiB cap is refused"
}

t2s_expect() {
  # t2s_expect <canned-sql> <want|-> <err|ok> <label>; uses T2S_ENV
  # (env pairs) + SQLTXT (the mock plugin's canned response file).
  local canned="$1" want="$2" mode="$3" label="$4" r rc
  if [ "$want" = "-" ]; then want=""; fi
  printf '%s' "$canned" > "$SQLTXT"
  r=$(sqlq_env ${T2S_ENV[@]+"${T2S_ENV[@]}"} -- "SELECT fractal_text_to_sql('give me the orders data');")
  rc=$?
  if [ "$mode" = "err" ]; then
    expect_err "$want" "$rc" "$r" "$label"
  else
    expect_ok "$rc" "$r" "$label" "$want"
  fi
}

gate_05() {
  if ! have_plugin evil_nonterminating_plugin; then
    skip "evil_nonterminating fixture needs mmap/mprotect (POSIX-only); a guard-page analog is not wired in this harness"
    return
  fi
  printf 'SELECT 42\n' > "$SQLTXT"
  local r rc
  printf '1' > "$EVILTRIG"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj evil_nonterminating_plugin)" \
      "FSQL_EVIL_SQL_FILE=$SQLTXTW" -- "SELECT fractal_text_to_sql('why is it slow');")
  rc=$?
  expect_survive "$rc" "$r" "text_to_sql GENERATE survives the guard-page response (no over-read)"
  printf '1' > "$EVILTRIG"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj evil_nonterminating_plugin)" \
      "FSQL_EVIL_SQL_FILE=$SQLTXTW" -- "SELECT fractal_reason('why is it slow', 'bt_orders');")
  rc=$?
  expect_survive "$rc" "$r" "bare fractal_reason survives the guard-page response"
}
gate_06() {
  local r rc out recovered deadline
  # a canary row the crash must not lose
  r=$(sqlq "CREATE TABLE bt_crash_canary(k INTEGER, v VARCHAR);" \
            "INSERT INTO bt_crash_canary VALUES (1, 'pre-crash');")
  r=$(sqlq "SELECT count(*) FROM bt_crash_canary;"); rc=$?
  expect_ok "$rc" "$r" "canary committed before the crash" "1"
  # kill the CLI in the middle of a reasoning call. In --asan mode the
  # fixture's deliberate NULL deref must NOT trip the sanitizer sweep or
  # ASan's own SIGSEGV handler: handle_segv=0 keeps the raw-SIGSEGV death
  # (rc 139) the non-sanitizer run expects, and SAN_EXEMPT silences the
  # report sweep for exactly this invocation.
  SAN_EXEMPT=1
  if [ "$SAN_MODE" = "asan" ]; then
    r=$(sqlq_env "ASAN_OPTIONS=${ASAN_OPTIONS:+${ASAN_OPTIONS}:}handle_segv=0" \
        "FRACTALSQL_REASONING_PLUGIN=$(pj evil_crash_plugin)" \
        -- "SELECT fractal_reason('q');")
  else
    r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj evil_crash_plugin)" \
        -- "SELECT fractal_reason('q');")
  fi
  rc=$?
  SAN_EXEMPT=""
  if crashed "$rc"; then
    pass "evil_crash_plugin killed the CLI process (rc=$rc)"
  else
    fail "expected the crash fixture to kill the CLI process"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
  fi
  # the DB must reopen cleanly; poll for the lock/WAL-reopen to settle
  deadline=$((SECONDS + 30 * TIMEOUT_MULT))
  recovered=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    if out="$("$DUCKDB" -bail -batch -list "$DBW" "SELECT count(*) FROM bt_crash_canary;" 2>&1)"; then
      recovered=1
      break
    fi
    sleep 1
  done
  if [ -z "$recovered" ]; then
    fail "database did not reopen within the recovery window"
    printf '      last open attempt: %.900s\n' "$out"
    return
  fi
  pass "database reopened safely after the mid-call crash"
  if printf '%s\n' "$out" | grep -qF "1"; then
    pass "pre-crash canary row intact after WAL replay"
  else
    fail "pre-crash canary row lost by the crash"
    printf '      got: %.900s\n' "$out"
  fi
  # and the extension still loads and serves the recovered DB
  r=$(sqlq "SELECT count(*) FROM bt_explore;"); rc=$?
  expect_ok "$rc" "$r" "extension serves the recovered database" "60"
}

gate_07() {
  if ! have_plugin evil_lying_length_plugin; then
    skip "evil_lying_length fixture did not compile"
    return
  fi
  printf 'SELECT 7\n' > "$SQLTXT"
  # trigger -1: lie on EVERY dispatch. The CLI constant-folds the SELECT
  # first, so dispatch #1 happens at fold time (the executor swallows
  # that attempt's exception) and the folded-constant path ends the call
  # sequence there if it succeeds -- a call-N-only lie would land on the
  # swallowed fold-time dispatch and never be observed.
  printf -- '-1' > "$EVILTRIG"
  local r rc
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj evil_lying_length_plugin)" \
      "FSQL_EVIL_SQL_FILE=$SQLTXTW" -- "SELECT fractal_text_to_sql('why is it slow');")
  rc=$?
  expect_err "implausible response length" "$rc" "$r" "T2S refuses a lying 32 MiB response length (nothing is read)"
  printf -- '-1' > "$EVILTRIG"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj evil_lying_length_plugin)" \
      "FSQL_EVIL_SQL_FILE=$SQLTXTW" -- "SELECT fractal_reason('why is it slow', 'bt_orders');")
  rc=$?
  expect_err "implausible response length" "$rc" "$r" "bare fractal_reason refuses the same claim"
}

gate_08() {
  # no authorizer analog exists in duckdb: the plugin path boundary
  # (gate 09) and the vectorizer create-time validation (gate 16) own
  # the neighborhood. Documented skip keeps the gate numbering stable.
  skip "no authorizer hook in duckdb; boundaries covered by gates 09/16"
}

gate_09() {
  printf 'SELECT 1\n' > "$SQLTXT"
  local r rc
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj mock_reasoning_plugin)" \
      -- "SELECT fractal_reason('q');")
  rc=$?
  expect_ok "$rc" "$r" "canonical absolute plugin path loads and answers" "SELECT 1"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=mock_reasoning_plugin$PLUGSUF" \
      -- "SELECT fractal_reason('q');")
  rc=$?
  expect_err "failed to load reasoning plugin" "$rc" "$r" "relative plugin path is rejected at load"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$BTROOTW/../fractalsql_bt_nonexistent_plugin$PLUGSUF" \
      -- "SELECT fractal_reason('q');")
  rc=$?
  expect_err "failed to load reasoning plugin" "$rc" "$r" "traversal plugin path is rejected at load"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$BADPLUGIN" \
      -- "SELECT fractal_reason('q');")
  rc=$?
  expect_err "failed to load reasoning plugin" "$rc" "$r" "missing plugin file is reported distinctly"
}

gate_10() {
  local r rc list i
  # a caller-supplied 513-table list trips the cap before any SQL runs
  list="['bt_dos_0'"
  for i in $(seq 1 512); do list="$list,'bt_dos_$i'"; done
  list="$list]"
  r=$(sqlq "SELECT fractal_schema_context($list);"); rc=$?
  expect_err "exceeds the limit of 512" "$rc" "$r" "513-element table_names[] trips the 512 cap"
  # injection-shaped names are matched by string equality only, never
  # interpolated into executed SQL. A canary row makes the "survived"
  # check below meaningful (bt_setup seeds no customer rows).
  sqlq "INSERT INTO bt_customers VALUES (1, 'canary', 'canary@fractalsql.test');" >/dev/null
  r=$(sqlq "SELECT fractal_schema_context(['bt_customers','bt; DROP TABLE bt_customers--']);"); rc=$?
  if [ "$rc" -eq 0 ] \
     && printf '%s\n' "$r" | grep -qF "TABLE bt_customers:" \
     && ! printf '%s\n' "$r" | grep -qF "DROP TABLE"; then
    pass "injection-shaped name never reaches executed SQL (only bt_customers renders)"
  else
    fail "injection-shaped table_names[] entry"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
  fi
  r=$(sqlq "SELECT count(*) FROM bt_customers;"); rc=$?
  expect_ok "$rc" "$r" "bt_customers survives the injection attempt" "1"
  r=$(sqlq "SELECT fractal_schema_context(['bt_customers'], 'bt_customers');"); rc=$?
  expect_ok "$rc" "$r" "list + query_hint arity accepted" "TABLE bt_customers:"
}

gate_11() {
  local r rc nrows uniqx n
  r=$(sqlq "SELECT particle FROM fractal_search_explore('bt_explore','embedding',[1.0, 0.05, 0.0, 0.0]::DOUBLE[], NULL);")
  rc=$?
  nrows=$(printf '%s\n' "$r" | grep -c '^\[' || true)
  uniqx=$(printf '%s\n' "$r" | grep '^\[' | sed 's/^\[//; s/,.*//' | sort -u | wc -l)
  if [ "$rc" -eq 0 ] && [ "$nrows" -ge 5 ] && [ "$uniqx" -ge 2 ]; then
    pass "scout population returned and dispersed ($nrows rows across $uniqx distinct x groups)"
  else
    fail "scout population return shape"
    printf '      got rc=%d, %s rows: %.900s\n' "$rc" "$nrows" "$r"
  fi
  # options-JSON overload still returns the same population contract
  r=$(sqlq "SELECT count(*) FROM fractal_search_explore('bt_explore','embedding',[1.0, 0.05, 0.0, 0.0]::DOUBLE[], '{\"population_size\": 24, \"iterations\": 11}');")
  rc=$?
  n="$(printf '%s' "$r" | tr -cd '0-9')"
  if [ "$rc" -eq 0 ] && [ "$n" -ge 5 ] 2>/dev/null; then
    pass "options-JSON overload accepted (population_size/iterations honored)"
  else
    fail "options-JSON overload"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
  fi
}

gate_12() {
  if [ -n "$SAN_MODE" ]; then
    skip "python driver gate: the pip-duckdb host process cannot be instrumented (skipped in ${SAN_MODE} mode)"
    return
  fi
  if [ -z "$PY" ]; then
    skip "python with the pip duckdb package is unavailable (set FSQL_PYTHON)"
    return
  fi
  if [ -n "$PY_DUCKDB_MAJOR" ] && [ "$PY_DUCKDB_MAJOR" != "${DUCKDB_MAJOR:-1}" ]; then
    skip "the pip duckdb package is ${PY_DUCKDB_MAJOR}.x but the CLI under test is ${DUCKDB_MAJOR:-1}.x -- the driver cannot read this engine's database file nor load its extension"
    return
  fi
  # soak shape: FSQL_BT_SOAK_WORKERS x FSQL_BT_SOAK_ITERS, defaults 4x10
  local soak_workers="${FSQL_BT_SOAK_WORKERS:-4}" soak_iters="${FSQL_BT_SOAK_ITERS:-10}"
  cat > "$PDIR/gate12.py" <<'PYEOF'
import concurrent.futures as cf
import duckdb, os, sys

db  = os.environ["FSQL_BT_DB"]
ext = os.environ["FSQL_BT_EXT"].replace("'", "''")
cfg = {"allow_unsigned_extensions": "true", "threads": "1"}
S = int(os.environ["FSQL_BT_SOAK_WORKERS"])
I = int(os.environ["FSQL_BT_SOAK_ITERS"])

base = duckdb.connect(db, config=cfg)
base.execute(f"LOAD '{ext}'")
base.execute("DELETE FROM bt_soak")

def worker(w):
    c = base.cursor()
    for i in range(1, I + 1):
        got = c.execute("SELECT fractal_sfs_converge(vec, vec) FROM bt_telemetry WHERE id = 1;").fetchone()
        assert got is not None, "fractal_sfs_converge returned no row"
        c.execute(f"INSERT INTO bt_soak VALUES ({w}, {i}, 'bt-soak')")
    c.close()

with cf.ThreadPoolExecutor(max_workers=S) as ex:
    list(ex.map(worker, range(1, S + 1)))

total = base.execute("SELECT count(*) FROM bt_soak;").fetchone()[0]
assert total == S * I, f"want {S*I} exactly-once inserts, got {total}"
assert base.execute("SELECT 1;").fetchone()[0] == 1, "db unresponsive after soak"
print("gate-12-ok")
# The extension's own contract: "Call [fractal_release()] as the last
# statement of a session that is about to close a file database." It closes
# the connections the extension holds open for nested queries and joins its
# host-departure monitor thread, which otherwise keeps polling the database
# while the host tears it down -- a race that kills the host at exit with a
# hard crash. Best effort: the driver has already reported its result.
try:
    base.execute("SELECT fractal_release();").fetchall()
except Exception:
    pass
PYEOF
  local r rc
  r=$(FSQL_BT_SOAK_WORKERS="$soak_workers" FSQL_BT_SOAK_ITERS="$soak_iters" \
      py_run "$PDIR/gate12.py"); rc=$?
  expect_ok "$rc" "$r" "S x I threaded soak ran clean (every search + insert exact)" "gate-12-ok"
  r=$(sqlq "SELECT count(*) FROM bt_soak;"); rc=$?
  expect_ok "$rc" "$r" "CLI agrees with the soak row count" "$((soak_workers * soak_iters))"
}
gate_13() {
  local r rc
  # the allowlist env var the port reads is FRACTALSQL_-prefixed
  # (fractalsql_extension_agents.cpp's CheckStatementAllowed); the old
  # FSQL_-prefixed alias is a silent no-op
  T2S_ENV=("FRACTALSQL_REASONING_PLUGIN=$(pj mock_reasoning_plugin)" \
           "FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update")
  t2s_expect "SELECT count(*) FROM bt_orders" "SELECT count(*) FROM bt_orders" ok \
             "control: SELECT still flows through"
  t2s_expect "INSERT INTO bt_orders VALUES (1, 1, 10.0, now())" "INSERT INTO bt_orders" ok \
             "INSERT flows through with select_insert_update"
  t2s_expect "UPDATE bt_orders SET amount = 20.0" "UPDATE bt_orders" ok \
             "UPDATE flows through with select_insert_update"
  t2s_expect "DELETE FROM bt_orders" 'statement type "DELETE" is not permitted' err \
             "DELETE stays rejected under siu"
  t2s_expect "DROP TABLE bt_orders" 'statement type "DROP" is not permitted' err \
             "DDL stays rejected under siu"
  r=$(sqlq "SELECT count(*) FROM bt_orders;"); rc=$?
  expect_ok "$rc" "$r" "widened allowlist never executes anything (bt_orders still empty)" "0"
}

gate_14() {
  local r rc
  rm -f "${RETRYPROMPT:?retry prompt contract}"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj retry_reasoning_plugin)" \
      -- "SELECT fractal_text_to_sql('do the thing');")
  rc=$?
  expect_ok "$rc" "$r" "attempt 1 rejected at the allowlist, attempt 2 succeeds in the retry loop" "SELECT 1"
  if [ -f "$RETRYPROMPT" ] && grep -qF "not permitted" "$RETRYPROMPT"; then
    pass "attempt-1 rejection reason was threaded into the attempt-2 GENERATE prompt"
  else
    fail "retry prompt is missing the attempt-1 rejection reason"
    [ -f "$RETRYPROMPT" ] && printf '      got: %.900s\n' "$(cat "$RETRYPROMPT")"
  fi
}

gate_15() {
  local r rc vid
  local embenv=("FRACTALSQL_REASONING_PLUGIN=$(pj mock_embed_plugin)" \
                "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings")
  # dispatch: mock_embed answers every tier with the canned 3-float vector
  r=$(sqlq_env "${embenv[@]}" -- "SELECT len(fractal_embed('hello world'));"); rc=$?
  expect_ok "$rc" "$r" "fractal_embed dispatches through the plugin (3-dim canned vector)" "3"
  r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_embed(NULL) IS NULL;"); rc=$?
  expect_ok "$rc" "$r" "fractal_embed passes NULL through as NULL" "true"
  # the input cap: an over-cap input is refused before any dispatch
  r=$(sqlq_env "${embenv[@]}" -- "SELECT len(fractal_embed(repeat('x', 4194305)));"); rc=$?
  expect_err "exceeds the 4 MiB limit" "$rc" "$r" "an embed input over the 4 MiB cap is refused"
  # config error ladder
  r=$(sqlq "SELECT fractal_embed('x');"); rc=$?
  expect_err "reasoning plugin not configured" "$rc" "$r" "embed tier reports the unconfigured plugin"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj mock_embed_plugin)" -- "SELECT fractal_embed('x');"); rc=$?
  expect_err "FSQL_REASONING_HTTP_EMBED_URL is not configured" "$rc" "$r" "embed tier reports the missing endpoint"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$BADPLUGIN" \
      "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings" \
      -- "SELECT fractal_embed('x');")
  rc=$?
  expect_err "failed to load reasoning plugin" "$rc" "$r" "embed tier reports an unloadable plugin path"
  # over-limit: evil_embed hands back 16385 floats; the enforced dim cap
  # lives in the agents-side parse, before any corpus scan runs
  if have_plugin evil_embed_plugin; then
    r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj evil_embed_plugin)" \
        "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings" \
        -- "SELECT 'x' FROM fractal_search_agent('near doc-2','bt_telemetry','vec',50,30);")
    rc=$?
    expect_err "failed to parse embedding" "$rc" "$r" "16385-float embed response rejected at the agents parse cap"
  else
    skip "evil_embed fixture did not compile"
  fi
  # vectorizer surface end to end (mock embed writes 3-dim vectors)
  r=$(sqlq_env "${embenv[@]}" -- \
      "CREATE TABLE bt_vembed(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" \
      "INSERT INTO bt_vembed VALUES (1, 'alpha doc about telemetry', NULL), (2, 'beta doc', NULL), (3, 'gamma doc', NULL);" \
      "SELECT fractal_vectorizer_create('bt_vembed','body','emb');")
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$(printf '%s' "$r" | tr -cd '0-9')" -gt 0 ] 2>/dev/null; then
    vid="$(printf '%s' "$r" | tr -cd '0-9')"
    pass "vectorizer created for bt_vembed (id $vid)"
  else
    fail "vectorizer create (bt_vembed)"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
    return
  fi
  r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_vectorizer_process_queue(20);"); rc=$?
  expect_ok "$rc" "$r" "backfill drained: process_queue reports 3 embeds" "3"
  r=$(sqlq "SELECT count(*) FROM bt_vembed WHERE len(emb) = 3;"); rc=$?
  expect_ok "$rc" "$r" "write-back populated a 3-dim embedding on every row" "3"
  r=$(sqlq "SELECT pending, processing, done, failed FROM fractal_vectorizer_status() WHERE source_table = 'bt_vembed';")
  rc=$?
  expect_ok "$rc" "$r" "status ledger reads 0|0|3|0 after the drain" "0|0|3|0"
  r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_vectorizer_create('bt_vembed','body','emb');"); rc=$?
  expect_err "already exists (id=" "$rc" "$r" "duplicate create names the vectorizer that already exists"
  r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_vectorizer_create('bt; DROP TABLE bt_vembed--','body','emb');"); rc=$?
  expect_err "invalid identifier" "$rc" "$r" "injection-shaped source_table is refused as an identifier, never executed"
  r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_vectorizer_create('1_leading_digit','body','emb');"); rc=$?
  expect_err "invalid identifier" "$rc" "$r" "digit-leading source_table refused"
  r=$(sqlq_env "${embenv[@]}" -- \
      "CREATE TABLE bt_vsq(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" \
      "INSERT INTO bt_vsq VALUES (1, 'a', NULL);" \
      "SELECT fractal_vectorizer_create('main.bt_vsq','body','emb');"); rc=$?
  expect_ok "$rc" "$r" "schema-qualified source_table (main.bt_vsq) accepted"
  r=$(sqlq "SELECT count(*) FROM fractal_vectorizer_status() WHERE source_table = 'main.bt_vsq';"); rc=$?
  expect_ok "$rc" "$r" "schema-qualified source_table registers under its qualified name" "1"
  # drop it again, so the later gates' process_queue counts see only
  # the vectorizers they create themselves
  sqlq "SELECT fractal_vectorizer_drop(id) FROM fractal_vectorizers WHERE source_table = 'main.bt_vsq';" >/dev/null 2>&1
  # the vectorizer option index_ensure: after a batch an existing index on the embedding column is brought up to date; a control
  # vectorizer without the option leaves its index stale
  r=$(sqlq_env "${embenv[@]}" -- \
      "CREATE TABLE bt_vix(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" \
      "CREATE TABLE bt_vix2(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" \
      "INSERT INTO bt_vix SELECT i, 'text ' || i, NULL FROM range(1, 31) t(i);" \
      "INSERT INTO bt_vix2 SELECT i, 'text ' || i, NULL FROM range(1, 31) t(i);" \
      "SELECT fractal_vectorizer_create('bt_vix','id','body','emb','{\"index_ensure\":true}');" \
      "SELECT fractal_vectorizer_create('bt_vix2','body','emb');" \
      "SELECT fractal_vectorizer_process_queue(100);" \
      "SELECT json_extract(fractal_index_ensure('bt_vix','emb','{\"name\":\"bt_vix_ix\",\"id_col\":\"id\",\"vector_format\":\"FP32\",\"nlist\":2}'),'\$.action');" \
      "SELECT json_extract(fractal_index_ensure('bt_vix2','emb','{\"name\":\"bt_vix2_ix\",\"id_col\":\"id\",\"vector_format\":\"FP32\",\"nlist\":2}'),'\$.action');" \
      "INSERT INTO bt_vix VALUES (101,'new a',NULL),(102,'new b',NULL);" \
      "INSERT INTO bt_vix2 VALUES (101,'new a',NULL),(102,'new b',NULL);" \
      "SELECT fractal_vectorizer_process_queue(100);" \
      "SELECT 'S1=' || json_extract_string(fractal_index_info('bt_vix_ix'),'\$.status') || '/' || json_extract_string(fractal_index_info('bt_vix_ix'),'\$.rows_added_since_build');" \
      "SELECT 'S2=' || json_extract_string(fractal_index_info('bt_vix2_ix'),'\$.status') || '/' || json_extract_string(fractal_index_info('bt_vix2_ix'),'\$.rows_added_since_build');")
  if printf '%s' "$r" | grep -qF "S1=ready/0" && printf '%s' "$r" | grep -qF "S2=stale/2"; then
    pass "a vectorizer with index_ensure folds the batch's new rows into its index (ready); one without leaves it stale"
  else
    fail "index_ensure hook: got '$r'"
  fi
  sqlq "SELECT fractal_vectorizer_drop(id) FROM fractal_vectorizers WHERE source_table IN ('bt_vix','bt_vix2');" >/dev/null 2>&1
  sqlq "SELECT fractal_index_drop('bt_vix_ix'); SELECT fractal_index_drop('bt_vix2_ix'); DROP TABLE bt_vix; DROP TABLE bt_vix2;" >/dev/null 2>&1
  # an unconfigured embed endpoint: every row fails cleanly, and a
  # failed row still counts as processed (it reached the end of its
  # attempt; leaving it out of the count would make a permanently
  # broken row look like a queue that is still moving)
  r=$(sqlq \
      "CREATE TABLE bt_vnoembed(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" \
      "INSERT INTO bt_vnoembed VALUES (1, 'a', NULL), (2, 'b', NULL);" \
      "SELECT fractal_vectorizer_create('bt_vnoembed','body','emb');" \
      "SELECT 'PROCESSED=' || fractal_vectorizer_process_queue(10);" \
      "SELECT 'FAILED=' || count(*) FROM fractal_vectorizer_queue WHERE status='failed' " \
      "AND vectorizer_id = (SELECT id FROM fractal_vectorizers WHERE source_table='bt_vnoembed');" \
      "SELECT error FROM fractal_vectorizer_queue WHERE status='failed' LIMIT 1;")
  rc=$?
  if printf '%s' "$r" | grep -qF "PROCESSED=2" && printf '%s' "$r" | grep -qF "FAILED=2" \
      && printf '%s' "$r" | grep -qF "reasoning plugin not configured"; then
    pass "unconfigured embed endpoint fails every row cleanly, and the failures count as processed"
  else
    fail "unconfigured embed endpoint: got '$r'"
  fi
  r=$(sqlq "SELECT count(*) FROM bt_vembed;"); rc=$?
  expect_ok "$rc" "$r" "nothing was dropped by the injection attempt" "3"
  # a source text over the 4 MiB embed cap: the row fails with the
  # vectorizer's own refusal rather than being sent to the endpoint
  r=$(sqlq_env "${embenv[@]}" -- \
      "CREATE TABLE bt_vbig(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" \
      "INSERT INTO bt_vbig VALUES (1, repeat('x', 4194305), NULL);" \
      "SELECT fractal_vectorizer_create('bt_vbig','body','emb');")
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$(printf '%s' "$r" | tr -cd '0-9')" -gt 0 ] 2>/dev/null; then
    vid="$(printf '%s' "$r" | tr -cd '0-9')"
    pass "vectorizer created for the over-cap source table (id $vid)"
  else
    fail "vectorizer create (bt_vbig)"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
  fi
  r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_vectorizer_process_queue(10);"); rc=$?
  r=$(sqlq "SELECT error FROM fractal_vectorizer_queue WHERE status='failed' " \
      "AND vectorizer_id = (SELECT id FROM fractal_vectorizers WHERE source_table='bt_vbig') LIMIT 1;")
  rc=$?
  expect_ok "$rc" "$r" "an over-cap source text fails the row with the vectorizer's own refusal" \
      "source text exceeds the 4 MiB embed limit"
  # pause/resume on a second vectorizer
  r=$(sqlq_env "${embenv[@]}" -- \
      "CREATE TABLE bt_vsoak_stub(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" \
      "INSERT INTO bt_vsoak_stub VALUES (1, 'stub body', NULL);" \
      "SELECT fractal_vectorizer_create('bt_vsoak_stub'::VARCHAR,'body'::VARCHAR,'emb'::VARCHAR);")
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$(printf '%s' "$r" | tr -cd '0-9')" -gt 0 ] 2>/dev/null; then
    vid="$(printf '%s' "$r" | tr -cd '0-9')"
    pass "second vectorizer created (bt_vsoak_stub, id $vid)"
  else
    fail "second vectorizer create (bt_vsoak_stub)"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
    return
  fi
  r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_vectorizer_pause($vid);"); rc=$?
  expect_ok "$rc" "$r" "pause acknowledged" "true"
  r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_vectorizer_resume($vid);"); rc=$?
  expect_ok "$rc" "$r" "resume acknowledged" "true"
  # clean up the stub queue so later gates' process_queue runs scan only
  # what they create here
  sqlq_env "${embenv[@]}" -- "SELECT fractal_vectorizer_pause($vid);" >/dev/null 2>&1
}

gate_16() {
  local r rc
  r=$(sqlq "CREATE TABLE bt_nopk(a INTEGER, body TEXT, emb DOUBLE[]);" \
            "CREATE TABLE bt_compk(id1 INTEGER, id2 INTEGER, PRIMARY KEY(id1, id2));")
  rc=$?
  expect_ok "$rc" "$r" "validation fixture tables created"
  local embenv=("FRACTALSQL_REASONING_PLUGIN=$(pj mock_embed_plugin)" \
                "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings")
  r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_vectorizer_create('bt_missing_table_v','body','emb');"); rc=$?
  expect_err "internal query failed" "$rc" "$r" "nonexistent source table rejected at create"
  r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_vectorizer_create('bt_nopk','body','emb');"); rc=$?
  expect_err "has no declared PRIMARY KEY" "$rc" "$r" "no-PK source table rejected at create"
  r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_vectorizer_create('bt_compk','body','emb');"); rc=$?
  expect_err "has a composite primary key" "$rc" "$r" "composite-PK source table rejected at create"
  skip "authorizer-driver half of this gate has no duckdb analog (see gate 08)"
}

gate_17() {
  local r rc vid
  local embenv=("FRACTALSQL_REASONING_PLUGIN=$(pj mock_embed_plugin)" \
                "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings")
  r=$(sqlq "CREATE TABLE bt_vsoak(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" \
            "INSERT INTO bt_vsoak SELECT i, 'doc ' || i, NULL FROM generate_series(1, 100) AS g(i);")
  rc=$?
  expect_ok "$rc" "$r" "100-row soak source staged"
  r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_vectorizer_create('bt_vsoak','body','emb');"); rc=$?
  if [ "$rc" -eq 0 ] && [ "$(printf '%s' "$r" | tr -cd '0-9')" -gt 0 ] 2>/dev/null; then
    vid="$(printf '%s' "$r" | tr -cd '0-9')"
    pass "soak vectorizer created (bt_vsoak, id $vid)"
  else
    fail "soak vectorizer create"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
    return
  fi
  local i want
  for i in 1 2 3 4 5 6; do
    want=20
    [ "$i" = "6" ] && want=0
    r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_vectorizer_process_queue(20);"); rc=$?
    expect_ok "$rc" "$r" "drain pass $i reports $want embeds" "$want"
  done
  r=$(sqlq "SELECT pending, processing, done, failed FROM fractal_vectorizer_status() WHERE source_table = 'bt_vsoak';")
  rc=$?
  expect_ok "$rc" "$r" "final queue ledger reads 0|0|100|0" "0|0|100|0"
  r=$(sqlq "SELECT count(*) FROM bt_vsoak WHERE len(emb) = 3;"); rc=$?
  expect_ok "$rc" "$r" "all 100 rows carry a write-back embedding" "100"
}

gate_18() {
  local r rc vid
  r=$(sqlq "CREATE TABLE bt_vcrash(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" \
            "INSERT INTO bt_vcrash VALUES (1, 'one', NULL), (2, 'two', NULL);")
  rc=$?
  expect_ok "$rc" "$r" "crash-vectorizer source staged"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj mock_embed_plugin)" \
      "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings" \
      -- "SELECT fractal_vectorizer_create('bt_vcrash','body','emb');")
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$(printf '%s' "$r" | tr -cd '0-9')" -gt 0 ] 2>/dev/null; then
    vid="$(printf '%s' "$r" | tr -cd '0-9')"
    pass "crash vectorizer created (id $vid)"
  else
    fail "crash vectorizer create"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
    return
  fi
  # die mid-drain: the embed tier loads the crash fixture, generate()
  # dereferences NULL, the CLI process dies inside process_queue. Same
  # deliberate-crash handling as gate 06 (exempt from the sweep; raw
  # SIGSEGV death in --asan).
  SAN_EXEMPT=1
  if [ "$SAN_MODE" = "asan" ]; then
    r=$(sqlq_env "ASAN_OPTIONS=${ASAN_OPTIONS:+${ASAN_OPTIONS}:}handle_segv=0" \
        "FRACTALSQL_REASONING_PLUGIN=$(pj evil_crash_plugin)" \
        "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings" \
        -- "SELECT fractal_vectorizer_process_queue(10);")
  else
    r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj evil_crash_plugin)" \
        "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings" \
        -- "SELECT fractal_vectorizer_process_queue(10);")
  fi
  rc=$?
  SAN_EXEMPT=""
  if crashed "$rc"; then
    pass "CLI died mid-process_queue (rc=$rc)"
  else
    fail "expected the embed step to kill the process mid-drain"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
    return
  fi
  local out recovered deadline
  deadline=$((SECONDS + 30 * TIMEOUT_MULT))
  recovered=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    if out="$("$DUCKDB" -bail -batch -list "$DBW" "SELECT count(*) FROM bt_vcrash;" 2>&1)"; then
      recovered=1
      break
    fi
    sleep 1
  done
  [ -n "$recovered" ] || { fail "database did not reopen within the recovery window"; return; }
  pass "database reopened safely after the mid-drain crash"
  if printf '%s\n' "$out" | grep -qF "2"; then
    pass "source table rows intact after the crash"
  else
    fail "source table rows lost"
    printf '      got: %.900s\n' "$out"
  fi
  # gate 15's write-backs are the persistence canary across gates
  if [ "$(sqlq "SELECT count(*) FROM duckdb_tables() WHERE table_name = 'bt_vembed';" | tr -cd '0-9')" != "0" ] 2>/dev/null; then
    r=$(sqlq "SELECT count(*) FROM bt_vembed WHERE len(emb) = 3;"); rc=$?
    expect_ok "$rc" "$r" "gate-15 write-backs survived the crash too" "3"
  else
    skip "gate 15 did not run in this invocation (bt_vembed absent)"
  fi
  # The vectorizer queue is persisted in the DB, not a TEMP table that
  # dies with the connection -- so the row that was
  # mid-embedding at the crash stays parked in 'processing' here, and the
  # crash's other row is still 'pending': the killed process never wrote
  # anything back, so the post-crash state is 1|1|0 (not 0|1|1).
  r=$(sqlq "SELECT pending, processing, done FROM fractal_vectorizer_status() WHERE source_table = 'bt_vcrash';"); rc=$?
  expect_ok "$rc" "$r" "stranded claim still parked in 'processing' after the crash" "1|1|0"
  # finish the drain on a healthy process: stale_after=1 reclaims the
  # stranded claim at once (the default reclaim window is 600s). The
  # claim must be older than the 1s window first, so wait it out.
  sleep 2
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj mock_embed_plugin)" \
      "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings" \
      -- "SELECT fractal_vectorizer_process_queue(10, 1);")
  rc=$?
  expect_ok "$rc" "$r" "recovery drain reclaims the stranded claim and finishes it" "2"
  r=$(sqlq "SELECT count(*) FROM bt_vcrash WHERE len(emb) = 3;"); rc=$?
  expect_ok "$rc" "$r" "both crash-source rows embedded after the recovery drain" "2"
}
gate_19() {
  local r rc big
  r=$(sqlq "SELECT fractal_sfs_converge([]::DOUBLE[], []::DOUBLE[]);"); rc=$?
  expect_err "query dim 0 out of range [1, 4096]" "$rc" "$r" "empty query vector rejected at the dim bound"
  # over-arena: a constant 4097-element list (one over the cap)
  big="$(awk 'BEGIN{for(i=0;i<4097;i++) printf "%s0.1", (i?",":"")}')"
  r=$(sqlq "SELECT fractal_sfs_converge([$big]::DOUBLE[], [$big]::DOUBLE[]);"); rc=$?
  expect_err "out of range [1, 4096]" "$rc" "$r" "4097-dim query rejected at the vector cap"
  r=$(sqlq "SELECT particle FROM fractal_search_explore('bt_explore','embedding',[0.5, 0.5]::DOUBLE[], NULL);"); rc=$?
  expect_err "does not match bt_explore.embedding" "$rc" "$r" "explore dim mismatch names the table.column it checked"
  r=$(sqlq "SELECT particle FROM fractal_search_explore('bt_explore','embedding',[1.0, 0.05, 0.0, 0.0]::DOUBLE[], '{\"iterations\": 99999999}');"); rc=$?
  expect_err "iterations 99999999 out of range [1, 10000]" "$rc" "$r" "explore options bound enforced"
  r=$(sqlq "SELECT count(*) FROM bt_explore;"); rc=$?
  expect_ok "$rc" "$r" "nothing executed: bt_explore untouched" "60"
}

gate_20() {
  local r rc
  printf 'canary-reason-response\n' > "$SQLTXT"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj mock_reasoning_plugin)" -- "SELECT fractal_reason('question');"); rc=$?
  expect_ok "$rc" "$r" "fractal_reason returns the canned chat response" "canary-reason-response"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj mock_reasoning_plugin)" -- "SELECT fractal_reason(NULL) IS NULL;"); rc=$?
  expect_ok "$rc" "$r" "fractal_reason passes NULL through as NULL" "true"
  r=$(sqlq -- "SELECT fractal_text_to_sql(NULL) IS NULL;"); rc=$?
  expect_ok "$rc" "$r" "fractal_text_to_sql passes NULL through as NULL" "true"
  r=$(sqlq "SELECT count(*) FROM fractal_search_explore('bt_explore','embedding',[1.0, 0.05, 0.0, 0.0]::DOUBLE[], '{\"population_size\":');"); rc=$?
  expect_ok "$rc" "$r" "malformed explore options fall back leniently to defaults"
  # process_queue bounds
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj mock_embed_plugin)" \
      "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings" \
      -- "SELECT fractal_vectorizer_process_queue(0);")
  rc=$?
  expect_err "batch_size must be 1.." "$rc" "$r" "process_queue rejects batch_size 0"
  r=$(sqlq "SELECT fractal_vectorizer_process_queue(100001);"); rc=$?
  expect_err "batch_size must be 1.." "$rc" "$r" "process_queue rejects a batch over the ceiling"
  r=$(sqlq "SELECT fractal_vectorizer_process_queue(10, 0);"); rc=$?
  expect_err "stale_after must be a positive" "$rc" "$r" "process_queue rejects a non-positive stale window"
  # agents-side bound check (the [1, 20] band lives on fractal_sql_agent)
  r=$(sqlq "SELECT * FROM fractal_sql_agent('q', ['bt_orders'], 0, false);"); rc=$?
  expect_err "max_retries out of range [1, 20]" "$rc" "$r" "fractal_sql_agent rejects max_retries 0"
  # staged stale-reclaim: the vectorizer's queue is persisted in the DB,
  # so the claim surgery happens through plain SQL
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj mock_embed_plugin)" \
      "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings" \
      -- "CREATE TABLE bt_vstale(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" \
         "INSERT INTO bt_vstale VALUES (999, 'stale body', NULL);" \
         "SELECT fractal_vectorizer_create('bt_vstale','body','emb');")
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$(printf '%s' "$r" | tr -cd '0-9')" -gt 0 ] 2>/dev/null; then
    pass "stale-reclaim vectorizer created (id $(printf '%s' "$r" | tr -cd '0-9'))"
  else
    fail "stale-reclaim vectorizer create"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
    return
  fi
  # a fresh claim is left alone by the stale window
  sqlq "UPDATE fractal_vectorizer_queue SET status = 'processing', started_at = now() WHERE pk_value = '999';" >/dev/null 2>&1
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj mock_embed_plugin)" \
      "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings" \
      -- "SELECT fractal_vectorizer_process_queue(10, 600);")
  rc=$?
  expect_ok "$rc" "$r" "fresh 'processing' claim not touched by the stale window" "0"
  r=$(sqlq "SELECT status FROM fractal_vectorizer_queue WHERE pk_value = '999';")
  expect_ok "$SQLQ_RC" "$r" "fresh claim still 'processing'" "processing"
  # an old claim IS reclaimed and drained
  sqlq "UPDATE fractal_vectorizer_queue SET status = 'processing', started_at = now() - INTERVAL '7200 seconds' WHERE pk_value = '999';" >/dev/null 2>&1
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj mock_embed_plugin)" \
      "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings" \
      -- "SELECT fractal_vectorizer_process_queue(10, 600);")
  rc=$?
  expect_ok "$rc" "$r" "7200s-old claim reclaimed and drained" "1"
  r=$(sqlq "SELECT status FROM fractal_vectorizer_queue WHERE pk_value = '999';")
  expect_ok "$SQLQ_RC" "$r" "reclaimed claim finished as 'done'" "done"
}

# ----------------------------------------------------------------
# Gate 21: the seeded mutation fuzzer.
# ----------------------------------------------------------------
# The fuzzer is deterministic: the same seed produces the same
# mutants on every run, on every platform, so a failure found in one
# harness can be replayed in the other. The PowerShell port
# (build_test.ps1) draws from the same PRNG, the same character pool
# and the same keyword list in the same order, so the two ports
# generate the SAME mutants from the same seed.
#
# The state lives in a global rather than a command substitution:
# $(fz_rand n) would run in a subshell and throw the updated state
# away, so every draw leaves its result in FZ_R.

FZ_STATE=20260930
FZ_R=0
FZ_MUT=""
FZ_STMTS=0
FZ_OUT=""
FZ_ERR=""
FZ_ALL=""
FZ_RC=0
FZ_TIMEDOUT=0
FZ_N=0
FZ_ALPHA=""
FZ_KEYWORDS=("DELETE " "DROP " "UNION " "INSERT " "UPDATE " "CREATE " "ALTER " "--" "/*" "*/" \
             "' OR '1'='1" "0x" "%" "\\" "||")

fz_rand() {
  # fz_rand <n>: advance the 31-bit LCG and leave the draw in FZ_R.
  local n="$1"
  if [ "$n" -le 0 ]; then FZ_R=0; return 0; fi
  FZ_STATE=$(( (FZ_STATE * 1103515245 + 12345) & 0x7FFFFFFF ))
  FZ_R=$(( FZ_STATE % n ))
}

fz_alphabet() {
  # The character pool a mutation draws from. Deliberately includes the
  # characters that break SQL lexing (quotes, brackets, comment
  # starters), the whitespace that changes statement shape, and two
  # non-ASCII code points so the extension's UTF-8 handling is on the
  # hook too.
  FZ_ALPHA='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789;()[]{}<>*+-/%!,.:=@#$&|~^_ '
  FZ_ALPHA="$FZ_ALPHA"$'\t\n\r'
  FZ_ALPHA="$FZ_ALPHA"$'é€'
}

# The fuzzer counts CHARACTERS, not bytes. The PowerShell port's
# string lengths are UTF-16 units and its substring offsets are
# character offsets, so a shell in the C locale (which counts bytes)
# would draw its mutation positions against a different length and
# generate different mutants from the same seed. C.UTF-8 fixes that.
# The locale is set inside the two functions that need it, so nothing
# else in the harness is affected.
fz_char_semantics() {
  local LC_ALL=C.UTF-8 2>/dev/null
  local probe="aé"
  [ "${#probe}" -eq 2 ]
}

fz_mutate() {
  # fz_mutate <text>: apply 1-3 mutations and leave the result in
  # FZ_MUT. The mutation kinds are the classic ones -- substitute,
  # delete, insert, duplicate a slice, splice another seed in, inject
  # a keyword -- because between them they turn a valid statement into
  # something the extension has never seen.
  local s="$1" i op len pos n cut slice other c kw nseeds
  local LC_ALL=C.UTF-8 2>/dev/null
  fz_alphabet
  fz_rand 3; local ops=$(( FZ_R + 1 ))
  for (( i = 0; i < ops; i++ )); do
    [ ${#s} -eq 0 ] && break
    len=${#s}
    fz_rand 6; op=$FZ_R
    fz_rand "$len"; pos=$FZ_R
    case "$op" in
      0)
        fz_rand "${#FZ_ALPHA}"; c="${FZ_ALPHA:$FZ_R:1}"
        s="${s:0:$pos}${c}${s:$((pos+1))}"
        ;;
      1)
        s="${s:0:$pos}${s:$((pos+1))}"
        ;;
      2)
        fz_rand "${#FZ_ALPHA}"; c="${FZ_ALPHA:$FZ_R:1}"
        s="${s:0:$pos}${c}${s:$pos}"
        ;;
      3)
        fz_rand 16; n=$(( FZ_R + 1 ))
        if (( pos + n > len )); then n=$(( len - pos )); fi
        if (( n > 0 )); then
          slice="${s:$pos:$n}"
          s="${s:0:$pos}${slice}${slice}${s:$((pos+n))}"
        fi
        ;;
      4)
        nseeds=${#FZ_SEEDS[@]}
        if (( nseeds > 0 )); then
          fz_rand "$nseeds"; other="${FZ_SEEDS[$FZ_R]}"
          fz_rand $(( ${#other} + 1 )); cut=$FZ_R
          s="${s:0:$pos}${other:0:$cut}${s:$pos}"
        fi
        ;;
      5)
        fz_rand "${#FZ_KEYWORDS[@]}"; kw="${FZ_KEYWORDS[$FZ_R]}"
        s="${s:0:$pos}${kw}${s:$pos}"
        ;;
    esac
    if [ ${#s} -gt 4096 ]; then s="${s:0:4096}"; fi
  done
  FZ_MUT="$s"
}

fz_trunc() {
  # fz_trunc <text> <n>: the first <n> CHARACTERS of <text>.
  #
  # printf's %.Ns precision counts BYTES, so a mutant carrying one of
  # the pool's non-ASCII code points would be cut short by one or two
  # characters relative to the PowerShell port, which truncates on
  # UTF-16 units. The two ports print the same diagnostic lines, so
  # they cut the same way.
  local s="$1" n="$2"
  local LC_ALL=C.UTF-8 2>/dev/null
  printf '%s' "${s:0:$n}"
}

fz_count_statements() {
  # fz_count_statements <sql>: the number of statements in a SQL text,
  # left in FZ_STMTS.
  #
  # A statement starts at the first character that is not whitespace, a
  # comment, or the inside of a string literal or quoted identifier, and
  # at every character that follows a semicolon. This is the harness'
  # own check of the property the extension's allowlist promises: what
  # comes back must be ONE statement. The extension decides that with
  # DuckDB's parser; this counts it independently, so a hole in the
  # allowlist shows up as a disagreement rather than as a silent pass.
  local sql="$1" n=0 seen=0 afterSemi=0 i=0 len ch
  local LC_ALL=C.UTF-8 2>/dev/null
  FZ_STMTS=0
  [ -z "$sql" ] && return 0
  len=${#sql}
  while [ "$i" -lt "$len" ]; do
    ch="${sql:$i:1}"
    case "$ch" in
      "'")
        i=$(( i + 1 ))
        while [ "$i" -lt "$len" ]; do
          if [ "${sql:$i:1}" = "'" ]; then
            if [ $(( i + 1 )) -lt "$len" ] && [ "${sql:$((i+1)):1}" = "'" ]; then
              i=$(( i + 2 )); continue
            fi
            break
          fi
          i=$(( i + 1 ))
        done
        i=$(( i + 1 ))
        if [ "$seen" -eq 0 ]; then n=1; seen=1; afterSemi=0
        elif [ "$afterSemi" -eq 1 ]; then n=$(( n + 1 )); afterSemi=0; fi
        continue
        ;;
      '"')
        i=$(( i + 1 ))
        while [ "$i" -lt "$len" ]; do
          if [ "${sql:$i:1}" = '"' ]; then
            if [ $(( i + 1 )) -lt "$len" ] && [ "${sql:$((i+1)):1}" = '"' ]; then
              i=$(( i + 2 )); continue
            fi
            break
          fi
          i=$(( i + 1 ))
        done
        i=$(( i + 1 ))
        if [ "$seen" -eq 0 ]; then n=1; seen=1; afterSemi=0
        elif [ "$afterSemi" -eq 1 ]; then n=$(( n + 1 )); afterSemi=0; fi
        continue
        ;;
      '-')
        if [ $(( i + 1 )) -lt "$len" ] && [ "${sql:$((i+1)):1}" = "-" ]; then
          while [ "$i" -lt "$len" ] && [ "${sql:$i:1}" != $'\n' ]; do i=$(( i + 1 )); done
          continue
        fi
        ;;
      '/')
        if [ $(( i + 1 )) -lt "$len" ] && [ "${sql:$((i+1)):1}" = "*" ]; then
          i=$(( i + 2 ))
          while [ $(( i + 1 )) -lt "$len" ]; do
            if [ "${sql:$i:1}" = "*" ] && [ "${sql:$((i+1)):1}" = "/" ]; then break; fi
            i=$(( i + 1 ))
          done
          i=$(( i + 2 ))
          continue
        fi
        ;;
      ';')
        afterSemi=1; i=$(( i + 1 )); continue
        ;;
      ' '|$'\t'|$'\n'|$'\r')
        i=$(( i + 1 )); continue
        ;;
    esac
    if [ "$seen" -eq 0 ]; then n=1; seen=1; afterSemi=0
    elif [ "$afterSemi" -eq 1 ]; then n=$(( n + 1 )); afterSemi=0; fi
    i=$(( i + 1 ))
  done
  FZ_STMTS=$n
}

# fz_run_cli <sql> [<db>]: run the CLI with a wall-clock budget.
# The budget is what keeps a mutant that turns into an unbounded query
# from hanging the harness; the CLI is run WITHOUT -bail, because a SQL
# error is a perfectly ordinary outcome for a mutant and the only
# interesting one is the process dying.
fz_run_cli() {
  local sql="$1" db="${2:-}" tag sqlfile errfile out err rc
  FZ_N=$(( FZ_N + 1 ))
  tag="fz_$$_$FZ_N"
  sqlfile="$PDIR/$tag.sql"
  errfile="$PDIR/$tag.err"
  printf '%s' "$sql" > "$sqlfile"
  if [ -n "$db" ]; then
    out="$(timeout "$FZ_TIMEOUT_SEC" "$DUCKDB" -batch -list -noheader -unsigned "$(wpath "$db")" \
              < "$sqlfile" 2>"$errfile")"
  else
    out="$(timeout "$FZ_TIMEOUT_SEC" "$DUCKDB" -batch -list -noheader -unsigned \
              < "$sqlfile" 2>"$errfile")"
  fi
  rc=$?
  err="$(cat "$errfile" 2>/dev/null)"
  rm -f "$sqlfile" "$errfile"
  # FZ_OUT is stdout alone -- the SQL a statement returned is stdout, and
  # the extension's own warnings (a plugin loaded without a signature) are
  # stderr: counting those as statements is a false positive. FZ_ALL is
  # both, and that is what the sanitizer sweep reads (a report lands on
  # stderr).
  FZ_OUT="$out"
  FZ_ERR="$err"
  FZ_ALL="$out$err"
  FZ_RC=$rc
  # timeout reports 124 when it had to kill the process.
  if [ "$rc" -eq 124 ]; then FZ_TIMEDOUT=1; else FZ_TIMEDOUT=0; fi
}

gate_21() {
  local corpusDir="$HERE/tests/fuzz_corpus"
  local -a seedFiles=()
  local f seeds=() base mut i rc ran=0 replyChecked=0 crashes=0 bypasses=0 reports=0 hangs=0
  local iters=120 budget=60 elapsed stmts head answer

  shopt -s nullglob
  seedFiles=("$corpusDir"/*.sql)
  shopt -u nullglob
  if [ ${#seedFiles[@]} -eq 0 ]; then
    skip "no fuzz corpus under tests/fuzz_corpus (nothing to mutate)"
    return
  fi
  # The seeds keep their trailing newline: $(cat f) would strip it, and
  # a seed one character shorter is a different mutant (the mutation
  # positions are drawn against the seed's length). The sentinel keeps
  # command substitution from eating it.
  for f in "${seedFiles[@]}"; do
    seeds+=("$(cat "$f"; printf 'x')")
    seeds[${#seeds[@]}-1]="${seeds[${#seeds[@]}-1]%x}"
  done

  [ -n "${FSQL_FUZZ_ITERS:-}" ] && iters="$FSQL_FUZZ_ITERS"
  [ -n "${FSQL_FUZZ_TIME:-}" ] && budget="$FSQL_FUZZ_TIME"
  FZ_STATE=20260930
  [ -n "${FSQL_FUZZ_SEED:-}" ] && FZ_STATE="$FSQL_FUZZ_SEED"
  FZ_SEEDS=("${seeds[@]}")

  # The gate's own detector, proved on a known input first: a counter
  # that silently always returned 1 would turn the whole allowlist
  # half of this gate into a no-op, and nothing else here would say so.
  fz_count_statements "SELECT 1; DROP TABLE bt_orders"
  if [ "$FZ_STMTS" -ne 2 ]; then
    fail "21 fuzz: the harness' own statement counter does not see a stacked statement -- the allowlist check below would be vacuous"
    return
  fi
  fz_count_statements "SELECT 'a;b'"
  if [ "$FZ_STMTS" -ne 1 ]; then
    fail "21 fuzz: the harness' own statement counter does not see a semicolon inside a string literal"
    return
  fi

  local mockOk=1
  have_plugin mock_reasoning_plugin || mockOk=0
  if [ "$mockOk" -eq 0 ]; then
    printf '      note: the mock reasoning plugin did not compile; the allowlist half of this gate is skipped\n'
  fi

  local fuzzdb="$PDIR/fuzz.db"
  local start=$SECONDS
  for (( i = 0; i < iters; i++ )); do
    elapsed=$(( SECONDS - start ))
    [ "$elapsed" -ge "$budget" ] && break
    fz_rand "${#FZ_SEEDS[@]}"; base="${FZ_SEEDS[$FZ_R]}"
    fz_mutate "$base"; mut="$FZ_MUT"

    # role 1: the mutant as ordinary SQL
    rm -f "$fuzzdb" "${fuzzdb}.wal"
    fz_run_cli "LOAD '$EXTW';
$mut" "$fuzzdb"
    if [ "$FZ_TIMEDOUT" -eq 1 ]; then
      # A mutant that outran the budget was killed, not crashed: it is
      # reported (a hang is worth a human's eye) but it is not a
      # failure of the extension.
      hangs=$(( hangs + 1 ))
      printf '      note: mutant %d outran the %sms budget and was killed\n' "$i" "$FZ_TIMEOUT_MS"
      printf '      mutant: %s\n' "$(fz_trunc "$mut" 200)"
    elif [ "$FZ_RC" -ge 128 ]; then
      crashes=$(( crashes + 1 ))
      fail "21 fuzz: the CLI died on mutant $i (exit code $FZ_RC)"
      printf '      mutant: %s\n' "$(fz_trunc "$mut" 200)"
      break
    fi
    ran=$(( ran + 1 ))
    if san_posture && san_report "$FZ_ALL"; then
      reports=$(( reports + 1 ))
      fail "21 fuzz: a sanitizer report fired on mutant $i"
      printf '      mutant: %s\n' "$(fz_trunc "$mut" 200)"
      break
    fi

    # role 2: the mutant as a model reply
    if [ "$mockOk" -eq 1 ]; then
      replyChecked=$(( replyChecked + 1 ))
      printf '%s' "$mut" > "$SQLTXT"
      fz_run_cli "LOAD '$EXTW';
SELECT fractal_text_to_sql('give me the orders data');" "$DB"
      if [ "$FZ_TIMEDOUT" -eq 1 ]; then
        hangs=$(( hangs + 1 ))
        printf '      note: mutant %d outran the %sms budget on the allowlist path\n' "$i" "$FZ_TIMEOUT_MS"
        printf '      mutant: %s\n' "$(fz_trunc "$mut" 200)"
      fi
      if san_posture && san_report "$FZ_ALL"; then
        reports=$(( reports + 1 ))
        fail "21 fuzz: a sanitizer report fired on the allowlist path for mutant $i"
        printf '      mutant: %s\n' "$(fz_trunc "$mut" 200)"
        break
      fi
      if [ "$FZ_RC" -eq 0 ] && [ "$FZ_TIMEDOUT" -eq 0 ]; then
        # The allowlist accepted the reply. Two things must hold: the
        # statement it hands back starts with SELECT (or WITH ...),
        # and it is ONE statement. The second is the property the
        # extension decides with DuckDB's parser; the harness counts
        # the statements itself, so a hole in the allowlist shows up
        # as a disagreement rather than as a silent pass.
        answer="${FZ_OUT}"
        head="$(printf '%s' "$answer" | tr -d '\r' | sed -n '/[^[:space:]]/{s/^[[:space:]]*//;p;q;}')"
        case "$head" in
          SELECT*|WITH*) ;;
          *)
            bypasses=$(( bypasses + 1 ))
            fail "21 fuzz: the SELECT-only allowlist returned a non-SELECT statement for mutant $i: $head"
            printf '      mutant: %s\n' "$(fz_trunc "$mut" 200)"
            break
            ;;
        esac
        fz_count_statements "$answer"
        stmts="$FZ_STMTS"
        if [ "$stmts" -gt 1 ]; then
          bypasses=$(( bypasses + 1 ))
          fail "21 fuzz: the SELECT-only allowlist returned $stmts statements for mutant $i: $(fz_trunc "$answer" 120)"
          printf '      mutant: %s\n' "$(fz_trunc "$mut" 200)"
          break
        fi
      fi
    fi
  done
  rm -f "$fuzzdb" "${fuzzdb}.wal"

  if [ "$crashes" -eq 0 ] && [ "$bypasses" -eq 0 ] && [ "$reports" -eq 0 ]; then
    local extra=""
    [ "$replyChecked" -gt 0 ] && extra="$extra, $replyChecked checked against the allowlist"
    [ "$hangs" -gt 0 ] && extra="$extra, $hangs killed on the wall-clock budget"
    pass "21 fuzz: $ran mutant(s) from ${#seedFiles[@]} seed(s) -- no crash, no allowlist bypass$extra"
  fi
  # The invariant that outlives the run: nothing the fuzzer fed the
  # extension was ever executed.
  local r
  r=$(sqlq "SELECT count(*) FROM bt_orders;"); rc=$?
  expect_ok "$rc" "$r" "the fuzzer never executed anything it fed the extension" "0"
}

gate_22() {
  local r rc s pts n
  # -- analytics core --
  r=$(sqlq "SELECT fractal_dimension_dfa([1.0, 2.0, 3.0]::DOUBLE[]);"); rc=$?
  expect_err "series needs >= 16 points" "$rc" "$r" "dfa rejects a too-short series"
  s="$(awk 'BEGIN{s=0; for(i=0;i<32;i++){s+=0.7; printf "%s%.4f", (i?",":""), s}}')"
  r=$(sqlq "SELECT fractal_dimension_dfa([$s]::DOUBLE[]);"); rc=$?
  if [ "$rc" -eq 0 ] && awk -v v="$(printf '%s' "$r" | tr -d '[:space:]')" 'BEGIN{exit !(v+0==v)}'; then
    pass "dfa exponent returned for the monotone walk"
  else
    fail "dfa exponent return shape"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
  fi
  s="$(awk 'BEGIN{for(i=0;i<200;i++) printf "%s%.6f", (i?",":""), sin(i*0.2)}')"
  r=$(sqlq "SELECT fractal_dimension_drift([$s]::DOUBLE[], 64);"); rc=$?
  expect_ok "$rc" "$r" "dimension_drift reports drift/recent_alpha/baseline_alpha" "recent_alpha"
  r=$(sqlq "SELECT fractal_dimension_boxcount([0.0, 0.0, 0.1, 0.1, 0.2, 0.2]::DOUBLE[], 2);"); rc=$?
  expect_err "need >= 8 points" "$rc" "$r" "boxcount rejects a too-small point set"
  # the fixture: 40 jittered points with coordinate
  # magnitudes >= 1 -- the boxcount core reads a sub-unit bounding box
  # as degenerate even at sufficient density
  pts="$(awk 'BEGIN{for(i=1;i<=40;i++) printf "%s%.4f,%.4f", (i>1?",":""), i+((i*13)%7)*0.001, i*0.5+((i*29)%7)*0.001}')"
  r=$(sqlq "SELECT fractal_dimension_boxcount([$pts]::DOUBLE[], 2);"); rc=$?
  if [ "$rc" -eq 0 ] && awk -v v="$(printf '%s' "$r" | tr -d '[:space:]')" 'BEGIN{exit !(v+0==v && v<=2)}'; then
    pass "boxcount dimension returned for the jittered ridge"
  else
    fail "boxcount return shape"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
  fi
  s="$(awk 'BEGIN{for(i=0;i<40;i++) printf "%s%.1f", (i?",":""), (i<20?1.0:3.0)}')"
  r=$(sqlq "SELECT fractal_change_point_detect([$s]::DOUBLE[], 10, 1.0);"); rc=$?
  expect_ok "$rc" "$r" "change_point_detect flags the step change" "[20]"
  r=$(sqlq "SELECT count(*) FROM fractal_periodogram([$s]::DOUBLE[], 3);"); rc=$?
  n="$(printf '%s' "$r" | tr -cd '0-9')"
  if [ "$rc" -eq 0 ] && [ "$n" -ge 1 ] 2>/dev/null; then
    pass "periodogram tabulates freq/power rows"
  else
    fail "periodogram"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
  fi
  r=$(sqlq "SELECT string_agg(column_name, ',') FROM (DESCRIBE SELECT * FROM fractal_periodogram([$s]::DOUBLE[], 3));"); rc=$?
  expect_ok "$rc" "$r" "periodogram columns are named freq and power" "freq,power"
  # -- fractal_spectrogram_entropy: short-time spectral entropy, a plain
  # DOUBLE[] (a period-8 tone, 64 samples, window 16 / hop 8 -> 7 frames) --
  local tone="[sin(2 * pi() * t / 8.0) for t in range(0, 64)]"
  r=$(sqlq "SELECT len(fractal_spectrogram_entropy($tone, 16, 8));"); rc=$?
  expect_ok "$rc" "$r" "spectrogram_entropy yields one value per frame (64 samples, window 16, hop 8 -> 7)" "7"
  r=$(sqlq "SELECT list_min(e) >= 0 AND list_max(e) <= 1 FROM (SELECT fractal_spectrogram_entropy($tone, 16, 8) AS e);"); rc=$?
  expect_ok "$rc" "$r" "every frame entropy is normalized into [0,1]" "true"
  r=$(sqlq "SELECT list_max(fractal_spectrogram_entropy([1.0 for t in range(0, 64)], 16, 8));"); rc=$?
  expect_ok "$rc" "$r" "a constant series reports 0.0 per frame, never NaN" "0.0"
  r=$(sqlq "SELECT (SELECT list_avg(fractal_spectrogram_entropy([sin(t * 12.9898) * 43758.5453 - floor(sin(t * 12.9898) * 43758.5453) for t in range(0, 64)], 16, 8))) > (SELECT list_avg(fractal_spectrogram_entropy($tone, 16, 8)));"); rc=$?
  expect_ok "$rc" "$r" "wideband noise reads more disordered than a tone" "true"
  r=$(sqlq "SELECT len(fractal_spectrogram_entropy($tone));"); rc=$?
  expect_ok "$rc" "$r" "the 1-argument form defaults to window 64 / hop 32 (one frame for 64 samples)" "1"
  r=$(sqlq "SELECT len(fractal_spectrogram_entropy($tone, 16, 8, 3));"); rc=$?
  expect_ok "$rc" "$r" "max_frames caps the output" "3"
  r=$(sqlq "SELECT fractal_spectrogram_entropy(NULL::DOUBLE[], 16, 8) IS NULL;"); rc=$?
  expect_ok "$rc" "$r" "a NULL series passes through as NULL" "true"
  r=$(sqlq "SELECT fractal_spectrogram_entropy($tone, 4, 2);"); rc=$?
  expect_err "window 4 out of range [8, 512]" "$rc" "$r" "spectrogram_entropy rejects window < 8"
  r=$(sqlq "SELECT fractal_spectrogram_entropy($tone, 16, 0);"); rc=$?
  expect_err "hop must be > 0" "$rc" "$r" "spectrogram_entropy rejects hop <= 0"
  r=$(sqlq "SELECT fractal_spectrogram_entropy($tone, 16, 8, 0);"); rc=$?
  expect_err "max_frames 0 out of range [1, 4096]" "$rc" "$r" "spectrogram_entropy rejects max_frames <= 0"
  r=$(sqlq "SELECT fractal_spectrogram_entropy([1.0, 2.0, 3.0]::DOUBLE[], 16, 8);"); rc=$?
  expect_err "series shorter than window" "$rc" "$r" "spectrogram_entropy rejects a series shorter than the window"
  r=$(sqlq "SELECT fractal_change_point_detect(fractal_spectrogram_entropy([(CASE WHEN t < 128 THEN sin(2 * pi() * t / 8.0) ELSE sin(t * 12.9898) * 43758.5453 - floor(sin(t * 12.9898) * 43758.5453) END) for t in range(0, 256)], 32, 16), 3, 8.0, 16);"); rc=$?
  expect_ok "$rc" "$r" "the entropy series feeds change_point_detect (tone -> noise flags a boundary)" "["
  r=$(sqlq "SELECT fractal_tda_persistence_diagram([$pts]::DOUBLE[], 2, 1, 1.0);"); rc=$?
  expect_ok "$rc" "$r" "persistence diagram carries its bars and betti1" "betti1"
  r=$(sqlq "SELECT len(hex(fractal_state_fingerprint([1.0, 0.0, 1.0, 1.0]::DOUBLE[], 64)));"); rc=$?
  expect_ok "$rc" "$r" "state fingerprint n_bits=64 packs into 8 bytes" "16"
  # cycle_detect is a table function, and duckdb bans subqueries in table
  # function arguments -- the alternating fingerprint stream is baked in
  # as BLOB literals (hex(fractal_state_fingerprint([1,0],[0,1],64))).
  # The threshold argument is a hamming threshold, and 64 is the full
  # fingerprint width: every 64-bit pair then reads as equal and the
  # loop closes at cycle_len 1 -- the gate uses a threshold well below
  # the width so the period-2 structure actually has to close.
  r=$(sqlq "SELECT max(cycle_len) FROM fractal_cycle_detect([x'EFFF65115A1D8D10', x'2B5CC30F8F43A34B', x'EFFF65115A1D8D10', x'2B5CC30F8F43A34B', x'EFFF65115A1D8D10', x'2B5CC30F8F43A34B', x'EFFF65115A1D8D10', x'2B5CC30F8F43A34B', x'EFFF65115A1D8D10', x'2B5CC30F8F43A34B']::BLOB[], 8);")
  rc=$?
  expect_ok "$rc" "$r" "cycle detection closes the alternating fingerprint loop" "2"
  # -- portfolio --
  r=$(sqlq "SELECT fractal_optimize_portfolio([0.10, 0.12, 0.07]::DOUBLE[], [0.04, 0.02, 0.01, 0.02, 0.06, 0.02, 0.01, 0.02, 0.05]::DOUBLE[], 2, 42);"); rc=$?
  expect_ok "$rc" "$r" "optimize_portfolio returns scored weights" "weights"
  r=$(sqlq "SELECT fractal_optimize_portfolio([0.10, 0.12, 0.07]::DOUBLE[], [0.04, 0.02]::DOUBLE[], 2, 42);"); rc=$?
  expect_err "must be n_assets^2" "$rc" "$r" "cov length must be n_assets^2"
  r=$(sqlq "SELECT fractal_optimize_subset([10.0, 9.0, 8.0, 7.0, 6.0]::DOUBLE[], [1.0, 1.0, 1.0, 1.0, 1.0]::DOUBLE[], 5);"); rc=$?
  expect_ok "$rc" "$r" "optimize_subset returns scored weights" "weights"
  r=$(sqlq "SELECT * FROM fractal_optimize_portfolio_multimodal_pareto([0.10, 0.12]::DOUBLE[], [0.04, 0.01, 0.01, 0.03]::DOUBLE[], 1);"); rc=$?
  expect_err "requires the FractalSQL Enterprise tier" "$rc" "$r" "pareto frontier stays gated behind the enterprise tier"
  # -- geometry -- (fixture: a
  # 30-node 3D vessel chain with POSITIVE rand()*0.01 jitter and per-edge
  # arc lengths computed as the euclidean distance between consecutive
  # nodes -- signed jitter with exact-1.0 arcs makes the core reject the
  # graph)
  local vascnl vascel vascal
  vascnl="$(awk 'BEGIN{
    srand(1); n=30; nc=""; el=""; al="";
    for (i=0;i<n;i++) { x=i; y=rand()*0.01; z=rand()*0.01;
      xs[i]=x; ys[i]=y; zs[i]=z; if (i>0) nc=nc","; nc=nc x","y","z; }
    for (i=0;i<n-1;i++) { if (i>0) { el=el","; al=al","; }
      el=el i","(i+1);
      dx=xs[i+1]-xs[i]; dy=ys[i+1]-ys[i]; dz=zs[i+1]-zs[i];
      al=al sqrt(dx*dx+dy*dy+dz*dz); }
    printf "%s", nc; }')"
  vascel="$(awk 'BEGIN{
    srand(1); n=30; el="";
    for (i=0;i<n-1;i++) { if (i>0) el=el","; el=el i","(i+1); }
    printf "%s", el; }')"
  vascal="$(awk 'BEGIN{
    srand(1); n=30; al="";
    for (i=0;i<n;i++) { x=i; y=rand()*0.01; z=rand()*0.01;
      xs[i]=x; ys[i]=y; zs[i]=z;
      if (i>0) { dx=xs[i]-xs[i-1]; dy=ys[i]-ys[i-1]; dz=zs[i]-zs[i-1];
        if (i>1) al=al","; al=al sqrt(dx*dx+dy*dy+dz*dz); } }
    printf "%s", al; }')"
  r=$(sqlq "SELECT fractal_vascular_network([$vascnl]::DOUBLE[], [$vascel]::BIGINT[], [$vascal]::DOUBLE[]);"); rc=$?
  expect_ok "$rc" "$r" "vascular network metric parses the graph fixture" "fractal_dimension"
  r=$(sqlq "SELECT fractal_cortical_folding([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0, 1.0, 1.0]::DOUBLE[], [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]::BIGINT[]);"); rc=$?
  expect_ok "$rc" "$r" "cortical folding returns its gyrification key" "gyrification_index"
  nel="$(awk 'BEGIN{for(i=0;i<80;i++) printf "%s%.1f,%.4f", (i?",":""), i, (i%2)*1.0+((i*7)%5-2)*0.001}')"
  local nerveel
  nerveel="$(awk 'BEGIN{for(i=0;i<79;i++) printf "%s%d,%d", (i?",":""), i, i+1}')"
  r=$(sqlq "SELECT fractal_nerve_plexus_metric([$nel]::DOUBLE[], 2, [$nerveel]::BIGINT[]);"); rc=$?
  expect_ok "$rc" "$r" "nerve plexus metric parses the graph fixture" ""
  r=$(sqlq "SELECT fractal_morphological_complexity([$pts]::DOUBLE[], 2);"); rc=$?
  expect_ok "$rc" "$r" "morphological complexity returns dimension/lacunarity" "lacunarity"
  # -- diversify + explain (community ledger surface) --
  r=$(sqlq "SELECT fractal_diversify_enable();"); rc=$?
  expect_ok "$rc" "$r" "diversify_enable reports its state" "true"
  r=$(sqlq "SELECT fractal_explain_result();"); rc=$?
  expect_ok "$rc" "$r" "explain_result carries the dq key" '"dq"'
  # -- telemetry / hybrid / trajectory (core numeric posture) --
  r=$(sqlq "SELECT d.id FROM fractal_search_telemetry('bt_telemetry','vec',[0.6, 0.8, 0.0, 0.0]::DOUBLE[], 2) t \
        JOIN bt_telemetry d ON CAST(d.rowid AS VARCHAR) = t.doc_id ORDER BY t.distance LIMIT 1;")
  rc=$?
  expect_ok "$rc" "$r" "telemetry doc_id joins back to the source row (nearest first)" "1"
  r=$(sqlq "SELECT scan_pos FROM fractal_search_telemetry('bt_telemetry','vec',[0.6, 0.8, 0.0, 0.0]::DOUBLE[], 2) LIMIT 1;")
  rc=$?
  expect_ok "$rc" "$r" "scan position starts at 0 for the nearest hit" "0"
  r=$(sqlq "SELECT 'x' FROM fractal_search_telemetry('bt_telemetry','vec',[0.0, 0.0, 0.0, 0.0]::DOUBLE[], 0);"); rc=$?
  expect_err "out of range [1," "$rc" "$r" "telemetry k bound enforced"
  r=$(sqlq "SELECT 'x' FROM fractal_hybrid_clinical_search('bt_telemetry','vec',[0.0, 1.0, 0.0, 0.0]::DOUBLE[], ['2','4','5'], 3);"); rc=$?
  expect_ok "$rc" "$r" "hybrid clinical search honors the rowid cohort"
  r=$(sqlq "SELECT 'x' FROM fractal_hybrid_clinical_search('bt_telemetry','vec',[0.0, 1.0, 0.0, 0.0]::DOUBLE[], ['9999999'], 3);"); rc=$?
  expect_err "doc_ids cohort matched no rows" "$rc" "$r" "zero-cohort hybrid search reports the miss"
  r=$(sqlq "SELECT 'x' FROM fractal_search_trajectory('bt_traj','vec',[0.0, 0.0, 0.0, 0.0]::DOUBLE[],[0.3, 0.0, 0.0, 0.0]::DOUBLE[], 3);")
  rc=$?
  expect_ok "$rc" "$r" "search_trajectory returns the trajectory corridor"
  # the ledger
  # reads its OWN fsql ctx, which a fresh CLI process has never run a
  # search through, so the
  # score legitimately reads NaN here -- a non-NaN assertion cannot be
  # reproduced through the CLI
  r=$(sqlq "SELECT fractal_detect_collapse();")
  rc=$?
  expect_ok "$rc" "$r" "detect_collapse responds" "nan"
  # ...but the telemetry search of the SAME connection feeds the diversify monitor: after a warm window of searches on a
  # connection with diversify on, the diversity quotient is a real number (it was NaN while every search ran on a private context)
  local dq_sql="CREATE OR REPLACE TABLE dq_t AS SELECT i AS id, [(i*7%97)/97.0, (i*13%89)/89.0, (i*5%83)/83.0]::DOUBLE[] AS emb FROM range(1,60) t(i); SELECT fractal_diversify_enable(); SELECT fractal_diversify_set_params(8, NULL, 0.3, 0.5);" dq_g
  for dq_g in 0 1 2 3 4 5 6 7 8 9; do
    dq_sql+=" SELECT count(*) FROM fractal_search_telemetry('dq_t','emb',[$(awk -v g=$dq_g 'BEGIN{printf "%.2f,%.2f,%.2f", 0.9-g*0.05, 0.5+g*0.05, (g-3)*0.1}')]::float8[],3);"
  done
  r=$(sqlq "$dq_sql SELECT fractal_detect_collapse(); DROP TABLE dq_t;"); rc=$?
  dq_g="$(printf '%s\n' "$r" | grep -v '^true$' | tail -1)"
  if [ "$rc" -eq 0 ] && [[ "$dq_g" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
    pass "22 vector_api: detect_collapse is a real number after a warm window of telemetry searches on a diversify-enabled connection ($dq_g)"
  else
    fail "22 vector_api: detect_collapse after warm telemetry searches was '$dq_g' (rc=$rc)"
  fi
  # -- vector math --
  r=$(sqlq "SELECT fractal_vector_lp_distance([1.0, 0.0, 0.0]::FLOAT[], [0.5, 0.0, 0.0]::FLOAT[], 2.0);"); rc=$?
  expect_ok "$rc" "$r" "lp distance p=2 reports the half-step" "0.5"
  r=$(sqlq "SELECT fractal_vector_lp_distance([1.0, 0.0, 0.0]::FLOAT[], [0.5, 0.0, 0.0]::FLOAT[], 0.0);"); rc=$?
  expect_err "p must be > 0" "$rc" "$r" "lp distance rejects p=0"
  # the proportional pair only zeroes out at the float32 epsilon, so the
  # gate rounds before comparing
  r=$(sqlq "SELECT round(fractal_vector_cosine_distance([1.0, 2.0, 3.0]::FLOAT[], [2.0, 4.0, 6.0]::FLOAT[]), 6);"); rc=$?
  expect_ok "$rc" "$r" "cosine distance of proportional vectors rounds to 0" "0.0"
  r=$(sqlq "SELECT json_extract(fractal_vector_quantize_int8([1.0, -1.0, 0.5]::FLOAT[]), '$' || '.scale') IS NOT NULL;"); rc=$?
  expect_ok "$rc" "$r" "int8 quantization carries a scale" "true"
  local ten_bits="[1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0]"
  r=$(sqlq "SELECT octet_length(fractal_vector_quantize_binary($ten_bits::FLOAT[]));"); rc=$?
  expect_ok "$rc" "$r" "binary quantization packs 10 bits into 2 bytes" "2"
  r=$(sqlq "SELECT fractal_vector_hamming_distance(fractal_vector_quantize_binary($ten_bits::FLOAT[]), fractal_vector_quantize_binary($ten_bits::FLOAT[]));")
  rc=$?
  expect_ok "$rc" "$r" "hamming distance of identical blobs is 0" "0"
  r=$(sqlq "SELECT fractal_vector_hamming_distance(fractal_vector_quantize_binary($ten_bits::FLOAT[]), fractal_vector_quantize_binary([1.0, 1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0]::FLOAT[]));")
  rc=$?
  expect_ok "$rc" "$r" "hamming distance counts one flipped sign" "1"
}

gate_23() {
  # the settings table in the reasoning-setup guide names every configuration key this build defines
  if command -v python3 >/dev/null 2>&1; then
    local dcout; dcout="$(python3 -I "$HERE/test/check_config_docs.py" "$HERE" 2>&1)" \
      && pass "23 agents: ${dcout#check_config_docs: }" || fail "23 agents: ${dcout#check_config_docs: }"
  else skip "23 agents: the settings-table check needs python3"; fi
  local r rc n
  local embenv=("FRACTALSQL_REASONING_PLUGIN=$(pj mock_embed_plugin)" \
                "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings")
  # the search/rag agents embed their query through the EMBED tier (the
  # mock's canned 3-dim vector), so the corpus is 3-dim to match
  r=$(sqlq "CREATE TABLE bt_agent_docs(id INTEGER, tag VARCHAR, body VARCHAR, emb DOUBLE[]);" \
            "INSERT INTO bt_agent_docs VALUES " \
            " (1, 'doc-1', 'doc-a about cosine metrics', [1.0, 0.05, 0.0])," \
            " (2, 'doc-2', 'doc-b about vector stores', [1.0, 0.1, 0.0])," \
            " (3, 'doc-3', 'doc-c about fractal search', [0.05, 1.0, 0.0])," \
            " (4, 'doc-4', 'doc-d on SFS optimization', [0.1, 0.95, 0.0])," \
            " (5, 'doc-5', 'doc-e on embedding tiers', [0.05, 0.0, 1.0]);")
  rc=$?
  expect_ok "$rc" "$r" "agent fixture table staged"
  # search_agent: embed (mock), scan, answer (chat mock) -- the shape is
  # everything, the content is canned
  r=$(sqlq_env "${embenv[@]}" -- \
      "SELECT (answer IS NOT NULL) AND (len(source_row_ids) >= 1) FROM fractal_search_agent('near doc-1','bt_agent_docs','emb',50,30);")
  rc=$?
  expect_ok "$rc" "$r" "search_agent embeds, scans, and answers with doc ids" "true"
  # rag_agent: same pipeline minus the answer synthesis
  r=$(sqlq_env "${embenv[@]}" -- \
      "SELECT (answer IS NOT NULL) FROM fractal_rag_agent('near doc-1','bt_agent_docs','emb','{}');")
  rc=$?
  expect_ok "$rc" "$r" "rag_agent returns an answer row" "true"
  # retrieval: meta_filter, row ids, the index path (agent_use_index off/on/auto), the context budget, fractal_index_ensure
  r=$(sqlq_env "${embenv[@]}" -- "SELECT json_extract(fractal_index_ensure('bt_agent_docs','emb','{\"name\":\"bt_agent_ix\",\"id_col\":\"id\",\"vector_format\":\"FP32\",\"nlist\":2}'),'\$.action');"); rc=$?
  expect_ok "$rc" "$r" "ensure builds the index when there is none (created)" '"created"'
  r=$(sqlq "SELECT json_extract(fractal_index_ensure('bt_agent_docs','emb'),'\$.action');"); rc=$?
  expect_ok "$rc" "$r" "ensure on a fit index changes nothing (unchanged)" '"unchanged"'
  r=$(sqlq "INSERT INTO bt_agent_docs VALUES (6, 'doc-6', 'doc-f late arrival', [0.9, 0.2, 0.0]);" "SELECT json_extract(fractal_index_ensure('bt_agent_docs','emb'),'\$.action');"); rc=$?
  expect_ok "$rc" "$r" "ensure folds in a few added rows (refreshed)" '"refreshed"'
  r=$(sqlq "INSERT INTO bt_agent_docs SELECT 100 + i, 'doc-x', 'extra ' || i, [0.3, 0.3, 0.9]::DOUBLE[] FROM range(10) t(i);" "SELECT json_extract(fractal_index_ensure('bt_agent_docs','emb'),'\$.action');"); rc=$?
  expect_ok "$rc" "$r" "ensure rebuilds after more than a quarter of the rows were added (rebuilt)" '"rebuilt"'
  r=$(sqlq_env "${embenv[@]}" -- "SELECT used_index FROM fractal_rag_agent('near doc-1','bt_agent_docs','emb','{}');"); rc=$?
  expect_ok "$rc" "$r" "rag_agent scans by default (used_index false)" "false"
  r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_config_set('agent_use_index','on');" "SELECT used_index FROM fractal_rag_agent('near doc-1','bt_agent_docs','emb','{}');" | tail -1); rc=$?
  expect_ok "$rc" "$r" "agent_use_index on sends rag_agent through the index (used_index true)" "true"
  # plan_explore through the index: the nearest rows from the index, each branch_id still the row's position in the full scan
  PEQ="SELECT count(*) || '/' || count(*) FILTER (WHERE abs(b.plan_trajectory[1] - s.emb[1]) < 0.000001) FROM fractal_agent_plan_explore('near doc-1','bt_agent_docs','emb',3) b JOIN (SELECT emb, row_number() OVER () - 1 AS pos FROM bt_agent_docs) s ON s.pos = b.branch_id;"
  r=$(sqlq_env "${embenv[@]}" -- "$PEQ" | tail -1); rc=$?
  expect_ok "$rc" "$r" "plan_explore scans by default and each branch_id is the row's position with its own vector" "3/3"
  r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_config_set('agent_use_index','on');" "$PEQ" "SELECT json_extract(fractal_index_info('bt_agent_ix'),'\$.last_search.used_index');" | tr '\n' ' '); rc=$?
  if printf '%s' "$r" | grep -qF "3/3" && printf '%s' "$r" | grep -qF "true"; then
    pass "plan_explore with agent_use_index on finds its branches through the index (ids are still full-scan positions)"
  else
    fail "plan_explore through the index: got '$r'"
  fi
  r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_config_set('agent_use_index','auto');" "SELECT used_index FROM fractal_rag_agent('near doc-1','bt_agent_docs','emb','{}');" "SELECT fractal_config_set('agent_index_min_rows','5');" "SELECT used_index FROM fractal_rag_agent('near doc-1','bt_agent_docs','emb','{}');" | grep -E '^(true|false)$' | tr '\n' ' '); rc=$?
  expect_ok "$rc" "$r" "auto scans a small table and uses the ready index once the table reaches agent_index_min_rows" "false true "
  r=$(sqlq "SELECT fractal_config_set('agent_use_index','sometimes');"); rc=$?
  expect_err "must be one of: off, on, auto" "$rc" "$r" "agent_use_index refuses a value that is not off, on or auto"
  r=$(sqlq "SELECT fractal_config_set('text_to_sql_allowed_statements','select_insert_update');" "SELECT fractal_config_get('text_to_sql_allowed_statements');" "SELECT fractal_config_set('text_to_sql_use_review','on');" "SELECT fractal_config_get('text_to_sql_use_review');" | tr '\n' ' '); rc=$?
  expect_ok "$rc" "$r" "the text-to-SQL keys are settable and read back" "true select_insert_update true 1"
  r=$(sqlq "SELECT fractal_config_keys() LIKE '%{\"name\":\"agent_use_index\",\"type\":\"enum\",\"session_overridable\":true}%' AND fractal_config_keys() LIKE '%{\"name\":\"http_num_ctx\",\"type\":\"int\",%';"); rc=$?
  expect_ok "$rc" "$r" "fractal_config_keys lists each key with its type and session scope" "true"
  r=$(sqlq "SELECT fractal_config_set('text_to_sql_allowed_statements','delete');"); rc=$?
  expect_err "must be one of: select, select_insert_update" "$rc" "$r" "text_to_sql_allowed_statements refuses a value outside its choices"
  r=$(sqlq "SELECT fractal_config_set('text_to_sql_use_review','maybe');"); rc=$?
  expect_err "must be one of: on, off" "$rc" "$r" "text_to_sql_use_review refuses a value that is not on or off"
  r=$(sqlq "SELECT fractal_config_set('enterprise_require_signature','on');" "SELECT fractal_config_get('enterprise_require_signature');" | tr '\n' ' '); rc=$?
  expect_ok "$rc" "$r" "enterprise_require_signature can be turned on from SQL" "true 1"
  r=$(sqlq "SELECT fractal_config_set('enterprise_require_signature','off');"); rc=$?
  expect_err "can only be turned on from SQL" "$rc" "$r" "enterprise_require_signature cannot be turned off from SQL (an operator setting)"
  r=$(sqlq_env "${embenv[@]}" -- "SELECT list_sort(source_row_ids) = (SELECT list_sort(list(rowid)) FROM bt_agent_docs WHERE tag = 'doc-3') FROM fractal_rag_agent('near doc-3','bt_agent_docs','emb','{\"tag\":\"doc-3\"}');"); rc=$?
  expect_ok "$rc" "$r" "meta_filter limits the scan to the matching rows, and source_row_ids are their row ids" "true"
  r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_config_set('agent_use_index','on');" "SELECT list_sort(source_row_ids) = (SELECT list_sort(list(rowid)) FROM bt_agent_docs WHERE tag = 'doc-3') AND used_index FROM fractal_rag_agent('near doc-3','bt_agent_docs','emb','{\"tag\":\"doc-3\"}');" | tail -1); rc=$?
  expect_ok "$rc" "$r" "meta_filter through the index passes the matching keys as the ids option, same rows" "true"
  r=$(sqlq_env "${embenv[@]}" -- "SELECT * FROM fractal_rag_agent('q','bt_agent_docs','emb','{\"nosuch\":1}');"); rc=$?
  expect_err "nosuch" "$rc" "$r" "a meta_filter column the table does not have is an error"
  r=$(sqlq_env "${embenv[@]}" -- "SELECT * FROM fractal_rag_agent('q','bt_agent_docs','emb','{\"tag\":\"nope\"}');"); rc=$?
  expect_err "for that meta_filter" "$rc" "$r" "a meta_filter that matches no row is an error, never ignored"
  r=$(sqlq_env "${embenv[@]}" -- "SELECT * FROM fractal_rag_agent('q','bt_agent_docs','emb','[1]');"); rc=$?
  expect_err "meta_filter must be a JSON object" "$rc" "$r" "a meta_filter that is not an object is an error"
  r=$(sqlq_env "${embenv[@]}" -- "SELECT fractal_config_set('agent_context_row_bytes','5');" "SELECT json_extract(context_cut,'\$.cells')::INT > 0 AND execution_time_ms >= 0 FROM fractal_search_agent('near doc-1','bt_agent_docs','emb',10,5, meta_filter := '{\"tag\":\"doc-1\"}');" | tail -1); rc=$?
  expect_ok "$rc" "$r" "a text cell over agent_context_row_bytes is cut and counted; search_agent takes a named meta_filter and reports a measured time" "true"
  r=$(sqlq "SELECT fractal_chunk_text('abcdefghij', 4, 1, 'fixed');"); rc=$?
  expect_ok "$rc" "$r" "chunk_text fixed, size 4, overlap 1" '[{"no":0,"start":0,"end":4,"text":"abcd"},{"no":1,"start":3,"end":7,"text":"defg"},{"no":2,"start":6,"end":10,"text":"ghij"}]'
  r=$(sqlq "SELECT string_agg(json_extract_string(e,'\$.start') || '-' || json_extract_string(e,'\$.end') || ':' || json_extract_string(e,'\$.text'), '|') FROM (SELECT unnest(from_json(fractal_chunk_text('One. Two sentences! Is this three? Yes.  Four is a long one that keeps on going and going.', 30, 5, 'sentence'), '[\"JSON\"]')) AS e);"); rc=$?
  expect_ok "$rc" "$r" "chunk_text sentence packing, a long sentence split with overlap" "0-19:One. Two sentences!|20-39:Is this three? Yes.|41-71:Four is a long one that keeps |66-90:eeps on going and going."
  r=$(sqlq "SELECT fractal_chunk_text('', 10, 0), fractal_chunk_text(NULL, 10, 0) IS NULL;"); rc=$?
  expect_ok "$rc" "$r" "chunk_text of empty text is [] and of NULL is NULL" "[]"
  r=$(sqlq "SELECT fractal_chunk_text('x', 5, 5);"); rc=$?
  expect_err "overlap must be 0..size-1" "$rc" "$r" "chunk_text refuses an overlap of size or more"
  r=$(sqlq "SELECT fractal_chunk_text('x', 5, 0, 'word');"); rc=$?
  expect_err "mode must be one of: fixed, paragraph, sentence" "$rc" "$r" "chunk_text refuses an unknown mode"
  # sql_agent: never executes under auto_execute=false, reports the
  # pipeline status per row
  printf 'SELECT count(*) FROM bt_agent_docs\n' > "$SQLTXT"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj mock_reasoning_plugin)" -- \
      "SELECT (len(generated_sql) > 0) AND (retry_count IS NOT NULL) FROM fractal_sql_agent('how many rows live in bt_agent_docs', ['bt_agent_docs'], 3, false);")
  rc=$?
  expect_ok "$rc" "$r" "sql_agent returns the generated_sql + retry pipeline columns" "true"
  printf 'DROP TABLE bt_agent_docs\n' > "$SQLTXT"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj mock_reasoning_plugin)" -- \
      "SELECT execution_status FROM fractal_sql_agent('nuke it', ['bt_agent_docs'], 1, false);")
  rc=$?
  expect_ok "$rc" "$r" "sql_agent surfaces validation_failed for rejected SQL" "validation_failed"
  # fractal_cross_modal_search concatenates its two modality vectors
  # (morphology ++ clinical) into one query of its combined dim, so
  # its corpus needs that combined dim, not bt_agent_docs's 3 (sized for
  # the EMBED tier's canned output) -- a separate 6-dim (3+3) fixture.
  # bt_traj itself is created in bt_setup (PK + the 0.0..0.4 reference
  # walk) -- re-creating it here would collide with that.
  r=$(sqlq "CREATE TABLE bt_agent_docs_xmodal(id INTEGER, body VARCHAR, emb DOUBLE[]);" \
            "INSERT INTO bt_agent_docs_xmodal VALUES " \
            " (1, 'xm-a morph-heavy', [1.0, 0.05, 0.0, 0.05, 0.0, 0.0])," \
            " (2, 'xm-b balanced', [0.5, 0.5, 0.0, 0.5, 0.5, 0.0])," \
            " (3, 'xm-c clinical-heavy', [0.0, 0.05, 0.0, 1.0, 0.05, 0.0]);")
  rc=$?
  expect_ok "$rc" "$r" "xmodal fixture staged"
  # plan_explore: two branches planned from the fixture corpus (it rides
  # the reasoning plugin like every LLM-adjacent agent)
  r=$(sqlq_env "${embenv[@]}" -- \
      "SELECT count(*) FROM fractal_agent_plan_explore('1.0,0.0,0.0,0.0','bt_agent_docs','emb',2);")
  rc=$?
  n="$(printf '%s' "$r" | tr -cd '0-9')"
  if [ "$rc" -eq 0 ] && [ "$n" -ge 2 ] 2>/dev/null; then
    pass "plan_explore produced the requested branch count"
  else
    fail "plan_explore"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
  fi
  # trajectory_predict: baseline row 1 vs the corridor ahead
  r=$(sqlq_env "${embenv[@]}" -- \
      "SELECT max(projected_drift_delta) FROM fractal_agent_trajectory_predict('bt_traj','vec',1,2);")
  rc=$?
  if [ "$rc" -eq 0 ] && awk -v v="$(printf '%s' "$r" | tr -d '[:space:]')" 'BEGIN{exit !(v+0==v)}'; then
    pass "trajectory_predict reports a numeric drift projection"
  else
    fail "trajectory_predict"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
  fi
  # detect_loop: one-hot alternation closes the cycle; distinct
  # directions with varied norms do not (32 states -- the DFA needs
  # >= 24 points and a non-constant series, and the fingerprint is
  # SimHash over a 2-dim state so direction spread matters)
  local states states2
  states="$(awk 'BEGIN{for(i=0;i<16;i++){ if(i%2==0){ printf "%s1.0,0.0", (i?",":"") } else { printf ",0.0,1.0" } }}')"
  r=$(sqlq "SELECT fractal_agent_detect_loop('agent-t1', [$states]::DOUBLE[], 2).is_loop_detected;"); rc=$?
  expect_ok "$rc" "$r" "one-hot alternation flags the state loop" "true"
  states2="0.999,0.05, 1.261,0.317, 0.633,0.3, 0.963,0.716, 0.604,0.667, 0.719,1.201, 0.202,0.565, 0.16,1.088, -0.04,0.799, -0.366,1.455, -0.3,0.633, -0.775,1.043, -0.667,0.604, -1.03,0.616, -0.565,0.202, -1.385,0.204, -0.999,-0.05, -0.776,-0.195, -1.175,-0.557, -0.562,-0.418, -1.006,-1.112, -0.462,-0.772, -0.37,-1.036, -0.087,-0.594, 0.06,-1.199, 0.341,-1.358, 0.343,-0.723, 0.418,-0.562, 0.964,-0.872, 0.858,-0.513, 1.413,-0.504, 0.89,-0.131"
  r=$(sqlq "SELECT fractal_agent_detect_loop('agent-t2', [$states2]::DOUBLE[], 2).is_loop_detected;"); rc=$?
  expect_ok "$rc" "$r" "drifting walk reads loop-free" "false"
  # telemetry over the fixture table
  r=$(sqlq "SELECT count(*) FROM fractal_search_telemetry('bt_agent_docs','emb',[1.0, 0.0, 0.0]::DOUBLE[], 2) WHERE doc_id IS NOT NULL;"); rc=$?
  expect_ok "$rc" "$r" "telemetry reports scan diagnostics for k hits" "2"
  r=$(sqlq "SELECT count(*) FROM fractal_hybrid_clinical_search('bt_agent_docs','emb',[1.0, 0.0, 0.0]::DOUBLE[], ['1','2','3'], 2);"); rc=$?
  expect_ok "$rc" "$r" "hybrid search narrows to the cohort" "2"
  r=$(sqlq "SELECT 'x' FROM fractal_hybrid_clinical_search('bt_agent_docs','emb',[1.0, 0.0, 0.0]::DOUBLE[], []::VARCHAR[], 2);"); rc=$?
  expect_err "doc_ids must be non-empty" "$rc" "$r" "empty cohort rejected"
  # cross_modal + guards (queries stay 3-dim each; the fixture table
  # carries the combined 6-dim)
  r=$(sqlq "SELECT count(*) FROM fractal_cross_modal_search('bt_agent_docs_xmodal','emb',[1.0, 0.0, 0.0]::DOUBLE[], [0.0, 1.0, 0.0]::DOUBLE[], 0.5, 2);")
  rc=$?
  expect_ok "$rc" "$r" "cross_modal search blends morphology and clinical vectors"
  r=$(sqlq "SELECT 'x' FROM fractal_cross_modal_search('bt_agent_docs_xmodal','emb',[1.0, 0.0, 0.0]::DOUBLE[], [0.0, 1.0, 0.0]::DOUBLE[], 1.5, 2);")
  rc=$?
  expect_err "alpha_weight must be in [0,1]" "$rc" "$r" "cross_modal alpha bound enforced"
  r=$(sqlq "SELECT 'x' FROM fractal_hybrid_clinical_search('bt_agent_docs','emb',[1.0, 0.0, 0.0]::DOUBLE[], ['1','2'], 0);"); rc=$?
  expect_err "out of range [1," "$rc" "$r" "hybrid k bound enforced"
  # empty corpus
  r=$(sqlq "CREATE TABLE bt_agent_empty(id INTEGER, emb DOUBLE[]);"); rc=$?
  expect_ok "$rc" "$r" "empty fixture table created"
  r=$(sqlq_env "${embenv[@]}" -- "SELECT 'x' FROM fractal_search_agent('q','bt_agent_empty','emb',50,30);"); rc=$?
  expect_err "no rows found in bt_agent_empty.emb" "$rc" "$r" "empty corpus reported distinctly after the embed step"
  r=$(sqlq "SELECT fractal_explain_result();"); rc=$?
  expect_ok "$rc" "$r" "explain_result closes the pipeline (dq key present)" '"dq"'
}

gate_24() {
  local r rc
  r=$(sqlq "SELECT fractal_ledger_flush();"); rc=$?
  expect_err "requires the FractalSQL Enterprise tier" "$rc" "$r" "ledger_flush reports the dormant enterprise tier"
  r=$(sqlq "SELECT fractal_audit_log('bt-entry', '{}');"); rc=$?
  expect_err "requires the FractalSQL Enterprise tier" "$rc" "$r" "audit_log reports the dormant enterprise tier"
  # a configured-but-unloadable lib surfaces the loader detail on stderr
  # (the dormant-tier message rides along with it; both lines land in
  # the captured output)
  r=$(sqlq_env "FRACTALSQL_ENTERPRISE_LIB=$BTROOTW/fractalsql_bt_nonexistent_enterprise$PLUGSUF" "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0" \
      -- "SELECT fractal_ledger_flush();")
  rc=$?
  expect_err "could not load enterprise library" "$rc" "$r" "unloadable enterprise lib reports the loader error"
  if printf '%s\n' "$r" | grep -qF "requires the FractalSQL Enterprise tier"; then
    pass "dormant-tier message retained alongside the loader detail"
  else
    fail "dormant-tier message missing next to the loader error"
    printf '      got: %.900s\n' "$r"
  fi
}
gate_25() {
  if [ -n "$SAN_MODE" ]; then
    skip "python driver gate: the pip-duckdb host process cannot be instrumented (skipped in ${SAN_MODE} mode)"
    return
  fi
  # the real core when FSQL_TEST_ENTERPRISE_LIB names it, otherwise the mock core (test/mock_enterprise.c)
  local ent25="${FSQL_TEST_ENTERPRISE_LIB:-}"
  if [ -z "$ent25" ] || [ ! -f "$ent25" ]; then
    if ! command -v cc >/dev/null 2>&1 || ! cc -shared -fPIC -std=c99 -I"$HERE/include" "$HERE/test/mock_enterprise.c" -o "$PDIR/gate25_mock_enterprise$PLUGSUF" 2>/dev/null; then
      fail "25 enterprise_stress: the mock enterprise core did not build (set FSQL_TEST_ENTERPRISE_LIB to use the real one)"; return
    fi
    ent25="$PDIR/gate25_mock_enterprise$PLUGSUF"
  fi
  if [ -z "$PY" ]; then
    skip "python with the pip duckdb package is unavailable (set FSQL_PYTHON)"
    return
  fi
  if [ -n "$PY_DUCKDB_MAJOR" ] && [ "$PY_DUCKDB_MAJOR" != "${DUCKDB_MAJOR:-1}" ]; then
    skip "the pip duckdb package is ${PY_DUCKDB_MAJOR}.x but the CLI under test is ${DUCKDB_MAJOR:-1}.x -- the driver cannot read this engine's database file nor load its extension"
    return
  fi
  cat > "$PDIR/gate25.py" <<'PYEOF'
import concurrent.futures as cf
import duckdb, json, os, sys

db  = os.environ["FSQL_BT_DB"]
ext = os.environ["FSQL_BT_EXT"].replace("'", "''")
os.environ["FRACTALSQL_ENTERPRISE_LIB"] = os.environ["FSQL_TEST_ENTERPRISE_LIB"]
os.environ["FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE"] = "0"   # test core ships unsigned
cfg = {"allow_unsigned_extensions": "true", "threads": "1"}

con = duckdb.connect(db, config=cfg)
con.execute(f"LOAD '{ext}'")

def verified(v):
    """The verify verdict: the document parses and says ok."""
    try:
        d = json.loads(str(v))
    except Exception:
        return False
    return isinstance(d, dict) and d.get("ok") is True

# verify() must run with the core loaded and keep its exact contract. The
# extension's documented form is compact -- {"ok":true,"rows_verified":N}
# (src/fsql_ledger_store.h) -- so the check parses the document instead of
# matching a spelling.
v = con.execute("SELECT fractal_ledger_verify();").fetchone()[0]
assert verified(v), f"verify contract changed: {v!r}"

# with the core loaded the persistence actions stop gating
for sql in ("SELECT fractal_ledger_flush();",
            "SELECT fractal_ledger_load();",
            "SELECT fractal_ledger_truth_count();",
            "SELECT fractal_ledger_shadow_count();"):
    try:
        con.execute(sql)
    except Exception as e:
        raise AssertionError(f"{sql} gated despite the core: {e}")

# in-process churn: collapse/diversify/explain keep answering across
# cursor threads (duckdb allows separate connections to one file only
# within one process, so the soak is cursors, not processes)
base = con
def churn(w):
    c = base.cursor()
    for _ in range(100):
        c.execute("SELECT fractal_detect_collapse();").fetchone()
    c.close()
with cf.ThreadPoolExecutor(max_workers=4) as ex:
    list(ex.map(churn, range(4)))

v = con.execute("SELECT fractal_ledger_verify();").fetchone()[0]
assert verified(v), f"verify broke after churn: {v!r}"
print("gate-25-ok")
# The extension's own contract: "Call [fractal_release()] as the last
# statement of a session that is about to close a file database." It closes
# the connections the extension holds open for nested queries and joins its
# host-departure monitor thread, which otherwise keeps polling the database
# while the host tears it down -- a race that kills the host at exit with a
# hard crash. Best effort: the driver has already reported its result.
try:
    con.execute("SELECT fractal_release();").fetchall()
except Exception:
    pass
PYEOF
  local r rc
  r=$(FSQL_TEST_ENTERPRISE_LIB="$ent25" py_run "$PDIR/gate25.py"); rc=$?
  expect_ok "$rc" "$r" "enterprise core absorbed the in-process churn (verify contract intact)" "gate-25-ok"
}

gate_26() {
  local r rc
  # with NO lib configured: the clean dormant-tier message
  r=$(sqlq "SELECT fractal_ledger_load();"); rc=$?
  expect_err "requires the FractalSQL Enterprise tier" "$rc" "$r" "unconfigured FRACTALSQL_ENTERPRISE_LIB reports the clean dormant-tier message"
  # with a configured-but-unloadable lib: the loader detail surfaces too
  r=$(sqlq_env "FRACTALSQL_ENTERPRISE_LIB=$BTROOTW/fractalsql_bt_nonexistent_enterprise$PLUGSUF" "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0" \
      -- "SELECT fractal_ledger_reset_soft();")
  rc=$?
  expect_err "could not load enterprise library" "$rc" "$r" "configured-but-unloadable lib surfaces the loader detail"
  # signature check ordering/refusals are covered by gate 32
}

gate_27() {
  if ! have_plugin think_reasoning_plugin; then
    skip "think_reasoning fixture did not compile"
    return
  fi
  local r rc kv
  local thinkenv=("FRACTALSQL_REASONING_PLUGIN=$(pj think_reasoning_plugin)" \
                  "FSQL_REASONING_HTTP_THINK=medium" \
                  "FSQL_REASONING_HTTP_THINK_PROVIDER=local_http" \
                  "FSQL_REASONING_HTTP_NATIVE_URL=https://think.invalid/internal" \
                  "FSQL_REASONING_HTTP_NUM_CTX=4096")
  # CHAT forwards all four THINK keys into the GENERATE dispatch
  rm -f "${THINKDUMP:?think dump contract}"
  r=$(sqlq_env "${thinkenv[@]}" -- "SELECT fractal_reason('q');"); rc=$?
  expect_ok "$rc" "$r" "chat dispatch ran through the think fixture" "OK"
  kv="$(cat "$THINKDUMP" 2>/dev/null || printf 'MISSING')"
  if printf '%s\n' "$kv" | grep -qF "THINK=medium" \
     && printf '%s\n' "$kv" | grep -qF "THINK_PROVIDER=local_http" \
     && printf '%s\n' "$kv" | grep -qF "NATIVE_URL=https://think.invalid/internal" \
     && printf '%s\n' "$kv" | grep -qF "NUM_CTX=4096"; then
    pass "all four THINK keys forwarded through the CHAT tier"
  else
    fail "THINK keys dropped on the CHAT path"
    printf '      dump: %s\n' "$kv"
  fi
  # T2S's GENERATE passes them through too (RESPONSE_MODE is forced to
  # code at tier load; the think keys are untouched). The canned "OK"
  # response fails the SQL parse ladder on purpose -- the dispatch
  # itself must survive it.
  printf 'SELECT 1\n' > "$SQLTXT"
  rm -f "$THINKDUMP"
  r=$(sqlq_env "${thinkenv[@]}" -- "SELECT fractal_text_to_sql('q');"); rc=$?
  kv="$(cat "$THINKDUMP" 2>/dev/null || printf 'MISSING')"
  if printf '%s\n' "$kv" | grep -qF "THINK=medium" \
     && printf '%s\n' "$kv" | grep -qF "NUM_CTX=4096"; then
    pass "THINK keys forwarded through the T2S GENERATE path"
  else
    fail "THINK keys dropped on the T2S path"
    printf '      dump: %.900s\n' "$kv"
  fi
  expect_survive "$rc" "$r" "T2S call survived the canned non-SQL response"
  # EMBED must NOT see any of them
  rm -f "$THINKDUMP"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj think_reasoning_plugin)" \
      "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings" \
      "FSQL_REASONING_HTTP_THINK=medium" \
      "FSQL_REASONING_HTTP_THINK_PROVIDER=local_http" \
      "FSQL_REASONING_HTTP_NATIVE_URL=https://think.invalid/internal" \
      "FSQL_REASONING_HTTP_NUM_CTX=4096" \
      -- "SELECT fractal_embed('x');")
  rc=$?
  expect_err "non-numeric-array" "$rc" "$r" "embed dispatch ran (think fixture's non-vector response refused)"
  kv="$(cat "$THINKDUMP" 2>/dev/null || printf 'MISSING')"
  if printf '%s\n' "$kv" | grep -qF "THINK=(unset)" \
     && printf '%s\n' "$kv" | grep -qF "THINK_PROVIDER=(unset)" \
     && printf '%s\n' "$kv" | grep -qF "NATIVE_URL=(unset)" \
     && printf '%s\n' "$kv" | grep -qF "NUM_CTX=(unset)"; then
    pass "no THINK key leaked into the EMBED tier context"
  else
    fail "THINK keys leaked into the EMBED tier context"
    printf '      dump: %s\n' "$kv"
  fi
}

gate_28() {
  local r rc dump
  printf 'SELECT 1\n' > "$SQLTXT"
  # 1: T2S's GENERATE runs under the hard-forced code mode...
  rm -f "${REVIEWDUMP:?review dump contract}"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj mock_reasoning_plugin)" -- "SELECT fractal_text_to_sql('q');")
  rc=$?
  expect_ok "$rc" "$r" "T2S GENERATE returned the canned SQL un-fenced" "SELECT 1"
  dump="$(cat "$REVIEWDUMP" 2>/dev/null || printf 'MISSING')"
  if printf '%s\n' "$dump" | grep -qF "RESPONSE_MODE=code"; then
    pass "T2S's lazy reasoning ctx loaded under RESPONSE_MODE=code"
  else
    fail "T2S dispatch did not run under the forced code mode"
    printf '      dump: %s\n' "$dump"
  fi
  # 2: ...and a CHAT call in the same process must not inherit it: one
  # CLI invocation = one duckdb process = one set of lazy tier contexts
  rm -f "$REVIEWDUMP"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj mock_reasoning_plugin)" -- \
      "SELECT fractal_reason('chat one');" \
      "SELECT fractal_text_to_sql('q');" \
      "SELECT fractal_reason('chat two');")
  rc=$?
  expect_ok "$rc" "$r" "chat calls interleave cleanly with the T2S call in-process"
  dump="$(cat "$REVIEWDUMP" 2>/dev/null || printf 'MISSING')"
  # the fixture is one dlopen-cached module, so the init-captured line
  # holds the last tier's re-init value (t2s's "code"); the chat tier's
  # own isolation shows up in the LIVE line read at this dispatch
  if printf '%s\n' "$dump" | grep -qF "LIVE_RESPONSE_MODE=(unset)"; then
    pass "the CHAT tier ctx kept the boot-cured (unset) RESPONSE_MODE"
  else
    fail "CHAT tier inherited the T2S-forced code mode"
    printf '      dump: %s\n' "$dump"
  fi
  # 3: the critique round dispatches on its OWN tier, whose response
  # mode is unset: the T2S tier's forced "code" mode must not leak into
  # it (a fenced verdict would hide the leading PASS/FAIL).
  rm -f "$REVIEWDUMP" "$REVIEWTXT"
  printf 'SELECT 1' > "$SQLTXT"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj mock_reasoning_plugin)" \
        "FRACTALSQL_TEXT_TO_SQL_USE_REVIEW=on" -- "SELECT fractal_text_to_sql('q');")
  rc=$?
  dump="$(cat "$REVIEWDUMP" 2>/dev/null || printf 'MISSING')"
  if printf '%s\n' "$dump" | grep -qF "LIVE_RESPONSE_MODE=(unset)"; then
    pass "the REVIEW tier dispatched with RESPONSE_MODE unset"
  else
    fail "REVIEW tier inherited the T2S-forced code mode"
    printf '      dump: %s\n' "$dump"
  fi
  # 4: the endpoints stay apart as well. The embedding tier points the
  # extension's own configuration at the embeddings endpoint before it
  # loads, so a chat tier that loads afterwards has to be given the chat
  # endpoint again -- otherwise the chat call is dispatched to the
  # embeddings endpoint and fails.
  rm -f "$REVIEWDUMP"
  printf 'chat-endpoint-canary\n' > "$SQLTXT"
  r=$(sqlq_env "FRACTALSQL_REASONING_PLUGIN=$(pj mock_reasoning_plugin)" \
        "FSQL_REASONING_HTTP_URL=https://chat.invalid/v1/chat/completions" \
        "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings" \
        -- "SELECT len(fractal_embed('hello'));" \
        "SELECT fractal_reason('chat after embed');")
  rc=$?
  expect_ok "$rc" "$r" "an embedding dispatch and a chat dispatch run in one process" "chat-endpoint-canary"
  dump="$(cat "$REVIEWDUMP" 2>/dev/null || printf 'MISSING')"
  if printf '%s\n' "$dump" | grep -qF "URL=https://chat.invalid/v1/chat/completions"; then
    pass "the CHAT tier reached the chat endpoint after the embedding tier loaded"
  else
    fail "the CHAT tier was pointed at the embeddings endpoint"
    printf '      dump: %s\n' "$dump"
  fi
}
gate_29() {
  local r rc s100
  printf 'domain-agent-canary\n' > "$SQLTXT"
  # the domain agents read the reasoning plugin from the environment;
  # route every
  # LLM-composed subtest through sqlq_env
  local MOCKENV="FRACTALSQL_REASONING_PLUGIN=$(pj mock_reasoning_plugin)"
  r=$(sqlq "CREATE TABLE bt_da_logs(host VARCHAR, metric DOUBLE, ts INTEGER);" \
            "INSERT INTO bt_da_logs " \
            "SELECT CASE WHEN i % 4 = 3 THEN 'host-2' ELSE 'host-1' END, " \
            "       10.0 + sin(i * 0.2) * 2.0 + i * 0.05, " \
            "       i FROM generate_series(1, 96) AS g(i);")
  rc=$?
  expect_ok "$rc" "$r" "anomaly fixture staged (96 rows, drifting metric)"
  # anomaly_triage: table + drift + reasoning (the summary carries the
  # canned canary because the reasoning ctx rides the mock plugin)
  r=$(sqlq_env "$MOCKENV" -- "SELECT fractal_agent_anomaly_triage('bt_da_logs','metric','ts','host','host-1',32);"); rc=$?
  if [ "$rc" -eq 0 ] \
     && printf '%s\n' "$r" | grep -qF "anomaly_type" \
     && printf '%s\n' "$r" | grep -qF "vector_drift" \
     && printf '%s\n' "$r" | grep -qF "domain-agent-canary"; then
    pass "anomaly_triage composed drift + reasoning (triage_summary carries the canary)"
  else
    fail "anomaly_triage composition"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
  fi
  r=$(sqlq "SELECT fractal_agent_anomaly_triage('bt_da_logs','metric','ts','host','no-such-host',32);"); rc=$?
  expect_err "fractal_agent_anomaly_triage: no rows in bt_da_logs.metric" "$rc" "$r" "empty series reported by table.column"
  # recall_hybrid: pure retrieval with a cohort filter, no LLM in the loop
  r=$(sqlq "CREATE TABLE bt_da_mem(id INTEGER, kind VARCHAR, body VARCHAR, emb DOUBLE[]);" \
            "INSERT INTO bt_da_mem VALUES " \
            " (1, 'a', 'first memory', [1.0, 0.0, 0.0, 0.0])," \
            " (2, 'b', 'second memory', [0.0, 0.0, 0.0, 1.0])," \
            " (3, 'a', 'third memory', [0.9, 0.1, 0.0, 0.0]);")
  r=$(sqlq "SELECT fractal_agent_recall_hybrid('bt_da_mem','emb',[1.0, 0.0, 0.0, 0.0]::DOUBLE[],'kind','a',5,'id','body');")
  rc=$?
  if [ "$rc" -eq 0 ] \
     && printf '%s\n' "$r" | grep -qF "mem_id" \
     && printf '%s\n' "$r" | grep -qF "first memory" \
     && ! printf '%s\n' "$r" | grep -qF "second memory"; then
    pass "recall_hybrid honored the kind='a' cohort filter"
  else
    fail "recall_hybrid cohort filter"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
  fi
  r=$(sqlq "SELECT fractal_agent_recall_hybrid('bt_da_mem','emb',[1.0, 0.0, 0.0, 0.0]::DOUBLE[],'kind','zzz',5,'id','body');")
  rc=$?
  expect_err "filter matched no rows in" "$rc" "$r" "empty recall filter reported distinctly"
  # regime_triage: array in, dfa/drift + reasoning out
  s100="$(awk 'BEGIN{s=0; for(i=0;i<100;i++){s+=0.5; printf "%s%.3f", (i?",":""), s}}')"
  r=$(sqlq_env "$MOCKENV" -- "SELECT fractal_agent_regime_triage([$s100]::DOUBLE[], 64, 0.5);"); rc=$?
  if [ "$rc" -eq 0 ] \
     && printf '%s\n' "$r" | grep -qF "dfa_exponent" \
     && printf '%s\n' "$r" | grep -qF "drift_detected" \
     && printf '%s\n' "$r" | grep -qF "domain-agent-canary"; then
    pass "regime_triage composed dfa + drift + reasoning (rationale carries the canary)"
  else
    fail "regime_triage composition"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
  fi
  # outlier_intercept: the metric arg is part of the contract
  r=$(sqlq "CREATE TABLE bt_da_badstates(kind VARCHAR, state_vec DOUBLE[]);" \
            "INSERT INTO bt_da_badstates VALUES " \
            " ('ok', [1.0, 0.0, 0.0, 0.0]), ('bad', [0.0, 1.0, 0.0, 0.0]), ('ok', [0.9, 0.1, 0.0, 0.0]);")
  r=$(sqlq_env "$MOCKENV" -- "SELECT fractal_agent_outlier_intercept([1.0, 0.0, 0.0, 0.0]::DOUBLE[],'bt_da_badstates','state_vec',0.5,'cosine');")
  rc=$?
  if [ "$rc" -eq 0 ] \
     && printf '%s\n' "$r" | grep -qF "intercepted" \
     && printf '%s\n' "$r" | grep -qF "cosine"; then
    pass "outlier_intercept runs under the cosine metric"
  else
    fail "outlier_intercept (cosine)"
    printf '      got rc=%d: %.900s\n' "$rc" "$r"
  fi
  r=$(sqlq "SELECT fractal_agent_outlier_intercept([1.0, 0.0, 0.0, 0.0]::DOUBLE[],'bt_da_badstates','state_vec',0.5,'minkowski');")
  rc=$?
  expect_err "metric must be 'cosine' or 'l2'" "$rc" "$r" "outlier_intercept rejects unknown metrics"
  # an empty history table has nothing to intercept
  r=$(sqlq "CREATE TABLE bt_da_nobad(kind VARCHAR, state_vec DOUBLE[]);")
  r=$(sqlq "SELECT fractal_agent_outlier_intercept([1.0, 0.0, 0.0, 0.0]::DOUBLE[],'bt_da_nobad','state_vec',1.0,'l2');")
  rc=$?
  expect_err "no bad-state rows in bt_da_nobad" "$rc" "$r" "empty history table reports the no-bad-state condition"
}

gate_30() {
  # the feature-store surface is exercised by gate 66
  skip "feature store: see gate 66"
}

gate_31() {
  local r rc
  r=$(sqlq "SELECT fractal_ledger_verify();"); rc=$?
  expect_ok "$rc" "$r" "verify() runs with NO enterprise lib and holds the exact contract" '{"ok":true,"rows_verified":0}'
  # the persistence/truth surface stays behind the enterprise gate
  local fn
  for fn in fractal_ledger_flush fractal_ledger_load fractal_ledger_compact \
            fractal_ledger_reset_soft fractal_ledger_reset_hard \
            fractal_ledger_truth_count fractal_ledger_shadow_count; do
    r=$(sqlq "SELECT $fn();"); rc=$?
    expect_err "requires the FractalSQL Enterprise tier" "$rc" "$r" "$fn reports the dormant enterprise tier"
  done
  r=$(sqlq "SELECT fractal_audit_log('bt-entry', '{}');"); rc=$?
  expect_err "requires the FractalSQL Enterprise tier" "$rc" "$r" "audit_log reports the dormant enterprise tier"
  # the community ledger surface answers with no enterprise lib at all
  r=$(sqlq "SELECT fractal_diversify_enable();"); rc=$?
  expect_ok "$rc" "$r" "diversify_enable answers community-side" "true"
  r=$(sqlq "SELECT fractal_diversify_disable();"); rc=$?
  expect_ok "$rc" "$r" "diversify_disable answers community-side" "false"
  # the ledger
  # reads its OWN fsql ctx, which a fresh CLI process has never run a
  # search through, so the
  # score legitimately reads NaN through the CLI
  r=$(sqlq "SELECT fractal_detect_collapse();")
  rc=$?
  expect_ok "$rc" "$r" "detect_collapse answers community-side" "nan"
  r=$(sqlq "SELECT fractal_explain_result();"); rc=$?
  expect_ok "$rc" "$r" "explain_result answers community-side" '"dq"'
}

gate_32() {
  # Ed25519 detached-signature verification of the enterprise library
  # (src/fsql_ed25519.h + src/fsql_enterprise.c).
  #  A  verifier primitive: RFC 8032 vectors + accept/tamper/wrong-key
  #  B  no .sig, no opt-out          -> refused before dlopen
  #  C  garbage / wrong-size .sig    -> refused even WITH the opt-out
  #  D  no .sig + opt-out            -> signature step passes, the
  #                                     loader error surfaces instead
  local cc_bin="${CC:-cc}" r rc
  if command -v "$cc_bin" >/dev/null 2>&1 \
     && "$cc_bin" -std=c11 -O1 -Isrc tests/ed25519_probe.c -o "$PDIR/ed25519_probe" >"$PDIR/ed25519_probe.log" 2>&1 \
     && "$PDIR/ed25519_probe" >>"$PDIR/ed25519_probe.log" 2>&1; then
    pass "32 ed25519 primitive: RFC 8032 vectors + tamper/wrong-key/corrupt-sig rejected"
  else
    fail "32 ed25519 primitive: probe failed (see $PDIR/ed25519_probe.log)"
  fi
  local lib="$PDIR/fsql_bt_sigtest_enterprise$PLUGSUF" libw="$BTROOTW/fsql_bt_sigtest_enterprise$PLUGSUF"
  [ -n "${PDIRW:-}" ] && libw="$PDIRW/fsql_bt_sigtest_enterprise$PLUGSUF"
  printf 'not a real enterprise core' > "$lib"
  rm -f "$lib.sig"
  r=$(sqlq_env "FRACTALSQL_ENTERPRISE_LIB=$libw" -- "SELECT fractal_ledger_reset_soft();"); rc=$?
  expect_err "no signature found for enterprise library" "$rc" "$r" "32 missing .sig without opt-out is refused"
  head -c 64 /dev/zero > "$lib.sig"
  r=$(sqlq_env "FRACTALSQL_ENTERPRISE_LIB=$libw" "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0" -- "SELECT fractal_ledger_reset_soft();"); rc=$?
  expect_err "failed signature verification" "$rc" "$r" "32 invalid 64-byte .sig is refused even with the opt-out"
  head -c 63 /dev/zero > "$lib.sig"
  r=$(sqlq_env "FRACTALSQL_ENTERPRISE_LIB=$libw" "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0" -- "SELECT fractal_ledger_reset_soft();"); rc=$?
  expect_err "failed signature verification" "$rc" "$r" "32 wrong-size .sig is refused even with the opt-out"
  rm -f "$lib.sig"
  r=$(sqlq_env "FRACTALSQL_ENTERPRISE_LIB=$libw" "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0" -- "SELECT fractal_ledger_reset_soft();"); rc=$?
  expect_err "could not load enterprise library" "$rc" "$r" "32 opt-out lets a .sig-less file reach the loader"
  rm -f "$lib"
}

gate_33() {
  # The extension's own ThreadSanitizer run is gate 51 (the `thread` cell of test/lifecycle_run.sh): the extension and
  # the test host are built with -fsanitize=thread and loaded into the stock libduckdb, and a report counts when one
  # of its racing accesses is in the extension's code. --tsan, below, is the other half: it builds the MCP server
  # (the other multi-threaded part of this repo) with -fsanitize=thread and runs gates 35-40 against it.
  skip "33 tsan_ledger_concurrent (the extension's TSan run is gate 51's thread cell; --tsan covers the MCP server)"
}

# The environment the vertical kits run under: the mock reasoning
# plugin, plus an embedding endpoint so the embed tier is reachable
# and the embed-coupled kits can run.
#
# The embed tier needs an endpoint configured (the extension refuses
# the tier outright when FSQL_REASONING_HTTP_EMBED_URL is unset) and
# the mock plugin answers the embedding dispatch with a deterministic
# vector of FSQL_MOCK_EMBED_DIM floats. 768 is the width the two
# embed-coupled kits (agentic-ops-devops, agentic-fintech-mcts)
# declare their column as.
kit_env() {
  printf '%s\n%s\n%s\n%s\n' \
    "FRACTALSQL_REASONING_PLUGIN=$MOCK" \
    "FSQL_REASONING_HTTP_EMBED_URL=https://mock.invalid/v1/embeddings" \
    "FSQL_REASONING_HTTP_EMBED_MODEL=mock-embed" \
    "FSQL_MOCK_EMBED_DIM=768"
}

# Runs one vertical demo kit and prints the CLI's raw output.
#
# The kit's SQL is prefixed with the extension LOAD and spooled through
# a temp file; the run happens in its own scratch directory, because
# the kits spool their own output files and would otherwise litter
# the harness's working directory.
run_vertical_kit() {
  local k="$1"
  local f="$HERE/demo/demo-vertical-$k.sql"
  if [ ! -f "$f" ]; then
    die "kit file missing: $f"
  fi
  local kf kdir
  kf="$(mktemp "${TMPDIR:-/tmp}/fsql_kit_XXXXXX.sql")"
  kdir="$(mktemp -d "${TMPDIR:-/tmp}/fsql_kitdir_XXXXXX")"
  { printf "LOAD '%s';\n" "$EXTW"; cat "$f"; } > "$kf"
  local out
  out="$(cd "$kdir" && env $(kit_env | tr '\n' ' ') "$DUCKDB" -batch -list -noheader -unsigned \
            -separator '|' < "$kf" 2>&1)"
  rm -f "$kf"
  rm -rf "$kdir"
  printf '%s\n' "$out"
}

gate_34() {
  # The starter kits: each demo/demo-vertical-*.sql runs start to finish in a
  # fresh in-memory database against the mock reasoning plugin, raising no
  # SQL error (the scenario-planning kit's plan_explore step needs an
  # embedding endpoint, so it is allowed exactly one), printing no NaN, and
  # reproducing its headline result.
  local kits="ev-battery-lifecycle adas-safety-validation v2x-warranty-triage
    critical-inventory-routing heavy-industry-predictive-maintenance
    climatech-grid-balancing hazmat-occupational-triage
    scenario-planning-simulation avionics-fault-prediction
    satellite-constellation-coverage telecom-account-anomaly-screening
    telecom-traffic-routing climatech-emissions-monitoring
    climatech-risk-exposure rf-spectrum-sensing
    event-stream-anomaly-triage outlier-interception-footprint agentic-budget-reallocation
    stalled-process-triage intent-matching-discovery
    agentic-next-action-ranking document-risk-drift
    coordinated-record-detection sensor-telemetry-allocation simulated-economy-drift
    multi-series-replenishment periodicity-portfolio-selection
    agentic-recall-recommendation spatial-footprint-portfolio-risk
    agentic-customer-support agentic-edge-swarm agentic-fintech-mcts agentic-ops-devops
    biotech-genomics cybersecurity-threat-detection fleet-logistics maritime-defense
    medtech-clinical quant-finance recommendation-search smart-cities-iot sovereign-edge-ai"
  local k f out nerr maxerr ok
  for k in $kits; do
    f="$HERE/demo/demo-vertical-$k.sql"
    if [ ! -f "$f" ]; then
      fail "$k: $f is missing"; continue
    fi
    out="$(run_vertical_kit "$k")"
    nerr=$(printf '%s\n' "$out" | grep -cE '^[A-Za-z ]*Error:')
    maxerr=0; [ "$k" = scenario-planning-simulation ] && maxerr=1; [ "$k" = periodicity-portfolio-selection ] && maxerr=1
    if [ "$nerr" -gt "$maxerr" ]; then
      fail "$k raised $nerr SQL error(s), at most $maxerr expected"
      printf '      %s\n' "$(printf '%s\n' "$out" | grep -E '^[A-Za-z ]*Error:' | head -2)"
      continue
    fi
    if printf '%s\n' "$out" | grep -qE '(^|\|)-?([Nn]a[Nn]|[Ii]nf|Infinity)(\||$)'; then
      fail "$k printed a NaN/inf cell"; continue
    fi
    ok=0
    case "$k" in
      ev-battery-lifecycle) printf '%s\n' "$out" | awk -F'|' '$1=="EV-203" && $2+0>0.5 && $3+0>1.5 {a=1} $1=="EV-101" && $2+0<0 && $3+0<1 {b=1} END{exit !(a&&b)}' && ok=1 ;;
      adas-safety-validation) printf '%s\n' "$out" | awk -F'|' '$1 ~ /^P1 firm/ && $4=="true" {a=1} $1 ~ /^P2 steady/ && $4=="false" {b=1} $1 ~ /^P3 gentle/ && $4=="true" {c=1} END{exit !(a&&b&&c)}' && ok=1 ;;
      v2x-warranty-triage) printf '%s\n' "$out" | grep -q '^battery-thermal-service|0\.99' && ok=1 ;;
      critical-inventory-routing) printf '%s\n' "$out" | awk -F'|' '$1==4 && $2=="west" && $5+0>1.2 {a=1} END{exit !a}' && ok=1 ;;
      heavy-industry-predictive-maintenance) printf '%s\n' "$out" | awk -F'|' '$1=="PUMP-07" && $2+0>0.5 && $3+0>1.5 {a=1} $1=="PUMP-03" && $2+0<0 {b=1} END{exit !(a&&b)}' && ok=1 ;;
      climatech-grid-balancing) printf '%s\n' "$out" | awk -F'|' '$1=="AREA-C" && $2+0>0.5 && $3+0>1.2 {a=1} $1=="AREA-A" && $2+0<0 {b=1} END{exit !(a&&b)}' && ok=1 ;;
      hazmat-occupational-triage) printf '%s\n' "$out" | awk -F'|' '($1==7||$1==15||$1==31) && $2=="reactor-bay" && $3=="night" && $4+0<0.001 {n++} END{exit !(n>=3)}' && ok=1 ;;
      scenario-planning-simulation) [ "$(printf '%s\n' "$out" | grep -c 'variant')" -ge 6 ] && ok=1 ;;
      avionics-fault-prediction) printf '%s\n' "$out" | grep -q '^AC-09|0\.2' && ok=1 ;;
      satellite-constellation-coverage) printf '%s\n' "$out" | awk -F'|' '$1=="healthy" && NF==3 {h=$3+0} $1=="degraded" && NF==3 {d=$3+0} END{exit !(h>0 && d>h)}' && ok=1 ;;
      telecom-account-anomaly-screening) printf '%s\n' "$out" | awk -F'|' '$1 ~ /^E1 swap/ && $4=="true" {a=1} $1 ~ /^E2 routine/ && $4=="false" {b=1} $1 ~ /^E4 faint/ && $4=="true" {c=1} END{exit !(a&&b&&c)}' && ok=1 ;;
      telecom-traffic-routing) printf '%s\n' "$out" | grep -q '^R3 mobile handover burst|edge-mobile-hub|' && printf '%s\n' "$out" | grep -q '^R3 mobile handover burst|edge-backup-west$' && ok=1 ;;
      climatech-emissions-monitoring) printf '%s\n' "$out" | awk -F'|' '$1=="CH4-02" && $2+0>0.5 && $3+0>1.5 {a=1} $1=="CH4-01" && $2+0<0 {b=1} END{exit !(a&&b)}' && ok=1 ;;
      climatech-risk-exposure) printf '%s\n' "$out" | awk -F'|' '$1=="dry season" && NF==3 {a=1} $1=="wet season" && NF==3 {b=1} END{exit !(a&&b)}' && ok=1 ;;
      rf-spectrum-sensing) printf '%s\n' "$out" | grep -q '^CH-A|\[9\]$' && printf '%s\n' "$out" | grep -q '^CH-B|\[\]$' && printf '%s\n' "$out" | grep -q '^CH-C|\[\]$' && ok=1 ;;
      # The remaining kits carry the same HEADLINE marker convention
      # ("HEADLINE kit=<name> ok", computed from the kit's own results)
      # and the gate greps for it.
      *) printf '%s\n' "$out" | grep -q "HEADLINE kit=$k ok" && ok=1 ;;
    esac
    if [ "$ok" -eq 1 ]; then
      pass "demo-vertical-$k.sql runs clean and reproduces its headline result"
    else
      fail "demo-vertical-$k.sql did not reproduce its headline result"
    fi
  done
}

# 53 capi_edge: the edge-input matrix, default environment (see test/edge_inputs.py). Runs the uninstrumented release band; the
# sanitizer runs of the parity corpus are gate 48's. The matrix under other process environments (FSQL_AUDIT_REDACT, the mock
# enterprise variants, ...) is part of the coverage run.
gate_53() {
  if [ ! -f "$HERE/test/edge_inputs.py" ]; then skip "53 capi_edge (no test/edge_inputs.py)"; return; fi
  if ! command -v python3 >/dev/null 2>&1; then skip "53 capi_edge (needs python3)"; return; fi
  if ! ls "$HERE"/dist/*/fractalsql.capi.*.duckdb_extension >/dev/null 2>&1; then
    if ! nice make -C "$HERE" -s >/dev/null 2>&1; then fail "53 capi_edge: the extension did not build"; return; fi
  fi
  local out rc n bad
  out="$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS nice python3 -I "$HERE/test/edge_inputs.py" 2>&1)"; rc=$?
  n="$(grep -oE '[0-9]+ statements' <<< "$out" | tail -1 | grep -oE '^[0-9]+')"
  bad="$(grep -oE '[0-9]+ function sweep' <<< "$out" | tail -1 | grep -oE '^[0-9]+')"
  if [ "$rc" -eq 0 ] && [ "${bad:-1}" = 0 ] && [ "${n:-0}" -gt 0 ]; then
    pass "53 capi_edge: $n awkward-argument statements across every registered function: no crash, no INTERNAL error"
  else
    grep -E 'FAIL|crash|INTERNAL' <<< "$out" | head -10 | sed 's/^/    /' >&2
    fail "53 capi_edge: ${bad:-?} function sweep(s) with a crash or INTERNAL error (run test/edge_inputs.py)"
  fi
}

# 54 error_table: test/error_table.py, a table of calls with the exact outcome each must produce.
gate_54() {
  if [ ! -f "$HERE/test/error_table.py" ]; then skip "54 error_table (no test/error_table.py)"; return; fi
  if ! command -v python3 >/dev/null 2>&1; then skip "54 error_table (needs python3)"; return; fi
  if ! ls "$HERE"/dist/*/fractalsql.capi.*.duckdb_extension >/dev/null 2>&1; then
    if ! nice make -C "$HERE" -s >/dev/null 2>&1; then fail "54 error_table: the extension did not build"; return; fi
  fi
  local out rc line
  out="$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS nice python3 -I "$HERE/test/error_table.py" 2>&1)"; rc=$?
  line="$(grep -E '^error table: ' <<< "$out" | tail -1)"
  if [ "$rc" -eq 0 ] && [ -n "$line" ]; then
    pass "54 error_table: ${line#error table: }"
  else
    grep -E '^  FAIL|^       expected' <<< "$out" | head -20 | sed 's/^/    /' >&2
    fail "54 error_table: ${line:-the table did not finish} (run test/error_table.py)"
  fi
}

# 55 ledger_integrity: test/ledger_run.sh (the store and verifier, forged and damaged chains; sanitized under --asan/--ubsan) and
# test/ledger_sql.py (the ledger through SQL with the mock enterprise core).
gate_55() {
  if [ ! -x "$HERE/test/ledger_run.sh" ]; then skip "55 ledger_integrity (no test/ledger_run.sh)"; return; fi
  if ! command -v cc >/dev/null 2>&1; then skip "55 ledger_integrity (needs a C compiler)"; return; fi
  if ! command -v python3 >/dev/null 2>&1; then skip "55 ledger_integrity (needs python3)"; return; fi
  if ! ls "$HERE"/dist/*/fractalsql.capi.*.duckdb_extension >/dev/null 2>&1; then
    if ! nice make -C "$HERE" -s >/dev/null 2>&1; then fail "55 ledger_integrity: the extension did not build"; return; fi
  fi
  local san="" out rc sout src np
  [ "$SAN_MODE" = asan ] && san="address"; [ "$SAN_MODE" = ubsan ] && san="undefined"
  out="$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS SAN="$san" nice "$HERE/test/ledger_run.sh" 2>&1)"; rc=$?
  np="$(grep -c '^  PASS ' <<< "$out")"
  if [ "$rc" -eq 0 ] && [ "$np" -ge 5 ]; then pass "55 ledger store: forged/damaged chains, size cap, anchor log, allocation failure ($np runs${san:+, under $san})"
  else grep -E '^  FAIL' <<< "$out" | head -8 | sed 's/^/    /' >&2; fail "55 ledger store: failures (run test/ledger_run.sh)"; fi
  sout="$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS nice python3 -I "$HERE/test/ledger_sql.py" 2>&1)"; src=$?
  if [ "$src" -eq 0 ]; then pass "55 ledger sql: $(grep -E '^ledger sql: ' <<< "$sout" | tail -1 | sed 's/^ledger sql: //')"
  else grep -E '^  FAIL' <<< "$sout" | head -8 | sed 's/^/    /' >&2; fail "55 ledger sql: failures (run test/ledger_sql.py)"; fi
}

# 56 capi_oom / 57 capi_oom_full: the allocation-failure sweep (test/oom_sweep.py). 56 is a sampled run that fits a default gate set;
# 57 (--fault) is the full-depth sweep. Linux only; a sanitizer runtime and the fault shim cannot both interpose the allocator.
# Waits (up to FSQL_LOAD_WAIT s, default 300) for the 1-minute load average to fall under FSQL_LOAD_MAX (default 1.5 x CPUs, min 2)
# before the next gate starts, so one gate's leftover load is not stacked under the next. Linux only; a no-op elsewhere.
load_guard() {
  [ -r /proc/loadavg ] || return 0
  local n max wait="${FSQL_LOAD_WAIT:-300}" t0 la
  n="$(nproc 2>/dev/null || echo 1)"
  max="${FSQL_LOAD_MAX:-$(awk -v n="$n" 'BEGIN{m=n*1.5; if(m<2)m=2; print m}')}"
  t0=$SECONDS
  while la="$(cut -d' ' -f1 /proc/loadavg)"; awk -v a="$la" -v m="$max" 'BEGIN{exit !(a+0>m+0)}'; do
    [ $((SECONDS - t0)) -ge "$wait" ] && { printf '  (load %s still above %s after %ss; going on)\n' "$la" "$max" "$wait"; return 0; }
    sleep 5
  done
}
oom_gate() {   # oom_gate NUM LABEL ENV...
  local num="$1" label="$2"; shift 2
  if [ ! -f "$HERE/test/oom_sweep.py" ]; then skip "$num $label (no test/oom_sweep.py)"; return; fi
  if [ "$(uname -s)" != Linux ]; then skip "$num $label (Linux only: it interposes the allocator with LD_PRELOAD)"; return; fi
  if [ -n "$SAN_MODE" ]; then skip "$num $label (a sanitizer runtime and the fault shim cannot both interpose the allocator)"; return; fi
  if ! command -v cc >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then skip "$num $label (needs a C compiler and python3)"; return; fi
  if ! ls "$HERE"/dist/*/fractalsql.capi.*.duckdb_extension >/dev/null 2>&1; then
    if ! nice make -C "$HERE" -s >/dev/null 2>&1; then fail "$num $label: the extension did not build"; return; fi
  fi
  # Wall-clock cap (OOM_BUDGET_SECONDS; 0 = none). Every trial that kills the extension spawns a fresh CLI process, so an
  # uncapped full sweep on a shared-folder working copy can wedge the guest in uninterruptible I/O. timeout signals the whole
  # process group, so the CLI children go with the sweep. A capped sweep reports "did not finish" and fails, never a false pass.
  local out rc line probs tmo="" budget="${OOM_BUDGET_SECONDS:-}"
  [ -z "$budget" ] && { [ "$num" = 57 ] && budget=600 || budget=0; }
  if [ "$budget" != 0 ]; then
    if command -v timeout >/dev/null 2>&1; then tmo="timeout --kill-after=10 $budget"
    elif [ -x /opt/homebrew/opt/coreutils/libexec/gnubin/timeout ]; then tmo="/opt/homebrew/opt/coreutils/libexec/gnubin/timeout --kill-after=10 $budget"; fi
  fi
  # Run against a tmp copy of the built extensions so no sweep process touches the shared working copy (same reason gate 54's
  # scratch is in tmp). CAPI_DIST is the harness's switch for the build under test. The sweep's band_file looks for the
  # band of $OOM_LINE in one directory, and a release tree keeps the bands apart: build.sh's dist/<arch>/ holds only the
  # per-DuckDB-version copies of the stable band, no `.capi` file, so the staging source is the newest directory that
  # actually holds what the sweep will load (the check above has built it for us when it was missing), not
  # dirname(resolve_ext), whose per-version name wins the resolver from the older Docker cell.
  local srcdist stage band oline="${OOM_LINE:-15}"
  local reserved='^dist/(asan|ubsan|san-[a-z]+|cov|unit|lifecycle|windows[^/]*)/'
  if [ "$oline" = 14 ]; then
    band="$(ls -1t "$HERE"/dist/*/fractalsql.v1.4.*.duckdb_extension 2>/dev/null | grep -vE "$reserved" | head -1 || true)"
  else
    band="$(ls -1t "$HERE"/dist/*/fractalsql.capi.*.duckdb_extension 2>/dev/null | grep -vE "$reserved" | head -1 || true)"
  fi
  if [ -n "$band" ]; then srcdist="$(dirname "$band")"; else srcdist="$(dirname "$(resolve_ext)")"; fi
  stage="$(mktemp -d "${TMPDIR:-/tmp}/fsql_oomdist_XXXXXX")" && cp "$srcdist"/*.duckdb_extension "$stage"/ || { fail "$num $label: could not stage the extension in tmp"; return; }
  out="$(env -u LD_PRELOAD CAPI_DIST="$stage" "$@" $tmo nice python3 -I "$HERE/test/oom_sweep.py" 2>&1)"; rc=$?
  rm -rf "$stage"
  line="$(grep -E '^oom sweep: ' <<< "$out" | tail -1)"
  probs="$(grep -oE '[0-9]+ problem' <<< "$line" | grep -oE '^[0-9]+')"
  if [ "$rc" -eq 0 ] && [ "${probs:-1}" = 0 ]; then pass "$num $label: ${line#oom sweep: }"
  else grep -E '^  FAIL|^       ' <<< "$out" | head -12 | sed 's/^/    /' >&2
    if [ "$rc" -ne 0 ] && [ "${probs:-1}" = 0 ]; then fail "$num $label: INCOMPLETE, stopped at the ${budget}s cap with 0 problems so far (raise OOM_BUDGET_SECONDS): ${line#oom sweep: }"
    else fail "$num $label: ${line:-the sweep did not finish}"; fi; fi
}
gate_56() { oom_gate 56 capi_oom OOM_MAX_TRIALS=12 OOM_SAMPLE=3 OOM_LOAD_STRIDE=3; }
gate_57() { oom_gate 57 capi_oom_full OOM_MAX_TRIALS=40 OOM_SAMPLE=1 OOM_LOAD_STRIDE=1; }

# ----------------------------------------------------------------
# Runner.
# ----------------------------------------------------------------


# --- the MCP server (mcp/): gates 35-38 ---------------------------------------
# A C++17 program that links libduckdb (DuckDB's C library) and loads the extension into its own process. It needs a
# libduckdb of the SAME DuckDB version the extension was built for: FSQL_LIBDUCKDB_DIR names a directory holding
# duckdb.h and libduckdb.so, or the matching release archive is fetched once into a cache.
MCP_EXE=""; MCP_LIBDIR=""; MCP_EXEC=""; MCP_SAN=""; MCP_PROBES_BUILT=0; MCP_WORK=""
# libduckdb is a C++ library, so ASan can see its operator new freed by free: that one check is off.
mcp_san_env() {
  printf '%s\n' "ASAN_OPTIONS=detect_leaks=0:halt_on_error=1:alloc_dealloc_mismatch=0" "UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1" \
                "TSAN_OPTIONS=halt_on_error=1:second_deadlock_stack=1:suppressions=$HERE/mcp/tests/tsan_mcp.supp:log_path=${MCP_WORK:-/tmp}/tsan"
}
# What the server and probes are compiled with, and the prefix they run under (TSan needs ASLR off on this kernel).
MCP_RUN=""
mcp_kind_flags() {
  MCP_SAN=""; MCP_RUN=""
  case "$MCP_KIND" in
    asan)  MCP_SAN="-fsanitize=address -fno-omit-frame-pointer -g" ;;
    ubsan) MCP_SAN="-fsanitize=undefined -fno-sanitize-recover=undefined -g" ;;
    tsan)  MCP_SAN="-fsanitize=thread -g"; MCP_RUN="setarch $(uname -m) -R" ;;
    cov)   MCP_SAN="--coverage -fprofile-update=atomic" ;;
  esac
}
# mcp_san_check LABEL OUTPUT: under a sanitizer, fails when the output carries a sanitizer report.
mcp_san_check() {
  [ -n "$MCP_KIND" ] && [ "$MCP_KIND" != cov ] || return 0
  if grep -q -E "ERROR: (Address|Leak|Undefined)Sanitizer|runtime error:|WARNING: ThreadSanitizer" <<< "$2"; then
    grep -E "ERROR: (Address|Leak|Undefined)Sanitizer|runtime error:|WARNING: ThreadSanitizer" <<< "$2" | head -3 >&2
    fail "$1: the sanitizer reported an error"; return 1
  fi
}
mcp_libduckdb() {
  [ -n "$MCP_LIBDIR" ] && return 0
  if [ -n "${FSQL_LIBDUCKDB_DIR:-}" ]; then
    [ -f "$FSQL_LIBDUCKDB_DIR/duckdb.h" ] && ls "$FSQL_LIBDUCKDB_DIR"/libduckdb.* >/dev/null 2>&1 \
      || { skip "mcp (FSQL_LIBDUCKDB_DIR=$FSQL_LIBDUCKDB_DIR has no duckdb.h and libduckdb)"; return 1; }
    MCP_LIBDIR="$(cd "$FSQL_LIBDUCKDB_DIR" && pwd)"; return 0
  fi
  local base ver arch
  base="$(basename "$EXT")"
  # The DuckDB version: the file name carries it for the 1.4 band and the per-version cells (fractalsql.v1.5.6.*), but
  # the stable-band file (fractalsql.capi.*) does not -- it loads on several versions. Then it is the version of the
  # DuckDB CLI under test, which is the one the extension is being loaded into anyway.
  ver="$(printf '%s' "$base" | sed -n 's/^fractalsql\.\(v[0-9][0-9.]*\)\..*/\1/p')"
  if [ -z "$ver" ] && [ -n "${DUCKDB:-}" ]; then
    ver="$("$DUCKDB" -noheader -list -c 'SELECT version()' 2>/dev/null | tr -d '\r' | tail -1)"
    case "$ver" in v[0-9]*) ;; *) ver="" ;; esac
  fi
  case "$base" in *linux_amd64*) arch=amd64 ;; *linux_arm64*|*linux_aarch64*) arch=arm64 ;; *) arch="" ;; esac
  if [ -z "$ver" ] || [ -z "$arch" ]; then
    skip "mcp (could not tell which DuckDB version to build the server against; set FSQL_LIBDUCKDB_DIR to a libduckdb release directory)"; return 1
  fi
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/fractalsql/libduckdb-$ver-$arch"
  # Offline first: a libduckdb.so next to the CLI is the same release as the CLI. It has no header beside it, but the
  # API headers for this version are vendored in the repository.
  if [ ! -f "$cache/duckdb.h" ] && [ -n "${DUCKDB:-}" ]; then
    local clidir hdr
    clidir="$(cd "$(dirname "$DUCKDB")" 2>/dev/null && pwd)"; hdr="$HERE/vendor/duckdb-$ver/duckdb.h"
    if [ -n "$clidir" ] && [ -f "$clidir/libduckdb.so" ] && [ -f "$hdr" ]; then
      mkdir -p "$cache" && cp "$hdr" "$cache/duckdb.h" && cp "$clidir/libduckdb.so" "$cache/libduckdb.so" || rm -rf "$cache"
    fi
  fi
  if [ ! -f "$cache/duckdb.h" ] && [ "${FSQL_FETCH_LIBDUCKDB:-1}" = 0 ]; then
    skip "mcp (set FSQL_LIBDUCKDB_DIR to a libduckdb release directory matching the extension's DuckDB version)"; return 1
  fi
  if [ ! -f "$cache/duckdb.h" ]; then
    mkdir -p "$cache" && bash "$HERE/scripts/fetch_duckdb.sh" libs "$ver" linux "$arch" "$cache" \
      || { skip "mcp (could not fetch libduckdb $ver for linux-$arch; set FSQL_LIBDUCKDB_DIR)"; return 1; }
  fi
  MCP_LIBDIR="$cache"
}

# Homebrew's openssl@3 is keg-only on macOS: neither its headers nor its libraries are on the default search paths.
# Sets MCP_SSL_CPP / MCP_SSL_LD (empty elsewhere) for the server build and the probes.
MCP_SSL_CPP=""; MCP_SSL_LD=""
mcp_ssl_flags() {
  [ "$(uname -s)" = Darwin ] || return 0
  local p=""
  command -v brew >/dev/null 2>&1 && p="$(brew --prefix openssl@3 2>/dev/null || true)"
  [ -n "$p" ] && [ -d "$p/include/openssl" ] || for p in /opt/homebrew/opt/openssl@3 /usr/local/opt/openssl@3; do [ -d "$p/include/openssl" ] && break; p=""; done
  [ -n "$p" ] && { MCP_SSL_CPP="-I$p/include"; MCP_SSL_LD="-L$p/lib"; }
  return 0
}

mcp_build() {
  [ -n "$MCP_EXE" ] && [ -x "$MCP_EXE" ] && return 0
  [ -n "$EXTW" ] || { skip "mcp (no extension resolved)"; return 1; }
  command -v python3 >/dev/null 2>&1 || { skip "mcp (python3 is needed for the test drivers)"; return 1; }
  local cxx=""; for c in "${CXX:-}" g++ c++ clang++; do [ -n "$c" ] && command -v "$c" >/dev/null 2>&1 && { cxx="$c"; break; }; done
  [ -n "$cxx" ] || { skip "mcp (no C++ compiler on PATH)"; return 1; }
  mcp_libduckdb || return 1
  local w; w="$(mktemp -d "${TMPDIR:-/tmp}/fsql_mcp_XXXXXX")"
  printf '#include <openssl/ssl.h>\nint main(){return 0;}\n' > "$w/ssl.cpp"
  mcp_ssl_flags
  "$cxx" $MCP_SSL_CPP -fsyntax-only "$w/ssl.cpp" >/dev/null 2>&1 || { skip "mcp (OpenSSL development headers not found: libssl-dev / openssl-devel)"; return 1; }
  MCP_WORK="$w"
  # Under --asan/--ubsan the server itself is built instrumented, so it carries the runtime that the
  # instrumented extension needs and every MCP gate checks the output for sanitizer reports.
  mcp_kind_flags
  if ! make -C "$HERE/mcp" CXX="$cxx" CXXFLAGS="-O1" CPPEXTRA="$MCP_SSL_CPP" LDEXTRA="$MCP_SSL_LD" SANFLAGS="$MCP_SAN" DUCKDB_DIR="$MCP_LIBDIR" BUILD="$w/build" OUT="$w/fractalsql-ext-mcp" >"$w/build.log" 2>&1; then
    tail -20 "$w/build.log" >&2; fail "35 mcp: the server did not build"; return 1
  fi
  MCP_EXE="$w/fractalsql-ext-mcp"
  # The server refuses to start without its drift locks; they are looked up next to the executable.
  cp "$HERE/mcp/.mcp-schema-lock" "$HERE/mcp/.mcp-safety-annotations-lock" "$w/"
  if [ -n "$MCP_RUN" ]; then   # the drivers launch one executable: wrap it so it starts under the prefix
    printf '#!/bin/sh\nexec %s "%s" "$@"\n' "$MCP_RUN" "$MCP_EXE" > "$w/srv-run.sh"; chmod +x "$w/srv-run.sh"
    MCP_EXE="$w/srv-run.sh"
  fi
}

mcp_probes_build() {
  [ "$MCP_PROBES_BUILT" -eq 1 ] && return 0
  if [ -z "$MCP_WORK" ]; then   # the probes do not need the server built
    [ -n "$EXTW" ] || { skip "mcp (no extension resolved)"; return 1; }
    command -v python3 >/dev/null 2>&1 || { skip "mcp (python3 is needed for the test drivers)"; return 1; }
    mcp_libduckdb || return 1
    MCP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/fsql_mcp_XXXXXX")"
    mcp_kind_flags
  fi
  mcp_ssl_flags
  local cxx; cxx="$(command -v g++ || command -v c++ || command -v clang++)"
  if ! make -C "$HERE/mcp" probes CXX="$cxx" CXXFLAGS="-O1 $MCP_SAN" CPPEXTRA="$MCP_SSL_CPP" LDEXTRA="$MCP_SSL_LD" DUCKDB_DIR="$MCP_LIBDIR" BUILD="$MCP_WORK/build" >"$MCP_WORK/probes.log" 2>&1; then
    tail -20 "$MCP_WORK/probes.log" >&2; fail "mcp probes: they did not build"; return 1
  fi
  MCP_EXEC="$MCP_WORK/build/duckdb_exec"
  if [ -n "$MCP_RUN" ]; then   # the drivers launch the helper directly: start it under the same prefix
    printf '#!/bin/sh\nexec %s "%s" "$@"\n' "$MCP_RUN" "$MCP_EXEC" > "$MCP_WORK/exec-run.sh"; chmod +x "$MCP_WORK/exec-run.sh"
    MCP_EXEC="$MCP_WORK/exec-run.sh"
  fi
  MCP_PROBES_BUILT=1
}

mcp_probe_run() {   # mcp_probe_run NUM PROBE
  local num="$1" p="$2" out rc
  mcp_probes_build || return
  out="$(env $(mcp_san_env) LD_LIBRARY_PATH="$MCP_LIBDIR" FSQL_DUCKDB_EXTENSION="$(realpath "$EXT")" $MCP_RUN "$MCP_WORK/build/$p" 2>&1)"; rc=$?
  mcp_san_check "$num mcp: $p" "$out" || return
  if [ "$rc" -eq 0 ]; then pass "$num mcp: $p ($(grep -cE '^OK|^  ok' <<< "$out") checks)"
  else grep -E '^FAIL' <<< "$out" | head -5 >&2; fail "$num mcp: $p reported a failure"; fi
}

gate_35() {   # server build, vectors_probe and sanitize_probe
  mcp_build || return
  pass "35 mcp: fractalsql-ext-mcp built ($(LD_LIBRARY_PATH="$MCP_LIBDIR" "$MCP_EXE" --version))"
  mcp_probe_run 35 vectors_probe
  mcp_probe_run 35 sanitize_probe
}
gate_39() { mcp_probe_run 39 db_probe; }
gate_40() { mcp_probe_run 40 concurrency_probe; }

# 41 mcp_faults (Linux): the server, with the extension loaded in-process, under tests/oom_preload.c. One
# allocation, file call or socket call is failed at a time while every tool is called; the server must keep
# answering. This is also the extension's allocation-failure injection: its allocations happen inside the server.
gate_41() {
  [ "$(uname -s)" = Linux ] || { skip "41 mcp_faults (needs LD_PRELOAD and signals, Linux only)"; return; }
  if [ -n "$MCP_KIND" ] && [ "$MCP_KIND" != cov ]; then skip "41 mcp_faults (a sanitizer runtime and the fault shim cannot both interpose the allocator)"; return; fi
  mcp_build || return
  mcp_probes_build || return
  local w="$MCP_WORK/faults"; rm -rf "$w"; mkdir -p "$w"
  if ! cc -O2 -fPIC -shared -o "$w/oom_preload.so" tests/oom_preload.c -ldl 2>"$w/build.log"; then
    cat "$w/build.log" >&2; fail "41 mcp_faults: oom_preload.so failed to build"; return
  fi
  local out rc
  out="$(LD_LIBRARY_PATH="$MCP_LIBDIR" FSQL_DUCKDB_EXTENSION="$(realpath "$EXT")" FSQL_DUCKDB_BOOTSTRAP="$HERE/mcp/tests/fixtures.sql" \
         FSQL_DUCKDB_ALLOW_UNSIGNED=true \
         MCP_OOM_PRELOAD="$w/oom_preload.so" MCP_SERVER_EXE="$MCP_EXE" MCP_SERVER_CWD="$w" \
         timeout 420 nice python3 -u "$HERE/mcp/tests/mcp_faults.py" 2>&1)"; rc=$?
  printf '%s\n' "$out" > "$MCP_WORK/faults.log"
  if [ "$rc" -eq 0 ] && grep -q 'ALL GREEN' <<< "$out"; then
    pass "41 mcp_faults: $(grep -c '^ *PASS' <<< "$out") checks passed ($(grep -E '^PASS faults: [0-9]+ injected alloc' <<< "$out" | head -1 | cut -c1-110))"
  else
    grep -E '^ *FAIL|cause' <<< "$out" | head -10 >&2
    fail "41 mcp_faults: failed (exit $rc; full log $MCP_WORK/faults.log)"
  fi
}

# 42 mcp_fuzz (--fuzz only): libFuzzer + ASan over the JSON-RPC front door and the argument coercion.
gate_42() {
  local cc="" cxx c secs="${FSQL_FUZZ_TIME:-30}" t rc
  mcp_libduckdb || return
  local w; w="$(mktemp -d "${TMPDIR:-/tmp}/fsql_mcpfuzz_XXXXXX")"
  for c in "${FSQL_FUZZ_CC:-}" clang-19 clang-18 clang-17 clang; do
    [ -n "$c" ] || continue
    command -v "$c" >/dev/null 2>&1 || continue
    printf 'int LLVMFuzzerTestOneInput(const unsigned char*d,unsigned long n){return d&&n;}\n' > "$w/p.c"
    "$c" -fsanitize=fuzzer "$w/p.c" -o "$w/p" >/dev/null 2>&1 && { cc="$c"; break; }
  done
  [ -n "$cc" ] || { skip "42 mcp_fuzz (no clang with libFuzzer: set FSQL_FUZZ_CC)"; return; }
  cxx="${cc/clang/clang++}"; command -v "$cxx" >/dev/null 2>&1 || { skip "42 mcp_fuzz (no $cxx next to $cc)"; return; }
  for t in vectors jsonrpc; do
    local srcs=(mcp/src/errors.cpp)
    case "$t" in
      vectors) srcs+=(mcp/src/vectors.cpp) ;;
      jsonrpc) srcs+=(mcp/src/db.cpp mcp/src/jsonrpc_server.cpp mcp/src/logging.cpp mcp/src/prompts.cpp mcp/src/resources.cpp) ;;
    esac
    if ! "$cxx" -std=c++17 -O1 -g -fsanitize=fuzzer,address,undefined -Imcp/src -Imcp/vendor -I"$MCP_LIBDIR" "tests/fuzz/fuzz_mcp_$t.cpp" "${srcs[@]}" \
          -L"$MCP_LIBDIR" -lduckdb -Wl,-rpath,"$MCP_LIBDIR" -lssl -lcrypto -lpthread -o "$w/fuzz_mcp_$t" >"$w/$t.build.log" 2>&1; then
      fail "42 mcp_fuzz: fuzz_mcp_$t failed to build; see $w/$t.build.log"; continue
    fi
    mkdir -p "$w/seed_$t"; rc=0
    ASAN_OPTIONS="detect_leaks=0:symbolize=0:abort_on_error=1:alloc_dealloc_mismatch=0" "$w/fuzz_mcp_$t" "$w/seed_$t" "tests/fuzz/corpus_mcp_$t" \
      -max_total_time="$secs" -print_final_stats=1 >"$w/$t.run.log" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then pass "42 mcp_fuzz: fuzz_mcp_$t (${secs}s, corpus-seeded)"
    else fail "42 mcp_fuzz: fuzz_mcp_$t exited rc=$rc; see $w/$t.run.log"; tail -5 "$w/$t.run.log" 2>/dev/null | sed 's/^/         /'; fi
  done
  [ "$FAILED" -eq 0 ] && rm -rf "$w"   # keep the logs when a target failed
}

# 52 fuzz_parse (--fuzz only): libFuzzer + ASan + UBSan over the extension's own parser for a model's reply.
# The reply is untrusted input -- whatever a language model said -- so the code that turns it into SQL is attack
# surface, and this fuzzer drives exactly the functions the text-to-SQL tier calls (src/fsql_parse.c). The target
# carries no DuckDB, so unlike gate 42 this needs no libduckdb, no OpenSSL and no MCP server.
gate_52() {
  local cc="" secs="${FSQL_FUZZ_TIME:-30}" w rc
  w="$(mktemp -d "${TMPDIR:-/tmp}/fsql_parsefuzz_XXXXXX")"
  # The denied-call scan, case by case, in every spelling the SQL parser accepts (a comment or a quoted name before the parenthesis).
  # A plain C program: it needs no libFuzzer.
  local ucc; ucc="$(command -v cc || command -v gcc || true)"
  if [ -n "$ucc" ]; then
    if "$ucc" -std=c11 -Wall -Wextra -Isrc tests/denied_call_test.c src/fsql_parse.c src/fsql_buf.c -o "$w/denied_call_test" >"$w/denied.log" 2>&1 \
       && "$w/denied_call_test" >>"$w/denied.log" 2>&1; then
      pass "52 denied_call: the generated-SQL function denylist catches every spelling of a call"
    else
      fail "52 denied_call: a denied function got through; see $w/denied.log"; tail -8 "$w/denied.log" 2>/dev/null | sed 's/^/         /'
    fi
  fi
  for c in "${FSQL_FUZZ_CC:-}" clang-19 clang-18 clang-17 clang; do
    [ -n "$c" ] || continue
    command -v "$c" >/dev/null 2>&1 || continue
    printf 'int LLVMFuzzerTestOneInput(const unsigned char*d,unsigned long n){return d&&n;}
' > "$w/p.c"
    "$c" -fsanitize=fuzzer "$w/p.c" -o "$w/p" >/dev/null 2>&1 && { cc="$c"; break; }
  done
  [ -n "$cc" ] || { skip "52 fuzz_parse (no clang with libFuzzer: set FSQL_FUZZ_CC)"; rm -rf "$w"; return; }
  if ! "$cc" -std=c11 -O1 -g -fsanitize=fuzzer,address,undefined -Isrc         tests/fuzz/fuzz_t2s_parse.c src/fsql_parse.c src/fsql_buf.c -o "$w/fuzz_t2s_parse" >"$w/build.log" 2>&1; then
    fail "52 fuzz_parse: fuzz_t2s_parse failed to build; see $w/build.log"; tail -5 "$w/build.log" 2>/dev/null | sed 's/^/         /'; return
  fi
  mkdir -p "$w/corpus"; rc=0
  ASAN_OPTIONS="detect_leaks=0:symbolize=0:abort_on_error=1:alloc_dealloc_mismatch=0"     "$w/fuzz_t2s_parse" "$w/corpus" "tests/fuzz/corpus_t2s_parse"     -max_total_time="$secs" -print_final_stats=1 >"$w/run.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then pass "52 fuzz_parse: fuzz_t2s_parse (${secs}s, corpus-seeded, ASan+UBSan)"
  else fail "52 fuzz_parse: fuzz_t2s_parse exited rc=$rc; see $w/run.log"; tail -5 "$w/run.log" 2>/dev/null | sed 's/^/         /'; fi
  [ "$FAILED" -eq 0 ] && rm -rf "$w"   # keep the logs when a target failed
}

# 43 recall_hybrid_filter: fractal_agent_recall_hybrid's four-argument form (a filter column with no filter
# value) once dereferenced a null and killed the process. It must now answer with an error. This needs an
# extension built from a source tree that has the fix (rebuild dist/ with build.sh).
gate_43() {
  mcp_probes_build || return
  local sql out rc bad=0
  for sql in "SELECT fractal_agent_recall_hybrid('x','y',[1.0]::DOUBLE[],'z')" \
             "SELECT fractal_agent_recall_hybrid('docs','emb',[1.0,0,0,0]::DOUBLE[],'body')"; do
    out="$(env $(mcp_san_env) LD_LIBRARY_PATH="$MCP_LIBDIR" timeout 60 "$MCP_EXEC" :memory: --ext "$(realpath "$EXT")" -- "$sql" 2>&1)"; rc=$?
    if [ "$rc" -ge 124 ]; then bad=$((bad + 1)); printf '    crashed or hung (rc=%s): %s\n' "$rc" "$sql" >&2; fi
  done
  if [ "$bad" -eq 0 ]; then pass "43 recall_hybrid_filter: the filter-column-only call is refused with an error, not a crash"
  else fail "43 recall_hybrid_filter: $bad call(s) killed the process; the extension in use predates the fix (rebuild dist/)"; fi
}

# 45 mcp_conformance: the protocol conformance gate. The driver starts the servers it needs
# itself -- both protocol eras, with and without a bearer token, in read-only mode, with the
# operator switches on and off, over HTTP and over stdio -- and checks the behaviour against
# the published rules. It is the same driver file in every engine's repository.
gate_45() {
  local driver="$HERE/mcp/tests/mcp_conformance.py"
  local PY_CONFORMANCE=""
  if [ ! -f "$driver" ]; then
    skip "45 mcp_conformance (no mcp/tests/mcp_conformance.py)"; return
  fi
  if ! command -v python3 >/dev/null 2>&1 || ! python3 -c '' >/dev/null 2>&1; then
    if command -v python >/dev/null 2>&1 && python -c '' >/dev/null 2>&1; then
      PY_CONFORMANCE=python
    else
      skip "45 mcp_conformance (no python3 on PATH -- the conformance driver needs it)"; return
    fi
  else
    PY_CONFORMANCE=python3
  fi
  # The server refuses to start without its two drift locks, and the driver checks that it
  # refuses: without them there is nothing to check.
  if [ ! -f "$HERE/mcp/.mcp-schema-lock" ] || [ ! -f "$HERE/mcp/.mcp-safety-annotations-lock" ]; then
    skip "45 mcp_conformance (the drift locks are missing)"; return
  fi
  mcp_build || { skip "45 mcp_conformance (the server was not built)"; return; }
  if [ -z "$MCP_EXE" ] || [ ! -x "$MCP_EXE" ]; then
    skip "45 mcp_conformance (no server binary)"; return
  fi
  # The driver runs the desktop profile with a scrubbed environment -- only what a client
  # config would pass -- so the extension path travels in the passthrough list as well.
  local work="$MCP_WORK/conformance"; mkdir -p "$work"
  local out rc
  out="$(env \
    MCP_SERVER_EXE="$MCP_EXE" \
    MCP_SERVER_CWD="$work" \
    MCP_HERE="$HERE/mcp" \
    FSQL_DUCKDB_EXTENSION="$(realpath "$EXT")" \
    FSQL_DUCKDB_ALLOW_UNSIGNED="${FSQL_DUCKDB_ALLOW_UNSIGNED:-true}" \
    MCPC_TOKEN="conformance-token" \
    MCPC_GATE=45 \
    MCPC_LOCK_DIR="$HERE/mcp" \
    MCPC_PASSTHROUGH_ENV="FSQL_DUCKDB_EXTENSION,FSQL_DUCKDB_ALLOW_UNSIGNED,FSQL_DUCKDB_DATABASE" \
    MCPC_READ_TOOL="fractal_version" \
    MCPC_READ_ARGS='{}' \
    MCPC_STATE_TOOL="fractal_diversify_enable" \
    MCPC_STATE_ARGS='{}' \
    MCPC_STATE_READER="fractal_explain_result" \
    MCPC_DESTRUCTIVE_TOOL="fractal_diversify_enable" \
    MCPC_DESTRUCTIVE_ARGS='{}' \
    MCPC_SAFE_KEY="http_model" \
    MCPC_UNSAFE_KEY="http_url" \
    LD_LIBRARY_PATH="$MCP_LIBDIR" \
    $(mcp_san_env) \
    timeout 1800 "$PY_CONFORMANCE" -u "$driver" 2>&1)"; rc=$?
  printf '%s\n' "$out" > "$MCP_WORK/mcp_conformance.log"
  if [ "$rc" -eq 0 ] && grep -q 'ALL GREEN' <<< "$out"; then
    pass "45 mcp_conformance: $(grep -c '^PASS' <<< "$out") checks passed ($(grep -E 'ALL GREEN' <<< "$out" | tail -1 | sed 's/^ *//'))"
  else
    # The driver's own failure lines, not the server's log: they name the rule that was broken.
    grep -E '^ *(FAIL|SKIP) ' <<< "$out" | head -12 >&2
    fail "45 mcp_conformance: the conformance driver reported failures (exit $rc; full log $MCP_WORK/mcp_conformance.log)"
  fi
}

mcp_driver_gate() {   # mcp_driver_gate NUM NAME SCRIPT [VAR=value ...]
  local num="$1" name="$2" script="$3"; shift 3
  mcp_build || return
  mcp_probes_build || return    # also builds duckdb_exec, wrapped to start under setarch -R for --tsan
  local out rc
  local skip_sweeps=""; { [ "$MCP_KIND" = tsan ] || [ "$MCP_KIND" = cov ]; } && skip_sweeps=1
  out="$(env "$@" ${skip_sweeps:+MCP_SMOKE_SKIP_SWEEPS=1} $(mcp_san_env) LD_LIBRARY_PATH="$MCP_LIBDIR" FSQL_DUCKDB_EXTENSION="$(realpath "$EXT")" FSQL_DUCKDB_ALLOW_UNSIGNED="${FSQL_DUCKDB_ALLOW_UNSIGNED:-true}" MCP_SERVER_EXE="$MCP_EXE" MCP_SERVER_CWD="$MCP_WORK" \
         MCP_HERE="$HERE/mcp" MCP_DUCKDB_EXEC="$MCP_EXEC" timeout 1800 python3 "$HERE/mcp/tests/$script" 2>&1)"; rc=$?
  printf '%s\n' "$out" > "$MCP_WORK/$name.log"
  mcp_san_check "$num mcp_$name" "$out" || return
  local nfail; nfail="$(grep -c '^ *FAIL' <<< "$out")"
  if [ "$rc" -eq 0 ] && grep -q 'ALL GREEN' <<< "$out"; then
    pass "$num mcp_$name: $(grep -c '^ *PASS' <<< "$out") checks passed ($(grep -E 'ALL GREEN' <<< "$out" | tail -1 | sed 's/^ *//' | cut -c1-70))"
  else
    grep -E '^ *FAIL|offender|Traceback|Error' <<< "$out" | head -12 >&2
    fail "$num mcp_$name: $nfail check(s) failed (exit $rc; full log $MCP_WORK/$name.log)"
  fi
}

gate_36() { mcp_driver_gate 36 smoke mcp_smoke_client.py; }
gate_37() {
  command -v openssl >/dev/null 2>&1 || { skip "37 mcp_https (no openssl CLI for the throwaway certificate)"; return; }
  mcp_build || return
  local w="$MCP_WORK/tls"; mkdir -p "$w"; : > "$w/empty.cnf"
  OPENSSL_CONF="$w/empty.cnf" openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=127.0.0.1" \
    -keyout "$w/key.pem" -out "$w/cert.pem" >/dev/null 2>&1 || { skip "37 mcp_https (could not generate a certificate)"; return; }
  local port; port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
  mcp_driver_gate 37 https mcp_https_smoke_client.py MCP_HTTPS_PORT="$port" MCP_HTTPS_CERT="$w/cert.pem" MCP_HTTPS_KEY="$w/key.pem"
}
gate_38() { mcp_driver_gate 38 cli mcp_cli.py; }
# The HTTP transport refuses lookalike origins and repeated headers (no engine needed)
gate_58() { mcp_driver_gate 58 audit_http mcp_audit_http.py; }

# 59 audit_regress: test/audit_regress.py, the security regressions reachable from SQL. DK-01: the reasoning plugin path is copied
# into a bounded buffer before the tier environment is rewritten (an over-long path is a clean error); DK-02: an unreadable .sig is refused;
# DK-05: fractal_vectorizer_create outside 3 to 5 arguments is a bind error.
gate_59() {
  if [ ! -f "$HERE/test/audit_regress.py" ]; then skip "59 audit_regress (no test/audit_regress.py)"; return; fi
  if ! command -v python3 >/dev/null 2>&1; then skip "59 audit_regress (needs python3)"; return; fi
  if ! ls "$HERE"/dist/*/fractalsql.capi.*.duckdb_extension >/dev/null 2>&1; then
    if ! nice make -C "$HERE" -s >/dev/null 2>&1; then fail "59 audit_regress: the extension did not build"; return; fi
  fi
  local out rc line
  out="$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS nice python3 -I "$HERE/test/audit_regress.py" 2>&1)"; rc=$?
  line="$(grep -E '^audit_regress: ' <<< "$out" | tail -1)"
  if [ "$rc" -eq 0 ] && [ -n "$line" ]; then
    pass "59 audit_regress: ${line#audit_regress: }"
  else
    grep -E '^  FAIL' <<< "$out" | head -10 | sed 's/^/    /' >&2
    fail "59 audit_regress: ${line:-the driver did not finish} (run test/audit_regress.py)"
  fi
}


# 46 capi_matrix: the pure-C extension. It builds and checks its own files, not the artifact the other
# gates locate. See test/load_matrix.sh for the
# individual checks; this wrapper counts them and surfaces any failure line.
gate_46() {
  if [ ! -f "$HERE/Makefile" ] || [ ! -x "$HERE/test/load_matrix.sh" ]; then
    skip "46 capi_matrix (no pure-C extension tree)"; return
  fi
  if ! command -v make >/dev/null 2>&1 || ! command -v "${CC:-cc}" >/dev/null 2>&1; then
    skip "46 capi_matrix (needs make and a C compiler)"; return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    skip "46 capi_matrix (needs python3 for the metadata footer)"; return
  fi
  local blog="${TMPDIR:-/tmp}/fsql_bt_capi_build_$$.log" out rc
  if ! nice make -C "$HERE" -s >"$blog" 2>&1; then
    tail -15 "$blog" >&2
    fail "46 capi_matrix: the extension did not build (log $blog)"; return
  fi
  rm -f "$blog"
  out="$("$HERE/test/load_matrix.sh" 2>&1)"; rc=$?
  local np nf ns
  np="$(grep -c '^  PASS ' <<< "$out")"; nf="$(grep -c '^  FAIL ' <<< "$out")"; ns="$(grep -c '^  SKIP ' <<< "$out")"
  grep -E '^  (FAIL|SKIP) ' <<< "$out" | sed 's/^/    /' >&2
  if [ "$rc" -eq 0 ] && [ "$nf" -eq 0 ] && [ "$np" -gt 0 ]; then
    pass "46 capi_matrix: $np checks passed$([ "$ns" -gt 0 ] && printf ", %s skipped" "$ns") (both bands built; load/refuse matrix, footer, one exported symbol, no DuckDB code inside)"
  else
    fail "46 capi_matrix: $nf check(s) failed ($np passed); run test/load_matrix.sh for the full list"
  fi
}

# 47 capi_parity: see test/parity_diff.py. Needs both bands built (gate 46 builds them)
# and python3. The retired C++ build is compared only when CPP_EXT names one (its functions kept the old names);
# otherwise the corpus's written expectations and cross-version consistency (1.4.x / 1.5.x / 2.0.x) are what is checked.
gate_47() {
  if [ ! -f "$HERE/test/parity_diff.py" ]; then skip "47 capi_parity (no pure-C extension tree)"; return; fi
  if ! command -v python3 >/dev/null 2>&1; then skip "47 capi_parity (needs python3)"; return; fi
  if ! ls "$HERE"/dist/*/fractalsql.capi.*.duckdb_extension >/dev/null 2>&1; then
    if ! nice make -C "$HERE" -s >/dev/null 2>&1; then fail "47 capi_parity: the extension did not build"; return; fi
  fi
  local out rc np nf ns
  # the parity corpus compares the uninstrumented builds: a sanitizer runtime preloaded by --asan/--ubsan would make a C++ reference (CPP_EXT) fail on its own
  # alloc-dealloc mismatches (gate 48 is the sanitizer run of the corpus)
  out="$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS nice python3 -I "$HERE/test/parity_diff.py" 2>&1)"; rc=$?
  np="$(grep -c '^  PASS ' <<< "$out")"; nf="$(grep -c '^  FAIL ' <<< "$out")"; ns="$(grep -c '^  SKIP ' <<< "$out")"
  grep -E '^  FAIL |^      ' <<< "$out" | head -20 | sed 's/^/    /' >&2
  grep -E '^  SKIP ' <<< "$out" | sed 's/^/    /' >&2
  if [ "$rc" -eq 0 ] && [ "$nf" -eq 0 ] && [ "$np" -gt 0 ]; then
    pass "47 capi_parity: $np parity checks passed ($(grep -oE '[0-9]+ error-class prefixes' <<< "$out" | head -1 || true) normalised, the accepted error-prefix rule)"
  else
    fail "47 capi_parity: $nf difference(s) from the corpus's expectations or between DuckDB versions ($np matched); run test/parity_diff.py"
  fi
}

# 49 capi_lifecycle: see test/lifecycle_run.sh. Needs both bands built, a C compiler and a
# libduckdb.so per DuckDB line (a line without one is skipped and reported).
gate_49() {
  if [ ! -x "$HERE/test/lifecycle_run.sh" ]; then skip "49 capi_lifecycle (no pure-C extension tree)"; return; fi
  if [ "$(uname -s)" != Linux ]; then skip "49 capi_lifecycle (Linux only: it reads /proc/self/fd)"; return; fi
  if ! command -v cc >/dev/null 2>&1; then skip "49 capi_lifecycle (needs a C compiler)"; return; fi
  if ! ls "$HERE"/dist/*/fractalsql.capi.*.duckdb_extension >/dev/null 2>&1; then
    if ! nice make -C "$HERE" -s >/dev/null 2>&1; then fail "49 capi_lifecycle: the extension did not build"; return; fi
  fi
  local out rc np nf ns
  # The 2.x one-shot CLI variant hits a documented teardown race: the process
  # exits within milliseconds of closing its database and touching libduckdb
  # during teardown is not safe (the script's own comment, and the flag it
  # already carries for exactly this). The "release" and "off" variants still
  # cover the 2.x line, so the plain one is skipped rather than failed.
  out="$(LIFECYCLE_SKIP_PLAIN=1 CAPI_DIST="${CAPI_DIST:-}" "$HERE/test/lifecycle_run.sh" 2>&1)"; rc=$?
  np="$(grep -c '^  PASS ' <<< "$out")"; nf="$(grep -c '^  FAIL ' <<< "$out")"; ns="$(grep -c '^  SKIP ' <<< "$out")"
  grep -E '^  FAIL ' <<< "$out" | head -10 | sed 's/^/    /' >&2
  grep -E '^  SKIP ' <<< "$out" | sed 's/^/    /' >&2
  if [ "$rc" -eq 0 ] && [ "$nf" -eq 0 ] && [ "$np" -gt 0 ]; then
    pass "49 capi_lifecycle: $np lifecycle checks passed$([ "$ns" -gt 0 ] && printf ', %s skipped' "$ns") (a closed database is released with no call at all; also after fractal_release(), nested queries off, reconnects, freeze/thaw, concurrent databases)"
  elif [ "$np" -eq 0 ] && [ "$nf" -eq 0 ]; then
    skip "49 capi_lifecycle (no libduckdb.so found for any line; set FSQL_LIBDUCKDB_15)"
  else
    fail "49 capi_lifecycle: $nf failure(s); run test/lifecycle_run.sh"
  fi
}

# 51 capi_lifecycle_san: gate 49's modes under AddressSanitizer (+LeakSanitizer) and ThreadSanitizer, one round each.
gate_51() {
  if [ ! -x "$HERE/test/lifecycle_run.sh" ]; then skip "51 capi_lifecycle_san (no pure-C extension tree)"; return; fi
  if [ "$(uname -s)" != Linux ]; then skip "51 capi_lifecycle_san (Linux only)"; return; fi
  if ! command -v cc >/dev/null 2>&1; then skip "51 capi_lifecycle_san (needs a C compiler)"; return; fi
  local san out rc np nf ns total_p=0 bad=0 ran=""
  for san in address thread; do
    if ! echo 'int main(void){return 0;}' | cc -x c - -fsanitize="$san" -o /dev/null >/dev/null 2>&1; then
      printf '      the compiler cannot build with -fsanitize=%s: skipped\n' "$san" >&2; continue
    fi
    out="$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS CAPI_LIFECYCLE_SAN="$san" CAPI_LIFECYCLE_ROUNDS=1 CAPI_DEPARTRACE_ROUNDS=4 "$HERE/test/lifecycle_run.sh" 2>&1)"; rc=$?
    np="$(grep -c '^  PASS ' <<< "$out")"; nf="$(grep -c '^  FAIL ' <<< "$out")"; ns="$(grep -c '^  SKIP ' <<< "$out")"
    grep -E '^  FAIL ' <<< "$out" | head -6 | sed "s/^/    [$san] /" >&2
    if [ "$rc" -ne 0 ] || [ "$nf" -ne 0 ]; then bad=$((bad + 1)); continue; fi
    [ "$np" -gt 0 ] && { total_p=$((total_p + np)); ran="$ran $san"; }
  done
  if [ "$bad" -ne 0 ]; then fail "51 capi_lifecycle_san: failures under a sanitizer; run CAPI_LIFECYCLE_SAN=address|thread test/lifecycle_run.sh"
  elif [ "$total_p" -eq 0 ]; then skip "51 capi_lifecycle_san (no sanitizer build possible, or no libduckdb.so found)"
  else pass "51 capi_lifecycle_san: $total_p lifecycle checks passed under${ran} (no memory error, no leak, no race in the extension)"
  fi
}

# 50 plugin_sig_vendored: every vendored reasoning plugin carries its detached signature. The host loads
# the plugin only when <plugin>.sig (exactly 64 raw Ed25519 bytes) sits beside it, so a plugin vendored
# without one (or with a truncated one) would ship a release whose reasoning tier refuses to load.
# A static check of include/<platform>/; needs no DuckDB.
gate_50() {
  local n=0 bad=0 f
  for f in "$HERE"/include/*/fractalsql-reasoning-http.so "$HERE"/include/*/fractalsql-reasoning-http.dll; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    if [ ! -f "${f}.sig" ] || [ "$(wc -c < "${f}.sig" | tr -d ' ')" -ne 64 ]; then
      printf '      missing or not 64 bytes: %s.sig\n' "${f#"$HERE"/}"; bad=$((bad + 1))
    fi
  done
  if [ "$n" -eq 0 ]; then skip "50 plugin_sig_vendored (no vendored plugins under include/)"; return; fi
  if [ "$bad" -ne 0 ]; then fail "50 plugin_sig_vendored: $bad of $n vendored plugin(s) lack a valid .sig"; return; fi
  pass "50 plugin_sig_vendored: all $n vendored plugins have a 64-byte .sig beside them"
}

# 48 capi_sanitize: see test/parity_diff.py (CAPI_SAN) and `make -C capi unit`. The C extension is
# memory-unsafe-capable code, so every family that lands is run through ASan and UBSan here.
gate_48() {
  if [ ! -f "$HERE/test/parity_diff.py" ]; then skip "48 capi_sanitize (no pure-C extension tree)"; return; fi
  if ! command -v python3 >/dev/null 2>&1 || ! command -v "${CC:-cc}" >/dev/null 2>&1; then
    skip "48 capi_sanitize (needs python3 and a C compiler)"; return
  fi
  local san lib out rc bad=0 total=0 ulog="${TMPDIR:-/tmp}/fsql_bt_capi_unit_$$.log"
  # this gate sets up its own sanitizer runtime: a different one preloaded by --asan/--ubsan must not be inherited
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS nice make -C "$HERE" -s unit >"$ulog" 2>&1; then
    tail -15 "$ulog" >&2; fail "48 capi_sanitize: the buffer-layer unit test failed under ASan/UBSan (log $ulog)"; return
  fi
  total=$(grep -oE '[0-9]+ checks' "$ulog" | head -1)
  rm -f "$ulog"
  for san in address undefined; do
    lib="libasan.so"; [ "$san" = undefined ] && lib="libubsan.so"
    if [ ! -e "$("${CC:-cc}" -print-file-name=$lib 2>/dev/null)" ]; then
      skip "48 capi_sanitize ($san: $lib not found next to the compiler)"; continue
    fi
    if ! nice make -C "$HERE" -s SAN=$san >/dev/null 2>&1; then
      fail "48 capi_sanitize: the $san build did not build"; bad=$((bad + 1)); continue
    fi
    out="$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS CAPI_SAN=$san nice python3 -I "$HERE/test/parity_diff.py" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
      grep -E '^  FAIL |^      |SANITIZER' <<< "$out" | head -12 | sed 's/^/    /' >&2
      fail "48 capi_sanitize: $san reported a failure"; bad=$((bad + 1))
    fi
  done
  [ "$bad" -eq 0 ] && pass "48 capi_sanitize: buffer layer ($total) and the full parity corpus are clean under ASan and UBSan (on 1.5.x; cross-version equality is gate 47)"
}

gate_title() {
  printf '\n== Gate %s: %s\n' "$1" "$2"
}

# 60 precision: test/test_precision.py -- the precision contract (R2, R3, R5, R7, R8): the rename, the ONE cosine,
# the double accumulation, and the build flags.
gate_60() {
  if [ ! -f "$HERE/test/test_precision.py" ]; then skip "60 precision (no test/test_precision.py)"; return; fi
  if ! command -v python3 >/dev/null 2>&1; then skip "60 precision (needs python3)"; return; fi
  if ! ls "$HERE"/dist/*/fractalsql.capi.*.duckdb_extension >/dev/null 2>&1; then
    if ! nice make -C "$HERE" -s >/dev/null 2>&1; then fail "60 precision: the extension did not build"; return; fi
  fi
  local out rc line
  out="$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS nice python3 -I "$HERE/test/test_precision.py" 2>&1)"; rc=$?
  line="$(grep -E '^precision: ' <<< "$out" | tail -1)"
  if [ "$rc" -eq 0 ] && [ -n "$line" ]; then
    pass "60 precision: ${line#precision: }"
  else
    grep -E '^  FAIL' <<< "$out" | head -20 | sed 's/^/    /' >&2
    fail "60 precision: ${line:-the checks did not finish} (run test/test_precision.py)"
  fi
}

# 61 index: test/test_index.py -- the native IVF index: the SQL surface, the exact verified distances, the delta, and the
# proof that the index was ACTUALLY USED (the rows it scanned are far below the table's row count).
gate_61() {
  if [ ! -f "$HERE/test/test_index.py" ]; then skip "61 index (no test/test_index.py)"; return; fi
  if ! command -v python3 >/dev/null 2>&1; then skip "61 index (needs python3)"; return; fi
  if ! ls "$HERE"/dist/*/fractalsql.capi.*.duckdb_extension >/dev/null 2>&1; then
    if ! nice make -C "$HERE" -s >/dev/null 2>&1; then fail "61 index: the extension did not build"; return; fi
  fi
  # A sanitizer cell (like gate 48): the driver runs the instrumented build (CAPI_SAN selects dist/<san>/ and
  # folds the runtime into every CLI call), so the SAN-instrumented mock reasoning plugin this gate hands the
  # agents joins the resident runtime instead of loading into an uninstrumented CLI.
  local out rc line san=""
  [ "$SAN_MODE" = asan ] && san="address"
  [ "$SAN_MODE" = ubsan ] && san="undefined"
  out="$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS CAPI_SAN="$san" FSQL_TEST_MOCK_REASONING="${MOCK:-}" nice python3 -I "$HERE/test/test_index.py" 2>&1)"; rc=$?
  line="$(grep -E '^index: ' <<< "$out" | tail -1)"
  if grep -qE '^index: SKIPPED' <<< "$out"; then
    skip "61 index: ${out#index: SKIPPED -- }"
    return
  fi
  if [ "$rc" -eq 0 ] && [ -n "$line" ]; then
    pass "61 index: ${line#index: }"
  else
    grep -E '^  FAIL' <<< "$out" | head -20 | sed 's/^/    /' >&2
    fail "61 index: ${line:-the checks did not finish} (run test/test_index.py)"
  fi
}

# 63 enterprise_core: test/test_enterprise_core.py -- the extension with an enterprise core library: the REAL one when FSQL_TEST_ENTERPRISE_LIB
# names it (an absolute path to libfractalsql-enterprise-*-c with its .sig beside it), otherwise the mock core: the gated functions are live, the audit chain verifies, a flush
# is restored by a load, both retention modes reach the core, the signature is checked, and the retrieval features (index ensure,
# agent_use_index, recall_hybrid) work with the enterprise tier active. The Pareto and signature checks need the real library and run only with it.
gate_63() {
  if [ ! -f "$HERE/test/test_enterprise_core.py" ]; then skip "63 enterprise_core (no test/test_enterprise_core.py)"; return; fi
  if ! command -v python3 >/dev/null 2>&1; then skip "63 enterprise_core (needs python3)"; return; fi
  if ! ls "$HERE"/dist/*/fractalsql.capi.*.duckdb_extension >/dev/null 2>&1; then
    if ! nice make -C "$HERE" -s >/dev/null 2>&1; then fail "63 enterprise_core: the extension did not build"; return; fi
  fi
  local out rc line
  out="$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS nice python3 -I "$HERE/test/test_enterprise_core.py" 2>&1)"; rc=$?
  line="$(grep -E '^enterprise core: ' <<< "$out" | tail -1)"
  if [ "$rc" -eq 0 ] && [ -n "$line" ]; then
    pass "63 enterprise_core: ${line#enterprise core: } (audit chain, flush and load, retention, latch, index ensure and recall_hybrid; Pareto and signature with the real library)"
  else
    grep -E '^  FAIL' <<< "$out" | head -20 | sed 's/^/    /' >&2
    fail "63 enterprise_core: ${line:-the checks did not finish} (run test/test_enterprise_core.py)"
  fi
}

# 64 unicode: test/test_unicode.py -- accented Latin, CJK, right-to-left text, emoji and combining marks through fractal_chunk_text and a table
# round trip: one chunk is the whole text, offsets are character offsets, the chunks join back, the JSON is strict UTF-8.
gate_64() {
  if [ ! -f "$HERE/test/test_unicode.py" ]; then skip "64 unicode (no test/test_unicode.py)"; return; fi
  if ! command -v python3 >/dev/null 2>&1; then skip "64 unicode (needs python3)"; return; fi
  if ! ls "$HERE"/dist/*/fractalsql.capi.*.duckdb_extension >/dev/null 2>&1; then
    if ! nice make -C "$HERE" -s >/dev/null 2>&1; then fail "64 unicode: the extension did not build"; return; fi
  fi
  local out rc line
  out="$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS nice python3 -I "$HERE/test/test_unicode.py" 2>&1)"; rc=$?
  line="$(grep -E '^unicode: ' <<< "$out" | tail -1)"
  if [ "$rc" -eq 0 ] && [ -n "$line" ]; then
    pass "64 unicode: ${line#unicode: } (Latin, CJK, right-to-left, emoji, combining marks, JSON-special characters)"
  else
    grep -E '^  FAIL' <<< "$out" | head -20 | sed 's/^/    /' >&2
    fail "64 unicode: ${line:-the checks did not finish} (run test/test_unicode.py)"
  fi
}

# 65 partial_reasoning: test/test_partial_reasoning.py -- agent_partial_reasoning_fail. Off (the default) an agent raises when its reasoning step
# fails; on, search_agent / rag_agent and the domain agents keep their computed half and report reasoning_step_failed. A local HTTP stub answers
# embeddings and fails every chat call, through the vendored http plugin.
gate_65() {
  if [ ! -f "$HERE/test/test_partial_reasoning.py" ]; then skip "65 partial_reasoning (no test/test_partial_reasoning.py)"; return; fi
  if ! command -v python3 >/dev/null 2>&1; then skip "65 partial_reasoning (needs python3)"; return; fi
  if ! ls "$HERE"/dist/*/fractalsql.capi.*.duckdb_extension >/dev/null 2>&1; then
    if ! nice make -C "$HERE" -s >/dev/null 2>&1; then fail "65 partial_reasoning: the extension did not build"; return; fi
  fi
  local out rc line
  out="$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS nice python3 -I "$HERE/test/test_partial_reasoning.py" 2>&1)"; rc=$?
  if grep -q '^  SKIP' <<< "$out"; then skip "65 partial_reasoning: $(grep '^  SKIP' <<< "$out" | head -1 | sed 's/^  SKIP //')"; return; fi
  line="$(grep -E '^failed: ' <<< "$out" | tail -1)"
  if [ "$rc" -eq 0 ] && [ "$line" = "failed: 0" ]; then
    pass "65 partial_reasoning: $(grep -c '^ok' <<< "$out") checks (rag_agent and a domain agent raise by default and keep their computed half with the key on; the key validates and is listed)"
  else
    grep -E '^FAIL' <<< "$out" | head -20 | sed 's/^/    /' >&2
    fail "65 partial_reasoning: ${line:-the checks did not finish} (run test/test_partial_reasoning.py)"
  fi
}

# 71 ledger_payloads: what fractal_audit_log writes into the chain for every shape of entry type, payload and actor
# (test/ledger_payloads.py): the caller's text never breaks the JSON or the chain.
gate_71() {
  if [ ! -f "$HERE/test/ledger_payloads.py" ]; then skip "71 ledger_payloads (no test/ledger_payloads.py)"; return; fi
  if ! command -v python3 >/dev/null 2>&1; then skip "71 ledger_payloads (needs python3)"; return; fi
  if ! ls "$HERE"/dist/*/fractalsql.capi.*.duckdb_extension >/dev/null 2>&1; then
    if ! nice make -C "$HERE" -s >/dev/null 2>&1; then fail "71 ledger_payloads: the extension did not build"; return; fi
  fi
  local out rc line
  out="$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS nice python3 -I "$HERE/test/ledger_payloads.py" 2>&1)"; rc=$?
  line="$(grep -E '^ledger_payloads: ' <<< "$out" | tail -1)"
  if [ "$rc" -eq 0 ] && [ -n "$line" ]; then
    pass "71 ledger_payloads: ${line#ledger_payloads: }"
  else
    grep -E '^  FAIL' <<< "$out" | head -20 | sed 's/^/    /' >&2
    fail "71 ledger_payloads: ${line:-the checks did not finish} (run test/ledger_payloads.py)"
  fi
}

# 72 kit_mutation: the demo kits' own statements, with one literal argument replaced at a time by an awkward value; nothing may crash.
# The kits run against the pure-C band, the same artifact the other python-driven gates load.
gate_72() {
  if [ ! -f "$HERE/test/kit_mutation.py" ]; then skip "72 kit_mutation (no test/kit_mutation.py)"; return; fi
  if ! command -v python3 >/dev/null 2>&1; then skip "72 kit_mutation (needs python3)"; return; fi
  # The kits run in-process (the pip duckdb module hosting the extension in each worker process), so a sanitizer
  # cell skips them: the pip host is not instrumentable, the same reason gates 12 and 25 skip there.
  if [ -n "$SAN_MODE" ]; then skip "72 kit_mutation (the in-process pip-duckdb host cannot be instrumented; skipped in ${SAN_MODE} cell)"; return; fi
  if ! ls "$HERE"/dist/*/fractalsql.capi.*.duckdb_extension >/dev/null 2>&1; then
    if ! nice make -C "$HERE" -s >/dev/null 2>&1; then fail "72 kit_mutation: the extension did not build"; return; fi
  fi
  # The pip-hosted gates degrade to a clean skip when the package is absent (gates 12 and 25), so a wheel
  # resolution failure -- as in a cell the workflow does not install it in -- is not a failing assertion.
  if [ -z "$PY" ]; then skip "72 kit_mutation: python with the pip duckdb package is unavailable (set FSQL_PYTHON)"; return; fi
  if [ -n "$PY_DUCKDB_MAJOR" ] && [ "$PY_DUCKDB_MAJOR" != "${DUCKDB_MAJOR:-1}" ]; then
    skip "72 kit_mutation: the pip duckdb package is ${PY_DUCKDB_MAJOR}.x but the CLI under test is ${DUCKDB_MAJOR:-1}.x (the driver cannot read this engine's database file nor load its extension)"
    return
  fi
  local ext out rc line
  # The runner's own resolver, not a glob: it asks the CLI under test which
  # DuckDB it is and takes that band's cell, so the gate cannot load a stale
  # artifact from another platform's or another build's directory (the glob
  # picks dist/cov's coverage band, which is older than the source). An
  # FSQL_EXT the run named itself (a --gate or --coverage cell) wins.
  ext="$(resolve_ext)"
  if [ -n "${FSQL_EXT:-}" ] && [ -f "$FSQL_EXT" ]; then ext="$FSQL_EXT"; fi
  out="$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS FSQL_BT_EXT="$ext" \
        nice python3 -I "$HERE/test/kit_mutation.py" 2>&1)"; rc=$?
  line="$(grep -E '^kit mutation: ' <<< "$out" | tail -1)"
  if [ "$rc" -eq 0 ] && [ -n "$line" ]; then
    pass "72 kit_mutation: ${line#kit mutation: } (every kit statement with an awkward argument: no crash)"
  else
    printf '%s\n' "$out" | tail -8 | sed 's/^/    /' >&2
    fail "72 kit_mutation: ${line:-the checks did not finish} (run test/kit_mutation.py)"
  fi
}

# 73 scripted_replies: the extension against a model that answers exactly what the test scripts: the reply is handed back as the model
# wrote it, and the embedding tier takes a vector in every shape the parser takes or refuses.
gate_73() {
  if [ ! -f "$HERE/test/scripted_replies.py" ]; then skip "73 scripted_replies (no test/scripted_replies.py)"; return; fi
  if ! command -v python3 >/dev/null 2>&1; then skip "73 scripted_replies (needs python3)"; return; fi
  if ! ls "$HERE"/dist/*/fractalsql.capi.*.duckdb_extension >/dev/null 2>&1; then
    if ! nice make -C "$HERE" -s >/dev/null 2>&1; then fail "73 scripted_replies: the extension did not build"; return; fi
  fi
  local ext out rc line
  # The runner's own resolver, not a glob: it asks the CLI under test which
  # DuckDB it is and takes that band's cell, so the gate cannot load a stale
  # artifact from another platform's or another build's directory (the glob
  # picks dist/cov's coverage band, which is older than the source).
  ext="$(resolve_ext)"
  out="$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS FSQL_BT_EXT="$ext" \
        nice python3 -I "$HERE/test/scripted_replies.py" 2>&1)"; rc=$?
  line="$(grep -E '^scripted_replies: ' <<< "$out" | tail -1)"
  if [ "$rc" -eq 0 ] && [ -n "$line" ]; then
    pass "73 scripted_replies: ${line#scripted_replies: } (the model answers exactly what the test scripts)"
  else
    grep -E '^  FAIL' <<< "$out" | head -20 | sed 's/^/    /' >&2
    fail "73 scripted_replies: ${line:-the checks did not finish} (run test/scripted_replies.py)"
  fi
}

# 68 rename: the two-argument fractal_search was renamed fractal_sfs_converge. The old names are refused, and the refusal names the new
# one: there are no aliases.
gate_68() {
  local ext out
  # The runner's own resolver, not a glob: it asks the CLI under test which
  # DuckDB it is and takes that band's cell, so the gate cannot load a stale
  # artifact from another platform's or another build's directory (the glob
  # picks dist/cov's coverage band, which is older than the source).
  ext="$(resolve_ext)"
  [ -n "$ext" ] || { skip "68 rename (the extension is not built)"; return; }
  out="$(printf "LOAD '%s';\nSELECT fractal_search([1.0,0.1]::DOUBLE[], [1.0,0.1]::DOUBLE[]);\n" "$ext" | "$DUCKDB" -batch -unsigned 2>&1)"
  if grep -q "renamed fractal_sfs_converge" <<< "$out"; then
    pass "68 rename: fractal_search(vector, query) is refused and the refusal names fractal_sfs_converge"
  else
    printf '%s\n' "$out" | tail -5 | sed 's/^/    /' >&2; fail "68 rename: fractal_search(vector, query) was not refused"
  fi
  out="$(printf "LOAD '%s';\nSELECT fractal_sfs_converge([1.0,0.1]::DOUBLE[], [1.0,0.1]::DOUBLE[]);\n" "$ext" | "$DUCKDB" -batch -unsigned 2>&1)"
  if grep -qi "error" <<< "$out"; then
    printf '%s\n' "$out" | tail -5 | sed 's/^/    /' >&2; fail "68 rename: fractal_sfs_converge: $out"
  else
    pass "68 rename: fractal_sfs_converge(vector, query) answers"
  fi
}

# 69 ledger_env: the ledger's environment configuration. The retention mode is read from the environment, and a value that is neither
# fade nor exact is refused.
gate_69() {
  local ext out
  # The runner's own resolver, not a glob: it asks the CLI under test which
  # DuckDB it is and takes that band's cell, so the gate cannot load a stale
  # artifact from another platform's or another build's directory (the glob
  # picks dist/cov's coverage band, which is older than the source).
  ext="$(resolve_ext)"
  [ -n "$ext" ] || { skip "69 ledger_env (the extension is not built)"; return; }
  out="$(printf "LOAD '%s';\nSELECT fractal_config_set('ledger_retention','exact');\n" "$ext" | "$DUCKDB" -batch -unsigned 2>&1)"
  if grep -qi "error" <<< "$out"; then
    printf '%s\n' "$out" | tail -5 | sed 's/^/    /' >&2; fail "69 ledger_env: the exact retention mode was refused: $out"
  else
    pass "69 ledger_env: the exact retention mode is accepted"
  fi
  out="$(printf "LOAD '%s';\nSELECT fractal_config_set('ledger_retention','sometimes');\n" "$ext" | "$DUCKDB" -batch -unsigned 2>&1)"
  if grep -q "must be one of" <<< "$out"; then
    pass "69 ledger_env: a retention mode that is neither fade nor exact is refused"
  else
    printf '%s\n' "$out" | tail -5 | sed 's/^/    /' >&2; fail "69 ledger_env: a bad retention mode was not refused: $out"
  fi
}

# 70 redact_unit: the audit-redaction header at the storage seam (test/redact_unit.c): the hash and truncate modes, the buffer limits and
# every JSON-special character.
gate_70() {
  local cc="${FSQL_CC:-cc}"
  command -v "$cc" >/dev/null 2>&1 || { skip "70 redact_unit (no C compiler on PATH)"; return; }
  [ -f "$HERE/test/redact_unit.c" ] || { skip "70 redact_unit (no test/redact_unit.c)"; return; }
  local log="$PDIR/redact_unit_build.log" bin="$PDIR/redact_unit"
  if ! env -u LD_PRELOAD "$cc" -std=c11 -O1 -g -Wno-unused-function -I"$HERE/src" -c "$HERE/test/redact_unit.c" -o "$PDIR/redact_unit.o" >"$log" 2>&1 \
     || ! env -u LD_PRELOAD "$cc" "$PDIR/redact_unit.o" -o "$bin" >>"$log" 2>&1; then
    tail -5 "$log" | sed 's/^/    /' >&2; fail "70 redact_unit: the unit test did not build"; return
  fi
  local out rc
  out="$(env -u LD_PRELOAD "$bin" 2>&1)"; rc=$?
  rm -f "$PDIR/redact_unit.o" "$bin"
  if [ "$rc" -eq 0 ]; then pass "70 redact_unit: $(tail -1 <<< "$out")"
  else printf '%s\n' "$out" | tail -12 | sed 's/^/    /' >&2; fail "70 redact_unit: see the output above"; fi
}

# 67 id_emission: how the domain agents write a row's id into their JSON result (test/id_emission.py). The id column is the caller's
# data, so what an agent writes must never become JSON structure and must never be altered: an id is written as a JSON number only when
# the whole text is one, otherwise as a string carrying the text exactly.
gate_67() {
  if [ ! -f "$HERE/test/id_emission.py" ]; then skip "67 id_emission (no test/id_emission.py)"; return; fi
  if ! command -v python3 >/dev/null 2>&1; then skip "67 id_emission (needs python3)"; return; fi
  if ! ls "$HERE"/dist/*/fractalsql.capi.*.duckdb_extension >/dev/null 2>&1; then
    if ! nice make -C "$HERE" -s >/dev/null 2>&1; then fail "67 id_emission: the extension did not build"; return; fi
  fi
  local out rc line
  out="$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES -u ASAN_OPTIONS -u UBSAN_OPTIONS nice python3 -I "$HERE/test/id_emission.py" 2>&1)"; rc=$?
  line="$(grep -E '^id_emission: ' <<< "$out" | tail -1)"
  if [ "$rc" -eq 0 ] && [ -n "$line" ]; then
    pass "67 id_emission: ${line#id_emission: }"
  else
    grep -E '^  FAIL' <<< "$out" | head -20 | sed 's/^/    /' >&2
    fail "67 id_emission: ${line:-the checks did not finish} (run test/id_emission.py)"
  fi
}

# 66 feature_store: fractal_store_morphology / fractal_mine_topology_negatives -- the named per-doc_id vector store (a plain table, created on first use):
# an upsert (last writer wins), true Euclidean nearest-first mining, a DOUBLE[] or a text vector, other dimensions skipped, bad input refused.
gate_66() {
  local r
  r=$(sqlq \
    "SELECT fractal_store_morphology(1, '[1,0,0]');" \
    "SELECT fractal_store_morphology(2, '0.9,0.1,0');" \
    "SELECT fractal_store_morphology(3, [0.0,1.0,0.0]::DOUBLE[]);" \
    "SELECT fractal_store_morphology(2, '0.8,0.2,0');" \
    "SELECT fractal_store_morphology(9, '[1,1]');" \
    "SELECT 'M1=' || (fractal_mine_topology_negatives('[1,0,0]', 2)::JSON->>'\$[1].doc_id') || ',' || json_array_length(fractal_mine_topology_negatives('[1,0,0]', 2)::JSON);" \
    "SELECT 'M2=' || json_array_length(fractal_mine_topology_negatives([0.0,1.0,0.0]::DOUBLE[], 10)::JSON);" \
    "SELECT 'M3=' || (fractal_mine_topology_negatives([0.0,1.0,0.0]::DOUBLE[], 3)::JSON->>'\$[0].doc_id');" \
    "SELECT 'M4=' || fractal_mine_topology_negatives('[1,0,0,0]', 3);" \
    "SELECT 'M5=' || round((fractal_mine_topology_negatives('[1,0,0]', 2)::JSON->>'\$[1].distance')::DOUBLE, 6);"); rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$r" | grep -qF "M1=2,2" && printf '%s' "$r" | grep -qF "M2=3" && printf '%s' "$r" | grep -qF "M3=3" \
     && printf '%s' "$r" | grep -qF "M4=[]" && printf '%s' "$r" | grep -qF "M5=0.282843"; then
    pass "66 feature_store: store is an upsert (the second write of doc 2 wins), mine is nearest-first Euclidean, a DOUBLE[] works, other dimensions are skipped"
  else
    fail "66 feature_store: got '$r'"
  fi
  r=$(sqlq "SELECT fractal_mine_topology_negatives('[1,0,0]', 0);" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && printf '%s' "$r" | grep -qF "k must be > 0" && pass "66 feature_store: k must be positive" || fail "66 feature_store: k=0 not refused: $r"
  r=$(sqlq "SELECT fractal_store_morphology(-1, '[1]');" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && printf '%s' "$r" | grep -qF "doc_id must be >= 0" && pass "66 feature_store: a negative doc_id is refused" || fail "66 feature_store: negative doc_id not refused: $r"
  r=$(sqlq "SELECT fractal_store_morphology(1, '[1,2,3]');" "SELECT count(*) FROM fractalsql_feature_store;" "SELECT fractal_store_morphology(NULL, '[1]');" 2>&1 | tr '\n' ' ')
  printf '%s' "$r" | grep -qE "ok +[0-9]+ +NULL" && pass "66 feature_store: the store is a plain table (fractalsql_feature_store) and a NULL doc_id answers NULL" || fail "66 feature_store: table/NULL: $r"
}

# 62 lakehouse: demo/demo-lakehouse-ducklake.sql and demo/demo-lakehouse-iceberg.sql run start to finish against the fixtures
# this gate writes under a private LAKE_DIR (the docker demo's lake-fixture / ducklake-fixture services write the same ones).
# Skips, naming what is missing, when DuckDB cannot download the ducklake / iceberg extensions (no network) or python3 has no
# pyiceberg + pyarrow + sqlalchemy for the Iceberg writer.
gate_62() {
  local lake kdir kf out rc ran=0
  lake="$(mktemp -d "${TMPDIR:-/tmp}/fsql_lake_XXXXXX")"; mkdir -p "$lake/ducklake"
  kdir="$(mktemp -d "${TMPDIR:-/tmp}/fsql_lakedir_XXXXXX")"
  kf="$(mktemp "${TMPDIR:-/tmp}/fsql_lake_XXXXXX.sql")"
  local lakew; lakew="$(wpath "$lake")"
  # --- DuckLake
  if out="$(cd "$lake" && LAKE_DIR="$lakew" "$DUCKDB" -unsigned < "$HERE/demo/lakehouse/make_ducklake_fixture.sql" 2>&1)"; then
    { printf "LOAD '%s';\n" "$EXTW"; cat "$HERE/demo/demo-lakehouse-ducklake.sql"; } > "$kf"
    rc=0; out="$(cd "$kdir" && env LAKE_DIR="$lakew" $(kit_env | tr '\n' ' ') "$DUCKDB" -batch -list -noheader -unsigned -separator '|' < "$kf" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ] && ! grep -qE '^[A-Za-z ]*Error: ' <<< "$out" && grep -q '"intercepted":true' <<< "$out" && grep -q '"intercepted":false' <<< "$out"; then
      pass "62 lakehouse: demo-lakehouse-ducklake.sql reads the DuckLake table and its screen intercepts the outage state and lets the healthy one through"
    else
      grep -E 'Error' <<< "$out" | head -5 | sed 's/^/    /' >&2; fail "62 lakehouse: demo-lakehouse-ducklake.sql (exit $rc)"
    fi
    ran=1
  else
    skip "62 lakehouse: the DuckLake fixture could not be written (DuckDB downloads the ducklake extension): ${out:0:120}"
  fi
  # --- Iceberg
  if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import pyiceberg, pyarrow, sqlalchemy' >/dev/null 2>&1; then
    skip "62 lakehouse: the Iceberg demo needs python3 with pyiceberg, pyarrow and sqlalchemy for its fixture writer"
  elif ! out="$(cd "$lake" && LAKE_DIR="$lakew" python3 "$HERE/demo/lakehouse/make_iceberg_fixture.py" 2>&1)"; then
    fail "62 lakehouse: the Iceberg fixture writer failed: ${out: -200}"
  else
    { printf "LOAD '%s';\n" "$EXTW"; cat "$HERE/demo/demo-lakehouse-iceberg.sql"; } > "$kf"
    rc=0; out="$(cd "$kdir" && env LAKE_DIR="$lakew" $(kit_env | tr '\n' ' ') "$DUCKDB" -batch -list -noheader -unsigned -separator '|' < "$kf" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ] && ! grep -qE '^[A-Za-z ]*Error: ' <<< "$out" && grep -q '"intercepted":true' <<< "$out" && grep -q '"intercepted":false' <<< "$out"; then
      pass "62 lakehouse: demo-lakehouse-iceberg.sql reads the Iceberg table and its screen intercepts the outage state and lets the healthy one through"
    else
      grep -E 'Error' <<< "$out" | head -5 | sed 's/^/    /' >&2; fail "62 lakehouse: demo-lakehouse-iceberg.sql (exit $rc)"
    fi
    ran=1
  fi
  rm -rf "$lake" "$kdir" "$kf"
  return 0
}

gate_body() {
  case "$1" in
    01) gate_01 ;;
    02) gate_02 ;;
    03) gate_03 ;;
    04) gate_04 ;;
    05) gate_05 ;;
    06) gate_06 ;;
    07) gate_07 ;;
    08) gate_08 ;;
    09) gate_09 ;;
    10) gate_10 ;;
    11) gate_11 ;;
    12) gate_12 ;;
    13) gate_13 ;;
    14) gate_14 ;;
    15) gate_15 ;;
    16) gate_16 ;;
    17) gate_17 ;;
    18) gate_18 ;;
    19) gate_19 ;;
    20) gate_20 ;;
    21) gate_21 ;;
    22) gate_22 ;;
    23) gate_23 ;;
    24) gate_24 ;;
    25) gate_25 ;;
    26) gate_26 ;;
    27) gate_27 ;;
    28) gate_28 ;;
    29) gate_29 ;;
    30) gate_30 ;;
    31) gate_31 ;;
    32) gate_32 ;;
    33) gate_33 ;;
    34) gate_34 ;;
    35) gate_35 ;;
    36) gate_36 ;;
    37) gate_37 ;;
    38) gate_38 ;;
    39) gate_39 ;;
    40) gate_40 ;;
    41) gate_41 ;;
    42) gate_42 ;;
    43) gate_43 ;;
    45) gate_45 ;;
    46) gate_46 ;;
    47) gate_47 ;;
    48) gate_48 ;;
    49) gate_49 ;;
    50) gate_50 ;;
    51) gate_51 ;;
    52) gate_52 ;;
    53) gate_53 ;;
    54) gate_54 ;;
    55) gate_55 ;;
    56) gate_56 ;;
    57) gate_57 ;;
    58) gate_58 ;;
    59) gate_59 ;;
    60) gate_60 ;;
    61) gate_61 ;;
    62) gate_62 ;;
    63) gate_63 ;;
    64) gate_64 ;;
    65) gate_65 ;;
    66) gate_66 ;;
    67) gate_67 ;;
    68) gate_68 ;;
    69) gate_69 ;;
    70) gate_70 ;;
    71) gate_71 ;;
    72) gate_72 ;;
    73) gate_73 ;;
  esac
}

gate_name() {
  case "$1" in
    01) echo "build" ;;
    02) echo "smoke" ;;
    03) echo "schema_context" ;;
    04) echo "text_to_sql" ;;
    05) echo "evil_overread" ;;
    06) echo "crash_recovery" ;;
    07) echo "evil_lying_length" ;;
    08) echo "authz" ;;
    09) echo "path_security" ;;
    10) echo "dos_and_injection" ;;
    11) echo "scout" ;;
    12) echo "soak" ;;
    13) echo "siu_mode" ;;
    14) echo "retry" ;;
    15) echo "embed" ;;
    16) echo "embed_authz" ;;
    17) echo "embed_soak" ;;
    18) echo "embed_crash" ;;
    19) echo "sfs_bounds" ;;
    20) echo "api_func" ;;
    21) echo "fuzz_smoke" ;;
    22) echo "new_primitives" ;;
    23) echo "agents" ;;
    24) echo "enterprise" ;;
    25) echo "enterprise_stress" ;;
    26) echo "enterprise_signature" ;;
    27) echo "think" ;;
    28) echo "review_isolation" ;;
    29) echo "domain_agents" ;;
    30) echo "feature_store" ;;
    31) echo "ledger_chain" ;;
    32) echo "enterprise_signature_real" ;;
    33) echo "tsan_ledger_concurrent" ;;
    34) echo "kits" ;;
    35) echo "mcp_probes" ;;
    36) echo "mcp_smoke" ;;
    37) echo "mcp_https" ;;
    38) echo "mcp_cli" ;;
    39) echo "mcp_db_probe" ;;
    40) echo "mcp_concurrency_probe" ;;
    41) echo "mcp_faults" ;;
    42) echo "mcp_fuzz" ;;
    43) echo "recall_hybrid_filter" ;;
    45) echo "mcp_conformance" ;;
    46) echo "capi_matrix" ;;
    47) echo "capi_parity" ;;
    48) echo "capi_sanitize" ;;
    49) echo "capi_lifecycle" ;;
    50) echo "plugin_sig_vendored" ;;
    51) echo "capi_lifecycle_san" ;;
    52) echo "fuzz_parse" ;;
    53) echo "capi_edge" ;;
    54) echo "error_table" ;;
    55) echo "ledger_integrity" ;;
    56) echo "capi_oom" ;;
    57) echo "capi_oom_full" ;;
    58) echo "mcp_audit_http" ;;
    59) echo "audit_regress" ;;
    60) echo "precision" ;;
    61) echo "index" ;;
    62) echo "lakehouse" ;;
    63) echo "enterprise_core" ;;
    64) echo "unicode" ;;
    65) echo "partial_reasoning" ;;
    66) echo "feature_store" ;;
    67) echo "id_emission" ;;
    68) echo "rename" ;;
    69) echo "ledger_env" ;;
    70) echo "redact_unit" ;;
    71) echo "ledger_payloads" ;;
    72) echo "kit_mutation" ;;
    73) echo "scripted_replies" ;;
    *) echo "" ;;
  esac
}

run_gate() {
  local g="$1"
  local title; title="$(gate_name "$g")"
  if [ -z "$title" ]; then
    fail "unknown gate \"$g\""
    return
  fi
  gate_title "$g" "$title"
  GATES_RAN=$((GATES_RAN + 1))
  local t0=$SECONDS
  gate_body "$g"
  local dt=$((SECONDS - t0))
  [ "$dt" -gt 0 ] && printf '   (gate %s took %ss)\n' "$g" "$dt"
}

main() {
  if [ -n "$ONE_KIT" ]; then
    # One kit, printed: the authoring aid for a kit's HEADLINE
    # predicate. The kit runs under the same mock-plugin environment
    # gate 34 sets up, so what it prints here is what the gate sees.
    find_toolchain
    if [ -z "$EXTW" ]; then
      if [ -n "${FSQL_EXT:-}" ]; then
        [ -f "$FSQL_EXT" ] || die "FSQL_EXT=$FSQL_EXT does not exist"
        EXT="$FSQL_EXT"
      else
        EXT="$(resolve_ext)"
      fi
      [ -n "$EXT" ] || die "no fractalsql.*.duckdb_extension under dist/ (run build.sh first, or set FSQL_EXT)"
      EXTW="$(wpath "$EXT")"
    fi
    PDIR="$BTROOT/fractalsql_bt_$$"
    PDIRW="$PDIR"
    if [ "${IS_MSYS}" = 1 ]; then
      PDIRW="$(cygpath -w "$PDIR")"
      PDIRSEP='\'
    fi
    compile_plugins
    MOCK="$(pj mock_reasoning_plugin)"
    run_vertical_kit "$ONE_KIT"
    return
  fi
  if [ -n "${LIST_ONLY:-}" ]; then
    local g
    for g in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 \
             21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66; do
      printf '  %s  %s\n' "$g" "$(gate_name "$g")"
    done
    exit 0
  fi
  # The fixture files under $BTROOT are shared by every run of this host (and
  # of the hosts that use the same mock plugin), so only one run may have them
  # at a time. Taken before anything reads or writes them.
  if ! acquire_run_lock; then
    die "another build_test run is holding $LOCKDIR -- the fixture files under $BTROOT are shared, so only one run at a time; wait for the other run to finish (held by $(cat "$LOCKDIR/owner" 2>/dev/null || echo "an unknown run"))"
  fi

  find_toolchain

  PDIR="$BTROOT/fractalsql_bt_$$"
  PDIRW="$PDIR"
  if [ "${IS_MSYS}" = 1 ]; then
    PDIRW="$(cygpath -w "$PDIR")"
    PDIRSEP='\'
  fi
  DB="$PDIR/bt.db"
  DBW="$(wpath "$DB")"
  SQLTXTW="$(wpath "$SQLTXT")"
  EVILTRIGW="$(wpath "$EVILTRIG")"
  RETRYPROMPTW="$(wpath "$RETRYPROMPT")"
  THINKDUMPW="$(wpath "$THINKDUMP")"
  REVIEWDUMPW="$(wpath "$REVIEWDUMP")"
  BADPLUGIN="$BTROOT/fractalsql_bt_nonexistent_plugin$PLUGSUF"
  BADLIB="$BTROOTW/fractalsql_bt_nonexistent_enterprise$PLUGSUF"

  compile_plugins
  # the plugin env vars carry native-form paths
  MOCK="$(pj mock_reasoning_plugin)"
  MOCKEMB="$(pj mock_embed_plugin)"
  RETRYPLUG="$(pj retry_reasoning_plugin)"
  THINKPLUG="$(pj think_reasoning_plugin)"
  EVILNT="$(pj evil_nonterminating_plugin)"
  CRASHPLUG="$(pj evil_crash_plugin)"
  EVILLEN="$(pj evil_lying_length_plugin)"
  EVOLEMB="$(pj evil_embed_plugin)"

  local -a to_run=()
  if [ -n "$MCP_ALIAS" ]; then
    to_run=(35 36 37 38 39 40 58)      # --gate mcp: the MCP server gates only (42 is --fuzz only,
                                       # 41 is a fault gate: --gate mcp --fault adds it)
    [ "$FAULT" = 1 ] && to_run+=(41)
  elif [ -n "$ONE_GATE" ]; then
    to_run=("$ONE_GATE")
  elif [ "$MCP_KIND" = tsan ] || [ "$MCP_KIND" = cov ]; then
    to_run=(35 36 37 38 39 40 58)       # --tsan / --coverage: the MCP server gates only
  elif [ "$MODE" = "quick" ]; then
    to_run=(01 02)
  elif [ "$MODE" = "fuzz" ]; then
    to_run=(21 42 52)
  else
    to_run=(01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 \
            22 23 24 25 26 27 28 29 30 31 32 34 35 36 37 38 39 40 43 45 46 47 48 49 51 53 54 55 56 59 60 61 62 63 64 65 66 \
            67 68 69 70 71 72 73)
    [ "$FAULT" = 1 ] && to_run+=("${FAULT_GATES[@]}")
  fi

  # Every gate except 01 (locate) resolves the artifact itself, so a
  # run that does not include 01 -- a single-gate run, or the fuzz run
  # -- has to resolve it up front.
  local has01=0 g
  for g in "${to_run[@]}"; do [ "$g" = "01" ] && has01=1; done
  if [ "$has01" -eq 0 ] && [ -z "$EXTW" ]; then
    # FSQL_EXT names the artifact explicitly -- the only way to pick
    # between the artifacts of two DuckDB lines, which the loader's
    # own version check then has to agree with
    if [ -n "${FSQL_EXT:-}" ]; then
      [ -f "$FSQL_EXT" ] || die "FSQL_EXT=$FSQL_EXT does not exist"
      EXT="$FSQL_EXT"
    else
      EXT="$(resolve_ext)"
    fi
    [ -n "$EXT" ] || die "no fractalsql.*.duckdb_extension under dist/ (run build.sh first, or set FSQL_EXT)"
    EXTW="$(wpath "$EXT")"
  fi

  local banner banner_list g san_tag
  banner_list="$(printf '%s, ' "${to_run[@]}")"
  banner="${banner_list%, }"
  san_tag=""
  if [ -n "$SAN_MODE" ]; then
    san_tag=" [${SAN_MODE}-instrumented pair]"
  elif san_artifacts_instrumented; then
    san_tag=" [instrumented pair]"
  fi
  printf '\nfractalsql-ext build_test%s -- %s -- gates: %s\n' \
    "$san_tag" "$("$DUCKDB" --version 2>/dev/null | head -1)" "$banner"

  # Lowest I/O priority and a lower CPU priority for the whole run (children inherit both), so a heavy gate cannot starve the
  # host: on a shared-folder VM the starvation is what wedges the guest.
  command -v ionice >/dev/null 2>&1 && ionice -c3 -p $$ >/dev/null 2>&1
  renice -n 5 -p $$ >/dev/null 2>&1
  for g in "${to_run[@]}"; do
    load_guard
    # The sanitizer options have to be in the environment before the
    # first instrumented CLI process starts; the artifacts are only
    # known once gate 01 has located them, so this runs per gate.
    san_options
    # every gate except 01 (locate) runs on the shared fixture
    # database -- the fuzz gate included, whose closing assertion is
    # that nothing it fed the extension was executed
    if [ "$g" != "01" ] && [ -z "${SETUP_DONE:-}" ]; then
      bt_setup
      SETUP_DONE=1
    fi
    run_gate "$g"
    # A stale artifact makes every later gate test yesterday's binary against
    # today's source, so their results would say nothing about the code under
    # test. Stop here instead of reporting them.
    if [ "$STALE_ARTIFACT" -eq 1 ]; then
      printf '\n== ABORTED after gate 01: the extension artifact is older than src/, so the remaining gates would report on a stale binary. Rebuild (make, or --rebuild) and run again.\n'
      break
    fi
  done

  [ "$MCP_KIND" = cov ] && mcp_coverage_report
  # the MCP build tree (server, probes, logs) lives in a mktemp dir; remove it once its report has been printed
  # (only on a green run: a failure message points at logs inside it)
  [ "$FAILED" -eq 0 ] && [ -n "$MCP_WORK" ] && [ -d "$MCP_WORK" ] && rm -rf "$MCP_WORK"

  # --coverage: the extension's own sources, after the MCP report. test/coverage_run.sh builds the extension with gcov and
  # drives it. Plain --coverage runs the quick stages (build, gates 01-34, the error table and the ledger through SQL, the
  # header unit tests, report); with --fault it adds the heavy ones (parity corpus, edge matrix, lifecycle modes and the
  # allocation-failure sweep). It prints its own report and fails below 80% lines, functions or branches.
  if [ "$COVERAGE_ALL" -eq 1 ]; then
    if [ "$FAULT" -eq 1 ]; then
      covstages="build gates parity edge table unit lifecycle oom report"
      printf '\n== extension sources (src/*.c): gcov build driven by gates 01-34, parity, edge matrix, error table, unit tests, lifecycle, OOM sweep\n'
    else
      covstages="build gates table unit report"
      printf '\n== extension sources (src/*.c): gcov build driven by gates 01-34, error table, ledger through SQL, unit tests (quick; add --fault for parity, edge matrix, lifecycle and the OOM sweep)\n'
    fi
    if STAGES="$covstages" "$HERE/test/coverage_run.sh"; then pass "coverage: extension src/*.c at or above 80% for lines, functions and branches"
    else fail "coverage: extension src/*.c coverage run failed or is below 80% (see the report above)"; fi
  fi

  if [ "$FAILED" -eq 0 ]; then
    if [ "$COVERAGE_ALL" -eq 1 ]; then
      printf '\n== ALL GREEN: %s MCP gates plus the extension coverage run (gates 01-34, parity, edge, unit, lifecycle, OOM sweep), 0 failing assertions\n' "$GATES_RAN"
    else
      printf '\n== ALL GREEN: %s gates ran, 0 failing assertions\n' "$GATES_RAN"
    fi
  else
    printf '\n== FAILED: %s failing assertion(s) across %s gates\n' "$FAILED" "$GATES_RAN"
    exit 1
  fi
}

# --coverage: per-file line coverage of the MCP server sources, from the gates that ran against the gcov build. No
# floor: it shows what the MCP gates reach. (The extension has no gcov cell; see the --coverage note in the header.)
mcp_coverage_report() {
  if [ -z "$MCP_WORK" ] || ! find "$MCP_WORK/build" -name '*.gcda' 2>/dev/null | grep -q .; then
    skip "coverage: no MCP .gcda produced (no MCP gate ran against the gcov build)"; return
  fi
  command -v gcov >/dev/null 2>&1 || { skip "coverage: gcov is not on PATH"; return; }
  printf '\ncoverage (MCP server sources, gates 35-40; C++ exception edges not counted as branches):\n'
  python3 -I "$HERE/test/gcov_summary.py" "$MCP_WORK/build" 'src/[^/]+\.cpp$' 'probe|duckdb_exec' | grep -v '^TOTAL '
  pass "coverage: MCP server line, function and branch coverage reported above"
}

main
