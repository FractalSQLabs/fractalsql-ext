-- Parity cases for the community portfolio functions in fsql_sovereign.c. All seeded: deterministic.

SELECT fractal_optimize_portfolio([0.10, 0.12, 0.08, 0.15]::DOUBLE[], [0.04,0.01,0.00,0.01, 0.01,0.05,0.01,0.00, 0.00,0.01,0.03,0.01, 0.01,0.00,0.01,0.06]::DOUBLE[], 2, 42);

SELECT p.sharpe, p.weights FROM (SELECT fractal_optimize_portfolio([0.10, 0.12, 0.08, 0.15]::DOUBLE[], [0.04,0.01,0.00,0.01, 0.01,0.05,0.01,0.00, 0.00,0.01,0.03,0.01, 0.01,0.00,0.01,0.06]::DOUBLE[], 2, 7) AS p);

SELECT fractal_optimize_portfolio([0.10, 0.12, 0.08, 0.15]::DOUBLE[], [0.04,0.01,0.00,0.01, 0.01,0.05,0.01,0.00, 0.00,0.01,0.03,0.01, 0.01,0.00,0.01,0.06]::DOUBLE[], 2);

SELECT fractal_optimize_portfolio([0.10, 0.12, 0.08, 0.15]::DOUBLE[], [0.04,0.01,0.00,0.01, 0.01,0.05,0.01,0.00, 0.00,0.01,0.03,0.01, 0.01,0.00,0.01,0.06]::DOUBLE[], 3, 42, true);

SELECT fractal_optimize_portfolio([0.10, 0.12, 0.08, 0.15]::DOUBLE[], [0.04,0.01,0.00,0.01, 0.01,0.05,0.01,0.00, 0.00,0.01,0.03,0.01, 0.01,0.00,0.01,0.06]::DOUBLE[], 2, 42, false, 'levy');

SELECT fractal_optimize_portfolio([0.10, 0.12, 0.08, 0.15]::DOUBLE[], [0.04,0.01,0.00,0.01, 0.01,0.05,0.01,0.00, 0.00,0.01,0.03,0.01, 0.01,0.00,0.01,0.06]::DOUBLE[], 2, 42, false, 'gaussian');

SELECT fractal_optimize_portfolio([0.10, 0.12, 0.08, 0.15]::DOUBLE[], [0.04,0.01,0.00,0.01, 0.01,0.05,0.01,0.00, 0.00,0.01,0.03,0.01, 0.01,0.00,0.01,0.06]::DOUBLE[], 2, 42, false, 'cauchy');

-- optional arguments passed as NULL fall back to their defaults
SELECT fractal_optimize_portfolio([0.10, 0.12, 0.08, 0.15]::DOUBLE[], [0.04,0.01,0.00,0.01, 0.01,0.05,0.01,0.00, 0.00,0.01,0.03,0.01, 0.01,0.00,0.01,0.06]::DOUBLE[], 2, NULL, NULL, NULL);

-- the same seed gives the same answer; different seeds may differ
SELECT fractal_optimize_portfolio([0.1,0.2,0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, 5) = fractal_optimize_portfolio([0.1,0.2,0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, 5);

-- errors
SELECT fractal_optimize_portfolio([]::DOUBLE[], []::DOUBLE[], 1);

SELECT fractal_optimize_portfolio([0.1,0.2]::DOUBLE[], [0.04,0,0]::DOUBLE[], 1);

SELECT fractal_optimize_portfolio([0.1,0.2]::DOUBLE[], [0.04,0,0,0.09]::DOUBLE[], 0);

SELECT fractal_optimize_portfolio([0.1,0.2]::DOUBLE[], [0.04,0,0,0.09]::DOUBLE[], 3);

SELECT fractal_optimize_portfolio([0.1,0.2]::DOUBLE[], [0.04,0,0,0.09]::DOUBLE[], -1);

SELECT fractal_optimize_portfolio([0.1,0.2]::DOUBLE[], NULL::DOUBLE[], 1);

SELECT fractal_optimize_portfolio(NULL::DOUBLE[], [0.04]::DOUBLE[], 1), fractal_optimize_portfolio([0.1]::DOUBLE[], [0.04]::DOUBLE[], NULL);

-- a table of problems across several chunks
CREATE TABLE p AS SELECT i, [0.10 + i*0.0001, 0.12, 0.08, 0.15]::DOUBLE[] AS mu FROM range(1, 40) t(i);
SELECT count(*), round(sum(fractal_optimize_portfolio(mu, [0.04,0.01,0.00,0.01, 0.01,0.05,0.01,0.00, 0.00,0.01,0.03,0.01, 0.01,0.00,0.01,0.06]::DOUBLE[], 2, 1).sharpe), 6) FROM p;

-- optimize_subset
SELECT fractal_optimize_subset([0.9, 0.5, 0.7, 0.3]::DOUBLE[], [0.6, 0.6, 0.6, 0.6]::DOUBLE[], 2, NULL, 0.0, 42);

SELECT s.score, s.weights FROM (SELECT fractal_optimize_subset([0.9, 0.5, 0.7, 0.3]::DOUBLE[], [0.6, 0.6, 0.6, 0.6]::DOUBLE[], 2) AS s);

SELECT fractal_optimize_subset([0.9, 0.5, 0.7, 0.3]::DOUBLE[], [0.6, 0.6, 0.6, 0.6]::DOUBLE[], 2, [0.25, 0.25, 0.25, 0.25]::DOUBLE[]);

SELECT fractal_optimize_subset([0.9, 0.5, 0.7, 0.3]::DOUBLE[], [0.6, 0.6, 0.6, 0.6]::DOUBLE[], 2, [0.25, 0.25, 0.25, 0.25]::DOUBLE[], 0.5);

SELECT fractal_optimize_subset([0.9, 0.5, 0.7, 0.3]::DOUBLE[], [0.6, 0.6, 0.6, 0.6]::DOUBLE[], 2, [0.25, 0.25, 0.25, 0.25]::DOUBLE[], 0.5, 9);

SELECT fractal_optimize_subset([0.9, 0.5]::DOUBLE[], [0.6, 0.6]::DOUBLE[], 3);

SELECT fractal_optimize_subset([0.9, 0.5]::DOUBLE[], [0.6, 0.6]::DOUBLE[], 0);

SELECT fractal_optimize_subset([0.9, 0.5]::DOUBLE[], [0.6]::DOUBLE[], 1);

SELECT fractal_optimize_subset([0.9, 0.5]::DOUBLE[], [0.6, 0.6]::DOUBLE[], 1, [0.5]::DOUBLE[]);

SELECT fractal_optimize_subset([]::DOUBLE[], []::DOUBLE[], 1);

SELECT fractal_optimize_subset([0.9, 0.5]::DOUBLE[], [0.1, 0.1]::DOUBLE[], 2);

SELECT fractal_optimize_subset([0.9, 0.5]::DOUBLE[], [1.5, 0.6]::DOUBLE[], 1);

-- SPECIAL null handling: NULL arguments give a typed NULL row, not an error
SELECT fractal_optimize_subset(NULL::DOUBLE[], [0.6, 0.6]::DOUBLE[], 1) IS NULL, fractal_optimize_subset([0.9, 0.5]::DOUBLE[], NULL::DOUBLE[], 1) IS NULL, fractal_optimize_subset([0.9, 0.5]::DOUBLE[], [0.6, 0.6]::DOUBLE[], NULL) IS NULL;

SELECT fractal_optimize_subset([0.9, NULL]::DOUBLE[], [0.6, 0.6]::DOUBLE[], 1) IS NULL;

-- typing
SELECT typeof(fractal_optimize_portfolio([0.1]::DOUBLE[], [0.04]::DOUBLE[], 1)), typeof(fractal_optimize_subset([0.9]::DOUBLE[], [1.0]::DOUBLE[], 1));
