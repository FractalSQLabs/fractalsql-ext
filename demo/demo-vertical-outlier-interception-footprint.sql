-- demo/demo-vertical-outlier-interception-footprint.sql
--
-- Industry vertical: Automated-traffic interception: bot-farm and
-- invalid-traffic screening. DOMAIN kit: Screens proposed traffic sessions
-- against a history of known-abuse signatures with
-- `fractal_agent_outlier_intercept` (cosine by default, exact Euclidean
-- when magnitude should count), then uses `fractal_dimension_boxcount` on
-- click-coordinate clouds: organic traffic fills the page (a high
-- box-counting dimension) while an automated farm hammering a handful of
-- targets collapses onto a line (a dimension near 1).
--
--   1. fractal_agent_outlier_intercept: hold sessions that sit near a known
--      bot-farm signature.
--   2. The same screen under exact Euclidean distance (threshold 0.30),
--      where magnitude matters.
--   3. fractal_dimension_boxcount: the topological footprint of each
--      traffic source's click map.
--   4. A closing fractal_reason() writes the hold / release justification.
--
-- Prerequisites: LOAD 'fractalsql.duckdb_extension'; (the agents ship
-- inside the extension). The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.<platform>.duckdb_extension';"; cat demo/demo-vertical-outlier-interception-footprint.sql; } \
--       | duckdb -unsigned
--
-- Safe to re-run: oif_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Session signature = [click velocity, IP-pool concentration, device
--     reuse, headless-UA ratio, geo mismatch].
--   * Click maps are 200 points each in the unit square: an organic spread
--     vs a collinear farm pattern.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=outlier-interception-footprint ok);
--     the build_test kit gate greps for it.

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

.print
.print === 1. Known abuse signatures + proposed traffic sessions ===
DROP TABLE IF EXISTS oif_known;
CREATE TABLE oif_known (
    id INTEGER PRIMARY KEY,
    label text,
    vec float8[5]
);
INSERT INTO oif_known (id, label, vec) VALUES
    (1, 'automated farm: one device pool, burst requests', [0.95, 0.9, 0.85, 0.1, 0.2]),
    (2, 'datacenter bot traffic, headless browsers', [0.9, 0.05, 0.3, 0.95, 0.4]),
    (3, 'residential-proxy request spoofing', [0.05, 0.05, 0.1, 0.1, 0.95]),
    (4, 'request-stacking ring', [0.1, 0.8, 0.9, 0.85, 0.3]);
DROP TABLE IF EXISTS oif_proposed;
CREATE TABLE oif_proposed (
    id INTEGER PRIMARY KEY,
    label text,
    vec float8[5]
);
INSERT INTO oif_proposed (id, label, vec) VALUES
    (1, 'T1 burst requests from a shared device pool', [0.92, 0.88, 0.8, 0.12, 0.18]),
    (2, 'T2 organic referral session', [0.02, 0, 0.05, 0, 0.05]),
    (3, 'T3 returning user on a new device', [0, 0.02, 0.7, 0.04, 0.05]),
    (4, 'T4 faint headless traffic, far geo', [0.4, 0.02, 0.12, 0.42, 0.16]);

.print
.print === 2. fractal_agent_outlier_intercept (cosine, threshold 0.10) ===
DROP TABLE IF EXISTS oif_screen;
CREATE TABLE oif_screen AS
SELECT id, label, (json_extract_string(o, '$.intercepted') = 'true')::INTEGER AS intercepted, 'cosine' AS metric
FROM (SELECT id, label, fractal_agent_outlier_intercept(vec, 'oif_known', 'vec', 0.1) AS o
        FROM oif_proposed)
ORDER BY id;

SELECT id, label, intercepted, metric FROM oif_screen ORDER BY id;

.print
.print === 3. Same screen under exact Euclidean distance (threshold 0.30) ===
DROP TABLE IF EXISTS oif_screen_l2;
CREATE TABLE oif_screen_l2 AS
SELECT id, label, (json_extract_string(o, '$.intercepted') = 'true')::INTEGER AS intercepted, 'l2' AS metric
FROM (SELECT id, label, fractal_agent_outlier_intercept(vec, 'oif_known', 'vec', 0.3, 'l2') AS o
        FROM oif_proposed)
ORDER BY id;

SELECT id, label, intercepted, metric FROM oif_screen_l2 ORDER BY id;

.print
.print === 4. Click-map topology: organic traffic vs an automated farm ===
DROP TABLE IF EXISTS oif_clicks;
CREATE TABLE oif_clicks (
    ent text,
    pt  int,
    x   float8,
    y   float8
);
INSERT INTO oif_clicks (ent, pt, x, y)
SELECT ent, g, ((g * 37) % 100) / 100.0, CASE WHEN p1 = 1 THEN ((g * 61) % 100) / 100.0 ELSE ((g * 37) % 100) / 200.0 + 0.002 * (g % 5) END
FROM (VALUES ('organic-source', 1),
             ('farm-ring', 0)) AS s(ent, p1),
     generate_series(1, 200) AS gs(g);
DROP TABLE IF EXISTS oif_dim;
CREATE TABLE oif_dim AS
SELECT ent, round(fractal_dimension_boxcount(flatten(list([x, y] ORDER BY pt)), 2), 3) AS dim
FROM oif_clicks GROUP BY ent ORDER BY ent;

SELECT ent, dim FROM oif_dim ORDER BY ent;

.print
.print === 5. Reasoning: hold / release justification ===
SELECT fractal_reason(
    'one-line justification for holding the flagged traffic and the topology evidence for an automated farm',
    json_object('held_session', (SELECT label FROM oif_screen WHERE id = 1), 'farm_dimension', (SELECT dim FROM oif_dim WHERE ent = 'farm-ring'), 'organic_dimension', (SELECT dim FROM oif_dim WHERE ent = 'organic-source'))::VARCHAR) AS narrative;

-- The demo's own claims, recomputed from the demo's own tables: the
-- screen holds the shared-device-pool session (T1) and the faint
-- headless session (T4) and leaves the organic referral (T2) and the
-- returning-user session (T3) alone; the same screen under exact
-- Euclidean distance still holds T1 -- the one session that really
-- does sit on a known signature -- but no longer holds T4, whose
-- magnitude is too far off to matter; and the automated farm's click
-- map covers a smaller area than the organic source's -- a handful of
-- repeated targets against a page-filling spread.
.print
.print === 6. Headline check ===
.mode list
.headers off
SELECT 'HEADLINE kit=outlier-interception-footprint ' || CASE WHEN
    (SELECT intercepted FROM oif_screen WHERE id = 1) = 1
    AND (SELECT intercepted FROM oif_screen WHERE id = 2) = 0
    AND (SELECT intercepted FROM oif_screen WHERE id = 3) = 0
    AND (SELECT intercepted FROM oif_screen WHERE id = 4) = 1
    AND (SELECT count(*) FROM oif_screen) = 4
    AND (SELECT intercepted FROM oif_screen_l2 WHERE id = 1) = 1
    AND (SELECT intercepted FROM oif_screen_l2 WHERE id = 2) = 0
    AND (SELECT intercepted FROM oif_screen_l2 WHERE id = 4) = 0
    AND (SELECT count(*) FROM oif_dim) = 2
    AND (SELECT dim FROM oif_dim WHERE ent = 'farm-ring') + 0.3
        < (SELECT dim FROM oif_dim WHERE ent = 'organic-source')
  THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE oif_known;
.print   DROP TABLE oif_proposed;
.print   DROP TABLE oif_screen;
.print   DROP TABLE oif_screen_l2;
.print   DROP TABLE oif_clicks;
.print   DROP TABLE oif_dim;
.print (one DROP per statement -- DuckDB's DROP TABLE takes exactly one table.)
