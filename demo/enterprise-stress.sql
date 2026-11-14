-- demo/enterprise-stress.sql
--
-- FractalSQL Enterprise -- QTL Ledger under stress in this build.
--
-- Companion to enterprise-qtl-audit.sql (which walks the gated surface
-- one call at a time). This demo hammers the same surface: it fills the
-- in-memory Truth/Shadow ledgers to their capacity bound (64 each),
-- churns repeated flush/load cycles, then builds an append-only chain
-- and walks it with fractal_ledger_verify().
--
-- Runs in BOTH states, one CLI invocation each:
--
--   * Enterprise ACTIVE -- every phase below runs.
--
--   * Enterprise DORMANT -- the first gated enterprise call (the Phase A
--     probe) raises the clean activation error, and under -bail the run
--     stops right there. That IS the dormant-path demonstration: the
--     activation error on screen, community search unaffected (DuckDB
--     has no procedural SQL to catch-and-continue inside one script, so
--     the two states are two invocations, not two branches).
--
-- What cannot port (gaps of this build, judged and
-- documented rather than faked):
--   * The tamper-evidence phases (corrupting
--     a PERSISTED blob via direct table manipulation -- truncation,
--     payload byte-flip, HMAC envelope) have no target here. This
--     build's ledger storage is an opaque in-memory per-connection VFS
--     (docs/enterprise.md): no SQL-visible
--     fractalsql_ledger table, no blob accessor from SQL at all, and
--     the vendored core carries no HMAC keying surface this build can
--     set (see docs/enterprise.md for the full gap list). Porting the
--     tamper phases for real needs a blob-accessor companion in src/
--     first (e.g. fractal_ledger_export_blob(kind) -> BLOB /
--     fractal_ledger_import_blob(kind, blob)), rather than faking it.
--     The in-memory chain is still tamper-CHECKABLE: the verify() walk
--     below recomputes every hash link -- but nothing on this build's
--     SQL surface can corrupt the chain mid-run, so only the clean
--     chain half of Phase E is demonstrated.
--   * Concurrency / cross-session persistence (parallel last-writer-wins
--     flush, load-in-a-fresh-connection) has no DuckDB embedded-engine
--     analog: the ledger is per-connection and the database file is
--     single-writer. That coverage belongs to the test harness.
--
-- Activate: set FRACTALSQL_ENTERPRISE_LIB in the environment the duckdb
-- process starts in (env config only in this build -- no config file to
-- reload), then:
--
--   FRACTALSQL_ENTERPRISE_LIB=/path/to/libfractalsql-enterprise-sovereign-c.so \
--     { echo "LOAD '<path/to/fractalsql.v1.5.6.<platform>.duckdb_extension>';"; \
--       cat demo/enterprise-stress.sql; } | duckdb -bail -unsigned
--
-- Omit the env var entirely to see the dormant path (a stop at the
-- Phase A probe with the activation error is the EXPECTED dormant
-- output, not a failure).
--
-- Safe to re-run: the ledger context is per-connection in memory -- a
-- fresh duckdb process starts empty; there is no persisted table to
-- drop.

.print === Enterprise QTL Ledger -- stress (this build) ===
.print fractal_feedback_report() is a COMMUNITY primitive used to seed the
.print in-memory Truth/Shadow ledgers that the enterprise tier later
.print seals into a QTL blob. Caps: 64 Truth + 64 Shadow (the core's
.print FSQL_TRUTH/SHADOW_DEFAULT_CAP) -- informational, confirmed by eye
.print on an active run. Each fractal_feedback_report() call below
.print returns true in this build -- the true rows ARE the successful
.print writes, not noise to ignore.

-- The diversify/repulsion path is the documented precondition for
-- engagement recording; the inserts themselves are ledger-level.
SELECT fractal_diversify_enable();

.print
.print --- Phase A: fill to capacity bound + flush ---
-- The first enterprise call below (reset_hard) is the dormant probe: it
-- succeeds under the enterprise tier; on a dormant run the script
-- stops here with:
--   IO Error: fractalsql: fractal_ledger_reset_hard requires the
--   FractalSQL Enterprise tier -- set FRACTALSQL_ENTERPRISE_LIB ...
SELECT fractal_ledger_reset_hard();

-- 64 distinct Truth events (doc_ids 1..64) + 64 distinct Shadow events
-- (doc_ids 65..128). Disjoint doc_ids => no QTL dedup => the blob
-- encodes all 128. Beyond 64 of either kind the ledger evicts the
-- lowest-weight entry, so 64/64 is the cap.
SELECT fractal_feedback_report(n, 'positive')
FROM range(1, 65) seq(n);
SELECT fractal_feedback_report(n, 'negative')
FROM range(65, 129) seq(n);

.print (expect truth_count=64 shadow_count=64)
SELECT fractal_ledger_truth_count() AS truth_count,
       fractal_ledger_shadow_count() AS shadow_count;

SELECT fractal_ledger_flush();
-- The audit round-trip (fractal_audit_unpack over the
-- persisted blob, expecting a 128-element CISO array) has no target
-- here: nothing on this build's SQL surface can hand back the flushed
-- blob (flush returns true; there is no blob accessor) -- see the
-- header's "What cannot port". The count assertions above are the
-- round-trip's observable half.

.print
.print --- Phase B: churn (5 flush/load cycles at capacity) ---
-- Each cycle: reset_hard, refill 64+64 with a cycle-unique doc_id
-- offset (so no cross-cycle dedup), flush, load. DuckDB CLI has no
-- loop construct, so the 5 cycles are unrolled explicitly.

SELECT fractal_ledger_reset_hard();
SELECT fractal_feedback_report(n + 1000, 'positive') FROM range(1, 65) seq(n);
SELECT fractal_feedback_report(n + 1000, 'negative') FROM range(65, 129) seq(n);
SELECT fractal_ledger_flush();
SELECT fractal_ledger_load();

SELECT fractal_ledger_reset_hard();
SELECT fractal_feedback_report(n + 2000, 'positive') FROM range(1, 65) seq(n);
SELECT fractal_feedback_report(n + 2000, 'negative') FROM range(65, 129) seq(n);
SELECT fractal_ledger_flush();
SELECT fractal_ledger_load();

SELECT fractal_ledger_reset_hard();
SELECT fractal_feedback_report(n + 3000, 'positive') FROM range(1, 65) seq(n);
SELECT fractal_feedback_report(n + 3000, 'negative') FROM range(65, 129) seq(n);
SELECT fractal_ledger_flush();
SELECT fractal_ledger_load();

SELECT fractal_ledger_reset_hard();
SELECT fractal_feedback_report(n + 4000, 'positive') FROM range(1, 65) seq(n);
SELECT fractal_feedback_report(n + 4000, 'negative') FROM range(65, 129) seq(n);
SELECT fractal_ledger_flush();
SELECT fractal_ledger_load();

SELECT fractal_ledger_reset_hard();
SELECT fractal_feedback_report(n + 5000, 'positive') FROM range(1, 65) seq(n);
SELECT fractal_feedback_report(n + 5000, 'negative') FROM range(65, 129) seq(n);
SELECT fractal_ledger_flush();
SELECT fractal_ledger_load();

.print (expect truth_count=64 shadow_count=64 after 5 churn cycles)
SELECT fractal_ledger_truth_count() AS truth_count,
       fractal_ledger_shadow_count() AS shadow_count;

.print
.print --- Phase E: append-only chain (clean-chain half) ---
.print The ledger is an append-only hash chain, not a last-writer-wins
.print snapshot. fractal_ledger_load() only checks the chain TIP
.print (O(1), cheap, every load); fractal_ledger_verify() walks the
.print WHOLE chain (O(n), on demand). This build's chain is in-memory
.print per connection, and every flush Phases A/B made appended one
.print entry -- those stick, so rows_verified below reflects that
.print history plus the three fresh flushes here.
.print Phase E's tamper half (a middle-row tamper that load()'s
.print tip-only check cannot see but verify()'s full walk catches)
.print is table manipulation and cannot port -- see the header.

SELECT fractal_ledger_reset_hard();
SELECT fractal_feedback_report(1, 'positive');
SELECT fractal_ledger_flush();
SELECT fractal_ledger_reset_hard();
SELECT fractal_feedback_report(2, 'positive');
SELECT fractal_ledger_flush();
SELECT fractal_ledger_reset_hard();
SELECT fractal_feedback_report(3, 'positive');
SELECT fractal_ledger_flush();

.print (expect ok=true and rows_verified growing by 3 -- one per flush
.print this connection has ever made)
SELECT fractal_ledger_verify();

-- The decision-audit chain (kind=2, appended by fractal_audit_log) gets
-- the same chain-verification guarantee; recorded here as this build's
-- live illustration of append-and-verify mechanics, which the
-- middle-row tamper demonstration otherwise exercised:
SELECT fractal_audit_log('allocation-review',
    '{"reason":"enterprise-stress demo entry","risk":"low"}');
SELECT fractal_audit_log('data-analyst-run',
    '{"tables":["bi_orders"],"rows_inspected":0}');

.print (expect ok=true, rows_verified=2 for the audit chain)
SELECT fractal_ledger_verify(2);

.print
.print Verify's shape in this build (docs/enterprise.md):
.print {"ok":true,"rows_verified":N} on a clean chain; {"ok":false,
.print "first_failure_id":<id>,"reason":"..."} on the first failure.
.print The reasons it can report: "sequence gap (a row was deleted)",
.print "chain-link break (prev_hash mismatch)", "entry_hash mismatch
.print (blob or mac tampered)" and "out of memory" (in-memory
.print corruption/reordering is the only way a link breaks here --
.print deliberately no SQL-side corruption path exists in this build).
.print Concurrency (parallel append-only writers staying one unforked
.print chain) is exercised by the test harness -- not something a
.print single CLI session can drive (single-writer file lock).

.print
.print === Demo complete: ledger stress surface exercised; dormant path
.print stops at the Phase A probe with the activation error. ===