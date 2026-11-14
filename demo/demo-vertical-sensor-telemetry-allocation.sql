-- demo/demo-vertical-sensor-telemetry-allocation.sql
--
-- Industry vertical: Resource allocation: sensor telemetry regime shifts
-- and non-linear demand. AGENTIC kit: Six sites x 64 days of resource
-- demand from soil-moisture sensors. `fractal_dimension_dfa` finds the site
-- whose demand is accelerating (a non-linear trend or a failing supply
-- line) rather than merely high; `fractal_optimize_portfolio` picks which 3
-- sites get the scheduled service run with the risk matrix inflated by the
-- DFA exponent; the accelerating site is flagged for an inspection instead.
-- `fractal_agent_allocate` is the shipped one-call form of the optimizer
-- step.
--
--   1. fractal_dimension_dfa over each site's daily demand.
--   2. fractal_optimize_portfolio (SFS): 3-of-6 scheduled service, risk =
--      variance x DFA exponent.
--   3. fractal_agent_allocate: the same optimizer plus a reasoned
--      rationale, one call.
--   4. A closing fractal_reason() writes the service-plan rationale.
--
-- Prerequisites: LOAD 'fractalsql.duckdb_extension'; (the agents ship
-- inside the extension). The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.<platform>.duckdb_extension';"; cat demo/demo-vertical-sensor-telemetry-allocation.sql; } \
--       | duckdb -unsigned
--
-- Safe to re-run: sta_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * mu is mean daily demand served per unit of resource moved; the risk
--     matrix is demand variance x DFA exponent, so an accelerating site
--     costs more risk than a steady one of the same volume.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=sensor-telemetry-allocation ok);
--     the build_test kit gate greps for it.

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

.print
.print === 1. Six sites x 64 days of resource demand ===
DROP TABLE IF EXISTS sta_demand;
CREATE TABLE sta_demand (
    ent text,
    seq int,
    val float8
);
INSERT INTO sta_demand (ent, seq, val)
SELECT ent, g, base * (1.0 + 0.06 * ((g + p1) % 7) / 7.0) + CASE WHEN p2 > 0 AND g > 40 THEN p2 * (g - 40) * (g - 40) ELSE 0 END
FROM (VALUES ('site-a', 120, 1, 0),
             ('site-b', 95, 2, 0),
             ('site-c', 140, 3, 0),
             ('site-d', 110, 4, 0.45),
             ('site-e', 160, 5, 0),
             ('site-f', 85, 6, 0)) AS s(ent, base, p1, p2),
     generate_series(1, 64) AS gs(g);

.print
.print === 2. DFA exponent of each site ===
DROP TABLE IF EXISTS sta_prof;
CREATE TABLE sta_prof AS
SELECT row_number() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, round(m.mean_v, 4) AS mean_v, round(m.var_v, 4) AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha
FROM (SELECT ent, arr FROM (SELECT ent, list(round(val, 5) ORDER BY seq) AS arr FROM sta_demand GROUP BY ent)) a
JOIN (SELECT ent, avg(val) AS mean_v, avg(val * val) - avg(val) * avg(val) AS var_v
        FROM sta_demand GROUP BY ent) m ON m.ent = a.ent
ORDER BY a.ent;
SELECT ent, mean_v, var_v, round(dfa_alpha, 3) AS dfa_alpha
  FROM sta_prof ORDER BY ent;

.print
.print === 3. fractal_optimize_portfolio: pick 3 sites ===
DROP TABLE IF EXISTS sta_result;
CREATE TABLE sta_result AS
SELECT fractal_optimize_portfolio(
    (SELECT list(round(p.mean_v / 100.0, 4) ORDER BY p.pid) FROM sta_prof p),
    (SELECT list(CASE WHEN a.pid = b.pid THEN round(a.var_v * a.dfa_alpha / 100.0, 4) ELSE 0::float8 END
                 ORDER BY a.pid, b.pid)
       FROM sta_prof a CROSS JOIN sta_prof b),
    3, 42) AS rj;

SELECT round(rj.sharpe, 4) AS sharpe FROM sta_result;

.print --- the chosen entries (weight > 0; weights are in ent order) ---
SELECT p.ent, round(w.weight, 4) AS weight
FROM sta_result r,
     LATERAL (SELECT unnest(r.rj.weights) AS weight, generate_subscripts(r.rj.weights, 1) AS ord) w
JOIN sta_prof p ON p.pid = w.ord
WHERE w.weight > 0
ORDER BY w.weight DESC;
.print --- sites flagged for inspection (DFA exponent > 1.2) ---
SELECT ent, round(dfa_alpha, 3) AS dfa_alpha
  FROM sta_prof WHERE dfa_alpha > 1.2 ORDER BY dfa_alpha DESC;
.print --- the shipped agent: optimizer + reasoned rationale, one call (reasoning plugin) ---
SELECT json_extract(j, '$.allocation') AS allocation,
       json_extract(j, '$.sharpe')     AS sharpe,
       json_extract_string(j, '$.rationale') AS rationale
FROM (SELECT fractal_agent_allocate(
    (SELECT list(round(p.mean_v / 100.0, 4) ORDER BY p.pid) FROM sta_prof p),
    (SELECT list(CASE WHEN a.pid = b.pid THEN round(a.var_v * a.dfa_alpha / 100.0, 4) ELSE 0::float8 END
                 ORDER BY a.pid, b.pid)
       FROM sta_prof a CROSS JOIN sta_prof b),
    3, '{"portfolio": "sensor-allocation"}') AS j);

.print
.print === 4. Reasoning: service-plan rationale ===
SELECT fractal_reason(
    'one-line service-plan rationale: which sites get the resource this cycle and which needs an inspection',
    json_object('inspect_site', (SELECT ent FROM sta_prof ORDER BY dfa_alpha DESC LIMIT 1), 'top_dfa', (SELECT max(dfa_alpha) FROM sta_prof))::VARCHAR) AS narrative;

.print
.print === 5. Headline check ===
.mode list
.headers off
SELECT 'HEADLINE kit=sensor-telemetry-allocation ' || CASE WHEN
    -- exactly one site is accelerating (site-d), and it is site-d
    (SELECT count(*) FROM sta_prof WHERE dfa_alpha > 1.2) = 1
    AND (SELECT dfa_alpha FROM sta_prof WHERE ent = 'site-d') > 1.2
    -- the optimizer fills exactly three of the six slots
    AND (SELECT count(*) FROM sta_result r,
                LATERAL (SELECT unnest(r.rj.weights) AS weight) w
         WHERE w.weight > 0) = 3
    -- and the accelerating site is the one left out: it gets the
    -- inspection, not a scheduled service run
    AND (SELECT w.weight FROM sta_result r,
                LATERAL (SELECT unnest(r.rj.weights) AS weight,
                                generate_subscripts(r.rj.weights, 1) AS ord) w
         WHERE w.ord = (SELECT pid FROM sta_prof WHERE ent = 'site-d')) = 0
    AND (SELECT rj.sharpe FROM sta_result) > 0
  THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE sta_demand, sta_prof, sta_result;
