-- demo/enterprise-qtl-audit.sql
--
-- FractalSQL Enterprise -- Quantized Ternary Ledger (QTL), end to end.
--
-- The QTL ledger surface is enterprise-tier, runtime-gated behind a
-- second dlopen'd library (see docs/enterprise.md
-- for the full rationale): fractal_ledger_flush/_load/_compact/
-- _reset_soft/_reset_hard/_truth_count/_shadow_count and
-- fractal_audit_unpack are DORMANT until FRACTALSQL_ENTERPRISE_LIB
-- (an environment variable -- no config function or config file in an
-- embedded engine) names a library exporting the expected symbols,
-- read once at first use in the process.
--
-- No enterprise artifact ships with this repo (there's no separate
-- "enterprise .so" built for DuckDB yet, unlike the community-
-- sovereign core, which IS vendored). Set FRACTALSQL_ENTERPRISE_LIB
-- before starting duckdb if you have a compatible library to test
-- against; otherwise this script will error at the first
-- fractal_ledger_flush() call below with "requires the FractalSQL
-- Enterprise tier".
--
-- Plain DuckDB SQL has no generic exception-catching expression --
-- there's no SQL-level try/catch around an arbitrary function call,
-- so this script can't self-detect the dormant state and degrade the
-- way a procedural DO $$ ... EXCEPTION WHEN ... END $$ block would.
-- This build can't make a "runs cleanly either way" promise; check
-- your environment variable before running this, rather than relying
-- on the script to self-detect and degrade.
--
-- Persistence note: this build's ledger storage is in-memory only, per
-- DuckDB connection -- there is no persisted fractalsql_ledger table.
-- "Flush"/"load" here
-- round-trip through that in-memory representation, not a durable
-- table; state is lost when the connection closes.
--
-- Known gap (flagged for the src/ owner, not fixed here): this build's
-- fractal_audit_unpack(blob BLOB) has no SQL-visible way to fetch the
-- blob it expects as input. Nothing in the current SQL surface
-- produces a BLOB value to pass it. The Phase B "decode the persisted
-- blob" step is omitted below rather than
-- faked; fractal_audit_unpack needs a companion accessor (e.g.
-- fractal_ledger_export_blob(kind) -> BLOB) before it's actually
-- usable from SQL.

.print === 1. Seed real engagement events into the in-memory Truth/Shadow ledgers ===
.print fractal_feedback_report() is a COMMUNITY primitive -- it records search
.print engagement (dwell / positive -> Truth, negative -> Shadow) into the same
.print in-memory context the enterprise ledger later seals. No enterprise tier
.print needed for this step.

SELECT fractal_diversify_enable();

-- Record two Truth events (positive + dwell) and two Shadow events (negative).
-- result_handle is the corpus row index the event refers to.
SELECT fractal_feedback_report(1, 'positive', 500);   -- Truth: doc 1
SELECT fractal_feedback_report(2, 'dwell',   1200);    -- Truth: doc 2
SELECT fractal_feedback_report(3, 'negative');          -- Shadow: doc 3
SELECT fractal_feedback_report(4, 'negative');          -- Shadow: doc 4

.print
.print === 2. Enterprise QTL Ledger (requires FRACTALSQL_ENTERPRISE_LIB) ===

-- Flush: encode the in-memory Truth + Shadow ledgers into a QTL blob,
-- held in this connection's in-memory storage VFS.
SELECT fractal_ledger_flush();
SELECT fractal_ledger_truth_count()  AS truth_count_after_flush;
SELECT fractal_ledger_shadow_count() AS shadow_count_after_flush;

-- Load: rehydrate the in-memory ledgers from the flushed representation.
SELECT fractal_ledger_load();

-- Compact: defragment / re-pack the in-memory QTL representation.
SELECT fractal_ledger_compact();

-- Reset soft: clear the Shadow ledger, preserve Truth.
SELECT fractal_ledger_reset_soft();
SELECT fractal_ledger_truth_count()  AS truth_count_after_reset_soft;
SELECT fractal_ledger_shadow_count() AS shadow_count_after_reset_soft;

-- Reset hard: clear both ledgers.
SELECT fractal_ledger_reset_hard();
SELECT fractal_ledger_truth_count()  AS truth_count_after_reset_hard;
SELECT fractal_ledger_shadow_count() AS shadow_count_after_reset_hard;

.print
.print === Demo complete (7 of 8 enterprise functions exercised -- ===
.print === fractal_audit_unpack skipped, see the gap noted at the top) ===
