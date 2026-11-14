-- Closing a database that has the extension loaded (fsql_duck.c, fsql_config.c): fractal_release() and
-- FRACTALSQL_NESTED_QUERIES. The file-level behaviour (descriptors, WAL, reopen) is checked by
-- test/lifecycle_test.c; these cases pin the SQL surface.

-- expect: true
SELECT fractal_release();

-- expect: true
SELECT fractal_release(), fractal_release();

-- the nested-query functions say so after a release, and the pool-free ones keep working
-- expect: nested queries were released by fractal_release()
SELECT fractal_release();
SELECT fractal_schema_context();

-- expect: 2.0.0
SELECT fractal_release();
SELECT fractal_version();

-- expect: fractal_search_debug
SELECT fractal_release();
SELECT count(*) > 0 AS ok, 'fractal_search_debug' FROM (SELECT fractal_search_debug([0.1, 0.2, 0.3]::DOUBLE[], 5, 10, 2));

-- a function that runs SQL on the caller's database reports that nested queries are off
-- env: FRACTALSQL_NESTED_QUERIES=off
-- expect: nested queries are off
SELECT fractal_schema_context();

-- env: FRACTALSQL_NESTED_QUERIES=off
-- expect: nested queries are off
SELECT * FROM fractal_search_telemetry('docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], 3);

-- off: everything that needs no nested query still works
-- env: FRACTALSQL_NESTED_QUERIES=off
-- expect: 2.0.0
SELECT fractal_version();

-- env: FRACTALSQL_NESTED_QUERIES=off
-- expect: true
SELECT fractal_release();

-- the other spellings of off
-- env: FRACTALSQL_NESTED_QUERIES=0
-- expect: nested queries are off
SELECT fractal_schema_context();

-- an unrecognised value leaves nested queries on
-- env: FRACTALSQL_NESTED_QUERIES=maybe
-- expect: TABLE
CREATE TABLE t (i INTEGER);
SELECT fractal_schema_context();

-- the destructive latch does not refuse a release: it refuses the destructive ledger actions, and a latched database still has to be
-- releasable (the host-departure monitor's release must not race the host's own teardown)
-- expect: true
SELECT fractal_lock_destructive();
SELECT fractal_release();
