-- SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
-- The world the MCP smoke test searches. Loaded once at server start-up (FSQL_DUCKDB_BOOTSTRAP), before the lock-down.
-- 40 documents in four clusters of 4-D vectors, a metric series per host, a fleet table and a strategy table.
CREATE TABLE docs AS
SELECT i AS id, 'document ' || i AS body, 'topic ' || (i % 4) AS topic,
       [CAST(CASE WHEN i % 4 = 0 THEN 1.0 ELSE 0.0 END + 0.05 * sin(i) AS DOUBLE),
        CAST(CASE WHEN i % 4 = 1 THEN 1.0 ELSE 0.0 END + 0.05 * cos(i) AS DOUBLE),
        CAST(CASE WHEN i % 4 = 2 THEN 1.0 ELSE 0.0 END + 0.05 * sin(2 * i) AS DOUBLE),
        CAST(CASE WHEN i % 4 = 3 THEN 1.0 ELSE 0.0 END + 0.05 * cos(2 * i) AS DOUBLE)] AS emb,
       CASE WHEN i % 2 = 0 THEN 'a' ELSE 'b' END AS cohort
FROM range(40) t(i);
CREATE TABLE metrics AS
SELECT i AS ts, 'host-1' AS host, CAST(50 + 5 * sin(i / 3.0) + CASE WHEN i > 70 THEN 30 ELSE 0 END + (i % 5) AS DOUBLE) AS cpu
FROM range(120) t(i);
CREATE TABLE fleet AS
SELECT i AS id, 'veh-' || i AS name, [CAST(sin(i) AS DOUBLE), CAST(cos(i) AS DOUBLE), CAST(sin(i / 2.0) AS DOUBLE)] AS emb
FROM range(20) t(i);
CREATE TABLE strategies (id BIGINT PRIMARY KEY, label VARCHAR, emb DOUBLE[]);
INSERT INTO strategies
SELECT i, 'strategy ' || i, [CAST(sin(i) AS DOUBLE), CAST(cos(i) AS DOUBLE), CAST(sin(2 * i) AS DOUBLE), CAST(cos(2 * i) AS DOUBLE)]
FROM range(12) t(i);
