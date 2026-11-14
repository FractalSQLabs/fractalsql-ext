-- Parity cases for the vector family (fsql_vector.c). Blank-line separated; one session each.

SELECT fractal_vector_dot([1,2,3]::FLOAT[], [4,5,6]::FLOAT[]), fractal_vector_l2_squared([1,2,3]::FLOAT[], [4,5,6]::FLOAT[]), fractal_vector_l2_distance([0,0,0]::FLOAT[], [3,4,0]::FLOAT[]);

SELECT fractal_vector_cosine_distance([1,0]::FLOAT[], [0,1]::FLOAT[]), fractal_vector_cosine_similarity([1,0]::FLOAT[], [1,0]::FLOAT[]), fractal_vector_cosine_similarity([1,2,3]::FLOAT[], [-1,-2,-3]::FLOAT[]);

SELECT fractal_vector_cosine_distance([0,0]::FLOAT[], [1,1]::FLOAT[]);

SELECT fractal_vector_norm([3,4]::FLOAT[]), fractal_vector_normalize([3,4]::FLOAT[]), fractal_vector_normalize([0,0]::FLOAT[]);

SELECT fractal_vector_dims([1,2,3,4,5]::FLOAT[]), fractal_vector_dims([]::FLOAT[]), fractal_vector_dims(NULL::FLOAT[]);

SELECT fractal_vector_from_float8_array([1.5, 2.5, 3.5]::DOUBLE[]), fractal_vector_to_float8_array([1.5, 2.5, 3.5]::FLOAT[]);

SELECT fractal_vector_from_float8_array([]::DOUBLE[]), fractal_vector_to_float8_array([]::FLOAT[]);

SELECT fractal_vector_from_float8_array(NULL::DOUBLE[]), fractal_vector_to_float8_array(NULL::FLOAT[]);

-- expect-c: NULL
-- (the C++ build raised an INTERNAL Error on a NULL list element; the C build returns NULL, like every other vector function)
SELECT fractal_vector_from_float8_array([1.0, NULL]::DOUBLE[]);

-- expect-c: NULL
SELECT fractal_vector_to_float8_array([1.0, NULL]::FLOAT[]);

SELECT fractal_vector_add([1,2,3]::FLOAT[], [10,20,30]::FLOAT[]), fractal_vector_sub([10,20,30]::FLOAT[], [1,2,3]::FLOAT[]);

SELECT fractal_vector_scale([1,2,3]::FLOAT[], 2.5::FLOAT), fractal_vector_scale([1,2,3]::FLOAT[], 0::FLOAT), fractal_vector_scale([1,2,3]::FLOAT[], -1::FLOAT);

SELECT fractal_vector_weighted_concat([1,2]::FLOAT[], 0.5::FLOAT, [3,4,5]::FLOAT[], 2::FLOAT);

SELECT fractal_vector_lp_distance([0,0]::FLOAT[], [3,4]::FLOAT[], 2::FLOAT), fractal_vector_lp_distance([0,0]::FLOAT[], [3,4]::FLOAT[], 1::FLOAT), fractal_vector_lp_distance([0,0]::FLOAT[], [3,4]::FLOAT[], 3::FLOAT);

SELECT fractal_vector_lp_distance([0,0]::FLOAT[], [3,4]::FLOAT[], 0::FLOAT);

SELECT fractal_vector_lp_distance([0,0]::FLOAT[], [3,4]::FLOAT[], -1::FLOAT);

SELECT fractal_vector_lp_distance([0,0]::FLOAT[], [3,4]::FLOAT[], 'nan'::FLOAT);

SELECT fractal_vector_quantize_int8([0.5, -1.0, 0.25, 1.0]::FLOAT[]);

SELECT fractal_vector_quantize_int8([0,0,0]::FLOAT[]);

SELECT fractal_vector_quantize_binary([1,-1,0.5,-0.5,2,-2,3,-3,1]::FLOAT[]), octet_length(fractal_vector_quantize_binary([1,-1,0.5,-0.5,2,-2,3,-3,1]::FLOAT[]));

SELECT fractal_vector_hamming_distance(fractal_vector_quantize_binary([1,1,1,1,1,1,1,1]::FLOAT[]), fractal_vector_quantize_binary([1,-1,1,-1,1,-1,1,-1]::FLOAT[]));

SELECT fractal_vector_hamming_distance('\x01'::BLOB, '\x01\x02'::BLOB);

SELECT fractal_vector_hamming_distance(''::BLOB, ''::BLOB);

-- NULL propagation: any NULL argument -> NULL
SELECT fractal_vector_dot(NULL::FLOAT[], [1]::FLOAT[]), fractal_vector_dot([1]::FLOAT[], NULL::FLOAT[]), fractal_vector_norm(NULL::FLOAT[]), fractal_vector_scale([1]::FLOAT[], NULL::FLOAT), fractal_vector_quantize_binary(NULL::FLOAT[]), fractal_vector_hamming_distance(NULL::BLOB, '\x01'::BLOB);

-- a NULL element inside a list makes the row NULL
SELECT fractal_vector_dot([1, NULL]::FLOAT[], [1, 2]::FLOAT[]), fractal_vector_norm([NULL]::FLOAT[]);

-- dimension errors
SELECT fractal_vector_dot([1,2,3]::FLOAT[], [1,2]::FLOAT[]);

SELECT fractal_vector_add([1,2,3]::FLOAT[], [1,2]::FLOAT[]);

SELECT fractal_vector_dot([]::FLOAT[], []::FLOAT[]);

SELECT fractal_vector_norm([]::FLOAT[]);

SELECT fractal_vector_normalize([]::FLOAT[]);

SELECT fractal_vector_scale([]::FLOAT[], 1::FLOAT);

SELECT fractal_vector_quantize_binary([]::FLOAT[]);

SELECT fractal_vector_weighted_concat([]::FLOAT[], 1::FLOAT, [1]::FLOAT[], 1::FLOAT);

-- the 1 Mi element ceiling
SELECT fractal_vector_norm(list_transform(range(1048576), lambda x: 1.0::FLOAT)::FLOAT[]);

SELECT fractal_vector_norm(list_transform(range(1048577), lambda x: 1.0::FLOAT)::FLOAT[]);

-- many rows across several 2048-row chunks, with NULLs mixed in
CREATE TABLE v AS SELECT CASE WHEN i % 7 = 0 THEN NULL ELSE [i*1.0, i*2.0, i*3.0]::FLOAT[] END AS a, [1,1,1]::FLOAT[] AS b, (i % 5)::FLOAT + 0.5 AS s FROM range(1, 6000) t(i);
SELECT count(*), count(fractal_vector_dot(a, b)), round(sum(fractal_vector_dot(a, b)), 3), round(sum(fractal_vector_l2_distance(a, b)), 3), count(fractal_vector_scale(a, s)), sum(fractal_vector_dims(fractal_vector_add(a, b))) FROM v;

SELECT round(sum(fractal_vector_lp_distance(a, b, s)), 3), count(fractal_vector_quantize_int8(a)), count(fractal_vector_quantize_binary(a)) FROM v;

-- typing and overload resolution
SELECT typeof(fractal_vector_dot([1]::FLOAT[], [1]::FLOAT[])), typeof(fractal_vector_normalize([1]::FLOAT[])), typeof(fractal_vector_dims([1]::FLOAT[])), typeof(fractal_vector_quantize_int8([1]::FLOAT[])), typeof(fractal_vector_quantize_binary([1]::FLOAT[])), typeof(fractal_vector_hamming_distance('\x01'::BLOB, '\x01'::BLOB));

-- implicit casts at the call site (DOUBLE[] literal into a FLOAT[] parameter)
SELECT fractal_vector_dot([1.5, 2.5], [2.0, 4.0]);
