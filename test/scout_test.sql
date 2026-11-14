-- test/scout_test.sql -- Scout Mode (fractal_search_explore aggregate) gate.
--
-- Run like smoke_test.sql:
--   { echo "LOAD '<path>';"; cat test/scout_test.sql; } | duckdb -bail -unsigned
--
-- Asserts the §8 Scout enablement properties for the aggregate:
--   (1)+(2) returns the population -- population_size particles, each of
--           the corpus dim (not 1, the old per-row-cosine symptom);
--   (3)     discovery -- the walk=0 population disperses across more than
--           one island, where a Sniper top-k would collapse into one.

-- 3 well-separated unit-axis clusters in R^3 (tiny intra-cluster jitter).
CREATE TABLE scout_corpus AS
SELECT
    i AS id,
    (i % 3) AS cluster,
    CASE (i % 3)
        WHEN 0 THEN [1.0 + sin(i*0.01)*0.02, cos(i*0.013)*0.02, sin(i*0.017)*0.02]
        WHEN 1 THEN [sin(i*0.01)*0.02, 1.0 + cos(i*0.013)*0.02, sin(i*0.017)*0.02]
        ELSE       [sin(i*0.01)*0.02, cos(i*0.013)*0.02, 1.0 + sin(i*0.017)*0.02]
    END::DOUBLE[] AS embedding
FROM range(0, 60) t(i);

-- One row per population particle.
CREATE TABLE scout_pop AS
SELECT UNNEST(
         fractal_search_explore(embedding, [1.0, 0.0, 0.0]::DOUBLE[],
                         '{"population_size":24,"iterations":12}')
       ) AS p
FROM scout_corpus;

-- (1)+(2) population shape: 24 particles, each 3-D.
SELECT
    CASE
        WHEN count_star() <> 24
            THEN error('expected 24 particles; got ' || count_star())
        WHEN count_if(len(p) <> 3) > 0
            THEN error('particle dim != 3')
        ELSE 'population ok: ' || count_star() || ' particles'
    END AS status
FROM scout_pop;

-- (3) discovery: particles disperse across >1 of the 3 islands. Each
-- particle is labeled by its nearest unit-axis center (squared L2).
WITH nearest AS (
    SELECT
        CASE
            WHEN ((p[1]-1)*(p[1]-1) + p[2]*p[2] + p[3]*p[3])
                  <= (p[1]*p[1] + (p[2]-1)*(p[2]-1) + p[3]*p[3])
             AND ((p[1]-1)*(p[1]-1) + p[2]*p[2] + p[3]*p[3])
                  <= (p[1]*p[1] + p[2]*p[2] + (p[3]-1)*(p[3]-1)) THEN 0
            WHEN (p[1]*p[1] + (p[2]-1)*(p[2]-1) + p[3]*p[3])
                  <= (p[1]*p[1] + p[2]*p[2] + (p[3]-1)*(p[3]-1)) THEN 1
            ELSE 2
        END AS isl
    FROM scout_pop
)
SELECT
    CASE
        WHEN count(DISTINCT isl) < 2
            THEN error('Scout discovered only ' || count(DISTINCT isl)
                       || ' island(s); expected >= 2 (no dispersion)')
        ELSE 'discovery ok: ' || count(DISTINCT isl) || ' islands'
    END AS status
FROM nearest;
