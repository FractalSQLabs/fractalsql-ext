-- Parity cases for the reasoning machinery (fsql_reasoning.c) via fractal_reason (fsql_agents.c).
-- The mock plugin returns a fenced SELECT 1 unless the harness's /tmp files say otherwise.

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
SELECT fractal_reason('hello');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
SELECT fractal_reason('hello', '{"k": 1}');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
SELECT fractal_reason('a'), fractal_reason('b'), fractal_reason(NULL), fractal_reason('c', NULL);

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
CREATE TABLE q AS SELECT 'question ' || i AS t FROM range(1, 60) x(i);
SELECT count(*), count(DISTINCT fractal_reason(t)) FROM q;

-- not configured
SELECT fractal_reason('hello');

-- a plugin path that is not absolute / a missing file
-- env: FRACTALSQL_REASONING_PLUGIN=relative/plugin.so
SELECT fractal_reason('hello');

-- env: FRACTALSQL_REASONING_PLUGIN=/nonexistent/plugin.so
SELECT fractal_reason('hello');

-- the product default refuses an unsigned, unpinned plugin
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- env: FSQL_REASONING_ALLOW_UNVERIFIED=
-- expect: no signature found for reasoning plugin
SELECT fractal_reason('hello');

-- The SHA-256 pin was retired with the signature policy: the pin variable is ignored now, and an unsigned plugin is
-- refused whatever it says. (The C++ reference predates that, so these are spec cases, not reference comparisons.)
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- env: FSQL_REASONING_ALLOW_UNVERIFIED=
-- env: FSQL_REASONING_PLUGIN_SHA256=nothex
-- expect: no signature found for reasoning plugin
SELECT fractal_reason('hello');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- env: FSQL_REASONING_ALLOW_UNVERIFIED=
-- env: FSQL_REASONING_PLUGIN_SHA256=0000000000000000000000000000000000000000000000000000000000000000
-- expect: no signature found for reasoning plugin
SELECT fractal_reason('hello');

-- a plugin whose response claims an implausible length is refused before it is read
-- env: FRACTALSQL_REASONING_PLUGIN=${evil_lying_length_plugin}
SELECT fractal_reason('hello');
