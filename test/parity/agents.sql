-- Parity cases for the table-scanning agents and the search composition functions (fsql_agents.c).
-- The mock embed plugin answers every tier with [0.1,0.2,0.3], so corpora here are 3-dimensional.

-- search_debug
SELECT fractal_sfs_converge_debug([0.1, 0.2, 0.3]::DOUBLE[], 5, 10, 2);

SELECT fractal_sfs_converge_debug([0.1, 0.2, 0.3]::DOUBLE[], 0, 10, 2);

SELECT fractal_sfs_converge_debug([0.1, 0.2, 0.3]::DOUBLE[], 5, 0, 2);

SELECT fractal_sfs_converge_debug([0.1, 0.2, 0.3]::DOUBLE[], 5, 10, 99);

SELECT fractal_sfs_converge_debug(NULL, 5, 10, 2), fractal_sfs_converge_debug([1.0]::DOUBLE[], NULL, 10, 2);

SELECT fractal_sfs_converge_debug([]::DOUBLE[], 5, 10, 2);

-- corpora
CREATE TABLE docs (id INTEGER PRIMARY KEY, label VARCHAR, v DOUBLE[]);
INSERT INTO docs VALUES (1, 'a', [0.1, 0.2, 0.3]), (2, 'b', [0.9, 0.1, 0.0]), (3, 'c', [0.0, 0.8, 0.5]), (4, 'd', [0.3, 0.3, 0.3]), (5, 'e', [0.7, 0.7, 0.1]);
SELECT count(*) FROM fractal_search_telemetry('docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], 3);
SELECT doc_id, round(distance, 6), scan_pos FROM fractal_search_telemetry('docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], 3) ORDER BY scan_pos;
SELECT doc_id, round(distance, 6), scan_pos FROM fractal_search_telemetry('docs', 'v', [0.9, 0.1, 0.0]::DOUBLE[], 1);
SELECT * FROM fractal_search_telemetry('docs', 'v', [0.1, 0.2]::DOUBLE[], 3);
SELECT * FROM fractal_search_telemetry('docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], 0);
SELECT * FROM fractal_search_telemetry('docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], 100001);
SELECT * FROM fractal_search_telemetry('docs', 'v', NULL::DOUBLE[], 3);
SELECT * FROM fractal_search_telemetry('docs', 'v', []::DOUBLE[], 3);
SELECT * FROM fractal_search_telemetry('nope', 'v', [0.1, 0.2, 0.3]::DOUBLE[], 3);
SELECT * FROM fractal_search_telemetry('docs', 'nope', [0.1, 0.2, 0.3]::DOUBLE[], 3);
SELECT * FROM fractal_search_telemetry('docs', 'label', [0.1, 0.2, 0.3]::DOUBLE[], 3);

CREATE TABLE empty_docs (id INTEGER, v DOUBLE[]);
SELECT * FROM fractal_search_telemetry('empty_docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], 3);

CREATE TABLE null_docs (id INTEGER, v DOUBLE[]);
INSERT INTO null_docs VALUES (1, [0.1, 0.2, 0.3]), (2, NULL);
SELECT * FROM fractal_search_telemetry('null_docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], 1);

CREATE TABLE ragged (id INTEGER, v DOUBLE[]);
INSERT INTO ragged VALUES (1, [0.1, 0.2, 0.3]), (2, [0.1, 0.2]);
SELECT * FROM fractal_search_telemetry('ragged', 'v', [0.1, 0.2, 0.3]::DOUBLE[], 1);

CREATE TABLE float_docs (id INTEGER, v FLOAT[]);
INSERT INTO float_docs VALUES (1, [0.5, 0.25, 0.125]), (2, [0.0, 1.0, 0.0]);
SELECT doc_id, round(distance, 5) FROM fractal_search_telemetry('float_docs', 'v', [0.5, 0.25, 0.125]::DOUBLE[], 1);

CREATE VIEW docs_view AS SELECT id, v FROM docs;
SELECT doc_id, scan_pos FROM fractal_search_telemetry('docs_view', 'v', [0.1, 0.2, 0.3]::DOUBLE[], 2) ORDER BY scan_pos;

-- search_trajectory / cross-modal / hybrid clinical
SELECT doc_id, round(distance, 6) FROM fractal_search_trajectory('docs', 'v', [0.0, 0.0, 0.0]::DOUBLE[], [0.1, 0.2, 0.3]::DOUBLE[], 2) ORDER BY doc_id;
SELECT * FROM fractal_search_trajectory('docs', 'v', [0.0, 0.0]::DOUBLE[], [0.1, 0.2, 0.3]::DOUBLE[], 2);
SELECT * FROM fractal_search_trajectory('docs', 'v', NULL::DOUBLE[], [0.1, 0.2, 0.3]::DOUBLE[], 2);
SELECT * FROM fractal_search_trajectory('docs', 'v', [0.0, 0.0, 0.0]::DOUBLE[], [0.1, 0.2, 0.3]::DOUBLE[], 0);
SELECT * FROM fractal_search_trajectory('docs', 'v', [0.0]::DOUBLE[], [0.1]::DOUBLE[], 2);

SELECT doc_id, round(distance, 6) FROM fractal_cross_modal_search('docs', 'v', [0.1, 0.2]::DOUBLE[], [0.3]::DOUBLE[], 0.5, 2) ORDER BY doc_id;
SELECT * FROM fractal_cross_modal_search('docs', 'v', [0.1, 0.2]::DOUBLE[], [0.3]::DOUBLE[], 1.5, 2);
SELECT * FROM fractal_cross_modal_search('docs', 'v', [0.1, 0.2]::DOUBLE[], [0.3]::DOUBLE[], -0.1, 2);
SELECT * FROM fractal_cross_modal_search('docs', 'v', [0.1, 0.2]::DOUBLE[], [0.3, 0.4]::DOUBLE[], 0.5, 2);
SELECT * FROM fractal_cross_modal_search('docs', 'v', NULL::DOUBLE[], [0.3]::DOUBLE[], 0.5, 2);
SELECT * FROM fractal_cross_modal_search('docs', 'v', [0.1, 0.2]::DOUBLE[], [0.3]::DOUBLE[], 0.5, 0);

SELECT doc_id, scan_pos FROM fractal_hybrid_clinical_search('docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], ['0', '2', '4'], 2) ORDER BY scan_pos;
SELECT * FROM fractal_hybrid_clinical_search('docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], ['999'], 2);
SELECT * FROM fractal_hybrid_clinical_search('docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], []::VARCHAR[], 2);
SELECT * FROM fractal_hybrid_clinical_search('docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], NULL::VARCHAR[], 2);
SELECT * FROM fractal_hybrid_clinical_search('docs', 'v', [0.1, 0.2]::DOUBLE[], ['0'], 2);
SELECT * FROM fractal_hybrid_clinical_search('docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], ['0'], 0);
SELECT * FROM fractal_hybrid_clinical_search('docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], ['0''; DROP TABLE docs; --'], 2);
SELECT count(*) FROM docs;

-- search_explore (full arity only)
SELECT count(*) > 0 FROM fractal_search_explore('docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], '{"population_size": 4, "iterations": 3}');
SELECT len(particle) FROM fractal_search_explore('docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], '{"population_size": 4}') LIMIT 1;
SELECT count(*) > 0 FROM fractal_search_explore('docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], NULL);
SELECT * FROM fractal_search_explore('docs', 'v', [0.1, 0.2]::DOUBLE[], '');
SELECT * FROM fractal_search_explore('docs', 'v', NULL::DOUBLE[], '');
SELECT * FROM fractal_search_explore('docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], '{"iterations": 99999}');
SELECT * FROM fractal_search_explore('docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], '{"population_size": 100001}');
SELECT * FROM fractal_search_explore('docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], '{"diffusion_factor": 99}');
SELECT * FROM fractal_search_explore('empty_docs', 'v', [0.1, 0.2, 0.3]::DOUBLE[], '');

-- trajectory_predict
SELECT round(projected_drift_delta, 6), risk_threshold_exceeded, len(predicted_state_vector) FROM fractal_agent_trajectory_predict('docs', 'v', 1, 0);
SELECT * FROM fractal_agent_trajectory_predict('docs', 'v', 999, 0);
SELECT * FROM fractal_agent_trajectory_predict('empty_docs', 'v', 1, 0);
SELECT * FROM fractal_agent_trajectory_predict('nope', 'v', 1, 0);
SELECT * FROM fractal_agent_trajectory_predict('ragged', 'v', 1, 0);

-- agents that embed and answer (mock embed plugin + embed URL)
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
-- env: FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings
CREATE TABLE kb (id INTEGER PRIMARY KEY, note VARCHAR, v DOUBLE[]);
INSERT INTO kb VALUES (1, 'alpha', [0.1, 0.2, 0.3]), (2, 'beta', [0.9, 0.1, 0.0]), (3, 'gamma', [0.0, 0.8, 0.5]);
SELECT answer, source_row_ids FROM fractal_search_agent('hello', 'kb', 'v', 3, 5);
SELECT answer FROM fractal_rag_agent('hello', 'kb', 'v', '');
SELECT branch_id, round(confidence_score, 6), len(plan_trajectory) FROM fractal_agent_plan_explore('start', 'kb', 'v', 2) ORDER BY branch_id;
SELECT execution_time_ms >= 0 FROM fractal_search_agent('hello', 'kb', 'v', 3, 5);
SELECT * FROM fractal_search_agent('hello', 'kb', 'v', 0, 5);
SELECT * FROM fractal_search_agent('hello', 'kb', 'v', 3, 0);
SELECT * FROM fractal_search_agent('hello', 'nope', 'v', 3, 5);
SELECT * FROM fractal_rag_agent('hello', 'nope', 'v', '');
SELECT * FROM fractal_agent_plan_explore('start', 'kb', 'v', 0);

-- embedding dimension mismatch
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
-- env: FSQL_REASONING_HTTP_EMBED_URL=https://embed.invalid/v1/embeddings
CREATE TABLE kb2 (id INTEGER PRIMARY KEY, v DOUBLE[]);
INSERT INTO kb2 VALUES (1, [0.1, 0.2]);
SELECT * FROM fractal_search_agent('hello', 'kb2', 'v', 3, 5);
SELECT * FROM fractal_rag_agent('hello', 'kb2', 'v', '');
SELECT * FROM fractal_agent_plan_explore('start', 'kb2', 'v', 2);

-- no plugin
SELECT * FROM fractal_search_agent('hello', 'docs', 'v', 3, 5);
SELECT * FROM fractal_rag_agent('hello', 'docs', 'v', '');

-- detect_loop
SELECT fractal_agent_detect_loop('a1', [1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0]::DOUBLE[], 2);
SELECT fractal_agent_detect_loop('a1', [1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0]::DOUBLE[], 2, 32);
SELECT fractal_agent_detect_loop('a1', [1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0]::DOUBLE[], 2, 32, 7.0);
SELECT fractal_agent_detect_loop('a1', [1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0]::DOUBLE[], 2, 32, 7.0, 3);
SELECT fractal_agent_detect_loop('a2', [0.1, 0.9, 0.5, 0.3, 0.8, 0.2, 0.7, 0.4, 0.6, 0.35]::DOUBLE[], 1);
SELECT fractal_agent_detect_loop('a2', [0.1, 0.9, 0.5, 0.3, 0.8, 0.2]::DOUBLE[], 2).dfa_exponent IS NOT NULL;
SELECT fractal_agent_detect_loop('x', [1.0, 2.0]::DOUBLE[], 2);
SELECT fractal_agent_detect_loop('x', [1.0, 2.0, 3.0]::DOUBLE[], 2);
SELECT fractal_agent_detect_loop('x', [1.0, 2.0, 3.0, 4.0]::DOUBLE[], 0);
SELECT fractal_agent_detect_loop('x', [1.0, 2.0, 3.0, 4.0]::DOUBLE[], 5000);
SELECT fractal_agent_detect_loop('x', [1.0, 2.0, 3.0, 4.0]::DOUBLE[], 2, 0);
SELECT fractal_agent_detect_loop('x', [1.0, 2.0, 3.0, 4.0]::DOUBLE[], 2, 64, 1.0, -1);
SELECT fractal_agent_detect_loop('x', [1.0, NULL, 3.0, 4.0]::DOUBLE[], 2);
SELECT fractal_agent_detect_loop(NULL, [1.0, 2.0, 3.0, 4.0]::DOUBLE[], 2), fractal_agent_detect_loop('x', NULL, 2), fractal_agent_detect_loop('x', [1.0, 2.0, 3.0, 4.0]::DOUBLE[], NULL);
SELECT typeof(fractal_agent_detect_loop('x', [1.0, 2.0, 3.0, 4.0]::DOUBLE[], 2));
SELECT count(*) FROM (SELECT fractal_agent_detect_loop('r' || i, [1.0, 2.0, 3.0, 4.0]::DOUBLE[], 2) FROM range(500) t(i));
