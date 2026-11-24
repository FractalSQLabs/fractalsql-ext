-- demo/demo-business-intelligence.sql
--
-- A business-intelligence walkthrough, not just a text-to-sql
-- walkthrough: ask a plain-English business question, generate SQL,
-- EXECUTE it, and feed the real result back into fractal_reason() for
-- a narrative answer -- the loop demo-text-to-sql.sql deliberately
-- stops short of (execution is always a separate, explicit, caller-
-- side step -- see ../docs/text-to-sql-setup.md). Also covers the
-- other half of the product: Sniper Search to define a target
-- customer archetype, and Scout Discovery to find and name real
-- customer segments -- general data reasoning, not single-query
-- translation.
--
-- The synthetic data below has real patterns baked into it on
-- purpose (a revenue dip, five RFM-style customer segments) so the
-- reasoning sections below have something genuine to discover, not
-- just a number to restate -- same trick demo.sql's alert table uses.
--
-- Prerequisites: extension installed, reasoning configured -- see
-- ../docs/reasoning-setup.md and confirm with:
--   SELECT fractal_reason('reply with a short confirmation that this connection works');
-- before running this script.
--
-- API surface notes:
--   * DuckDB has no procedural SQL at all (no exception handling, no
--     user-defined function bodies beyond CREATE MACRO's single
--     expression), so generation results land in a TEMP staging table
--     instead of a safe-wrapper function: on the
--     retry-budget-exhausted path (a real, expected outcome for a
--     weaker model or an ambiguous question -- it raises, aborting
--     that statement), the staging INSERT fails with the clean error
--     and the staging table simply stays empty; every later step
--     reads the staging table and spools empty, i.e. no-ops, instead
--     of cascading into later steps. Run this demo WITHOUT -bail so
--     that survivable path is actually survivable:
--       { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; \
--         cat demo/demo-business-intelligence.sql; } | duckdb -unsigned
--   * The generated SQL is executed with the CLI's .once/.read spool
--     trick. Spool files land in the current directory, overwritten
--     each run. (Timing is omitted -- none in-demo;
--     measure latency at the harness level, e.g.
--     demo/demo-workload.sh.)
--   * fractal_sfs_converge(query, iterations) is the abstract-space Sniper
--     form (raw SFS over the [-1,1] box, returning the ideal point);
--     fractal_sfs_converge_debug(query, iterations, population_size,
--     diffusion_factor) is its diagnostic sibling, returning a
--     VARCHAR debug report instead of the point.
--   * Scout Discovery is the fractal_search_explore TABLE function
--     over a stored column -- returning the particles as rows.
--
-- Safe to re-run: the schema is dropped and recreated at the top.

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Schema + seed data. 18 months of orders across 60 customers,
-- with two patterns deliberately built in:
--   - a real revenue dip 4 months back (a supply issue, say) --
--     something for Section 3 to find.
--   - five RFM (recency/frequency/monetary) customer archetypes,
--     spread across SFS's [-1,1] operating box with enough margin
--     that Scout can actually tell them apart -- see benchmark.sql's
--     own comment on why narrow clustering silently understates
--     Scout's real result.
-- ------------------------------------------------------------------
.print
.print === 1. Schema + 18 months of order history, 60 customers ===

DROP TABLE IF EXISTS bi_customer_features;
DROP TABLE IF EXISTS bi_orders;
DROP TABLE IF EXISTS bi_customers;

DROP SEQUENCE IF EXISTS seq_bi_customers_id;
CREATE SEQUENCE seq_bi_customers_id;
CREATE TABLE bi_customers (
    id       INTEGER PRIMARY KEY DEFAULT nextval('seq_bi_customers_id'),
    name     text NOT NULL,
    segment  text NOT NULL,   -- ground truth, for narrating results below -- not fed to Scout/Sniper
    status   text NOT NULL DEFAULT 'active'
);
COMMENT ON TABLE bi_customers IS 'Customers, with a ground-truth RFM segment label for narrating results below';

DROP SEQUENCE IF EXISTS seq_bi_orders_id;
CREATE SEQUENCE seq_bi_orders_id;
CREATE TABLE bi_orders (
    id            INTEGER PRIMARY KEY DEFAULT nextval('seq_bi_orders_id'),
    customer_id   int NOT NULL REFERENCES bi_customers(id),
    total_cents   int NOT NULL,
    placed_at     timestamptz NOT NULL
);
COMMENT ON TABLE bi_orders IS 'Order history; total_cents is order value in cents';

-- Five RFM archetypes: (recency, frequency, monetary), each roughly
-- in [-0.8, 0.8] -- comfortably inside the [-1,1] box with margin for
-- per-customer noise. -1 recency = very recent/good; +1 frequency/
-- monetary = high/good (recency is inverted: -1 is the "good" end).
CREATE TEMP TABLE bi_archetypes (segment text PRIMARY KEY, r double, f double, m double, n_customers int);
INSERT INTO bi_archetypes (segment, r, f, m, n_customers) VALUES
    ('Champions',        -0.7,  0.7,  0.7, 14),
    ('At-Risk',           0.6,  0.5,  0.6, 10),
    ('New & Exploring',  -0.6, -0.6, -0.5, 12),
    ('Lost',               0.7, -0.7, -0.6, 14),
    ('Loyal & Modest',   -0.3,  0.4, -0.2, 10);

-- The fixture generator: a two-round LCG over pure integer arithmetic,
-- so every draw is exactly the same everywhere.
--
-- random() would not do: setseed() seeds only the engine of the thread
-- that called it, and every other DuckDB worker thread runs its own
-- random() stream, so a fixture query DuckDB spreads over several
-- threads hands each row a value from a different stream -- and the
-- customer features, the order amounts and (worse) the ORDER COUNTS
-- came out different on a different machine. The LCG is a pure function
-- of the row id, so every fixture below is the same on every machine,
-- core count and DuckDB build.
--
-- The bare row_number() OVER () would not do either: it numbers rows in
-- whatever order the scan produced them, so which customer got which
-- name moved with the core count. Ordering it by (segment, n) pins the
-- numbering -- and the id, which the sequence hands out in insert order.
-- The xor-shift rounds are not decoration: a plain LCG is AFFINE in its
-- seed, so two seeds one apart differ by a CONSTANT amount -- the three
-- RFM dimensions of one customer came out mirror images of each other
-- instead of independent draws. The xor-shift breaks that affinity.
CREATE OR REPLACE MACRO bi_lcg(s) AS ((((s::BIGINT * 1103515245::BIGINT) + 12345) % 2147483648));
CREATE OR REPLACE MACRO bi_xs(a, sh) AS (xor(a, a >> sh));
CREATE OR REPLACE MACRO bi_mix(s) AS (bi_xs(bi_lcg(bi_xs(bi_lcg(s), 13)), 17));
CREATE OR REPLACE MACRO bi_rand(s) AS (bi_mix(s)::DOUBLE / 2147483648.0);

INSERT INTO bi_customers (name, segment)
SELECT 'customer_' || row_number() OVER (ORDER BY a.segment, g.n), a.segment
FROM bi_archetypes a
CROSS JOIN LATERAL generate_series(1, a.n_customers) g(n)
ORDER BY a.segment, g.n;

CREATE TABLE bi_customer_features (customer_id int PRIMARY KEY REFERENCES bi_customers(id), feature_vec double[]);
INSERT INTO bi_customer_features (customer_id, feature_vec)
SELECT c.id, array_agg(v.val ORDER BY v.dim_idx)
FROM bi_customers c
JOIN bi_archetypes a ON a.segment = c.segment
CROSS JOIN LATERAL (VALUES
    (1, a.r + (bi_rand(c.id * 10 + 1) - 0.5) * 0.15),
    (2, a.f + (bi_rand(c.id * 10 + 2) - 0.5) * 0.15),
    (3, a.m + (bi_rand(c.id * 10 + 3) - 0.5) * 0.15)
) AS v(dim_idx, val)
GROUP BY c.id
ORDER BY c.id;

-- Order history: order count/value roughly follows each customer's
-- own frequency/monetary features, so the two tables tell a
-- consistent story. Month 4 (of 18, counting back from today) gets a
-- deliberate ~40% revenue dip across every segment -- 4 months back
-- comfortably inside any "last 6 months" trend question regardless of
-- what today's actual date is when this script runs, unlike a fixed
-- calendar month would be.
INSERT INTO bi_orders (customer_id, total_cents, placed_at)
SELECT c.id,
       CAST((3000 + (bi_rand(c.id * 1000 + mo.month_offset * 10 + 1) * 12000))
              * CASE WHEN mo.month_offset = 4 THEN 0.6 ELSE 1.0 END AS INTEGER),
       now() - (mo.month_offset || ' months')::interval
              + (bi_rand(c.id * 1000 + mo.month_offset * 10 + 2) * interval '25 days')
FROM bi_customers c
JOIN bi_customer_features f ON f.customer_id = c.id
CROSS JOIN LATERAL generate_series(1, 18) AS mo(month_offset)
-- order count per customer per month scales with their frequency
-- feature (f.feature_vec[2]): high-frequency customers order most
-- months, low-frequency customers order occasionally.
WHERE bi_rand(c.id * 1000 + mo.month_offset * 10 + 3) < (0.15 + 0.5 * ((f.feature_vec[2] + 1) / 2))
ORDER BY c.id, mo.month_offset;

.print
.print Seed data:
SELECT (SELECT count(*) FROM bi_customers) AS customers,
       (SELECT count(*) FROM bi_orders) AS orders,
       (SELECT round(sum(total_cents) / 100.0, 2) FROM bi_orders) AS total_revenue;

-- ------------------------------------------------------------------
-- 2. Simple fact lookup: generate -> execute -> show the raw result.
-- No reasoning yet -- this section is the loop's first half only, to
-- show what "generate then execute" looks like plainly before adding
-- interpretation on top of it in Section 3.
-- ------------------------------------------------------------------
.print
.print === 2. Simple fact lookup: generate, then execute ===

DROP TABLE IF EXISTS bi_gen;
CREATE TEMP TABLE bi_gen (sql_text TEXT);
-- On generation failure this INSERT is the one thing that errors
-- (with the clean reason/limit message) and bi_gen stays empty --
-- every step after reads an empty staging table and spools a no-op.
INSERT INTO bi_gen (sql_text)
SELECT fractal_text_to_sql(
    'how many customers do we have and what is our total revenue?',
    ['bi_customers', 'bi_orders']);

.print Generated:
SELECT sql_text AS generated_sql FROM bi_gen;
.print

.mode list
.headers off
.output bi_generated.sql
SELECT sql_text FROM bi_gen;
.output stdout
.read bi_generated.sql

.print
.print Worth noticing: if the customer count above is lower than the 60
.print from the seed summary in Section 1, the model chose an INNER JOIN
.print between customers and orders -- quietly narrowing the question
.print from ALL customers to CUSTOMERS WITH ORDERS. Not wrong, exactly,
.print but a real example of why fractal_text_to_sql() never
.print auto-executes: the SQL is always worth reading, not just
.print trusting the English question implies.

-- ------------------------------------------------------------------
-- 3. The full BI loop: generate -> execute -> reason over the REAL
-- result. This is the part demo-text-to-sql.sql deliberately never
-- does. The question is designed to surface the month-4 dip baked
-- into the data above -- fractal_reason() sees the actual monthly
-- numbers, not a hint that a dip exists. Explicitly excluding the
-- current (in-progress) month, not just "last 6 months" -- otherwise
-- whatever partial month is running when this script executes always
-- looks like a fake dip, which would be a real and common BI
-- reporting mistake to bake into a demo unremarked.
-- ------------------------------------------------------------------
.print
.print === 3. The full loop: generate, execute, then reason over the real result ===

DROP TABLE IF EXISTS bi_gen;
CREATE TEMP TABLE bi_gen (sql_text TEXT);
INSERT INTO bi_gen (sql_text)
SELECT fractal_text_to_sql(
    'show total revenue for each of the 6 most recent FULLY COMPLETED calendar months, excluding the current in-progress month, oldest first',
    ['bi_orders']);

.print Generated:
SELECT sql_text AS trend_sql FROM bi_gen;

-- Result materialized by spooling the candidate wrapped in
-- DROP/CREATE TEMP TABLE AS (no dynamic SQL in the CLI; empty
-- staging -> empty spool -> no-op .read -> bi_trend_result stays the
-- empty placeholder below, so Section 4 keeps a defined shape). The
-- placeholder is created BEFORE the spool read, and the spooled
-- statement drops and re-creates it. The .mode/.headers toggles put a
-- bare SQL line in the spool file -- DuckDB CLI's default box
-- rendering is display-only, not re-readable.
CREATE TEMP TABLE bi_trend_result (month timestamptz, total_revenue numeric);

.mode list
.headers off
.output bi_trend.sql
SELECT 'DROP TABLE IF EXISTS bi_trend_result; CREATE TEMP TABLE bi_trend_result AS ' || sql_text || ';'
  FROM bi_gen;
.output stdout
.headers on
.mode box
.read bi_trend.sql

.print
.print Executed -- real result:
SELECT * FROM bi_trend_result;

.print
.print Reasoning over the actual result (not the question, the DATA):
SELECT fractal_reason(
    'this is our last 6 months of revenue by month -- what happened, and does it need attention?',
    (SELECT list(t)::text FROM bi_trend_result t)
);

-- ------------------------------------------------------------------
-- 4. General data reasoning: synthesize across SEVERAL facts in one
-- call, not translate one question into one query. This is the
-- capability text-to-sql alone can't offer -- a single SQL statement
-- can't hold "here's the trend AND the segment mix AND the churn
-- signal, now tell me what's really going on."
-- ------------------------------------------------------------------
.print
.print === 4. General reasoning: synthesize multiple facts into one narrative ===

-- No JSON extension loaded -- struct_pack(...) builds the labeled
-- context fields and list(t) serializes each row as a STRUCT.
-- fractal_reason's context argument is free-form prompt text, not
-- something parsed back out, so DuckDB's own struct/list text
-- rendering is sufficient here (same reasoning as demo.sql's Section 3).
SELECT fractal_reason(
    'given revenue trend, customer segment mix, and status breakdown together, what is the state of the business and what would you look into first?',
    struct_pack(
        monthly_revenue := (SELECT list(t) FROM bi_trend_result t),
        segment_mix := (SELECT list(s) FROM (
            SELECT segment, count(*) AS customers FROM bi_customers GROUP BY segment ORDER BY segment
        ) s),
        status_breakdown := (SELECT list(u) FROM (
            SELECT status, count(*) AS customers FROM bi_customers GROUP BY status
        ) u)
    )::text
);

-- ------------------------------------------------------------------
-- 5. Sniper Search: converge toward a TARGET customer archetype.
-- Not a lookup against real customers -- SFS refines toward the
-- mathematically ideal point matching the query direction, useful for
-- "what would our best-possible customer profile look like" before
-- you go find (or build toward) one.
-- ------------------------------------------------------------------
.print
.print === 5. Sniper Search: converge toward an ideal-customer profile ===
.print Query: recent + frequent + high-value (a "Champions"-shaped target)

-- Positional only (no `name => value` syntax in DuckDB scalar functions).
SELECT fractal_sfs_converge(ARRAY[-0.7, 0.7, 0.7]::float8[], 50) AS ideal_profile;

.print
.print Notice the ratio between components matches the query direction,
.print but the exact magnitude varies run to run (sometimes near the
.print [-1,1] box edges, sometimes a scaled-down interior point) -- cosine
.print similarity (what Sniper optimizes for) is scale-invariant, so
.print every point along the same ray as the query scores identically.
.print SFS has no pressure to pick one particular point on that ray over
.print another, only to find the right ray. Read this as a DIRECTION to
.print aim for, not a literal target coordinate.

-- ------------------------------------------------------------------
-- 6. Scout Discovery: find real, DIVERSE customer segments from the
-- actual stored feature vectors -- then have fractal_reason() name
-- them in business language. This is the same anti-mode-collapse
-- property benchmark.sql measures numerically, applied to an actual
-- business question: "what kinds of customers do we actually have?"
-- ------------------------------------------------------------------
.print
.print === 6. Scout Discovery: find and name real customer segments ===

DROP TABLE IF EXISTS bi_scout_result;
CREATE TEMP TABLE bi_scout_result AS
SELECT row_number() OVER () AS particle_id, particle AS feature_vec
FROM fractal_search_explore(
    'bi_customer_features', 'feature_vec', [0.2, 0.2, 0.2]::float8[],
    '{"population_size": 8, "iterations": 10, "walk": 0}'
);
-- (The explore query is a small nonzero point, NOT the origin -- cosine
-- is undefined for a zero vector, the same adversarial case
-- benchmark.sql's comment documents.)

.print Scout found a diverse population (recency, frequency, monetary):
.print the particles concentrate near the most query-relevant archetypes
.print and throw the odd outlier -- the same population the naming step
.print below turns into business language.
SELECT * FROM bi_scout_result;

.print
.print Naming the segments Scout actually found, in business language:
SELECT fractal_reason(
    'each item is a (recency, frequency, monetary) customer profile in [-1,1], where recency -1 is very recent, frequency/monetary +1 is high. Name and describe each distinct segment in one line.',
    (SELECT list(feature_vec)::text FROM bi_scout_result)
);

.print
.print ================================================================
.print Demo complete. Tables left in place for inspection. Clean up with:
.print   DROP TABLE bi_customer_features, bi_orders, bi_customers;
.print (the bi_* TEMP tables and the bi_generated.sql / bi_trend.sql
.print spool files evaporate with the connection / live in the current
.print directory, overwritten each run.)
.print ================================================================