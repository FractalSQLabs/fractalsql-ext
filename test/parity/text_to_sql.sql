-- Parity cases for fractal_text_to_sql / fractal_sql_agent. The mock reasoning plugin answers with the
-- canned reply set by "-- file: sql=...".

-- no plugin configured
SELECT fractal_text_to_sql('how many orders');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT id, name FROM customers WHERE id = 1
CREATE TABLE customers (id INTEGER PRIMARY KEY, name VARCHAR);
CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, amount DOUBLE);
SELECT fractal_text_to_sql('give me the customer');
SELECT fractal_text_to_sql('give me the customer', ['customers', 'orders']);
SELECT fractal_text_to_sql('give me the customer', ['no_such_table']);
SELECT fractal_text_to_sql(NULL), fractal_text_to_sql('q', NULL);
SELECT fractal_text_to_sql(repeat('x', 4194305));
SELECT count(*) FROM customers;

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT 1; SELECT 2
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=CREATE TABLE dos (a INTEGER)
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=DELETE FROM orders
CREATE TABLE orders (id INTEGER);
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=INSERT INTO orders VALUES (1)
CREATE TABLE orders (id INTEGER);
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- env: FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update
-- file: sql=INSERT INTO orders VALUES (1)
CREATE TABLE orders (id INTEGER);
SELECT fractal_text_to_sql('q');
SELECT count(*) FROM orders;

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- env: FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update
-- file: sql=UPDATE orders SET id = 2
CREATE TABLE orders (id INTEGER);
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- env: FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update
-- file: sql=DELETE FROM orders
CREATE TABLE orders (id INTEGER);
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=EXPLAIN SELECT 1
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=this is not sql at all ##
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=123 not a keyword
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT no_such_column FROM orders
CREATE TABLE orders (id INTEGER);
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT * FROM table_that_does_not_exist
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELEC 1
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT fractal_ledger_flush()
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT 'fractal_ledger_flush()' AS s
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT fractal_lock_destructive()
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=-- note\nSELECT 1
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=Here is the query you asked for:\n\n```sql\nSELECT 41 + 1\n```\n\nHope that helps.
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=```\nSELECT 7\n```
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=   
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=WITH t AS (SELECT 1 AS a) SELECT a FROM t
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- xver: skip
-- file: sql=WITH d AS (DELETE FROM orders RETURNING *) SELECT * FROM d
CREATE TABLE orders (id INTEGER);
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=WITH x AS (SELECT 1) DELETE FROM orders
CREATE TABLE orders (id INTEGER);
SELECT fractal_text_to_sql('q');

-- the review round (off by default; with no critique file a PASS can never come back)
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- env: FRACTALSQL_TEXT_TO_SQL_USE_REVIEW=on
-- file: sql=SELECT 1
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- env: FRACTALSQL_TEXT_TO_SQL_USE_REVIEW=on
-- file: sql=SELECT 1
-- file: review=PASS looks right
SELECT fractal_text_to_sql('q');

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- env: FRACTALSQL_TEXT_TO_SQL_USE_REVIEW=yes
-- file: sql=SELECT 1
-- file: review=FAIL wrong table
SELECT fractal_text_to_sql('q');

-- fractal_sql_agent
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT count(*) FROM docs
CREATE TABLE docs (id INTEGER, v DOUBLE[]);
INSERT INTO docs VALUES (1, [0.1]), (2, [0.2]);
SELECT generated_sql, execution_status, retry_count, result_json FROM fractal_sql_agent('how many', ['docs'], 3, false);
SELECT generated_sql, execution_status, retry_count, result_json FROM fractal_sql_agent('how many', ['docs'], 3, true);
SELECT execution_status, retry_count FROM fractal_sql_agent('how many', NULL, 1, false);
SELECT * FROM fractal_sql_agent('how many', ['docs'], 0, false);
SELECT * FROM fractal_sql_agent('how many', ['docs'], 21, false);
SELECT * FROM fractal_sql_agent(repeat('x', 4194305), ['docs'], 1, false);

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=DROP TABLE docs
CREATE TABLE docs (id INTEGER);
SELECT generated_sql, execution_status, retry_count, result_json FROM fractal_sql_agent('nuke it', ['docs'], 2, false);
SELECT generated_sql, execution_status, retry_count, result_json FROM fractal_sql_agent('nuke it', ['docs'], 1, true);
SELECT count(*) FROM docs;

-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT 1/0
SELECT generated_sql, execution_status, retry_count FROM fractal_sql_agent('boom', []::VARCHAR[], 1, true);

-- retry: first DROP (rejected), then SELECT 1
-- env: FRACTALSQL_REASONING_PLUGIN=${retry_reasoning_plugin}
SELECT generated_sql, execution_status, retry_count FROM fractal_sql_agent('retry me', []::VARCHAR[], 3, false);

-- env: FRACTALSQL_REASONING_PLUGIN=${retry_reasoning_plugin}
SELECT fractal_text_to_sql('retry me');

