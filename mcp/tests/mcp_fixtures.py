#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs

"""One valid call for every tool, and what a correct server returns for it.

The world is tests/fixtures.sql (docs, metrics, fleet, strategies), loaded into each server's in-memory database at
start-up through FSQL_DUCKDB_BOOTSTRAP. EXPECT says what a correct server returns with the extension loaded but NO
reasoning plugin, NO embedding provider and NO enterprise library:

    "ok"      the call succeeds
    "engine"  the call reaches the extension and is refused with a clean engine-class error
              (a plugin, a provider or the enterprise tier is needed)

mcp_mutate.py changes one argument of each at a time and replays them.

Zero dependencies beyond the stdlib."""

from __future__ import annotations

import math
import random

_SERIES = [round(math.sin(i / 3.0) * 2 + (3.0 if i > 70 else 0.0) + (i % 5) * 0.1, 3) for i in range(120)]
_R = [(i * 7919 % 1000) / 1000.0 for i in range(800)]
_PTS = [[_R[2 * i], _R[2 * i + 1]] for i in range(400)]
_Q = [1.0, 0.0, 0.0, 0.0]
_B = [0.0, 1.0, 0.0, 0.0]
_Q3 = [1.0, 0.0, 0.0]
_MU = [0.05, 0.08, 0.03, 0.12, 0.07, 0.01]
_COV = [[0.02 if i == j else 0.001 for j in range(6)] for i in range(6)]
_CUBE_V = [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0], [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1]]
_CUBE_F = [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 2, 6, 3, 6, 7, 0, 3, 7, 0, 7, 4, 1, 2, 6, 1, 6, 5]


def _skeleton(n=300):
    rng = random.Random(5)
    pts = [[0.0, 0.0, 0.0]]
    for i in range(1, n):
        pts.append([round(pts[-1][k] + rng.gauss(0, 1), 4) for k in range(3)])
    edges, arcs = [], []
    for i in range(1, n):
        j = max(0, i - 1 - (1 if rng.random() < 0.2 else 0))
        edges += [j, i]
        arcs.append(round(math.dist(pts[j], pts[i]), 4))
    return pts, edges, arcs


_SK, _SK_E, _SK_A = _skeleton()

FIXTURE_CALLS = [
    ("fractal_version", {}),
    ("fractal_config_get", {"key": "http_model"}),
    ("fractal_config_set", {"key": "http_model", "value": "mcp-smoke-model"}),
    ("fractal_configure_reasoning", {"model": "mcp-smoke-model"}),
    ("fractal_search", {"query": _Q, "iterations": 20, "population_size": 16}),
    ("fractal_search_debug", {"query": _Q, "iterations": 5, "population_size": 8, "diffusion_factor": 2}),
    ("fractal_search_explore", {"table_name": "docs", "vector_col": "emb", "query": _Q, "limit": 5}),
    ("fractal_search_telemetry", {"table_name": "docs", "vector_col": "emb", "query": _Q, "k": 3}),
    ("fractal_search_trajectory", {"table_name": "docs", "vector_col": "emb", "baseline_vector": _B, "current_vector": _Q, "k": 3}),
    ("fractal_cross_modal_search", {"table_name": "docs", "vector_col": "emb", "morphology_vector": _Q[:2], "clinical_vector": _B[:2], "alpha_weight": 0.5, "k": 3}),
    ("fractal_hybrid_clinical_search", {"table_name": "docs", "vector_col": "emb", "query": _Q, "doc_ids": ["0", "4", "8", "12"], "k": 2}),
    ("fractal_diversify_enable", {}),
    ("fractal_diversify_set_params", {"window_n": 5, "repulsion_weight": 0.8}),
    ("fractal_explain_result", {}),
    ("fractal_detect_collapse", {}),
    ("fractal_feedback_report", {"result_handle": 1, "kind": "negative"}),
    ("fractal_isolate_background", {"result_handle": 2}),
    ("fractal_diversify_disable", {}),
    ("fractal_reason", {"query": "reply with one word"}),
    ("fractal_embed", {"input": "hello world"}),
    ("fractal_text_to_sql", {"question": "how many docs are there", "table_names": ["docs"]}),
    ("fractal_schema_context", {"table_names": ["docs"]}),
    ("fractal_sql_agent", {"question": "how many docs are there", "table_names": ["docs"], "max_retries": 1, "auto_execute": False}),
    ("fractal_agent_anomaly_triage", {"log_table": "metrics", "metric_col": "cpu", "time_col": "ts", "filter_col": "host", "filter_val": "host-1"}),
    ("fractal_agent_allocate", {"mu": _MU, "cov": _COV, "cardinality": 2}),
    ("fractal_agent_route_task", {"task_emb": _Q, "cap_table": "docs", "cap_emb_col": "emb", "cap_id_col": "id", "budget": 1000}),
    ("fractal_agent_outlier_intercept", {"state_vec": _Q, "history_table": "docs", "emb_col": "emb", "threshold": 0.3}),
    ("fractal_agent_recall_hybrid", {"mem_table": "docs", "vec_col": "emb", "query_vec": _Q, "k": 3}),
    ("fractal_agent_recommend_diverse", {"catalog_table": "docs", "emb_col": "emb", "query_vec": _Q, "k": 3}),
    ("fractal_agent_data_analyst", {"question": "how many docs are there", "table_names": ["docs"]}),
    ("fractal_agent_patient_deterioration_triage", {"patient_table": "docs", "vec_col": "emb", "query_vec": _Q, "baseline_vec": _B, "current_vec": _Q}),
    ("fractal_agent_feedback_audit", {"catalog_table": "docs", "emb_col": "emb", "query_vec": _Q, "warmup_table": "docs", "warmup_vec_col": "emb", "warmup_count": 4}),
    ("fractal_agent_schedule_workload", {"task_vec": _Q, "node_table": "docs", "node_emb_col": "emb", "node_id_col": "id", "iterations": 5, "population": 8}),
    ("fractal_agent_rebalance_sibling", {"mu": _MU[:4], "cov": [[0.02 if i == j else 0.001 for j in range(4)] for i in range(4)], "cardinality": 2,
                                         "alloc_table": "strategies", "alloc_emb_col": "emb", "baseline_vec": [0.25, 0.25, 0.25, 0.25], "seed": 7}),
    ("fractal_agent_detour_classify", {"vehicle_table": "fleet", "emb_col": "emb", "baseline_vec": _Q3, "current_vec": [0.0, 1.0, 0.0], "gps_trace": [v for p in _PTS for v in p]}),
    ("fractal_agent_track_anomaly", {"track_table": "fleet", "emb_col": "emb", "baseline_vec": _Q3, "current_vec": [0.0, 1.0, 0.0], "heading_series": _SERIES}),
    ("fractal_agent_network_coverage_alert", {"point_cloud": [v for p in _PTS for v in p], "drift_series": _SERIES}),
    ("fractal_agent_regime_triage", {"series": _SERIES, "win": 32}),
    ("fractal_agent_diverse_portfolios", {"mu": _MU, "cov": _COV, "cardinality": 2, "n_restarts": 3}),
    ("fractal_agent_plan_explore", {"initial_state": "a seed state", "strategy_table": "strategies", "vector_col": "emb", "max_branches": 3}),
    ("fractal_agent_trajectory_predict", {"table_name": "strategies", "vector_col": "emb", "baseline_id": 1, "forecast_steps": 2}),
    ("fractal_agent_detect_loop", {"agent_id": "mcpt-agent", "state_log": [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0], "dim": 3}),
    ("fractal_search_agent", {"query": "what is topic 1", "table_name": "docs", "vector_col": "emb", "pop_size": 8, "iterations": 5}),
    ("fractal_rag_agent", {"query": "what is topic 1", "table_name": "docs", "vector_col": "emb", "meta_filter": "{}"}),
    ("fractal_dimension_dfa", {"series": _SERIES}),
    ("fractal_dimension_drift", {"series": _SERIES, "win": 32}),
    ("fractal_dimension_boxcount", {"points": _PTS}),
    ("fractal_periodogram", {"series": _SERIES, "max_peaks": 3}),
    ("fractal_change_point_detect", {"series": _SERIES, "window": 16, "threshold": 1.0}),
    ("fractal_state_fingerprint", {"vector": _Q, "n_bits": 64, "seed": 7}),
    ("fractal_spectrogram_entropy", {"series": _SERIES, "window": 32, "hop": 16}),
    ("fractal_cycle_detect", {"fingerprints": ["aa55", "bb66", "aa55", "bb66", "aa55", "bb66"], "hamming_threshold": 0}),
    ("fractal_tda_persistence_diagram", {"points": _PTS[:30], "max_dim": 1, "max_thresh": 0.5}),
    ("fractal_morphological_complexity", {"points": _PTS}),
    ("fractal_cortical_folding", {"vertices": [v for p in _CUBE_V for v in p], "faces": _CUBE_F}),
    ("fractal_nerve_plexus_metric", {"node_coords": _SK, "edges": _SK_E}),
    ("fractal_vascular_network", {"node_coords": [v for p in _SK for v in p], "edges": _SK_E, "arc_length": _SK_A}),
    ("fractal_optimize_portfolio", {"mu": _MU, "cov": _COV, "k": 2, "seed": 42}),
    ("fractal_optimize_subset", {"item_values": [0.12, 0.09, 0.15, 0.06, 0.11], "upper_bounds": [0.6] * 5, "k": 2}),
    ("fractal_optimize_portfolio_multimodal", {"mu": _MU, "cov": _COV, "k": 2, "n_restarts": 3}),
    ("fractal_optimize_portfolio_multimodal_pareto", {"mu": _MU, "cov": _COV, "k": 2, "n_restarts": 3}),
    ("fractal_vector_lp_distance", {"a": [0, 0], "b": [3, 4], "p": 1}),
    ("fractal_vector_hamming_distance", {"a": "0f", "b": "f0"}),
    ("fractal_vector_quantize_int8", {"vector": [1, -2, 3]}),
    ("fractal_vector_quantize_binary", {"vector": [1, -2, 3, 4, -1, -1, 1, 1]}),
    ("fractal_vectorizer_create", {"source_table": "docs", "source_pk_col": "id", "text_col": "body", "embedding_col": "emb"}),
    ("fractal_vectorizer_pause", {"id": 1}),
    ("fractal_vectorizer_resume", {"id": 1}),
    ("fractal_vectorizer_status", {}),
    ("fractal_vectorizer_process_queue", {"batch_size": 4}),
    ("fractal_vectorizer_drop", {"id": 1}),
    ("fractal_ledger_verify", {"kind": 2}),
    ("fractal_ledger_truth_count", {}),
    ("fractal_ledger_shadow_count", {}),
    ("fractal_ledger_flush", {}),
    ("fractal_ledger_load", {}),
    ("fractal_ledger_compact", {}),
    ("fractal_ledger_reset_soft", {}),
    ("fractal_ledger_reset_hard", {}),
    ("fractal_audit_log", {"entry_type": "probe", "payload": '{"a": 1}'}),
    ("fractal_audit_unpack", {"blob": "00ff"}),
]

# Refused cleanly by the extension when nothing is behind it: a reasoning plugin, an embedding provider, or the enterprise library.
_ENGINE = {
    "fractal_reason", "fractal_embed", "fractal_text_to_sql", "fractal_sql_agent", "fractal_agent_anomaly_triage", "fractal_agent_allocate",
    "fractal_agent_route_task", "fractal_agent_outlier_intercept", "fractal_agent_data_analyst", "fractal_agent_patient_deterioration_triage",
    "fractal_agent_schedule_workload", "fractal_agent_rebalance_sibling", "fractal_agent_detour_classify", "fractal_agent_track_anomaly",
    "fractal_agent_network_coverage_alert", "fractal_agent_regime_triage", "fractal_agent_diverse_portfolios", "fractal_agent_plan_explore",
    "fractal_search_agent", "fractal_rag_agent", "fractal_optimize_portfolio_multimodal", "fractal_optimize_portfolio_multimodal_pareto",
    "fractal_ledger_truth_count", "fractal_ledger_shadow_count", "fractal_ledger_flush", "fractal_ledger_load",
    "fractal_ledger_compact", "fractal_ledger_reset_soft", "fractal_ledger_reset_hard", "fractal_audit_log", "fractal_audit_unpack",
}
EXPECT = {name: ("engine" if name in _ENGINE else "ok") for name, _ in FIXTURE_CALLS}

# Replayed only against a throwaway server and never with a model behind it (mcp_mutate.py).
RISKY = {"fractal_ledger_flush", "fractal_ledger_load", "fractal_ledger_compact", "fractal_ledger_reset_soft", "fractal_ledger_reset_hard",
         "fractal_vectorizer_drop", "fractal_sql_agent"}
