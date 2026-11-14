-- Parity cases for the analytics part of fsql_sovereign.c. Deterministic generated series.

-- dfa: noise vs a random-walk-ish cumulative series
SELECT fractal_dimension_dfa(list_transform(range(256), lambda i: ((i*7919) % 101) / 101.0 - 0.5));

SELECT fractal_dimension_dfa(list_transform(range(256), lambda i: sin(i * 0.1) * 10.0));

SELECT fractal_dimension_dfa(list_transform(range(10), lambda i: i * 1.0));

SELECT fractal_dimension_dfa([]::DOUBLE[]), fractal_dimension_dfa(NULL::DOUBLE[]);

SELECT fractal_dimension_dfa([1.0, NULL, 3.0]::DOUBLE[]);

-- drift
SELECT fractal_dimension_drift(list_transform(range(400), lambda i: CASE WHEN i < 200 THEN ((i*7919) % 101) / 101.0 ELSE ((i*7919) % 101) / 10.0 + i END), 64);

SELECT d.drift, d.recent_alpha, d.baseline_alpha FROM (SELECT fractal_dimension_drift(list_transform(range(300), lambda i: sin(i * 0.2) * 3.0 + ((i*31) % 17) / 17.0), 32) AS d);

SELECT fractal_dimension_drift(list_transform(range(100), lambda i: i * 1.0), 0);

SELECT fractal_dimension_drift(list_transform(range(100), lambda i: i * 1.0), -5);

SELECT fractal_dimension_drift(list_transform(range(20), lambda i: i * 1.0), 16);

SELECT fractal_dimension_drift(NULL::DOUBLE[], 32), fractal_dimension_drift(list_transform(range(100), lambda i: i * 1.0), NULL);

-- boxcount (points are a flat row-major array)
SELECT fractal_dimension_boxcount(flatten(list_transform(range(20), lambda x: list_transform(range(20), lambda y: [x * 0.05 + (y % 3) * 0.001, y * 0.05])))::DOUBLE[], 2, 1, 1.0);

SELECT fractal_dimension_boxcount(list_transform(range(100), lambda i: i * 0.01), 1);

SELECT fractal_dimension_boxcount([1.0, 2.0, 3.0]::DOUBLE[], 2, 1, 1.0);

SELECT fractal_dimension_boxcount([1.0, 2.0]::DOUBLE[], 0, 1, 1.0);

SELECT fractal_dimension_boxcount([1.0, 2.0]::DOUBLE[], 65, 1, 1.0);

SELECT fractal_dimension_boxcount([1.0, 2.0, 3.0, 4.0]::DOUBLE[], 2, 1, 1.0);

-- change points
SELECT fractal_change_point_detect(list_transform(range(200), lambda i: CASE WHEN i < 100 THEN 0.0 ELSE 10.0 END + (i % 5) * 0.01), 20);

SELECT fractal_change_point_detect(list_transform(range(200), lambda i: CASE WHEN i < 100 THEN 0.0 ELSE 10.0 END + (i % 5) * 0.01), 20, 3.5);

SELECT fractal_change_point_detect(list_transform(range(200), lambda i: CASE WHEN i < 100 THEN 0.0 ELSE 10.0 END + (i % 5) * 0.01), 20, 3.5, 1);

SELECT fractal_change_point_detect(list_transform(range(200), lambda i: i * 0.0), 20);

SELECT fractal_change_point_detect(list_transform(range(200), lambda i: i * 1.0), 0);

SELECT fractal_change_point_detect(list_transform(range(200), lambda i: i * 1.0), 20, 2.0, 0);

SELECT fractal_change_point_detect(list_transform(range(200), lambda i: i * 1.0), 20, 2.0, 65537);

SELECT fractal_change_point_detect(list_transform(range(30), lambda i: i * 1.0), 20);

SELECT fractal_change_point_detect(list_transform(range(200), lambda i: i * 1.0), 20, -1.0);

SELECT fractal_change_point_detect(NULL::DOUBLE[], 20), fractal_change_point_detect([1.0]::DOUBLE[], NULL), fractal_change_point_detect([1.0]::DOUBLE[], 1, NULL::DOUBLE);

-- spectrogram entropy
SELECT fractal_spectrogram_entropy(list_transform(range(512), lambda i: sin(i * 0.3)));

SELECT fractal_spectrogram_entropy(list_transform(range(512), lambda i: ((i*7919) % 101) / 101.0), 32);

SELECT fractal_spectrogram_entropy(list_transform(range(512), lambda i: ((i*7919) % 101) / 101.0), 32, 16);

SELECT len(fractal_spectrogram_entropy(list_transform(range(512), lambda i: sin(i * 0.3)), 32, 16, 5));

SELECT fractal_spectrogram_entropy(list_transform(range(100), lambda i: 1.0), 16, 8);

SELECT fractal_spectrogram_entropy(list_transform(range(100), lambda i: i * 1.0), 7);

SELECT fractal_spectrogram_entropy(list_transform(range(100), lambda i: i * 1.0), 513);

SELECT fractal_spectrogram_entropy(list_transform(range(100), lambda i: i * 1.0), 16, 0);

SELECT fractal_spectrogram_entropy(list_transform(range(100), lambda i: i * 1.0), 16, 8, 0);

SELECT fractal_spectrogram_entropy(list_transform(range(100), lambda i: i * 1.0), 16, 8, 4097);

SELECT fractal_spectrogram_entropy(list_transform(range(10), lambda i: i * 1.0), 16);

SELECT fractal_spectrogram_entropy(NULL::DOUBLE[]), fractal_spectrogram_entropy([1.0]::DOUBLE[], NULL);

-- periodogram (table function)
SELECT * FROM fractal_periodogram(list_transform(range(128), lambda i: sin(i * 2 * pi() * 0.125)), 8);

SELECT * FROM fractal_periodogram(list_transform(range(128), lambda i: sin(i * 2 * pi() * 0.125) + 0.5 * sin(i * 2 * pi() * 0.3)), 3);

SELECT count(*) FROM fractal_periodogram(list_transform(range(128), lambda i: ((i*7919) % 101) / 101.0), 4096);

SELECT * FROM fractal_periodogram([1.0, 2.0]::DOUBLE[], 8);

SELECT * FROM fractal_periodogram(list_transform(range(16), lambda i: i * 1.0), 0);

SELECT * FROM fractal_periodogram(list_transform(range(16), lambda i: i * 1.0), 4097);

SELECT * FROM fractal_periodogram(list_transform(range(16385), lambda i: i * 1.0), 8);

SELECT * FROM fractal_periodogram(NULL::DOUBLE[], 8);

SELECT * FROM fractal_periodogram([1.0, NULL, 3.0, 4.0]::DOUBLE[], 8);

SELECT * FROM fractal_periodogram(list_transform(range(16), lambda i: i * 1.0), NULL);

-- overload resolution for the table function, and use in a join
SELECT count(*) FROM fractal_periodogram(list_transform(range(64), lambda i: sin(i * 0.5)), 8) p, fractal_periodogram(list_transform(range(64), lambda i: sin(i * 0.5)), 2) q;

-- tda persistence diagram: two clusters
SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0, 5.1,5.0, 5.0,5.1]::DOUBLE[], 2, 1, 1.0);

SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0, 5.1,5.0, 5.0,5.1]::DOUBLE[], 2, 0, 1.0);

SELECT t.betti1 IS NULL, len(t.h0_bars) FROM (SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0]::DOUBLE[], 2, 0, 1.0) AS t);

SELECT fractal_tda_persistence_diagram([0.0,0.0, 1.0,0.0, 1.0,1.0, 0.0,1.0]::DOUBLE[], 2, 1, 1.5);

SELECT fractal_tda_persistence_diagram([0.0,0.0, 1.0,0.0, 1.0,1.0, 0.0,1.0]::DOUBLE[], 2, 1, 1.5, 2);

SELECT UNNEST(t.h0_bars) FROM (SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0]::DOUBLE[], 2, 1, 1.0) AS t);

SELECT fractal_tda_persistence_diagram([0.0,0.0, 1.0,1.0]::DOUBLE[], 0, 1, 1.0);

SELECT fractal_tda_persistence_diagram([0.0,0.0, 1.0,1.0]::DOUBLE[], 65, 1, 1.0);

SELECT fractal_tda_persistence_diagram([0.0,0.0, 1.0,1.0, 2.0]::DOUBLE[], 2, 1, 1.0);

SELECT fractal_tda_persistence_diagram([0.0,0.0, 1.0,1.0]::DOUBLE[], 2, 2, 1.0);

SELECT fractal_tda_persistence_diagram([0.0,0.0, 1.0,1.0]::DOUBLE[], 2, 1, 0.0);

SELECT fractal_tda_persistence_diagram([0.0,0.0, 1.0,1.0]::DOUBLE[], 2, 1, 'nan'::DOUBLE);

SELECT fractal_tda_persistence_diagram([0.0,0.0, 1.0,1.0]::DOUBLE[], 2, 1, 1.0, 0);

SELECT fractal_tda_persistence_diagram([0.0,0.0]::DOUBLE[], 2, 1, 1.0);

SELECT fractal_tda_persistence_diagram(NULL::DOUBLE[], 2, 1, 1.0), fractal_tda_persistence_diagram([0.0,0.0, 1.0,1.0]::DOUBLE[], NULL, 1, 1.0);

-- many rows across chunks
CREATE TABLE t AS SELECT i, [i*0.1, 0.0, i*0.1+0.05, 0.1, 5.0, 5.0 + i*0.01]::DOUBLE[] AS p FROM range(1, 3000) x(i);
SELECT count(*), sum(len(fractal_tda_persistence_diagram(p, 2, 0, 1.0).h0_bars)), sum(fractal_tda_persistence_diagram(p, 2, 1, 1.0).betti1) FROM t;

-- state fingerprint
SELECT fractal_state_fingerprint([1.0, 2.0, 3.0]::DOUBLE[]), octet_length(fractal_state_fingerprint([1.0, 2.0, 3.0]::DOUBLE[]));

SELECT fractal_state_fingerprint([1.0, 2.0, 3.0]::DOUBLE[], 64), octet_length(fractal_state_fingerprint([1.0, 2.0, 3.0]::DOUBLE[], 64));

SELECT fractal_state_fingerprint([1.0, 2.0, 3.0]::DOUBLE[], 65, 42.0), octet_length(fractal_state_fingerprint([1.0, 2.0, 3.0]::DOUBLE[], 65, 42.0));

SELECT fractal_state_fingerprint([1.0, 2.0, 3.0]::DOUBLE[], 64, 1.0) = fractal_state_fingerprint([1.0, 2.0, 3.0]::DOUBLE[], 64, 1.0), fractal_state_fingerprint([1.0, 2.0, 3.0]::DOUBLE[], 64, 1.0) = fractal_state_fingerprint([1.0, 2.0, 3.0]::DOUBLE[], 64, 2.0);

SELECT fractal_state_fingerprint([]::DOUBLE[]);

SELECT fractal_state_fingerprint([1.0]::DOUBLE[], 0, 1, 1.0);

SELECT fractal_state_fingerprint([1.0]::DOUBLE[], 65537);

SELECT fractal_state_fingerprint(NULL::DOUBLE[]), fractal_state_fingerprint([1.0]::DOUBLE[], NULL), fractal_state_fingerprint([1.0]::DOUBLE[], 64, NULL::DOUBLE);

SELECT fractal_state_fingerprint([1.0, NULL]::DOUBLE[]);

-- cycle detect (table function)
SELECT * FROM fractal_cycle_detect(['\xAA'::BLOB, '\xBB'::BLOB, '\xAA'::BLOB, '\xBB'::BLOB, '\xAA'::BLOB, '\xBB'::BLOB], 0);

SELECT * FROM fractal_cycle_detect(['\x00'::BLOB, '\x01'::BLOB, '\x00'::BLOB, '\x01'::BLOB], 1);

SELECT * FROM fractal_cycle_detect(['\x01\x02'::BLOB, '\x03\x04'::BLOB, '\x05\x06'::BLOB], 0);

SELECT * FROM fractal_cycle_detect(['\x01'::BLOB, '\x01\x02'::BLOB], 0);

SELECT * FROM fractal_cycle_detect([]::BLOB[], 0);

SELECT * FROM fractal_cycle_detect(NULL::BLOB[], 0);

SELECT * FROM fractal_cycle_detect(['\x01'::BLOB, NULL], 0);

SELECT * FROM fractal_cycle_detect([NULL, '\x01'::BLOB], 0);

SELECT * FROM fractal_cycle_detect([''::BLOB, ''::BLOB], 0);

SELECT * FROM fractal_cycle_detect(['\x01'::BLOB], -1);

SELECT * FROM fractal_cycle_detect(['\x01'::BLOB], NULL);

-- a cycle detected over a fingerprint stream produced by fractal_state_fingerprint
SELECT * FROM fractal_cycle_detect(list_transform(range(12), lambda i: fractal_state_fingerprint([(i % 3) * 1.0, 1.0, 2.0]::DOUBLE[], 64, 7.0)), 0);

-- typing
SELECT typeof(fractal_dimension_drift(list_transform(range(100), lambda i: i * 1.0), 32)), typeof(fractal_change_point_detect([1.0]::DOUBLE[], 1)), typeof(fractal_spectrogram_entropy([1.0]::DOUBLE[])), typeof(fractal_tda_persistence_diagram([0.0,0.0, 1.0,1.0]::DOUBLE[], 2, 1, 1.0)), typeof(fractal_state_fingerprint([1.0]::DOUBLE[]));

-- Known limitation L1 (documented API change from the C++ build): the optional trailing argument
-- of the two table functions is required, because the C API cannot overload a table function.
-- expect-c: No function matches the given name and argument types 'fractal_periodogram(
SELECT * FROM fractal_periodogram(list_transform(range(16), lambda i: i * 1.0));

-- expect-c: No function matches the given name and argument types 'fractal_cycle_detect(
SELECT * FROM fractal_cycle_detect(['\x01'::BLOB, '\x01'::BLOB]);
