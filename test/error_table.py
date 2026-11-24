#!/usr/bin/env python3
"""test/error_table.py -- a table of calls, each with the outcome it must produce: the argument-validation and error-path contract
of the SQL surface, one line per rule.

  ("E", text)   the call must raise an error whose message contains text
  ("O", regex)  the call must succeed and its result must match the regex (re.search on the printed value)
  ("N",)        the call must succeed and return NULL
  ("NW", text)  the call must succeed, return NULL, and say text on stderr (the debug/telemetry functions degrade this way)

Every call runs in its own CLI process against the same small fixtures (tables docs and telemetry, the mock reasoning plugin, the
mock enterprise core), so one call cannot disturb another. The edge-input matrix (test/edge_inputs.py) throws awkward values at every
argument and asserts only that nothing crashes; this table pins the specific message or value for the rules that are documented.

Env: CAPI_DIST / EDGE_LINE as in edge_inputs.py. Exit status is nonzero when any row fails."""
import os, re, sys
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I drops the script dir
from harness_common import signature_policy, PLUGINS, CLEAN_ENV, MOCK_FILES, latest_cli, band_file, run_cli, timeout_for

LINE = os.environ.get("EDGE_LINE", "15")
CLI, EXT = latest_cli(LINE), band_file(LINE)
if not CLI or not EXT:
    print("  FAIL need a DuckDB CLI and the built extension for line " + LINE); sys.exit(1)

PRELUDE = """
CREATE TABLE docs (id INTEGER PRIMARY KEY, label VARCHAR, v DOUBLE[]);
INSERT INTO docs VALUES (1,'a',[0.1,0.2,0.3]),(2,'b',[0.9,0.1,0.0]),(3,'c',[0.0,0.8,0.5]),(4,'d',[0.3,0.3,0.3]);
CREATE TABLE telemetry (ts INTEGER, host VARCHAR, cpu DOUBLE);
INSERT INTO telemetry SELECT i, 'h1', sin(i * 0.37) + (i % 7) * 0.05 FROM range(60) t(i);
CREATE TABLE tiny (id INTEGER, v DOUBLE[]);
CREATE TABLE ragged (id INTEGER, v DOUBLE[]);
INSERT INTO ragged VALUES (1,[0.1,0.2,0.3]),(2,[0.1,0.2]);
"""
V3 = "[0.1,0.2,0.3]::DOUBLE[]"

T = [
    # ---- search / explore: parameter bounds
    ("SELECT fractal_sfs_converge_debug(%s, 0, 10, 2)" % V3,    ("NW", "iterations 0 out of range [1, 10000]")),
    ("SELECT fractal_sfs_converge_debug(%s, 5, 0, 2)" % V3,     ("NW", "population_size 0 out of range [1, 10000]")),
    ("SELECT fractal_sfs_converge_debug(%s, 5, 10, 99)" % V3,   ("NW", "diffusion_factor 99 out of range [1, 32]")),
    ("SELECT fractal_sfs_converge_debug([]::DOUBLE[], 5, 10, 2)", ("NW", "dim 0 out of range")),
    ("SELECT fractal_sfs_converge_debug(%s, 5, 10, 2)" % V3,    ("O", r"dim"":3|dim\"\":3")),
    ("SELECT fractal_sfs_converge(NULL::DOUBLE[], 5)",          ("N",)),
    ("SELECT fractal_search_explore(v, [0.1,0.2]::DOUBLE[]) FROM docs WHERE false", ("N",)),
    ("SELECT length(fractal_search_explore(v, [0.1,0.2,0.3]::DOUBLE[])) FROM docs", ("O", r"^\d+$")),
    ("SELECT fractal_search_explore(v, [0.1,0.2,0.3]::DOUBLE[]) FROM ragged", ("E", "inconsistent embedding dim")),
    ("SELECT fractal_search_explore(v, [0.1,0.2]::DOUBLE[]) IS NULL FROM docs", ("O", "true")),
    ("SELECT fractal_search_explore(v, NULL::DOUBLE[]) IS NULL FROM docs", ("O", "true")),
    ("SELECT count(*) FROM fractal_search_explore('docs','v',[0.1,0.2,0.3]::DOUBLE[],'{}')", ("O", r"^\d+$")),
    ("SELECT count(*) FROM fractal_search_explore('docs','v',[0.1,0.2]::DOUBLE[],'{}')", ("E", "dim")),
    ("SELECT count(*) FROM fractal_search_explore('nosuch','v',%s,'{}')" % V3, ("E", "nosuch")),
    ("SELECT count(*) FROM fractal_search_explore('docs','x;DROP TABLE docs',%s,'{}')" % V3, ("E", "not found in FROM clause")),
    ("SELECT count(*) FROM fractal_search_explore('docs','v',%s,'{\"population_size\": 5, \"iterations\": 3}')" % V3, ("O", r"^\d+$")),
    # ---- the SFS work cap: iterations x population_size x diffusion_factor x dim must not exceed 2^31.
    # Every factor is in range on its own here (10000/10000/32 are the ceilings), so only the product can
    # catch the call -- and each row is refused BEFORE the search runs, so the row itself stays cheap.
    ("SELECT fractal_sfs_converge(%s, 10000, 10000, 32)" % V3, ("E", "search too large (iterations x population_size x diffusion_factor x dim exceeds 2147483648)")),
    ("SELECT count(*) FROM fractal_search_explore('docs','v',%s,'{\"iterations\": 10000, \"population_size\": 10000, \"diffusion_factor\": 32}')" % V3, ("E", "search too large (iterations x population_size x diffusion_factor x dim exceeds 2147483648)")),
    ("SELECT answer FROM fractal_search_agent('a question', 'docs', 'v', 10000, 10000)", ("E", "search too large (iterations x population_size x diffusion_factor x dim exceeds 2147483648)")),
    # ---- the k-subset work cap: item count x k must not exceed 2^24.
    # 4097 items with k = 4097 is the smallest pair that clears the cap while keeping k <= n_items;
    # the cap is checked before the core call, so the row stays cheap.
    ("SELECT fractal_optimize_subset(list_transform(range(4097), lambda x: 0.5::DOUBLE), list_transform(range(4097), lambda x: 0.5::DOUBLE), 4097)", ("E", "item count x k must not exceed 16777216")),
    # ---- the fingerprint work cap: n_bits x vector length must not exceed 2^28.
    # 65536 bits x 4097 dims is over the cap while each factor is in range on its own.
    ("SELECT fractal_state_fingerprint(list_transform(range(4097), lambda x: 0.5::DOUBLE), 65536)", ("E", "n_bits x vector length must not exceed 268435456")),
    # ---- vectors (FLOAT[] arguments)
    ("SELECT fractal_vector_lp_distance([1,2]::FLOAT[],[3,4]::FLOAT[], 0)", ("E", "p must be > 0")),
    ("SELECT fractal_vector_lp_distance([1,2]::FLOAT[],[3,4]::FLOAT[], 1)", ("O", r"^4(\.0+)?$")),
    ("SELECT fractal_vector_l2_distance([0,0]::FLOAT[],[3,4]::FLOAT[])", ("O", r"^5(\.0+)?$")),
    ("SELECT fractal_vector_l2_squared([0,0]::FLOAT[],[3,4]::FLOAT[])", ("O", r"^25(\.0+)?$")),
    ("SELECT fractal_vector_l2_distance([1,2]::FLOAT[],[1,2,3]::FLOAT[])", ("E", "dim")),
    ("SELECT fractal_vector_cosine_distance([1,0]::FLOAT[],[0,1]::FLOAT[])", ("O", r"^1(\.0+)?$")),
    ("SELECT fractal_vector_cosine_distance([0,0]::FLOAT[],[0,1]::FLOAT[])", ("O", r".")),
    ("SELECT fractal_vector_dot([1,2,3]::FLOAT[],[4,5,6]::FLOAT[])", ("O", r"^32(\.0+)?$")),
    ("SELECT fractal_vector_norm([3,4]::FLOAT[])", ("O", r"^5(\.0+)?$")),
    ("SELECT fractal_vector_normalize([0,0]::FLOAT[])", ("O", r".")),
    ("SELECT fractal_vector_dims([1,2,3]::FLOAT[])", ("O", r"^3$")),
    ("SELECT fractal_vector_dims([]::FLOAT[])", ("O", r"^0$")),
    ("SELECT fractal_vector_dims(NULL::FLOAT[])", ("N",)),
    ("SELECT fractal_vector_add([1,2]::FLOAT[],[3,4]::FLOAT[])", ("O", r"\[4(\.0)?, 6(\.0)?\]")),
    ("SELECT fractal_vector_add([1,2]::FLOAT[],[3]::FLOAT[])", ("E", "dim")),
    ("SELECT fractal_vector_quantize_binary([1,-2,3]::FLOAT[])", ("O", r".")),
    ("SELECT fractal_vector_quantize_int8([]::FLOAT[])", ("E", "dim")),
    ("SELECT fractal_vector_hamming_distance('\\x0f'::BLOB,'\\xf0'::BLOB)", ("O", r"^8$")),
    ("SELECT fractal_vector_hamming_distance('\\x0f'::BLOB,'\\xf0\\x00'::BLOB)", ("E", "length")),
    ("SELECT fractal_vector_weighted_concat([1,2]::FLOAT[], 0.5::FLOAT, [3]::FLOAT[], 0.5::FLOAT)", ("O", r".")),
    # ---- analytics: series / geometry bounds
    ("SELECT fractal_dimension_dfa([1.0]::DOUBLE[])", ("E", "series")),
    ("SELECT fractal_dimension_dfa(NULL::DOUBLE[])", ("N",)),
    ("SELECT fractal_dimension_boxcount([1.0,2.0]::DOUBLE[], 2)", ("E", "")),
    ("SELECT fractal_spectrogram_entropy(list_transform(range(64), lambda x: sin(x*0.3)::DOUBLE), 4, 2)", ("E", "window 4 out of range [8, 512]")),
    ("SELECT fractal_spectrogram_entropy(list_transform(range(64), lambda x: sin(x*0.3)::DOUBLE), 16, 0)", ("E", "hop must be > 0")),
    ("SELECT fractal_spectrogram_entropy(list_transform(range(64), lambda x: sin(x*0.3)::DOUBLE), 16, 8, 0)", ("E", "max_frames 0 out of range [1, 4096]")),
    ("SELECT fractal_spectrogram_entropy(list_transform(range(8), lambda x: 1.0::DOUBLE), 16, 8)", ("E", "")),
    ("SELECT len(fractal_spectrogram_entropy(list_transform(range(64), lambda x: sin(x*0.3)::DOUBLE), 16, 8))", ("O", r"^7$")),
    ("SELECT fractal_state_fingerprint([1.0,2.0]::DOUBLE[], 0)", ("E", "n_bits")),
    ("SELECT fractal_state_fingerprint([1.0,2.0]::DOUBLE[], 100000)", ("E", "n_bits 100000 out of range [1, 65536]")),
    ("SELECT * FROM fractal_cycle_detect([]::BLOB[], 4)", ("E", "")),
    ("SELECT * FROM fractal_cycle_detect(['\\x01'::BLOB,'\\x01\\x02'::BLOB], 4)", ("E", "same length")),
    ("SELECT * FROM fractal_cycle_detect(['\\x01'::BLOB,'\\x01'::BLOB], -1)", ("E", "hamming_threshold must be >= 0")),
    ("SELECT fractal_optimize_portfolio([0.1,0.2]::DOUBLE[], [0.1,0.0,0.0]::DOUBLE[], 2)", ("E", "cov length")),
    ("SELECT fractal_optimize_portfolio([0.1,0.2]::DOUBLE[], [0.04,0.0,0.0,0.09]::DOUBLE[], 2)", ("O", r".")),
    ("SELECT fractal_vascular_network([0,0,0,1,0]::DOUBLE[], [0,1]::BIGINT[], [1.0,1.0]::DOUBLE[])", ("E", "must be a multiple of 3")),
    ("SELECT fractal_vascular_network([0,0,0,1,0,0]::DOUBLE[], [0]::BIGINT[], [1.0]::DOUBLE[])", ("E", "edges length must be a multiple of 2")),
    ("SELECT fractal_vascular_network([0,0,0,1,0,0]::DOUBLE[], [0,5]::BIGINT[], [1.0]::DOUBLE[])", ("E", "out of range")),
    ("SELECT fractal_cortical_folding([0,0,0,1,0,0,0,1,0]::DOUBLE[], [0,1]::BIGINT[])", ("E", "faces length must be a multiple of 3")),
    ("SELECT fractal_morphological_complexity([0.0]::DOUBLE[], 3)", ("E", "")),
    ("SELECT fractal_tda_persistence_diagram([0.0,0.0,1.0,1.0]::DOUBLE[], 3, 1, 1.0, 5)", ("E", "dim")),
    ("SELECT fractal_tda_persistence_diagram([0.0,0.0,1.0,1.0]::DOUBLE[], 2, 1, 1.0, 0)", ("E", "max_h0_bars > 0")),
    # ---- tda persistence diagram: every argument check, the optional arguments, and each NULL
    ('SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0]::DOUBLE[], 2, 2, 1.0)', ('E', 'invalid input')),
    ('SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0]::DOUBLE[], 2, 1, 0.0)', ('E', 'invalid input')),
    ("SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0]::DOUBLE[], 2, 1, 'NaN'::DOUBLE)", ('E', 'invalid input')),
    ('SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0]::DOUBLE[], 2, 1, 1.0, -5)', ('E', 'invalid input')),
    ('SELECT fractal_tda_persistence_diagram([0.0,0.0,1.0]::DOUBLE[], 2, 1, 1.0)', ('E', 'invalid input')),
    ('SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0]::DOUBLE[], 2, 1, 1.0, 1000000)', ('E', 'out of range [1, 512]')),
    ('SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0]::DOUBLE[], 0, 1, 1.0)', ('E', 'dim must be > 0')),
    ('SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0]::DOUBLE[], -1, 1, 1.0)', ('E', 'dim must be > 0')),
    ('SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0]::DOUBLE[], 65, 1, 1.0)', ('E', 'dim exceeds cap 64')),
    ('SELECT fractal_tda_persistence_diagram(list_transform(range(2000002), lambda x: 0.0)::DOUBLE[], 2, 1, 1.0)', ('E', 'exceeds cap')),
    ('SELECT fractal_tda_persistence_diagram([0.0,0.0]::DOUBLE[], 2, 1, 1.0)', ('E', 'rc=')),
    ('SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0]::DOUBLE[], 2, 0, 1.0, 8)', ('O', 'h0_bars')),
    ('SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0]::DOUBLE[], 2, 1, 1.0, 8)', ('O', 'betti1')),
    ('SELECT fractal_tda_persistence_diagram(NULL::DOUBLE[], 2, 1, 1.0)', ('N',)),
    ('SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0]::DOUBLE[], NULL, 1, 1.0)', ('N',)),
    ('SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0]::DOUBLE[], 2, NULL, 1.0)', ('N',)),
    ('SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0]::DOUBLE[], 2, 1, NULL)', ('N',)),
    ('SELECT fractal_tda_persistence_diagram([0.0,0.0, 0.1,0.0, 0.0,0.1, 5.0,5.0]::DOUBLE[], 2, 1, 1.0, NULL)', ('N',)),
    ("SELECT * FROM fractal_periodogram([]::DOUBLE[], 4)", ("E", "")),
    ("SELECT fractal_change_point_detect([1.0,1.0,1.0]::DOUBLE[], 2)", ("E", "")),
    # ---- config
    ("SELECT fractal_config_get('no_such_key')", ("E", "unknown config key 'no_such_key': the documented keys are")),
    ("SELECT fractal_config_set('no_such_key','x')", ("E", "unknown config key")),
    ("SELECT fractal_config_get(NULL)", ("N",)),
    ("SELECT fractal_config_set('http_model','m1'), fractal_config_get('http_model')", ("O", "m1")),
    ("SELECT fractal_config_get('http_token')", ("E", "is a secret and is never read back")),
    ("SELECT fractal_version()", ("O", r"^\d+\.\d+\.\d+")),
    ("SELECT fractal_edition()", ("O", "Community")),
    # ---- schema context / text to sql
    ("SELECT length(fractal_schema_context())", ("O", r"^\d+$")),
    ("SELECT fractal_schema_context(['nosuch'])", ("E", "no visible tables found")),
    ("SELECT fractal_schema_context(['docs'], 'rows')", ("O", "docs")),
    ("SELECT fractal_text_to_sql('how many docs', ['docs'])", ("O", "(?i)select")),
    ("SELECT fractal_text_to_sql(NULL, ['docs'])", ("N",)),
    ("SELECT fractal_text_to_sql(repeat('q', 5000000), ['docs'])", ("E", "question exceeds the 4 MiB input cap")),
    ("SELECT fractal_reason(NULL)", ("N",)),
    ("SELECT fractal_embed(repeat('q', 5000000))", ("E", "exceeds the 4 MiB limit")),
    ("SELECT fractal_embed(NULL)", ("N",)),
    # ---- agents
    ("SELECT * FROM fractal_sql_agent('count docs', ['docs'], 0, false)", ("E", "max_retries out of range [1, 20]")),
    ("SELECT * FROM fractal_sql_agent('count docs', ['docs'], 21, false)", ("E", "max_retries out of range [1, 20]")),
    ("SELECT answer FROM fractal_search_agent('a question', 'docs', 'v', 10, 5)", ("E", "embedding dim 768 does not m")),
    ("SELECT * FROM fractal_search_telemetry('docs','v',%s, 0)" % V3, ("E", "")),
    ("SELECT * FROM fractal_hybrid_clinical_search('docs','v',%s, []::VARCHAR[], 2)" % V3, ("E", "doc_ids must be non-empty")),
    ("SELECT * FROM fractal_cross_modal_search('docs','v',%s,%s, 1.5, 2)" % (V3, V3), ("E", "alpha_weight must be in [0,1]")),
    # ---- vectorizer
    ("SELECT fractal_vectorizer_create('nosuch','id','label','v')", ("E", "nosuch")),
    ("SELECT fractal_vectorizer_create('docs','id','label','v','not json')", ("E", "vectorizer options must be a JSON object")),
    ("SELECT fractal_vectorizer_create('docs','id','label','v','{\"bogus\": 1}')", ("E", "unknown vectorizer option 'bogus'")),
    # ---- vectorizer options: the JSON reader's valid forms and every way it rejects a malformed one
    ("SELECT fractal_vectorizer_create('docs','id','label','v','{}')", ('O', '^1$')),
    ("SELECT fractal_vectorizer_create('docs','id','label','v','   ')", ('O', '^1$')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"max_embeds_per_window": 5, "window_secs": 60}\')', ('O', '^1$')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"max_embeds_per_window": 0, "window_secs": 1}\')', ('O', '^1$')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"window_secs": +5}\')', ('O', '^1$')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'\t{\r\n "window_secs"\t:\n 10 \n}\n\')', ('O', '^1$')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"window_secs": 99999999999999999999999999999999999999999999999999999999999999999999}\')', ('O', '^1$')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"window_secs": 5.0}\')', ('E', 'must be an integer')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"window_secs": 5e2}\')', ('E', 'must be an integer')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"window_secs": -}\')', ('E', 'must be an integer')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"max_embeds_per_window": "x"}\')', ('E', 'must be an integer')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"window_secs": 0}\')', ('E', 'must be a positive number of seconds')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"max_embeds_per_window": -1}\')', ('E', 'must not be negative')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"a\\"\\\\\\/\\b\\f\\n\\r\\t": 1}\')', ('E', 'unknown vectorizer option')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"a\\q": 1}\')', ('E', 'vectorizer options: malformed JSON')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"abc\\\')', ('E', 'vectorizer options: malformed JSON')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"abc\')', ('E', 'vectorizer options: malformed JSON')),
    ("SELECT fractal_vectorizer_create('docs','id','label','v','{abc: 1}')", ('E', 'vectorizer options: malformed JSON')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"a" 1}\')', ('E', 'vectorizer options: malformed JSON')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"window_secs"\')', ('E', 'vectorizer options: malformed JSON')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"window_secs":\')', ('E', 'vectorizer options: malformed JSON')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"bogus": "str\\n\\"esc"}\')', ('E', 'unknown vectorizer option')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"bogus": {"k": [1, {"z": "}]"}]}}\')', ('E', 'unknown vectorizer option')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"bogus": [1,2,[3]]}\')', ('E', 'unknown vectorizer option')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"bogus": true}\')', ('E', 'unknown vectorizer option')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"bogus": null}\')', ('E', 'unknown vectorizer option')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"bogus": -1.5e3}\')', ('E', 'unknown vectorizer option')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"bogus": 5\')', ('E', 'unknown vectorizer option')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"bogus": {"k": 1}\')', ('E', 'unknown vectorizer option')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"bogus": "unterminated}\')', ('E', 'vectorizer options: malformed JSON')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"bogus": [1, 2}\')', ('E', 'vectorizer options: malformed JSON')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"bogus": {"k": "x\\q"}}\')', ('E', 'vectorizer options: malformed JSON')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"bogus": }\')', ('E', 'vectorizer options: malformed JSON')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"bogus": ,}\')', ('E', 'vectorizer options: malformed JSON')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"bogus"}\')', ('E', 'vectorizer options: malformed JSON')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"window_secs": 5 "x": 1}\')', ('E', 'vectorizer options: malformed JSON')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"window_secs": 5 x}\')', ('E', 'vectorizer options: malformed JSON')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"window_secs": 5} x\')', ('E', 'vectorizer options: malformed JSON')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"window_secs": 5\')', ('E', 'vectorizer options: malformed JSON')),
    ('SELECT fractal_vectorizer_create(\'docs\',\'id\',\'label\',\'v\',\'{"window_secs": 5, "max_embeds_per_window": 2, "window_secs": 9}\')', ('O', '^1$')),
    ("SELECT fractal_vectorizer_create('docs','id','label','v','{\"stale_after\": -5}')", ("E", "unknown vectorizer option 'stale_after'")),
    ("SELECT fractal_vectorizer_create('docs','id','label','v','{\"window_secs\": 0}')", ("E", "option 'window_secs' must be a positive number of seconds")),
    ("SELECT fractal_vectorizer_create('docs; DROP TABLE docs','id','label','v')", ("E", "invalid identifier")),
    ("SELECT fractal_vectorizer_create('docs','id','label','v','{\"max_embeds_per_window\": -1}')", ("E", "must not be negative")),
    ("SELECT fractal_vectorizer_create('docs','id','label','v','{\"window_secs\": \"x\"}')", ("E", "must be an integer")),
    ("SELECT fractal_vectorizer_process_queue(0)", ("E", "batch_size must be 1..")),
    ("SELECT fractal_vectorizer_process_queue(10, 0)", ("E", "stale_after must be a positive number of seconds")),
    ("SELECT count(*) FROM fractal_vectorizer_status()", ("O", r"^0$")),
    # ---- feedback / handles
    ("SELECT fractal_feedback_report(-1, 'positive')", ("E", "result_handle must be >= 0")),
    ("SELECT fractal_isolate_background(-1)", ("E", "result_handle must be >= 0")),
    # ---- enterprise-gated
    ("SELECT fractal_ledger_truth_count()", ("O", r"^7$")),
    ("SELECT fractal_audit_log('t','not json')", ("E", "payload must be well-formed JSON")),
    ("SELECT fractal_audit_unpack('\\xff'::BLOB)", ("E", "")),
    # ---- a row id is emitted as a bare JSON number only when it is one (the agent lists all 14 ids below, 12 and -0 are numbers, the
    #      rest are not); the nearest row's id is what the result names
    ("CREATE TABLE pt (pid VARCHAR, v DOUBLE[]); INSERT INTO pt VALUES ('12',[0.9,0.1,0.0]),('-0',[0.8,0.2,0.1]),('01',[0.1,0.9,0.2]),('1.5',[0.0,0.2,0.9]),('1.',[0.5,0.5,0.0]),('1e3',[0.4,0.4,0.2]),('1E+3',[0.3,0.3,0.3]),('1e',[0.2,0.2,0.6]),('-',[0.6,0.2,0.2]),('abc',[0.7,0.1,0.1]),('+1',[0.2,0.7,0.1]),('1e+',[0.15,0.15,0.7]),('1.5e-2',[0.35,0.35,0.3]),('',[0.45,0.45,0.1]); SELECT fractal_agent_patient_deterioration_triage('pt','v',[0.9,0.1,0.0]::DOUBLE[],[0.8,0.2,0.0]::DOUBLE[],[0.5,0.4,0.1]::DOUBLE[],NULL::BIGINT[],20,'pid')", ("O", r'nearest_cohort_id"":12,')),
    ("CREATE TABLE pt (pid VARCHAR, v DOUBLE[]); INSERT INTO pt VALUES ('12',[0.9,0.1,0.0]),('-0',[0.8,0.2,0.1]),('01',[0.1,0.9,0.2]),('1.5',[0.0,0.2,0.9]),('1.',[0.5,0.5,0.0]),('1e3',[0.4,0.4,0.2]),('1E+3',[0.3,0.3,0.3]),('1e',[0.2,0.2,0.6]),('-',[0.6,0.2,0.2]),('abc',[0.7,0.1,0.1]),('+1',[0.2,0.7,0.1]),('1e+',[0.15,0.15,0.7]),('1.5e-2',[0.35,0.35,0.3]),('',[0.45,0.45,0.1]); SELECT fractal_agent_patient_deterioration_triage('pt','v',[0.1,0.9,0.2]::DOUBLE[],[0.8,0.2,0.0]::DOUBLE[],[0.5,0.4,0.1]::DOUBLE[],NULL::BIGINT[],20,'pid')", ("O", r'nearest_cohort_id"":""01"",')),
    ("CREATE TABLE pt (pid VARCHAR, v DOUBLE[]); INSERT INTO pt VALUES ('12',[0.9,0.1,0.0]),('-0',[0.8,0.2,0.1]),('01',[0.1,0.9,0.2]),('1.5',[0.0,0.2,0.9]),('1.',[0.5,0.5,0.0]),('1e3',[0.4,0.4,0.2]),('1E+3',[0.3,0.3,0.3]),('1e',[0.2,0.2,0.6]),('-',[0.6,0.2,0.2]),('abc',[0.7,0.1,0.1]),('+1',[0.2,0.7,0.1]),('1e+',[0.15,0.15,0.7]),('1.5e-2',[0.35,0.35,0.3]),('',[0.45,0.45,0.1]); SELECT fractal_agent_patient_deterioration_triage('pt','v',[0.7,0.1,0.1]::DOUBLE[],[0.8,0.2,0.0]::DOUBLE[],[0.5,0.4,0.1]::DOUBLE[],NULL::BIGINT[],20,'pid')", ("O", r'nearest_cohort_id"":""abc"",')),
    ("CREATE TABLE pt (pid VARCHAR, v DOUBLE[]); INSERT INTO pt VALUES ('12',[0.9,0.1,0.0]),('-0',[0.8,0.2,0.1]),('01',[0.1,0.9,0.2]),('1.5',[0.0,0.2,0.9]),('1.',[0.5,0.5,0.0]),('1e3',[0.4,0.4,0.2]),('1E+3',[0.3,0.3,0.3]),('1e',[0.2,0.2,0.6]),('-',[0.6,0.2,0.2]),('abc',[0.7,0.1,0.1]),('+1',[0.2,0.7,0.1]),('1e+',[0.15,0.15,0.7]),('1.5e-2',[0.35,0.35,0.3]),('',[0.45,0.45,0.1]); SELECT fractal_agent_patient_deterioration_triage('pt','v',[0.45,0.45,0.1]::DOUBLE[],[0.8,0.2,0.0]::DOUBLE[],[0.5,0.4,0.1]::DOUBLE[],NULL::BIGINT[],20,'pid')", ("O", r'nearest_cohort_id"":""""')),
    # ---- the vectorizer queue with more than 8 vectorizers (the config table grows), an empty text, and explicit batch / stale arguments
    ("CREATE TABLE vt0 (id INTEGER, body VARCHAR, emb DOUBLE[]); INSERT INTO vt0 VALUES (1,'alpha',NULL),(2,'',NULL),(3,'gamma',NULL); CREATE TABLE vt1 (id INTEGER, body VARCHAR, emb DOUBLE[]); INSERT INTO vt1 VALUES (1,'alpha',NULL),(2,'',NULL),(3,'gamma',NULL); CREATE TABLE vt2 (id INTEGER, body VARCHAR, emb DOUBLE[]); INSERT INTO vt2 VALUES (1,'alpha',NULL),(2,'',NULL),(3,'gamma',NULL); CREATE TABLE vt3 (id INTEGER, body VARCHAR, emb DOUBLE[]); INSERT INTO vt3 VALUES (1,'alpha',NULL),(2,'',NULL),(3,'gamma',NULL); CREATE TABLE vt4 (id INTEGER, body VARCHAR, emb DOUBLE[]); INSERT INTO vt4 VALUES (1,'alpha',NULL),(2,'',NULL),(3,'gamma',NULL); CREATE TABLE vt5 (id INTEGER, body VARCHAR, emb DOUBLE[]); INSERT INTO vt5 VALUES (1,'alpha',NULL),(2,'',NULL),(3,'gamma',NULL); CREATE TABLE vt6 (id INTEGER, body VARCHAR, emb DOUBLE[]); INSERT INTO vt6 VALUES (1,'alpha',NULL),(2,'',NULL),(3,'gamma',NULL); CREATE TABLE vt7 (id INTEGER, body VARCHAR, emb DOUBLE[]); INSERT INTO vt7 VALUES (1,'alpha',NULL),(2,'',NULL),(3,'gamma',NULL); CREATE TABLE vt8 (id INTEGER, body VARCHAR, emb DOUBLE[]); INSERT INTO vt8 VALUES (1,'alpha',NULL),(2,'',NULL),(3,'gamma',NULL); CREATE TABLE vt9 (id INTEGER, body VARCHAR, emb DOUBLE[]); INSERT INTO vt9 VALUES (1,'alpha',NULL),(2,'',NULL),(3,'gamma',NULL); SELECT fractal_vectorizer_create('vt0','id','body','emb'); SELECT fractal_vectorizer_create('vt1','id','body','emb'); SELECT fractal_vectorizer_create('vt2','id','body','emb'); SELECT fractal_vectorizer_create('vt3','id','body','emb'); SELECT fractal_vectorizer_create('vt4','id','body','emb'); SELECT fractal_vectorizer_create('vt5','id','body','emb'); SELECT fractal_vectorizer_create('vt6','id','body','emb'); SELECT fractal_vectorizer_create('vt7','id','body','emb'); SELECT fractal_vectorizer_create('vt8','id','body','emb'); SELECT fractal_vectorizer_create('vt9','id','body','emb'); SELECT fractal_vectorizer_process_queue(5, 10)", ("O", r"^\d+$")),
    # ---- the audit payload's JSON check: every number shape and string escape it accepts, and each way it rejects a malformed one
    ('SELECT fractal_audit_log(\'t\',\'{"a":1}\')', ('O', '^true$')),
    ('SELECT fractal_audit_log(\'t\',\'"just a string"\')', ('O', '^true$')),
    ("SELECT fractal_audit_log('t','12')", ('O', '^true$')),
    ("SELECT fractal_audit_log('t','true')", ('O', '^true$')),
    ("SELECT fractal_audit_log('t','null')", ('O', '^true$')),
    ('SELECT fractal_audit_log(\'t\',\'{"a":"é😀"}\')', ('O', '^true$')),
    ('SELECT fractal_audit_log(\'t\',\'{"a":"\\"\\\\\\/\\b\\f\\n\\r\\t"}\')', ('O', '^true$')),
    ('SELECT fractal_audit_log(\'t\',\'[0, -0, 1, -1, 0.5, 1e3, 1E+3, 1e-3, 123456789, 0.5e-3, true, false, null, "x", [], {}]\')', ('O', '^true$')),
    ('SELECT fractal_audit_log(\'t\',\' \t\r\n{"nested":{"k":[1,{"z":[]}]}} \n\')', ('O', '^true$')),
    ("SELECT fractal_audit_log('t','[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]')", ('O', '^true$')),
    ("SELECT fractal_audit_log('t','')", ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','   ')", ('E', 'payload must be well-formed JSON')),
    ('SELECT fractal_audit_log(\'t\',\'{"a":"\\u12"}\')', ('E', 'payload must be well-formed JSON')),
    ('SELECT fractal_audit_log(\'t\',\'{"a":"\\u12zz"}\')', ('E', 'payload must be well-formed JSON')),
    ('SELECT fractal_audit_log(\'t\',\'{"a":"\\u"}\')', ('E', 'payload must be well-formed JSON')),
    ('SELECT fractal_audit_log(\'t\',\'{"a":"\\q"}\')', ('E', 'payload must be well-formed JSON')),
    ('SELECT fractal_audit_log(\'t\',\'{"a":"\\\')', ('E', 'payload must be well-formed JSON')),
    ('SELECT fractal_audit_log(\'t\',\'{"a":"x\')', ('E', 'payload must be well-formed JSON')),
    ('SELECT fractal_audit_log(\'t\',\'{"a":"tab\there"}\')', ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','[-]')", ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','[01]')", ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','[1.]')", ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','[1.e3]')", ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','[1e]')", ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','[1e+]')", ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','[.5]')", ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','[+1]')", ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','[--1]')", ('E', 'payload must be well-formed JSON')),
    ('SELECT fractal_audit_log(\'t\',\'{"a"}\')', ('E', 'payload must be well-formed JSON')),
    ('SELECT fractal_audit_log(\'t\',\'{"a":}\')', ('E', 'payload must be well-formed JSON')),
    ('SELECT fractal_audit_log(\'t\',\'{"a":1,}\')', ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','[1,]')", ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','[1 2]')", ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','{1:2}')", ('E', 'payload must be well-formed JSON')),
    ('SELECT fractal_audit_log(\'t\',\'{"a":1 "b":2}\')', ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','[')", ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','{')", ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','}')", ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t',']')", ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','nul')", ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','trux')", ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','falsy')", ('E', 'payload must be well-formed JSON')),
    ('SELECT fractal_audit_log(\'t\',\'{"a":1} x\')', ('E', 'payload must be well-formed JSON')),
    ("SELECT fractal_audit_log('t','[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]')", ('E', 'payload must be well-formed JSON')),
    # ---- lifecycle
    ("SELECT fractal_release()", ("O", "true")),
]


def run(i):
    sql, expect = T[i]
    env = dict(CLEAN_ENV); signature_policy(env)
    env.update({"FRACTALSQL_REASONING_PLUGIN": PLUGINS.get("mock_reasoning_plugin", ""), "FRACTALSQL_ENTERPRISE_LIB": PLUGINS.get("mock_enterprise", ""),
                "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE": "0", "FSQL_REASONING_HTTP_EMBED_URL": "https://mock.invalid/v1/embeddings",
                "FSQL_REASONING_HTTP_EMBED_MODEL": "mock-embed", "FSQL_MOCK_EMBED_DIM": "768"})
    script = "LOAD '%s';\n%s\nSELECT '@@START';\n%s\nSELECT '@@END';\nSELECT fractal_release();\n" % (EXT, PRELUDE, sql if sql.endswith(";") else sql + ";")
    # the outcome of the statement under test is what lies between the markers on stdout (and anything on stderr)
    p = run_cli([CLI, "-unsigned", "-csv", "-noheader", "-bail"], input=script, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=timeout_for(120))
    return i, p


def main():
    for k in MOCK_FILES.values():
        try: os.remove(k)
        except OSError: pass
    with open(MOCK_FILES["sql"], "w") as fh: fh.write("SELECT count(*) FROM docs;")
    passes = fails = 0
    with ThreadPoolExecutor(max_workers=4) as ex:
        for i, p in ex.map(run, range(len(T))):
            sql, expect = T[i]
            err = " ".join(l for l in p.stderr.split("\n") if l.strip())
            region = p.stdout.split("@@START", 1)[1].split("@@END", 1)[0] if "@@START" in p.stdout else ""
            out_lines = [l for l in region.split("\n") if l.strip()]
            val = out_lines[0] if out_lines else ""
            kind = expect[0]
            ok = False
            if kind == "E":
                ok = p.returncode != 0 and "Error" in err and expect[1] in err and "INTERNAL" not in err
            elif kind == "NW":
                ok = p.returncode == 0 and val == "NULL" and expect[1] in err
            elif kind == "N":
                ok = p.returncode == 0 and val == "NULL"
            else:
                ok = p.returncode == 0 and re.search(expect[1], val.strip('"')) is not None
            if ok: passes += 1
            else:
                fails += 1
                print("  FAIL %s\n       expected %s; got rc=%s out=%r err=%r" % (sql[:110], expect, p.returncode, val[:120], err[:200]))
    for k in MOCK_FILES.values():
        try: os.remove(k)
        except OSError: pass
    print("error table: %d rows, %d passed, %d failed" % (len(T), passes, fails))
    return 1 if fails else 0


sys.exit(main())
