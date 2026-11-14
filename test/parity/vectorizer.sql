-- Parity cases for fractal_embed and the vectorizer family (fsql_vectorizer.c). Mock embed plugin supplies vectors.

-- no plugin / no embed URL
SELECT fractal_embed('hello');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
-- env: FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings
SELECT fractal_embed('hello');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
-- env: FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings
SELECT fractal_embed(NULL), fractal_embed(''), len(fractal_embed('x'));

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
-- env: FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings
SELECT typeof(fractal_embed('a')), count(fractal_embed('r' || i)) FROM range(100) t(i);

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
-- env: FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings
SELECT fractal_embed(repeat('x', 4194305));

-- plugin loaded but no embed URL
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
SELECT fractal_embed('hello');

-- plugin returns something that is not an array
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- env: FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings
SELECT fractal_embed('hello');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
-- env: FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings
SELECT fractal_embed('hello') FROM (SELECT 1) WHERE false;

-- vectorizer lifecycle
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
-- env: FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings
CREATE TABLE docs (id INTEGER PRIMARY KEY, body VARCHAR, emb DOUBLE[]);
INSERT INTO docs VALUES (1, 'alpha', NULL), (2, 'beta', NULL), (3, NULL, NULL);
SELECT fractal_vectorizer_create('docs', 'id', 'body', 'emb');
SELECT * FROM fractal_vectorizer_status();
SELECT fractal_vectorizer_process_queue();
SELECT id, len(emb) FROM docs ORDER BY id;
SELECT * FROM fractal_vectorizer_status();
INSERT INTO docs VALUES (4, 'gamma', NULL);
SELECT fractal_vectorizer_process_queue();
SELECT * FROM fractal_vectorizer_status();
SELECT fractal_vectorizer_pause(1);
INSERT INTO docs VALUES (5, 'delta', NULL);
SELECT fractal_vectorizer_process_queue();
SELECT * FROM fractal_vectorizer_status();
SELECT fractal_vectorizer_resume(1);
SELECT fractal_vectorizer_process_queue(10, 60);
SELECT * FROM fractal_vectorizer_status();
SELECT count(*) FROM docs WHERE emb IS NOT NULL;
SELECT fractal_vectorizer_drop(1);
SELECT * FROM fractal_vectorizer_status();

-- 3-arg form detects the primary key; schema-qualified table; options
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
-- env: FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings
CREATE TABLE t1 (k INTEGER PRIMARY KEY, txt VARCHAR, v DOUBLE[]);
INSERT INTO t1 VALUES (1, 'a', NULL), (2, 'b', NULL), (3, 'c', NULL);
SELECT fractal_vectorizer_create('main.t1', 'txt', 'v');
SELECT fractal_vectorizer_process_queue(2);
SELECT * FROM fractal_vectorizer_status();
SELECT fractal_vectorizer_process_queue();
SELECT * FROM fractal_vectorizer_status();

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
-- env: FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings
CREATE TABLE t2 (k INTEGER PRIMARY KEY, txt VARCHAR, v DOUBLE[]);
INSERT INTO t2 SELECT i, 'row' || i, NULL FROM range(6) r(i);
SELECT fractal_vectorizer_create('t2', 'k', 'txt', 'v', '{"max_embeds_per_window": 2, "window_secs": 3600}');
SELECT fractal_vectorizer_process_queue();
SELECT * FROM fractal_vectorizer_status();
SELECT count(*) FROM t2 WHERE v IS NOT NULL;
SELECT fractal_vectorizer_process_queue();
SELECT count(*) FROM t2 WHERE v IS NOT NULL;

-- options validation
CREATE TABLE o1 (k INTEGER PRIMARY KEY, txt VARCHAR, v DOUBLE[]);
SELECT fractal_vectorizer_create('o1', 'k', 'txt', 'v', '[1]');
SELECT fractal_vectorizer_create('o1', 'k', 'txt', 'v', '{"bogus": 1}');
SELECT fractal_vectorizer_create('o1', 'k', 'txt', 'v', '{"window_secs": 0}');
SELECT fractal_vectorizer_create('o1', 'k', 'txt', 'v', '{"max_embeds_per_window": -1}');
SELECT fractal_vectorizer_create('o1', 'k', 'txt', 'v', '{"max_embeds_per_window": 1.5}');
SELECT fractal_vectorizer_create('o1', 'k', 'txt', 'v', '{"max_embeds_per_window": "x"}');
SELECT fractal_vectorizer_create('o1', 'k', 'txt', 'v', '{"window_secs": 5');
SELECT fractal_vectorizer_create('o1', 'k', 'txt', 'v', '{"window_secs": 5,}');
SELECT fractal_vectorizer_create('o1', 'k', 'txt', 'v', '{"window_secs": 5} x');
SELECT fractal_vectorizer_create('o1', 'k', 'txt', 'v', '');
SELECT fractal_vectorizer_create('o1', 'k', 'txt', 'v', NULL);

-- identifier validation
CREATE TABLE i1 (k INTEGER PRIMARY KEY, txt VARCHAR, v DOUBLE[]);
SELECT fractal_vectorizer_create('i1; DROP TABLE i1', 'k', 'txt', 'v');
SELECT fractal_vectorizer_create('i1', 'k', 'tx t', 'v');
SELECT fractal_vectorizer_create('i1', 'k', 'txt', 'a.b');
SELECT fractal_vectorizer_create('a.b.c', 'k', 'txt', 'v');
SELECT fractal_vectorizer_create('1abc', 'k', 'txt', 'v');
SELECT fractal_vectorizer_create('i1', 'k', 'txt', '');
SELECT fractal_vectorizer_create('', 'k', 'txt', 'v');
SELECT fractal_vectorizer_create('i1', 'k', 'txt', repeat('a', 64));
SELECT fractal_vectorizer_create('i1', 'k"', 'txt', 'v');
SELECT fractal_vectorizer_create(NULL, 'k', 'txt', 'v');
SELECT fractal_vectorizer_create('i1', 'k', 'txt', 'v') FROM range(0);

-- missing table / PK detection failures / duplicates
SELECT fractal_vectorizer_create('no_such_table', 'k', 'txt', 'v');
CREATE TABLE nopk (a INTEGER, txt VARCHAR, v DOUBLE[]);
SELECT fractal_vectorizer_create('nopk', 'txt', 'v');
CREATE TABLE cpk (a INTEGER, b INTEGER, txt VARCHAR, v DOUBLE[], PRIMARY KEY (a, b));
SELECT fractal_vectorizer_create('cpk', 'txt', 'v');
CREATE TABLE d1 (k INTEGER PRIMARY KEY, txt VARCHAR, v DOUBLE[]);
SELECT fractal_vectorizer_create('d1', 'k', 'txt', 'v');
SELECT fractal_vectorizer_create('d1', 'k', 'txt', 'v');
SELECT fractal_vectorizer_create('d1', 'txt', 'v');

-- unknown ids
SELECT fractal_vectorizer_drop(999);
SELECT fractal_vectorizer_pause(999);
SELECT fractal_vectorizer_resume(999);
SELECT fractal_vectorizer_drop(NULL), fractal_vectorizer_pause(NULL), fractal_vectorizer_resume(NULL);

-- process_queue bounds
SELECT fractal_vectorizer_process_queue(0);
SELECT fractal_vectorizer_process_queue(100001);
SELECT fractal_vectorizer_process_queue(1, 0);
SELECT fractal_vectorizer_process_queue(-5, 10);
SELECT fractal_vectorizer_process_queue(NULL);
SELECT fractal_vectorizer_process_queue(5, 5);

-- no plugin: the row is marked failed, the call still reports it processed
CREATE TABLE np (k INTEGER PRIMARY KEY, txt VARCHAR, v DOUBLE[]);
INSERT INTO np VALUES (1, 'x', NULL);
SELECT fractal_vectorizer_create('np', 'k', 'txt', 'v');
SELECT fractal_vectorizer_process_queue();
SELECT * FROM fractal_vectorizer_status();

-- status with nothing configured, typing
SELECT * FROM fractal_vectorizer_status();
SELECT typeof(fractal_vectorizer_create('x','y','z')) FROM range(0);
DESCRIBE SELECT * FROM fractal_vectorizer_status();
