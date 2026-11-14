-- Parity cases for the sixteen domain agents (fsql_domain_agents.c). The mock embed plugin answers the
-- cognition (CHAT) step with a fixed string, so the documents are deterministic.

-- A. anomaly_triage
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
CREATE TABLE telemetry (ts INTEGER, host VARCHAR, cpu DOUBLE);
INSERT INTO telemetry SELECT i, 'h1', sin(i * 0.37) * cos(i * 0.11) + (i % 7) * 0.05 FROM range(120) t(i);
INSERT INTO telemetry SELECT i, 'h2', (i % 5) * 0.3 FROM range(20) t(i);
SELECT fractal_agent_anomaly_triage('telemetry', 'cpu', 'ts', 'host', 'h1');
SELECT fractal_agent_anomaly_triage('telemetry', 'cpu', 'ts', 'host', 'h1', 40);
SELECT fractal_agent_anomaly_triage('telemetry', 'cpu', 'ts', 'host', 'h1', 0);
SELECT fractal_agent_anomaly_triage('telemetry', 'cpu', 'ts', 'host', 'h2');
SELECT fractal_agent_anomaly_triage('telemetry', 'cpu', 'ts', 'host', 'nobody');
SELECT fractal_agent_anomaly_triage('telemetry', 'cpu', 'ts', 'host', NULL);
SELECT fractal_agent_anomaly_triage(NULL, 'cpu', 'ts', 'host', 'h1');
SELECT fractal_agent_anomaly_triage('nope', 'cpu', 'ts', 'host', 'h1');
SELECT fractal_agent_anomaly_triage('telemetry', 'cpu', 'ts', 'host', 'h1', NULL);

-- no plugin: the cognition step was never configured
SELECT fractal_agent_anomaly_triage('telemetry', 'cpu', 'ts', 'host', 'h1');

-- B. allocate
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
SELECT fractal_agent_allocate([0.10, 0.12, 0.07, 0.15]::DOUBLE[], [0.04,0.01,0,0, 0.01,0.05,0,0, 0,0,0.02,0, 0,0,0,0.06]::DOUBLE[], 2);
SELECT fractal_agent_allocate([0.10, 0.12, 0.07, 0.15]::DOUBLE[], [0.04,0.01,0,0, 0.01,0.05,0,0, 0,0,0.02,0, 0,0,0,0.06]::DOUBLE[], 2, '{"note":"x"}');
SELECT fractal_agent_allocate([0.10, 0.12]::DOUBLE[], [0.04,0.01,0.01,0.05]::DOUBLE[], 5);
SELECT fractal_agent_allocate([0.10, 0.12]::DOUBLE[], [0.04]::DOUBLE[], 1);
SELECT fractal_agent_allocate(NULL, [0.04]::DOUBLE[], 1);
SELECT fractal_agent_allocate([0.10]::DOUBLE[], [0.04]::DOUBLE[], NULL);

-- C. route_task
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
CREATE TABLE caps (name VARCHAR, emb DOUBLE[]);
INSERT INTO caps VALUES ('search', [0.9, 0.1, 0.0]), ('write', [0.1, 0.9, 0.1]), ('math', [0.0, 0.2, 0.95]);
SELECT fractal_agent_route_task([0.8, 0.2, 0.1]::DOUBLE[], 'caps', 'emb', 'name', 1000);
SELECT fractal_agent_route_task([0.8, 0.2, 0.1]::DOUBLE[], 'caps', 'emb', 'name', 1000, 200);
SELECT fractal_agent_route_task([0.1, 0.2, 0.9]::DOUBLE[], 'caps', 'emb', 'name', 5);
CREATE TABLE no_caps (name VARCHAR, emb DOUBLE[]);
SELECT fractal_agent_route_task([0.8, 0.2, 0.1]::DOUBLE[], 'no_caps', 'emb', 'name', 5);
SELECT fractal_agent_route_task([0.8, 0.2]::DOUBLE[], 'caps', 'emb', 'name', 5);
SELECT fractal_agent_route_task(NULL, 'caps', 'emb', 'name', 5);
SELECT fractal_agent_route_task([0.8, 0.2, 0.1]::DOUBLE[], 'caps', 'emb', 'missing_col', 5);

-- D. outlier_intercept
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
CREATE TABLE bad_states (id INTEGER, emb DOUBLE[]);
INSERT INTO bad_states VALUES (1, [0.9, 0.1, 0.0]), (2, [0.0, 0.0, 1.0]), (3, NULL);
SELECT fractal_agent_outlier_intercept([0.85, 0.15, 0.0]::DOUBLE[], 'bad_states', 'emb', 0.2);
SELECT fractal_agent_outlier_intercept([0.85, 0.15, 0.0]::DOUBLE[], 'bad_states', 'emb', 0.2, 'cosine');
SELECT fractal_agent_outlier_intercept([0.85, 0.15, 0.0]::DOUBLE[], 'bad_states', 'emb', 0.2, 'l2');
SELECT fractal_agent_outlier_intercept([0.3, 0.3, 0.3]::DOUBLE[], 'bad_states', 'emb', 0.0001, 'l2');
SELECT fractal_agent_outlier_intercept([0.85, 0.15, 0.0]::DOUBLE[], 'bad_states', 'emb', 0.2, 'manhattan');
SELECT fractal_agent_outlier_intercept([0.85, 0.15, 0.0]::DOUBLE[], 'bad_states', 'emb', 0.2, NULL);
SELECT fractal_agent_outlier_intercept([0.85, 0.15, 0.0]::DOUBLE[], 'bad_states', 'emb', NULL);
CREATE TABLE no_bad (id INTEGER, emb DOUBLE[]);
SELECT fractal_agent_outlier_intercept([0.85, 0.15, 0.0]::DOUBLE[], 'no_bad', 'emb', 0.2);
SELECT fractal_agent_outlier_intercept([0.85, 0.15, 0.0]::DOUBLE[], 'no_bad', 'emb', 0.2, 'l2');

-- E. recall_hybrid
CREATE TABLE mem (id INTEGER PRIMARY KEY, kind VARCHAR, text VARCHAR, v DOUBLE[]);
INSERT INTO mem VALUES (1, 'fact', 'sky is blue', [0.9, 0.1, 0.0]), (2, 'fact', 'grass is green', [0.1, 0.9, 0.1]), (3, 'task', 'buy milk', [0.0, 0.1, 0.9]), (4, 'task', 'call mom', [0.2, 0.2, 0.8]);
SELECT fractal_agent_recall_hybrid('mem', 'v', [0.8, 0.2, 0.0]::DOUBLE[]);
SELECT fractal_agent_recall_hybrid('mem', 'v', [0.8, 0.2, 0.0]::DOUBLE[], NULL, NULL, 2);
SELECT fractal_agent_recall_hybrid('mem', 'v', [0.8, 0.2, 0.0]::DOUBLE[], 'kind', 'task', 2);
SELECT fractal_agent_recall_hybrid('mem', 'v', [0.8, 0.2, 0.0]::DOUBLE[], 'kind', 'task', 2, 'id', 'text');
SELECT fractal_agent_recall_hybrid('mem', 'v', [0.8, 0.2, 0.0]::DOUBLE[], 'kind', 'fact', 1, 'text');
SELECT fractal_agent_recall_hybrid('mem', 'v', [0.8, 0.2, 0.0]::DOUBLE[], 'kind');
SELECT fractal_agent_recall_hybrid('mem', 'v', [0.8, 0.2, 0.0]::DOUBLE[], 'kind', 'nothing');
SELECT fractal_agent_recall_hybrid('mem', 'v', [0.8, 0.2, 0.0]::DOUBLE[], 'kind', NULL);
SELECT fractal_agent_recall_hybrid('mem', 'v', NULL);
SELECT fractal_agent_recall_hybrid('nope', 'v', [0.8, 0.2, 0.0]::DOUBLE[]);
CREATE TABLE empty_mem (id INTEGER, v DOUBLE[]);
SELECT fractal_agent_recall_hybrid('empty_mem', 'v', [0.8, 0.2, 0.0]::DOUBLE[]);

-- F. recommend_diverse
CREATE TABLE catalog (id VARCHAR, v DOUBLE[]);
INSERT INTO catalog VALUES ('a', [0.9, 0.1, 0.0]), ('b', [0.8, 0.2, 0.0]), ('c', [0.1, 0.9, 0.1]), ('d', [0.0, 0.1, 0.9]), ('e', [0.5, 0.5, 0.0]);
SELECT fractal_agent_recommend_diverse('catalog', 'v', [0.85, 0.15, 0.0]::DOUBLE[]);
SELECT fractal_agent_recommend_diverse('catalog', 'v', [0.85, 0.15, 0.0]::DOUBLE[], 3);
SELECT fractal_agent_recommend_diverse('catalog', 'v', [0.85, 0.15, 0.0]::DOUBLE[], 3, 'id');
SELECT fractal_agent_recommend_diverse('empty_mem', 'v', [0.85, 0.15, 0.0]::DOUBLE[]);
SELECT fractal_agent_recommend_diverse(NULL, 'v', [0.85, 0.15, 0.0]::DOUBLE[]);
SELECT fractal_agent_recommend_diverse('catalog', 'v', [0.85, 0.15]::DOUBLE[]);

-- G. data_analyst (T2S through the mock reasoning plugin). These are SPEC cases written from the current source:
-- auto_execute is an optional argument defaulting to false (the C++ reference binary predates that).

-- expect: analysis"":null
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT count(*) AS n FROM docs
CREATE TABLE docs (id INTEGER, v DOUBLE[]);
INSERT INTO docs VALUES (1, [0.1]), (2, [0.2]);
SELECT fractal_agent_data_analyst('how many docs');

-- expect: generated_sql"":""SELECT count(*) AS n FROM docs
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT count(*) AS n FROM docs
CREATE TABLE docs (id INTEGER, v DOUBLE[]);
INSERT INTO docs VALUES (1, [0.1]), (2, [0.2]);
SELECT fractal_agent_data_analyst('how many docs', ['docs']);

-- expect: result_json"":{""status"":""validation_failed
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=DROP TABLE docs
CREATE TABLE docs (id INTEGER, v DOUBLE[]);
INSERT INTO docs VALUES (1, [0.1]), (2, [0.2]);
SELECT fractal_agent_data_analyst('nuke it', ['docs'], 1, '{}', true);

-- expect: analysis"":null
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT count(*) AS n FROM docs
CREATE TABLE docs (id INTEGER, v DOUBLE[]);
INSERT INTO docs VALUES (1, [0.1]), (2, [0.2]);
SELECT fractal_agent_data_analyst('how many docs', ['docs'], 3);

-- expect: analysis"":null
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT count(*) AS n FROM docs
CREATE TABLE docs (id INTEGER, v DOUBLE[]);
INSERT INTO docs VALUES (1, [0.1]), (2, [0.2]);
SELECT fractal_agent_data_analyst('how many docs', ['docs'], 3, '{"k":1}');

-- expect: status"":""executed
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT count(*) AS n FROM docs
CREATE TABLE docs (id INTEGER, v DOUBLE[]);
INSERT INTO docs VALUES (1, [0.1]), (2, [0.2]);
SELECT fractal_agent_data_analyst('how many docs', ['docs'], 3, '{"k":1}', true);

-- expect: analysis"":""
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT count(*) AS n FROM docs
CREATE TABLE docs (id INTEGER, v DOUBLE[]);
INSERT INTO docs VALUES (1, [0.1]), (2, [0.2]);
SELECT fractal_agent_data_analyst('how many docs', ['docs'], 3, '{"k":1}', true);

-- expect: analysis"":null
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT count(*) AS n FROM docs
CREATE TABLE docs (id INTEGER, v DOUBLE[]);
INSERT INTO docs VALUES (1, [0.1]), (2, [0.2]);
SELECT fractal_agent_data_analyst('how many docs', NULL, 3, '{}', false);

-- expect: question must not be NULL
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT count(*) AS n FROM docs
CREATE TABLE docs (id INTEGER, v DOUBLE[]);
INSERT INTO docs VALUES (1, [0.1]), (2, [0.2]);
SELECT fractal_agent_data_analyst(NULL);

-- expect: max_retries out of range
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_reasoning_plugin}
-- file: sql=SELECT count(*) AS n FROM docs
CREATE TABLE docs (id INTEGER, v DOUBLE[]);
INSERT INTO docs VALUES (1, [0.1]), (2, [0.2]);
SELECT fractal_agent_data_analyst('how many docs', ['docs'], 0);

-- H. patient_deterioration_triage
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
CREATE TABLE patients (id INTEGER PRIMARY KEY, name VARCHAR, v DOUBLE[]);
INSERT INTO patients VALUES (1, 'ann', [0.9, 0.1, 0.0]), (2, 'bob', [0.8, 0.2, 0.1]), (3, 'cy', [0.1, 0.9, 0.2]), (4, 'di', [0.0, 0.2, 0.9]);
SELECT fractal_agent_patient_deterioration_triage('patients', 'v', [0.85, 0.15, 0.0]::DOUBLE[], [0.8, 0.2, 0.0]::DOUBLE[], [0.5, 0.4, 0.1]::DOUBLE[]);
SELECT fractal_agent_patient_deterioration_triage('patients', 'v', [0.85, 0.15, 0.0]::DOUBLE[], [0.8, 0.2, 0.0]::DOUBLE[], [0.5, 0.4, 0.1]::DOUBLE[], [1, 2]::BIGINT[]);
SELECT fractal_agent_patient_deterioration_triage('patients', 'v', [0.85, 0.15, 0.0]::DOUBLE[], [0.8, 0.2, 0.0]::DOUBLE[], [0.5, 0.4, 0.1]::DOUBLE[], [1, 2]::BIGINT[], 1, 'name');
SELECT fractal_agent_patient_deterioration_triage('patients', 'v', [0.85, 0.15, 0.0]::DOUBLE[], [0.8, 0.2, 0.0]::DOUBLE[], [0.5, 0.4, 0.1]::DOUBLE[], []::BIGINT[]);
SELECT fractal_agent_patient_deterioration_triage('patients', 'v', [0.85, 0.15, 0.0]::DOUBLE[], [0.8, 0.2, 0.0]::DOUBLE[], [0.5, 0.4, 0.1]::DOUBLE[], [999]::BIGINT[]);
SELECT fractal_agent_patient_deterioration_triage('patients', 'v', [0.85, 0.15, 0.0]::DOUBLE[], [0.8, 0.2]::DOUBLE[], [0.5, 0.4, 0.1]::DOUBLE[]);
SELECT fractal_agent_patient_deterioration_triage('empty_mem', 'v', [0.85, 0.15, 0.0]::DOUBLE[], [0.8, 0.2, 0.0]::DOUBLE[], [0.5, 0.4, 0.1]::DOUBLE[]);
SELECT fractal_agent_patient_deterioration_triage('patients', 'v', NULL, [0.8, 0.2, 0.0]::DOUBLE[], [0.5, 0.4, 0.1]::DOUBLE[]);

-- I. feedback_audit
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
CREATE TABLE sess (id INTEGER, v DOUBLE[]);
INSERT INTO sess VALUES (1, [0.9, 0.1, 0.0]), (2, [0.1, 0.9, 0.1]), (3, [0.0, 0.2, 0.8]);
SELECT fractal_agent_feedback_audit('catalog', 'v', [0.85, 0.15, 0.0]::DOUBLE[], 'sess', 'v');
SELECT fractal_agent_feedback_audit('catalog', 'v', [0.85, 0.15, 0.0]::DOUBLE[], 'sess', 'v', 2);
SELECT fractal_agent_feedback_audit('catalog', 'v', [0.85, 0.15, 0.0]::DOUBLE[], 'sess', 'v', 2, 2);
SELECT fractal_agent_feedback_audit('catalog', 'v', [0.85, 0.15, 0.0]::DOUBLE[], 'no_such_table', 'v');
SELECT fractal_agent_feedback_audit('empty_mem', 'v', [0.85, 0.15, 0.0]::DOUBLE[], 'sess', 'v');
SELECT fractal_agent_feedback_audit(NULL, 'v', [0.85, 0.15, 0.0]::DOUBLE[], 'sess', 'v');

-- J. schedule_workload
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
CREATE TABLE nodes (name VARCHAR, v DOUBLE[]);
INSERT INTO nodes VALUES ('n1', [0.9, 0.1, 0.0]), ('n2', [0.1, 0.9, 0.1]), ('n3', [0.0, 0.2, 0.8]);
SELECT fractal_agent_schedule_workload([0.8, 0.2, 0.1]::DOUBLE[], 'nodes', 'v', 'name');
SELECT fractal_agent_schedule_workload([0.8, 0.2, 0.1]::DOUBLE[], 'nodes', 'v', 'name', 5);
SELECT fractal_agent_schedule_workload([0.8, 0.2, 0.1]::DOUBLE[], 'nodes', 'v', 'name', 5, 10);
SELECT fractal_agent_schedule_workload([0.8, 0.2, 0.1]::DOUBLE[], 'nodes', 'v', 'name', 5, 10, 0, '{"x":1}');
SELECT fractal_agent_schedule_workload([0.8, 0.2, 0.1]::DOUBLE[], 'empty_mem', 'v', 'name');
SELECT fractal_agent_schedule_workload(NULL, 'nodes', 'v', 'name');
SELECT fractal_agent_schedule_workload([0.8, 0.2]::DOUBLE[], 'nodes', 'v', 'name');

-- K. rebalance_sibling
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
CREATE TABLE allocs (id VARCHAR, w DOUBLE[]);
INSERT INTO allocs VALUES ('q1', [0.5, 0.5, 0.0, 0.0]), ('q2', [0.0, 0.0, 0.5, 0.5]), ('q3', [0.25, 0.25, 0.25, 0.25]);
SELECT fractal_agent_rebalance_sibling([0.10, 0.12, 0.07, 0.15]::DOUBLE[], [0.04,0.01,0,0, 0.01,0.05,0,0, 0,0,0.02,0, 0,0,0,0.06]::DOUBLE[], 2, 'allocs', 'w', [0.3, 0.3, 0.2, 0.2]::DOUBLE[]);
SELECT fractal_agent_rebalance_sibling([0.10, 0.12, 0.07, 0.15]::DOUBLE[], [0.04,0.01,0,0, 0.01,0.05,0,0, 0,0,0.02,0, 0,0,0,0.06]::DOUBLE[], 2, 'allocs', 'w', [0.3, 0.3, 0.2, 0.2]::DOUBLE[], 7, 0, 'id', '{"a":1}');
SELECT fractal_agent_rebalance_sibling([0.10, 0.12, 0.07, 0.15]::DOUBLE[], [0.04,0.01,0,0, 0.01,0.05,0,0, 0,0,0.02,0, 0,0,0,0.06]::DOUBLE[], 2, 'empty_mem', 'w', [0.3, 0.3, 0.2, 0.2]::DOUBLE[]);
SELECT fractal_agent_rebalance_sibling([0.10, 0.12, 0.07, 0.15]::DOUBLE[], [0.04,0.01,0,0, 0.01,0.05,0,0, 0,0,0.02,0, 0,0,0,0.06]::DOUBLE[], 2, 'allocs', 'w', [0.3, 0.3]::DOUBLE[]);
SELECT fractal_agent_rebalance_sibling(NULL, [0.04]::DOUBLE[], 1, 'allocs', 'w', [0.3]::DOUBLE[]);

-- L. detour_classify
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
CREATE TABLE fleet (vid VARCHAR, v DOUBLE[]);
INSERT INTO fleet VALUES ('v1', [0.9, 0.1, 0.0]), ('v2', [0.1, 0.9, 0.1]), ('v3', [0.0, 0.2, 0.8]);
SELECT fractal_agent_detour_classify('fleet', 'v', [0.5, 0.5, 0.5]::DOUBLE[], [0.9, 0.1, 0.0]::DOUBLE[], list_transform(range(40), lambda i: ((i * 37) % 17) / 17.0)::DOUBLE[]);
SELECT fractal_agent_detour_classify('fleet', 'v', [0.5, 0.5, 0.5]::DOUBLE[], [0.9, 0.1, 0.0]::DOUBLE[], list_transform(range(40), lambda i: ((i * 37) % 17) / 17.0)::DOUBLE[], 0, 'vid', 2);
SELECT fractal_agent_detour_classify('fleet', 'v', [0.5, 0.5, 0.5]::DOUBLE[], [0.9, 0.1, 0.0]::DOUBLE[], [0.1, 0.2]::DOUBLE[]);
SELECT fractal_agent_detour_classify('fleet', 'v', [0.5, 0.5, 0.5]::DOUBLE[], [0.9, 0.1, 0.0]::DOUBLE[], list_transform(range(40), lambda i: ((i * 37) % 17) / 17.0)::DOUBLE[], 0, 'vid', 99);
SELECT fractal_agent_detour_classify('empty_mem', 'v', [0.5, 0.5, 0.5]::DOUBLE[], [0.9, 0.1, 0.0]::DOUBLE[], [0.1, 0.2]::DOUBLE[]);
SELECT fractal_agent_detour_classify(NULL, 'v', [0.5, 0.5, 0.5]::DOUBLE[], [0.9, 0.1, 0.0]::DOUBLE[], [0.1, 0.2]::DOUBLE[]);

-- M. track_anomaly
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
SELECT fractal_agent_track_anomaly('fleet', 'v', [0.5, 0.5, 0.5]::DOUBLE[], [0.9, 0.1, 0.0]::DOUBLE[], list_transform(range(80), lambda i: sin(i * 0.4) + (i % 3) * 0.1)::DOUBLE[]);
SELECT fractal_agent_track_anomaly('fleet', 'v', [0.5, 0.5, 0.5]::DOUBLE[], [0.9, 0.1, 0.0]::DOUBLE[], list_transform(range(80), lambda i: sin(i * 0.4) + (i % 3) * 0.1)::DOUBLE[], 0, 'vid');
SELECT fractal_agent_track_anomaly('fleet', 'v', [0.5, 0.5, 0.5]::DOUBLE[], [0.9, 0.1, 0.0]::DOUBLE[], [0.1, 0.2]::DOUBLE[]);
SELECT fractal_agent_track_anomaly('empty_mem', 'v', [0.5, 0.5, 0.5]::DOUBLE[], [0.9, 0.1, 0.0]::DOUBLE[], [0.1, 0.2]::DOUBLE[]);
SELECT fractal_agent_track_anomaly('fleet', 'v', [0.5, 0.5]::DOUBLE[], [0.9, 0.1, 0.0]::DOUBLE[], [0.1, 0.2]::DOUBLE[]);

-- N. network_coverage_alert
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
SELECT fractal_agent_network_coverage_alert(list_transform(range(60), lambda i: ((i * 13) % 10) / 10.0 + (i % 2) * 0.03)::DOUBLE[], list_transform(range(100), lambda i: sin(i * 0.3) + i * 0.01)::DOUBLE[]);
SELECT fractal_agent_network_coverage_alert(list_transform(range(60), lambda i: ((i * 13) % 10) / 10.0 + (i % 2) * 0.03)::DOUBLE[], list_transform(range(100), lambda i: sin(i * 0.3) + i * 0.01)::DOUBLE[], 2, 32, 0.01, '{"z":1}');
SELECT fractal_agent_network_coverage_alert([0.1, 0.2]::DOUBLE[], list_transform(range(100), lambda i: sin(i * 0.3))::DOUBLE[]);
SELECT fractal_agent_network_coverage_alert(list_transform(range(60), lambda i: ((i * 13) % 10) / 10.0)::DOUBLE[], [0.1, 0.2]::DOUBLE[]);
SELECT fractal_agent_network_coverage_alert(list_transform(range(60), lambda i: ((i * 13) % 10) / 10.0)::DOUBLE[], list_transform(range(100), lambda i: sin(i * 0.3))::DOUBLE[], 9);
SELECT fractal_agent_network_coverage_alert(NULL, [0.1]::DOUBLE[]);

-- O. regime_triage
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
SELECT fractal_agent_regime_triage(list_transform(range(200), lambda i: sin(i * 0.2) + (CASE WHEN i > 120 THEN 2.0 ELSE 0.0 END))::DOUBLE[]);
SELECT fractal_agent_regime_triage(list_transform(range(200), lambda i: sin(i * 0.2))::DOUBLE[], 40);
SELECT fractal_agent_regime_triage(list_transform(range(200), lambda i: sin(i * 0.2))::DOUBLE[], 40, 0.1);
SELECT fractal_agent_regime_triage(list_transform(range(200), lambda i: sin(i * 0.2))::DOUBLE[], 40, 0.1, '{"y":2}');
SELECT fractal_agent_regime_triage([0.1, 0.2, 0.3]::DOUBLE[]);
SELECT fractal_agent_regime_triage(list_transform(range(200), lambda i: sin(i * 0.2))::DOUBLE[], 0);
SELECT fractal_agent_regime_triage(NULL);

-- P. diverse_portfolios (enterprise multimodal, through the mock core)
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
-- env: FRACTALSQL_ENTERPRISE_LIB=${mock_enterprise}
-- env: FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1
SELECT fractal_agent_diverse_portfolios([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2);
SELECT fractal_agent_diverse_portfolios([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, 3);
SELECT fractal_agent_diverse_portfolios([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, 3, 0.2, 0.8);
SELECT fractal_agent_diverse_portfolios([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, 3, 0.2, 0.8, 5, '{"q":1}', 'pareto');
SELECT fractal_agent_diverse_portfolios([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, 3, 0.2, 0.8, 5, '{}', 'sharpe');
SELECT fractal_agent_diverse_portfolios([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2, 3, 0.2, 0.8, 5, '{}', 'weird');
SELECT fractal_agent_diverse_portfolios([0.1, 0.2, 0.15]::DOUBLE[], [0.04]::DOUBLE[], 2);
SELECT fractal_agent_diverse_portfolios(NULL, [0.04]::DOUBLE[], 2);

-- dormant without the enterprise core
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
SELECT fractal_agent_diverse_portfolios([0.1, 0.2, 0.15]::DOUBLE[], [0.04,0,0, 0,0.09,0, 0,0,0.06]::DOUBLE[], 2);

-- typing, multiple rows
-- env: FRACTALSQL_REASONING_PLUGIN=${mock_embed_plugin}
SELECT typeof(fractal_agent_regime_triage(list_transform(range(200), lambda i: sin(i * 0.2))::DOUBLE[]));
SELECT count(*) FROM (SELECT fractal_agent_recall_hybrid('mem', 'v', [0.8, 0.2, 0.0]::DOUBLE[], 'kind', 'task', 2) FROM range(20));
