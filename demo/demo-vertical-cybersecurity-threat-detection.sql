-- demo/demo-vertical-cybersecurity-threat-detection.sql
--
-- Industry vertical: Cybersecurity & Threat Detection (network behavior
-- analytics / SOC log analysis).
--
-- A 35-host fleet across three network zones, each with a BASELINE
-- traffic-behavior vector and a CURRENT (recent window) vector. One
-- host goes quiet-then-beacons: a compromise pattern (outbound
-- connection volume, unique destination ports, and DNS query rate all
-- spike; failed-auth rate barely moves -- this isn't a brute-force
-- attempt, it's a stealthier C2 beaconing profile). Diverse
-- traffic-profile clustering for threat hunting, a zone-restricted
-- search, current-vs-baseline drift detection, connection-rate
-- regime-change detection via DFA, and a periodogram over the
-- post-shift traffic isolating the beacon interval itself.
--
-- Prerequisites: extension installed. Sections 2 and 5 dispatch reasoning
-- through the domain agents (the raw forms alongside them run without an
-- endpoint) -- see ../docs/reasoning-setup.md.
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; cat demo/demo-vertical-cybersecurity-threat-detection.sql; } \
--       | duckdb -bail -unsigned
--
-- Safe to re-run: vcy_* tables are dropped and recreated each time.

-- Notes:
--   * HOST-7 (id 7, dmz zone) is the fleet's ONE compromised host: its
--     current vector sits 1.22 (L2) off its baseline -- outbound
--     connections, unique destination ports and DNS query rate all spike
--     while failed-auth barely moves -- and every other host stays inside
--     the ~0.06 ordinary-traffic noise band.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=cybersecurity-threat-detection ok);
--     the build_test kit gate greps for it.

-- (Timing is omitted -- DuckDB's CLI has no per-statement
-- timing dot-command; measure latency at the harness level, e.g.
-- demo/demo-workload.sh.)
-- The fixture generator: an LCG with xor-shift rounds over pure integer
-- arithmetic, so every draw is exactly the same everywhere.
--
-- random() would not do: setseed() seeds only the engine of the thread
-- that called it, and every other DuckDB worker thread runs its own
-- random() stream, so a fixture query DuckDB spreads over several
-- threads hands each row a value from a different stream -- and the
-- host fleet came out different on a different machine. Deriving every
-- draw from the row id instead makes the fixture a pure function of the
-- data: the same fleet on every machine, core count and DuckDB build.
-- The xor-shift rounds are not decoration: a plain LCG is AFFINE in
-- its seed, so two seeds one apart differ by a CONSTANT amount --
-- "separate" dimensions drawn from adjacent seeds came out as mirror
-- images of each other, and a 2-D walk built that way collapses onto a
-- line. The xor-shift breaks that affinity, so neighbouring seeds give
-- genuinely unrelated draws.
CREATE OR REPLACE MACRO vcy_lcg(s) AS ((((s::BIGINT * 1103515245::BIGINT) + 12345) % 2147483648));
CREATE OR REPLACE MACRO vcy_xs(a, sh) AS (xor(a, a >> sh));
CREATE OR REPLACE MACRO vcy_mix(s) AS (vcy_xs(vcy_lcg(vcy_xs(vcy_lcg(s), 13)), 17));
CREATE OR REPLACE MACRO vcy_rand(s) AS (vcy_mix(s)::DOUBLE / 2147483648.0);

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 35 hosts across 3 zones (dmz, internal, guest), each with a
-- BASELINE behavior vector (normal traffic profile) and a CURRENT
-- vector (this window's telemetry). Fields, in order:
-- [outbound_conn_rate, unique_dest_ports, dns_query_rate,
-- failed_auth_rate], each normalized to roughly [-1, 1]. Host 7 gets
-- a deliberate compromise pattern -- everyone else's current stays
-- close to baseline (ordinary traffic noise).
-- ------------------------------------------------------------------
.print
.print === 1. 35 hosts: baseline vs. current network-behavior vectors ===

DROP TABLE IF EXISTS vcy_hosts;
DROP SEQUENCE IF EXISTS seq_vcy_hosts_id;
CREATE SEQUENCE seq_vcy_hosts_id;
CREATE TABLE vcy_hosts (
    id       INTEGER PRIMARY KEY DEFAULT nextval('seq_vcy_hosts_id'),
    hostname text,
    zone     text,
    -- float8[4], not a fractal_vector catalog type -- this build has none
    -- (see docs/api-analytics.md).
    -- float8/DOUBLE, not float4: these columns only ever feed
    -- fractal_search_trajectory/fractal_agent_track_anomaly below, both
    -- DOUBLE-based, never a fractal_vector_* arithmetic primitive.
    -- Fixed-width for the same reason as demo-vertical-medtech-
    -- clinical.sql's vitals and demo-vertical-maritime-defense.sql's
    -- baseline/current: a feature-extraction bug that silently changed
    -- the vector's width should be a hard write-time error, not a
    -- corrupted search corpus.
    baseline float8[4],
    current  float8[4]
);

-- INSERT is UNCHANGED (still literal ::float8[] values) -- the
-- assignment cast handles coercion into the float8[4] columns
-- automatically, same as the other three verticals below.
--
-- The id is written out rather than left to the column's DEFAULT
-- nextval: a sequence hands out its values in the order the rows are
-- physically inserted, and DuckDB does not insert them in the order
-- generate_series produces them. The id is this demo's handle on a
-- host -- "host 7" means the row whose id is 7 -- so it is written
-- from the same series that names the host, and the two always agree.
INSERT INTO vcy_hosts (id, hostname, zone, baseline, current)
SELECT gs, 'HOST-' || gs,
       (ARRAY['dmz', 'internal', 'guest'])[((gs - 1) % 3) + 1],
       ARRAY[b1, b2, b3, b4]::float8[],
       ARRAY[b1 + (vcy_rand(gs*10+5)-0.5)*0.06, b2 + (vcy_rand(gs*10+6)-0.5)*0.06,
             b3 + (vcy_rand(gs*10+7)-0.5)*0.06, b4 + (vcy_rand(gs*10+8)-0.5)*0.06]::float8[]
FROM generate_series(1, 35) gs(gs),
     LATERAL (SELECT vcy_rand(gs*10+1)*2-1, vcy_rand(gs*10+2)*2-1,
                     vcy_rand(gs*10+3)*2-1, vcy_rand(gs*10+4)*2-1) AS bl(b1, b2, b3, b4);

-- Host 7's deliberate compromise: outbound connections, destination
-- ports, and DNS query volume all spike; failed-auth barely moves.
-- Explicit ::float8[] cast before per-element subscripting, even
-- though baseline is already float8[4] -- kept for consistency with
-- the other verticals below rather than relying on ARRAY subscripting
-- directly (same pattern as
-- demo-vertical-maritime-defense.sql's vessel-7 UPDATE), then let the
-- assignment cast coerce the result back on write.
UPDATE vcy_hosts
   SET current = ARRAY[(baseline::float8[])[1] + 0.8, (baseline::float8[])[2] + 0.7,
                        (baseline::float8[])[3] + 0.6, (baseline::float8[])[4] + 0.05]::float8[]
 WHERE id = 7;

-- ------------------------------------------------------------------
-- 2. Scout Discovery: diverse traffic-profile clustering across the
-- fleet -- threat hunting ("what KINDS of behavior profiles are
-- actually running right now") instead of cosine top-K, which would
-- just return 6 near-duplicates of whichever profile is most common
-- and miss the one host that looks different.
-- ------------------------------------------------------------------
.print
.print === 2. Diverse traffic-profile clustering (threat hunting) ===
.print --- raw explore form (query-agnostic -- explore samples the space) ---

-- Blueprint (raw primitive): returns a diverse representative set of the
-- fleet's traffic-profile embeddings -- surfaces the one host that looks
-- different instead of K near-duplicates of the most common profile.
SELECT particle FROM fractal_search_explore(
    'vcy_hosts', 'current', ARRAY[0,0,0,0]::float8[],
    '{"population_size": 6, "iterations": 8, "walk": 0}'
);

-- Productized preset: the shipped engine (a scalar returning one JSON
-- document -- an array of {item_id, score} rows, score = 1 -
-- cosine_distance) enables session-global repulsion on the shared engine
-- context, then leaves it on (the caller owns that policy). The raw
-- explore above is query-agnostic (explore samples the space); the
-- telemetry form is query-anchored, so anchor on the first host's own
-- current vector. There is no SQL toggle for the engine context (the
-- registered fractal_diversify_disable() acts on the ledger's own
-- context, a different session) -- but the disable below resets that
-- ledger context all the same, and the section-3 telemetry top-k here is
-- deliberately a literal, repulsion-unadjusted nearest list regardless
-- (see the recommendation-search vertical's section 4 scoping note).
.print --- recommend_diverse composition (query-anchored, repulsion on) ---
SELECT fractal_agent_recommend_diverse(
    'vcy_hosts', 'current',
    (SELECT current::float8[] FROM vcy_hosts ORDER BY id LIMIT 1),
    6, 'id');
-- Table-function args are constant-only in DuckDB, so the probe vector
-- spools through the .once/.read idiom (demo-agents.sql 13a):
.mode list
.headers off
.output vcy_tel.sql
SELECT 'SELECT doc_id, distance FROM fractal_search_telemetry(''vcy_hosts'', ''current'', ' ||
       (SELECT current FROM vcy_hosts ORDER BY id LIMIT 1)::VARCHAR ||
       ', 6) ORDER BY distance ASC;'
;
.output stdout
.mode box
.headers on
.read vcy_tel.sql
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 3. Zone-restricted search: "DMZ hosts only" -- fractal_search_
-- telemetry's table_name argument is a plain text table name, so a
-- zone filter composes by searching a filtered temp table instead
-- (the same cohort-then-search shape fractal_hybrid_clinical_search
-- uses internally for its doc_ids allowlist, without needing that
-- clinically-named function here -- same composition
-- demo-vertical-fleet-logistics.sql uses for its route-3 cohort).
--
-- doc_id here is DuckDB's `rowid` pseudocolumn, stringified (see
-- docs/api-agency.md (the corpus scan)/fractal_search_
-- telemetry). rowid is the stable-enough locator this build uses; it
-- can shift under operations that rewrite the table, so treat doc_id
-- as ephemeral -- map doc_id back to hostname via a direct rowid
-- predicate below rather than assuming doc_id + 1 = id.
-- ------------------------------------------------------------------
.print
.print === 3. Zone-restricted search: DMZ hosts only ===

-- A real table, not TEMP: the agent surfaces scan through a side
-- connection, which cannot see the connection-private TEMP schema.
DROP TABLE IF EXISTS vcy_dmz_cohort;
CREATE TABLE vcy_dmz_cohort AS
SELECT * FROM vcy_hosts WHERE zone = 'dmz';

SELECT h.hostname, t.distance
FROM fractal_search_telemetry('vcy_dmz_cohort', 'current',
                              ARRAY[0.3, 0.3, 0.3, 0.0]::float8[], 5) t
JOIN vcy_dmz_cohort h ON h.rowid::text = t.doc_id
ORDER BY t.distance;

-- ------------------------------------------------------------------
-- 4. fractal_search_trajectory: current vs. baseline DELTA for host 7
-- -- "what changed" rather than "what's closest", the direct fit for
-- compromise/beaconing detection. host7.baseline/host7.current are
-- plain float8[4] values -- there's only one fractal_search_trajectory
-- overload in this build (no fractal_vector type to overload on).
--
-- Same doc_id-vs-id caveat as section 3 above -- map via rowid, not
-- id - 1 (see that section's comment for why).
-- ------------------------------------------------------------------
.print
.print === 4. Host 7's drift vs. the fleet (fractal_search_trajectory) ===

-- The current-vs-baseline DELTA search for host 7's compromise drift --
-- "what changed" rather than "what's closest", the direct fit for
-- compromise/beaconing detection. Same doc_id-vs-id caveat as section 3:
-- trajectory's doc_id is the 0-INDEXED scan position, mapped back to the
-- host rows through rowid order. Generalized by the shipped
-- fractal_agent_track_anomaly preset in Section 5, which folds this
-- trajectory search together with the connection-rate DFA and a
-- reasoning step.
-- Table-function args are constant-only in DuckDB, so the two
-- subquery-built vectors roundtrip through the .once/.read spool (the
-- demo-agents.sql 13a idiom):
.mode list
.headers off
.output vcy_traj.sql
SELECT 'SELECT h.hostname, h.zone, t.distance FROM fractal_search_trajectory(''vcy_hosts'', ''current'', ' ||
       (SELECT baseline FROM vcy_hosts WHERE id = 7)::VARCHAR ||
       ', ' || (SELECT current FROM vcy_hosts WHERE id = 7)::VARCHAR ||
       ', 5) t JOIN (SELECT id, hostname, zone, row_number() OVER (ORDER BY rowid) - 1 AS doc_id FROM vcy_hosts) h ON h.doc_id = t.doc_id ORDER BY t.distance;'
;
.output stdout
.mode box
.headers on
.read vcy_traj.sql

-- ------------------------------------------------------------------
-- 5. fractal_dimension_dfa / fractal_dimension_drift: host 7's
-- connections-per-minute series over the last 300 minutes, with a
-- deliberate regime change at t=220 -- low-amplitude noisy baseline
-- traffic, then a shift to a regular, higher-frequency beaconing
-- interval. DFA's scaling exponent picks up the change in long-range
-- structure; fractal_dimension_drift makes the same point directly by
-- comparing the tail window against everything before it.
-- ------------------------------------------------------------------
.print
.print === 5. fractal_dimension_dfa / drift: host 7 connection-rate regime change ===

DROP TABLE IF EXISTS vcy_conn_series;
CREATE TEMP TABLE vcy_conn_series AS
SELECT t,
       CASE WHEN t < 220
            THEN 4.0 + 1.5 * sin(t * 0.31) + (vcy_rand(1000 + t)-0.5) * 0.8
            ELSE 4.0 + 3.0 * sin(t * 1.4)  + (vcy_rand(1000 + t)-0.5) * 0.4
       END AS conn_rate
FROM generate_series(1, 300) t(t);

-- fractal_agent_regime_triage and fractal_agent_track_anomaly are 2 of
-- the 16 NAMED domain agents, registered with the extension itself. The
-- raw-primitive forms they compose run here first (the trajectory search
-- ran in Section 4 above):
SELECT fractal_dimension_dfa(
    (SELECT array_agg(conn_rate ORDER BY t) FROM vcy_conn_series)
) AS full_series_dfa_exponent;

SELECT fractal_dimension_drift(
    (SELECT array_agg(conn_rate ORDER BY t) FROM vcy_conn_series),
    60
) AS recent_60min_vs_history;

-- The shipped presets (scalars returning one JSON document each;
-- regime_triage: {dfa_exponent, drift_detected, recent_alpha,
-- baseline_alpha, rationale}; track_anomaly: {nearest_fleet_id,
-- trajectory_distance, dfa_exponent, rationale}), folding the raw
-- fixtures above into one reasoning step each:
SELECT fractal_agent_regime_triage(
    (SELECT array_agg(conn_rate ORDER BY t) FROM vcy_conn_series),
    64, 0.5);

SELECT fractal_agent_track_anomaly(
    'vcy_hosts', 'current',
    (SELECT baseline::float8[] FROM vcy_hosts WHERE id = 7),
    (SELECT current::float8[]  FROM vcy_hosts WHERE id = 7),
    (SELECT array_agg(conn_rate ORDER BY t) FROM vcy_conn_series),
    5, 'id');

-- ------------------------------------------------------------------
-- 5b. fractal_periodogram: DFA above characterizes the CHANGE in
-- long-range structure at t=220; this characterizes what the post-shift
-- traffic actually IS -- a regular, higher-frequency beaconing interval,
-- the signature C2 checks in for rather than genuinely noisy traffic.
-- Restricted to the post-t=220 window (the beaconing regime itself);
-- run over the whole series the pre-shift noise floor would dilute the
-- peak. Citation: Schuster, A. (1898), "On the investigation of hidden
-- periodicities...", Terrestrial Magnetism -- the classical periodogram,
-- computed here via direct DFT.
-- ------------------------------------------------------------------
.print
.print === 5b. fractal_periodogram: beacon-interval detection, host 7 post-shift traffic ===
-- fractal_periodogram is a TABLE function, and DuckDB table-function
-- arguments cannot contain subqueries -- so the series is spooled
-- through the .output/.read idiom (the demo-agents.sql 13a pattern),
-- with the list literal cast to DOUBLE[] in the generated SQL so it
-- binds to the function's float8[] argument.
.mode list
.headers off
.output vcy_periodogram.sql
SELECT 'SELECT freq, power FROM fractal_periodogram(CAST(' ||
       (SELECT array_agg(conn_rate ORDER BY t) FROM vcy_conn_series WHERE t >= 220)::VARCHAR ||
       ' AS DOUBLE[]), 4) ORDER BY power DESC;'
;
.output stdout
.mode box
.headers on
.read vcy_periodogram.sql

-- ------------------------------------------------------------------
-- 6. Reasoning: the SOC triage narrative for host 7 is now split across
-- the two Section 5 preset rationales -- fractal_agent_track_anomaly
-- (the baseline->current drift + connection-rate DFA) and
-- fractal_agent_regime_triage (the regime change itself).
-- ------------------------------------------------------------------
.print
.print === 6. Reasoning: absorbed into the Section 5 track_anomaly + regime_triage rationales ===

-- ------------------------------------------------------------------
-- 7. Headline check: the demo's own claims, recomputed from the demo's
-- own table and the demo's own series -- HOST-7 is the fleet's ONE large
-- baseline-to-current behavior deviation (a compromise profile: outbound
-- connections, unique destination ports and DNS query rate all spike
-- while failed-auth barely moves), every other host stays inside the
-- ordinary-traffic noise band, host 7 sits in the DMZ cohort, and host
-- 7's connection-rate series really did change regime at t=220.
--
-- Host 7's deviations are the fixed offsets Section 1 writes onto its
-- baseline, so the L2 deviation and the per-signal shape are exact; the
-- noise band around the other hosts and the DFA exponents of the
-- connection series are drawn values, so those are asserted as bands,
-- not as exact figures. The DMZ and trajectory searches are deliberately
-- NOT asserted here -- their orderings follow the drawn vectors.
-- ------------------------------------------------------------------
.print
.print === 7. Headline check ===
.mode list
.headers off
WITH dev AS (
    SELECT id, hostname, zone,
           ("current"::float8[])[1] - (baseline::float8[])[1] AS d1,
           ("current"::float8[])[2] - (baseline::float8[])[2] AS d2,
           ("current"::float8[])[3] - (baseline::float8[])[3] AS d3,
           ("current"::float8[])[4] - (baseline::float8[])[4] AS d4,
           sqrt(pow(("current"::float8[])[1] - (baseline::float8[])[1], 2)
              + pow(("current"::float8[])[2] - (baseline::float8[])[2], 2)
              + pow(("current"::float8[])[3] - (baseline::float8[])[3], 2)
              + pow(("current"::float8[])[4] - (baseline::float8[])[4], 2)) AS drift_l2
    FROM vcy_hosts
),
drift AS (
    SELECT dj.drift, dj.recent_alpha, dj.baseline_alpha
    FROM (SELECT fractal_dimension_drift(
               (SELECT array_agg(conn_rate ORDER BY t) FROM vcy_conn_series),
               60) AS dj)
)
SELECT 'HEADLINE kit=cybersecurity-threat-detection ' || CASE WHEN
         (SELECT count(*) FROM vcy_hosts) = 35
     AND (SELECT count(*) FROM dev WHERE drift_l2 > 0.5) = 1
     AND (SELECT id FROM dev WHERE drift_l2 > 0.5) = 7
     AND (SELECT hostname FROM dev WHERE id = 7) = 'HOST-7'
     AND (SELECT zone FROM dev WHERE id = 7) = 'dmz'
     AND (SELECT drift_l2 FROM dev WHERE id = 7) > 1.2
     AND (SELECT drift_l2 FROM dev WHERE id = 7) < 1.3
     AND (SELECT max(drift_l2) FROM dev WHERE id <> 7) < 0.2
     AND (SELECT d1 FROM dev WHERE id = 7) > 0.5
     AND (SELECT d2 FROM dev WHERE id = 7) > 0.5
     AND (SELECT d3 FROM dev WHERE id = 7) > 0.5
     AND (SELECT d4 FROM dev WHERE id = 7) > 0.0
     AND (SELECT d4 FROM dev WHERE id = 7) < 0.1
     AND (SELECT count(*) FROM vcy_dmz_cohort) = 12
     AND (SELECT count(*) FROM vcy_dmz_cohort WHERE hostname = 'HOST-7') = 1
     AND (SELECT drift FROM drift) < 0
     AND (SELECT abs(drift) FROM drift) > 0.2
     AND (SELECT recent_alpha FROM drift) < (SELECT baseline_alpha FROM drift)
THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vcy_hosts;
.print (the vcy_* TEMP tables evaporate with the connection.)
.print ================================================================
