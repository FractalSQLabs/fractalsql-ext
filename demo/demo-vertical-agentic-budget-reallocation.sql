-- demo/demo-vertical-agentic-budget-reallocation.sql
--
-- Industry vertical: Agentic allocation: multi-source attribution and
-- dynamic cross-channel budget reallocation. AGENTIC kit: Six channels x 64
-- days of attributed outcomes. `fractal_dimension_dfa` finds the channel
-- whose response is accelerating (a non-linear surge a plain average would
-- hide); `fractal_optimize_portfolio` picks which 3 channels receive the
-- scheduled budget increase with the risk matrix inflated by the DFA
-- exponent; the surging channel is flagged for a capped, monitored test
-- instead. `fractal_agent_allocate` is the shipped one-call form of the
-- optimizer step, and `fractal_agent_route_task` dispatches each journey to
-- the best-matching model under a token budget.
--
--   1. fractal_dimension_dfa over each channel's daily outcomes: non-linear
--      response vs merely high.
--   2. fractal_optimize_portfolio (SFS): 3-of-6 budget increase, risk =
--      variance x DFA exponent.
--   3. fractal_agent_allocate: the same optimizer plus a reasoned
--      rationale, one call.
--   4. fractal_agent_route_task: each journey routed to the best-capable
--      model.
--   5. A closing fractal_reason() gives the reallocation rationale.
--
-- Prerequisites: LOAD 'fractalsql.duckdb_extension'; (the agents ship
-- inside the extension). The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.<platform>.duckdb_extension';"; cat demo/demo-vertical-agentic-budget-reallocation.sql; } \
--       | duckdb -unsigned
--
-- Safe to re-run: abr_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * The optimizer maximizes a Sharpe-style ratio: mu is the mean daily
--     outcomes per unit of spend, the matrix is the response risk (variance
--     x DFA exponent).
--   * Model capability vectors = [single-step, recency-weighted, mid-path-
--     heavy, cross-device].
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=agentic-budget-reallocation ok);
--     the build_test kit gate greps for it.

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

.print
.print === 1. Six channels x 64 days of attributed outcomes ===
DROP TABLE IF EXISTS abr_outcome;
CREATE TABLE abr_outcome (
    ent text,
    seq int,
    val float8
);
INSERT INTO abr_outcome (ent, seq, val)
SELECT ent, g, base * (1.0 + 0.06 * ((g + p1) % 7) / 7.0) + CASE WHEN p2 > 0 AND g > 40 THEN p2 * (g - 40) * (g - 40) ELSE 0 END
FROM (VALUES ('channel-a', 120, 1, 0),
             ('channel-b', 95, 2, 0),
             ('channel-c', 140, 3, 0),
             ('channel-d', 110, 4, 0.45),
             ('channel-e', 160, 5, 0),
             ('channel-f', 85, 6, 0)) AS s(ent, base, p1, p2),
     generate_series(1, 64) AS gs(g);

.print
.print === 2. DFA exponent of each channel ===
DROP TABLE IF EXISTS abr_prof;
CREATE TABLE abr_prof AS
SELECT row_number() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, round(m.mean_v, 4) AS mean_v, round(m.var_v, 4) AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha
FROM (SELECT ent, arr FROM (SELECT ent, list(round(val, 5) ORDER BY seq) AS arr FROM abr_outcome GROUP BY ent)) a
JOIN (SELECT ent, avg(val) AS mean_v, avg(val * val) - avg(val) * avg(val) AS var_v
        FROM abr_outcome GROUP BY ent) m ON m.ent = a.ent
ORDER BY a.ent;
SELECT ent, mean_v, var_v, round(dfa_alpha, 3) AS dfa_alpha
  FROM abr_prof ORDER BY ent;

.print
.print === 3. fractal_optimize_portfolio: pick 3 channels ===
DROP TABLE IF EXISTS abr_result;
CREATE TABLE abr_result AS
SELECT fractal_optimize_portfolio(
    (SELECT list(round(p.mean_v / 100.0, 4) ORDER BY p.pid) FROM abr_prof p),
    (SELECT list(CASE WHEN a.pid = b.pid THEN round(a.var_v * a.dfa_alpha / 100.0, 4) ELSE 0::float8 END
                 ORDER BY a.pid, b.pid)
       FROM abr_prof a CROSS JOIN abr_prof b),
    3, 42) AS rj;

SELECT round(rj.sharpe, 4) AS sharpe FROM abr_result;

.print --- the chosen entries (weight > 0; weights are in ent order) ---
SELECT p.ent, round(w.weight, 4) AS weight
FROM abr_result r,
     LATERAL (SELECT unnest(r.rj.weights) AS weight, generate_subscripts(r.rj.weights, 1) AS ord) w
JOIN abr_prof p ON p.pid = w.ord
WHERE w.weight > 0
ORDER BY w.weight DESC;
.print --- channels flagged from Step 1 for a capped test (DFA exponent > 1.2) ---
SELECT ent, round(dfa_alpha, 3) AS dfa_alpha
  FROM abr_prof WHERE dfa_alpha > 1.2 ORDER BY dfa_alpha DESC;
.print --- the shipped agent: optimizer + reasoned rationale, one call (reasoning plugin) ---
SELECT json_extract(j, '$.allocation') AS allocation,
       json_extract(j, '$.sharpe')     AS sharpe,
       json_extract_string(j, '$.rationale') AS rationale
FROM (SELECT fractal_agent_allocate(
    (SELECT list(round(p.mean_v / 100.0, 4) ORDER BY p.pid) FROM abr_prof p),
    (SELECT list(CASE WHEN a.pid = b.pid THEN round(a.var_v * a.dfa_alpha / 100.0, 4) ELSE 0::float8 END
                 ORDER BY a.pid, b.pid)
       FROM abr_prof a CROSS JOIN abr_prof b),
    3, '{"portfolio": "budget-reallocation"}') AS j);

.print
.print === 4. Dispatch each journey to a routing model ===
DROP TABLE IF EXISTS abr_models;
CREATE TABLE abr_models (
    id INTEGER PRIMARY KEY,
    label text,
    vec float8[4]
);
INSERT INTO abr_models (id, label, vec) VALUES
    (1, 'single-step', [0.95, 0.2, 0.1, 0.1]),
    (2, 'time-decay', [0.3, 0.95, 0.2, 0.15]),
    (3, 'mid-path-weighted', [0.2, 0.3, 0.9, 0.2]),
    (4, 'cross-device', [0.35, 0.4, 0.45, 0.95]);
DROP TABLE IF EXISTS abr_events;
CREATE TABLE abr_events (
    id INTEGER PRIMARY KEY,
    label text,
    vec float8[4]
);
INSERT INTO abr_events (id, label, vec) VALUES
    (1, 'J1 one-step direct path', [0.92, 0.15, 0.1, 0.1]),
    (2, 'J2 week-long path, recent contact', [0.3, 0.92, 0.2, 0.15]),
    (3, 'J3 multi-channel path, mid-touch heavy', [0.2, 0.3, 0.88, 0.2]),
    (4, 'J4 cross-device path', [0.35, 0.4, 0.45, 0.92]),
    (5, 'J5 direct return visit', [0.9, 0.25, 0.1, 0.12]);
DROP TABLE IF EXISTS abr_routed;
CREATE TABLE abr_routed AS
SELECT r.id AS req_id, r.label, json_extract_string(r.a, '$.routed_to') AS routed_to,
       round(json_extract(r.a, '$.confidence')::double, 4) AS confidence,
       json_extract(r.a, '$.remaining_budget')::INTEGER AS remaining_budget
FROM (SELECT id, label, fractal_agent_route_task(vec, 'abr_models', 'vec', 'label', 1000) AS a
        FROM abr_events) r
ORDER BY r.id;

SELECT req_id, label, routed_to, confidence, remaining_budget FROM abr_routed ORDER BY req_id;

.print
.print === 5. Reasoning: reallocation rationale ===
SELECT fractal_reason(
    'one-line rationale for this cross-channel budget reallocation and the capped test on the surging channel',
    json_object('surging_channel', (SELECT ent FROM abr_prof ORDER BY dfa_alpha DESC LIMIT 1), 'top_dfa', (SELECT max(dfa_alpha) FROM abr_prof), 'journeys_routed', (SELECT count(*) FROM abr_routed))::VARCHAR) AS narrative;

.print
.print === 6. Headline check ===
.mode list
.headers off
SELECT 'HEADLINE kit=agentic-budget-reallocation ' || CASE WHEN
    (SELECT dfa_alpha FROM abr_prof WHERE ent = 'channel-d') > 1.2
    AND (SELECT count(*) FROM abr_prof WHERE dfa_alpha > 1.2) = 1
    AND (SELECT count(*) FROM abr_routed) = 5
    AND (SELECT routed_to FROM abr_routed WHERE req_id = 1) = 'single-step'
    AND (SELECT routed_to FROM abr_routed WHERE req_id = 4) = 'cross-device'
  THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE abr_outcome, abr_prof, abr_result, abr_models, abr_events, abr_routed;
