-- demo/demo-text-to-sql.sql
-- Runnable walkthrough of fractal_text_to_sql(), against a richer
-- schema with real foreign keys -- distinct from
-- demo/text-to-sql-spike-*.sql, a step-by-step manual walkthrough
-- of the stages (single table, no FKs, driving fractal_reason()
-- directly). See
-- ../docs/text-to-sql-setup.md for the full pipeline explanation, the
-- FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS env var, and the security
-- model.
--
-- Prerequisites: extension loaded, reasoning configured -- see
-- ../docs/reasoning-setup.md and confirm with:
--   SELECT fractal_reason('reply with a short confirmation that this connection works');
-- before running this script.
--
-- Safe to re-run: the schema is dropped and recreated at the top.
-- Without a reasoning endpoint configured, the first
-- fractal_text_to_sql()/fractal_sql_agent call is the intended first
-- failure -- its error is the
-- clean "reasoning plugin not configured" hint, so run the file
-- WITHOUT -bail and the shell carries on past it.
--
-- (Timing is omitted -- DuckDB's CLI has no per-statement
-- timing dot-command; measure latency at the harness level, e.g.
-- demo/demo-workload.sh. Encoding needs no setting -- DuckDB is
-- always UTF8 internally.)

DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;
DROP SEQUENCE IF EXISTS seq_customers_id;
DROP SEQUENCE IF EXISTS seq_orders_id;
DROP SEQUENCE IF EXISTS seq_order_items_id;

CREATE SEQUENCE seq_customers_id;
CREATE TABLE customers (
    id      INTEGER PRIMARY KEY DEFAULT nextval('seq_customers_id'),
    name    text NOT NULL,
    status  text NOT NULL DEFAULT 'active'
);
COMMENT ON TABLE customers IS 'People or companies who place orders';
COMMENT ON COLUMN customers.status IS 'one of: active, churned';

CREATE SEQUENCE seq_orders_id;
CREATE TABLE orders (
    id          INTEGER PRIMARY KEY DEFAULT nextval('seq_orders_id'),
    customer_id int NOT NULL REFERENCES customers(id),
    placed_at   timestamptz NOT NULL DEFAULT now(),
    status      text NOT NULL DEFAULT 'pending'
);
COMMENT ON COLUMN orders.status IS 'one of: pending, paid, refunded, cancelled';

CREATE SEQUENCE seq_order_items_id;
CREATE TABLE order_items (
    id          INTEGER PRIMARY KEY DEFAULT nextval('seq_order_items_id'),
    order_id    int NOT NULL REFERENCES orders(id),
    sku         text NOT NULL,
    quantity    int NOT NULL,
    unit_cents  int NOT NULL
);
COMMENT ON TABLE order_items IS 'Line items within an order; total = quantity * unit_cents';

INSERT INTO customers (name, status) VALUES
    ('acme',       'active'),
    ('globex',     'active'),
    ('initech',    'churned');

INSERT INTO orders (customer_id, status) VALUES
    (1, 'paid'), (1, 'paid'), (1, 'refunded'),
    (2, 'paid'),
    (3, 'cancelled');

INSERT INTO order_items (order_id, sku, quantity, unit_cents) VALUES
    (1, 'widget-a', 3, 500),
    (1, 'widget-b', 1, 1200),
    (2, 'widget-a', 2, 500),
    (3, 'widget-c', 1, 4000),
    (4, 'widget-b', 5, 1200);

.print === Section 1: schema context (what GENERATE actually sees) ===
SELECT fractal_schema_context(ARRAY['customers', 'orders', 'order_items']);

.print
.print === Section 2: a simple single-table question ===
SELECT fractal_text_to_sql(
    'How many customers have status active?',
    ARRAY['customers']
);

.print
.print === Section 3: a question requiring a join across the FK chain ===
SELECT fractal_text_to_sql(
    'List the names of customers who have at least one paid order, '
    'with how many paid orders each has.',
    ARRAY['customers', 'orders']
);

.print
.print === Section 4: a question requiring all three tables ===
SELECT fractal_text_to_sql(
    'For each customer, what is the total value in cents of their paid orders '
    '(quantity times unit price, summed across all line items)?',
    ARRAY['customers', 'orders', 'order_items']
);

.print
.print === Section 5: generate and execute in one call ===
.print fractal_text_to_sql() never executes what it generates -- that is
.print always a separate, explicit step. There is no client-side
.print variable-capture mechanism in this CLI, so piping a generated
.print statement into execution needs
.print either a host language (Python/Node/R) or the in-database
.print alternative below: fractal_sql_agent's auto_execute argument runs
.print the exact same GENERATE -> ALLOWLIST -> EXPLAIN pipeline and then
.print executes the validated statement itself, returning the SQL, a
.print status, the retry count, and the execution result together.
SELECT * FROM fractal_sql_agent(
    'What is the average number of line items per order?',
    ARRAY['orders', 'order_items'],
    3,
    true
);

.print
.print ================================================================
.print Next: docs/text-to-sql-setup.md for the security model, the
.print execution-role grant pattern (do not run generated SQL with an
.print unrestricted connection in production), and how to validate
.print against your own local models.
.print
.print Clean up: DROP TABLE order_items, orders, customers;
.print ================================================================
