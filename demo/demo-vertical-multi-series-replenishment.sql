-- demo/demo-vertical-multi-series-replenishment.sql
--
-- Industry vertical: Multi-location replenishment: stockout prevention and
-- non-linear demand forecasting. AGENTIC kit: Six locations x 64 days of
-- unit demand. `fractal_dimension_dfa` finds the location whose demand is
-- accelerating (a viral item or a local event) rather than merely high;
-- `fractal_optimize_portfolio` picks which 3 locations get the scheduled
-- replenishment from the central hub with the risk matrix inflated by the
-- DFA exponent; the surging location is flagged for an expedited pick
-- instead. `fractal_agent_allocate` is the shipped one-call form of the
-- optimizer step.
--
--   1. fractal_dimension_dfa over each location's daily units: non-linear
--      vs merely high.
--   2. fractal_optimize_portfolio (SFS): 3-of-6 scheduled replenishment,
--      risk = variance x DFA exponent.
--   3. fractal_agent_allocate: the same optimizer plus a reasoned
--      rationale, one call.
--   4. A closing fractal_reason() writes the redistribution rationale.
--
-- Prerequisites: LOAD 'fractalsql.duckdb_extension'; (the agents ship
-- inside the extension). The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.<platform>.duckdb_extension';"; cat demo/demo-vertical-multi-series-replenishment.sql; } \
--       | duckdb -unsigned
--
-- Safe to re-run: msr_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * mu is mean daily units per unit of stock moved; the matrix is demand
--     variance x DFA exponent.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=multi-series-replenishment ok);
--     the build_test kit gate greps for it.

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

.print
.print === 1. Six locations x 64 days of unit demand ===
DROP TABLE IF EXISTS msr_units;
CREATE TABLE msr_units (
    ent text,
    seq int,
    val float8
);
INSERT INTO msr_units (ent, seq, val)
SELECT ent, g, base * (1.0 + 0.10 * ((g + p1) % 7) / 7.0) + CASE WHEN p2 > 0 AND g > 40 THEN p2 * (g - 40) * (g - 40) ELSE 0 END
FROM (VALUES ('loc-a', 130, 1, 0),
             ('loc-b', 105, 2, 0),
             ('loc-c', 150, 3, 0),
             ('loc-d', 115, 4, 0.4),
             ('loc-e', 170, 5, 0),
             ('loc-f', 90, 6, 0)) AS s(ent, base, p1, p2),
     generate_series(1, 64) AS gs(g);

.print
.print === 2. DFA exponent of each location ===
DROP TABLE IF EXISTS msr_prof;
CREATE TABLE msr_prof AS
SELECT row_number() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, round(m.mean_v, 4) AS mean_v, round(m.var_v, 4) AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha
FROM (SELECT ent, arr FROM (SELECT ent, list(round(val, 5) ORDER BY seq) AS arr FROM msr_units GROUP BY ent)) a
JOIN (SELECT ent, avg(val) AS mean_v, avg(val * val) - avg(val) * avg(val) AS var_v
        FROM msr_units GROUP BY ent) m ON m.ent = a.ent
ORDER BY a.ent;
SELECT ent, mean_v, var_v, round(dfa_alpha, 3) AS dfa_alpha
  FROM msr_prof ORDER BY ent;

.print
.print === 3. fractal_optimize_portfolio: pick 3 locations ===
DROP TABLE IF EXISTS msr_result;
CREATE TABLE msr_result AS
SELECT fractal_optimize_portfolio(
    (SELECT list(round(p.mean_v / 100.0, 4) ORDER BY p.pid) FROM msr_prof p),
    (SELECT list(CASE WHEN a.pid = b.pid THEN round(a.var_v * a.dfa_alpha / 100.0, 4) ELSE 0::float8 END
                 ORDER BY a.pid, b.pid)
       FROM msr_prof a CROSS JOIN msr_prof b),
    3, 42) AS rj;

SELECT round(rj.sharpe, 4) AS sharpe FROM msr_result;

.print --- the chosen entries (weight > 0; weights are in ent order) ---
SELECT p.ent, round(w.weight, 4) AS weight
FROM msr_result r,
     LATERAL (SELECT unnest(r.rj.weights) AS weight, generate_subscripts(r.rj.weights, 1) AS ord) w
JOIN msr_prof p ON p.pid = w.ord
WHERE w.weight > 0
ORDER BY w.weight DESC;
.print --- locations flagged for an expedited pick (DFA exponent > 1.2) ---
SELECT ent, round(dfa_alpha, 3) AS dfa_alpha
  FROM msr_prof WHERE dfa_alpha > 1.2 ORDER BY dfa_alpha DESC;
.print --- the shipped agent: optimizer + reasoned rationale, one call (reasoning plugin) ---
SELECT json_extract(j, '$.allocation') AS allocation,
       json_extract(j, '$.sharpe')     AS sharpe,
       json_extract_string(j, '$.rationale') AS rationale
FROM (SELECT fractal_agent_allocate(
    (SELECT list(round(p.mean_v / 100.0, 4) ORDER BY p.pid) FROM msr_prof p),
    (SELECT list(CASE WHEN a.pid = b.pid THEN round(a.var_v * a.dfa_alpha / 100.0, 4) ELSE 0::float8 END
                 ORDER BY a.pid, b.pid)
       FROM msr_prof a CROSS JOIN msr_prof b),
    3, '{"portfolio": "multi-location-replenishment"}') AS j);

.print
.print === 4. Reasoning: redistribution rationale ===
SELECT fractal_reason(
    'one-line redistribution rationale: which locations get scheduled stock and which needs an expedited pick',
    json_object('surging_location', (SELECT ent FROM msr_prof ORDER BY dfa_alpha DESC LIMIT 1), 'top_dfa', (SELECT max(dfa_alpha) FROM msr_prof))::VARCHAR) AS narrative;

.print
.print === 5. Headline check ===
.mode list
.headers off
SELECT 'HEADLINE kit=multi-series-replenishment ' || CASE WHEN
    -- exactly one location is accelerating (loc-d), and it is loc-d
    (SELECT count(*) FROM msr_prof WHERE dfa_alpha > 1.2) = 1
    AND (SELECT dfa_alpha FROM msr_prof WHERE ent = 'loc-d') > 1.2
    -- the optimizer fills exactly three of the six slots
    AND (SELECT count(*) FROM msr_result r,
                LATERAL (SELECT unnest(r.rj.weights) AS weight) w
         WHERE w.weight > 0) = 3
    -- and the accelerating location is the one left out: it gets the
    -- expedited pick, not a scheduled one
    AND (SELECT w.weight FROM msr_result r,
                LATERAL (SELECT unnest(r.rj.weights) AS weight,
                                generate_subscripts(r.rj.weights, 1) AS ord) w
         WHERE w.ord = (SELECT pid FROM msr_prof WHERE ent = 'loc-d')) = 0
    AND (SELECT rj.sharpe FROM msr_result) > 0
  THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE msr_units, msr_prof, msr_result;
