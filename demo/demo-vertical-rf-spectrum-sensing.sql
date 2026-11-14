-- demo/demo-vertical-rf-spectrum-sensing.sql
--
-- Industry vertical: RF and signal-interference monitoring -- spectrum
-- sensing for telecom operators, spectrum regulators, satellite ground
-- stations and any site that must notice when a carrier, a beacon or a
-- telemetry link loses its structure (interference, jamming, a failing
-- transmitter).  DOMAIN kit showcasing the short-time spectral entropy
-- primitive, fractal_spectrogram_entropy, composed with the periodogram
-- and change-point localization:
--
--   * fractal_periodogram -- WHICH frequencies dominate a whole capture.
--   * fractal_spectrogram_entropy -- HOW ORDERED the spectrum is, window
--     by window: low = energy in a few frequencies (a beacon, a locked
--     carrier), high = spread across the band (noise, jamming).
--   * fractal_change_point_detect -- WHEN the order changed, taken
--     straight from the entropy series (the function returns a plain
--     DOUBLE[], so it feeds the next call as-is).
--
-- Prerequisites: extension installed.  Everything except the closing
-- fractal_reason() runs with no model at all (raw primitives); the
-- narrative needs the reasoning plugin (docs/reasoning-setup.md).
--
-- Run:
--   { echo "LOAD '/path/to/fractalsql.v1.5.6.<platform>.duckdb_extension';"; cat demo/demo-vertical-rf-spectrum-sensing.sql; } \
--       | duckdb -unsigned
--
-- Safe to re-run: rfs_* tables and macros are dropped and recreated each
-- time.
--
-- Notes:
--   * Fully deterministic fixture: the noise is a closed-form hash of the
--     sample index (rfs_noise), not random().  The capture is also
--     available as a pure expression (rfs_level), which is what lets
--     Section 2 hand fractal_periodogram -- a table function, which takes
--     constant arguments rather than subqueries -- the same samples the
--     table holds.
--   * Three channels x 256 samples of received level.  CH-A is a beacon
--     (a period-8 tone plus a little noise) that is JAMMED from sample
--     161: the tone is replaced by wideband noise.  CH-B is steady noise
--     (an empty channel).  CH-C is a steady period-16 telemetry carrier.
--   * Calibration: a pure tone reads about 0.2-0.4 after the Hann taper,
--     white noise about 0.9 (a noise periodogram is itself randomly
--     distributed, so it does not reach 1.0).  Window 32 / hop 16 gives
--     15 frames per channel; boundary indices are FRAME indices, so
--     sample position = frame_index * hop.

.print === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Capture: 3 channels x 256 samples.  Channel 1 = CH-A, 2 = CH-B,
-- 3 = CH-C inside the macros.
-- ------------------------------------------------------------------
.print
.print === 1. Capture: 3 channels x 256 samples ===

CREATE OR REPLACE MACRO rfs_noise(ch, t) AS
    2 * (sin(t * 12.9898 + ch * 78.233) * 43758.5453
         - floor(sin(t * 12.9898 + ch * 78.233) * 43758.5453)) - 1;

CREATE OR REPLACE MACRO rfs_level(ch, t) AS
    round(CASE ch
            WHEN 1 THEN CASE WHEN t <= 160 THEN sin(2 * pi() * t / 8.0) + 0.1 * rfs_noise(ch, t)
                             ELSE 1.2 * rfs_noise(ch, t) END
            WHEN 2 THEN 1.2 * rfs_noise(ch, t)
            ELSE sin(2 * pi() * t / 16.0) + 0.1 * rfs_noise(ch, t)
          END, 5);

DROP TABLE IF EXISTS rfs_capture;
CREATE TABLE rfs_capture (
    channel text,
    seq     int,
    level   float8,
    PRIMARY KEY (channel, seq)
);

INSERT INTO rfs_capture (channel, seq, level)
SELECT 'CH-' || chr((64 + ch)::INTEGER), t, rfs_level(ch, t)
FROM generate_series(1, 3) AS c(ch), generate_series(1, 256) AS s(t);

SELECT channel, count(*) AS samples FROM rfs_capture GROUP BY channel ORDER BY channel;

-- ------------------------------------------------------------------
-- 2. Which frequencies dominate each channel (periodogram).  freq is
-- cycles per sample; 1/freq is samples per cycle.  CH-A is polluted by
-- its jammed second half but still shows the 1/8 beacon; CH-B has no
-- dominant line; CH-C is the 1/16 carrier.
-- ------------------------------------------------------------------
.print
.print === 2. Dominant frequency per channel (fractal_periodogram) ===

SELECT 'CH-A' AS channel, round(freq, 4) AS top_freq, round(1.0 / freq, 1) AS samples_per_cycle
  FROM fractal_periodogram([rfs_level(1, t) for t in range(1, 257)], 1)
UNION ALL
SELECT 'CH-B', round(freq, 4), round(1.0 / freq, 1)
  FROM fractal_periodogram([rfs_level(2, t) for t in range(1, 257)], 1)
UNION ALL
SELECT 'CH-C', round(freq, 4), round(1.0 / freq, 1)
  FROM fractal_periodogram([rfs_level(3, t) for t in range(1, 257)], 1)
ORDER BY channel;

-- ------------------------------------------------------------------
-- 3. How ordered is each channel, window by window
-- (fractal_spectrogram_entropy: window 32, hop 16 -> 15 frames).
-- ------------------------------------------------------------------
.print
.print === 3. Per-frame spectral entropy (fractal_spectrogram_entropy) ===

DROP TABLE IF EXISTS rfs_entropy;
CREATE TABLE rfs_entropy AS
SELECT channel,
       fractal_spectrogram_entropy(list(level ORDER BY seq), 32, 16) AS ent
  FROM rfs_capture GROUP BY channel;

SELECT channel, len(ent) AS frames,
       round(list_min(ent), 3) AS min_entropy,
       round(list_max(ent), 3) AS max_entropy,
       round(list_avg(ent), 3) AS mean_entropy
FROM rfs_entropy ORDER BY channel;

.print --- CH-A frame by frame: ordered, then jammed ---
SELECT u.frame, u.frame * 16 AS first_sample, round(u.entropy, 3) AS entropy
FROM (SELECT unnest(ent) AS entropy, generate_subscripts(ent, 1) - 1 AS frame
        FROM rfs_entropy WHERE channel = 'CH-A') u
ORDER BY u.frame;

-- ------------------------------------------------------------------
-- 4. When did CH-A lose its structure?  fractal_change_point_detect on
-- the entropy series (window 3 frames, threshold 8.0 pooled-stddev
-- units).  The jam begins at sample 161; frame 9 (samples 144-175) is the
-- first to contain it, and that is the boundary reported.  A clean
-- channel's entropy series is nearly constant, so its pooled standard
-- deviation is tiny and a low threshold would flag measurement jitter --
-- keep the threshold high for entropy series.
-- ------------------------------------------------------------------
.print
.print === 4. Where the order changed (change-point on the entropy series) ===

SELECT channel, fractal_change_point_detect(ent, 3, 8.0, 16) AS change_points
FROM rfs_entropy ORDER BY channel;

-- ------------------------------------------------------------------
-- 5. Reasoning: the interference triage narrative (needs the reasoning
-- plugin).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: interference triage ===

SELECT fractal_reason(
    'one-line RF interference triage: which channel lost its structure, when, and the likely cause',
    json_object(
      'ch_a_entropy',       (SELECT ent FROM rfs_entropy WHERE channel = 'CH-A'),
      'ch_a_change_points', (SELECT fractal_change_point_detect(ent, 3, 8.0, 16)
                               FROM rfs_entropy WHERE channel = 'CH-A'),
      'ch_b_mean_entropy',  (SELECT round(list_avg(ent), 3)
                               FROM rfs_entropy WHERE channel = 'CH-B'))::VARCHAR) AS triage;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE rfs_capture, rfs_entropy;
