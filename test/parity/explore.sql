-- Parity cases for fractal_search_explore (Scout aggregate), in fractalsql_ext.c.

CREATE TABLE d AS SELECT [i*0.1, 1.0-i*0.05, (i%7)*0.3]::DOUBLE[] AS e, i % 3 AS g FROM range(1,400) t(i);
SELECT len(r), r[1], r[2], r[50] FROM (SELECT fractal_search_explore(e, [0.3,0.5,0.7]::DOUBLE[]) AS r FROM d);

CREATE TABLE d AS SELECT [i*0.1, 1.0-i*0.05, (i%7)*0.3]::DOUBLE[] AS e FROM range(1,400) t(i);
SELECT len(r) FROM (SELECT fractal_search_explore(e, [0.3,0.5,0.7]::DOUBLE[], '{"population_size": 10}') AS r FROM d);

CREATE TABLE d AS SELECT [i*0.1, 1.0-i*0.05, (i%7)*0.3]::DOUBLE[] AS e FROM range(1,400) t(i);
SELECT len(r), r[1] FROM (SELECT fractal_search_explore(e, [0.3,0.5,0.7]::DOUBLE[], '{"population_size": 7, "iterations": 5, "diffusion_factor": 3}') AS r FROM d);

-- unusable option values fall back to the defaults
CREATE TABLE d AS SELECT [i*0.1, 1.0-i*0.05, (i%7)*0.3]::DOUBLE[] AS e FROM range(1,400) t(i);
SELECT len(r) FROM (SELECT fractal_search_explore(e, [0.3,0.5,0.7]::DOUBLE[], '{"population_size": -4}') AS r FROM d);

CREATE TABLE d AS SELECT [i*0.1, 1.0-i*0.05, (i%7)*0.3]::DOUBLE[] AS e FROM range(1,400) t(i);
SELECT len(r) FROM (SELECT fractal_search_explore(e, [0.3,0.5,0.7]::DOUBLE[], 'not json') AS r FROM d);

-- GROUP BY: one population per group
CREATE TABLE d AS SELECT [i*0.1, 1.0-i*0.05, (i%7)*0.3]::DOUBLE[] AS e, i % 3 AS g FROM range(1,400) t(i);
SELECT g, len(r) FROM (SELECT g, fractal_search_explore(e, [0.3,0.5,0.7]::DOUBLE[]) AS r FROM d GROUP BY g) ORDER BY g;

-- empty input and all-NULL input give NULL
CREATE TABLE d (e DOUBLE[]);
SELECT fractal_search_explore(e, [0.3,0.5,0.7]::DOUBLE[]) IS NULL FROM d;

CREATE TABLE d AS SELECT NULL::DOUBLE[] AS e FROM range(10);
SELECT fractal_search_explore(e, [0.3,0.5,0.7]::DOUBLE[]) IS NULL FROM d;

-- a NULL query gives NULL
CREATE TABLE d AS SELECT [i*0.1, 1.0, 2.0]::DOUBLE[] AS e FROM range(1,20) t(i);
SELECT fractal_search_explore(e, NULL::DOUBLE[]) IS NULL FROM d;

-- NULL rows are skipped, the rest are used
CREATE TABLE d AS SELECT CASE WHEN i % 4 = 0 THEN NULL ELSE [i*0.1, 1.0, 2.0] END::DOUBLE[] AS e FROM range(1,100) t(i);
SELECT len(r) FROM (SELECT fractal_search_explore(e, [0.3,0.5,0.7]::DOUBLE[]) AS r FROM d);

-- inconsistent dimensions across rows is an error
CREATE TABLE d AS SELECT CASE WHEN i = 5 THEN [1.0, 2.0] ELSE [1.0, 2.0, 3.0] END::DOUBLE[] AS e FROM range(1,10) t(i);
SELECT fractal_search_explore(e, [0.3,0.5,0.7]::DOUBLE[]) FROM d;

-- an embedding wider than the 4096 ceiling is an error
CREATE TABLE d AS SELECT list_transform(range(4097), lambda x: 0.5)::DOUBLE[] AS e FROM range(2);
SELECT fractal_search_explore(e, [0.3]::DOUBLE[]) FROM d;

-- query width differing from the embedding width is refused (the query used to be read past its end: found by the valgrind
-- profile; the C++ build returned whatever was in memory there)
-- expect-c: query dimension 2 does not match the corpus dimension 3
CREATE TABLE d AS SELECT [i*0.1, 1.0, 2.0]::DOUBLE[] AS e FROM range(1,20) t(i);
SELECT fractal_search_explore(e, [0.3,0.5]::DOUBLE[]) IS NULL FROM d;

-- a large table so DuckDB parallelises the aggregate and merges partial states (combine)
CREATE TABLE d AS SELECT [(i % 1000) * 0.001, ((i * 7) % 1000) * 0.001, ((i * 13) % 1000) * 0.001]::DOUBLE[] AS e FROM range(1, 300000) t(i);
SELECT len(r), r[1], r[25], r[50] FROM (SELECT fractal_search_explore(e, [0.5,0.5,0.5]::DOUBLE[]) AS r FROM d);

-- usable in a subquery with UNNEST, as the docs show
CREATE TABLE d AS SELECT [i*0.1, 1.0-i*0.05, (i%7)*0.3]::DOUBLE[] AS e FROM range(1,400) t(i);
SELECT count(*) FROM (SELECT UNNEST(fractal_search_explore(e, [0.3,0.5,0.7]::DOUBLE[])) FROM d);

-- typing and overload resolution
SELECT typeof(fractal_search_explore([1.0]::DOUBLE[], [1.0]::DOUBLE[])), typeof(fractal_search_explore([1.0]::DOUBLE[], [1.0]::DOUBLE[], '{}'));
