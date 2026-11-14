-- Parity cases for the search family. Cases are separated by blank lines; each
-- case runs in ONE CLI session (so setup statements can precede the query).
-- Lines starting with "--" are comments. Only deterministic output belongs here.

SELECT fractal_edition(), fractal_version();

SELECT fractal_version() FROM range(3000) LIMIT 1;

SELECT fractal_search([0.1,0.2,0.3]::DOUBLE[]);

SELECT fractal_search([0.1,0.2,0.3]::DOUBLE[], 10);

SELECT fractal_search([0.1,0.2,0.3]::DOUBLE[], 10, 20);

SELECT fractal_search([0.1,0.2,0.3]::DOUBLE[], 10, 20, 3);

SELECT fractal_search([1.0,2.0,3.0]::DOUBLE[], [1.0,2.0,3.0]::DOUBLE[]);

SELECT fractal_search([1.0,0.0,0.0]::DOUBLE[], [0.0,1.0,0.0]::DOUBLE[]);

-- a column of vectors against a constant query, spanning several 2048-row chunks
CREATE TABLE d AS SELECT [i*0.1, i*0.2, i*0.3]::DOUBLE[] AS v FROM range(1,5000) t(i);
SELECT count(*), round(min(fractal_search(v, [0.5,0.5,0.5]::DOUBLE[])), 9), round(max(fractal_search(v, [0.5,0.5,0.5]::DOUBLE[])), 9), round(sum(fractal_search(v, [0.5,0.5,0.5]::DOUBLE[])), 6) FROM d;

-- NULL and edge inputs
SELECT fractal_search(NULL::DOUBLE[]);

SELECT fractal_search([]::DOUBLE[]);

SELECT fractal_search([1.0, NULL]::DOUBLE[]);

SELECT fractal_search([0.1]::DOUBLE[], [0.1,0.2]::DOUBLE[]);

SELECT fractal_search([0.1,0.2]::DOUBLE[], NULL::DOUBLE[]);

SELECT fractal_search(NULL::DOUBLE[], [0.1,0.2]::DOUBLE[]);

-- a NULL row among valid ones
CREATE TABLE n AS SELECT CASE WHEN i % 3 = 0 THEN NULL ELSE [i*1.0, 2.0, 3.0] END::DOUBLE[] AS v FROM range(1,10) t(i);
SELECT i, fractal_search(v, [1.0,2.0,3.0]::DOUBLE[]) FROM (SELECT row_number() OVER () AS i, v FROM n) ORDER BY i;
SELECT fractal_search(v) FROM n;

-- dimension limits: 4096 is the ceiling
SELECT len(fractal_search(list_transform(range(4096), lambda x: 0.5)::DOUBLE[]));

SELECT fractal_search(list_transform(range(4097), lambda x: 0.5)::DOUBLE[]);

SELECT fractal_search([1.0]::DOUBLE[], list_transform(range(4097), lambda x: 0.5)::DOUBLE[]);

SELECT fractal_search([1.0]::DOUBLE[], []::DOUBLE[]);

-- iterations / population / diffusion edge values reach the core unchanged
SELECT fractal_search([0.1,0.2]::DOUBLE[], 0);

SELECT fractal_search([0.1,0.2]::DOUBLE[], -1, 50, 2);

SELECT fractal_search([0.1,0.2]::DOUBLE[], 5, NULL, 2);

-- overload resolution
SELECT typeof(fractal_search([0.1]::DOUBLE[])), typeof(fractal_search([0.1]::DOUBLE[], [0.1]::DOUBLE[])), typeof(fractal_version());
