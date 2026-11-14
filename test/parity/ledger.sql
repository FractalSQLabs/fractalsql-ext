-- Parity cases for the ledger family (fsql_ledger.c). No enterprise library is configured here, so the
-- enterprise-gated actions report the dormant tier; verify, lock and the checks that run before the
-- enterprise gate are exercised for real.

SELECT fractal_ledger_verify();

SELECT fractal_ledger_verify(1), fractal_ledger_verify(2), fractal_ledger_verify(7);

SELECT fractal_ledger_verify(NULL);

SELECT fractal_ledger_flush();

SELECT fractal_ledger_load();

SELECT fractal_ledger_compact();

SELECT fractal_ledger_reset_soft();

SELECT fractal_ledger_reset_hard();

SELECT fractal_ledger_truth_count();

SELECT fractal_ledger_shadow_count();

SELECT fractal_audit_log('decision', '{"x": 1}');

SELECT fractal_audit_log('decision', '{"x": 1}', 'alice');

SELECT fractal_audit_unpack('\x00\x01'::BLOB);

-- the destructive latch: once set, destructive actions refuse BEFORE the enterprise check
SELECT fractal_lock_destructive();

SELECT fractal_lock_destructive(), fractal_lock_destructive();

SELECT fractal_lock_destructive();
SELECT fractal_ledger_flush();

SELECT fractal_lock_destructive();
SELECT fractal_ledger_load();

SELECT fractal_lock_destructive();
SELECT fractal_ledger_compact();

SELECT fractal_lock_destructive();
SELECT fractal_ledger_reset_soft();

SELECT fractal_lock_destructive();
SELECT fractal_ledger_reset_hard();

SELECT fractal_lock_destructive();
SELECT fractal_audit_log('decision', '{"x": 1}');

-- reads are not destructive: still the dormant tier, not the latch
SELECT fractal_lock_destructive();
SELECT fractal_ledger_truth_count();

SELECT fractal_lock_destructive();
SELECT fractal_ledger_verify();

-- per-row evaluation of a constant call
SELECT count(DISTINCT fractal_ledger_verify()) FROM range(3000);

-- typing
SELECT typeof(fractal_ledger_flush()), typeof(fractal_ledger_truth_count()), typeof(fractal_ledger_verify()), typeof(fractal_lock_destructive());

-- ===== with a (mock) enterprise core: the real loader, the real chain =====

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT fractal_ledger_flush(), fractal_ledger_load(), fractal_ledger_compact(), fractal_ledger_reset_soft(), fractal_ledger_reset_hard();

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT fractal_ledger_truth_count(), fractal_ledger_shadow_count();

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT fractal_audit_log('decision', '{"x": 1}'), fractal_ledger_verify(2);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT fractal_audit_log('a', '{"x": 1}'), fractal_audit_log('b', '[1,2,3]', 'bob'), fractal_audit_log('c', '"str"'), fractal_audit_log('d', '17');
SELECT fractal_ledger_verify(2);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT count(fractal_audit_log('row', '{"i": ' || i || '}')) FROM range(500) t(i);
SELECT fractal_ledger_verify(2);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT fractal_audit_log('x', '{"a":');

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT fractal_audit_log('x', 'not json');

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT fractal_audit_log('x', '{"_actor": "forged"}');

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT fractal_audit_log('x', '{"a": [1, 2.5e3, -0, true, false, null, {"b": "cé\n"}]}'), fractal_ledger_verify(2);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT fractal_audit_log(NULL, '{}'), fractal_audit_log('x', NULL);

-- unpack grows its buffer through the truncation path, and rejects a bad input and an out-of-range length
-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT length(fractal_audit_unpack('\x01\x02\x03'::BLOB));

-- (the C++ build leaked DuckDB's JSON error envelope into this wrapped message; the C build gives the clean text)
-- expect-c: fractalsql: fractal_audit_unpack: fsql_audit_unpack rc=-1
-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT fractal_audit_unpack('\xFF'::BLOB);

-- expect-c: fractalsql: fractal_audit_unpack: fractalsql: fsql_audit_unpack reported an out-of-range length
-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT fractal_audit_unpack('\xFE'::BLOB);

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT fractal_audit_unpack(NULL::BLOB);

-- the latch with a live enterprise core
-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT fractal_lock_destructive();
SELECT fractal_audit_log('x', '{}');

-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT fractal_lock_destructive();
SELECT fractal_ledger_truth_count();

-- the enterprise library must verify unless the operator opts out
-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- expect: no signature found for enterprise library
SELECT fractal_ledger_truth_count();

-- env: FRACTALSQL_ENTERPRISE_LIB=/nonexistent/lib.so
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT fractal_ledger_truth_count();

-- redaction of the audit text
-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
-- env: FSQL_AUDIT_REDACT=hash
SELECT fractal_audit_log('decision', '{"patient": "Jane Roe", "note": "private"}'), fractal_ledger_verify(2);
