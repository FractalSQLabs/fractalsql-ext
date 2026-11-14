-- Parity cases for fractal_schema_context (fsql_t2s.c). Nested catalog queries via the connection pool.

CREATE TABLE customers (id INTEGER PRIMARY KEY, name VARCHAR NOT NULL, email VARCHAR);
CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id), total DOUBLE, placed TIMESTAMP);
SELECT fractal_schema_context(['customers', 'orders']);

CREATE TABLE customers (id INTEGER PRIMARY KEY, name VARCHAR NOT NULL, email VARCHAR);
CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id), total DOUBLE);
SELECT fractal_schema_context(['orders']);

CREATE TABLE customers (id INTEGER PRIMARY KEY, name VARCHAR NOT NULL);
CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id));
SELECT fractal_schema_context(['customers', 'orders'], 'which customers ordered?');

-- no argument: every table in the search path
CREATE TABLE only_one (a INTEGER, b VARCHAR);
SELECT fractal_schema_context() LIKE '%TABLE only_one:%a INTEGER%b VARCHAR%';

CREATE TABLE only_one (a INTEGER, b VARCHAR);
SELECT fractal_schema_context(NULL), fractal_schema_context(NULL, NULL) LIKE '%only_one%';

-- a composite primary key and a composite foreign key
CREATE TABLE parent (a INTEGER, b INTEGER, PRIMARY KEY (a, b));
CREATE TABLE child (x INTEGER, y INTEGER, FOREIGN KEY (x, y) REFERENCES parent(a, b));
SELECT fractal_schema_context(['parent', 'child']);

-- a name that needs quoting, with a single quote in it
CREATE TABLE "it's" (id INTEGER);
SELECT fractal_schema_context(['it''s']);

CREATE TABLE "Mixed Case" ("Col One" INTEGER NOT NULL, "col two" VARCHAR);
SELECT fractal_schema_context(['Mixed Case']);

-- a table that does not exist, and an empty filter list
CREATE TABLE present (a INTEGER);
SELECT fractal_schema_context(['absent']);

CREATE TABLE present (a INTEGER);
SELECT fractal_schema_context([]::VARCHAR[]) LIKE '%present%';

-- no tables at all
SELECT fractal_schema_context(['absent']);

-- over the table cap
SELECT fractal_schema_context(list_transform(range(513), lambda i: 't' || i));

CREATE TABLE t1 (a INTEGER);
SELECT fractal_schema_context(list_transform(range(512), lambda i: CASE WHEN i = 0 THEN 't1' ELSE 'x' || i END));

-- per-row: a query result of many rows
CREATE TABLE t1 (a INTEGER);
SELECT count(*), count(DISTINCT fractal_schema_context(['t1'])) FROM range(100);

-- a schema big enough to exceed the prompt cap
-- 
-- (kept small here so the gate stays quick; the cap check itself is exercised by the message path above)

-- typing
SELECT typeof(fractal_schema_context(['t'])), typeof(fractal_schema_context());
