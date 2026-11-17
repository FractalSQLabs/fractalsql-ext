#!/usr/bin/env pwsh
#
# fractalsql-ext build_test (PowerShell port) -- the 35-gate
# confidence harness.
#
# This is the Windows-native port of build_test.sh: the same gates,
# the same numbering, the same gate titles, the same CLI options, the
# same output shape ("  [PASS] ..." under "== Gate NN: title"). Run it
# with:  pwsh -File .\build_test.ps1
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
#   01  build            locate/validate the extension artifact (this
#                        harness deliberately does NOT build; use
#                        build.sh/docker or build_test.ps1's -Build for
#                        that once wired; gates only drive the artifact).
#                        In -Asan/-Ubsan: the instrumented extension (and
#                        the instrumented CLI that hosts it) are built
#                        natively into dist\windows-asan\ /
#                        dist\windows-ubsan\, plus an instrumentedness
#                        probe.
#   02  smoke            fractal_version()/fractal_edition() =
#                        2.0.0/"Community", fractal_search convergence,
#                        fractal_search_debug's best_point JSON
#   03  schema_context   fractal_schema_context(): PK / NOT NULL / FK
#                        rendering + 0-arg auto-discovery
#   04  text_to_sql      SELECT-only allowlist end to end: stacked,
#                        DDL, DELETE, modifying-CTE (a parse error by
#                        construction here), bad column (analyze
#                        failure), EXPLAIN tier; never executes
#   05  evil_overread    [SKIP on Windows] -- evil_nonterminating_plugin
#                        builds its guard page from mmap/mprotect
#                        (POSIX-only); no guard-page analog is wired in
#                        this harness
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
#                        tests\fuzz_corpus\: every mutant is fed to the
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
#   25  enterprise_stress  [skips without a vendored enterprise core;
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
#   30  feature_store    [SKIP] -- not implemented in the duckdb build
#   31  ledger_chain     the ledger's community-vs-enterprise gate
#                        posture: audit_log/flush/load gated,
#                        fractal_ledger_verify() runs with NO
#                        enterprise lib at all (chain state is
#                        in-memory per connect, so the storage-layer
#                        row surgery has no target and gate 26 owns
#                        the load boundary instead)
#   32  enterprise_signature_real  Ed25519 signature check: refusal cases
#   33  tsan_ledger_concurrent  [SKIP] -- MSVC has no ThreadSanitizer. The
#                        extension's TSan run is gate 51 of build_test.sh
#                        (Linux); the Asan cell exists here -- see -Asan
#   34  kits             the 15 newest demo\demo-vertical-*.sql starter kits
#                        (ev-battery .. rf-spectrum-sensing) each run start
#                        to finish in a fresh in-memory database against the
#                        mock reasoning plugin: zero SQL errors (one allowed
#                        for scenario-planning, whose plan_explore step needs
#                        an embedding endpoint), no NaN/inf, and the kit's
#                        headline result reproduced
#   35-43  the MCP server (mcp\), same numbers as build_test.sh: 35 mcp_probes (server build,
#                        vectors and sanitize probes), 36 mcp_smoke, 37 mcp_https, 38 mcp_cli,
#                        39 mcp_db_probe, 40 mcp_concurrency_probe, 41 mcp_faults (skipped: needs
#                        LD_PRELOAD), 42 mcp_fuzz (-Fuzz only; clang-cl), 43 recall_hybrid_filter.
#                        Built by mcp\scripts\windows\build.bat against libduckdb-windows-amd64
#                        (FSQL_LIBDUCKDB_DIR, or fetched). -Gate mcp runs 35-41.
#   44  shipped_http_plugin  (Windows only; was 35) the SHIPPED HTTP reasoning plugin (the
#                        fractalsql-reasoning-http binary under include\)
#                        driven against a local HTTP stub: the chat tier
#                        answers, and -- the decisive part -- a run
#                        configured ONLY with the embed endpoint still
#                        reaches the plugin, because the tier's endpoint
#                        override has to land in the plugin's own C
#                        runtime's environment. The mock fixtures in
#                        tests\ read no environment at all, so no other
#                        gate can catch a regression there.
#   47  fuzz_parse        (-Fuzz only) libFuzzer over the extension's OWN
#                        parser for a model's reply (src\fsql_parse.c): the
#                        reply is untrusted input, so the code that turns it
#                        into SQL is attack surface. The target carries no
#                        DuckDB, so the gate needs nothing but a
#                        libFuzzer-capable clang.
#   53  capi_edge        test\edge_inputs.py, default environment: every
#                        registered function x awkward arguments; no crash and
#                        no DuckDB INTERNAL error. Needs a python (stdlib only)
#                        and a gcc-style compiler (FSQL_CC) for the mock plugins.
#   54  error_table      test\error_table.py: a table of calls, each with the
#                        outcome it must produce (message, value or NULL).
#   55  ledger_integrity test\ledger_unit.c (the ledger store and its verifier:
#                        chains built by hand and damaged in every way the check
#                        must notice, the size cap, the anchor log) compiled with
#                        the gcc-style compiler, and test\ledger_sql.py (the
#                        ledger through SQL with the mock enterprise core).
#   56  capi_oom         [SKIP on Windows] allocation-failure sweep; it interposes
#   57  capi_oom_full    the allocator with LD_PRELOAD (Linux only).
#
# Gate sets:
#
#   (default)        01 02 03 .. 20 22 .. 32 34 35 (33 is Tsan-only and
#                                                   21/47 are Fuzz-only)
#   -Quick           01 02                     pre-push smoke
#   -Rebuild         (any set)                 rebuild the extension
#                                              first when the artifact
#                                              under dist\ is missing or
#                                              older than the sources --
#                                              gate 01 refuses a stale
#                                              artifact, and this
#                                              satisfies that guard in
#                                              one command
#                                              (scripts\windows\build.bat)
#   -Fuzz            21 42 47                  the seeded mutation fuzzer
#                                              over tests\fuzz_corpus\ --
#                                              FSQL_FUZZ_ITERS mutants
#                                              (default 120) and a
#                                              FSQL_FUZZ_TIME wall-clock
#                                              budget (default 60s)
#   -Asan            the default set against the natively built MSVC
#                                              /fsanitize=address
#                                              extension and the
#                                              instrumented CLI that
#                                              hosts it, in
#                                              dist\windows-asan\ --
#                                              gates 12/25 skip (the
#                                              pip-duckdb host is not
#                                              instrumented), any
#                                              sanitizer report in
#                                              captured CLI output
#                                              fails its gate, and
#                                              gates 06/18 are report-
#                                              exempt for their one
#                                              deliberate-crash call
#   -Ubsan           the default set against the clang-cl
#                                              -fsanitize=undefined
#                                              extension and its
#                                              instrumented CLI, in
#                                              dist\windows-ubsan\ --
#                                              same skip/exempt posture
#                                              as -Asan. The cell builds
#                                              the EXTENSION only: the
#                                              pure-C build has no
#                                              DuckDB-from-source path, so
#                                              the instrumented CLI has to
#                                              be in that directory already
#   -Kit <name>     run ONE vertical demo kit (demo\demo-vertical-<name>.sql)
#                    under the mock-plugin environment gate 34 uses and
#                    print its raw output. The authoring aid for a kit's
#                    HEADLINE predicate: run the kit, read what it
#                    prints, assert on that.
#
# Usage:
#
#   .\build_test.ps1              # full gate matrix
#   .\build_test.ps1 -Quick       # gates 01 02
#   .\build_test.ps1 -Gate 6      # one gate (leading zero optional)
#   .\build_test.ps1 -Kit ev-battery-lifecycle   # one kit, printed
#   .\build_test.ps1 -List        # print the gate matrix, exit 0
#   .\build_test.ps1 -Rebuild     # rebuild the extension first, if the
#                                 #   artifact under dist\ is missing or
#                                 #   older than the sources (gate 01
#                                 #   refuses a stale artifact; this
#                                 #   satisfies that guard in one command)
#   .\build_test.ps1 -Asan        # full matrix on the native MSVC ASan
#                                 #   build (rebuilds into
#                                 #   dist\windows-asan\; needs MSVC)
#   .\build_test.ps1 -Ubsan       # full matrix on the native clang-cl
#                                 #   UBSan build (rebuilds into
#                                 #   dist\windows-ubsan\; needs clang-cl)
#   .\build_test.ps1 -Fuzz        # gate 21 only: the seeded mutation
#                                 #   fuzzer over tests\fuzz_corpus\
#   .\build_test.ps1 -Fuzz -Asan  # the same fuzzer, with every mutant run
#                                 #   against the instrumented CLI and
#                                 #   extension (a sanitizer report on any
#                                 #   mutant fails the gate)
#
# Environment:
#
#   FSQL_DUCKDB              path to the duckdb CLI (default: PATH;
#                            with no duckdb on PATH the harness falls
#                            back to a release CLI under dist/, paired
#                            with the extension beside it)
#   FSQL_EXT                 explicit path to the built extension file
#                            (.duckdb_extension); otherwise resolved
#                            from dist/ (gate 01)
#   FSQL_CC                  cc/gcc/clang for the tests/*.c fixture
#                            plugins (default: PATH; probed in order)
#   FSQL_PYTHON              python3/python that has the pip `duckdb`
#                            package installed (default: PATH probe)
#   FSQL_PYTHON_ANY          python3/python for the stdlib-only HTTP stub
#                            gate 44 starts (default: PATH probe; no
#                            third-party package needed)
#   FSQL_HTTP_PLUGIN         path to the shipped HTTP reasoning plugin
#                            gate 44 drives (default: the copy under
#                            include\windows-x86_64\)
#   BTROOT                   override for the root the fixture plugins'
#                            hardcoded /tmp/... contracts resolve to.
#                            On Windows the plugins fopen the literal
#                            POSIX "/tmp/..." paths, which resolve to
#                            <process-drive>:\tmp -- so BTROOT stays
#                            pinned to <drive>:\tmp for the drive the
#                            harness is started from (the CWD's drive).
#   FSQL_TEST_TIMEOUT_MULT   scales the crash-recovery poll windows in
#                            gates 06/18 (default 1)
#   FSQL_EVIL_SQL_FILE       evil_nonterminating_plugin's canned SQL
#                            source (set automatically per gate)
#   FSQL_ASAN_OPTIONS        ASAN_OPTIONS forwarded to the native -Asan
#                            run in place of the harness default below
#                            (reports land on stderr, which sqlq
#                            captures and sweeps)
#   FSQL_ASAN_DETECT_LEAKS   0 turns LeakSanitizer off in the docker
#                            sanitizer cells (LSan needs ptrace there)
#   FSQL_UBSAN_OPTIONS       UBSAN_OPTIONS forwarded to the native
#                            -Ubsan run (default: print_stacktrace=1)
#   FSQL_FUZZ_ITERS          number of mutants gate 21 generates
#                            (default 120)
#   FSQL_FUZZ_TIMEOUT_MS     wall-clock budget for ONE mutant, in
#                            milliseconds (default 20000); a mutant
#                            that outruns it is killed and counted as
#                            a hang, not a crash
#   FSQL_FUZZ_TIME           wall-clock budget for gate 21, in seconds
#                            (default 60); the loop stops early when it
#                            is reached
#   FSQL_FUZZ_SEED           seed for the deterministic mutation PRNG
#                            (default 20260930; the same seed always
#                            produces the same mutants)
#   FSQL_FUZZ_CC             (unused here; kept for option parity)

#Requires -Version 5.1

param(
  [switch]$Quick,
  [switch]$Fuzz,
  [switch]$List,
  [string]$Gate,
  # -Rebuild rebuilds the extension before the gates when the artifact
  # under dist\ is missing or older than the sources. The staleness
  # guard in gate 01 exists so the gates can never test yesterday's
  # binary against today's source; this switch is the one-command way to
  # satisfy it instead of running scripts\windows\build.bat by hand
  # first. A fresh artifact is left alone, so the fast path stays fast.
  # A sanitizer cell is excluded (its own build produces the
  # instrumented artifact), and so is an artifact named by FSQL_EXT (the
  # build writes under dist\, not to that path).
  [switch]$Rebuild,
  # -Kit runs ONE vertical demo kit and prints its raw output, with
  # the same mock-plugin environment gate 34 sets up. It is the
  # authoring aid for a kit's HEADLINE predicate: run the kit, read
  # what it actually prints, and assert on that.
  [string]$Kit,
  [switch]$Help,
  # Asan runs the matrix natively (MSVC /fsanitize=address rebuild of
  # the extension via scripts\windows\build.bat). Ubsan runs it the
  # same way through clang-cl (-fsanitize=undefined). Both rebuild the
  # extension AND the DuckDB CLI that hosts it, because an ASan
  # runtime that is loaded after the process is already running is the
  # one order ASan refuses to work in. Tsan/Coverage stay
  # hard errors so the sh/ps1 CLI surfaces mirror.
  [switch]$Asan,
  [switch]$Ubsan,
  [switch]$Tsan,
  [switch]$Coverage
)

# ----------------------------------------------------------------
# Machinery: paths, state, output helpers.
# ----------------------------------------------------------------

$script:ESC = [char]27

# The fixture plugins fopen the literal "/tmp/..." paths, which a native Windows process resolves against ITS current drive,
# so the root has to sit on the drive the harness runs from (D: on GitHub's runners), not always on the system drive.
$script:BTROOT = (Join-Path ([System.IO.Path]::GetPathRoot((Get-Location).Path)) "tmp")
if (-not $script:BTROOT -or $script:BTROOT -notmatch '^[A-Za-z]:') { $script:BTROOT = "$($env:SystemDrive)\tmp" }
if (-not (Test-Path -LiteralPath $script:BTROOT)) { New-Item -ItemType Directory -Force $script:BTROOT | Out-Null }
if ($env:BTROOT -and -not ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)) {
  $script:BTROOT = $env:BTROOT
}

# The five hardcoded file contracts the C fixture plugins share with
# this script (the plugin sources fopen the literal "/tmp/..." paths,
# which drive-root-resolve under $BTROOT).
$script:SQLTXT      = Join-Path $script:BTROOT "fractalsql_bt_sql.txt"
$script:EVILTRIG    = Join-Path $script:BTROOT "fractalsql_bt_evil_trigger_call.txt"
$script:RETRYPROMPT = Join-Path $script:BTROOT "fractalsql_bt_retry_prompt.txt"
$script:THINKDUMP   = Join-Path $script:BTROOT "fractalsql_bt_think_dump.txt"
$script:REVIEWDUMP  = Join-Path $script:BTROOT "fractalsql_bt_review_env_dump.txt"
$script:REVIEWTXT  = Join-Path $script:BTROOT "fractalsql_bt_review.txt"
$script:REVIEWPROMPT = Join-Path $script:BTROOT "fractalsql_bt_review_prompt.txt"

# Mutable run state.
$script:PDIR        = ""
$script:PDIRSEP     = "\"
$script:EXT         = ""
$script:EXT_SLASH   = ""
$script:DB          = ""
$script:DUCK        = ""
$script:DUCK_ARGS   = @()
$script:DUCK_VER    = ""
$script:PY          = $null
$script:CC          = $null
$script:PLUGSUF     = ".dll"
$script:FAILED      = 0
$script:GATES_RAN   = 0
$script:SETUP_DONE  = $false
$script:SQLQ_OUT    = ""
$script:SQLQ_RC     = 0
$script:PY_RC       = 0
$script:T2S_ENV     = @()
$script:SAN_EXEMPT  = $false
$script:TIMEOUT_MULT = 1
if ($env:FSQL_TEST_TIMEOUT_MULT) {
  $script:TIMEOUT_MULT = [int]$env:FSQL_TEST_TIMEOUT_MULT
}

function cleanup {
  if ($script:PDIR) { Remove-Item -LiteralPath $script:PDIR -Recurse -Force -ErrorAction SilentlyContinue }
  foreach ($f in @($script:SQLTXT, $script:EVILTRIG, $script:RETRYPROMPT, $script:THINKDUMP, $script:REVIEWDUMP, $script:REVIEWTXT, $script:REVIEWPROMPT)) {
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
  }
}

# Output shape: "  [PASS] <label>" lines under one "== Gate NN: title"
# banner, so the two harness ports stay mirrorable.
function pass { param([string]$m) Write-Host ("  " + $script:ESC + "[0;32m[PASS]" + $script:ESC + "[0m " + $m) }
function fail {
  param([string]$m)
  $script:FAILED = $script:FAILED + 1
  Write-Host ("  " + $script:ESC + "[0;31m[FAIL]" + $script:ESC + "[0m " + $m)
}
function skip { param([string]$m) Write-Host ("  " + $script:ESC + "[0;36m[SKIP]" + $script:ESC + "[0m " + $m) }
function die {
  param([string]$m)
  [Console]::Error.WriteLine("build_test: " + $m)
  exit 2
}

function trunc { param($s, [int]$n = 300)
  if ($null -eq $s) { return "" }
  $t = [string]$s
  if ($t.Length -le $n) { return $t }
  return $t.Substring(0, $n)
}

# grep -qF analog: does $out contain the exact $want substring?
function out_has { param([string]$s, [string]$want)
  if ($null -eq $s) { return $false }
  return $s.Contains($want)
}

# ----------------------------------------------------------------
# Windows PowerShell 5.1 / PowerShell 7 compatibility.
#
# The harness runs on both hosts (#Requires -Version 5.1), so no code
# path may reach for an API that exists on only one of them. Two did:
#
#   ProcessStartInfo.ArgumentList -- a .NET Core collection. On 5.1
#   the property does not exist at all, so filling it dies with "You
#   cannot call a method on a null-valued expression". Windows
#   PowerShell gets the single Arguments string instead, quoted the
#   way CommandLineToArgvW expects.
#
#   Process.Kill(true) -- the .NET Core overload that kills the whole
#   process tree. On 5.1 the overload does not exist, so the call
#   throws, and when that happened inside the same try as the wait it
#   took WaitForExit down with it and left the HTTP stub holding its
#   port for the rest of the run.
# ----------------------------------------------------------------

# Quote one argument the way the Windows command line expects it: a
# run of backslashes before a quote doubles, and a trailing run of
# backslashes doubles so it does not escape the closing quote.
function quote_win_arg {
  param([string]$Arg)
  if ($null -eq $Arg) { return '""' }
  if ($Arg -notmatch '[\s"]') { return $Arg }
  $q = [regex]::Replace($Arg, '(\\*)"', '$1$1\"')
  $q = [regex]::Replace($q, '(\\+)$', '$1$1')
  return '"' + $q + '"'
}

# Append one argument to a ProcessStartInfo, whichever host we are on.
function add_proc_arg {
  param($Psi, [string]$Arg)
  if ($null -ne $Psi.PSObject.Properties["ArgumentList"]) {
    $Psi.ArgumentList.Add($Arg)
  } elseif ($Psi.Arguments) {
    $Psi.Arguments = $Psi.Arguments + " " + (quote_win_arg $Arg)
  } else {
    $Psi.Arguments = quote_win_arg $Arg
  }
}

# Native stderr captured with 2>&1 arrives as ErrorRecord objects, and
# the two hosts render them differently: PowerShell 7 prints the
# record's message, Windows PowerShell 5.1 prints a multi-line block
# ("prog.exe : msg", then the script position, the CategoryInfo and
# the FullyQualifiedErrorId). The gates parse that text -- numerify
# scrapes digits out of it, and an error-text match has to survive it
# -- so the rendering difference shows up as a gate failure that only
# happens on one host. Unwrapping every record to its message gives
# both hosts the same plain text.
#
# A filter, not a function: a function's parameters do not take
# pipeline input unless they say so, so a plain function here would
# silently swallow the whole capture.
filter plain_lines {
  if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message }
  else { [string]$_ }
}

# Stop a process and wait for it, killing the tree where the runtime
# supports it. The wait gets its own try: a failed kill must not leave
# the caller with a live child.
function stop_proc {
  param($Proc, [int]$TimeoutMs = 5000)
  if (-not $Proc) { return }
  try {
    if (-not $Proc.HasExited) {
      if ($null -ne $Proc.GetType().GetMethod("Kill", [type[]]@([bool]))) { $Proc.Kill($true) } else { $Proc.Kill() }
    }
  } catch { }
  try { $Proc.WaitForExit($TimeoutMs) | Out-Null } catch { }
}

# Sanitizer-run sweep: any sanitizer diagnostic in captured CLI output
# fails the invoking gate. Gates 06/18 opt out via SAN_EXEMPT for their
# single deliberate-crash call: an ASan-instrumented module turns the
# NULL deref into the runtime's report+exit instead of a raw exception
# status, and the gate's own "the process died" assertion covers that
# shape.
function san_report { param([string]$s)
  if ($null -eq $s) { return $false }
  return ($s -match 'AddressSanitizer|LeakSanitizer|UndefinedBehaviorSanitizer|runtime error\:')
}

# Print a sanitizer report in full. The gate messages truncate the CLI
# output, and a truncated ASan report is just a header: the stack is the
# part that says what happened.
function san_dump { param([string]$out)
  if ($null -eq $out) { return }
  foreach ($line in ($out -split "`r?`n")) {
    if ($line -ne "") { Write-Host ("      | " + $line) }
  }
}

# Env pairs for a deliberate-crash sqlq_env call (gates 06/18): under
# ASan, disable the runtime's segv handling for that invocation so the
# fixture dies with the raw exception status and the gate's crashed()
# assertion keeps its meaning -- the same handle_segv=0 opt-out the sh
# harness uses (verified honored by the MSVC runtime).
function san_crash_pairs {
  param([string[]]$ExtraPairs = @())
  $pairs = @()
  if ($script:SAN -eq "asan") {
    if ($env:ASAN_OPTIONS) { $a = $env:ASAN_OPTIONS + ":handle_segv=0" }
    else { $a = "handle_segv=0" }
    $pairs += "ASAN_OPTIONS=" + $a
  }
  return ($pairs + @($ExtraPairs))
}

# Decimal digits only (tr -cd '0-9' analog).
function numerify { param([string]$s)
  if ($null -eq $s) { return "" }
  return (-join (($s.ToCharArray()) | Where-Object { [char]::IsDigit($_) }))
}

# A non-throwing int parse for numerify's output: when the command under test printed an error message instead of a
# number, its digits (a pid in a path, a line number) concatenate into something that does not fit an Int32, and a
# bare [int] cast then aborts the whole run. -1 means "not a usable count"; every caller already treats that as a failure.
function to_int { param([string]$s)
  $v = 0L
  if ([long]::TryParse($s, [ref]$v) -and ($v -ge 0) -and ($v -le 2147483647)) { return [int]$v }
  return -1
}

# Invariant-culture numeric parse (awk's v+0==v analog) + abs < 1e-6.
function to_num { param([string]$s)
  try { return [double]::Parse($s.Trim(), [cultureinfo]::InvariantCulture) }
  catch { return [double]::NaN }
}
function num_abs_lt_1e6 { param([string]$s)
  $d = to_num ("" + $s)
  if ([double]::IsNaN($d)) { return $false }
  return ([math]::Abs($d) -lt 1e-6)
}

# expect_err <want> <rc> <output> <label>
#   rc must be nonzero (and not a crash) and output must contain want.
function expect_err {
  param([string]$want, [int]$rc, [string]$out, [string]$label)
  if ($script:SAN -and (-not $script:SAN_EXEMPT) -and (san_report $out)) {
    # the only path where a sanitizer report would otherwise ride a
    # nonzero rc to a pass
    fail ($label + " (sanitizer report in the error-path output)")
    Write-Host ("      rc=" + $rc + ": " + (trunc $out))
    san_dump $out
    return
  }
  if (crashed $rc) {
    fail $label
    Write-Host ("      expected error """ + $want + """, got rc=" + $rc + " (signal death): " + (trunc $out))
    return
  }
  if ($rc -eq 0) {
    fail $label
    Write-Host ("      expected error """ + $want + """, got rc=0: " + (trunc $out))
    return
  }
  if (out_has $out $want) { pass $label; return }
  fail $label
  Write-Host ("      expected error """ + $want + """, got rc=" + $rc + ": " + (trunc $out))
}

# expect_ok <rc> <output> <label> [<want>]
function expect_ok {
  param([int]$rc, [string]$out, [string]$label, [string]$want = "")
  if (crashed $rc) {
    fail $label
    Write-Host ("      rc=" + $rc + " (signal death): " + (trunc $out))
    return
  }
  if ($rc -ne 0) {
    fail $label
    Write-Host ("      rc=" + $rc + ": " + (trunc $out))
    if ($script:SAN -and (san_report $out)) { san_dump $out }
    return
  }
  if ($want -and -not (out_has $out $want)) {
    fail $label
    Write-Host ("      expected output containing """ + $want + """: " + (trunc $out))
    return
  }
  pass $label
}

# crashed <rc>: a signal death shows up as a high rc (128+N after a
# POSIX kill; the native NTSTATUS code, e.g. 0xC0000005, on Windows).
# POSIX signals land in [128, 255]; on Windows a crashed native process
# reports its NTSTATUS as a negative $LASTEXITCODE (e.g. -1073741819 =
# 0xC0000005 access violation).
function crashed { param([int]$rc) return (($rc -ge 128) -or ($rc -lt 0)) }

# expect_survive <rc> <output> <label>: the evil fixture must NOT kill
# the process; the exact returned/error payload is not asserted here.
function expect_survive {
  param([int]$rc, [string]$out, [string]$label)
  if (crashed $rc) {
    fail $label
    Write-Host ("      rc=" + $rc + " (signal death): " + (trunc $out))
    return
  }
  pass $label
}

# Write/read one of the five fixture contract files.
function wc_file { param([string]$path, [string]$content)
  [IO.File]::WriteAllText($path, $content + [Environment]::NewLine, [System.Text.Encoding]::ASCII)
}
function rc_file { param([string]$path)
  if (Test-Path -LiteralPath $path) { return [IO.File]::ReadAllText($path) }
  return "MISSING"
}

# Invariant-culture fixed-point formatting for fixture vectors.
function Fm { param([double]$v, [int]$dp)
  return [string]::Format([cultureinfo]::InvariantCulture, "{0:F" + $dp + "}", $v)
}

# ----------------------------------------------------------------
# Toolchain, artifact, CLI plumbing.
# ----------------------------------------------------------------

# probe the toolchain; python-with-duckdb is optional (gates 12/25).
# The interpreter for the python-side helpers. The pip `duckdb` package
# is needed by the drivers under tests/ but not by the stdlib-only HTTP
# stub, so the two are resolved separately: the first one gates the
# driver-backed gates (they skip cleanly when it is absent), the
# second one gates the shipped-plugin gate.
function resolve_python {
  param([switch]$NeedDuckdb)
  $cands = @()
  $explicit = if ($NeedDuckdb) { $env:FSQL_PYTHON } else { $env:FSQL_PYTHON_ANY }
  if ($explicit) { $cands += @(Get-Command $explicit -ErrorAction SilentlyContinue) }
  $cands += @(Get-Command python3 -ErrorAction SilentlyContinue)
  $cands += @(Get-Command python -ErrorAction SilentlyContinue)
  foreach ($c in $cands) {
    if (-not $c) { continue }
    # the Microsoft Store app-execution alias is a launcher, not an
    # interpreter: it prints an install hint and exits without running
    # anything, so probing it would look like a broken python.
    if ($c.Source -like "*\WindowsApps\*") { continue }
    if ($NeedDuckdb) {
      # the drivers require the pip duckdb package; probe and downgrade
      # to a clean [SKIP] when absent rather than failing late.
      $null = & $c.Source -c "import duckdb" 2>&1 | plain_lines
    } else {
      $null = & $c.Source -c "import sys; print(sys.version_info[0])" 2>&1 | plain_lines
    }
    if ($LASTEXITCODE -eq 0) { return $c.Source }
  }
  return $null
}

# The pip duckdb package is a separate build of the engine: the
# python-driver gates open the harness's database file with it and load
# the built extension into it, so it has to be the same DuckDB major as
# the CLI under test. A 1.x driver can neither read a 2.x database file
# (storage format) nor load a 2.x-built extension (ABI), so those gates
# are skipped -- loudly, and with the reason -- when the two majors
# differ.
function pip_duckdb_major {
  if (-not $script:PY) { return 0 }
  $v = (& $script:PY -c "import duckdb; print(duckdb.__version__)" 2>$null | Select-Object -First 1)
  if ($v -match '^(\d+)\.') { return [int]$Matches[1] }
  return 0
}

# A CLI under dist/ is a release build of the DuckDB line the
# extension sitting next to it targets, so the pair is what the
# harness should drive when PATH carries no duckdb at all. The pair
# matters: the loader refuses an extension built for a different
# DuckDB line, so a CLI and an extension from two different dist
# directories is a run that cannot work.
#
# The sanitizer cells' directories are excluded, for the same reason
# resolve_ext excludes them: those hold instrumented artifacts, not
# release ones.
#
# The pairing is CLI + extension, and the extension has to be one the CLI
# can actually LOAD. Two rules make that true:
#   - the pure-C extension only (the retired C++ artifact under the same
#     file-name pattern carries a different entry point and a different
#     plugin/enterprise signature vocabulary, so every plugin-backed gate
#     would fail against it);
#   - the C extension's stable band (fractalsql.capi.*) loads on every
#     DuckDB line from 1.5 up; the LTS band (fractalsql.v1.4.N.*) is
#     pinned to one exact 1.4.x and pairs only with that one.
#
# The two do NOT have to sit in the same directory: the C build stages
# its artifacts in dist\windows_amd64\ while the 2.0 CLI lives in
# dist\windows_amd64-200\. So the extension is searched across all of
# dist\, and the CLI is paired with the band that suits its version.
function resolve_dist_cli_pair {
  # Build directories that are not release artifacts: sanitizer, coverage, unit-test and lifecycle cells. The Linux
  # runs share this checkout and leave their own (linux_amd64) builds in some of them, e.g. dist\san-undefined.
  $sanDirs = @("asan", "ubsan", "windows-asan", "windows-ubsan", "cov", "unit", "lifecycle")
  $dirs = @(Get-ChildItem -Path "dist/*/duckdb.exe" -ErrorAction SilentlyContinue |
            Where-Object { $sanDirs -notcontains $_.Directory.Name -and $_.Directory.Name -notlike "san-*" } |
            Sort-Object LastWriteTime -Descending)
  # Every pure-C artifact under dist\, newest first.
  $allExt = @(Get-ChildItem -Path "dist/*/fractalsql.*.duckdb_extension" -ErrorAction SilentlyContinue |
              Where-Object { $sanDirs -notcontains $_.Directory.Name -and $_.Directory.Name -notlike "san-*" } |
              Where-Object { $_.Name -like "*.windows_amd64.duckdb_extension" } |
              Where-Object { ext_is_c_extension $_.FullName } |
              Sort-Object LastWriteTime -Descending)
  foreach ($d in $dirs) {
    $cliVer = ""
    $vline = (& $d.FullName --version 2>$null | Select-Object -First 1)
    if ($vline -match 'v(\d+\.\d+\.\d+)') { $cliVer = $Matches[1] }
    if ($cliVer -match '^1\.4\.') {
      # the LTS band is pinned to one exact 1.4.x: pair only with that one
      $lts = @($allExt | Where-Object { (ext_duck_version $_.FullName) -eq $cliVer })
      if ($lts.Count -eq 0) { continue }
      return @{ Cli = $d.FullName; Ext = $lts[0].FullName }
    }
    # the stable band serves every line from 1.5 up
    $stable = @($allExt | Where-Object { $_.Name -like "fractalsql.capi.*" })
    if ($stable.Count -gt 0) {
      return @{ Cli = $d.FullName; Ext = $stable[0].FullName }
    }
  }
  return $null
}

function find_toolchain {
  # A sanitizer cell brings its own instrumented CLI, and that CLI is
  # the one the instrumented extension must be hosted by: an
  # uninstrumented host loads the ASan runtime after the process is
  # already running, which is the order ASan refuses to work in. An
  # explicit FSQL_DUCKDB still wins -- it is how a caller points the
  # run at a specific build.
  if ($script:SAN -and (-not $env:FSQL_DUCKDB)) {
    # A sanitizer cell ALWAYS hosts the instrumented extension in the
    # cell's instrumented CLI -- also when FSQL_EXT named the artifact
    # (and so the cell was not built): an uninstrumented host would load
    # the ASan runtime after the process is already running, which is the
    # order ASan refuses to work in.
    $cellCli = $null
    if ($script:SAN_CELL -and $script:SAN_CELL.Cli) { $cellCli = $script:SAN_CELL.Cli }
    else { $cellCli = resolve_san_cli }
    if (-not $cellCli) {
      die ("-" + $script:SAN + " needs the instrumented CLI under " + (sanitize_out_dir $script:SAN) +
           " (the pure-C build has no DuckDB-from-source path)")
    }
    $script:DUCK = $cellCli
  } elseif ($env:FSQL_DUCKDB) {
    if (Test-Path -LiteralPath $env:FSQL_DUCKDB) { $script:DUCK = $env:FSQL_DUCKDB }
    else {
      $c = Get-Command $env:FSQL_DUCKDB -ErrorAction SilentlyContinue
      if (-not $c) { die "FSQL_DUCKDB=$env:FSQL_DUCKDB is not a duckdb CLI on PATH or a file" }
      $script:DUCK = $c.Source
    }
  } else {
    $c = Get-Command duckdb -ErrorAction SilentlyContinue
    if ($c) {
      $script:DUCK = $c.Source
    } else {
      # No duckdb on PATH: fall back to a release CLI under dist/, and
      # remember the extension beside it so the two stay paired.
      $pair = resolve_dist_cli_pair
      if (-not $pair) {
        die "no duckdb CLI on PATH (set FSQL_DUCKDB, or install one; see docs/getting-started.md)"
      }
      $script:DUCK = $pair.Cli
      $script:DUCK_PAIR_EXT = $pair.Ext
      Write-Host ("  no duckdb on PATH -- using the release CLI under dist/: " + $pair.Cli)
    }
  }
  $ok = $false
  $null = ("SELECT 1;" | & $script:DUCK -batch -unsigned 2>&1 | plain_lines)
  if ($LASTEXITCODE -eq 0) { $ok = $true }
  if (-not $ok) { die ($script:DUCK + " is not a working duckdb CLI") }

  # DuckDB 2.x's shell turns on an "agent mode" when it detects an agent
  # environment (AI_AGENT / CLAUDECODE and friends) and stdout is not a
  # terminal -- which is always the case here. The banner it prints goes
  # to stderr, so it stays out of the harness's parsed stdout, but
  # -no-agent silences it anyway.
  # 2.x takes -no-agent; 1.x has no such flag and no such banner.
  $script:DUCK_ARGS = @()
  $script:DUCK_MAJOR = 1
  # the full version ("2.0.0"), not just the major: the extension
  # artifact is pinned to a DuckDB line and the loader refuses a
  # mismatch, so the artifact choice needs the exact version. Every
  # line of --version is scanned, because the 2.x agent-mode banner
  # can share the output.
  $script:DUCK_VERSION = ""
  foreach ($vl in (& $script:DUCK --version 2>$null)) {
    if ($vl -match 'v(\d+)\.(\d+)\.(\d+)') {
      $script:DUCK_MAJOR = [int]$Matches[1]
      $script:DUCK_VERSION = ($Matches[1] + "." + $Matches[2] + "." + $Matches[3])
      break
    }
  }
  if ($script:DUCK_MAJOR -ge 2) { $script:DUCK_ARGS = @("-no-agent") }
  # The extension that came with the CLI from dist/ is only usable if it
  # was built for the CLI's own DuckDB line. A dist/ tree can hold
  # artifacts for two lines whose mtimes are a minute apart, so the
  # pairing is verified here and dropped when it does not hold; the
  # version-aware resolve_ext then picks the right artifact instead.
  if ($script:DUCK_PAIR_EXT) {
    $pev = ext_duck_version $script:DUCK_PAIR_EXT
    if ($script:DUCK_VERSION -and $pev -and ($pev -ne $script:DUCK_VERSION)) {
      Write-Host ("  the extension beside that CLI is for DuckDB v" + $pev +
                  " while the CLI is v" + $script:DUCK_VERSION + " -- re-resolving the artifact")
      $script:DUCK_PAIR_EXT = $null
    }
  }

  $script:CC = $null
  if ($env:FSQL_CC) {
    $c = Get-Command $env:FSQL_CC -ErrorAction SilentlyContinue
    if ($c) { $script:CC = $c.Source } else { die "FSQL_CC=$env:FSQL_CC is not on PATH" }
  } else {
    foreach ($ccname in @("cc", "gcc", "clang")) {
      $c = Get-Command $ccname -ErrorAction SilentlyContinue
      if ($c) { $script:CC = $c.Source; break }
    }
  }
  if (-not $script:CC) { die "no C compiler found for the tests/*.c fixture plugins (set FSQL_CC)" }

  $script:PY = resolve_python -NeedDuckdb
  $script:PYANY = resolve_python
}

# The DuckDB version an extension artifact was built for, taken from
# its file name: the release artifact is named
# fractalsql.v<duckdb-version>.<platform>.duckdb_extension, and the
# version in that name is the DuckDB line it was compiled against.
# Empty when the name carries no version tag (the un-versioned
# dist/amd64/fractalsql.duckdb_extension).
function ext_duck_version {
  param([string]$path)
  $leaf = Split-Path -Leaf $path
  if ($leaf -match '\.v(\d+\.\d+\.\d+)\.') { return $Matches[1] }
  return ""
}

# newest dist/ artifact wins; only called when FSQL_EXT is unset. The
# sanitizer cells (native dist\windows-asan\windows-ubsan and the docker
# dist/asan + dist/ubsan) are excluded from every resolution: they are
# not loadable in a release run (the Linux pair would fail its ABI check
# outright), and a plain newest-wins glob would otherwise pick them up
# silently.
#
# "newest wins" is not the same as "loadable": the loader refuses an
# artifact built for a different DuckDB line, and a checkout can hold
# artifacts for two lines whose mtimes are a minute apart. So among the
# candidates the one built for the CLI's own version wins, and the
# newest-wins order is only the tie-break inside that set.
# True when the file is the pure-C extension (it carries the C extension API entry point). The retired C++ build does
# not, and dist\ can still hold some under names this harness would otherwise take.
function ext_is_c_extension {
  param([string]$path)
  try { return ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($path))).Contains("fractalsql_init_c_api") }
  catch { return $false }
}

function resolve_ext {
  $cand = $null
  # Build directories that are not release artifacts: sanitizer, coverage, unit-test and lifecycle cells. The Linux
  # runs share this checkout and leave their own (linux_amd64) builds in some of them, e.g. dist\san-undefined.
  $sanDirs = @("asan", "ubsan", "windows-asan", "windows-ubsan", "cov", "unit", "lifecycle")
  foreach ($pat in @("dist/windows/fractalsql.*.duckdb_extension",
                     "dist/*/fractalsql.*.duckdb_extension",
                     "dist/fractalsql.*.duckdb_extension")) {
    $c = @(Get-ChildItem -Path $pat -ErrorAction SilentlyContinue |
           Where-Object { $sanDirs -notcontains $_.Directory.Name -and $_.Directory.Name -notlike "san-*" -and $_.Name -like "*.windows_amd64.duckdb_extension" } |
           Where-Object { ext_is_c_extension $_.FullName })
    if ($c.Count -gt 0) {
      if ($script:DUCK_VERSION) {
        $m = @($c | Where-Object { (ext_duck_version $_.FullName) -eq $script:DUCK_VERSION })
        # The stable-band file (fractalsql.capi.*) carries no version in its name: it serves every DuckDB line
        # except 1.4, which has a file of its own per 1.4.N.
        if ($m.Count -eq 0 -and $script:DUCK_VERSION -notmatch '^1\.4\.') { $m = @($c | Where-Object { $_.Name -like "fractalsql.capi.*" }) }
        if ($m.Count -gt 0) { $c = $m }
      }
      $cand = ($c | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
      break
    }
  }
  return $cand
}

# The extension and the CLI have to come from the same DuckDB line --
# the loader refuses the pairing outright -- so a resolved artifact is
# checked against the CLI's version before anything tries to LOAD it.
# The failure this replaces is DuckDB's own ("The file was built
# specifically for DuckDB version 'v1.5.6'"), which names the artifact
# but not the fix.
function assert_ext_matches_cli {
  param([string]$ext)
  if (-not $ext -or -not $script:DUCK_VERSION) { return }
  $ev = ext_duck_version $ext
  if (-not $ev) { return }
  if ($ev -ne $script:DUCK_VERSION) {
    die ("extension " + $ext + " was built for DuckDB v" + $ev +
         " but the CLI under test is v" + $script:DUCK_VERSION +
         " -- the loader refuses that pairing. Point FSQL_EXT at an artifact built for v" +
         $script:DUCK_VERSION + ", or FSQL_DUCKDB at a v" + $ev + " CLI.")
  }
}

# A resolved artifact that is OLDER than the sources it was built from is
# stale: it was compiled against an earlier tree, so it can be missing
# whatever the current sources added since. The symptom is a downstream
# gate failing with a message that describes the OLD binary's behavior
# (e.g. gate 32 expecting the enterprise .sig refusal but getting the
# plain "could not load enterprise library", because the stale artifact
# predates the signature check entirely) -- which reads like a logic
# bug in the extension rather than the build-staleness it actually is.
#
# This harness deliberately does not build (see gate_01), so the staleness
# check is the only place that can catch it: it names the artifact and
# the fix instead of leaving a misleading failure several gates later.
#
# Timestamps only -- the artifact is a single PE file and the sources are
# a tree, so a content hash of "the whole extension" is not a meaningful
# comparison; mtime is exactly the signal a rebuild invalidates.
function ext_stale_source {
  param([string]$ext)
  if (-not $ext -or -not (Test-Path -LiteralPath $ext)) { return $null }
  $extTime = (Get-Item -LiteralPath $ext).LastWriteTime
  $srcDir = Join-Path $script:HERE "src"
  if (-not (Test-Path -LiteralPath $srcDir)) { return $null }
  $newest = Get-ChildItem -LiteralPath $srcDir -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $newest) { return $null }
  # A one-minute grace absorbs timestamp granularity (a build finishing in
  # the same minute as the last source edit) -- only a source that is
  # MEASURABLY newer than the artifact counts as stale.
  if ($newest.LastWriteTime -le $extTime.AddMinutes(1)) { return $null }
  return $newest
}
# rebuild_extension: build the extension from source, the way the release
# artifact is built (scripts\windows\build.bat on Windows, build.sh
# elsewhere). This harness deliberately does not build -- gate 01's
# staleness assertion is what keeps the gates from testing yesterday's
# binary -- so -Rebuild is the one-command way to satisfy that assertion.
# Returns $true when the build succeeded.
function rebuild_extension {
  $bat = Join-Path $script:HERE "scripts\windows\build.bat"
  if (-not (Test-Path -LiteralPath $bat)) {
    Write-Host ("      no " + $bat + " to run")
    return $false
  }
  # build.bat runs `python -I scripts\append_metadata.py` for the metadata
  # footer, so the interpreter has to be reachable by name, not only by
  # its full path. The harness may not have resolved one yet (the rebuild
  # runs before find_toolchain), so look for one here if needed.
  $boot = Join-Path $script:BTROOT "fractalsql_bt_rebuild.bat"
  $lines = @('@echo off')
  $py = $script:PY
  if (-not $py) { $py = resolve_python }
  if ($py) {
    $pyDir = Split-Path -Parent $py
    if ($pyDir) { $lines += ('set "PATH=' + $pyDir + ';%PATH%"') }
  }
  $lines += ('cd /d "' + $script:HERE + '"')
  $lines += ('call "' + $bat + '"')
  $lines += 'exit /b %ERRORLEVEL%'
  [IO.File]::WriteAllLines($boot, $lines)
  & cmd.exe /c $boot 2>&1 | plain_lines | Out-Host
  return ($LASTEXITCODE -eq 0)
}

function assert_ext_not_stale {
  param([string]$ext)
  $newest = ext_stale_source $ext
  if (-not $newest) { return }
  $extTime = (Get-Item -LiteralPath $ext).LastWriteTime
  fail ("stale artifact: " + (Split-Path -Leaf $ext) + " was built " +
        ([int]((Get-Date) - $extTime).TotalMinutes) + " min ago, but " +
        $newest.Name + " is newer -- rebuild the extension before running the gates " +
        "(scripts\windows\build.bat on Windows, build.sh elsewhere), or point FSQL_EXT at a fresh one")
}

# ----------------------------------------------------------------
# Native sanitizer cells.
# ----------------------------------------------------------------
# Two cells, both built from source by scripts\windows\build.bat with
# the same DuckDB version the extension is pinned to, so the CLI and
# the extension agree on the ABI:
#
#   -Asan   MSVC cl.exe, /fsanitize=address. The ASan runtime is the
#           DYNAMIC one (clang_rt.asan_dynamic-x86_64.dll), staged
#           next to the instrumented CLI by build.bat.
#   -Ubsan  clang-cl, -fsanitize=undefined. MSVC has no undefined-
#           behavior sanitizer at all, so this cell switches the
#           compiler driver; build.bat carries the -DDUCKDB_API=
#           workaround DuckDB's deleted-function dllexport needs
#           under clang.
#
# The instrumented CLI hosts the instrumented extension. The older
# shape -- an instrumented extension loaded into an uninstrumented
# release CLI -- leaves the ASan runtime loaded after the process is
# already running, which is the one order ASan refuses to work in.
function sanitize_build_dir { param([string]$mode)
  if ($mode -eq "asan") { return "build-windows-asan" }
  return "build-windows-ubsan"
}

function sanitize_out_dir { param([string]$mode)
  if ($mode -eq "asan") { return "dist\windows-asan" }
  return "dist\windows-ubsan"
}

# sanitizer-mode artifact resolution (native -Asan / -Ubsan).
function resolve_san_ext {
  if (-not $script:SAN) { return $null }
  # the pure-C band only: the C++-era artifacts that sit in the same
  # directory (fractalsql.v2.0.0.*) match a wider pattern and would
  # win on a stale timestamp, and they are not what the cell built.
  $pat = Join-Path $script:HERE ((sanitize_out_dir $script:SAN) + "\fractalsql.capi.*.duckdb_extension")
  $c = Get-ChildItem -Path $pat -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($c) { return $c.FullName }
  return $null
}

# The instrumented CLI of a sanitizer cell, if it was built.
function resolve_san_cli {
  if (-not $script:SAN) { return $null }
  $p = Join-Path $script:HERE ((sanitize_out_dir $script:SAN) + "\duckdb.exe")
  if (Test-Path -LiteralPath $p) { return $p }
  return $null
}

# Build a native sanitizer cell: scripts\windows\build.bat with
# FSQL_SANITIZE=address (MSVC /fsanitize=address) or
# FSQL_SANITIZE=undefined (clang-cl -fsanitize=undefined), driven
# through a vcvars boot script so the run works outside a Developer
# Command Prompt. /MT stays untouched, and the tree never uses
# /GL//LTCG, so there is no LTO-vs-sanitizer conflict.
#
# The cell builds the EXTENSION only. The instrumented CLI that hosts
# it is not built here: the extension is pure C now and links against
# the vendored core, so there is no DuckDB source to compile. The CLI
# the cell uses is the instrumented one that sits in the cell's
# directory -- it has to be that one, because an uninstrumented host
# would load the ASan runtime after the process is already running,
# which is the one order ASan refuses to work in.
function Build-SanCell {
  param([ValidateSet("asan", "ubsan")][string]$Mode)

  $cli = resolve_san_cli
  if (-not $cli) {
    throw ("no instrumented CLI under " + (sanitize_out_dir $Mode) + ": the cell hosts the instrumented " +
           "extension in that directory's DuckDB CLI, and the pure-C build has no DuckDB-from-source path")
  }

  $vcvars = Get-ChildItem 'C:\Program Files\Microsoft Visual Studio\*\*\VC\Auxiliary\Build\vcvarsall.bat' `
              -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
  if (-not $vcvars -and -not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    throw "no MSVC toolchain found (run from a Native Tools Command Prompt, or install VS Build Tools)"
  }
  $outDir = Join-Path $script:HERE (sanitize_out_dir $Mode)
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null

  $boot = Join-Path $script:BTROOT ("fractalsql_bt_" + $Mode + "_build_cmd.bat")
  $lines = @('@echo off')
  if ($vcvars) { $lines += "call `"$vcvars`" x64 >nul 2>&1" }
  $lines += ("set FSQL_SANITIZE=" + $Mode)
  $lines += "call `"$script:HERE\scripts\windows\build.bat`""
  $lines += 'exit /b %ERRORLEVEL%'
  [IO.File]::WriteAllLines($boot, $lines)
  # BTROOT is <drive>:\tmp -- never a spaced path -- so the boot script
  # itself is safe; the repo path inside it may be, hence the quoted
  # call line.

  $buildLog = Join-Path $outDir ("build-" + $Mode + ".log")
  Write-Host ''
  Write-Host ("building the " + $Mode.ToUpper() + "-instrumented extension (scripts\windows\build.bat, FSQL_SANITIZE=" + $Mode + ") ...")
  Write-Host ''
  # Out-Host terminates the pipeline: cmd's stderr (2>&1 arrives as
  # ErrorRecords) must not leak into this function's output stream --
  # the caller assigns it straight into $script:EXT. plain_lines also
  # keeps the log identical on both hosts.
  & cmd.exe /c $boot 2>&1 | plain_lines | Tee-Object -FilePath $buildLog | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw ("the " + $Mode + " extension build failed (full output: " + $buildLog + ")")
  }
  $ext = resolve_san_ext
  if ((-not $ext) -or (-not (Test-Path -LiteralPath $ext))) {
    throw ("the " + $Mode + " build produced no extension under " + (sanitize_out_dir $Mode))
  }
  Write-Host ("  -> {0} ({1:N0} bytes)" -f $ext, (Get-Item -LiteralPath $ext).Length)
  Write-Host ("  -> {0} (instrumented CLI)" -f $cli)
  return @{ Ext = $ext; Cli = $cli }
}

# sqlq_env -EnvPairs <K=V array> <sql statements...>
#   env pairs are applied to this invocation's process environment
#   (the sh's per-invocation `env` equivalent) and restored afterwards.
#   The extension is LOADed first, once per invocation. SQLQ_OUT/SQLQ_RC
#   mirror the CLI's output and rc so callers can inspect without
#   re-running.
# Remove a variable from THIS process's environment for real. PowerShell coerces
# $null to the empty string for SetEnvironmentVariable, which leaves the
# variable present-but-empty -- and an empty value reads as "configured", not
# "not configured", so a gate that needs the unconfigured behaviour would not
# get it. Remove-Item Env: really removes it.
function Remove-ProcessEnvVar([string]$name) {
  if (Test-Path ("Env:" + $name)) { Remove-Item ("Env:" + $name) -ErrorAction SilentlyContinue }
}

function sqlq_env {
  param(
    [string[]]$EnvPairs = @(),
    [string[]]$UnsetPairs = @(),
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][object[]]$Statements
  )
  if (-not $script:EXT) { die "sqlq: no extension resolved yet (gate 01 must run before the fixture gates)" }
  if ($null -eq $Statements) { $Statements = @() }
  # Two transport rules the DuckDB CLI forces here:
  #  - each positional argument is its own SQL script, so multi-line
  #    statements must be joined into one script (a split INSERT hits
  #    "syntax error at end of input");
  #  - the joined script is still fed through STDIN to a temp file
  #    rather than one giant argv element: gate 19's 4097-element list
  #    literal overflows the ~32K CreateProcess command-line limit
  #    ("The filename or extension is too long").
  # -noheader because the 1.5 shell prints the derived column name (the
  # rewritten expression text) even in -batch -list mode, which broke
  # every numeric gate check that parses the first output line.
  $sql = ("LOAD '" + $script:EXT_SLASH + "';") + "`n"
  $sql += (@($Statements) | ForEach-Object { [string]$_ }) -join "`n"
  # The extension's own contract: "Call [fractal_release()] as the last
  # statement of a session that is about to close a file database." It closes
  # the connections the extension holds open for nested queries, so the host's
  # own teardown (shutdown checkpoint, file unlock) can run. It also joins the
  # extension's host-departure monitor thread, which otherwise keeps polling
  # the database while the CLI tears it down -- that race kills the CLI at
  # exit with a hard crash (0xC0000005 / 0xC0000409 on Windows), and the
  # harness drives a file database, so every session here is such a session.
  # The call prints a boolean; its line is trimmed back off the output below.
  $sql += "`nSELECT fractal_release();"
  $sqlfile = Join-Path ([IO.Path]::GetTempPath()) ("fsql_bt_" + [guid]::NewGuid().ToString("N") + ".sql")
  [IO.File]::WriteAllText($sqlfile, $sql)
  # -bail stops the CLI at the first error, and that is what gives an
  # error-path gate its nonzero exit on the 1.4/1.5 lines. The 2.x shell
  # reports the error and exits nonzero either way, so the flag is
  # dropped there: the script then runs to its end, and the release
  # call appended above gets its chance to close the extension's pool
  # before the CLI tears the database down. Without it the extension's
  # host-departure monitor is still polling when that teardown starts,
  # and the race crashes the host -- an access violation at exit, which
  # the sanitizer cells report and the release build hides behind the
  # error the gate was already expecting.
  $cliArgs = @("-batch", "-list", "-noheader", "-unsigned")
  if ($script:DUCK_MAJOR -lt 2) { $cliArgs = @("-bail") + $cliArgs }
  $cliArgs += $script:DUCK_ARGS + @($script:DB)
  $saved = @()
  foreach ($p in @($EnvPairs)) {
    if (-not $p) { continue }
    $i = $p.IndexOf("=")
    if ($i -lt 1) { die ("sqlq_env: bad env pair (want K=V): " + $p) }
    $k = $p.Substring(0, $i)
    $v = $p.Substring($i + 1)
    $old = [Environment]::GetEnvironmentVariable($k, "Process")
    $saved += ,@($k, ($null -ne $old), $old)
    [Environment]::SetEnvironmentVariable($k, $v, "Process")
  }
  # -UnsetPairs removes variables for the duration of the call. A
  # variable set to the empty string is NOT the same thing: the plugins
  # read a missing variable as "not configured" and an empty one as
  # "configured with an empty value", so a gate that needs the
  # unconfigured behaviour has to remove the variable outright.
  foreach ($k in @($UnsetPairs)) {
    if (-not $k) { continue }
    $old = [Environment]::GetEnvironmentVariable($k, "Process")
    $saved += ,@($k, ($null -ne $old), $old)
    Remove-ProcessEnvVar $k
  }
  try {
    $raw = (Get-Content $sqlfile -Raw | & $script:DUCK @cliArgs 2>&1 | plain_lines | Out-String -Width 8192)
    $script:SQLQ_OUT = [string]$raw
    if ($script:SQLQ_OUT.EndsWith([Environment]::NewLine)) {
      $script:SQLQ_OUT = $script:SQLQ_OUT.TrimEnd()
    }
    $script:SQLQ_RC = $LASTEXITCODE
    # The release is the last statement of the script and prints a boolean,
    # so its line is the last line of the output. Drop it: the gates assert
    # on the output of their own statements. (A gate statement that itself
    # answers "true" keeps its own line -- only the last one goes.)
    if ($script:SQLQ_OUT -eq "true") {
      $script:SQLQ_OUT = ""
    } else {
      $script:SQLQ_OUT = [regex]::Replace($script:SQLQ_OUT, '(?m)\r?\ntrue$', '')
    }
    if ($script:SAN -and (-not $script:SAN_EXEMPT) -and (san_report $script:SQLQ_OUT)) {
      if ($script:SQLQ_RC -eq 0) { $script:SQLQ_RC = 86 }
      $script:SQLQ_OUT += "`n==== sanitizer report detected in CLI output"
    }
  } finally {
    Remove-Item -LiteralPath $sqlfile -Force -ErrorAction SilentlyContinue
    # restore in reverse order: a name that was both set and unset in
    # the same call ends up back at its pre-call value.
    for ($si = $saved.Count - 1; $si -ge 0; $si--) {
      $s = $saved[$si]
      if ($s[1]) { [Environment]::SetEnvironmentVariable($s[0], $s[2], "Process") }
      else { Remove-ProcessEnvVar $s[0] }
    }
  }
  Write-Output $script:SQLQ_OUT
}

function sqlq {
  param([Parameter(Position = 0, ValueFromRemainingArguments = $true)][object[]]$Statements)
  return (sqlq_env -Statements $Statements)
}

# bt_setup: build the fixture schema in a fresh $DB, autocommitted, and
# leave bt_orders empty so the never-executes checks have a baseline.
function bt_setup {
  Remove-Item -LiteralPath $script:DB -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath ($script:DB + ".wal") -Force -ErrorAction SilentlyContinue
  $null = sqlq `
    "CREATE TABLE bt_customers(id INTEGER PRIMARY KEY, name VARCHAR NOT NULL, email VARCHAR);" `
    "CREATE TABLE bt_orders(id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES bt_customers(id), amount DOUBLE, created_at TIMESTAMP);" `
    "CREATE TABLE bt_explore(id INTEGER, x DOUBLE, y DOUBLE, z DOUBLE, w DOUBLE, embedding DOUBLE[]);" `
    "INSERT INTO bt_explore " `
    "SELECT i, " `
    "    CAST(1 + (i*7919) % 5 AS DOUBLE), " `
    "    CAST(1 + (i*104729) % 3 AS DOUBLE), " `
    "    CAST(i + 0.5 AS DOUBLE), " `
    "    CAST((i % 4) * 0.01 + 0.05 AS DOUBLE), " `
    "    [CAST(1 + (i*7919) % 5 AS DOUBLE), CAST(1 + (i*104729) % 3 AS DOUBLE), " `
    "     CAST(i + 0.5 AS DOUBLE), CAST((i % 4) * 0.01 + 0.05 AS DOUBLE)] " `
    "FROM generate_series(1, 60) AS g(i);" `
    "CREATE TABLE bt_telemetry(id INTEGER, vec DOUBLE[]);" `
    "INSERT INTO bt_telemetry VALUES " `
    " (1, [0.6, 0.8, 0.0, 0.0]), (2, [0.0, 1.0, 0.0, 0.0]), (3, [0.8, 0.6, 0.0, 0.0]), (4, [0.0, 0.6, 0.0, 0.8])," `
    " (5, [0.0, 0.0, 1.0, 0.0]), (6, [0.7, 0.7, 0.0, 0.0]), (7, [1.0, 0.0, 0.0, 0.0]), (8, [0.9, 0.1, 0.0, 0.0]);" `
    "CREATE TABLE bt_corpus(id INTEGER, doc VARCHAR, emb DOUBLE[]);" `
    "INSERT INTO bt_corpus VALUES " `
    " (1, 'doc-1', [1.0, 0.0, 0.0, 0.0]), (2, 'doc-2', [0.0, 1.0, 0.0, 0.0]), (3, 'doc-3', [0.0, 0.0, 1.0, 0.0])," `
    " (4, 'doc-4', [0.0, 0.0, 0.0, 1.0]), (5, 'doc-5', [1.0, 0.0, 0.0, 0.0]), (6, 'doc-6', [0.0, 1.0, 0.0, 0.0]);" `
    "CREATE TABLE bt_traj(id INTEGER PRIMARY KEY, vec DOUBLE[]);" `
    "INSERT INTO bt_traj VALUES " `
    " (1, [0.0, 0.0, 0.0, 0.0]), (2, [0.1, 0.0, 0.0, 0.0]), (3, [0.2, 0.0, 0.0, 0.0])," `
    " (4, [0.3, 0.0, 0.0, 0.0]), (5, [0.4, 0.0, 0.0, 0.0]);" `
    "CREATE TABLE bt_soak(worker INTEGER, it INTEGER, tag VARCHAR);"
  if ($script:SQLQ_RC -ne 0) {
    [Console]::Error.WriteLine($script:SQLQ_OUT)
    die "fixture setup failed"
  }
}

# compile the tests/*.c fixture plugins into $PDIR (best effort;
# have_plugin reports what actually made it).
#
# evil_nonterminating_plugin is skipped outright on Windows: it builds
# its guard page out of mmap/mprotect, which has no Windows analog in
# this harness (gate 05 is a documented skip for the same reason).
# Compiling it anyway only produced a compiler error in the middle of
# an otherwise clean run, which reads like a failure of the run.
function compile_plugins {
  New-Item -ItemType Directory -Path $script:PDIR -Force | Out-Null
  $posixOnly = @()
  if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    $posixOnly = @("evil_nonterminating_plugin")
  }
  foreach ($name in @("mock_reasoning_plugin", "mock_embed_plugin", "retry_reasoning_plugin",
                      "think_reasoning_plugin", "evil_nonterminating_plugin", "evil_crash_plugin",
                      "evil_lying_length_plugin", "evil_embed_plugin")) {
    if ($posixOnly -contains $name) {
      Write-Host ("      note: " + $name + " is POSIX-only (mmap/mprotect guard page); skipped on Windows")
      continue
    }
    $src = Join-Path $script:HERE ("tests\" + $name + ".c")
    $out = Join-Path $script:PDIR ($name + $script:PLUGSUF)
    if (-not (Test-Path -LiteralPath $src)) { continue }
    & $script:CC -shared -fPIC -std=c99 -I (Join-Path $script:HERE "include") $src -o $out 2> ($out + ".build.log")
    if ($LASTEXITCODE -ne 0) {
      [Console]::Error.WriteLine("      note: could not compile " + $src + " (see " + $out + ".build.log)")
      Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
  }
}

function have_plugin {
  param([string]$name)
  return (Test-Path -LiteralPath (Join-Path $script:PDIR ($name + $script:PLUGSUF)))
}

# pj <name>: native-form plugin path for env vars.
function pj { param([string]$name)
  return ($script:PDIR + $script:PDIRSEP + $name + $script:PLUGSUF)
}

# py_run <script.py>: run a python driver with FSQL_BT_DB /
# FSQL_BT_EXT pointing at the harness database and extension.
function py_run {
  param([string]$scriptPath)
  $oldDb = [Environment]::GetEnvironmentVariable("FSQL_BT_DB", "Process")
  $oldExt = [Environment]::GetEnvironmentVariable("FSQL_BT_EXT", "Process")
  [Environment]::SetEnvironmentVariable("FSQL_BT_DB", $script:DB, "Process")
  [Environment]::SetEnvironmentVariable("FSQL_BT_EXT", $script:EXT_SLASH, "Process")
  try {
    $raw = (& $script:PY $scriptPath 2>&1 | plain_lines | Out-String -Width 8192)
    $script:SQLQ_OUT = [string]$raw
    $script:SQLQ_RC = $LASTEXITCODE
  } finally {
    [Environment]::SetEnvironmentVariable("FSQL_BT_DB", $oldDb, "Process")
    [Environment]::SetEnvironmentVariable("FSQL_BT_EXT", $oldExt, "Process")
  }
  Write-Output $script:SQLQ_OUT
}

# usage: the file's doc header (line 4 through the gate map) doubles as
# the help text.
function usage {
  $lines = Get-Content -LiteralPath $PSCommandPath
  $last = [Math]::Min($lines.Count, 200) - 1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].StartsWith("#   FSQL_FUZZ_CC")) { $last = $i; break }
  }
  Write-Output ($lines[3..$last])
}

# ----------------------------------------------------------------
# Gates.
# ----------------------------------------------------------------

function gate_01 {
  # The extension is pure C on DuckDB's C extension API, so its one entry point is fractalsql_init_c_api (the
  # C++ loader entry point fractalsql_duckdb_cpp_init belonged to the retired C++ build, and is still accepted so
  # an older artifact is reported as such rather than as missing). The pre-1.4 "fractalsql_init" symbol must be
  # gone; it IS a prefix of fractalsql_init_c_api, so the scan has to exclude that name.
  function check_entry_points($path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $scan = [Text.Encoding]::ASCII.GetString($bytes)
    if ($scan.Contains("fractalsql_init_c_api")) {
      pass "the C extension API entry point (fractalsql_init_c_api) is in the artifact"
    } elseif ($scan.Contains("fractalsql_duckdb_cpp_init")) {
      fail ("this artifact is the retired C++ build, which these gates no longer test -- build the C extension with " +
            "scripts\windows\build.bat and set FSQL_EXT to dist\windows_amd64\fractalsql.capi.windows_amd64.duckdb_extension " +
            "(or remove FSQL_EXT to let the harness find it)")
    } else {
      fail "no entry point (fractalsql_init_c_api) in the artifact"
    }
    if ([regex]::IsMatch($scan, "fractalsql_init(?!_c_api)")) {
      fail "the pre-1.4 entry point (fractalsql_init) is still in the artifact"
    } else {
      pass "the pre-1.4 entry point (fractalsql_init) is gone from the artifact"
    }
  }
  # -Asan/-Ubsan are the only modes where gate 01 builds anything: the
  # instrumented extension, natively, into dist\windows-asan\ /
  # dist\windows-ubsan\. The cell builds the instrumented CLI that
  # hosts it too (BUILD_SHELL=ON), and every gate drives THAT CLI
  # against the instrumented extension -- an uninstrumented host would
  # load the ASan runtime after the process is already running, which
  # is the one order ASan refuses to work in. All other modes only
  # locate an artifact.
  if ($script:SAN) {
    if ($env:FSQL_EXT) {
      if (-not (Test-Path -LiteralPath $env:FSQL_EXT)) {
        fail ("FSQL_EXT=" + $env:FSQL_EXT + " does not exist")
        return
      }
      $script:EXT = $env:FSQL_EXT
      pass ("01 build (artifact from FSQL_EXT): " + $script:EXT)
    } else {
      $script:EXT = resolve_san_ext
      if ((-not $script:EXT) -or (-not (Test-Path -LiteralPath $script:EXT))) {
        fail ("01 build [" + $script:SAN + "]: no artifact under " + (sanitize_out_dir $script:SAN))
        return
      }
      pass ("01 build (native " + $script:SAN + "-instrumented): " + (Split-Path -Leaf $script:EXT))
    }
    # Instrumentedness probe: a linked sanitizer runtime carries its
    # own symbols (ASan's __asan_report_load*, UBSan's
    # __ubsan_handle_*); a clean build has none. Without this, a stale
    # release artifact under the cell's directory would silently run
    # the whole matrix uninstrumented.
    $scan = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($script:EXT))
    if ($script:SAN -eq "asan") {
      if ($scan.Contains("__asan_report_load")) {
        pass "01 instrumentedness probe: ASan runtime linked into the extension"
      } else {
        fail "01 instrumentedness probe: no ASan runtime found in the extension (stale clean build under dist\windows-asan?)"
      }
    } else {
      if ($scan.Contains("__ubsan_handle_")) {
        pass "01 instrumentedness probe: UBSan runtime linked into the extension"
      } else {
        fail "01 instrumentedness probe: no UBSan runtime found in the extension (stale clean build under dist\windows-ubsan?)"
      }
    }
    # The instrumented CLI is what hosts the instrumented extension.
    $cli = resolve_san_cli
    if ($cli) {
      pass ("01 build (instrumented CLI): " + (Split-Path -Leaf $cli))
    } else {
      fail "01 build: no instrumented CLI under " + (sanitize_out_dir $script:SAN)
    }
    $script:EXT_SLASH = $script:EXT.Replace('\', '/')
    check_entry_points $script:EXT
    return
  }
  # Locate/validate the extension artifact. This harness deliberately
  # does NOT build: use build.sh (docker) or the CI runners first.
  if ($env:FSQL_EXT) {
    if (-not (Test-Path -LiteralPath $env:FSQL_EXT)) {
      fail ("FSQL_EXT=" + $env:FSQL_EXT + " does not exist")
      return
    }
    $script:EXT = $env:FSQL_EXT
    pass ("artifact from FSQL_EXT: " + $script:EXT)
  } else {
    $script:EXT = resolve_ext
    # A CLI picked up from dist/ (the no-PATH fallback) is paired with
    # the extension beside it; that pair beats the newest-wins glob.
    if ($script:DUCK_PAIR_EXT) { $script:EXT = $script:DUCK_PAIR_EXT }
    if ((-not $script:EXT) -or (-not (Test-Path -LiteralPath $script:EXT))) {
      fail "no fractalsql.*.duckdb_extension under dist/ (run build.sh or build_test.ps1 first)"
      return
    }
    pass ("artifact located: " + $script:EXT)
  }
  if ($script:EXT -like "*duckdb_extension*") {
    pass "artifact name matches a duckdb extension file"
  } else {
    fail ($script:EXT + " does not look like a duckdb extension file")
  }
  assert_ext_matches_cli $script:EXT
  assert_ext_not_stale $script:EXT
  $script:EXT_SLASH = $script:EXT.Replace('\', '/')
  check_entry_points $script:EXT
}

function gate_02 {
  $r = sqlq "SELECT fractal_version();"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "fractal_version() reports 2.0.1" "2.0.1"
  $r = sqlq "SELECT fractal_edition();"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "fractal_edition() reports Community" "Community"
  # smoke search: identical points converge onto the query point itself
  $r = sqlq "SELECT fractal_search([0.6, 0.8, 0.0, 0.0]::DOUBLE[], [0.6, 0.8, 0.0, 0.0]::DOUBLE[]);"; $rc = $script:SQLQ_RC
  if (($rc -eq 0) -and (num_abs_lt_1e6 $r)) {
    pass "fractal_search converges on an identical point (|d| < 1e-6)"
  } else {
    fail "fractal_search convergence smoke"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
  }
  $r = sqlq "SELECT fractal_search_debug([0.6, 0.8, 0.0, 0.0]::DOUBLE[], 30, 50, 2);"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "fractal_search_debug reports best_point" "best_point"
  # The CI smoke test (test/smoke_test.sql) is self-checking: every
  # assertion calls error(), which -bail turns into a non-zero exit.
  # Run the file itself rather than a copy of its checks, so the two
  # cannot drift apart.
  $smoke = Join-Path $script:HERE "test\smoke_test.sql"
  if (Test-Path -LiteralPath $smoke) {
    $r = sqlq (Get-Content -LiteralPath $smoke -Raw); $rc = $script:SQLQ_RC
    if ($rc -eq 0) {
      pass "test/smoke_test.sql runs clean"
    } else {
      fail "test/smoke_test.sql"
      Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
    }
  } else {
    fail "test/smoke_test.sql is missing"
  }
}

function gate_03 {
  $r = sqlq "SELECT fractal_schema_context();"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "0-arg auto-discovery renders both fixture tables" "TABLE bt_orders:"
  if (out_has $r "  id INTEGER PRIMARY KEY") {
    pass "primary key annotation rendered"
  } else {
    fail "primary key annotation missing from the rendering"
    Write-Host ("      got: " + (trunc $r))
  }
  if (out_has $r "  name VARCHAR NOT NULL") {
    pass "NOT NULL annotation rendered"
  } else {
    fail "NOT NULL annotation missing from the rendering"
    Write-Host ("      got: " + (trunc $r))
  }
  if ((out_has $r "FOREIGN KEYS:") -and (out_has $r "bt_orders(customer_id) -> bt_customers(id)")) {
    pass "foreign key rendered as bt_orders(customer_id) -> bt_customers(id)"
  } else {
    fail "foreign key rendering missing"
    Write-Host ("      got: " + (trunc $r))
  }
  $r = sqlq "SELECT fractal_schema_context(['bt_orders']);"; $rc = $script:SQLQ_RC
  if (($rc -eq 0) -and (out_has $r "TABLE bt_orders:") -and (-not (out_has $r "TABLE bt_customers:"))) {
    pass "table_names[] scoping returns only the requested table"
  } else {
    fail "table_names[] scoping"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
  }
  $r = sqlq "SELECT fractal_schema_context(['bt_customers'], 'bt_customers');"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "list + query_hint arity accepted" "TABLE bt_customers:"
  # a database with no visible tables has no schema to describe: that
  # is reported, not rendered as an empty description
  $emptydb = Join-Path $script:BTROOT ("fractalsql_bt_empty_" + [guid]::NewGuid().ToString("N") + ".db")
  $sqlfile = Join-Path ([IO.Path]::GetTempPath()) ("fsql_bt_" + [guid]::NewGuid().ToString("N") + ".sql")
  [IO.File]::WriteAllText($sqlfile, ("LOAD '" + $script:EXT_SLASH + "';`nSELECT fractal_schema_context();"))
  $raw = (Get-Content $sqlfile -Raw | & $script:DUCK -bail -batch -list -noheader -unsigned @($script:DUCK_ARGS) $emptydb 2>&1 | plain_lines | Out-String -Width 8192)
  $rc = $LASTEXITCODE
  Remove-Item -LiteralPath $sqlfile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $emptydb -Force -ErrorAction SilentlyContinue
  if (($rc -ne 0) -and (out_has $raw "no visible tables found")) {
    pass "a table-less database reports 'no visible tables found'"
  } else {
    fail "table-less database schema_context"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $raw))
  }
}

function t2s_expect {
  # t2s_expect <canned-sql> <want|'-'> <err|ok> <label>; uses T2S_ENV
  # (env pairs) + SQLTXT (the mock plugin's canned response file).
  param([string]$canned, [string]$want, [string]$mode, [string]$label)
  if ($want -eq "-") { $want = "" }
  [IO.File]::WriteAllText($script:SQLTXT, $canned, [System.Text.Encoding]::ASCII)
  $r = sqlq_env -EnvPairs $script:T2S_ENV "SELECT fractal_text_to_sql('give me the orders data');"
  $rc = $script:SQLQ_RC
  if ($mode -eq "err") {
    expect_err $want $rc $r $label
  } else {
    expect_ok $rc $r $label $want
  }
}

function gate_04 {
  $script:T2S_ENV = @("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_reasoning_plugin"))
  $happy = 'SELECT id, name FROM bt_customers WHERE id = 1'
  t2s_expect $happy $happy ok "happy path returns the canned SELECT (schema-scoped prompt)"
  t2s_expect 'SELECT 1; SELECT 2' "expected exactly one SQL statement, found 2" err "stacked statements rejected at the allowlist"
  t2s_expect 'CREATE TABLE bt_dos(a INTEGER)' 'statement type "CREATE" is not permitted' err "DDL rejected under the SELECT-only allowlist"
  t2s_expect 'DELETE FROM bt_orders' 'statement type "DELETE" is not permitted' err "DELETE rejected under the SELECT-only allowlist"
  t2s_expect 'INSERT INTO bt_orders VALUES (1)' 'statement type "INSERT" is not permitted' err "INSERT rejected under the SELECT-only allowlist"
  # A modifying CTE must never come back through the allowlist. 1.5's
  # grammar has no such statement, so the candidate is refused by the
  # parser; 2.0's grammar has one, so the allowlist refuses it instead
  # (the outer statement is a SELECT, and the DELETE hides in the CTE).
  if ($script:DUCK_MAJOR -ge 2) {
    t2s_expect 'WITH d AS (DELETE FROM bt_orders RETURNING *) SELECT * FROM d' "data-modifying CTE" err "modifying CTE refused by the allowlist"
  } else {
    t2s_expect 'WITH d AS (DELETE FROM bt_orders RETURNING *) SELECT * FROM d' "SQL does not parse" err "modifying CTE is a parse error under duckdb's grammar"
  }
  t2s_expect 'EXPLAIN SELECT 1' 'statement type "EXPLAIN" is not permitted' err "EXPLAIN rejected under the SELECT-only allowlist"
  t2s_expect 'this is not sql at all ##' "is not permitted" err "non-SQL prose refused on its first keyword"
  t2s_expect '123 not a keyword' "statement is empty or does not start with" err "a candidate that does not start with a keyword is refused"
  t2s_expect 'SELECT no_such_column FROM bt_orders' "SQL does not parse" err "unknown column surfaces from the EXPLAIN step"
  $r = sqlq "SELECT count(*) FROM bt_orders;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "fractal_text_to_sql never executes (bt_orders still empty)" "0"

  # the exhausted loop names the attempt count, the last rejection, and
  # quotes the rejected candidate back
  [IO.File]::WriteAllText($script:SQLTXT, 'DROP TABLE bt_orders', [System.Text.Encoding]::ASCII)
  $r = sqlq_env -EnvPairs $script:T2S_ENV "SELECT fractal_text_to_sql('give me the orders data');"
  $rc = $script:SQLQ_RC
  expect_err "exhausted 3 attempt(s), last rejection:" $rc $r "the exhausted loop names the attempt count and the last rejection"
  expect_err "Last candidate SQL: DROP TABLE bt_orders" $rc $r "the exhausted loop quotes the rejected candidate back"

  # a reply that carries no SQL at all: the loop reports the empty
  # candidate rather than the generic rejection
  [IO.File]::WriteAllText($script:SQLTXT, '   ', [System.Text.Encoding]::ASCII)
  $r = sqlq_env -EnvPairs $script:T2S_ENV "SELECT fractal_text_to_sql('give me the orders data');"
  $rc = $script:SQLQ_RC
  expect_err "the model response contained no SQL" $rc $r "a reply with no SQL at all is reported as such"

  # a fenced block is extracted from ANYWHERE in the reply, not only
  # from its first line. The fence is written from a single-quoted
  # format string: a backtick is PowerShell's escape character, so a
  # double-quoted literal would eat it.
  $fenced = 'Here is the query you asked for:{0}{0}```sql{0}SELECT id FROM bt_customers{0}```{0}{0}Hope that helps.' -f [Environment]::NewLine
  [IO.File]::WriteAllText($script:SQLTXT, $fenced, [System.Text.Encoding]::ASCII)
  $r = sqlq_env -EnvPairs $script:T2S_ENV "SELECT fractal_text_to_sql('give me the orders data');"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r 'a fenced ```sql block is extracted from anywhere in the reply' "SELECT id FROM bt_customers"

  # the critique round (opt-in, off by default). With no critique file
  # the verdict can never be a PASS, so the loop exhausts and reports
  # the verdict.
  Remove-Item -LiteralPath $script:REVIEWTXT -Force -ErrorAction SilentlyContinue
  [IO.File]::WriteAllText($script:SQLTXT, 'SELECT 1', [System.Text.Encoding]::ASCII)
  $r = sqlq_env -EnvPairs ($script:T2S_ENV + @("FRACTALSQL_TEXT_TO_SQL_USE_REVIEW=on")) "SELECT fractal_text_to_sql('give me the orders data');"
  $rc = $script:SQLQ_RC
  expect_err "exhausted 3 attempt(s), last review verdict:" $rc $r "the critique round exhausts the loop when the verdict is not a PASS"
  # with a PASS critique the candidate stands
  [IO.File]::WriteAllText($script:REVIEWTXT, 'PASS - the query answers the request', [System.Text.Encoding]::ASCII)
  $r = sqlq_env -EnvPairs ($script:T2S_ENV + @("FRACTALSQL_TEXT_TO_SQL_USE_REVIEW=on")) "SELECT fractal_text_to_sql('give me the orders data');"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "the critique round accepts a PASS verdict" "SELECT 1"
  $prompt = rc_file $script:REVIEWPROMPT
  if (out_has $prompt "Original request: give me the orders data") {
    pass "the critique prompt carries the original request"
  } else {
    fail "the critique prompt does not carry the original request"
    Write-Host ("      got: " + (trunc $prompt))
  }
  # the round is off unless it is switched on
  Remove-Item -LiteralPath $script:REVIEWTXT -Force -ErrorAction SilentlyContinue
  $r = sqlq_env -EnvPairs $script:T2S_ENV "SELECT fractal_text_to_sql('give me the orders data');"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "the critique round is off by default" "SELECT 1"

  # the question cap: one input over the 4 MiB bound is refused before
  # any dispatch
  $r = sqlq_env -EnvPairs $script:T2S_ENV "SELECT fractal_text_to_sql(repeat('x', 4194305));"
  $rc = $script:SQLQ_RC
  expect_err "exceeds the 4 MiB input cap" $rc $r "a question over the 4 MiB cap is refused"
}

function gate_05 {
  if (-not (have_plugin "evil_nonterminating_plugin")) {
    skip "evil_nonterminating fixture needs mmap/mprotect (POSIX-only); a guard-page analog is not wired in this harness"
    return
  }
  wc_file $script:SQLTXT "SELECT 42"
  wc_file $script:EVILTRIG "1"
  $r = sqlq_env -EnvPairs @("FSQL_EVIL_SQL_FILE=" + $script:SQLTXT) `
      ("SELECT fractal_text_to_sql('why is it slow');")
  $rc = $script:SQLQ_RC
  expect_survive $rc $r "text_to_sql GENERATE survives the guard-page response (no over-read)"
  wc_file $script:EVILTRIG "1"
  $r = sqlq_env -EnvPairs @("FSQL_EVIL_SQL_FILE=" + $script:SQLTXT) `
      ("SELECT fractal_reason('why is it slow', 'bt_orders');")
  $rc = $script:SQLQ_RC
  expect_survive $rc $r "bare fractal_reason survives the guard-page response"
}

function gate_06 {
  # a canary row the crash must not lose
  $null = sqlq "CREATE TABLE bt_crash_canary(k INTEGER, v VARCHAR);" `
               "INSERT INTO bt_crash_canary VALUES (1, 'pre-crash');"
  $r = sqlq "SELECT count(*) FROM bt_crash_canary;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "canary committed before the crash" "1"
  # kill the CLI in the middle of a reasoning call (deliberate crash:
  # report-exempt -- see san_report)
  $script:SAN_EXEMPT = $true
  $r = sqlq_env -EnvPairs (san_crash_pairs @("FRACTALSQL_REASONING_PLUGIN=" + (pj "evil_crash_plugin"))) `
      "SELECT fractal_reason('q');"
  $script:SAN_EXEMPT = $false
  $rc = $script:SQLQ_RC
  if (crashed $rc) {
    pass ("evil_crash_plugin killed the CLI process (rc=" + $rc + ")")
  } else {
    fail "expected the crash fixture to kill the CLI process"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
  }
  # the DB must reopen cleanly; poll for the lock/WAL-reopen to settle
  $deadline = (Get-Date).AddSeconds(30 * $script:TIMEOUT_MULT)
  $recovered = $false
  $out = ""
  while ((Get-Date) -lt $deadline) {
    $out = (& $script:DUCK -bail -batch -list @($script:DUCK_ARGS) $script:DB "SELECT count(*) FROM bt_crash_canary;" 2>&1 |
            plain_lines | Out-String -Width 8192).TrimEnd()
    if ($LASTEXITCODE -eq 0) { $recovered = $true; break }
    Start-Sleep -Seconds 1
  }
  if (-not $recovered) {
    fail "database did not reopen within the recovery window"
    Write-Host ("      last open attempt: " + (trunc $out))
    return
  }
  pass "database reopened safely after the mid-call crash"
  if (out_has $out "1") {
    pass "pre-crash canary row intact after WAL replay"
  } else {
    fail "pre-crash canary row lost by the crash"
    Write-Host ("      got: " + (trunc $out))
  }
  # and the extension still loads and serves the recovered DB
  $r = sqlq "SELECT count(*) FROM bt_explore;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "extension serves the recovered database" "60"
}

function gate_07 {
  if (-not (have_plugin "evil_lying_length_plugin")) {
    skip "evil_lying_length fixture did not compile"
    return
  }
  wc_file $script:SQLTXT "SELECT 7"
  # trigger -1: lie on EVERY dispatch. The duckdb CLI constant-folds the
  # SELECT first, so dispatch #1 happens at fold time (the executor
  # swallows that attempt's exception) and the folded-constant path ends
  # the call sequence there if it succeeds -- a call-N-only lie would
  # land on the swallowed fold-time dispatch when the earlier calls were
  # clean, and never on the execution-time dispatch the gate observes.
  wc_file $script:EVILTRIG "-1"
  # each element is parenthesized: a bare comma binds tighter than "+" in
  # PowerShell argument mode and collapses the array into one string
  $r = sqlq_env -EnvPairs @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "evil_lying_length_plugin")),
                            ("FSQL_EVIL_SQL_FILE=" + $script:SQLTXT)) `
      "SELECT fractal_text_to_sql('why is it slow');"
  $rc = $script:SQLQ_RC
  expect_err "implausible response length" $rc $r "T2S refuses a lying 32 MiB response length (nothing is read)"
  wc_file $script:EVILTRIG "-1"
  $r = sqlq_env -EnvPairs @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "evil_lying_length_plugin")),
                            ("FSQL_EVIL_SQL_FILE=" + $script:SQLTXT)) `
      "SELECT fractal_reason('why is it slow', 'bt_orders');"
  $rc = $script:SQLQ_RC
  expect_err "implausible response length" $rc $r "bare fractal_reason refuses the same claim"
}

function gate_08 {
  # no authorizer analog exists in duckdb: the plugin path boundary
  # (gate 09) and the vectorizer create-time validation (gate 16) own
  # the neighborhood. Documented skip keeps the gate numbering stable.
  skip "no authorizer hook in duckdb; boundaries covered by gates 09/16"
}

function gate_09 {
  wc_file $script:SQLTXT "SELECT 1"
  $r = sqlq_env -EnvPairs @("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_reasoning_plugin")) `
      "SELECT fractal_reason('q');"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "canonical absolute plugin path loads and answers" "SELECT 1"
  $r = sqlq_env -EnvPairs @("FRACTALSQL_REASONING_PLUGIN=mock_reasoning_plugin" + $script:PLUGSUF) `
      "SELECT fractal_reason('q');"
  $rc = $script:SQLQ_RC
  expect_err "failed to load reasoning plugin" $rc $r "relative plugin path is rejected at load"
  $trav = Join-Path (Join-Path $script:BTROOT "..") ("fractalsql_bt_nonexistent_plugin" + $script:PLUGSUF)
  $r = sqlq_env -EnvPairs @("FRACTALSQL_REASONING_PLUGIN=" + $trav) `
      "SELECT fractal_reason('q');"
  $rc = $script:SQLQ_RC
  expect_err "failed to load reasoning plugin" $rc $r "traversal plugin path is rejected at load"
  $bad = Join-Path $script:BTROOT ("fractalsql_bt_nonexistent_plugin" + $script:PLUGSUF)
  $r = sqlq_env -EnvPairs @("FRACTALSQL_REASONING_PLUGIN=" + $bad) `
      "SELECT fractal_reason('q');"
  $rc = $script:SQLQ_RC
  expect_err "failed to load reasoning plugin" $rc $r "missing plugin file is reported distinctly"
}

function gate_10 {
  # a caller-supplied 513-table list trips the cap before any SQL runs
  $list = "['bt_dos_0'"
  foreach ($i in 1..512) { $list = $list + ",'bt_dos_" + $i + "'" }
  $list = $list + "]"
  $r = sqlq ("SELECT fractal_schema_context(" + $list + ");"); $rc = $script:SQLQ_RC
  expect_err "exceeds the limit of 512" $rc $r "513-element table_names[] trips the 512 cap"
  # injection-shaped names are matched by string equality only, never
  # interpolated into executed SQL. A canary row makes the "survived"
  # check below meaningful (bt_setup seeds no customer rows).
  $null = sqlq "INSERT INTO bt_customers VALUES (1, 'canary', 'canary@fractalsql.test');"
  $r = sqlq "SELECT fractal_schema_context(['bt_customers','bt; DROP TABLE bt_customers--']);"; $rc = $script:SQLQ_RC
  if (($rc -eq 0) -and (out_has $r "TABLE bt_customers:") -and (-not (out_has $r "DROP TABLE"))) {
    pass "injection-shaped name never reaches executed SQL (only bt_customers renders)"
  } else {
    fail "injection-shaped table_names[] entry"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
  }
  $r = sqlq "SELECT count(*) FROM bt_customers;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "bt_customers survives the injection attempt" "1"
  $r = sqlq "SELECT fractal_schema_context(['bt_customers'], 'bt_customers');"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "list + query_hint arity accepted" "TABLE bt_customers:"
}
function gate_11 {
  # The 4-arg form: the table function has no SQL-level defaults, so the
  # options argument is always passed (NULL for "use the defaults").
  $r = sqlq "SELECT particle FROM fractal_search_explore('bt_explore','embedding',[1.0, 0.05, 0.0, 0.0]::DOUBLE[], NULL);"
  $rc = $script:SQLQ_RC
  $rows = @($r -split "`r?`n" | Where-Object { $_ -match '^\[' })
  $xs = @($rows | ForEach-Object { ($_ -split ',')[0].TrimStart('[') } | Select-Object -Unique)
  if (($rc -eq 0) -and ($rows.Count -ge 5) -and ($xs.Count -ge 2)) {
    pass ("scout population returned and dispersed (" + $rows.Count + " rows across " + $xs.Count + " distinct x groups)")
  } else {
    fail "scout population return shape"
    Write-Host ("      got rc=" + $rc + ", " + $rows.Count + " rows: " + (trunc $r))
  }
  # options-JSON overload still returns the same population contract
  $r = sqlq "SELECT count(*) FROM fractal_search_explore('bt_explore','embedding',[1.0, 0.05, 0.0, 0.0]::DOUBLE[], '{""population_size"": 24, ""iterations"": 11}');"
  $rc = $script:SQLQ_RC
  $n = (to_int (numerify $r))
  if (($rc -eq 0) -and ($n -ge 5)) {
    pass "options-JSON overload accepted (population_size/iterations honored)"
  } else {
    fail "options-JSON overload"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
  }
}

function gate_12 {
  if ($script:SAN) {
    skip "python driver gate under -Asan/-Ubsan: the pip-duckdb host process cannot be instrumented (known Windows load_extension issue)"
    return
  }
  if (-not $script:PY) {
    skip "python with the pip duckdb package is unavailable (set FSQL_PYTHON)"
    return
  }
  $pyMajor = pip_duckdb_major
  if ($pyMajor -ne $script:DUCK_MAJOR) {
    skip ("the pip duckdb package is " + $pyMajor + ".x but the CLI under test is " +
          $script:DUCK_MAJOR + ".x -- the driver cannot read this engine's database file nor load its extension")
    return
  }
  # soak shape: FSQL_BT_SOAK_WORKERS x FSQL_BT_SOAK_ITERS, defaults 4x10
  $script:SOAK_WORKERS = 4
  $script:SOAK_ITERS = 10
  if ($env:FSQL_BT_SOAK_WORKERS) { $script:SOAK_WORKERS = [int]$env:FSQL_BT_SOAK_WORKERS }
  if ($env:FSQL_BT_SOAK_ITERS) { $script:SOAK_ITERS = [int]$env:FSQL_BT_SOAK_ITERS }
  $py12 = @'
import concurrent.futures as cf
import duckdb, os, sys

db  = os.environ["FSQL_BT_DB"]
ext = os.environ["FSQL_BT_EXT"].replace("'", "''")
cfg = {"allow_unsigned_extensions": "true"}
S = int(os.environ["FSQL_BT_SOAK_WORKERS"])
I = int(os.environ["FSQL_BT_SOAK_ITERS"])

base = duckdb.connect(db, config=cfg)
base.execute(f"LOAD '{ext}'")
base.execute("DELETE FROM bt_soak")

def worker(w):
    c = base.cursor()
    for i in range(1, I + 1):
        got = c.execute("SELECT fractal_search(vec, vec) FROM bt_telemetry WHERE id = 1;").fetchone()
        assert got is not None, "fractal_search returned no row"
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
'@
  [IO.File]::WriteAllText((Join-Path $script:PDIR "gate12.py"), $py12, [System.Text.Encoding]::ASCII)
  $null = [Environment]::SetEnvironmentVariable("FSQL_BT_SOAK_WORKERS", [string]$script:SOAK_WORKERS, "Process")
  $null = [Environment]::SetEnvironmentVariable("FSQL_BT_SOAK_ITERS", [string]$script:SOAK_ITERS, "Process")
  $r = py_run (Join-Path $script:PDIR "gate12.py")
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "S x I threaded soak ran clean (every search + insert exact)" "gate-12-ok"
  $r = sqlq "SELECT count(*) FROM bt_soak;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "CLI agrees with the soak row count" ([string]($script:SOAK_WORKERS * $script:SOAK_ITERS))
}

function gate_13 {
  # the allowlist env var the port reads is FRACTALSQL_-prefixed
  # (src/fractalsql_extension_agents.cpp's CheckStatementAllowed); the
  # old FSQL_-prefixed alias is a silent no-op
  $script:T2S_ENV = @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_reasoning_plugin")),
                      "FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update")
  t2s_expect "SELECT count(*) FROM bt_orders" "SELECT count(*) FROM bt_orders" ok `
             "control: SELECT still flows through"
  t2s_expect "INSERT INTO bt_orders VALUES (1, 1, 10.0, now())" "INSERT INTO bt_orders" ok `
             "INSERT flows through with select_insert_update"
  t2s_expect "UPDATE bt_orders SET amount = 20.0" "UPDATE bt_orders" ok `
             "UPDATE flows through with select_insert_update"
  t2s_expect "DELETE FROM bt_orders" 'statement type "DELETE" is not permitted' err `
             "DELETE stays rejected under siu"
  t2s_expect "DROP TABLE bt_orders" 'statement type "DROP" is not permitted' err `
             "DDL stays rejected under siu"
  $r = sqlq "SELECT count(*) FROM bt_orders;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "widened allowlist never executes anything (bt_orders still empty)" "0"
}

function gate_14 {
  Remove-Item -LiteralPath $script:RETRYPROMPT -Force -ErrorAction SilentlyContinue
  $r = sqlq_env -EnvPairs @("FRACTALSQL_REASONING_PLUGIN=" + (pj "retry_reasoning_plugin")) `
      "SELECT fractal_text_to_sql('do the thing');"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "attempt 1 rejected at the allowlist, attempt 2 succeeds in the retry loop" "SELECT 1"
  if ((Test-Path -LiteralPath $script:RETRYPROMPT) -and (out_has (rc_file $script:RETRYPROMPT) "not permitted")) {
    pass "attempt-1 rejection reason was threaded into the attempt-2 GENERATE prompt"
  } else {
    fail "retry prompt is missing the attempt-1 rejection reason"
    if (Test-Path -LiteralPath $script:RETRYPROMPT) {
      Write-Host ("      got: " + (trunc (rc_file $script:RETRYPROMPT)))
    }
  }
}

function gate_15 {
  $embenv = @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_embed_plugin")),
              "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings")
  # dispatch: mock_embed answers every tier with the canned 3-float vector
  $r = sqlq_env -EnvPairs $embenv "SELECT len(fractal_embed('hello world'));"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "fractal_embed dispatches through the plugin (3-dim canned vector)" "3"
  $r = sqlq_env -EnvPairs $embenv "SELECT fractal_embed(NULL) IS NULL;"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "fractal_embed passes NULL through as NULL" "true"
  # the input cap: an over-cap input is refused before any dispatch
  $r = sqlq_env -EnvPairs $embenv "SELECT len(fractal_embed(repeat('x', 4194305)));"
  $rc = $script:SQLQ_RC
  expect_err "exceeds the 4 MiB limit" $rc $r "an embed input over the 4 MiB cap is refused"
  # config error ladder
  $r = sqlq "SELECT fractal_embed('x');"; $rc = $script:SQLQ_RC
  expect_err "reasoning plugin not configured" $rc $r "embed tier reports the unconfigured plugin"
  $r = sqlq_env -EnvPairs @("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_embed_plugin")) `
      -UnsetPairs @("FSQL_REASONING_HTTP_EMBED_URL", "FSQL_REASONING_HTTP_EMBED_MODEL") `
      "SELECT fractal_embed('x');"
  $rc = $script:SQLQ_RC
  expect_err "FSQL_REASONING_HTTP_EMBED_URL is not configured" $rc $r "embed tier reports the missing endpoint"
  $r = sqlq_env -EnvPairs @(("FRACTALSQL_REASONING_PLUGIN=" + (Join-Path $script:BTROOT ("fractalsql_bt_nonexistent_plugin" + $script:PLUGSUF))), `
                            "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings") `
      "SELECT fractal_embed('x');"
  $rc = $script:SQLQ_RC
  expect_err "failed to load reasoning plugin" $rc $r "embed tier reports an unloadable plugin path"
  # over-limit: evil_embed hands back 16385 floats; the enforced dim cap
  # lives in the agents-side parse, before any corpus scan runs
  if (have_plugin "evil_embed_plugin") {
    $r = sqlq_env -EnvPairs @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "evil_embed_plugin")),
                              "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings") `
        "SELECT 'x' FROM fractal_search_agent('near doc-2','bt_telemetry','vec',50,30);"
    $rc = $script:SQLQ_RC
    expect_err "failed to parse embedding" $rc $r "16385-float embed response rejected at the agents parse cap"
  } else {
    skip "evil_embed fixture did not compile"
  }
  # vectorizer surface end to end (mock embed writes 3-dim vectors)
  $r = sqlq_env -EnvPairs $embenv `
      "CREATE TABLE bt_vembed(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" `
      "INSERT INTO bt_vembed VALUES (1, 'alpha doc about telemetry', NULL), (2, 'beta doc', NULL), (3, 'gamma doc', NULL);" `
      "SELECT fractal_vectorizer_create('bt_vembed','body','emb');"
  $rc = $script:SQLQ_RC
  $vid = (to_int (numerify $r))
  if (($rc -eq 0) -and ($vid -gt 0)) {
    pass ("vectorizer created for bt_vembed (id " + $vid + ")")
  } else {
    fail "vectorizer create (bt_vembed)"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
    return
  }
  $r = sqlq_env -EnvPairs $embenv "SELECT fractal_vectorizer_process_queue(20);"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "backfill drained: process_queue reports 3 embeds" "3"
  $r = sqlq "SELECT count(*) FROM bt_vembed WHERE len(emb) = 3;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "write-back populated a 3-dim embedding on every row" "3"
  $r = sqlq "SELECT pending, processing, done, failed FROM fractal_vectorizer_status() WHERE source_table = 'bt_vembed';"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "status ledger reads 0|0|3|0 after the drain" "0|0|3|0"
  $r = sqlq_env -EnvPairs $embenv "SELECT fractal_vectorizer_create('bt_vembed','body','emb');"
  $rc = $script:SQLQ_RC
  expect_err "already exists (id=" $rc $r "duplicate create names the vectorizer that already exists"
  $r = sqlq_env -EnvPairs $embenv "SELECT fractal_vectorizer_create('bt; DROP TABLE bt_vembed--','body','emb');"
  $rc = $script:SQLQ_RC
  expect_err "invalid identifier" $rc $r "injection-shaped source_table is refused as an identifier, never executed"
  $r = sqlq_env -EnvPairs $embenv "SELECT fractal_vectorizer_create('1_leading_digit','body','emb');"
  $rc = $script:SQLQ_RC
  expect_err "invalid identifier" $rc $r "digit-leading source_table refused"
  $r = sqlq_env -EnvPairs $embenv `
      "CREATE TABLE bt_vsq(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" `
      "INSERT INTO bt_vsq VALUES (1, 'a', NULL);" `
      "SELECT fractal_vectorizer_create('main.bt_vsq','body','emb');"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "schema-qualified source_table (main.bt_vsq) accepted"
  $r = sqlq "SELECT count(*) FROM fractal_vectorizer_status() WHERE source_table = 'main.bt_vsq';"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "schema-qualified source_table registers under its qualified name" "1"
  # drop it again, so the later gates' process_queue counts see only
  # the vectorizers they create themselves
  $null = sqlq "SELECT fractal_vectorizer_drop(id) FROM fractal_vectorizers WHERE source_table = 'main.bt_vsq';"
  # an unconfigured embed endpoint: every row fails cleanly, and a
  # failed row still counts as processed (it reached the end of its
  # attempt; leaving it out of the count would make a permanently
  # broken row look like a queue that is still moving)
  $r = sqlq `
      "CREATE TABLE bt_vnoembed(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" `
      "INSERT INTO bt_vnoembed VALUES (1, 'a', NULL), (2, 'b', NULL);" `
      "SELECT fractal_vectorizer_create('bt_vnoembed','body','emb');" `
      "SELECT 'PROCESSED=' || fractal_vectorizer_process_queue(10);" `
      "SELECT 'FAILED=' || count(*) FROM fractal_vectorizer_queue WHERE status='failed' " `
      "AND vectorizer_id = (SELECT id FROM fractal_vectorizers WHERE source_table='bt_vnoembed');" `
      "SELECT error FROM fractal_vectorizer_queue WHERE status='failed' LIMIT 1;"
  $rc = $script:SQLQ_RC
  if ($r.Contains("PROCESSED=2") -and $r.Contains("FAILED=2") -and
      $r.Contains("reasoning plugin not configured")) {
    pass "unconfigured embed endpoint fails every row cleanly, and the failures count as processed"
  } else {
    fail ("unconfigured embed endpoint: got " + (trunc $r))
  }
  $r = sqlq "SELECT count(*) FROM bt_vembed;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "nothing was dropped by the injection attempt" "3"
  # a source text over the 4 MiB embed cap: the row fails with the
  # vectorizer's own refusal rather than being sent to the endpoint
  $r = sqlq_env -EnvPairs $embenv `
      "CREATE TABLE bt_vbig(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" `
      "INSERT INTO bt_vbig VALUES (1, repeat('x', 4194305), NULL);" `
      "SELECT fractal_vectorizer_create('bt_vbig','body','emb');"
  $rc = $script:SQLQ_RC
  $vid = (to_int (numerify $r))
  if (($rc -eq 0) -and ($vid -gt 0)) {
    pass ("vectorizer created for the over-cap source table (id " + $vid + ")")
  } else {
    fail "vectorizer create (bt_vbig)"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
  }
  $r = sqlq_env -EnvPairs $embenv "SELECT fractal_vectorizer_process_queue(10);"
  $rc = $script:SQLQ_RC
  $r = sqlq "SELECT error FROM fractal_vectorizer_queue WHERE status='failed' AND vectorizer_id = (SELECT id FROM fractal_vectorizers WHERE source_table='bt_vbig') LIMIT 1;"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "an over-cap source text fails the row with the vectorizer's own refusal" "source text exceeds the 4 MiB embed limit"
  # pause/resume on a second vectorizer
  $r = sqlq_env -EnvPairs $embenv `
      "CREATE TABLE bt_vsoak_stub(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" `
      "INSERT INTO bt_vsoak_stub VALUES (1, 'stub body', NULL);" `
      "SELECT fractal_vectorizer_create('bt_vsoak_stub'::VARCHAR,'body'::VARCHAR,'emb'::VARCHAR);"
  $rc = $script:SQLQ_RC
  $vid = (to_int (numerify $r))
  if (($rc -eq 0) -and ($vid -gt 0)) {
    pass ("second vectorizer created (bt_vsoak_stub, id " + $vid + ")")
  } else {
    fail "second vectorizer create (bt_vsoak_stub)"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
    return
  }
  $r = sqlq_env -EnvPairs $embenv ("SELECT fractal_vectorizer_pause(" + $vid + ");")
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "pause acknowledged" "true"
  $r = sqlq_env -EnvPairs $embenv ("SELECT fractal_vectorizer_resume(" + $vid + ");")
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "resume acknowledged" "true"
  # clean up the stub queue so later gates' process_queue runs scan only
  # what they create here
  $null = sqlq_env -EnvPairs $embenv ("SELECT fractal_vectorizer_pause(" + $vid + ");")
}

function gate_16 {
  $null = sqlq "CREATE TABLE bt_nopk(a INTEGER, body TEXT, emb DOUBLE[]);" `
               "CREATE TABLE bt_compk(id1 INTEGER, id2 INTEGER, PRIMARY KEY(id1, id2));"
  $embenv = @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_embed_plugin")),
              "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings")
  $r = sqlq_env -EnvPairs $embenv "SELECT fractal_vectorizer_create('bt_missing_table_v','body','emb');"
  $rc = $script:SQLQ_RC
  expect_err "internal query failed" $rc $r "nonexistent source table rejected at create"
  $r = sqlq_env -EnvPairs $embenv "SELECT fractal_vectorizer_create('bt_nopk','body','emb');"
  $rc = $script:SQLQ_RC
  expect_err "has no declared PRIMARY KEY" $rc $r "no-PK source table rejected at create"
  $r = sqlq_env -EnvPairs $embenv "SELECT fractal_vectorizer_create('bt_compk','body','emb');"
  $rc = $script:SQLQ_RC
  expect_err "has a composite primary key" $rc $r "composite-PK source table rejected at create"
  skip "authorizer-driver half of this gate has no duckdb analog (see gate 08)"
}

function gate_17 {
  $embenv = @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_embed_plugin")),
              "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings")
  $null = sqlq "CREATE TABLE bt_vsoak(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" `
               "INSERT INTO bt_vsoak SELECT i, 'doc ' || i, NULL FROM generate_series(1, 100) AS g(i);"
  $r = sqlq "SELECT count(*) FROM bt_vsoak;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "100-row soak source staged" "100"
  $r = sqlq_env -EnvPairs $embenv "SELECT fractal_vectorizer_create('bt_vsoak','body','emb');"
  $rc = $script:SQLQ_RC
  $vid = (to_int (numerify $r))
  if (($rc -eq 0) -and ($vid -gt 0)) {
    pass ("soak vectorizer created (bt_vsoak, id " + $vid + ")")
  } else {
    fail "soak vectorizer create"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
    return
  }
  for ($i = 1; $i -le 6; $i++) {
    $want = 20
    if ($i -eq 6) { $want = 0 }
    $r = sqlq_env -EnvPairs $embenv "SELECT fractal_vectorizer_process_queue(20);"
    $rc = $script:SQLQ_RC
    expect_ok $rc $r ("drain pass " + $i + " reports " + $want + " embeds") ([string]$want)
  }
  $r = sqlq "SELECT pending, processing, done, failed FROM fractal_vectorizer_status() WHERE source_table = 'bt_vsoak';"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "final queue ledger reads 0|0|100|0" "0|0|100|0"
  $r = sqlq "SELECT count(*) FROM bt_vsoak WHERE len(emb) = 3;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "all 100 rows carry a write-back embedding" "100"
}

function gate_18 {
  $null = sqlq "CREATE TABLE bt_vcrash(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" `
               "INSERT INTO bt_vcrash VALUES (1, 'one', NULL), (2, 'two', NULL);"
  $r = sqlq "SELECT count(*) FROM bt_vcrash;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "crash-vectorizer source staged" "2"
  $r = sqlq_env -EnvPairs @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_embed_plugin")),
                            "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings") `
      "SELECT fractal_vectorizer_create('bt_vcrash','body','emb');"
  $rc = $script:SQLQ_RC
  $vid = (to_int (numerify $r))
  if (($rc -eq 0) -and ($vid -gt 0)) {
    pass ("crash vectorizer created (id " + $vid + ")")
  } else {
    fail "crash vectorizer create"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
    return
  }
  # die mid-drain: the embed tier loads the crash fixture, generate()
  # dereferences NULL, the CLI process dies inside process_queue
  # (deliberate crash: report-exempt -- see san_report)
  $script:SAN_EXEMPT = $true
  $r = sqlq_env -EnvPairs (san_crash_pairs @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "evil_crash_plugin")),
                            "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings")) `
      "SELECT fractal_vectorizer_process_queue(10);"
  $script:SAN_EXEMPT = $false
  $rc = $script:SQLQ_RC
  if (crashed $rc) {
    pass ("CLI died mid-process_queue (rc=" + $rc + ")")
  } else {
    fail "expected the embed step to kill the process mid-drain"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
    return
  }
  $deadline = (Get-Date).AddSeconds(30 * $script:TIMEOUT_MULT)
  $recovered = $false
  $out = ""
  while ((Get-Date) -lt $deadline) {
    $out = (& $script:DUCK -bail -batch -list @($script:DUCK_ARGS) $script:DB "SELECT count(*) FROM bt_vcrash;" 2>&1 |
            plain_lines | Out-String -Width 8192).TrimEnd()
    if ($LASTEXITCODE -eq 0) { $recovered = $true; break }
    Start-Sleep -Seconds 1
  }
  if (-not $recovered) {
    fail "database did not reopen within the recovery window"
    return
  }
  pass "database reopened safely after the mid-drain crash"
  if (out_has $out "2") {
    pass "source table rows intact after the crash"
  } else {
    fail "source table rows lost"
    Write-Host ("      got: " + (trunc $out))
  }
  # gate 15's write-backs are the persistence canary across gates
  $tbl = (sqlq "SELECT count(*) FROM duckdb_tables() WHERE table_name = 'bt_vembed';")
  if ((numerify $tbl) -ne "0") {
    $r = sqlq "SELECT count(*) FROM bt_vembed WHERE len(emb) = 3;"; $rc = $script:SQLQ_RC
    expect_ok $rc $r "gate-15 write-backs survived the crash too" "3"
  } else {
    skip "gate 15 did not run in this invocation (bt_vembed absent)"
  }
  # The vectorizer queue is persisted in the DB, not a TEMP table that
  # dies with the connection -- so the row that was
  # mid-embedding at the crash stays parked in 'processing' here, and the
  # crash's other row is still 'pending': the killed process never wrote
  # anything back, so the post-crash state is 1|1|0 (not 0|1|1).
  $r = sqlq "SELECT pending, processing, done FROM fractal_vectorizer_status() WHERE source_table = 'bt_vcrash';"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "stranded claim still parked in 'processing' after the crash" "1|1|0"
  # finish the drain on a healthy process: stale_after=1 reclaims the
  # stranded claim at once (the default reclaim window is 600s). The
  # claim must be older than the 1s window first, so wait it out.
  Start-Sleep -Seconds (2 * $script:TIMEOUT_MULT)
  $r = sqlq_env -EnvPairs @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_embed_plugin")),
                            "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings") `
      "SELECT fractal_vectorizer_process_queue(10, 1);"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "recovery drain reclaims the stranded claim and finishes it" "2"
  $r = sqlq "SELECT count(*) FROM bt_vcrash WHERE len(emb) = 3;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "both crash-source rows embedded after the recovery drain" "2"
}
function gate_19 {
  $r = sqlq "SELECT fractal_search([]::DOUBLE[], []::DOUBLE[]);"; $rc = $script:SQLQ_RC
  expect_err "query dim 0 out of range [1, 4096]" $rc $r "empty query vector rejected at the dim bound"
  # over-arena: a constant 4097-element list (one over the cap)
  $big = ((0..4096) | ForEach-Object { "0.1" }) -join ","
  $r = sqlq ("SELECT fractal_search([" + $big + "]::DOUBLE[], [" + $big + "]::DOUBLE[]);")
  $rc = $script:SQLQ_RC
  expect_err "out of range [1, 4096]" $rc $r "4097-dim query rejected at the vector cap"
  $r = sqlq "SELECT particle FROM fractal_search_explore('bt_explore','embedding',[0.5, 0.5]::DOUBLE[], NULL);"
  $rc = $script:SQLQ_RC
  expect_err "does not match bt_explore.embedding" $rc $r "explore dim mismatch names the table.column it checked"
  $r = sqlq "SELECT particle FROM fractal_search_explore('bt_explore','embedding',[1.0, 0.05, 0.0, 0.0]::DOUBLE[], '{""iterations"": 99999999}');"
  $rc = $script:SQLQ_RC
  expect_err "iterations 99999999 out of range [1, 10000]" $rc $r "explore options bound enforced"
  $r = sqlq "SELECT count(*) FROM bt_explore;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "nothing executed: bt_explore untouched" "60"
}

function gate_20 {
  wc_file $script:SQLTXT "canary-reason-response"
  $r = sqlq_env -EnvPairs @("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_reasoning_plugin")) `
      "SELECT fractal_reason('question');"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "fractal_reason returns the canned chat response" "canary-reason-response"
  $r = sqlq_env -EnvPairs @("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_reasoning_plugin")) `
      "SELECT fractal_reason(NULL) IS NULL;"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "fractal_reason passes NULL through as NULL" "true"
  $r = sqlq "SELECT fractal_text_to_sql(NULL) IS NULL;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "fractal_text_to_sql passes NULL through as NULL" "true"
  $r = sqlq "SELECT count(*) FROM fractal_search_explore('bt_explore','embedding',[1.0, 0.05, 0.0, 0.0]::DOUBLE[], '{""population_size"":');"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "malformed explore options fall back leniently to defaults"
  # process_queue bounds
  $r = sqlq_env -EnvPairs @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_embed_plugin")),
                            "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings") `
      "SELECT fractal_vectorizer_process_queue(0);"
  $rc = $script:SQLQ_RC
  expect_err "batch_size must be 1.." $rc $r "process_queue rejects batch_size 0"
  $r = sqlq "SELECT fractal_vectorizer_process_queue(100001);"; $rc = $script:SQLQ_RC
  expect_err "batch_size must be 1.." $rc $r "process_queue rejects a batch over the ceiling"
  $r = sqlq "SELECT fractal_vectorizer_process_queue(10, 0);"; $rc = $script:SQLQ_RC
  expect_err "stale_after must be a positive" $rc $r "process_queue rejects a non-positive stale window"
  # agents-side bound check (the [1, 20] band lives on fractal_sql_agent)
  $r = sqlq "SELECT * FROM fractal_sql_agent('q', ['bt_orders'], 0, false);"; $rc = $script:SQLQ_RC
  expect_err "max_retries out of range [1, 20]" $rc $r "fractal_sql_agent rejects max_retries 0"
  # staged stale-reclaim: the vectorizer's queue is persisted in the DB,
  # so the claim surgery happens through plain SQL
  $r = sqlq_env -EnvPairs @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_embed_plugin")),
                            "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings") `
      "CREATE TABLE bt_vstale(id INTEGER PRIMARY KEY, body TEXT, emb DOUBLE[]);" `
      "INSERT INTO bt_vstale VALUES (999, 'stale body', NULL);" `
      "SELECT fractal_vectorizer_create('bt_vstale','body','emb');"
  $rc = $script:SQLQ_RC
  $vid = (to_int (numerify $r))
  if (($rc -eq 0) -and ($vid -gt 0)) {
    pass ("stale-reclaim vectorizer created (id " + $vid + ")")
  } else {
    fail "stale-reclaim vectorizer create"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
    return
  }
  # a fresh claim is left alone by the stale window
  $null = sqlq "UPDATE fractal_vectorizer_queue SET status = 'processing', started_at = now() WHERE pk_value = '999';"
  $r = sqlq_env -EnvPairs @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_embed_plugin")),
                            "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings") `
      "SELECT fractal_vectorizer_process_queue(10, 600);"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "fresh 'processing' claim not touched by the stale window" "0"
  $r = sqlq "SELECT status FROM fractal_vectorizer_queue WHERE pk_value = '999';"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "fresh claim still 'processing'" "processing"
  # an old claim IS reclaimed and drained
  $null = sqlq "UPDATE fractal_vectorizer_queue SET status = 'processing', started_at = now() - INTERVAL '7200 seconds' WHERE pk_value = '999';"
  $r = sqlq_env -EnvPairs @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_embed_plugin")),
                            "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings") `
      "SELECT fractal_vectorizer_process_queue(10, 600);"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "7200s-old claim reclaimed and drained" "1"
  $r = sqlq "SELECT status FROM fractal_vectorizer_queue WHERE pk_value = '999';"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "reclaimed claim finished as 'done'" "done"
}

# ----------------------------------------------------------------
# Gate 21 -- the seeded mutation fuzzer.
# ----------------------------------------------------------------
# The corpus under tests\fuzz_corpus\ holds one statement per file.
# Every mutant is used in two roles:
#
#   1. as ordinary SQL fed to the CLI -- the assertion is robustness:
#      the CLI must never die abnormally, whatever the mutation did.
#   2. as a model reply handed to fractal_text_to_sql() -- the
#      assertion is the SECURITY boundary: the extension's SELECT-only
#      allowlist must still refuse anything that is not a single
#      SELECT. A reply that came back as "DELETE ..." is a fail.
#
# Role 2 is the interesting one: the extension parses a model's SQL
# and hands it back to the caller, who will run it. The allowlist is
# the only thing standing between a hallucinated DROP and a dropped
# table, so it is worth fuzzing rather than spot-checking.
#
# The PRNG is a fixed-seed LCG: the same FSQL_FUZZ_SEED always
# produces the same mutants, so a failure is reproducible.

# 31-bit LCG (the classic glibc constants). The state is masked to 31
# bits so the multiply stays inside int64.
$script:FZ_STATE = 0
function fz_rand {
  param([int]$n)
  if ($n -le 0) { return 0 }
  $script:FZ_STATE = (([int64]$script:FZ_STATE * 1103515245) + 12345) -band 0x7FFFFFFF
  return [int]($script:FZ_STATE % $n)
}

# The character pool a mutation draws from. Deliberately includes the
# characters that break SQL lexing (quotes, brackets, comment
# starters), the whitespace that changes statement shape, and two
# non-ASCII code points so the extension's UTF-8 handling is on the
# hook too.
function fz_alphabet {
  $a = [System.Collections.Generic.List[char]]::new()
  foreach ($c in ([char[]]'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789')) { $a.Add($c) }
  foreach ($c in ([char[]]';()[]{}<>*+-/%!,.:=@#$&|~^_ ')) { $a.Add($c) }
  $a.Add([char]9); $a.Add([char]10); $a.Add([char]13)
  $a.Add([char]0x00E9); $a.Add([char]0x20AC)
  return $a.ToArray()
}

# fz_mutate <text> <all seeds>: apply 1-3 mutations and return the
# result. The mutation kinds are the classic ones -- substitute,
# delete, insert, duplicate a slice, splice another seed in, inject
# a keyword -- because between them they turn a valid statement into
# something the extension has never seen.
function fz_mutate {
  param([string]$s, [string[]]$allSeeds)
  if (-not $s) { return $s }
  $alpha = fz_alphabet
  $kws = @("DELETE ", "DROP ", "UNION ", "INSERT ", "UPDATE ", "CREATE ", "ALTER ", "--", "/*", "*/",
           "' OR '1'='1", "0x", "%", "\", "||")
  $ops = 1 + (fz_rand 3)
  for ($i = 0; $i -lt $ops; $i++) {
    if ($s.Length -eq 0) { break }
    $op = fz_rand 6
    $len = $s.Length
    $pos = fz_rand $len
    switch ($op) {
      0 {
        $c = $alpha[ (fz_rand $alpha.Length) ]
        $s = $s.Substring(0, $pos) + $c + $s.Substring($pos + 1)
      }
      1 {
        $s = $s.Substring(0, $pos) + $s.Substring($pos + 1)
      }
      2 {
        $c = $alpha[ (fz_rand $alpha.Length) ]
        $s = $s.Substring(0, $pos) + $c + $s.Substring($pos)
      }
      3 {
        $n = 1 + (fz_rand 16)
        if (($pos + $n) -gt $len) { $n = $len - $pos }
        if ($n -gt 0) {
          $slice = $s.Substring($pos, $n)
          $s = $s.Substring(0, $pos) + $slice + $slice + $s.Substring($pos + $n)
        }
      }
      4 {
        if ($allSeeds -and $allSeeds.Count -gt 0) {
          $other = $allSeeds[ (fz_rand $allSeeds.Count) ]
          $cut = fz_rand ($other.Length + 1)
          $s = $s.Substring(0, $pos) + $other.Substring(0, [Math]::Min($cut, $other.Length)) + $s.Substring($pos)
        }
      }
      5 {
        $kw = $kws[ (fz_rand $kws.Count) ]
        $s = $s.Substring(0, $pos) + $kw + $s.Substring($pos)
      }
    }
    if ($s.Length -gt 4096) { $s = $s.Substring(0, 4096) }
  }
  return $s
}

# fz_count_statements <sql> -- the number of statements in a SQL text.
#
# A statement starts at the first character that is not whitespace, a
# comment, or the inside of a string literal or quoted identifier, and
# at every character that follows a semicolon. This is the harness'
# own check of the property the extension's allowlist promises: what
# comes back must be ONE statement. The extension decides that with
# DuckDB's parser; this counts it independently, so a hole in the
# allowlist shows up as a disagreement rather than as a silent pass.
function fz_count_statements {
  param([string]$sql)
  if (-not $sql) { return 0 }
  $n = 0
  $seen = $false
  $afterSemi = $false
  $i = 0
  $len = $sql.Length
  while ($i -lt $len) {
    $ch = $sql[$i]
    if ($ch -eq "'") {
      # a string literal; '' is an escaped quote
      $i++
      while ($i -lt $len) {
        if ($sql[$i] -eq "'") {
          if (($i + 1) -lt $len -and ($sql[$i + 1] -eq "'")) { $i += 2; continue }
          break
        }
        $i++
      }
      $i++
      if (-not $seen) { $n = 1; $seen = $true; $afterSemi = $false }
      elseif ($afterSemi) { $n++; $afterSemi = $false }
      continue
    }
    if ($ch -eq '"') {
      # a quoted identifier; "" is an escaped quote
      $i++
      while ($i -lt $len) {
        if ($sql[$i] -eq '"') {
          if (($i + 1) -lt $len -and ($sql[$i + 1] -eq '"')) { $i += 2; continue }
          break
        }
        $i++
      }
      $i++
      if (-not $seen) { $n = 1; $seen = $true; $afterSemi = $false }
      elseif ($afterSemi) { $n++; $afterSemi = $false }
      continue
    }
    if ($ch -eq "-" -and ($i + 1) -lt $len -and ($sql[$i + 1] -eq "-")) {
      while ($i -lt $len -and $sql[$i] -ne "`n") { $i++ }
      continue
    }
    if ($ch -eq "/" -and ($i + 1) -lt $len -and ($sql[$i + 1] -eq "*")) {
      $i += 2
      while (($i + 1) -lt $len -and -not (($sql[$i] -eq "*") -and ($sql[$i + 1] -eq "/"))) { $i++ }
      $i += 2
      continue
    }
    if ($ch -eq ";") { $afterSemi = $true; $i++; continue }
    if ([char]::IsWhiteSpace($ch)) { $i++; continue }
    if (-not $seen) { $n = 1; $seen = $true; $afterSemi = $false }
    elseif ($afterSemi) { $n++; $afterSemi = $false }
    $i++
  }
  return $n
}

# The wall-clock budget for ONE mutant, in milliseconds. A mutant can
# turn into an unbounded query (a recursive CTE, a cross-product
# blow-up), and a fuzzer that can hang the harness is a fuzzer that
# never finishes. Overridable with FSQL_FUZZ_TIMEOUT_MS.
$script:FZ_TIMEOUT_MS = 20000
if ($env:FSQL_FUZZ_TIMEOUT_MS) {
  $n = 0
  if ([int]::TryParse($env:FSQL_FUZZ_TIMEOUT_MS, [ref]$n) -and $n -gt 0) { $script:FZ_TIMEOUT_MS = $n }
}

# cli_run_bounded -Sql <text> [-Db <path>] [-EnvPairs @("K=V")]
#
# Runs the CLI with a wall-clock budget and returns
# @{ Out; Rc; TimedOut }. Two things make this different from the
# harness' sqlq: the budget (a mutant must not be able to hang the
# run), and no -bail -- a SQL error is reported and the run continues,
# which is what the fuzzer wants, because the only interesting outcome
# is the process dying.
function cli_run_bounded {
  param(
    [string]$Sql,
    [string]$Db = "",
    [string[]]$EnvPairs = @(),
    [int]$TimeoutMs = 0
  )
  if ($TimeoutMs -le 0) { $TimeoutMs = $script:FZ_TIMEOUT_MS }
  $tag = [guid]::NewGuid().ToString("N")
  $sqlfile = Join-Path $script:PDIR ("fz_" + $tag + ".sql")
  $outFile = Join-Path $script:PDIR ("fz_" + $tag + ".out")
  $errFile = Join-Path $script:PDIR ("fz_" + $tag + ".err")
  [IO.File]::WriteAllText($sqlfile, $Sql)
  $saved = @()
  foreach ($p in $EnvPairs) {
    if (-not $p) { continue }
    $i = $p.IndexOf("=")
    if ($i -lt 1) { continue }
    $k = $p.Substring(0, $i)
    $v = $p.Substring($i + 1)
    $old = [Environment]::GetEnvironmentVariable($k, "Process")
    $saved += ,@($k, ($null -ne $old), $old)
    [Environment]::SetEnvironmentVariable($k, $v, "Process")
  }
  $cliArgs = @("-batch", "-list", "-noheader", "-unsigned") + $script:DUCK_ARGS
  if ($Db) { $cliArgs += $Db }
  try {
    $proc = Start-Process -FilePath $script:DUCK -ArgumentList $cliArgs `
              -RedirectStandardInput $sqlfile -RedirectStandardOutput $outFile `
              -RedirectStandardError $errFile -NoNewWindow -PassThru
    $timedOut = -not $proc.WaitForExit($TimeoutMs)
    if ($timedOut) {
      try { $proc.Kill() } catch { }
      $null = $proc.WaitForExit(5000)
    }
    $raw = ""
    $stdout = ""
    if (Test-Path -LiteralPath $outFile) {
      $stdout = [string](Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
      $raw += $stdout
    }
    if (Test-Path -LiteralPath $errFile) {
      $raw += [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
    }
    # Out is stdout+stderr (a sanitizer report lands on stderr); StdOut is
    # stdout alone, which is what the SQL a statement returned looks like.
    # The two must not be confused: the extension's own warnings (a plugin
    # loaded without a signature) are stderr, and counting them as
    # statements is a false positive.
    if ($timedOut) { return @{ Out = $raw; StdOut = $stdout; Rc = -1; TimedOut = $true } }
    return @{ Out = $raw; StdOut = $stdout; Rc = [int]$proc.ExitCode; TimedOut = $false }
  } finally {
    for ($si = $saved.Count - 1; $si -ge 0; $si--) {
      $s = $saved[$si]
      if ($s[1]) { [Environment]::SetEnvironmentVariable($s[0], $s[2], "Process") }
      else { Remove-ProcessEnvVar $s[0] }
    }
    Remove-Item -LiteralPath $sqlfile, $outFile, $errFile -Force -ErrorAction SilentlyContinue
  }
}

# Run one script against a THROWAWAY database.
function fuzz_run_cli {
  param([string]$sql)
  $fzdb = Join-Path $script:PDIR "fuzz.db"
  Remove-Item -LiteralPath $fzdb -Force -ErrorAction SilentlyContinue
  try {
    return (cli_run_bounded -Sql $sql -Db $fzdb)
  } finally {
    Remove-Item -LiteralPath $fzdb -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ($fzdb + ".wal") -Force -ErrorAction SilentlyContinue
  }
}

# Hand a mutant to the extension as a model reply and report what the
# SELECT-only allowlist made of it. The probe asks for the WHOLE
# answer, not a prefix: the gate has to see the entire returned
# statement to count it (fz_count_statements), and a multi-line answer
# is exactly what a stacked-statement bypass would look like.
function fuzz_reply_probe {
  param([string]$reply)
  [IO.File]::WriteAllText($script:SQLTXT, $reply, [System.Text.Encoding]::ASCII)
  $sql = ("LOAD '" + $script:EXT_SLASH + "';" + "`n") +
         "SELECT fractal_text_to_sql('give me the orders data');"
  return (cli_run_bounded -Sql $sql -Db $script:DB `
            -EnvPairs @("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_reasoning_plugin")))
}

function gate_21 {
  $corpusDir = Join-Path $script:HERE "tests\fuzz_corpus"
  $seedFiles = @(Get-ChildItem -Path (Join-Path $corpusDir "*.sql") -ErrorAction SilentlyContinue | Sort-Object Name)
  if ($seedFiles.Count -eq 0) {
    skip "no fuzz corpus under tests\fuzz_corpus (nothing to mutate)"
    return
  }
  $seeds = @()
  foreach ($f in $seedFiles) { $seeds += (Get-Content -LiteralPath $f.FullName -Raw) }

  $iters = 120
  if ($env:FSQL_FUZZ_ITERS) {
    $n = 0
    if ([int]::TryParse($env:FSQL_FUZZ_ITERS, [ref]$n) -and $n -gt 0) { $iters = $n }
  }
  $budget = 60
  if ($env:FSQL_FUZZ_TIME) {
    $n = 0
    if ([int]::TryParse($env:FSQL_FUZZ_TIME, [ref]$n) -and $n -gt 0) { $budget = $n }
  }
  $fzSeed = 20260930
  if ($env:FSQL_FUZZ_SEED) {
    $n = 0
    if ([int]::TryParse($env:FSQL_FUZZ_SEED, [ref]$n)) { $fzSeed = $n }
  }
  $script:FZ_STATE = $fzSeed

  $mockOk = have_plugin "mock_reasoning_plugin"
  if (-not $mockOk) {
    Write-Host "      note: the mock reasoning plugin did not compile; the allowlist half of this gate is skipped"
  }

  # The gate's own detector, proved on a known input first: a counter
  # that silently always returned 1 would turn the whole allowlist
  # half of this gate into a no-op, and nothing else here would say so.
  if ((fz_count_statements "SELECT 1; DROP TABLE bt_orders") -ne 2) {
    fail "21 fuzz: the harness' own statement counter does not see a stacked statement -- the allowlist check below would be vacuous"
    return
  }
  if ((fz_count_statements "SELECT 'a;b'") -ne 1) {
    fail "21 fuzz: the harness' own statement counter does not see a semicolon inside a string literal"
    return
  }

  $ran = 0; $replyChecked = 0; $crashes = 0; $bypasses = 0; $reports = 0; $hangs = 0
  $sw = [Diagnostics.Stopwatch]::StartNew()
  for ($i = 0; $i -lt $iters; $i++) {
    if ($sw.Elapsed.TotalSeconds -ge $budget) { break }
    $base = $seeds[ (fz_rand $seeds.Count) ]
    $mut = fz_mutate $base $seeds
    $ran++

    # role 1: the mutant as ordinary SQL
    $res = fuzz_run_cli ("LOAD '" + $script:EXT_SLASH + "';" + "`n" + $mut)
    if ($res.TimedOut) {
      # A mutant that outran the budget was killed, not crashed: it is
      # reported (a hang is worth a human's eye) but it is not a
      # failure of the extension.
      $hangs++
      Write-Host ("      note: mutant " + $i + " outran the " + $script:FZ_TIMEOUT_MS + "ms budget and was killed")
      Write-Host ("      mutant: " + (trunc $mut 200))
    } elseif (crashed $res.Rc) {
      $crashes++
      fail ("21 fuzz: the CLI died on mutant " + $i + " (exit code " + $res.Rc + ")")
      Write-Host ("      mutant: " + (trunc $mut 200))
      break
    }
    if ($script:SAN -and (san_report $res.Out)) {
      $reports++
      fail ("21 fuzz: a sanitizer report fired on mutant " + $i)
      Write-Host ("      mutant: " + (trunc $mut 200))
      break
    }

    # role 2: the mutant as a model reply
    if ($mockOk) {
      $replyChecked++
      $r2 = fuzz_reply_probe $mut
      if ($r2.TimedOut) {
        $hangs++
        Write-Host ("      note: mutant " + $i + " outran the " + $script:FZ_TIMEOUT_MS + "ms budget on the allowlist path")
        Write-Host ("      mutant: " + (trunc $mut 200))
      }
      if ($script:SAN -and (san_report $r2.Out)) {
        $reports++
        fail ("21 fuzz: a sanitizer report fired on the allowlist path for mutant " + $i)
        Write-Host ("      mutant: " + (trunc $mut 200))
        break
      }
      if (($r2.Rc -eq 0) -and (-not $r2.TimedOut)) {
        # The allowlist accepted the reply. Two things must hold: the
        # statement it hands back starts with SELECT (or WITH ...),
        # and it is ONE statement. The second is the property the
        # extension decides with DuckDB's parser; the harness counts
        # the statements itself, so a hole in the allowlist shows up
        # as a disagreement rather than as a silent pass.
        # stdout only: the SQL the extension returned is stdout, and the
        # extension's own warnings are stderr -- counting those as
        # statements would fail the gate on a warning.
        $answer = ($r2.StdOut -replace "`r", "").Trim()
        $head = ""
        foreach ($line in ($answer -split "`n")) {
          if ($line.Trim() -ne "") { $head = $line.Trim(); break }
        }
        if ($head -notmatch '^(SELECT|WITH)') {
          $bypasses++
          fail ("21 fuzz: the SELECT-only allowlist returned a non-SELECT statement for mutant " + $i + ": " + $head)
          Write-Host ("      mutant: " + (trunc $mut 200))
          break
        }
        $stmts = fz_count_statements $answer
        if ($stmts -gt 1) {
          $bypasses++
          fail ("21 fuzz: the SELECT-only allowlist returned " + $stmts + " statements for mutant " + $i + ": " + (trunc $answer 120))
          Write-Host ("      mutant: " + (trunc $mut 200))
          break
        }
      }
    }
  }

  if ($crashes -eq 0 -and $bypasses -eq 0 -and $reports -eq 0) {
    pass ("21 fuzz: " + $ran + " mutant(s) from " + $seedFiles.Count + " seed(s) -- no crash, no allowlist bypass" +
          $(if ($replyChecked -gt 0) { ", " + $replyChecked + " checked against the allowlist" } else { "" }) +
          $(if ($hangs -gt 0) { ", " + $hangs + " killed on the wall-clock budget" } else { "" }))
  }
  # The invariant that outlives the run: nothing the fuzzer fed the
  # extension was ever executed.
  $r = sqlq "SELECT count(*) FROM bt_orders;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "the fuzzer never executed anything it fed the extension" "0"
}

function gate_22 {
  # -- analytics core --
  $r = sqlq "SELECT fractal_dimension_dfa([1.0, 2.0, 3.0]::DOUBLE[]);"; $rc = $script:SQLQ_RC
  expect_err "series needs >= 16 points" $rc $r "dfa rejects a too-short series"
  $acc = 0.0
  $dfa32 = for ($i = 0; $i -lt 32; $i++) { $acc = $acc + 0.7; Fm $acc 4 }
  $s = $dfa32 -join ","
  $r = sqlq ("SELECT fractal_dimension_dfa([" + $s + "]::DOUBLE[]);"); $rc = $script:SQLQ_RC
  $d = to_num $r
  if (($rc -eq 0) -and (-not [double]::IsNaN($d))) {
    pass "dfa exponent returned for the monotone walk"
  } else {
    fail "dfa exponent return shape"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
  }
  $sine = for ($i = 0; $i -lt 200; $i++) { Fm ([math]::Sin($i * 0.2)) 6 }
  $s = $sine -join ","
  $r = sqlq ("SELECT fractal_dimension_drift([" + $s + "]::DOUBLE[], 64);"); $rc = $script:SQLQ_RC
  expect_ok $rc $r "dimension_drift reports drift/recent_alpha/baseline_alpha" "recent_alpha"
  $r = sqlq "SELECT fractal_dimension_boxcount([0.0, 0.0, 0.1, 0.1, 0.2, 0.2]::DOUBLE[], 2);"; $rc = $script:SQLQ_RC
  expect_err "need >= 8 points" $rc $r "boxcount rejects a too-small point set"
  # the fixture: 40 jittered points with coordinate
  # magnitudes >= 1 -- the boxcount core reads a sub-unit bounding box
  # as degenerate even at sufficient density
  $ptsarr = for ($i = 1; $i -le 40; $i++) {
    (Fm ($i + (($i * 13) % 7) * 0.001) 4) + "," + (Fm ($i * 0.5 + (($i * 29) % 7) * 0.001) 4)
  }
  $pts = $ptsarr -join ","
  $r = sqlq ("SELECT fractal_dimension_boxcount([" + $pts + "]::DOUBLE[], 2);"); $rc = $script:SQLQ_RC
  $d = to_num $r
  if (($rc -eq 0) -and (-not [double]::IsNaN($d)) -and ($d -le 2)) {
    pass "boxcount dimension returned for the jittered ridge"
  } else {
    fail "boxcount return shape"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
  }
  $step = for ($i = 0; $i -lt 40; $i++) {
    if ($i -lt 20) { Fm 1.0 1 } else { Fm 3.0 1 }
  }
  $s = $step -join ","
  $r = sqlq ("SELECT fractal_change_point_detect([" + $s + "]::DOUBLE[], 10, 1.0);"); $rc = $script:SQLQ_RC
  expect_ok $rc $r "change_point_detect flags the step change" "[20]"
  $r = sqlq ("SELECT count(*) FROM fractal_periodogram([" + $s + "]::DOUBLE[], 3);"); $rc = $script:SQLQ_RC
  $n = (to_int (numerify $r))
  if (($rc -eq 0) -and ($n -ge 1)) {
    pass "periodogram tabulates freq/power rows"
  } else {
    fail "periodogram"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
  }
  # -- fractal_spectrogram_entropy: short-time spectral entropy, a plain
  # DOUBLE[] (a period-8 tone, 64 samples, window 16 / hop 8 -> 7 frames) --
  $tone = "[sin(2 * pi() * t / 8.0) for t in range(0, 64)]"
  $noise = "[sin(t * 12.9898) * 43758.5453 - floor(sin(t * 12.9898) * 43758.5453) for t in range(0, 64)]"
  $r = sqlq ("SELECT len(fractal_spectrogram_entropy(" + $tone + ", 16, 8));"); $rc = $script:SQLQ_RC
  expect_ok $rc $r "spectrogram_entropy yields one value per frame (64 samples, window 16, hop 8 -> 7)" "7"
  $r = sqlq ("SELECT list_min(e) >= 0 AND list_max(e) <= 1 FROM (SELECT fractal_spectrogram_entropy(" + $tone + ", 16, 8) AS e);"); $rc = $script:SQLQ_RC
  expect_ok $rc $r "every frame entropy is normalized into [0,1]" "true"
  $r = sqlq "SELECT list_max(fractal_spectrogram_entropy([1.0 for t in range(0, 64)], 16, 8));"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "a constant series reports 0.0 per frame, never NaN" "0.0"
  $r = sqlq ("SELECT (SELECT list_avg(fractal_spectrogram_entropy(" + $noise + ", 16, 8))) > (SELECT list_avg(fractal_spectrogram_entropy(" + $tone + ", 16, 8)));"); $rc = $script:SQLQ_RC
  expect_ok $rc $r "wideband noise reads more disordered than a tone" "true"
  $r = sqlq ("SELECT len(fractal_spectrogram_entropy(" + $tone + "));"); $rc = $script:SQLQ_RC
  expect_ok $rc $r "the 1-argument form defaults to window 64 / hop 32 (one frame for 64 samples)" "1"
  $r = sqlq ("SELECT len(fractal_spectrogram_entropy(" + $tone + ", 16, 8, 3));"); $rc = $script:SQLQ_RC
  expect_ok $rc $r "max_frames caps the output" "3"
  $r = sqlq "SELECT fractal_spectrogram_entropy(NULL::DOUBLE[], 16, 8) IS NULL;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "a NULL series passes through as NULL" "true"
  $r = sqlq ("SELECT fractal_spectrogram_entropy(" + $tone + ", 4, 2);"); $rc = $script:SQLQ_RC
  expect_err "window 4 out of range [8, 512]" $rc $r "spectrogram_entropy rejects window < 8"
  $r = sqlq ("SELECT fractal_spectrogram_entropy(" + $tone + ", 16, 0);"); $rc = $script:SQLQ_RC
  expect_err "hop must be > 0" $rc $r "spectrogram_entropy rejects hop <= 0"
  $r = sqlq ("SELECT fractal_spectrogram_entropy(" + $tone + ", 16, 8, 0);"); $rc = $script:SQLQ_RC
  expect_err "max_frames 0 out of range [1, 4096]" $rc $r "spectrogram_entropy rejects max_frames <= 0"
  $r = sqlq "SELECT fractal_spectrogram_entropy([1.0, 2.0, 3.0]::DOUBLE[], 16, 8);"; $rc = $script:SQLQ_RC
  expect_err "series shorter than window" $rc $r "spectrogram_entropy rejects a series shorter than the window"
  $r = sqlq "SELECT fractal_change_point_detect(fractal_spectrogram_entropy([(CASE WHEN t < 128 THEN sin(2 * pi() * t / 8.0) ELSE sin(t * 12.9898) * 43758.5453 - floor(sin(t * 12.9898) * 43758.5453) END) for t in range(0, 256)], 32, 16), 3, 8.0, 16);"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "the entropy series feeds change_point_detect (tone -> noise flags a boundary)" "["
  $r = sqlq ("SELECT fractal_tda_persistence_diagram([" + $pts + "]::DOUBLE[], 2, 1, 1.0);"); $rc = $script:SQLQ_RC
  expect_ok $rc $r "persistence diagram carries its bars and betti1" "betti1"
  $r = sqlq "SELECT len(hex(fractal_state_fingerprint([1.0, 0.0, 1.0, 1.0]::DOUBLE[], 64)));"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "state fingerprint n_bits=64 packs into 8 bytes" "16"
  # cycle_detect is a table function, and duckdb bans subqueries in table
  # function arguments -- so the alternating fingerprint stream is baked
  # in as BLOB literals (hex(fractal_state_fingerprint([1,0],[0,1],64))).
  # The threshold argument is a hamming threshold, and 64 is the full
  # fingerprint width: every 64-bit pair then reads as equal and the
  # loop closes at cycle_len 1 -- the gate uses a threshold well below
  # the width so the period-2 structure actually has to close.
  $fp = "x'EFFF65115A1D8D10', x'2B5CC30F8F43A34B', x'EFFF65115A1D8D10', x'2B5CC30F8F43A34B'," +
        " x'EFFF65115A1D8D10', x'2B5CC30F8F43A34B', x'EFFF65115A1D8D10', x'2B5CC30F8F43A34B'," +
        " x'EFFF65115A1D8D10', x'2B5CC30F8F43A34B'"
  $r = sqlq ("SELECT max(cycle_len) FROM fractal_cycle_detect([" + $fp + "]::BLOB[], 8);")
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "cycle detection closes the alternating fingerprint loop" "2"
  # -- portfolio --
  $r = sqlq "SELECT fractal_optimize_portfolio([0.10, 0.12, 0.07]::DOUBLE[], [0.04, 0.02, 0.01, 0.02, 0.06, 0.02, 0.01, 0.02, 0.05]::DOUBLE[], 2, 42);"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "optimize_portfolio returns scored weights" "weights"
  $r = sqlq "SELECT fractal_optimize_portfolio([0.10, 0.12, 0.07]::DOUBLE[], [0.04, 0.02]::DOUBLE[], 2, 42);"
  $rc = $script:SQLQ_RC
  expect_err "must be n_assets^2" $rc $r "cov length must be n_assets^2"
  $r = sqlq "SELECT fractal_optimize_subset([10.0, 9.0, 8.0, 7.0, 6.0]::DOUBLE[], [1.0, 1.0, 1.0, 1.0, 1.0]::DOUBLE[], 5);"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "optimize_subset returns scored weights" "weights"
  $r = sqlq "SELECT * FROM fractal_optimize_portfolio_multimodal_pareto([0.10, 0.12]::DOUBLE[], [0.04, 0.01, 0.01, 0.03]::DOUBLE[], 1);"
  $rc = $script:SQLQ_RC
  expect_err "requires the FractalSQL Enterprise tier" $rc $r "pareto frontier stays gated behind the enterprise tier"
  # -- geometry -- (fixture: a 30-node 3D
  # vessel chain with POSITIVE rand()*0.01 jitter and per-edge arc lengths
  # computed as the euclidean distance between consecutive nodes -- signed
  # jitter with exact-1.0 arcs makes the core reject the graph)
  $vrx = New-Object 'double[]' 30
  $vry = New-Object 'double[]' 30
  $vrz = New-Object 'double[]' 30
  $vr = [System.Random]::new(1)
  $vascncarr = @(); $vascelarr = @(); $vascalarr = @()
  for ($i = 0; $i -lt 30; $i++) {
    $vrx[$i] = [double]$i
    $vry[$i] = $vr.NextDouble() * 0.01
    $vrz[$i] = $vr.NextDouble() * 0.01
    $vascncarr += (Fm $vrx[$i] 1) + "," + (Fm $vry[$i] 6) + "," + (Fm $vrz[$i] 6)
    if ($i -gt 0) {
      $vascelarr += ("$($i - 1),$i")
      $vdx = $vrx[$i] - $vrx[$i - 1]
      $vdy = $vry[$i] - $vry[$i - 1]
      $vdz = $vrz[$i] - $vrz[$i - 1]
      $vascalarr += (Fm ([math]::Sqrt($vdx*$vdx + $vdy*$vdy + $vdz*$vdz)) 9)
    }
  }
  $vascnc = $vascncarr -join ","
  $vascel = $vascelarr -join ","
  $vascal = $vascalarr -join ","
  $r = sqlq ("SELECT fractal_vascular_network([" + $vascnc + "]::DOUBLE[], [" + $vascel + "]::BIGINT[], [" + $vascal + "]::DOUBLE[]);")
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "vascular network metric parses the graph fixture" "fractal_dimension"
  $r = sqlq "SELECT fractal_cortical_folding([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0, 1.0, 1.0]::DOUBLE[], [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]::BIGINT[]);"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "cortical folding returns its gyrification key" "gyrification_index"
  $nervearr = for ($i = 0; $i -lt 80; $i++) {
    (Fm ([double]$i) 1) + "," + (Fm ((($i % 2) * 1.0) + (((($i * 7) % 5) - 2) * 0.001)) 4)
  }
  $nerve = $nervearr -join ","
  $nerveelarr = for ($i = 0; $i -lt 79; $i++) { "$i," + ($i + 1) }
  $nerveel = $nerveelarr -join ","
  $r = sqlq ("SELECT fractal_nerve_plexus_metric([" + $nerve + "]::DOUBLE[], 2, [" + $nerveel + "]::BIGINT[]);")
  $rc = $script:SQLQ_RC
  $r = sqlq ("SELECT fractal_morphological_complexity([" + $pts + "]::DOUBLE[], 2);"); $rc = $script:SQLQ_RC
  expect_ok $rc $r "morphological complexity returns dimension/lacunarity" "lacunarity"
  # -- diversify + explain (community ledger surface) --
  $r = sqlq "SELECT fractal_diversify_enable();"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "diversify_enable reports its state" "true"
  $r = sqlq "SELECT fractal_explain_result();"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "explain_result carries the dq key" '"dq"'
  # -- telemetry / hybrid / trajectory (core numeric posture) --
  $r = sqlq "SELECT d.id FROM fractal_search_telemetry('bt_telemetry','vec',[0.6, 0.8, 0.0, 0.0]::DOUBLE[], 2) t `
        JOIN bt_telemetry d ON CAST(d.rowid AS VARCHAR) = t.doc_id ORDER BY t.distance LIMIT 1;"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "telemetry doc_id joins back to the source row (nearest first)" "1"
  $r = sqlq "SELECT scan_pos FROM fractal_search_telemetry('bt_telemetry','vec',[0.6, 0.8, 0.0, 0.0]::DOUBLE[], 2) LIMIT 1;"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "scan position starts at 0 for the nearest hit" "0"
  $r = sqlq "SELECT 'x' FROM fractal_search_telemetry('bt_telemetry','vec',[0.0, 0.0, 0.0, 0.0]::DOUBLE[], 0);"
  $rc = $script:SQLQ_RC
  expect_err "out of range [1," $rc $r "telemetry k bound enforced"
  $r = sqlq "SELECT 'x' FROM fractal_hybrid_clinical_search('bt_telemetry','vec',[0.0, 1.0, 0.0, 0.0]::DOUBLE[], ['2','4','5'], 3);"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "hybrid clinical search honors the rowid cohort"
  $r = sqlq "SELECT 'x' FROM fractal_hybrid_clinical_search('bt_telemetry','vec',[0.0, 1.0, 0.0, 0.0]::DOUBLE[], ['9999999'], 3);"
  $rc = $script:SQLQ_RC
  expect_err "doc_ids cohort matched no rows" $rc $r "zero-cohort hybrid search reports the miss"
  $r = sqlq "SELECT 'x' FROM fractal_search_trajectory('bt_traj','vec',[0.0, 0.0, 0.0, 0.0]::DOUBLE[],[0.3, 0.0, 0.0, 0.0]::DOUBLE[], 3);"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "search_trajectory returns the trajectory corridor"
  # the ledger
  # reads its OWN fsql ctx, which a fresh CLI process has never run a
  # search through, so the
  # score legitimately reads NaN here -- a non-NaN assertion cannot be
  # reproduced through the CLI
  $r = sqlq "SELECT fractal_detect_collapse();"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "detect_collapse responds" "-nan"
  # -- vector math --
  $r = sqlq "SELECT fractal_vector_lp_distance([1.0, 0.0, 0.0]::FLOAT[], [0.5, 0.0, 0.0]::FLOAT[], 2.0);"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "lp distance p=2 reports the half-step" "0.5"
  $r = sqlq "SELECT fractal_vector_lp_distance([1.0, 0.0, 0.0]::FLOAT[], [0.5, 0.0, 0.0]::FLOAT[], 0.0);"
  $rc = $script:SQLQ_RC
  expect_err "p must be > 0" $rc $r "lp distance rejects p=0"
  # the proportional pair only zeroes out at the float32 epsilon, so the
  # gate rounds before comparing
  $r = sqlq "SELECT round(fractal_vector_cosine_distance([1.0, 2.0, 3.0]::FLOAT[], [2.0, 4.0, 6.0]::FLOAT[]), 6);"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "cosine distance of proportional vectors rounds to 0" "0.0"
  $r = sqlq "SELECT json_extract(fractal_vector_quantize_int8([1.0, -1.0, 0.5]::FLOAT[]), '$' || '.scale') IS NOT NULL;"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "int8 quantization carries a scale" "true"
  $ten_bits = "1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0"
  $r = sqlq ("SELECT octet_length(fractal_vector_quantize_binary([" + $ten_bits + "]::FLOAT[]));")
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "binary quantization packs 10 bits into 2 bytes" "2"
  $r = sqlq ("SELECT fractal_vector_hamming_distance(fractal_vector_quantize_binary([" + $ten_bits + "]::FLOAT[]), fractal_vector_quantize_binary([" + $ten_bits + "]::FLOAT[]));")
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "hamming distance of identical blobs is 0" "0"
  $r = sqlq ("SELECT fractal_vector_hamming_distance(fractal_vector_quantize_binary([" + $ten_bits + "]::FLOAT[]), fractal_vector_quantize_binary([1.0, 1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0]::FLOAT[]));")
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "hamming distance counts one flipped sign" "1"
}

function gate_23 {
  $embenv = @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_embed_plugin")),
              "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings")
  # the search/rag agents embed their query through the EMBED tier (the
  # mock's canned 3-dim vector), so the corpus is 3-dim to match
  $null = sqlq "CREATE TABLE bt_agent_docs(id INTEGER, tag VARCHAR, body VARCHAR, emb DOUBLE[]);" `
               "INSERT INTO bt_agent_docs VALUES " `
               " (1, 'doc-1', 'doc-a about cosine metrics', [1.0, 0.05, 0.0])," `
               " (2, 'doc-2', 'doc-b about vector stores', [1.0, 0.1, 0.0])," `
               " (3, 'doc-3', 'doc-c about fractal search', [0.05, 1.0, 0.0])," `
               " (4, 'doc-4', 'doc-d on SFS optimization', [0.1, 0.95, 0.0])," `
               " (5, 'doc-5', 'doc-e on embedding tiers', [0.05, 0.0, 1.0]);"
  $r = sqlq "SELECT count(*) FROM bt_agent_docs;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "agent fixture table staged" "5"
  # fractal_cross_modal_search concatenates its two modality vectors
  # (morphology ++ clinical) into one query of its combined dim, so
  # its corpus needs that combined dim, not bt_agent_docs's 3 (sized for
  # the EMBED tier's canned output) -- a separate 6-dim (3+3) fixture.
  # bt_traj itself is created in bt_setup (PK + the 0.0..0.4 reference
  # walk) -- re-creating it here would collide with that; bt_setup also
  # runs in single-gate mode, so the same fixture serves every entry.
  $null = sqlq "CREATE TABLE bt_agent_docs_xmodal(id INTEGER, body VARCHAR, emb DOUBLE[]);" `
               "INSERT INTO bt_agent_docs_xmodal VALUES " `
               " (1, 'xm-a morph-heavy', [1.0, 0.05, 0.0, 0.05, 0.0, 0.0])," `
               " (2, 'xm-b balanced', [0.5, 0.5, 0.0, 0.5, 0.5, 0.0])," `
               " (3, 'xm-c clinical-heavy', [0.0, 0.05, 0.0, 1.0, 0.05, 0.0]);"
  # search_agent: embed (mock), scan, answer (chat mock) -- the shape is
  # everything, the content is canned
  $r = sqlq_env -EnvPairs $embenv `
      "SELECT (answer IS NOT NULL) AND (len(source_doc_ids) >= 1) FROM fractal_search_agent('near doc-1','bt_agent_docs','emb',50,30);"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "search_agent embeds, scans, and answers with doc ids" "true"
  # rag_agent: same pipeline minus the answer synthesis
  $r = sqlq_env -EnvPairs $embenv `
      "SELECT (answer IS NOT NULL) FROM fractal_rag_agent('near doc-1','bt_agent_docs','emb','{}');"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "rag_agent returns an answer row" "true"
  # sql_agent: never executes under auto_execute=false, reports the
  # pipeline status per row
  wc_file $script:SQLTXT "SELECT count(*) FROM bt_agent_docs"
  $r = sqlq_env -EnvPairs @("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_reasoning_plugin")) `
      "SELECT (len(generated_sql) > 0) AND (retry_count IS NOT NULL) FROM fractal_sql_agent('how many rows live in bt_agent_docs', ['bt_agent_docs'], 3, false);"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "sql_agent returns the generated_sql + retry pipeline columns" "true"
  wc_file $script:SQLTXT "DROP TABLE bt_agent_docs"
  $r = sqlq_env -EnvPairs @("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_reasoning_plugin")) `
      "SELECT execution_status FROM fractal_sql_agent('nuke it', ['bt_agent_docs'], 1, false);"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "sql_agent surfaces validation_failed for rejected SQL" "validation_failed"
  # plan_explore: two branches planned from the fixture corpus (it rides
  # the reasoning plugin like every LLM-adjacent agent)
  $r = sqlq_env -EnvPairs $embenv "SELECT count(*) FROM fractal_agent_plan_explore('1.0,0.0,0.0,0.0','bt_agent_docs','emb',2);"
  $rc = $script:SQLQ_RC
  $n = (to_int (numerify $r))
  if (($rc -eq 0) -and ($n -ge 2)) {
    pass "plan_explore produced the requested branch count"
  } else {
    fail "plan_explore"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
  }
  # trajectory_predict: baseline row 1 vs the corridor ahead
  $r = sqlq_env -EnvPairs $embenv "SELECT max(projected_drift_delta) FROM fractal_agent_trajectory_predict('bt_traj','vec',1,2);"
  $rc = $script:SQLQ_RC
  $d = to_num $r
  if (($rc -eq 0) -and (-not [double]::IsNaN($d))) {
    pass "trajectory_predict reports a numeric drift projection"
  } else {
    fail "trajectory_predict"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
  }
  # detect_loop: one-hot alternation closes the cycle; distinct
  # directions with varied norms do not (32 states -- the DFA needs
  # >= 24 points and a non-constant series, and the fingerprint is
  # SimHash over a 2-dim state so direction spread matters)
  $states = ((0..15) | ForEach-Object {
    if ($_ % 2 -eq 0) { "1.0,0.0" } else { "0.0,1.0" }
  }) -join ","
  $r = sqlq ("SELECT fractal_agent_detect_loop('agent-t1', [" + $states + "]::DOUBLE[], 2).is_loop_detected;")
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "one-hot alternation flags the state loop" "true"
  $states2 = "0.999,0.05, 1.261,0.317, 0.633,0.3, 0.963,0.716," +
             "0.604,0.667, 0.719,1.201, 0.202,0.565, 0.16,1.088," +
             "-0.04,0.799, -0.366,1.455, -0.3,0.633, -0.775,1.043," +
             "-0.667,0.604, -1.03,0.616, -0.565,0.202, -1.385,0.204," +
             "-0.999,-0.05, -0.776,-0.195, -1.175,-0.557, -0.562,-0.418," +
             "-1.006,-1.112, -0.462,-0.772, -0.37,-1.036, -0.087,-0.594," +
             "0.06,-1.199, 0.341,-1.358, 0.343,-0.723, 0.418,-0.562," +
             "0.964,-0.872, 0.858,-0.513, 1.413,-0.504, 0.89,-0.131"
  $r = sqlq ("SELECT fractal_agent_detect_loop('agent-t2', [" + $states2 + "]::DOUBLE[], 2).is_loop_detected;")
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "drifting walk reads loop-free" "false"
  # telemetry over the fixture table
  $r = sqlq "SELECT count(*) FROM fractal_search_telemetry('bt_agent_docs','emb',[1.0, 0.0, 0.0]::DOUBLE[], 2) WHERE doc_id IS NOT NULL;"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "telemetry reports scan diagnostics for k hits" "2"
  $r = sqlq "SELECT count(*) FROM fractal_hybrid_clinical_search('bt_agent_docs','emb',[1.0, 0.0, 0.0]::DOUBLE[], ['1','2','3'], 2);"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "hybrid search narrows to the cohort" "2"
  $r = sqlq "SELECT 'x' FROM fractal_hybrid_clinical_search('bt_agent_docs','emb',[1.0, 0.0, 0.0]::DOUBLE[], []::VARCHAR[], 2);"
  $rc = $script:SQLQ_RC
  expect_err "doc_ids must be non-empty" $rc $r "empty cohort rejected"
  # cross_modal + guards (queries stay 3-dim each; the fixture table
  # carries the combined 6-dim)
  $r = sqlq "SELECT count(*) FROM fractal_cross_modal_search('bt_agent_docs_xmodal','emb',[1.0, 0.0, 0.0]::DOUBLE[], [0.0, 1.0, 0.0]::DOUBLE[], 0.5, 2);"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "cross_modal search blends morphology and clinical vectors"
  $r = sqlq "SELECT 'x' FROM fractal_cross_modal_search('bt_agent_docs_xmodal','emb',[1.0, 0.0, 0.0]::DOUBLE[], [0.0, 1.0, 0.0]::DOUBLE[], 1.5, 2);"
  $rc = $script:SQLQ_RC
  expect_err "alpha_weight must be in [0,1]" $rc $r "cross_modal alpha bound enforced"
  $r = sqlq "SELECT 'x' FROM fractal_hybrid_clinical_search('bt_agent_docs','emb',[1.0, 0.0, 0.0]::DOUBLE[], ['1','2'], 0);"
  $rc = $script:SQLQ_RC
  expect_err "out of range [1," $rc $r "hybrid k bound enforced"
  # empty corpus
  $null = sqlq "CREATE TABLE bt_agent_empty(id INTEGER, emb DOUBLE[]);"
  $r = sqlq_env -EnvPairs $embenv "SELECT 'x' FROM fractal_search_agent('q','bt_agent_empty','emb',50,30);"
  $rc = $script:SQLQ_RC
  expect_err "no rows found in bt_agent_empty.emb" $rc $r "empty corpus reported distinctly after the embed step"
  $r = sqlq "SELECT fractal_explain_result();"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "explain_result closes the pipeline (dq key present)" '"dq"'
}

function gate_24 {
  $r = sqlq "SELECT fractal_ledger_flush();"; $rc = $script:SQLQ_RC
  expect_err "requires the FractalSQL Enterprise tier" $rc $r "ledger_flush reports the dormant enterprise tier"
  $r = sqlq "SELECT fractal_audit_log('bt-entry', '{}');"; $rc = $script:SQLQ_RC
  expect_err "requires the FractalSQL Enterprise tier" $rc $r "audit_log reports the dormant enterprise tier"
  # a configured-but-unloadable lib surfaces the loader detail on stderr
  # (the dormant-tier message rides along with it; both lines land in
  # the captured output)
  $badlib = Join-Path $script:BTROOT ("fractalsql_bt_nonexistent_enterprise" + $script:PLUGSUF)
  $r = sqlq_env -EnvPairs @(("FRACTALSQL_ENTERPRISE_LIB=" + $badlib), "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0") `
      "SELECT fractal_ledger_flush();"
  $rc = $script:SQLQ_RC
  expect_err "could not load enterprise library" $rc $r "unloadable enterprise lib reports the loader error"
  if (out_has $r "requires the FractalSQL Enterprise tier") {
    pass "dormant-tier message retained alongside the loader detail"
  } else {
    fail "dormant-tier message missing next to the loader error"
    Write-Host ("      got: " + (trunc $r))
  }
}
function gate_25 {
  if ($script:SAN) {
    skip "python driver gate under -Asan/-Ubsan: the pip-duckdb host process cannot be instrumented (known Windows load_extension issue)"
    return
  }
  $entlib = $env:FSQL_TEST_ENTERPRISE_LIB
  if ((-not $entlib) -or (-not (Test-Path -LiteralPath $entlib))) {
    skip "no enterprise core configured for stress (set FSQL_TEST_ENTERPRISE_LIB to a compiled enterprise core library)"
    return
  }
  if (-not $script:PY) {
    skip "python with the pip duckdb package is unavailable (set FSQL_PYTHON)"
    return
  }
  $pyMajor = pip_duckdb_major
  if ($pyMajor -ne $script:DUCK_MAJOR) {
    skip ("the pip duckdb package is " + $pyMajor + ".x but the CLI under test is " +
          $script:DUCK_MAJOR + ".x -- the driver cannot read this engine's database file nor load its extension")
    return
  }
  $py25 = @'
import concurrent.futures as cf
import duckdb, os, sys

db  = os.environ["FSQL_BT_DB"]
ext = os.environ["FSQL_BT_EXT"].replace("'", "''")

os.environ["FRACTALSQL_ENTERPRISE_LIB"] = os.environ["FSQL_TEST_ENTERPRISE_LIB"]
os.environ["FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE"] = "0"   # test core ships unsigned
cfg = {"allow_unsigned_extensions": "true"}

con = duckdb.connect(db, config=cfg)
con.execute(f"LOAD '{ext}'")

# verify() must run with the core loaded and keep its exact contract
v = con.execute("SELECT fractal_ledger_verify();").fetchone()[0]
assert str(v).startswith('{"ok": true'), f"verify contract changed: {v!r}"

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
assert str(v).startswith('{"ok": true'), f"verify broke after churn: {v!r}"
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
'@
  [IO.File]::WriteAllText((Join-Path $script:PDIR "gate25.py"), $py25, [System.Text.Encoding]::ASCII)
  [Environment]::SetEnvironmentVariable("FSQL_TEST_ENTERPRISE_LIB", $entlib, "Process")
  $r = py_run (Join-Path $script:PDIR "gate25.py")
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "enterprise core absorbed the in-process churn (verify contract intact)" "gate-25-ok"
}

function gate_26 {
  # with NO lib configured: the clean dormant-tier message
  $r = sqlq "SELECT fractal_ledger_load();"; $rc = $script:SQLQ_RC
  expect_err "requires the FractalSQL Enterprise tier" $rc $r "unconfigured FRACTALSQL_ENTERPRISE_LIB reports the clean dormant-tier message"
  # with a configured-but-unloadable lib: the loader detail surfaces too
  $badlib = Join-Path $script:BTROOT ("fractalsql_bt_nonexistent_enterprise" + $script:PLUGSUF)
  $r = sqlq_env -EnvPairs @(("FRACTALSQL_ENTERPRISE_LIB=" + $badlib), "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0") `
      "SELECT fractal_ledger_reset_soft();"
  $rc = $script:SQLQ_RC
  expect_err "could not load enterprise library" $rc $r "configured-but-unloadable lib surfaces the loader detail"
  # signature refusals are covered by gate 32
}

function gate_27 {
  if (-not (have_plugin "think_reasoning_plugin")) {
    skip "think_reasoning fixture did not compile"
    return
  }
  $thinkenv = @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "think_reasoning_plugin")),
                "FSQL_REASONING_HTTP_THINK=medium",
                "FSQL_REASONING_HTTP_THINK_PROVIDER=local_http",
                "FSQL_REASONING_HTTP_NATIVE_URL=https://think.invalid/internal",
                "FSQL_REASONING_HTTP_NUM_CTX=4096")
  # CHAT forwards all four THINK keys into the GENERATE dispatch
  Remove-Item -LiteralPath $script:THINKDUMP -Force -ErrorAction SilentlyContinue
  $r = sqlq_env -EnvPairs $thinkenv "SELECT fractal_reason('q');"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "chat dispatch ran through the think fixture" "OK"
  $kv = rc_file $script:THINKDUMP
  if ((out_has $kv "THINK=medium") -and (out_has $kv "THINK_PROVIDER=local_http") -and `
      (out_has $kv "NATIVE_URL=https://think.invalid/internal") -and (out_has $kv "NUM_CTX=4096")) {
    pass "all four THINK keys forwarded through the CHAT tier"
  } else {
    fail "THINK keys dropped on the CHAT path"
    Write-Host ("      dump: " + (trunc $kv))
  }
  # T2S's GENERATE passes them through too (RESPONSE_MODE is forced to
  # code at tier load; the think keys are untouched). The canned "OK"
  # response fails the SQL parse ladder on purpose -- the dispatch
  # itself must survive it.
  wc_file $script:SQLTXT "SELECT 1"
  Remove-Item -LiteralPath $script:THINKDUMP -Force -ErrorAction SilentlyContinue
  $r = sqlq_env -EnvPairs $thinkenv "SELECT fractal_text_to_sql('q');"
  $rc = $script:SQLQ_RC
  $kv = rc_file $script:THINKDUMP
  if ((out_has $kv "THINK=medium") -and (out_has $kv "NUM_CTX=4096")) {
    pass "THINK keys forwarded through the T2S GENERATE path"
  } else {
    fail "THINK keys dropped on the T2S path"
    Write-Host ("      dump: " + (trunc $kv))
  }
  expect_survive $rc $r "T2S call survived the canned non-SQL response"
  # EMBED must NOT see any of them
  Remove-Item -LiteralPath $script:THINKDUMP -Force -ErrorAction SilentlyContinue
  $r = sqlq_env -EnvPairs @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "think_reasoning_plugin")),
                            "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings",
                            "FSQL_REASONING_HTTP_THINK=medium",
                            "FSQL_REASONING_HTTP_THINK_PROVIDER=local_http",
                            "FSQL_REASONING_HTTP_NATIVE_URL=https://think.invalid/internal",
                            "FSQL_REASONING_HTTP_NUM_CTX=4096") `
      "SELECT fractal_embed('x');"
  $rc = $script:SQLQ_RC
  expect_err "non-numeric-array" $rc $r "embed dispatch ran (think fixture's non-vector response refused)"
  $kv = rc_file $script:THINKDUMP
  if ((out_has $kv "THINK=(unset)") -and (out_has $kv "THINK_PROVIDER=(unset)") -and `
      (out_has $kv "NATIVE_URL=(unset)") -and (out_has $kv "NUM_CTX=(unset)")) {
    pass "no THINK key leaked into the EMBED tier context"
  } else {
    fail "THINK keys leaked into the EMBED tier context"
    Write-Host ("      dump: " + (trunc $kv))
  }
}

function gate_28 {
  wc_file $script:SQLTXT "SELECT 1"
  # 1: T2S's GENERATE runs under the hard-forced code mode...
  Remove-Item -LiteralPath $script:REVIEWDUMP -Force -ErrorAction SilentlyContinue
  $r = sqlq_env -EnvPairs @("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_reasoning_plugin")) `
      "SELECT fractal_text_to_sql('q');"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "T2S GENERATE returned the canned SQL un-fenced" "SELECT 1"
  $dump = rc_file $script:REVIEWDUMP
  if (out_has $dump "RESPONSE_MODE=code") {
    pass "T2S's lazy reasoning ctx loaded under RESPONSE_MODE=code"
  } else {
    fail "T2S dispatch did not run under the forced code mode"
    Write-Host ("      dump: " + (trunc $dump))
  }
  # 2: ...and a CHAT call in the same process must not inherit it: one
  # CLI invocation = one duckdb process = one set of lazy tier contexts
  Remove-Item -LiteralPath $script:REVIEWDUMP -Force -ErrorAction SilentlyContinue
  $r = sqlq_env -EnvPairs @("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_reasoning_plugin")) `
      "SELECT fractal_reason('chat one');" `
      "SELECT fractal_text_to_sql('q');" `
      "SELECT fractal_reason('chat two');"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "chat calls interleave cleanly with the T2S call in-process"
  $dump = rc_file $script:REVIEWDUMP
  # the fixture is one dlopen-cached module, so the init-captured line
  # holds the last tier's re-init value (t2s's "code"); the chat tier's
  # own isolation shows up in the LIVE line read at this dispatch
  if (out_has $dump "LIVE_RESPONSE_MODE=(unset)") {
    pass "the CHAT tier ctx kept the boot-cured (unset) RESPONSE_MODE"
  } else {
    fail "CHAT tier inherited the T2S-forced code mode"
    Write-Host ("      dump: " + (trunc $dump))
  }
  # 3: the critique round dispatches on its OWN tier, whose response
  # mode is unset: the T2S tier's forced "code" mode must not leak into
  # it (a fenced verdict would hide the leading PASS/FAIL).
  Remove-Item -LiteralPath $script:REVIEWDUMP -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $script:REVIEWTXT -Force -ErrorAction SilentlyContinue
  wc_file $script:SQLTXT "SELECT 1"
  $r = sqlq_env -EnvPairs @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_reasoning_plugin")),
                            "FRACTALSQL_TEXT_TO_SQL_USE_REVIEW=on") `
      "SELECT fractal_text_to_sql('q');"
  $rc = $script:SQLQ_RC
  $dump = rc_file $script:REVIEWDUMP
  if (out_has $dump "LIVE_RESPONSE_MODE=(unset)") {
    pass "the REVIEW tier dispatched with RESPONSE_MODE unset"
  } else {
    fail "REVIEW tier inherited the T2S-forced code mode"
    Write-Host ("      dump: " + (trunc $dump))
    Write-Host ("      rc=" + $rc + " out=" + (trunc $r))
  }
  # 4: the endpoints stay apart as well. The embedding tier points the
  # extension's own configuration at the embeddings endpoint before it
  # loads, so a chat tier that loads afterwards has to be given the chat
  # endpoint again -- otherwise the chat call is dispatched to the
  # embeddings endpoint and fails.
  Remove-Item -LiteralPath $script:REVIEWDUMP -Force -ErrorAction SilentlyContinue
  wc_file $script:SQLTXT "chat-endpoint-canary"
  $r = sqlq_env -EnvPairs @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_reasoning_plugin")),
                            "FSQL_REASONING_HTTP_URL=https://chat.invalid/v1/chat/completions",
                            "FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings") `
      "SELECT len(fractal_embed('hello'));" `
      "SELECT fractal_reason('chat after embed');"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "an embedding dispatch and a chat dispatch run in one process" "chat-endpoint-canary"
  $dump = rc_file $script:REVIEWDUMP
  if (out_has $dump "URL=https://chat.invalid/v1/chat/completions") {
    pass "the CHAT tier reached the chat endpoint after the embedding tier loaded"
  } else {
    fail "the CHAT tier was pointed at the embeddings endpoint"
    Write-Host ("      dump: " + (trunc $dump))
  }
}

function gate_29 {
  wc_file $script:SQLTXT "domain-agent-canary"
  # the domain agents read the reasoning plugin from the environment;
  # route every
  # LLM-composed subtest through sqlq_env
  $mockenv = @(("FRACTALSQL_REASONING_PLUGIN=" + (pj "mock_reasoning_plugin")))
  $null = sqlq "CREATE TABLE bt_da_logs(host VARCHAR, metric DOUBLE, ts INTEGER);" `
               "INSERT INTO bt_da_logs " `
               "SELECT CASE WHEN i % 4 = 3 THEN 'host-2' ELSE 'host-1' END, " `
               "       10.0 + sin(i * 0.2) * 2.0 + i * 0.05, " `
               "       i FROM generate_series(1, 96) AS g(i);"
  $r = sqlq "SELECT count(*) FROM bt_da_logs;"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "anomaly fixture staged (96 rows, drifting metric)" "96"
  # anomaly_triage: table + drift + reasoning (the summary carries the
  # canned canary because the reasoning ctx rides the mock plugin)
  $r = sqlq_env -EnvPairs $mockenv "SELECT fractal_agent_anomaly_triage('bt_da_logs','metric','ts','host','host-1',32);"
  $rc = $script:SQLQ_RC
  if (($rc -eq 0) -and (out_has $r "anomaly_type") -and (out_has $r "vector_drift") -and (out_has $r "domain-agent-canary")) {
    pass "anomaly_triage composed drift + reasoning (triage_summary carries the canary)"
  } else {
    fail "anomaly_triage composition"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
  }
  $r = sqlq "SELECT fractal_agent_anomaly_triage('bt_da_logs','metric','ts','host','no-such-host',32);"
  $rc = $script:SQLQ_RC
  expect_err "fractal_agent_anomaly_triage: no rows in bt_da_logs.metric" $rc $r "empty series reported by table.column"
  # recall_hybrid: pure retrieval with a cohort filter, no LLM in the loop
  $null = sqlq "CREATE TABLE bt_da_mem(id INTEGER, kind VARCHAR, body VARCHAR, emb DOUBLE[]);" `
               "INSERT INTO bt_da_mem VALUES " `
               " (1, 'a', 'first memory', [1.0, 0.0, 0.0, 0.0])," `
               " (2, 'b', 'second memory', [0.0, 0.0, 0.0, 1.0])," `
               " (3, 'a', 'third memory', [0.9, 0.1, 0.0, 0.0]);"
  $r = sqlq "SELECT fractal_agent_recall_hybrid('bt_da_mem','emb',[1.0, 0.0, 0.0, 0.0]::DOUBLE[],'kind','a',5,'id','body');"
  $rc = $script:SQLQ_RC
  if (($rc -eq 0) -and (out_has $r "mem_id") -and (out_has $r "first memory") -and (-not (out_has $r "second memory"))) {
    pass "recall_hybrid honored the kind='a' cohort filter"
  } else {
    fail "recall_hybrid cohort filter"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
  }
  $r = sqlq "SELECT fractal_agent_recall_hybrid('bt_da_mem','emb',[1.0, 0.0, 0.0, 0.0]::DOUBLE[],'kind','zzz',5,'id','body');"
  $rc = $script:SQLQ_RC
  expect_err "filter matched no rows in" $rc $r "empty recall filter reported distinctly"
  # regime_triage: array in, dfa/drift + reasoning out
  $regacc = 0.0
  $regarr = for ($i = 0; $i -lt 100; $i++) { $regacc = $regacc + 0.5; Fm $regacc 3 }
  $s100 = $regarr -join ","
  $r = sqlq_env -EnvPairs $mockenv ("SELECT fractal_agent_regime_triage([" + $s100 + "]::DOUBLE[], 64, 0.5);")
  $rc = $script:SQLQ_RC
  if (($rc -eq 0) -and (out_has $r "dfa_exponent") -and (out_has $r "drift_detected") -and (out_has $r "domain-agent-canary")) {
    pass "regime_triage composed dfa + drift + reasoning (rationale carries the canary)"
  } else {
    fail "regime_triage composition"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
  }
  # outlier_intercept: the metric arg is part of the contract
  $null = sqlq "CREATE TABLE bt_da_badstates(kind VARCHAR, state_vec DOUBLE[]);" `
               "INSERT INTO bt_da_badstates VALUES " `
               " ('ok', [1.0, 0.0, 0.0, 0.0]), ('bad', [0.0, 1.0, 0.0, 0.0]), ('ok', [0.9, 0.1, 0.0, 0.0]);"
  $r = sqlq_env -EnvPairs $mockenv "SELECT fractal_agent_outlier_intercept([1.0, 0.0, 0.0, 0.0]::DOUBLE[],'bt_da_badstates','state_vec',0.5,'cosine');"
  $rc = $script:SQLQ_RC
  if (($rc -eq 0) -and (out_has $r "intercepted") -and (out_has $r "cosine")) {
    pass "outlier_intercept runs under the cosine metric"
  } else {
    fail "outlier_intercept (cosine)"
    Write-Host ("      got rc=" + $rc + ": " + (trunc $r))
  }
  $r = sqlq "SELECT fractal_agent_outlier_intercept([1.0, 0.0, 0.0, 0.0]::DOUBLE[],'bt_da_badstates','state_vec',0.5,'minkowski');"
  $rc = $script:SQLQ_RC
  expect_err "metric must be 'cosine' or 'l2'" $rc $r "outlier_intercept rejects unknown metrics"
  # an empty history table has nothing to intercept
  $null = sqlq "CREATE TABLE bt_da_nobad(kind VARCHAR, state_vec DOUBLE[]);"
  $r = sqlq "SELECT fractal_agent_outlier_intercept([1.0, 0.0, 0.0, 0.0]::DOUBLE[],'bt_da_nobad','state_vec',1.0,'l2');"
  $rc = $script:SQLQ_RC
  expect_err "no bad-state rows in bt_da_nobad" $rc $r "empty history table reports the no-bad-state condition"
}

function gate_30 {
  # the feature-store surface never made it into the duckdb build
  skip "feature store is not implemented in the duckdb build"
}

function gate_31 {
  $r = sqlq "SELECT fractal_ledger_verify();"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "verify() runs with NO enterprise lib and holds the exact contract" '{"ok":true,"rows_verified":0}'
  # the persistence/truth surface stays behind the enterprise gate
  foreach ($fn in @("fractal_ledger_flush", "fractal_ledger_load", "fractal_ledger_compact",
                    "fractal_ledger_reset_soft", "fractal_ledger_reset_hard",
                    "fractal_ledger_truth_count", "fractal_ledger_shadow_count")) {
    $r = sqlq ("SELECT " + $fn + "();"); $rc = $script:SQLQ_RC
    expect_err "requires the FractalSQL Enterprise tier" $rc $r ($fn + " reports the dormant enterprise tier")
  }
  $r = sqlq "SELECT fractal_audit_log('bt-entry', '{}');"; $rc = $script:SQLQ_RC
  expect_err "requires the FractalSQL Enterprise tier" $rc $r "audit_log reports the dormant enterprise tier"
  # the community ledger surface answers with no enterprise lib at all
  $r = sqlq "SELECT fractal_diversify_enable();"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "diversify_enable answers community-side" "true"
  $r = sqlq "SELECT fractal_diversify_disable();"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "diversify_disable answers community-side" "false"
  # the ledger
  # reads its OWN fsql ctx, which a fresh CLI process has never run a
  # search through, so the
  # score legitimately reads NaN through the CLI
  $r = sqlq "SELECT fractal_detect_collapse();"
  $rc = $script:SQLQ_RC
  expect_ok $rc $r "detect_collapse answers community-side" "-nan"
  $r = sqlq "SELECT fractal_explain_result();"; $rc = $script:SQLQ_RC
  expect_ok $rc $r "explain_result answers community-side" '"dq"'
}

function gate_32 {
  # Ed25519 detached-signature check of the enterprise library: refusal
  # cases (the verifier primitive's RFC 8032 vectors run in build_test.sh).
  $lib = Join-Path $script:BTROOT ("fsql_bt_sigtest_enterprise" + $script:PLUGSUF)
  [IO.File]::WriteAllText($lib, "not a real enterprise core")
  Remove-Item -Force -ErrorAction SilentlyContinue ($lib + ".sig")
  $q = "SELECT fractal_ledger_reset_soft();"
  $r = sqlq_env -EnvPairs @("FRACTALSQL_ENTERPRISE_LIB=" + $lib) $q; $rc = $script:SQLQ_RC
  expect_err "no signature found for enterprise library" $rc $r "32 missing .sig without opt-out is refused"
  foreach ($n in 64, 63) {
    [IO.File]::WriteAllBytes(($lib + ".sig"), (New-Object byte[] $n))
    $r = sqlq_env -EnvPairs @(("FRACTALSQL_ENTERPRISE_LIB=" + $lib), "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0") $q; $rc = $script:SQLQ_RC
    expect_err "failed signature verification" $rc $r ("32 invalid " + $n + "-byte .sig is refused even with the opt-out")
  }
  Remove-Item -Force ($lib + ".sig")
  $r = sqlq_env -EnvPairs @(("FRACTALSQL_ENTERPRISE_LIB=" + $lib), "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0") $q; $rc = $script:SQLQ_RC
  expect_err "could not load enterprise library" $rc $r "32 opt-out lets a .sig-less file reach the loader"
  Remove-Item -Force $lib
}

function gate_33 {
  # TSan needs a sanitizer-instrumented host harness; the duckdb build
  # ships no make-wired TSan runner and the CLI host cannot be
  # dlopen-instrumented here
  skip "no TSan-wired host harness in the duckdb build"
}

# Runs one vertical demo kit and returns the CLI's output as a string.
# The kit's SQL is prefixed with the extension LOAD and spooled through
# a temp file; the run happens in its own scratch directory, because
# the kits spool their own output files and would otherwise litter the
# harness's working directory.
function RunVerticalKit([string]$k) {
  $f = Join-Path (Join-Path $script:HERE "demo") ("demo-vertical-" + $k + ".sql")
  if (-not (Test-Path -LiteralPath $f)) { throw ("kit file missing: " + $f) }
  $kf = Join-Path ([IO.Path]::GetTempPath()) ("fsql_kit_" + [guid]::NewGuid().ToString("N") + ".sql")
  [IO.File]::WriteAllText($kf, ("LOAD '" + $script:EXT_SLASH + "';`n" + [IO.File]::ReadAllText($f)))
  $kdir = Join-Path ([IO.Path]::GetTempPath()) ("fsql_kitdir_" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $kdir | Out-Null
  try {
    Push-Location -LiteralPath $kdir
    try {
      return [string](Get-Content $kf -Raw | & $script:DUCK -batch -list -noheader -unsigned @($script:DUCK_ARGS) -separator "|" 2>&1 | plain_lines | Out-String -Width 8192)
    } finally {
      Pop-Location
    }
  } finally {
    Remove-Item -LiteralPath $kf -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $kdir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# The mock-plugin environment gate 34 (and the -Kit mode) run the kits
# under: the mock reasoning plugin, plus an embedding endpoint so the
# embed tier is reachable and the two embed-coupled kits can run.
function UseMockPluginEnv {
  $script:SAVED_PLUG = [Environment]::GetEnvironmentVariable("FRACTALSQL_REASONING_PLUGIN", "Process")
  $script:SAVED_EMBED_URL = [Environment]::GetEnvironmentVariable("FSQL_REASONING_HTTP_EMBED_URL", "Process")
  $script:SAVED_EMBED_MODEL = [Environment]::GetEnvironmentVariable("FSQL_REASONING_HTTP_EMBED_MODEL", "Process")
  $script:SAVED_EMBED_DIM = [Environment]::GetEnvironmentVariable("FSQL_MOCK_EMBED_DIM", "Process")
  [Environment]::SetEnvironmentVariable("FRACTALSQL_REASONING_PLUGIN", (pj "mock_reasoning_plugin"), "Process")
  # The embed tier needs an endpoint configured (the extension refuses
  # the tier outright when FSQL_REASONING_HTTP_EMBED_URL is unset) and
  # the mock plugin answers the embedding dispatch with a
  # deterministic vector of FSQL_MOCK_EMBED_DIM floats. 768 is the
  # width the two embed-coupled kits (agentic-ops-devops,
  # agentic-fintech-mcts) declare their column as.
  [Environment]::SetEnvironmentVariable("FSQL_REASONING_HTTP_EMBED_URL", "https://mock.invalid/v1/embeddings", "Process")
  [Environment]::SetEnvironmentVariable("FSQL_REASONING_HTTP_EMBED_MODEL", "mock-embed", "Process")
  [Environment]::SetEnvironmentVariable("FSQL_MOCK_EMBED_DIM", "768", "Process")
}

function RestoreMockPluginEnv {
  if ($null -ne $script:SAVED_PLUG) { [Environment]::SetEnvironmentVariable("FRACTALSQL_REASONING_PLUGIN", $script:SAVED_PLUG, "Process") }
  else { [Environment]::SetEnvironmentVariable("FRACTALSQL_REASONING_PLUGIN", $null, "Process") }
  if ($null -ne $script:SAVED_EMBED_URL) { [Environment]::SetEnvironmentVariable("FSQL_REASONING_HTTP_EMBED_URL", $script:SAVED_EMBED_URL, "Process") }
  else { [Environment]::SetEnvironmentVariable("FSQL_REASONING_HTTP_EMBED_URL", $null, "Process") }
  if ($null -ne $script:SAVED_EMBED_MODEL) { [Environment]::SetEnvironmentVariable("FSQL_REASONING_HTTP_EMBED_MODEL", $script:SAVED_EMBED_MODEL, "Process") }
  else { [Environment]::SetEnvironmentVariable("FSQL_REASONING_HTTP_EMBED_MODEL", $null, "Process") }
  if ($null -ne $script:SAVED_EMBED_DIM) { [Environment]::SetEnvironmentVariable("FSQL_MOCK_EMBED_DIM", $script:SAVED_EMBED_DIM, "Process") }
  else { [Environment]::SetEnvironmentVariable("FSQL_MOCK_EMBED_DIM", $null, "Process") }
}

function gate_34 {
  # The starter kits: each demo\demo-vertical-*.sql runs start to finish in a
  # fresh in-memory database against the mock reasoning plugin, raising no
  # SQL error (the scenario-planning kit's plan_explore step needs an
  # embedding endpoint, so it is allowed exactly one), printing no NaN, and
  # reproducing its headline result.
  $kits = @("ev-battery-lifecycle", "adas-safety-validation", "v2x-warranty-triage",
            "critical-inventory-routing", "heavy-industry-predictive-maintenance",
            "climatech-grid-balancing", "hazmat-occupational-triage",
            "scenario-planning-simulation", "avionics-fault-prediction",
            "satellite-constellation-coverage", "telecom-account-anomaly-screening",
            "telecom-traffic-routing", "climatech-emissions-monitoring",
            "climatech-risk-exposure", "rf-spectrum-sensing",
            "event-stream-anomaly-triage", "outlier-interception-footprint",
            "agentic-budget-reallocation", "stalled-process-triage",
            "intent-matching-discovery", "agentic-next-action-ranking",
            "document-risk-drift", "coordinated-record-detection",
            "sensor-telemetry-allocation", "simulated-economy-drift",
            "multi-series-replenishment", "periodicity-portfolio-selection",
            "agentic-recall-recommendation", "spatial-footprint-portfolio-risk",
            "agentic-customer-support", "agentic-edge-swarm",
            "agentic-fintech-mcts", "agentic-ops-devops",
            "biotech-genomics", "cybersecurity-threat-detection",
            "fleet-logistics", "maritime-defense", "medtech-clinical",
            "quant-finance", "recommendation-search", "smart-cities-iot",
            "sovereign-edge-ai")
  UseMockPluginEnv
  try {
    foreach ($k in $kits) {
      $f = Join-Path (Join-Path $script:HERE "demo") ("demo-vertical-" + $k + ".sql")
      if (-not (Test-Path -LiteralPath $f)) { fail ($k + ": " + $f + " is missing"); continue }
      $out = RunVerticalKit $k
      $lines = @($out -split "`r?`n")
      $errLines = @($lines | Where-Object { $_ -match '^[A-Za-z ]*Error:' })
      $maxerr = 0
      if ($k -eq "scenario-planning-simulation") { $maxerr = 1 }
      if ($k -eq "periodicity-portfolio-selection") { $maxerr = 1 }
      if ($errLines.Count -gt $maxerr) {
        fail ($k + " raised " + $errLines.Count + " SQL error(s), at most " + $maxerr + " expected")
        Write-Host ("      " + (trunc ($errLines[0..([Math]::Min(1, $errLines.Count - 1))] -join " ")))
        continue
      }
      if ($lines | Where-Object { $_ -match '(^|\|)-?([Nn]a[Nn]|[Ii]nf|Infinity)(\||$)' }) {
        fail ($k + " printed a NaN/inf cell"); continue
      }
      $rows = @($lines | ForEach-Object { , ($_ -split '\|') })
      $ok = $false
      switch ($k) {
        default {
          # The remaining kits carry the same HEADLINE marker convention
          # ("HEADLINE kit=<name> ok", computed from the kit's own
          # results) and the gate greps for it.
          $ok = [bool]($lines | Where-Object { $_ -match ("HEADLINE kit=" + $k + " ok") }) }
        "ev-battery-lifecycle" {
          $a = $rows | Where-Object { $_[0] -eq "EV-203" -and $_.Count -ge 3 -and (to_num $_[1]) -gt 0.5 -and (to_num $_[2]) -gt 1.5 }
          $b = $rows | Where-Object { $_[0] -eq "EV-101" -and $_.Count -ge 3 -and (to_num $_[1]) -lt 0 -and (to_num $_[2]) -lt 1 }
          $ok = [bool]($a -and $b) }
        "adas-safety-validation" {
          $a = $rows | Where-Object { $_[0] -like "P1 firm*" -and $_.Count -ge 4 -and $_[3] -eq "true" }
          $b = $rows | Where-Object { $_[0] -like "P2 steady*" -and $_.Count -ge 4 -and $_[3] -eq "false" }
          $c = $rows | Where-Object { $_[0] -like "P3 gentle*" -and $_.Count -ge 4 -and $_[3] -eq "true" }
          $ok = [bool]($a -and $b -and $c) }
        "v2x-warranty-triage" {
          $ok = [bool]($lines | Where-Object { $_ -match '^battery-thermal-service\|0\.99' }) }
        "critical-inventory-routing" {
          $ok = [bool]($rows | Where-Object { $_[0] -eq "4" -and $_.Count -ge 5 -and $_[1] -eq "west" -and (to_num $_[4]) -gt 1.2 }) }
        "heavy-industry-predictive-maintenance" {
          $a = $rows | Where-Object { $_[0] -eq "PUMP-07" -and $_.Count -ge 3 -and (to_num $_[1]) -gt 0.5 -and (to_num $_[2]) -gt 1.5 }
          $b = $rows | Where-Object { $_[0] -eq "PUMP-03" -and $_.Count -ge 3 -and (to_num $_[1]) -lt 0 }
          $ok = [bool]($a -and $b) }
        "climatech-grid-balancing" {
          $a = $rows | Where-Object { $_[0] -eq "AREA-C" -and $_.Count -ge 3 -and (to_num $_[1]) -gt 0.5 -and (to_num $_[2]) -gt 1.2 }
          $b = $rows | Where-Object { $_[0] -eq "AREA-A" -and $_.Count -ge 3 -and (to_num $_[1]) -lt 0 }
          $ok = [bool]($a -and $b) }
        "hazmat-occupational-triage" {
          $n = @($rows | Where-Object { @("7", "15", "31") -contains $_[0] -and $_.Count -ge 4 -and $_[1] -eq "reactor-bay" -and $_[2] -eq "night" -and (to_num $_[3]) -lt 0.001 }).Count
          $ok = ($n -ge 3) }
        "scenario-planning-simulation" {
          $ok = (@($lines | Where-Object { $_ -match 'variant' }).Count -ge 6) }
        "avionics-fault-prediction" {
          $ok = [bool]($lines | Where-Object { $_ -match '^AC-09\|0\.2' }) }
        "satellite-constellation-coverage" {
          $h = $rows | Where-Object { $_[0] -eq "healthy" -and $_.Count -eq 3 } | Select-Object -First 1
          $d = $rows | Where-Object { $_[0] -eq "degraded" -and $_.Count -eq 3 } | Select-Object -First 1
          $ok = [bool]($h -and $d -and ((to_num $h[2]) -gt 0) -and ((to_num $d[2]) -gt (to_num $h[2]))) }
        "telecom-account-anomaly-screening" {
          $a = $rows | Where-Object { $_[0] -like "E1 swap*" -and $_.Count -ge 4 -and $_[3] -eq "true" }
          $b = $rows | Where-Object { $_[0] -like "E2 routine*" -and $_.Count -ge 4 -and $_[3] -eq "false" }
          $c = $rows | Where-Object { $_[0] -like "E4 faint*" -and $_.Count -ge 4 -and $_[3] -eq "true" }
          $ok = [bool]($a -and $b -and $c) }
        "telecom-traffic-routing" {
          $ok = [bool](($lines | Where-Object { $_ -match '^R3 mobile handover burst\|edge-mobile-hub\|' }) -and
                       ($lines | Where-Object { $_ -match '^R3 mobile handover burst\|edge-backup-west$' })) }
        "climatech-emissions-monitoring" {
          $a = $rows | Where-Object { $_[0] -eq "CH4-02" -and $_.Count -ge 3 -and (to_num $_[1]) -gt 0.5 -and (to_num $_[2]) -gt 1.5 }
          $b = $rows | Where-Object { $_[0] -eq "CH4-01" -and $_.Count -ge 3 -and (to_num $_[1]) -lt 0 }
          $ok = [bool]($a -and $b) }
        "climatech-risk-exposure" {
          $a = $rows | Where-Object { $_[0] -eq "dry season" -and $_.Count -eq 3 }
          $b = $rows | Where-Object { $_[0] -eq "wet season" -and $_.Count -eq 3 }
          $ok = [bool]($a -and $b) }
        "rf-spectrum-sensing" {
          $ok = [bool](($lines | Where-Object { $_ -match '^CH-A\|\[9\]$' }) -and
                       ($lines | Where-Object { $_ -match '^CH-B\|\[\]$' }) -and
                       ($lines | Where-Object { $_ -match '^CH-C\|\[\]$' })) }
      }
      if ($ok) { pass ("demo-vertical-" + $k + ".sql runs clean and reproduces its headline result") }
      else { fail ("demo-vertical-" + $k + ".sql did not reproduce its headline result") }
    }
  } finally {
    RestoreMockPluginEnv
  }
}

# ----------------------------------------------------------------
# Gate 44 -- the shipped HTTP reasoning plugin (numbered 35 before the MCP gates took 35-43).
#
# The fixture plugins under tests\ answer from memory and read no
# environment variable at all. The HTTP reasoning plugin this
# extension ships with is the opposite: it is a separate module with
# its own C runtime, and it reads its endpoint, model and dispatch
# mode from the environment when it initialises. No other gate in
# this harness can tell whether the extension handed that plugin the
# configuration it meant to, so this gate drives the real thing
# against a local HTTP stub.
# ----------------------------------------------------------------

# The plugin binary this extension ships with, under include\<platform>\.
function resolve_shipped_http_plugin {
  if ($env:FSQL_HTTP_PLUGIN) {
    if (Test-Path -LiteralPath $env:FSQL_HTTP_PLUGIN) {
      return (Resolve-Path -LiteralPath $env:FSQL_HTTP_PLUGIN).Path
    }
    return $null
  }
  $p = Join-Path $script:HERE "include\windows-x86_64\fractalsql-reasoning-http.dll"
  if (Test-Path -LiteralPath $p) { return $p }
  return $null
}

# The stdlib-only HTTP stub in tests\_mock_llm_server.py: one port
# serving a canned chat reply on /v1/chat/completions and a constant
# N-float embedding on /v1/embeddings. The stub prints the port it
# bound on stdout and then serves until it is killed.
function start_http_stub {
  param([string]$Reply = "pong-from-shipped", [int]$EmbedDim = 768)
  $stubSrc = Join-Path $script:HERE "tests\_mock_llm_server.py"
  if (-not (Test-Path -LiteralPath $stubSrc)) { return $null }
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $script:PYANY
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  # stderr is deliberately NOT redirected: an inherited stderr cannot
  # deadlock the stub on a full pipe, and a python traceback is worth
  # seeing in the log.
  add_proc_arg $psi "-I"
  add_proc_arg $psi $stubSrc
  add_proc_arg $psi $Reply
  add_proc_arg $psi "--embed-dim=$EmbedDim"
  $proc = $null
  try { $proc = [System.Diagnostics.Process]::Start($psi) } catch { return $null }
  if (-not $proc) { return $null }
  $port = 0
  try {
    $t = $proc.StandardOutput.ReadLineAsync()
    if ($t.Wait(20000)) {
      $line = [string]$t.Result
      if ($line.Trim() -match '^\d+$') { $port = [int]$line.Trim() }
    }
  } catch { $port = 0 }
  return @{ Proc = $proc; Port = $port }
}

function stop_http_stub {
  param($Stub)
  if (-not $Stub) { return }
  stop_proc $Stub.Proc 5000
  try { $Stub.Proc.Dispose() } catch { }
}

function gate_44 {
  $plugin = resolve_shipped_http_plugin
  if (-not $plugin) {
    skip "no shipped HTTP reasoning plugin under include\ (set FSQL_HTTP_PLUGIN to point at one)"
    return
  }
  if (-not $script:PYANY) {
    skip "no python interpreter for the local HTTP stub (set FSQL_PYTHON_ANY)"
    return
  }
  $stub = start_http_stub -Reply "pong-from-shipped" -EmbedDim 768
  if ((-not $stub) -or ($stub.Port -le 0)) {
    if ($stub) { stop_http_stub $stub }
    skip "the local HTTP stub did not start (python could not run tests\_mock_llm_server.py)"
    return
  }
  try {
    $base = "http://127.0.0.1:" + $stub.Port
    $chatUrl  = $base + "/v1/chat/completions"
    $embedUrl = $base + "/v1/embeddings"

    # 1. the chat tier, against the shipped plugin: the plugin reads
    #    its endpoint and model from the environment at init time.
    $r = sqlq_env -EnvPairs @(
            ("FRACTALSQL_REASONING_PLUGIN=" + $plugin),
            ("FSQL_REASONING_HTTP_URL=" + $chatUrl),
            "FSQL_REASONING_HTTP_MODEL=stub-model",
            "FSQL_REASONING_HTTP_ALLOW_PLAINTEXT=1") `
        "SELECT fractal_reason('ping');"
    expect_ok $script:SQLQ_RC $r "the shipped plugin answers the chat tier" "pong-from-shipped"

    # 2. the decisive one: the embed tier is configured ONLY through
    #    the embed endpoint. The plugin itself knows nothing about that
    #    variable -- the extension maps it onto the endpoint the plugin
    #    reads, in the plugin's own C runtime's environment. If that
    #    hand-off breaks, the plugin initialises without an endpoint
    #    and the load fails; this run must therefore succeed with the
    #    chat endpoint absent.
    $r = sqlq_env -EnvPairs @(
            ("FRACTALSQL_REASONING_PLUGIN=" + $plugin),
            ("FSQL_REASONING_HTTP_EMBED_URL=" + $embedUrl),
            "FSQL_REASONING_HTTP_EMBED_MODEL=stub-embed-model",
            "FSQL_REASONING_HTTP_ALLOW_PLAINTEXT=1") `
        -UnsetPairs @("FSQL_REASONING_HTTP_URL",
                      "FSQL_REASONING_HTTP_MODE",
                      "FSQL_REASONING_HTTP_RESPONSE_MODE",
                      "FSQL_REASONING_HTTP_SYSTEM_TAG") `
        "SELECT len(fractal_embed('hello'));"
    expect_ok $script:SQLQ_RC $r "the embed tier's endpoint override reaches the shipped plugin" "768"

    $r = sqlq_env -EnvPairs @(
            ("FRACTALSQL_REASONING_PLUGIN=" + $plugin),
            ("FSQL_REASONING_HTTP_EMBED_URL=" + $embedUrl),
            "FSQL_REASONING_HTTP_EMBED_MODEL=stub-embed-model",
            "FSQL_REASONING_HTTP_ALLOW_PLAINTEXT=1") `
        -UnsetPairs @("FSQL_REASONING_HTTP_URL",
                      "FSQL_REASONING_HTTP_MODE",
                      "FSQL_REASONING_HTTP_RESPONSE_MODE",
                      "FSQL_REASONING_HTTP_SYSTEM_TAG") `
        "SELECT fractal_embed('hello')[1];"
    expect_ok $script:SQLQ_RC $r "the shipped plugin's embedding comes back from the endpoint" "0.05"

    # 3. the unconfigured embed endpoint still reports the setup error
    #    rather than reaching the plugin.
    $r = sqlq_env -EnvPairs @(
            ("FRACTALSQL_REASONING_PLUGIN=" + $plugin),
            "FSQL_REASONING_HTTP_ALLOW_PLAINTEXT=1") `
        -UnsetPairs @("FSQL_REASONING_HTTP_EMBED_URL",
                      "FSQL_REASONING_HTTP_EMBED_MODEL",
                      "FSQL_REASONING_HTTP_URL",
                      "FSQL_MOCK_EMBED_DIM") `
        "SELECT fractal_embed('hello');"
    expect_err "FSQL_REASONING_HTTP_EMBED_URL is not configured" $script:SQLQ_RC $r `
      "the embed tier still reports a missing endpoint"

    # 4. a chat endpoint that is not there fails at dispatch time with
    #    the plugin's own transport error -- the shipped plugin really
    #    did dial the endpoint, it did not answer from memory.
    $r = sqlq_env -EnvPairs @(
            ("FRACTALSQL_REASONING_PLUGIN=" + $plugin),
            "FSQL_REASONING_HTTP_URL=http://127.0.0.1:1/v1/chat/completions",
            "FSQL_REASONING_HTTP_MODEL=stub-model",
            "FSQL_REASONING_HTTP_ALLOW_PLAINTEXT=1") `
        "SELECT fractal_reason('ping');"
    $rc = $script:SQLQ_RC
    if ($rc -ne 0) {
      pass "the shipped plugin reports a transport failure for an unreachable endpoint"
    } else {
      fail "the shipped plugin reports a transport failure for an unreachable endpoint"
      Write-Host ("      got rc=0: " + (trunc $r))
    }
  } finally {
    stop_http_stub $stub
  }
}

# ----------------------------------------------------------------
# 45 mcp_conformance: the protocol conformance gate. The driver starts the servers it
# needs itself -- both protocol eras, with and without a bearer token, in read-only mode,
# with the operator switches on and off, over HTTP and over stdio -- and checks the
# behaviour against the published rules. It is the same driver file in every engine's
# repository.
# ----------------------------------------------------------------
function gate_45 {
  $driver = Join-Path $script:HERE "mcp\tests\mcp_conformance.py"
  if (-not (Test-Path -LiteralPath $driver)) { skip "45 mcp_conformance (no mcp\tests\mcp_conformance.py)"; return }
  if (-not $script:PYANY) { skip "45 mcp_conformance (no python interpreter for the conformance driver)"; return }
  # The server refuses to start without its two drift locks, and the driver checks that it
  # refuses: without them there is nothing to check.
  foreach ($lock in @(".mcp-schema-lock", ".mcp-safety-annotations-lock")) {
    if (-not (Test-Path -LiteralPath (Join-Path $script:HERE ("mcp\" + $lock)))) {
      skip "45 mcp_conformance (the drift locks are missing)"; return
    }
  }
  if (-not (mcp_build)) { skip "45 mcp_conformance (the server was not built)"; return }
  $exe = Join-Path $script:MCP_DIR_OUT "fractalsql-ext-mcp.exe"
  if (-not (Test-Path -LiteralPath $exe)) { skip "45 mcp_conformance (no server binary)"; return }
  # The server looks for its two lock files beside the executable when no path is
  # configured, which is the layout the installed-layout check starts from.
  foreach ($lock in @(".mcp-schema-lock", ".mcp-safety-annotations-lock")) {
    Copy-Item -LiteralPath (Join-Path $script:HERE ("mcp\" + $lock)) -Destination (Join-Path $script:MCP_DIR_OUT $lock) -Force
  }
  $work = Join-Path $script:PDIR "conformance"
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  # The driver runs the desktop profile with a scrubbed environment -- only what a client
  # config would pass -- so the extension path travels in the passthrough list as well.
  $vars = @{
    FSQL_DUCKDB_EXTENSION = $script:EXT
    FSQL_DUCKDB_ALLOW_UNSIGNED = "true"
    MCP_SERVER_EXE = $exe
    MCP_SERVER_CWD = $work
    MCP_HERE = (Join-Path $script:HERE "mcp")
    MCPC_TOKEN = "conformance-token"
    MCPC_GATE = "45"
    MCPC_LOCK_DIR = (Join-Path $script:HERE "mcp")
    MCPC_PASSTHROUGH_ENV = "FSQL_DUCKDB_EXTENSION,FSQL_DUCKDB_ALLOW_UNSIGNED,FSQL_DUCKDB_DATABASE"
    MCPC_READ_TOOL = "fractal_version"
    MCPC_READ_ARGS = "{}"
    MCPC_STATE_TOOL = "fractal_diversify_enable"
    MCPC_STATE_ARGS = "{}"
    MCPC_STATE_READER = "fractal_explain_result"
    MCPC_DESTRUCTIVE_TOOL = "fractal_diversify_enable"
    MCPC_DESTRUCTIVE_ARGS = "{}"
    MCPC_SAFE_KEY = "http_model"
    MCPC_UNSAFE_KEY = "http_url"
  }
  $old = @{}
  foreach ($k in $vars.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k, "Process"); [Environment]::SetEnvironmentVariable($k, $vars[$k], "Process") }
  try {
    $o = (& $script:PYANY -u $driver 2>&1 | plain_lines | Out-String -Width 8192)
    $rc = $LASTEXITCODE
  } finally {
    foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k], "Process") }
  }
  $logf = Join-Path $script:MCP_DIR_OUT "mcp_conformance.log"
  Set-Content -Path $logf -Value $o
  if (($rc -eq 0) -and ($o -match 'ALL GREEN')) {
    $n = ([regex]::Matches($o, '(?m)^PASS')).Count
    pass ("45 mcp_conformance: " + $n + " checks passed")
  } else {
    # The driver's own failure lines, not the server's log: they name the rule that was broken.
    ($o -split "`n" | Where-Object { $_ -match '^ *(FAIL|SKIP) ' } | Select-Object -First 12) | ForEach-Object { Write-Host "    $_" }
    fail ("45 mcp_conformance: the conformance driver reported failures (exit " + $rc + "; full log " + $logf + ")")
  }
}

# ----------------------------------------------------------------
# Runner.
# ----------------------------------------------------------------

# ----------------------------------------------------------------
# The MCP server (mcp\): gates 35-43. Same numbers as build_test.sh.
# Built by mcp\scripts\windows\build.bat against a DuckDB release's
# libduckdb-windows-amd64 (duckdb.h, duckdb.lib, duckdb.dll), found in
# FSQL_LIBDUCKDB_DIR or fetched into %LOCALAPPDATA%\fractalsql.
# ----------------------------------------------------------------
$script:MCP_DIR_OUT = ""
$script:MCP_LIBDIR = ""
$script:MCP_BUILT = $false

function mcp_libduckdb {
  if ($script:MCP_LIBDIR) { return $true }
  if ($env:FSQL_LIBDUCKDB_DIR) {
    if ((Test-Path (Join-Path $env:FSQL_LIBDUCKDB_DIR 'duckdb.h')) -and (Test-Path (Join-Path $env:FSQL_LIBDUCKDB_DIR 'duckdb.lib'))) {
      $script:MCP_LIBDIR = (Resolve-Path $env:FSQL_LIBDUCKDB_DIR).Path; return $true
    }
    skip ("mcp (FSQL_LIBDUCKDB_DIR=" + $env:FSQL_LIBDUCKDB_DIR + " has no duckdb.h and duckdb.lib)"); return $false
  }
  $ver = ""
  if ($script:EXT -match 'fractalsql\.(v[0-9][0-9.]*)\.') { $ver = $Matches[1] }
  if (-not $ver) { skip "mcp (set FSQL_LIBDUCKDB_DIR to a libduckdb-windows-amd64 directory matching the extension's DuckDB version)"; return $false }
  $cache = Join-Path $env:LOCALAPPDATA ("fractalsql\libduckdb-" + $ver + "-amd64")
  if (-not (Test-Path (Join-Path $cache 'duckdb.h'))) {
    try {
      New-Item -ItemType Directory -Force -Path $cache | Out-Null
      $zip = Join-Path $cache 'libduckdb.zip'
      Invoke-WebRequest -UseBasicParsing -Uri ("https://github.com/duckdb/duckdb/releases/download/" + $ver + "/libduckdb-windows-amd64.zip") -OutFile $zip
      Expand-Archive -Path $zip -DestinationPath $cache -Force
      Remove-Item -Force $zip
    } catch {
      skip ("mcp (could not fetch libduckdb " + $ver + " for windows-amd64; set FSQL_LIBDUCKDB_DIR): " + $_.Exception.Message); return $false
    }
  }
  $script:MCP_LIBDIR = $cache
  return $true
}

function mcp_build {
  if ($script:MCP_BUILT) { return $true }
  if (-not $script:EXT) { skip "mcp (no extension resolved)"; return $false }
  if (-not $script:PYANY) { skip "mcp (no python interpreter for the test drivers)"; return $false }
  if ($script:SAN) { skip ("mcp (not built under -" + $script:SAN + "; the native sanitizer cell covers the extension)"); return $false }
  if (-not (mcp_libduckdb)) { return $false }
  $out = Join-Path $script:PDIR "mcp"
  New-Item -ItemType Directory -Force -Path $out | Out-Null
  $bat = Join-Path $script:HERE "mcp\scripts\windows\build.bat"
  $log = Join-Path $out "build.log"
  & cmd.exe /c ('"' + $bat + '" "' + $out + '" "' + $script:MCP_LIBDIR + '" probes') *> $log
  if ($LASTEXITCODE -ne 0) {
    Get-Content $log -Tail 20 | ForEach-Object { Write-Host "    $_" }
    fail "35 mcp: the server or its probes did not build (see $log)"; return $false
  }
  $script:MCP_DIR_OUT = $out
  $script:MCP_BUILT = $true
  return $true
}

function mcp_probe_run {
  param([string]$num, [string]$probe)
  if (-not (mcp_build)) { return }
  $exe = Join-Path $script:MCP_DIR_OUT ($probe + ".exe")
  $env:FSQL_DUCKDB_EXTENSION = $script:EXT
  $env:PATH = $script:MCP_DIR_OUT + ";" + $env:PATH
  $o = (& $exe 2>&1 | plain_lines | Out-String)
  $rc = $LASTEXITCODE
  if ($rc -eq 0) { pass ($num + " mcp: " + $probe) }
  else { ($o -split "`n" | Where-Object { $_ -match '^FAIL' } | Select-Object -First 5) | ForEach-Object { Write-Host "    $_" }; fail ($num + " mcp: " + $probe + " reported a failure") }
}

function mcp_driver_gate {
  param([string]$num, [string]$name, [string]$script_, [hashtable]$extra = @{})
  if (-not (mcp_build)) { return }
  # The server's working directory is where the HTTPS driver leaves its certificates and logs: a scratch
  # directory, not the repository (as in build_test.sh).
  $mcpWork = Join-Path ([IO.Path]::GetTempPath()) "fsql_mcp_work"
  New-Item -ItemType Directory -Force -Path $mcpWork | Out-Null
  $vars = @{
    FSQL_DUCKDB_EXTENSION = $script:EXT
    MCP_SERVER_EXE = (Join-Path $script:MCP_DIR_OUT "fractalsql-ext-mcp.exe")
    MCP_SERVER_CWD = $mcpWork
    MCP_HERE = (Join-Path $script:HERE "mcp")
    MCP_DUCKDB_EXEC = (Join-Path $script:MCP_DIR_OUT "duckdb_exec.exe")
  }
  foreach ($k in $extra.Keys) { $vars[$k] = $extra[$k] }
  $old = @{}
  foreach ($k in $vars.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k, "Process"); [Environment]::SetEnvironmentVariable($k, $vars[$k], "Process") }
  try {
    $o = (& $script:PYANY (Join-Path $script:HERE ("mcp\tests\" + $script_)) 2>&1 | plain_lines | Out-String -Width 8192)
    $rc = $LASTEXITCODE
  } finally {
    foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k], "Process") }
  }
  $logf = Join-Path $script:MCP_DIR_OUT ($name + ".log")
  Set-Content -Path $logf -Value $o
  if (($rc -eq 0) -and ($o -match 'ALL GREEN')) {
    $n = ([regex]::Matches($o, '(?m)^\s*PASS')).Count
    pass ($num + " mcp_" + $name + ": " + $n + " checks passed")
  } else {
    ($o -split "`n" | Where-Object { $_ -match '^\s*FAIL|offender|Traceback|Error' } | Select-Object -First 12) | ForEach-Object { Write-Host "    $_" }
    fail ($num + " mcp_" + $name + ": failed (exit " + $rc + "; full log " + $logf + ")")
  }
}

function gate_35 {
  if (-not (mcp_build)) { return }
  pass ("35 mcp: fractalsql-ext-mcp.exe built (" + (& (Join-Path $script:MCP_DIR_OUT "fractalsql-ext-mcp.exe") --version 2>&1 | plain_lines | Out-String).Trim() + ")")
  mcp_probe_run "35" "vectors_probe"
  mcp_probe_run "35" "sanitize_probe"
}
function gate_36 { mcp_driver_gate "36" "smoke" "mcp_smoke_client.py" }
function gate_37 {
  $ossl = Get-Command openssl.exe -ErrorAction SilentlyContinue
  if (-not $ossl) { skip "37 mcp_https (no openssl CLI on PATH for the throwaway certificate)"; return }
  if (-not (mcp_build)) { return }
  $w = Join-Path $script:MCP_DIR_OUT "tls"; New-Item -ItemType Directory -Force -Path $w | Out-Null
  $cnf = Join-Path $w "openssl.cnf"
  [IO.File]::WriteAllText($cnf, "[req]`ndistinguished_name = dn`nprompt = no`n[dn]`n")
  & $ossl.Source req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=127.0.0.1" -config $cnf -keyout (Join-Path $w "key.pem") -out (Join-Path $w "cert.pem") *> $null
  if ($LASTEXITCODE -ne 0) { skip "37 mcp_https (could not generate a certificate)"; return }
  $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0); $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
  mcp_driver_gate "37" "https" "mcp_https_smoke_client.py" @{ MCP_HTTPS_PORT = "$port"; MCP_HTTPS_CERT = (Join-Path $w "cert.pem"); MCP_HTTPS_KEY = (Join-Path $w "key.pem") }
}
function gate_38 { mcp_driver_gate "38" "cli" "mcp_cli.py" }
# SECURITY_AUDIT.md 3.17, 3.18: the HTTP transport refuses lookalike origins and repeated headers (no engine needed)
function gate_58 { mcp_driver_gate "58" "audit_http" "mcp_audit_http.py" }
function gate_39 { mcp_probe_run "39" "db_probe" }
function gate_40 { mcp_probe_run "40" "concurrency_probe" }
function gate_41 { skip "41 mcp_faults (needs LD_PRELOAD (tests/oom_preload.c) and signals; Linux only)" }

# 42 mcp_fuzz (-Fuzz only): libFuzzer + ASan under clang-cl over the JSON-RPC front door and the argument coercion.
function gate_42 {
  if (-not (mcp_libduckdb)) { return }
  $cl = Get-Command clang-cl.exe -ErrorAction SilentlyContinue
  if (-not $cl) { skip "42 mcp_fuzz (clang-cl not on PATH)"; return }
  $vc = $env:VCPKG_ROOT; $ossl = $null
  foreach ($c in @((Join-Path $vc "installed\x64-windows-static"), (Join-Path $script:HERE "..\vcpkg\installed\x64-windows-static"))) {
    if ($c -and (Test-Path (Join-Path $c "include\openssl\evp.h"))) { $ossl = (Resolve-Path $c).Path; break }
  }
  if (-not $ossl) { skip "42 mcp_fuzz (OpenSSL for MSVC not found: vcpkg install openssl:x64-windows-static, set VCPKG_ROOT)"; return }
  $w = Join-Path $script:PDIR "mcpfuzz"; New-Item -ItemType Directory -Force -Path $w | Out-Null
  $secs = if ($env:FSQL_FUZZ_TIME) { $env:FSQL_FUZZ_TIME } else { "30" }
  $rt = $null; try { $rt = (& $cl.Source -print-resource-dir 2>$null | Select-Object -First 1) } catch { }
  if ($rt) { $d = Join-Path $rt "lib\windows"; if (Test-Path $d) { $env:PATH = $d + ";" + $env:PATH } }
  $env:PATH = $script:MCP_LIBDIR + ";" + $env:PATH
  foreach ($t in @("vectors", "jsonrpc")) {
    $srcs = @("mcp\src\errors.cpp")
    if ($t -eq "vectors") { $srcs += "mcp\src\vectors.cpp" } else { $srcs += @("mcp\src\db.cpp","mcp\src\jsonrpc_server.cpp","mcp\src\logging.cpp","mcp\src\prompts.cpp","mcp\src\resources.cpp") }
    $bin = Join-Path $w ("fuzz_mcp_" + $t + ".exe")
    $log = Join-Path $w ($t + ".build.log")
    & $cl.Source /std:c++17 -O1 -Zi "-fsanitize=fuzzer,address,undefined" /EHsc -D_CRT_SECURE_NO_WARNINGS -DNOMINMAX -Imcp\src -Imcp\vendor ("-I" + $script:MCP_LIBDIR) ("-I" + (Join-Path $ossl "include")) ("tests\fuzz\fuzz_mcp_" + $t + ".cpp") @srcs ("/Fe" + $bin) /link ("/LIBPATH:" + $script:MCP_LIBDIR) ("/LIBPATH:" + (Join-Path $ossl "lib")) duckdb.lib libssl.lib libcrypto.lib ws2_32.lib crypt32.lib user32.lib advapi32.lib *> $log
    if ($LASTEXITCODE -ne 0) { fail ("42 mcp_fuzz: fuzz_mcp_" + $t + " failed to build; see " + $log); continue }
    $seed = Join-Path $w ("seed_" + $t); New-Item -ItemType Directory -Force -Path $seed | Out-Null
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $bin
    foreach ($a in @($seed, (Join-Path $script:HERE ("tests\fuzz\corpus_mcp_" + $t)), ("-max_total_time=" + $secs), "-print_final_stats=1")) { add_proc_arg $psi $a }
    $psi.EnvironmentVariables["ASAN_OPTIONS"] = "detect_leaks=0:symbolize=0:alloc_dealloc_mismatch=0"
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    if ($p.ExitCode -eq 0) { pass ("42 mcp_fuzz: fuzz_mcp_" + $t + " (" + $secs + "s, corpus-seeded)") }
    else {
      $rl = Join-Path $w ($t + ".run.log"); ($so.Result + "`n" + $se.Result) | Out-File -FilePath $rl -Encoding utf8
      fail ("42 mcp_fuzz: fuzz_mcp_" + $t + " exited " + $p.ExitCode + "; see " + $rl)
    }
  }
}

# 47 fuzz_parse (-Fuzz only): libFuzzer over the extension's OWN parser for a
# model's reply (src/fsql_parse.c). The reply is untrusted input -- it is
# whatever a language model said -- so the code that turns it into SQL is
# attack surface, and the fuzzer drives exactly the functions the tier
# calls. The target carries no DuckDB, so this gate needs nothing but a
# libFuzzer-capable clang: no libduckdb, no OpenSSL, no MCP server.
function find_clang_cl {
  $c = Get-Command clang-cl.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  foreach ($p in @("C:\Program Files\Microsoft Visual Studio\*\Community\VC\Tools\Llvm\x64\bin\clang-cl.exe",
                   "C:\Program Files\Microsoft Visual Studio\*\Professional\VC\Tools\Llvm\x64\bin\clang-cl.exe",
                   "C:\Program Files\Microsoft Visual Studio\*\Enterprise\VC\Tools\Llvm\x64\bin\clang-cl.exe",
                   "C:\Program Files\LLVM\bin\clang-cl.exe")) {
    $hit = Get-ChildItem -Path $p -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  return $null
}

function gate_47 {
  # The denied-call scan, case by case, in every spelling the SQL parser accepts (a comment or a quoted name before the
  # parenthesis). A plain C program: clang-cl or cl.exe builds it, and it needs no libFuzzer.
  $ccx = find_clang_cl
  if (-not $ccx) { $c2 = Get-Command cl.exe -ErrorAction SilentlyContinue; if ($c2) { $ccx = $c2.Source } }
  if ($ccx) {
    $wd = Join-Path $script:PDIR "deniedcall"
    New-Item -ItemType Directory -Force -Path $wd | Out-Null
    $dbin = Join-Path $wd "denied_call_test.exe"
    $dlog = Join-Path $wd "build.log"
    & $ccx /std:c11 /O1 /D_CRT_SECURE_NO_WARNINGS /D_CRT_NONSTDC_NO_WARNINGS -Isrc `
          "tests\denied_call_test.c" "src\fsql_parse.c" "src\fsql_buf.c" ("/Fe" + $dbin) *> $dlog
    if ($LASTEXITCODE -eq 0) {
      $dout = & $dbin 2>&1 | plain_lines
      if ($LASTEXITCODE -eq 0) {
        pass "47 denied_call: the generated-SQL function denylist catches every spelling of a call"
      } else {
        fail "47 denied_call: a denied function got through"
        $dout | ForEach-Object { Write-Host ("         " + $_) }
      }
    } else {
      fail ("47 denied_call: the test failed to build; see " + $dlog)
    }
  }
  $cl = find_clang_cl
  if (-not $cl) { skip "47 fuzz_parse (no clang-cl on this machine; libFuzzer needs one)"; return }
  $w = Join-Path $script:PDIR "parsefuzz"
  New-Item -ItemType Directory -Force -Path $w | Out-Null
  $secs = if ($env:FSQL_FUZZ_TIME) { $env:FSQL_FUZZ_TIME } else { "30" }
  # The sanitizer runtimes live next to the compiler's resource directory;
  # without that on PATH the driver starts and then fails to find them.
  $rt = $null
  try { $rt = (& $cl -print-resource-dir 2>$null | Select-Object -First 1) } catch { $rt = $null }
  if ($rt) { $d = Join-Path $rt "lib\windows"; if (Test-Path $d) { $env:PATH = $d + ";" + $env:PATH } }

  $bin = Join-Path $w "fuzz_t2s_parse.exe"
  $log = Join-Path $w "build.log"
  & $cl /std:c11 /O1 /Zi "-fsanitize=fuzzer,address,undefined" `
        /D_CRT_SECURE_NO_WARNINGS /D_CRT_NONSTDC_NO_WARNINGS -Isrc `
        "tests\fuzz\fuzz_t2s_parse.c" "src\fsql_parse.c" "src\fsql_buf.c" `
        ("/Fe" + $bin) *> $log
  if ($LASTEXITCODE -ne 0) {
    fail ("47 fuzz_parse: the driver failed to build; see " + $log)
    Get-Content $log -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("         " + $_) }
    return
  }
  # libFuzzer on Windows does not create the output corpus directory
  # itself (the POSIX side gets it implicitly); pre-create it.
  $seed = Join-Path $w "corpus"
  New-Item -ItemType Directory -Force -Path $seed | Out-Null
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $bin
  foreach ($a in @((Join-Path $script:HERE "tests\fuzz\corpus_t2s_parse"), $seed,
                   ("-max_total_time=" + $secs), "-print_final_stats=1",
                   ("-artifact_prefix=" + $w + "\")))
    { add_proc_arg $psi $a }
  # The stock CLI's own shutdown allocations would be reported as leaks.
  $psi.EnvironmentVariables["ASAN_OPTIONS"] = "detect_leaks=0:symbolize=0:alloc_dealloc_mismatch=0"
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
  $p = [System.Diagnostics.Process]::Start($psi)
  $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
  $p.WaitForExit()
  if ($p.ExitCode -eq 0) {
    pass ("47 fuzz_parse: fuzz_t2s_parse (" + $secs + "s, corpus-seeded, ASan+UBSan)")
  } else {
    $rl = Join-Path $w "run.log"
    ($so.Result + "`n" + $se.Result) | Out-File -FilePath $rl -Encoding utf8
    fail ("47 fuzz_parse: fuzz_t2s_parse exited " + $p.ExitCode + "; see " + $rl)
    Get-Content $rl -Tail 12 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("         " + $_) }
  }
}

# 43: fractal_agent_recall_hybrid with a filter column and no filter value must error, not crash.
function gate_43 {
  if (-not (mcp_build)) { return }
  $exe = Join-Path $script:MCP_DIR_OUT "duckdb_exec.exe"
  $env:PATH = $script:MCP_DIR_OUT + ";" + $env:PATH
  $bad = 0
  foreach ($q in @("SELECT fractal_agent_recall_hybrid('x','y',[1.0]::DOUBLE[],'z')",
                   "SELECT fractal_agent_recall_hybrid('docs','emb',[1.0,0,0,0]::DOUBLE[],'body')")) {
    $null = & $exe ":memory:" --ext $script:EXT -- $q 2>&1 | plain_lines
    if (crashed $LASTEXITCODE) { $bad++; Write-Host ("    crashed (rc=" + $LASTEXITCODE + "): " + $q) }
  }
  if ($bad -eq 0) { pass "43 recall_hybrid_filter: the filter-column-only call is refused with an error, not a crash" }
  else { fail ("43 recall_hybrid_filter: " + $bad + " call(s) killed the process; the extension in use predates the fix (rebuild dist\)") }
}

# 46 capi_matrix: the pure-C extension.
# It checks its own two files
# (scripts\windows\build.bat builds them): each band loads where it should and is refused where it
# should across the DuckDB 1.4.4 / 1.5.6 / 2.0.0 CLIs, carries the right footer, exports
# only its entry point and has no DuckDB code inside. The harness does not build, so the
# gate skips with the command to run when the files are absent.
# CLIs: FSQL_DUCKDB_14 / _15 / _20 name the CLI for the 1.4.x / 1.5.x / 2.0.x line. Default:
# the HIGHEST v1.4.* / v1.5.* / v2.0.* directory under dist\cli\ then $HOME\duckdb-cli\ (the support
# policy is the latest patch of each line); for 2.0.x also the CLI the Windows 2.0 build staged.
function capi_cli_for {
  param([string]$id)
  $envv = [Environment]::GetEnvironmentVariable("FSQL_DUCKDB_" + $id)
  if ($envv -and (Test-Path -LiteralPath $envv)) { return $envv }
  $pat = @{ "14" = "v1.4.*"; "15" = "v1.5.*"; "20" = "v2.0.*" }[$id]
  $dirs = @()
  foreach ($root in @((Join-Path $script:HERE "dist\cli"), (Join-Path $HOME "duckdb-cli"))) {
    if (Test-Path -LiteralPath $root) {
      $dirs += @(Get-ChildItem -LiteralPath $root -Directory -Filter $pat -ErrorAction SilentlyContinue |
                 Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "duckdb.exe") })
    }
  }
  if ($dirs.Count -gt 0) {
    $best = $dirs | Sort-Object { [version]($_.Name.TrimStart("v")) } | Select-Object -Last 1
    return (Join-Path $best.FullName "duckdb.exe")
  }
  if ($id -eq "20") {
    $staged = Join-Path $script:HERE "dist\windows_amd64-200\duckdb.exe"
    if (Test-Path -LiteralPath $staged) { return $staged }
  }
  return ""
}

function capi_footer {
  param([string]$file)
  $b = [IO.File]::ReadAllBytes($file)
  if ($b.Length -lt 534) { return "short-file" }
  $f = $b[($b.Length - 534 + 22)..($b.Length - 534 + 22 + 255)]   # META8..META1, 32 bytes each
  $fld = {
    param($i)
    $chunk = $f[($i * 32)..($i * 32 + 31)] | Where-Object { $_ -ne 0 }
    return [Text.Encoding]::ASCII.GetString([byte[]]$chunk)
  }
  return ((& $fld 3) + "|" + (& $fld 5) + "|" + (& $fld 6))     # META5 abi, META3 version, META2 platform
}

function gate_46 {
  $dist = Join-Path $script:HERE "dist\windows_amd64"
  $plat = "windows_amd64"
  $bandS = Join-Path $dist ("fractalsql.capi." + $plat + ".duckdb_extension")
  # The LTS band is one exact DuckDB 1.4.x (its version is in the file name); take the newest.
  $lfile = @(Get-ChildItem -LiteralPath $dist -Filter ("fractalsql.v1.4.*." + $plat + ".duckdb_extension") -ErrorAction SilentlyContinue |
             Sort-Object { [version]($_.Name -replace '^fractalsql\.v(1\.4\.\d+)\..*$', '$1') } | Select-Object -Last 1)
  $bandL = ""; $lver = ""
  if ($lfile.Count -gt 0) { $bandL = $lfile[0].FullName; $lver = "v" + ($lfile[0].Name -replace '^fractalsql\.v(1\.4\.\d+)\..*$', '$1') }
  if (-not (Test-Path -LiteralPath (Join-Path $script:HERE "scripts\windows\build.bat"))) { skip "46 capi_matrix (no pure-C extension tree)"; return }
  if (-not ((Test-Path -LiteralPath $bandS) -and $bandL -and (Test-Path -LiteralPath $bandL))) {
    skip "46 capi_matrix (not built: run scripts\windows\build.bat)"; return
  }
  # The probe proves the extension ANSWERS, not just that it loads. It has
  # to be a function the shipped extension actually has: fractal_spike_version()
  # belongs to the separate P0 spike build (test/spike/fsql_spike.c), not to
  # this one, so it made band S "fail" on a function that was never there.
  $probe = $env:CAPI_PROBE_SQL
  if (-not $probe) { $probe = "SELECT fractal_version()" }
  $maxb = 8388608
  if ($env:CAPI_MAX_BYTES) { $maxb = [int64]$env:CAPI_MAX_BYTES }
  $np = 0; $nf = 0; $ns = 0
  $ok   = { param($m) $script:capi_np++ }
  $script:capi_np = 0; $script:capi_nf = 0; $script:capi_ns = 0
  $bad  = { param($m) $script:capi_nf++; Write-Host ("    FAIL " + $m) }
  $note = { param($m) $script:capi_ns++; Write-Host ("    SKIP " + $m) }

  foreach ($f in @($bandS, $bandL)) {
    $name = Split-Path -Leaf $f
    $sz = (Get-Item -LiteralPath $f).Length
    if ($sz -le $maxb) { & $ok "" } else { & $bad ($name + " is " + $sz + " bytes, over the " + $maxb + " ceiling -- is DuckDB being linked in?") }
    $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($f))
    if ($text.Contains("duckdb::")) { & $bad ($name + " contains C++ DuckDB symbols (duckdb::)") } else { & $ok "" }
  }
  $dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
  if ($dumpbin) {
    foreach ($f in @($bandS, $bandL)) {
      $exp = & $dumpbin.Source /nologo /exports $f 2>&1 | plain_lines | Out-String
      $names = @([regex]::Matches($exp, '(?m)^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)') | ForEach-Object { $_.Groups[1].Value })
      if ($names.Count -eq 1 -and $names[0] -eq "fractalsql_init_c_api") { & $ok "" }
      else { & $bad ((Split-Path -Leaf $f) + " exports " + $names.Count + " symbols (want only fractalsql_init_c_api): " + ($names -join " ")) }
    }
  } else { & $note "export check (dumpbin not on PATH; run from a Native Tools prompt)" }

  $fs = capi_footer $bandS; $fl = capi_footer $bandL
  if ($fs -eq ("C_STRUCT|v1.5.6|" + $plat)) { & $ok "" } else { & $bad ("band S footer is '" + $fs + "'") }
  if ($fl -eq ("C_STRUCT_UNSTABLE|" + $lver + "|" + $plat)) { & $ok "" } else { & $bad ("band L footer is '" + $fl + "' (want C_STRUCT_UNSTABLE|" + $lver + "|" + $plat + ")") }

  Remove-Item Env:AI_AGENT -ErrorAction SilentlyContinue
  Remove-Item Env:CLAUDECODE -ErrorAction SilentlyContinue
  foreach ($row in @(@("14", "1.4.x", "refuse", "load"), @("15", "1.5.x", "load", "refuse"), @("20", "2.0.x", "load", "refuse"))) {
    $cli = capi_cli_for $row[0]
    if (-not $cli) { & $note ("no DuckDB " + $row[1] + " CLI (set FSQL_DUCKDB_" + $row[0] + ", or put it in $HOME\duckdb-cli\v<version>\)"); continue }
    $ver = ((& $cli --version 2>&1 | plain_lines | Out-String).Trim() -split '\s+')[0]
    foreach ($band in @(@("S", $bandS, $row[2]), @("L", $bandL, $row[3]))) {
      $want = $band[2]
      # the LTS band is the latest 1.4.x only: an older 1.4.x CLI must refuse it
      if ($band[0] -eq "L" -and $row[0] -eq "14" -and $ver -ne $lver) { $want = "refuse" }
      $sql = "LOAD '" + $band[1] + "'; " + $probe + ";"
      $out = (& $cli -unsigned -csv -c $sql 2>&1 | plain_lines | Out-String)
      $rc = $LASTEXITCODE
      $head = $out.Trim(); if ($head.Length -gt 160) { $head = $head.Substring(0, 160) }
      if ($want -eq "load") {
        if (($rc -eq 0) -and ($out -notmatch '(?i)error|exception')) { & $ok "" }
        else { & $bad ("band " + $band[0] + " should load on DuckDB " + $ver + ": " + $head) }
      } else {
        if ($out -match 'C API version|built specifically for DuckDB version') { & $ok "" }
        else { & $bad ("band " + $band[0] + " should be refused by DuckDB " + $ver + " (rc=" + $rc + "): " + $head) }
      }
    }
  }

  if ($script:capi_nf -eq 0 -and $script:capi_np -gt 0) {
    $skipNote = ""
    if ($script:capi_ns -gt 0) { $skipNote = ", " + $script:capi_ns + " skipped" }
    pass ("46 capi_matrix: " + $script:capi_np + " checks passed" + $skipNote + " (load/refuse matrix, footer, exports, no DuckDB code inside)")
  } else {
    fail ("46 capi_matrix: " + $script:capi_nf + " check(s) failed (" + $script:capi_np + " passed)")
  }
}

# --- gates 53-55: the python test drivers (test\edge_inputs.py, error_table.py, ledger_sql.py) and the ledger unit test ---------------
# They use test\harness_common.py, which compiles the mock plugins with the gcc-style compiler named by FSQL_CC (the same one
# compile_plugins uses) and finds the CLI and the extension through FSQL_DUCKDB_<line> and CAPI_DIST. Python is stdlib-only here
# ($script:PYANY); a gate skips when there is no interpreter or no compiler, like the MCP gates.
function capi_py_ready {
  param([string]$num, [string]$label)
  if (-not $script:PYANY) { skip ($num + " " + $label + " (no python interpreter: set FSQL_PYTHON_ANY)"); return $false }
  if (-not $script:CC) { skip ($num + " " + $label + " (no gcc-style compiler for the mock plugins: set FSQL_CC)"); return $false }
  if (-not $script:EXT -or -not (Test-Path -LiteralPath $script:EXT)) { skip ($num + " " + $label + " (no extension resolved)"); return $false }
  if (-not (Test-Path -LiteralPath $script:DUCK)) { skip ($num + " " + $label + " (no DuckDB CLI resolved)"); return $false }
  return $true
}

# the environment the drivers read, set for the duration of one script run
function capi_py_run {
  param([string]$script_name, [string]$extraArgs = "")
  $line = "15"
  if ($script:DUCK_VERSION -match '^1\.4\.') { $line = "14" } elseif ($script:DUCK_VERSION -match '^2\.') { $line = "20" }
  $vars = @{
    ("FSQL_DUCKDB_" + $line) = $script:DUCK
    CAPI_DIST = (Split-Path -Parent $script:EXT)
    EDGE_LINE = $line
    FSQL_CC = $script:CC
    PYTHONIOENCODING = "utf-8"
    PYTHONUTF8 = "1"
  }
  $old = @{}
  foreach ($k in $vars.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k, "Process"); [Environment]::SetEnvironmentVariable($k, $vars[$k], "Process") }
  try {
    $out = (& $script:PYANY -I (Join-Path $script:HERE ("test\" + $script_name)) 2>&1 | plain_lines | Out-String -Width 8192)
    $rc = $LASTEXITCODE
  } finally {
    foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k], "Process") }
  }
  return @{ out = $out; rc = $rc }
}

function gate_53 {
  if (-not (Test-Path -LiteralPath (Join-Path $script:HERE "test\edge_inputs.py"))) { skip "53 capi_edge (no test\edge_inputs.py)"; return }
  if (-not (capi_py_ready "53" "capi_edge")) { return }
  $r = capi_py_run "edge_inputs.py"
  $n = ""; $bad = ""
  if ($r.out -match '(\d+) statements in') { $n = $Matches[1] }
  if ($r.out -match '(\d+) function sweep\(s\) with a crash') { $bad = $Matches[1] }
  if ($r.rc -eq 0 -and $bad -eq "0" -and $n) {
    pass ("53 capi_edge: " + $n + " awkward-argument statements across every registered function: no crash, no INTERNAL error")
  } else {
    ($r.out -split "`n" | Where-Object { $_ -match 'FAIL|crash|INTERNAL' } | Select-Object -First 10) | ForEach-Object { [Console]::Error.WriteLine("    " + $_) }
    fail ("53 capi_edge: a function sweep crashed or reported INTERNAL (run test\edge_inputs.py)")
  }
}

function gate_54 {
  if (-not (Test-Path -LiteralPath (Join-Path $script:HERE "test\error_table.py"))) { skip "54 error_table (no test\error_table.py)"; return }
  if (-not (capi_py_ready "54" "error_table")) { return }
  $r = capi_py_run "error_table.py"
  $line = ($r.out -split "`n" | Where-Object { $_ -match '^error table: ' } | Select-Object -Last 1)
  if ($r.rc -eq 0 -and $line) {
    pass ("54 error_table: " + ($line -replace '^error table: ', '').Trim())
  } else {
    ($r.out -split "`n" | Where-Object { $_ -match '^  FAIL|^       expected' } | Select-Object -First 20) | ForEach-Object { [Console]::Error.WriteLine("    " + $_) }
    fail ("54 error_table: " + $(if ($line) { $line.Trim() } else { "the table did not finish" }) + " (run test\error_table.py)")
  }
}

# test\ledger_unit.c, built here and run in each environment it needs (the size cap and the anchor mode are read once per process)
function gate_55 {
  $src = Join-Path $script:HERE "test\ledger_unit.c"
  if (-not (Test-Path -LiteralPath $src)) { skip "55 ledger_integrity (no test\ledger_unit.c)"; return }
  if (-not $script:CC) { skip "55 ledger_integrity (no gcc-style compiler: set FSQL_CC)"; return }
  $w = Join-Path $script:PDIR "ledger"
  New-Item -ItemType Directory -Force -Path $w | Out-Null
  $exe = Join-Path $w "ledger_unit.exe"
  & $script:CC -std=c11 -O1 -g -Wall -Wextra -I (Join-Path $script:HERE "src") $src -o $exe 2> (Join-Path $w "build.log")
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
    Get-Content -LiteralPath (Join-Path $w "build.log") -ErrorAction SilentlyContinue | Select-Object -First 8 | ForEach-Object { [Console]::Error.WriteLine("    " + $_) }
    fail "55 ledger store: ledger_unit did not build (see build.log)"; return
  }
  $runs = @(
    @{ label = "default"; mode = "default"; env = @{} },
    @{ label = "cap";     mode = "cap";     env = @{ FSQL_DUCKDB_LEDGER_MAX_BYTES = "100" } },
    @{ label = "nocap";   mode = "nocap";   env = @{ FSQL_DUCKDB_LEDGER_MAX_BYTES = "0" } },
    @{ label = "badcap";  mode = "badcap";  env = @{ FSQL_DUCKDB_LEDGER_MAX_BYTES = "abc" } },
    @{ label = "anchor";  mode = "anchor";  env = @{ FSQL_LEDGER_ANCHOR_LOG = "stderr" } }
  )
  $bad = 0
  foreach ($r in $runs) {
    $old = @{}
    foreach ($k in $r.env.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k, "Process"); [Environment]::SetEnvironmentVariable($k, $r.env[$k], "Process") }
    try { $o = (& $exe $r.mode 2>&1 | plain_lines | Out-String); $rc = $LASTEXITCODE }
    finally { foreach ($k in $r.env.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k], "Process") } }
    if ($rc -ne 0) { $bad++; ($o -split "`n" | Where-Object { $_ -match 'FAIL' } | Select-Object -First 3) | ForEach-Object { [Console]::Error.WriteLine("    " + $r.label + ": " + $_) } }
  }
  if ($bad -eq 0) { pass ("55 ledger store: forged/damaged chains, size cap, anchor log, allocation failure (" + $runs.Count + " runs)") }
  else { fail ("55 ledger store: " + $bad + " of " + $runs.Count + " run(s) failed (run test\ledger_unit.c)") }
  # the ledger through SQL, with the mock enterprise core
  if (-not (Test-Path -LiteralPath (Join-Path $script:HERE "test\ledger_sql.py"))) { skip "55 ledger sql (no test\ledger_sql.py)"; return }
  if (-not (capi_py_ready "55" "ledger sql")) { return }
  $r2 = capi_py_run "ledger_sql.py"
  $l2 = ($r2.out -split "`n" | Where-Object { $_ -match '^ledger sql: ' } | Select-Object -Last 1)
  if ($r2.rc -eq 0 -and $l2) { pass ("55 ledger sql: " + ($l2 -replace '^ledger sql: ', '').Trim()) }
  else {
    ($r2.out -split "`n" | Where-Object { $_ -match '^  FAIL' } | Select-Object -First 8) | ForEach-Object { [Console]::Error.WriteLine("    " + $_) }
    fail "55 ledger sql: failures (run test\ledger_sql.py)"
  }
}

function gate_56 { skip "56 capi_oom (the allocation-failure sweep interposes the allocator with LD_PRELOAD: Linux only)" }
function gate_57 { skip "57 capi_oom_full (the allocation-failure sweep interposes the allocator with LD_PRELOAD: Linux only)" }

function gate_title {
  param([string]$n, [string]$name)
  Write-Host ("")
  Write-Host ("== Gate " + $n + ": " + $name)
}

function gate_name {
  param([string]$n)
  switch ($n) {
    "01" { return "build" }
    "02" { return "smoke" }
    "03" { return "schema_context" }
    "04" { return "text_to_sql" }
    "05" { return "evil_overread" }
    "06" { return "crash_recovery" }
    "07" { return "evil_lying_length" }
    "08" { return "authz" }
    "09" { return "path_security" }
    "10" { return "dos_and_injection" }
    "11" { return "scout" }
    "12" { return "soak" }
    "13" { return "siu_mode" }
    "14" { return "retry" }
    "15" { return "embed" }
    "16" { return "embed_authz" }
    "17" { return "embed_soak" }
    "18" { return "embed_crash" }
    "19" { return "sfs_bounds" }
    "20" { return "api_func" }
    "21" { return "fuzz_smoke" }
    "22" { return "v2_functions" }
    "23" { return "agents" }
    "24" { return "enterprise" }
    "25" { return "enterprise_stress" }
    "26" { return "enterprise_signature" }
    "27" { return "think" }
    "28" { return "review_isolation" }
    "29" { return "domain_agents" }
    "30" { return "feature_store" }
    "31" { return "ledger_chain" }
    "32" { return "enterprise_signature_real" }
    "33" { return "tsan_ledger_concurrent" }
    "34" { return "kits" }
    "35" { return "mcp_probes" }
    "36" { return "mcp_smoke" }
    "37" { return "mcp_https" }
    "38" { return "mcp_cli" }
    "39" { return "mcp_db_probe" }
    "40" { return "mcp_concurrency_probe" }
    "41" { return "mcp_faults" }
    "42" { return "mcp_fuzz" }
    "43" { return "recall_hybrid_filter" }
    "44" { return "shipped_http_plugin" }
    "45" { return "mcp_conformance" }
    "46" { return "capi_matrix" }
    "47" { return "fuzz_parse" }
    "53" { return "capi_edge" }
    "54" { return "error_table" }
    "55" { return "ledger_integrity" }
    "56" { return "capi_oom" }
    "57" { return "capi_oom_full" }
    "58" { return "mcp_audit_http" }
  }
  return ""
}

function gate_body {
  param([string]$g)
  switch ($g) {
    "01" { gate_01 }
    "02" { gate_02 }
    "03" { gate_03 }
    "04" { gate_04 }
    "05" { gate_05 }
    "06" { gate_06 }
    "07" { gate_07 }
    "08" { gate_08 }
    "09" { gate_09 }
    "10" { gate_10 }
    "11" { gate_11 }
    "12" { gate_12 }
    "13" { gate_13 }
    "14" { gate_14 }
    "15" { gate_15 }
    "16" { gate_16 }
    "17" { gate_17 }
    "18" { gate_18 }
    "19" { gate_19 }
    "20" { gate_20 }
    "21" { gate_21 }
    "22" { gate_22 }
    "23" { gate_23 }
    "24" { gate_24 }
    "25" { gate_25 }
    "26" { gate_26 }
    "27" { gate_27 }
    "28" { gate_28 }
    "29" { gate_29 }
    "30" { gate_30 }
    "31" { gate_31 }
    "32" { gate_32 }
    "33" { gate_33 }
    "34" { gate_34 }
    "35" { gate_35 }
    "36" { gate_36 }
    "37" { gate_37 }
    "38" { gate_38 }
    "39" { gate_39 }
    "40" { gate_40 }
    "41" { gate_41 }
    "42" { gate_42 }
    "43" { gate_43 }
    "44" { gate_44 }
    "45" { gate_45 }
    "46" { gate_46 }
    "47" { gate_47 }
    "53" { gate_53 }
    "54" { gate_54 }
    "55" { gate_55 }
    "56" { gate_56 }
    "57" { gate_57 }
    "58" { gate_58 }
  }
}

function run_gate {
  param([string]$g)
  $name = gate_name $g
  if (-not $name) {
    fail ("unknown gate """ + $g + """")
    return
  }
  gate_title $g $name
  $script:GATES_RAN = $script:GATES_RAN + 1
  $t0 = Get-Date
  gate_body $g
  $dt = [int]((Get-Date) - $t0).TotalSeconds
  if ($dt -gt 0) { Write-Host ("   (gate " + $g + " took " + $dt + "s)") }
}

function main {
  if ($script:ONE_KIT) {
    # One kit, printed: the authoring aid for a kit's HEADLINE
    # predicate. The kit runs under the same mock-plugin environment
    # gate 34 sets up, so what it prints here is what the gate sees.
    find_toolchain
    if (-not $script:EXT) {
      if ($env:FSQL_EXT) {
        if (-not (Test-Path -LiteralPath $env:FSQL_EXT)) { die ("FSQL_EXT=" + $env:FSQL_EXT + " does not exist") }
        $script:EXT = $env:FSQL_EXT
      } else {
        $script:EXT = resolve_ext
        # A CLI picked up from dist/ (the no-PATH fallback) is paired with
        # the extension beside it; that pair beats the newest-wins glob.
        if ($script:DUCK_PAIR_EXT) { $script:EXT = $script:DUCK_PAIR_EXT }
      }
      if (-not $script:EXT) { die "no fractalsql.*.duckdb_extension under dist/ (run build.sh first, or set FSQL_EXT)" }
      assert_ext_matches_cli $script:EXT
      $script:EXT_SLASH = $script:EXT.Replace('\', '/')
    }
    # the fixture plugins compile into $script:PDIR, which the
    # non-kit path below only assigns on the way to the gate list --
    # so the kit path has to set it up itself.
    $script:PDIR = Join-Path $script:BTROOT ("fractalsql_bt_" + $PID)
    compile_plugins
    UseMockPluginEnv
    try {
      Write-Output (RunVerticalKit $script:ONE_KIT)
    } catch {
      die ("kit run failed: " + $_.Exception.Message)
    } finally {
      RestoreMockPluginEnv
    }
    return
  }
  if ($script:LIST_ONLY) {
    foreach ($g in @("01","02","03","04","05","06","07","08","09","10","11","12","13","14","15","16","17","18","19","20",
                     "21","22","23","24","25","26","27","28","29","30","31","32","33","34","35","36","37","38","39","40","41","42","43","44","45","46","47","53","54","55","56","57","58")) {
      Write-Output ("  " + $g + "  " + (gate_name $g))
    }
    return
  }

  # Native sanitizer cell: built BEFORE the gates run. A build failure
  # must stop the whole run -- failing one gate and letting the other
  # thirty-four report against a stale artifact would be worse than
  # no report at all.
  if ($script:SAN -and (-not $env:FSQL_EXT)) {
    try { $script:SAN_CELL = Build-SanCell -Mode $script:SAN }
    catch { die ("sanitizer cell build failed: " + $_.Exception.Message) }
  }

  # -Rebuild: satisfy gate 01's staleness assertion by rebuilding the
  # extension, instead of leaving it to a separate command. This runs
  # BEFORE find_toolchain, because that call dies outright when no
  # artifact under dist\ pairs with a CLI -- the "you have not built
  # yet" case is exactly one of the two this switch exists for.
  if ($Rebuild) {
    if ($script:SAN) {
      Write-Host "  -Rebuild: the sanitizer cell builds its own artifact -- nothing to do"
    } elseif ($env:FSQL_EXT) {
      # An explicitly named artifact is somebody else's: the build writes
      # under dist\, so rebuilding would not touch it.
      Write-Host ("  -Rebuild: FSQL_EXT names the artifact -- not rebuilt")
    } else {
      # The same pairing the gates use: an artifact that a CLI under
      # dist\ can load. No pair at all means there is nothing to test
      # against, which is the other half of "build first".
      $pair = resolve_dist_cli_pair
      $why = ""
      if (-not $pair) {
        $why = "no artifact under dist\ pairs with a CLI"
      } else {
        $stale = ext_stale_source $pair.Ext
        if ($stale) { $why = (Split-Path -Leaf $pair.Ext) + " is older than " + $stale.Name }
      }
      if (-not $why) {
        Write-Host ("  -Rebuild: the artifact is current -- nothing to rebuild")
      } else {
        Write-Host ("  -Rebuild: " + $why + " -- rebuilding")
        if (-not (rebuild_extension)) { die "-Rebuild: the extension build failed" }
      }
    }
  }

  find_toolchain

  $script:PDIR = Join-Path $script:BTROOT ("fractalsql_bt_" + $PID)
  $script:DB = Join-Path $script:PDIR "bt.db"

  compile_plugins

  if ($script:MCP_ALIAS) {
    $toRun = @("35","36","37","38","39","40","41","58")
  } elseif ($script:ONE_GATE) {
    $toRun = @($script:ONE_GATE)
  } elseif ($script:MODE -eq "quick") {
    $toRun = @("01", "02")
  } elseif ($script:MODE -eq "fuzz") {
    $toRun = @("21", "42", "47")
  } else {
    $toRun = @("01","02","03","04","05","06","07","08","09","10","11","12","13","14","15","16","17","18","19","20",
               "22","23","24","25","26","27","28","29","30","31","32","34","35","36","37","38","39","40","41","43","44","45","46","53","54","55","56","58")
  }

  # Every gate except 01 (locate) resolves the artifact itself, so a
  # run that does not include 01 -- a single-gate run, or the fuzz
  # run -- has to resolve it up front.
  if (($toRun -notcontains "01") -and (-not $script:EXT)) {
    if ($env:FSQL_EXT) {
      # FSQL_EXT names the artifact explicitly -- the only way to
      # pick between the artifacts of two DuckDB lines, which the
      # loader's own version check then has to agree with
      if (-not (Test-Path -LiteralPath $env:FSQL_EXT)) {
        die ("FSQL_EXT=" + $env:FSQL_EXT + " does not exist")
      }
      $script:EXT = $env:FSQL_EXT
    } elseif ($script:SAN) {
      $script:EXT = resolve_san_ext
      if (-not $script:EXT) {
        try { $script:SAN_CELL = Build-SanCell -Mode $script:SAN; $script:EXT = $script:SAN_CELL.Ext }
        catch { die ("01 build [" + $script:SAN + "]: " + $_.Exception.Message) }
      }
    } else {
      $script:EXT = resolve_ext
      if ($script:DUCK_PAIR_EXT) { $script:EXT = $script:DUCK_PAIR_EXT }
    }
    if (-not $script:EXT) { die "no fractalsql.*.duckdb_extension under dist/ (run build.sh first, or set FSQL_EXT)" }
    assert_ext_matches_cli $script:EXT
    $script:EXT_SLASH = $script:EXT.Replace('\', '/')
  }

  Write-Host ("")
  $ver = (& $script:DUCK --version 2>$null | Select-Object -First 1)
  $sanTag = if ($script:SAN) { " [" + $script:SAN + "-instrumented extension]" } else { "" }
  Write-Host ("fractalsql-ext build_test" + $sanTag + " -- " + $ver + " -- gates: " + (($toRun | ForEach-Object { $_ }) -join ", "))

  foreach ($g in $toRun) {
    # every gate except 01 (locate) runs on the shared fixture
    # database -- the fuzz gate included, whose closing assertion is
    # that nothing it fed the extension was executed
    if (($g -ne "01") -and (-not $script:SETUP_DONE)) {
      bt_setup
      $script:SETUP_DONE = $true
    }
    run_gate $g
  }

  if ($script:FAILED -eq 0) {
    Write-Host ("")
    Write-Host ("== ALL GREEN: " + $script:GATES_RAN + " gates ran, 0 failing assertions")
    # explicit: a gate that deliberately drove the CLI into a nonzero
    # exit leaves $LASTEXITCODE set, and without this the harness would
    # hand that exit code to the shell even though every assertion
    # passed.
    exit 0
  } else {
    Write-Host ("")
    Write-Host ("== FAILED: " + $script:FAILED + " failing assertion(s) across " + $script:GATES_RAN + " gates")
    exit 1
  }
}


# -Asan and -Ubsan are native: the harness rebuilds the extension with
# scripts\windows\build.bat into dist\windows-asan\ or
# dist\windows-ubsan\, together with the matching DuckDB CLI, and every
# gate then drives that instrumented CLI against the instrumented
# extension. The CLI is instrumented on purpose: an ASan runtime that
# is loaded after the process is already running is the one order ASan
# refuses to work in, so the host has to carry the sanitizer too.

# ----------------------------------------------------------------
# Entry point.
# ----------------------------------------------------------------

$script:HERE = Split-Path -Parent $PSCommandPath
Set-Location -LiteralPath $script:HERE
# Test fixtures load an unsigned extension build and unsigned mock reasoning plugins; the product defaults are exercised explicitly where tested.
if (-not $env:FSQL_DUCKDB_ALLOW_UNSIGNED) { $env:FSQL_DUCKDB_ALLOW_UNSIGNED = "true" }
if (-not $env:FSQL_REASONING_REQUIRE_SIGNATURE) { $env:FSQL_REASONING_REQUIRE_SIGNATURE = "0" }

$script:MODE = "full"
$script:ONE_GATE = ""
$script:ONE_KIT = ""
$script:LIST_ONLY = [bool]($List -and $List.IsPresent)

if ($Asan -and $Ubsan) { die "-Asan and -Ubsan are mutually exclusive" }
$script:SAN = $null
$script:SAN_CELL = $null
# The extension paired with the CLI the harness picked up from dist/
# (the no-PATH fallback). Null when the CLI came from PATH or from an
# explicit FSQL_DUCKDB.
$script:DUCK_PAIR_EXT = $null
# the DuckDB version the CLI under test reports ("2.0.0"); the
# extension artifact is pinned to a DuckDB line and the loader refuses
# a mismatch, so this is what the artifact is chosen against.
$script:DUCK_VERSION = ""
if ($Asan)  { $script:SAN = "asan" }
if ($Ubsan) { $script:SAN = "ubsan" }
if ($Tsan) {
  die "-Tsan has no build path in the duckdb build (gate 33 is a documented skip); use -Asan (native MSVC run)"
}
if ($Coverage) {
  die "-Coverage has no build path in the duckdb build; use -Asan"
}
if ($Help) { usage | Write-Host; exit 0 }

if ($Quick) { $script:MODE = "quick" }
if ($Fuzz)  { $script:MODE = "fuzz" }
$script:MCP_ALIAS = $false
if ($Gate -eq "mcp") { $script:MCP_ALIAS = $true }
elseif ($Gate)  { $script:ONE_GATE = ("{0:D2}" -f ([int]$Gate)) }
if ($Kit)   { $script:ONE_KIT = $Kit }

if ($script:SAN -eq "asan") {
  # native ASan, falling straight into main. Default: disable ASan's
  # container-overflow check. The instrumented extension and the
  # instrumented CLI are the same build now (one configure, one
  # compiler, one CRT), so the annotation mismatch the old
  # mixed-instrumentation posture produced is gone -- but the
  # container-overflow check still fires inside DuckDB's own
  # teardown on Windows native, so it stays off. The fully-instrumented
  # docker ./build_test.sh --asan cell keeps the check ON;
  # FSQL_ASAN_OPTIONS overrides this default wholesale.
  if ($env:FSQL_ASAN_OPTIONS) { $env:ASAN_OPTIONS = $env:FSQL_ASAN_OPTIONS }
  else { $env:ASAN_OPTIONS = "detect_container_overflow=0" }
}
if ($script:SAN -eq "ubsan") {
  # UBSan reports and CONTINUES by default: a matrix that stops at the
  # first undefined behaviour would report one gate, where a report
  # that keeps going lets the sweep find every gate that touched it.
  # The build uses -fsanitize=undefined without -fno-sanitize-recover
  # for the same reason.
  if ($env:FSQL_UBSAN_OPTIONS) { $env:UBSAN_OPTIONS = $env:FSQL_UBSAN_OPTIONS }
  else { $env:UBSAN_OPTIONS = "print_stacktrace=1:report_error_type=1" }
}

try {
  main
} finally {
  cleanup
}
