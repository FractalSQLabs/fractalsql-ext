-- Expectation cases for fractal_config_get / fractal_config_set (fsql_config.c). The C++ reference binary
-- predates these two functions, so they are checked against the documented behaviour of the
-- C++ source (fractalsql_extension_config.cpp) instead of differentially.

-- expect: gpt-test
-- env: FSQL_REASONING_HTTP_MODEL=gpt-test
SELECT fractal_config_get('http_model');

-- the environment variable's own name is accepted as a spelling of the key
-- expect: gpt-test
-- env: FSQL_REASONING_HTTP_MODEL=gpt-test
SELECT fractal_config_get('FSQL_REASONING_HTTP_MODEL');

-- not configured -> NULL
-- expect: NULL
-- env: FSQL_REASONING_HTTP_MODEL=
SELECT fractal_config_get('http_model');

-- set then get in one session
-- expect: true
SELECT fractal_config_set('http_model', 'abc');

-- expect: abc
SELECT fractal_config_set('http_model', 'abc'), fractal_config_get('http_model');

-- the operator's chat-scope copy follows a set
-- expect: https://example.invalid/v1
SELECT fractal_config_set('http_url', 'https://example.invalid/v1');
SELECT fractal_config_get('http_url');

-- an empty value clears the setting
-- expect: NULL
-- env: FSQL_REASONING_HTTP_MODEL=before
SELECT fractal_config_set('http_model', '');
SELECT fractal_config_get('http_model');

-- the non-chat keys are read from the environment as written
-- expect: /opt/enterprise.so
SELECT fractal_config_set('enterprise_lib', '/opt/enterprise.so');
SELECT fractal_config_get('enterprise_lib');

-- expect: /opt/p.so
SELECT fractal_config_set('reasoning_plugin', '/opt/p.so');
SELECT fractal_config_get('reasoning_plugin');

-- an unknown key is refused, and the refusal lists the documented keys
-- expect: unknown config key 'nope': the documented keys are reasoning_plugin, http_url, http_model
SELECT fractal_config_get('nope');

-- expect: unknown config key 'nope'
SELECT fractal_config_set('nope', 'x');

-- a secret can be set but never read back
-- expect: 'http_token' is a secret and is never read back
SELECT fractal_config_get('http_token');

-- expect: 'FSQL_REASONING_HTTP_TOKEN' is a secret and is never read back
SELECT fractal_config_get('FSQL_REASONING_HTTP_TOKEN');

-- expect: true
SELECT fractal_config_set('http_token', 'sekret');

-- a set secret is still never read back
-- expect: is a secret and is never read back
SELECT fractal_config_set('http_token', 'sekret');
SELECT fractal_config_get('http_token');

-- NULL propagates
-- expect: NULL
SELECT fractal_config_get(NULL), fractal_config_set(NULL, 'x'), fractal_config_set('http_model', NULL);

-- many rows: every row is answered
-- expect: 3000
-- env: FSQL_REASONING_HTTP_MODEL=m
SELECT count(fractal_config_get('http_model')) FROM range(3000);

-- a plugin configured through fractal_config_set is the one fractal_reason loads
-- expect: SELECT 1
-- env: FSQL_REASONING_ALLOW_UNVERIFIED=1
SELECT fractal_config_set('reasoning_plugin', '${mock_reasoning_plugin}');
SELECT fractal_reason('hi');

-- every documented key can be set and read back (the chat-scope ones through the operator's copy)
-- expect: on
SELECT fractal_config_set('http_think', 'on');
SELECT fractal_config_get('http_think');

-- expect: openai
SELECT fractal_config_set('http_think_provider', 'openai');
SELECT fractal_config_get('http_think_provider');

-- expect: http://localhost:11434/api/chat
SELECT fractal_config_set('http_native_url', 'http://localhost:11434/api/chat');
SELECT fractal_config_get('http_native_url');

-- expect: 8192
SELECT fractal_config_set('http_num_ctx', '8192');
SELECT fractal_config_get('http_num_ctx');

-- expect: code
SELECT fractal_config_set('http_response_mode', 'code');
SELECT fractal_config_get('http_response_mode');

-- expect: https://embed.invalid/v1/embeddings
SELECT fractal_config_set('http_embed_url', 'https://embed.invalid/v1/embeddings');
SELECT fractal_config_get('http_embed_url');

-- expect: embed-model
SELECT fractal_config_set('http_embed_model', 'embed-model');
SELECT fractal_config_get('http_embed_model');

-- expect: /opt/reasoning.so
SELECT fractal_config_set('reasoning_plugin', '/opt/reasoning.so');
SELECT fractal_config_get('reasoning_plugin');

-- the credential can be set, never read back
-- expect: is a secret
SELECT fractal_config_set('http_token', 'sk-test');
SELECT fractal_config_get('http_token');

-- an unknown key is refused with the list of documented ones
-- expect: unknown config key
SELECT fractal_config_get('no_such_key');

-- expect: unknown config key
SELECT fractal_config_set('no_such_key', 'x');

-- NULL key or value passes through as NULL
-- expect: NULL
SELECT fractal_config_set(NULL, 'x');

-- expect: NULL
SELECT fractal_config_set('http_model', NULL);

-- expect: NULL
SELECT fractal_config_get(NULL);

