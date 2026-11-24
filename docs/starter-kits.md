<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# Starter Kits: Apply FractalSQL to Your Industry

You have the extension running ([getting-started.md](getting-started.md)). Now:
**which end-to-end example do I run for *my* problem?**

FractalSQL ships forty-two runnable industry walkthroughs: twenty-seven **domain
verticals** (mostly no-model) and fifteen **agentic verticals** (composed
multi-step agents, model-on). Each kit is a self-contained script: it builds
its own synthetic dataset, runs the primitives/agents that genuinely fit
that domain, and closes with a reasoned narrative. They are all re-runnable
(`DROP TABLE IF EXISTS` at the top of every section).

All forty-two kits are real, runnable DuckDB scripts (`LOAD` the extension,
plain SQL, native `DOUBLE[]`/`FLOAT[dim]` vector columns). The ten
domain-vertical kits call the sixteen registered recipe agents by name
directly (the two newest, Biotech/Genomics and Agentic Edge Swarm, are
raw-primitive showcases and run with no reasoning endpoint at all); the
three agentic verticals exercise the Universal and Domain Agent
compositions directly, each section needing reasoning configured.

> Run any kit with:
> ```bash
> { echo "LOAD '/path/to/fractalsql.duckdb_extension';"; cat demo/<kit-file>.sql; } \
>     | duckdb -bail -unsigned
> ```
> Drop `-bail` for the kits that print an expected error:
> `demo-vertical-periodicity-portfolio-selection.sql` ends with an
> enterprise-tier call, which reports that the tier is not loaded on a
> community build, and on a run with no reasoning endpoint configured the
> kits that dispatch to the model report that no endpoint is configured.
> The shell carries on past either one, so the rest of the file still runs.

## Which kit should I run?

| If your problem is… | Run this kit | Agents it exercises | Agent & recipe |
|---|---|---|---|
| Portfolio construction / regime detection | `demo-vertical-quant-finance.sql` | `fractal_agent_regime_triage`, `fractal_agent_rebalance_sibling`, `fractal_optimize_portfolio`, `fractal_dimension_dfa`/`_drift`, `fractal_change_point_detect`, `fractal_search_trajectory` | [fractal_agent_regime_triage](api-agency.md#regime-triage--fractal_agent_regime_triage), [fractal_agent_rebalance_sibling](api-agency.md#rebalance-sibling--fractal_agent_rebalance_sibling) |
| Patient monitoring / clinical telemetry | `demo-vertical-medtech-clinical.sql` | `fractal_agent_patient_deterioration_triage`, `fractal_hybrid_clinical_search`, `fractal_search_trajectory`, vascular/cortical/nerve geometry | [fractal_agent_patient_deterioration_triage](api-agency.md#patient-deterioration-triage--fractal_agent_patient_deterioration_triage) |
| Recommendation / diverse search | `demo-vertical-recommendation-search.sql` | `fractal_agent_recommend_diverse`, `fractal_agent_feedback_audit`, `fractal_search_explore`, `fractal_search_telemetry`, `fractal_cross_modal_search` | [fractal_agent_recommend_diverse](api-agency.md#recommend-diverse--fractal_agent_recommend_diverse), [fractal_agent_feedback_audit](api-agency.md#feedback-audit--fractal_agent_feedback_audit) |
| Edge / autonomous fleet allocation | `demo-vertical-sovereign-edge-ai.sql` | `fractal_agent_recommend_diverse`, `fractal_optimize_portfolio`, `fractal_dimension_boxcount`, Sniper (`fractal_sfs_converge`) | [fractal_agent_recommend_diverse](api-agency.md#recommend-diverse--fractal_agent_recommend_diverse) |
| Maritime / aviation track anomaly | `demo-vertical-maritime-defense.sql` | `fractal_agent_track_anomaly`, `fractal_search_trajectory`, `fractal_dimension_dfa`, Scout | [fractal_agent_track_anomaly](api-agency.md#track-anomaly--fractal_agent_track_anomaly) |
| Fleet logistics / detour detection | `demo-vertical-fleet-logistics.sql` | `fractal_agent_detour_classify`, `fractal_agent_recommend_diverse`, `fractal_search_trajectory`, `fractal_dimension_boxcount` | [fractal_agent_detour_classify](api-agency.md#detour-classify--fractal_agent_detour_classify), [fractal_agent_recommend_diverse](api-agency.md#recommend-diverse--fractal_agent_recommend_diverse) |
| Smart cities / IoT sensor grids | `demo-vertical-smart-cities-iot.sql` | `fractal_agent_network_coverage_alert`, `fractal_dimension_dfa`/`_drift`/`_boxcount`, `fractal_morphological_complexity`, Scout | [fractal_agent_network_coverage_alert](api-agency.md#network-coverage-alert--fractal_agent_network_coverage_alert) |
| Cybersecurity / network behavior analytics | `demo-vertical-cybersecurity-threat-detection.sql` | `fractal_agent_track_anomaly`, `fractal_agent_recommend_diverse`, `fractal_search_trajectory`, `fractal_dimension_dfa`/`_drift`, `fractal_periodogram`, Scout | [fractal_agent_track_anomaly](api-agency.md#track-anomaly--fractal_agent_track_anomaly) |
| Structural biology / single-cell genomics | `demo-vertical-biotech-genomics.sql` | `fractal_tda_persistence_diagram`, `fractal_vector_lp_distance` (raw primitives, no agents) | [api-analytics.md](api-analytics.md#time-series-and-topology) |
| Edge swarm / robotics coordination | `demo-vertical-agentic-edge-swarm.sql` | `fractal_state_fingerprint` + `fractal_cycle_detect` (via `fractal_agent_detect_loop`), `fractal_vector_quantize_int8`/`_binary` + `fractal_vector_hamming_distance`, `fractal_optimize_subset` | [fractal_agent_detect_loop](api-agency.md#fractal_agent_detect_loop), [api-analytics.md](api-analytics.md#vector-math-and-quantization) |
| **Agentic:** DevOps / SRE dispatch + safety | `demo-vertical-agentic-ops-devops.sql` | `fractal_agent_route_task`, `fractal_agent_outlier_intercept`, `fractal_agent_anomaly_triage` + `fractal_agent_detect_loop`, `fractal_agent_threat_triage` blueprint (a composed-agent reference design, see [Reference blueprints](api-agency.md#reference-blueprints-domain-agents)) | [fractal_agent_route_task](api-agency.md#route-task--fractal_agent_route_task), [fractal_agent_outlier_intercept](api-agency.md#outlier-intercept--fractal_agent_outlier_intercept), [fractal_agent_anomaly_triage](api-agency.md#anomaly-triage--fractal_agent_anomaly_triage) |
| **Agentic:** FinTech portfolio rebalance + MCTS | `demo-vertical-agentic-fintech-mcts.sql` | `fractal_agent_rebalance_sibling`, `fractal_agent_plan_explore`, `fractal_agent_portfolio_rebalance` blueprint, `fractal_optimize_portfolio` | [fractal_agent_rebalance_sibling](api-agency.md#rebalance-sibling--fractal_agent_rebalance_sibling), [fractal_agent_plan_explore](api-agency.md#building-blocks-the-six-universal-agents) |
| **Agentic:** Customer support recall + recommend | `demo-vertical-agentic-customer-support.sql` | `fractal_agent_recall_hybrid`, `fractal_agent_recommend_diverse`, `fractal_agent_trajectory_predict`, Scout | [fractal_agent_recall_hybrid](api-agency.md#recall-hybrid--fractal_agent_recall_hybrid), [fractal_agent_recommend_diverse](api-agency.md#recommend-diverse--fractal_agent_recommend_diverse) |
| **Agentic:** EV fleet battery health / thermal runaway | `demo-vertical-ev-battery-lifecycle.sql` | `fractal_agent_patient_deterioration_triage`, `fractal_agent_anomaly_triage` | [fractal_agent_patient_deterioration_triage](api-agency.md#patient-deterioration-triage----fractal_agent_patient_deterioration_triage), [fractal_agent_anomaly_triage](api-agency.md#anomaly-triage----fractal_agent_anomaly_triage) |
| **Agentic:** ADAS / autonomous-driving safety validation | `demo-vertical-adas-safety-validation.sql` | `fractal_agent_outlier_intercept`, `fractal_search_trajectory` | [fractal_agent_outlier_intercept](api-agency.md#outlier-intercept----fractal_agent_outlier_intercept) |
| **Agentic:** Connected-vehicle warranty & repair routing | `demo-vertical-v2x-warranty-triage.sql` | `fractal_agent_route_task`, `fractal_agent_recall_hybrid`, `fractal_hybrid_clinical_search` | [fractal_agent_route_task](api-agency.md#route-task----fractal_agent_route_task), [fractal_agent_recall_hybrid](api-agency.md#recall-hybrid----fractal_agent_recall_hybrid) |
| **Agentic:** Critical-consumables inventory & depot replenishment | `demo-vertical-critical-inventory-routing.sql` | `fractal_agent_allocate`, `fractal_dimension_dfa`, `fractal_optimize_portfolio` | [fractal_agent_allocate](api-agency.md#allocate----fractal_agent_allocate) |
| **Agentic:** Heavy-machinery / fleet predictive maintenance | `demo-vertical-heavy-industry-predictive-maintenance.sql` | `fractal_agent_anomaly_triage`, `fractal_agent_patient_deterioration_triage` | [fractal_agent_anomaly_triage](api-agency.md#anomaly-triage----fractal_agent_anomaly_triage), [fractal_agent_patient_deterioration_triage](api-agency.md#patient-deterioration-triage----fractal_agent_patient_deterioration_triage) |
| **Agentic:** Grid balancing (renewables + storage dispatch) | `demo-vertical-climatech-grid-balancing.sql` | `fractal_agent_anomaly_triage`, `fractal_agent_allocate`, `fractal_dimension_drift`, `fractal_optimize_portfolio` | [fractal_agent_anomaly_triage](api-agency.md#anomaly-triage----fractal_agent_anomaly_triage), [fractal_agent_allocate](api-agency.md#allocate----fractal_agent_allocate) |
| Hazmat / occupational exposure triage | `demo-vertical-hazmat-occupational-triage.sql` | `fractal_agent_patient_deterioration_triage`, `fractal_hybrid_clinical_search`, `fractal_search_trajectory` | [fractal_agent_patient_deterioration_triage](api-agency.md#patient-deterioration-triage----fractal_agent_patient_deterioration_triage) |
| Scenario planning & simulation training | `demo-vertical-scenario-planning-simulation.sql` | `fractal_agent_plan_explore`, `fractal_search_explore` (Scout) | [fractal_agent_plan_explore](api-agency.md#fractal_agent_plan_explore) |
| Avionics / flight-path fault prediction | `demo-vertical-avionics-fault-prediction.sql` | `fractal_agent_track_anomaly`, `fractal_dimension_dfa`, `fractal_search_trajectory` | [fractal_agent_track_anomaly](api-agency.md#track-anomaly----fractal_agent_track_anomaly) |
| Satellite constellation coverage gaps | `demo-vertical-satellite-constellation-coverage.sql` | `fractal_agent_network_coverage_alert`, `fractal_agent_schedule_workload`, `fractal_morphological_complexity` | [fractal_agent_network_coverage_alert](api-agency.md#network-coverage-alert----fractal_agent_network_coverage_alert), [fractal_agent_schedule_workload](api-agency.md#schedule-workload----fractal_agent_schedule_workload) |
| Telecom account-change screening (SIM swap, port-out) | `demo-vertical-telecom-account-anomaly-screening.sql` | `fractal_agent_outlier_intercept` | [fractal_agent_outlier_intercept](api-agency.md#outlier-intercept----fractal_agent_outlier_intercept) |
| Telecom traffic / bandwidth dispatch to the best node | `demo-vertical-telecom-traffic-routing.sql` | `fractal_agent_route_task` | [fractal_agent_route_task](api-agency.md#route-task----fractal_agent_route_task) |
| Industrial emissions / utility-leak detection | `demo-vertical-climatech-emissions-monitoring.sql` | `fractal_agent_anomaly_triage`, `fractal_dimension_drift` | [fractal_agent_anomaly_triage](api-agency.md#anomaly-triage----fractal_agent_anomaly_triage) |
| Physical climate-risk exposure (wildfire / flood / drought) | `demo-vertical-climatech-risk-exposure.sql` | `fractal_agent_network_coverage_alert`, `fractal_morphological_complexity` | [fractal_agent_network_coverage_alert](api-agency.md#network-coverage-alert----fractal_agent_network_coverage_alert) |
| RF / signal-interference spectrum sensing | `demo-vertical-rf-spectrum-sensing.sql` | `fractal_spectrogram_entropy`, `fractal_periodogram`, `fractal_change_point_detect` | [api-analytics.md](api-analytics.md#time-series-and-topology) |
| Event-stream anomaly triage: latency regime shifts and retry-storm periodicity | `demo-vertical-event-stream-anomaly-triage.sql` | `fractal_agent_anomaly_triage`, `fractal_periodogram`, `fractal_search_trajectory` | [fractal_agent_anomaly_triage](api-agency.md#anomaly-triage----fractal_agent_anomaly_triage) |
| Outlier interception: screen sessions against known abuse signatures and measure click footprint | `demo-vertical-outlier-interception-footprint.sql` | `fractal_agent_outlier_intercept`, `fractal_dimension_boxcount` | [fractal_agent_outlier_intercept](api-agency.md#outlier-intercept----fractal_agent_outlier_intercept) |
| **Agentic:** Budget reallocation: attribution routing and risk-aware allocation across channels | `demo-vertical-agentic-budget-reallocation.sql` | `fractal_agent_allocate`, `fractal_optimize_portfolio`, `fractal_agent_route_task`, `fractal_dimension_dfa` | [fractal_agent_allocate](api-agency.md#allocate----fractal_agent_allocate), [fractal_agent_route_task](api-agency.md#route-task----fractal_agent_route_task) |
| Stalled-process triage: baseline-vs-current drift across a staged pipeline | `demo-vertical-stalled-process-triage.sql` | `fractal_agent_patient_deterioration_triage`, `fractal_hybrid_clinical_search`, `fractal_search_trajectory` | [fractal_agent_patient_deterioration_triage](api-agency.md#patient-deterioration-triage----fractal_agent_patient_deterioration_triage) |
| Intent matching: diverse candidate selection and diverse content recommendation | `demo-vertical-intent-matching-discovery.sql` | `fractal_search_explore` (Scout), `fractal_agent_recommend_diverse` | [fractal_agent_recommend_diverse](api-agency.md#recommend-diverse----fractal_agent_recommend_diverse) |
| **Agentic:** Ranking and next-action: hybrid recall, diverse actions and a natural-language query | `demo-vertical-agentic-next-action-ranking.sql` | `fractal_agent_recall_hybrid`, `fractal_agent_recommend_diverse`, `fractal_sql_agent` | [fractal_agent_recall_hybrid](api-agency.md#recall-hybrid----fractal_agent_recall_hybrid), [fractal_agent_recommend_diverse](api-agency.md#recommend-diverse----fractal_agent_recommend_diverse), [fractal_sql_agent](api-agency.md#fractal_sql_agent) |
| Document risk drift: regime detection, diverse variants and diverse replacements | `demo-vertical-document-risk-drift.sql` | `fractal_dimension_drift`, `fractal_agent_anomaly_triage`, `fractal_search_explore` (Scout), `fractal_agent_recommend_diverse` | [fractal_agent_anomaly_triage](api-agency.md#anomaly-triage----fractal_agent_anomaly_triage), [fractal_agent_recommend_diverse](api-agency.md#recommend-diverse----fractal_agent_recommend_diverse) |
| Coordinated-record detection: signature screening, trajectory search and location footprint | `demo-vertical-coordinated-record-detection.sql` | `fractal_agent_outlier_intercept`, `fractal_dimension_boxcount`, `fractal_search_trajectory` | [fractal_agent_outlier_intercept](api-agency.md#outlier-intercept----fractal_agent_outlier_intercept) |
| **Agentic:** Sensor telemetry: non-linear demand detection and risk-aware allocation | `demo-vertical-sensor-telemetry-allocation.sql` | `fractal_dimension_dfa`, `fractal_optimize_portfolio`, `fractal_agent_allocate` | [fractal_agent_allocate](api-agency.md#allocate----fractal_agent_allocate) |
| **Agentic:** Simulated-economy drift: periodicity, non-linear inflation and loop detection | `demo-vertical-simulated-economy-drift.sql` | `fractal_periodogram`, `fractal_dimension_dfa`, `fractal_optimize_portfolio`, `fractal_agent_detect_loop` | [fractal_agent_detect_loop](api-agency.md#fractal_agent_detect_loop) |
| **Agentic:** Multi-series forecasting: non-linear demand detection and replenishment allocation | `demo-vertical-multi-series-replenishment.sql` | `fractal_dimension_dfa`, `fractal_optimize_portfolio`, `fractal_agent_allocate` | [fractal_agent_allocate](api-agency.md#allocate----fractal_agent_allocate) |
| Periodicity detection: cycle strength per series and risk-aware portfolio selection | `demo-vertical-periodicity-portfolio-selection.sql` | `fractal_periodogram`, `fractal_optimize_portfolio`, `fractal_agent_recommend_diverse`, `fractal_agent_diverse_portfolios` (Enterprise) | [fractal_agent_recommend_diverse](api-agency.md#recommend-diverse----fractal_agent_recommend_diverse), [fractal_agent_diverse_portfolios](api-agency.md#diverse-portfolios----fractal_agent_diverse_portfolios) |
| **Agentic:** Recall and diverse recommendation: Scout offers, hybrid recall and a natural-language query | `demo-vertical-agentic-recall-recommendation.sql` | `fractal_search_explore` (Scout), `fractal_agent_recall_hybrid`, `fractal_sql_agent` | [fractal_agent_recall_hybrid](api-agency.md#recall-hybrid----fractal_agent_recall_hybrid), [fractal_sql_agent](api-agency.md#fractal_sql_agent) |
| Spatial footprint complexity: box-counting dimension, portfolio risk and diverse comparables | `demo-vertical-spatial-footprint-portfolio-risk.sql` | `fractal_dimension_boxcount`, `fractal_optimize_portfolio`, `fractal_dimension_dfa`, `fractal_search_explore` (Scout) | [api-analytics.md](api-analytics.md#time-series-and-topology) |

> Not sure which agent does what? The
> [decision table](api-agency.md#which-agent-should-i-use) maps every problem
> shape to its agent.

## Domain kits (run with no model)

These ten run almost entirely **without a reasoning endpoint**: only the
closing `fractal_reason()` narrative needs one, so you can see the
retrieval/optimization/geometry results immediately and pull a model later
just for the summary (the two newest verticals, Biotech/Genomics and
Agentic Edge Swarm, are raw-primitive showcases with no reasoning
endpoint at all). The kits store per-entity vectors as DuckDB's own
native list/array types: plain `DOUBLE[]` columns and fixed-size
`FLOAT[dim]` arrays, whose width is enforced by the type at write time
(see the [storage note](features.md#storage-floatdim-vs-double) in
[features.md](features.md)).

### Quantitative Finance -- `demo-vertical-quant-finance.sql`
A 25-asset factor-model portfolio where `fractal_optimize_portfolio` picks the
best 8, and a 300-point price series with a deliberate volatility regime
change at t=240 that `fractal_dimension_dfa`/`_drift` detect automatically and
`fractal_change_point_detect` localizes to the boundary.
`fractal_search_trajectory` then finds which of 10 historical quarterly
rebalances the new allocation most resembles: the productized form is
`fractal_agent_rebalance_sibling` and `fractal_agent_regime_triage`.

### MedTech / Clinical -- `demo-vertical-medtech-clinical.sql`
40 synthetic patients, vitals stored as fixed 5-dimensional `double[5]`
columns (write-time dimension enforcement from the type itself).
`fractal_hybrid_clinical_search` over an age/condition cohort computed with
ordinary SQL, `fractal_search_trajectory` for a patient's current vitals vs.
their admission baseline (the productized form is `fractal_agent_patient_deterioration_triage`),
plus all four domain-geometry functions on small pre-extracted
fixtures (vessel graph, reference mesh, nerve skeleton).

### Recommendation / Search -- `demo-vertical-recommendation-search.sql`
A 300-item, 6-genre catalog for diverse "you might also like" discovery, and
the **full stateful-diversity loop**: enable Diversify, search, report negative
feedback on the top result, re-search the same query, confirm it's now avoided:
the real differentiator over plain top-K or MMR. Productized form:
`fractal_agent_recommend_diverse` and `fractal_agent_feedback_audit`. Also covers
`fractal_cross_modal_search` (content + behavior vectors, weighted).

### Sovereign / Edge AI -- `demo-vertical-sovereign-edge-ai.sql`
FractalSQL's whole story fits this vertical natively: search, reasoning, and
optimization all run as pure C inside the same DuckDB process, no external
vector-DB service. A 50-node edge fleet: Sniper for an ideal node profile,
Scout for diverse fleet profiles, `fractal_dimension_boxcount` over a
deployment grid, and `fractal_optimize_portfolio` repurposed as a general
on-device resource allocator (picking 6-of-50 nodes for a distributed job).

### Maritime / Defense -- `demo-vertical-maritime-defense.sql`
30 synthetic AIS vessel tracks (fixed 4-dimensional `double[]` track-state
vectors), one with a deliberate
course deviation. `fractal_search_trajectory` on the current-vs-baseline track
delta for "what changed" deviation detection, nearest/diverse-track clustering
across the fleet, and `fractal_dimension_dfa` on heading-change series to
separate smooth transit from erratic maneuvering. Productized form:
`fractal_agent_track_anomaly`.

### Fleet Logistics -- `demo-vertical-fleet-logistics.sql`
A 40-vehicle delivery fleet (fixed 4-dimensional `double[]`
track-state vectors), one running a deliberate
detour. Diverse route/zone clustering, a cohort-restricted search ("today's
route-3 vehicles only"), detour detection via `fractal_search_trajectory`, and
GPS-trace complexity via `fractal_dimension_boxcount`. Productized form:
`fractal_agent_detour_classify`.

### Smart Cities / IoT -- `demo-vertical-smart-cities-iot.sql`
A 400-sensor city grid (traffic / air-quality / noise): spatial coverage
diagnostics, an air-quality event detected via `fractal_dimension_dfa`/`_drift`
on a series with a deliberate regime shift, and diverse representative-zone
sampling via Scout. Productized form: `fractal_agent_network_coverage_alert`.

### Cybersecurity -- `demo-vertical-cybersecurity-threat-detection.sql`
A 35-host fleet across three zones (fixed 4-dimensional `double[]`
track-state vectors), one host showing a
stealthy compromise: outbound connections, destination ports, and DNS query
volume all spike while failed-auth stays flat (not a brute-force signature).
Diverse traffic-profile clustering for threat hunting, a zone-restricted
("DMZ only") search, compromise detection via `fractal_search_trajectory`,
beaconing-onset regime detection via `fractal_dimension_dfa`/`_drift`, with
`fractal_periodogram` reading the beacon interval itself out of the
post-shift traffic.
Productized form: `fractal_agent_track_anomaly` and `fractal_agent_recommend_diverse`.

### Biotech / Structural Biology & Genomics -- `demo-vertical-biotech-genomics.sql`
A synthetic scRNA-seq-style point cloud in 3D -- 60 points in two
well-separated clusters (30 + 30) plus 6 points bridging them in a rough
ring -- analyzed by `fractal_tda_persistence_diagram`:
exact 0-dim persistence (cluster birth/death bars) plus the graph-cycle-rank
Betti-1, which flags the closed loop the shape actually has. Then
`fractal_vector_lp_distance` between the two cluster centroids,
contrasting p=1 Manhattan (robust to per-feature outliers) against
p=2 Euclidean (sharper geometric contrast) between the two related cell
populations. Raw primitives only, no reasoning endpoint needed.

### Agentic Edge / Robotics Swarm -- `demo-vertical-agentic-edge-swarm.sql`
A battery- and bandwidth-constrained 20-node edge swarm (16-dim compressed
state summaries per node):
`fractal_vector_quantize_int8` (4x) and `fractal_vector_quantize_binary`
(32x) for compressed peer-state memory with `fractal_vector_hamming_distance`
as the cheap candidate filter ahead of a full-precision re-rank,
`fractal_agent_detect_loop` on a node stuck oscillating between two headings
vs. one genuinely exploring (the SimHash fingerprint + Brent cycle detector
exercised on their actual use case), and `fractal_optimize_subset`'s
value-weighted allocation for battery-constrained task routing. Raw
primitives and shipped presets only, no reasoning endpoint needed.

## Agentic kits (model-on, composed agents)

These three compose the six Universal Agents into multi-step Domain Agent
compositions. Each section calls the shipped `fractal_agent_*` recipes (and,
where the composition itself is the lesson, the Universal Agents) directly --
in this build a composition is a native extension function, not a SQL wrapper,
because DuckDB has no procedural SQL (see
[composition-guide.md](composition-guide.md) for the general building-block
guide and what composing a custom variant looks like). Every section needs
reasoning configured
([reasoning-setup.md](reasoning-setup.md)). See
[api-agency.md → Reference blueprints](api-agency.md#reference-blueprints-domain-agents)
for the per-blueprint composition table (hand-composed reference designs
with their shipped agent equivalents).

### DevOps / SRE -- `demo-vertical-agentic-ops-devops.sql`
A sub-agent dispatcher (`fractal_agent_route_task`), a pre-commit safety barrier
(`fractal_agent_outlier_intercept`), SOC incident triage (`fractal_agent_anomaly_triage`
+ the `fractal_agent_threat_triage` blueprint), and a loop-safety monitor
(`fractal_agent_detect_loop`). This is the kit to read if you want to see **guardrails
composed in**: the intercept + detect-loop pattern is the template for any
autonomous agent that acts on real systems.

### FinTech -- `demo-vertical-agentic-fintech-mcts.sql`
Cardinality-constrained portfolio rebalance (`fractal_agent_rebalance_sibling` +
the `fractal_agent_portfolio_rebalance` blueprint) and MCTS-style strategy exploration
(`fractal_agent_plan_explore`). Read this kit to see **optimization + reasoning composed**:
the SFS Sharpe optimizer runs, then `fractal_reason` writes the rationale for
the weight shift.

### Customer Support -- `demo-vertical-agentic-customer-support.sql`
Hybrid memory recall (`fractal_agent_recall_hybrid`), feedback-aware
recommendation (`fractal_agent_recommend_diverse`), and state-drift forecasting
(`fractal_agent_trajectory_predict`). Read this kit to see **retrieval composed with
stateful diversify**: the enable-diversify / search / feedback / re-search
loop wired into a real agent.

## More domain kits

Seventeen further domain kits, added with the spectrogram-entropy primitive. Same shape as the ten above: a synthetic dataset built by the script itself, the agents that genuinely fit, a closing `fractal_reason()` narrative, and `DROP TABLE IF EXISTS` at the top so every kit re-runs. The analytic sections run with no model; the reasoned columns need the reasoning plugin. Each is fully deterministic (no `random()` / `RAND()`), so every run returns the same numbers.

### Hazmat / Occupational Exposure — `demo-vertical-hazmat-occupational-triage.sql`
36 workers across work zones and shifts; a reactor-bay night-shift crew shows elevated dose rate, temperature and heart rate. `fractal_agent_patient_deterioration_triage` is reused verbatim (cohort search plus baseline-vs-current drift, with exposure columns in place of clinical vitals). Closes with a medical-countermeasure dispatch recommendation.

### Scenario Planning & Simulation — `demo-vertical-scenario-planning-simulation.sql`
24 candidate continuity scenarios in four clusters. Scout (`fractal_search_explore`) picks six deliberately different ones with no model; `fractal_agent_plan_explore` (MCTS-style exploration, needs an embedding endpoint) generates scenario variants from a seed state description. Closes with a summary of the scenario set.

### Avionics Fault Prediction — `demo-vertical-avionics-fault-prediction.sql`
A 12-aircraft fleet with planned-path and current-state vectors in 3D; one flight has drifted far off plan and has erratic heading changes. `fractal_agent_track_anomaly` generalizes straight from the maritime kit's 2D tracks to 3D flight paths (trajectory deviation search plus the heading-change DFA exponent). Closes with a reasoned classification of the deviation.

### Satellite Constellation Coverage — `demo-vertical-satellite-constellation-coverage.sql`
A 20 x 20 footprint lattice, healthy vs a copy missing an 8 x 8 dead zone (the gap raises lacunarity). `fractal_agent_network_coverage_alert` combines the footprint morphology with link-quality telemetry drift; `fractal_agent_schedule_workload` models launch-slot scheduling for the replacement payload. Coverage-gap angle only: orbital drift and collision detection are a different problem.

### Telecom Account-Anomaly Screening — `demo-vertical-telecom-account-anomaly-screening.sql`
Screens proposed account changes (SIM swap, port-out, new device, location jump) against a history of known-anomalous patterns with `fractal_agent_outlier_intercept`, reused verbatim: the same shape as the ADAS kit. Shows cosine (shape of the event) against exact Euclidean (intensity counts). A general pre-commit safety check, not a fraud-specific product.

### Telecom Traffic Routing — `demo-vertical-telecom-traffic-routing.sql`
Five session requests dispatched to the best-capable of four network nodes under a token budget with `fractal_agent_route_task`, reused verbatim; then re-routed over only the nodes with headroom so a loaded node's request is re-homed. Nearest-capable-node dispatch, not multi-hop rerouting around a failed node.

### Climate Tech: Emissions Monitoring — `demo-vertical-climatech-emissions-monitoring.sql`
Methane, CO2 and pipeline-pressure sensors; one methane sensor starts leaking (an accelerating concentration ramp). `fractal_agent_anomaly_triage` is reused verbatim to flag the shift into a leak regime; the same call screens a water-distribution pressure series. Closes with a leak narrative and field response.

### Climate Tech: Risk Exposure — `demo-vertical-climatech-risk-exposure.sql`
A 20 x 20 hazard-sensor grid with dry-season and wet-season fuel-moisture deficit indices. `fractal_agent_network_coverage_alert` is reused verbatim: morphology of the elevated-hazard region plus telemetry drift, shaped like the smart-cities kit's sensor grid. Closes with an exposure narrative for an insured portfolio.

### RF Spectrum Sensing — `demo-vertical-rf-spectrum-sensing.sql`
Three channels x 256 samples: a beacon that gets jammed partway through, an empty noise channel and a steady carrier. `fractal_periodogram` says which frequencies dominate, the new `fractal_spectrogram_entropy` says how ordered the spectrum is window by window, and `fractal_change_point_detect` localizes when the order was lost, straight from the entropy series. A raw-primitive showcase: no agents and no model until the closing triage narrative.

### Event-Stream Anomaly Triage — `demo-vertical-event-stream-anomaly-triage.sql`
Four endpoints x 96 one-minute intervals of request latency; one endpoint (EP-C) develops an accelerating latency ramp (a timeout cascade) and a second (EP-B) has a retry-storm oscillation in its request rate. `fractal_agent_anomaly_triage` flags the latency regime shift, `fractal_periodogram` finds the retry-storm period, and `fractal_search_trajectory` finds which endpoints' success-rate / latency / timeout / fill health has moved the same way EP-C's did.

### Outlier Interception & Footprint Analysis — `demo-vertical-outlier-interception-footprint.sql`
Screens proposed traffic sessions against a history of known-abuse signatures with `fractal_agent_outlier_intercept` (cosine by default, exact Euclidean when magnitude should count), then uses `fractal_dimension_boxcount` on click-coordinate clouds: organic traffic fills the page (a high box-counting dimension) while an automated farm hammering a handful of targets collapses onto a line (a dimension near 1).

### Stalled-Process Triage — `demo-vertical-stalled-process-triage.sql`
36 open items across segments and stages; three tier-1 items in the review stage show the same stall signature (time-in-stage far above the healthy velocity, falling engagement, a silent owner, deepening concessions). `fractal_agent_patient_deterioration_triage` is reused verbatim (cohort search plus baseline-vs-current drift, with item-health columns in place of clinical vitals): an item's stage-entry telemetry plays the patient's admission baseline.

### Intent Matching & Diverse Selection — `demo-vertical-intent-matching-discovery.sql`
24 target entities in four intent clusters (category + stage signal vectors) and a 30-item content library. Scout (`fractal_search_explore`, the diversity-first MMR search) picks six deliberately different entities around a target profile instead of six near-duplicates, and `fractal_agent_recommend_diverse` returns a repulsion-diverse set of content items for the chosen entity: no model needed for either.

### Document Risk Drift & Diverse Alternatives — `demo-vertical-document-risk-drift.sql`
Four agreements x 96 weekly clause-risk reviews; one agreement's amended terms drift into a new regime (an accelerating risk creep). `fractal_dimension_drift` (the regime-detection recipe from the quant-finance kit, applied to document risk) finds it; Scout (`fractal_search_explore`) pulls six deliberately different clause variants out of the 24-clause corpus so the reviewer sees the spread rather than six near-copies; and `fractal_agent_recommend_diverse` proposes diverse approved replacement language.

### Record Clustering & Severity Trajectory — `demo-vertical-coordinated-record-detection.sql`
A review desk screens new submissions against known ring signatures with `fractal_agent_outlier_intercept`, finds the records that moved from the normal severity baseline the way a staged ring does with `fractal_search_trajectory`, and measures the geographic footprint of event locations with `fractal_dimension_boxcount` (organic events scatter across the city; a staged ring repeats along one road).

### Periodicity Detection & Portfolio Selection — `demo-vertical-periodicity-portfolio-selection.sql`
Six items x 96 days of sales velocity with a weekly demand cycle of differing strength. `fractal_periodogram` quantifies which items are genuinely periodic; `fractal_optimize_portfolio` picks the 3 items that get the scheduled action (a Sharpe-style trade of margin recovered against demand volatility); `fractal_agent_recommend_diverse` proposes a diverse set of substitute items. On the FractalSQL Enterprise edition `fractal_agent_diverse_portfolios` (multimodal optimization) also returns structurally different schedules; on the FractalSQL Community edition that step reports "enterprise tier not loaded".

### Spatial Footprint Complexity & Portfolio Risk — `demo-vertical-spatial-footprint-portfolio-risk.sql`
Three districts' parcel footprints (a dense grid, a single arterial strip and a two-corridor district) measured with `fractal_dimension_boxcount`: the lower the dimension the more linear the frontage and the more a valuation depends on a few corridors. Six asset classes x 64 months of index values feed `fractal_dimension_dfa` and `fractal_optimize_portfolio` (pick 3 classes for the renewal push; the accelerating one is flagged), and Scout (`fractal_search_explore`) selects six deliberately different comparable parcels so the reviewer sees the spread of the market, not six near-twins.

## More agentic kits

Twelve further agentic kits. Each chains two installed agents (or an agent and a raw primitive) the way the three agentic kits above do: the composition is shown hand-composed first, then as the shipped one-call agent, then closed with a reasoned narrative. None of them adds a new agent function: they point existing agents at a new table.

### EV Battery Lifecycle — `demo-vertical-ev-battery-lifecycle.sql`
3 vehicles x 96 readings (state of health, pack temperature, cell voltage); one vehicle develops an accelerating thermal ramp and SoH fade. Chains `fractal_agent_patient_deterioration_triage` (cohort search plus baseline-vs-current trajectory drift: a vehicle's intake baseline plays the patient's admission baseline) with `fractal_agent_anomaly_triage` (the DFA drift exponent of the temperature series), each shown hand-composed first and then as the shipped one-call agent, closing with one maintenance / safety recommendation.

### ADAS Safety Validation — `demo-vertical-adas-safety-validation.sql`
A pre-commit safety barrier. `fractal_agent_outlier_intercept` screens three proposed maneuvers against a history of known-bad states (cosine by default, exact Euclidean when magnitude should count: a gentle lane change is intercepted by cosine but allowed by l2), and `fractal_search_trajectory` flags a vehicle whose routing vector has strayed from the fleet baseline. Closes with one go / no-go verdict.

### V2X Warranty Triage — `demo-vertical-v2x-warranty-triage.sql`
Routes an incoming diagnostic-trouble-code event to the best-capable repair workflow under a token budget (`fractal_agent_route_task`), then recalls similar historical warranty claims with a strict metadata filter (`fractal_agent_recall_hybrid`; a two-predicate model-year-and-component cohort is shown with `fractal_hybrid_clinical_search`). Closes with a dispatch + claim-context summary.

### Critical Inventory Routing — `demo-vertical-critical-inventory-routing.sql`
Six depots x 64 days of consumption. `fractal_dimension_dfa` finds the depot whose demand is accelerating (non-linear) rather than merely high; `fractal_optimize_portfolio` picks which 3 depots get the scheduled replenishment run with the risk matrix inflated by the DFA exponent; the bursty depot is flagged for expedited restock instead. `fractal_agent_allocate` is the shipped one-call form of the optimizer step. Closes with the rebalancing rationale.

### Heavy-Industry Predictive Maintenance — `demo-vertical-heavy-industry-predictive-maintenance.sql`
Four pumps and drives x 96 readings; one pump develops an accelerating bearing-vibration defect. `fractal_agent_anomaly_triage` flags the vibration regime shift and `fractal_agent_patient_deterioration_triage` measures drift from the asset's intake baseline with a same-class cohort search (an asset plays the patient). Closes with a maintenance-window recommendation. This is the wear / lifecycle half of heavy-industry monitoring.

### Climate Tech: Grid Balancing — `demo-vertical-climatech-grid-balancing.sql`
Grid-frequency telemetry for three balancing areas; one loses damping and its oscillation envelope grows. `fractal_dimension_drift` (the volatility-regime recipe from the quant-finance kit, applied to a grid) detects it, and `fractal_optimize_portfolio` chooses the 4 of 6 generation and storage resources that carry the response, with a ramp-risk matrix in which solar and wind share weather risk. `fractal_agent_anomaly_triage` and `fractal_agent_allocate` are the shipped one-call forms. Closes with the dispatch-plan rationale.

### Agentic Budget Reallocation — `demo-vertical-agentic-budget-reallocation.sql`
Six channels x 64 days of attributed outcomes. `fractal_dimension_dfa` finds the channel whose response is accelerating (a non-linear surge a plain average would hide); `fractal_optimize_portfolio` picks which 3 channels receive the scheduled budget increase with the risk matrix inflated by the DFA exponent; the surging channel is flagged for a capped, monitored test instead. `fractal_agent_allocate` is the shipped one-call form of the optimizer step, and `fractal_agent_route_task` dispatches each journey to the best-matching model under a token budget.

### Agentic Ranking & Next-Action Recommendation — `demo-vertical-agentic-next-action-ranking.sql`
30 candidates across segments, a 12-item action catalog and a natural-language question over the candidate table. `fractal_agent_recall_hybrid` recalls the most similar past candidates inside one segment (a strict metadata filter), `fractal_agent_recommend_diverse` proposes a diverse set of next actions (not four variations of 'send an email'), and `fractal_sql_agent` answers a status question in plain English by generating and running the SQL.

### Sensor Telemetry & Resource Allocation — `demo-vertical-sensor-telemetry-allocation.sql`
Six sites x 64 days of resource demand from soil-moisture sensors. `fractal_dimension_dfa` finds the site whose demand is accelerating (a non-linear trend or a failing supply line) rather than merely high; `fractal_optimize_portfolio` picks which 3 sites get the scheduled service run with the risk matrix inflated by the DFA exponent; the accelerating site is flagged for an inspection instead. `fractal_agent_allocate` is the shipped one-call form of the optimizer step.

### Simulated-Economy Drift & Loop Detection — `demo-vertical-simulated-economy-drift.sql`
Six markets x 96 days of price index; every market carries a weekly demand cycle, and one (mkt-d) enters an accelerating inflation spiral. `fractal_periodogram` confirms the weekly cycle, `fractal_dimension_dfa` flags the market that is inflating non-linearly, and `fractal_optimize_portfolio` picks the 3 markets for the scheduled sink program (the inflating market goes to an emergency price-cap instead). `fractal_agent_detect_loop` then watches trade-state logs: an automated actor that flips between the same two item states is detected while a varied actor is not.

### Multi-Series Forecasting & Replenishment — `demo-vertical-multi-series-replenishment.sql`
Six locations x 64 days of unit demand. `fractal_dimension_dfa` finds the location whose demand is accelerating (a viral item or a local event) rather than merely high; `fractal_optimize_portfolio` picks which 3 locations get the scheduled replenishment from the central hub with the risk matrix inflated by the DFA exponent; the surging location is flagged for an expedited pick instead. `fractal_agent_allocate` is the shipped one-call form of the optimizer step.

### Agentic Recall & Diverse Recommendation — `demo-vertical-agentic-recall-recommendation.sql`
24 candidate offers in four clusters and 30 abandoned sessions across categories. Scout (`fractal_search_explore`) picks six deliberately different offers around the user's profile so the follow-up tests variety rather than six near-identical offers; `fractal_agent_recall_hybrid` recalls the most similar past sessions inside the user's category (a strict metadata filter); and `fractal_sql_agent` answers a question over the session table in plain English.

## Other industry labels, same kits

Some industries are an existing kit under a different label. These need no script of their own; run the kit named and read the label as the use case.

| Industry label | Run | Exercises |
|---|---|---|
| Fire / Rescue: emergency fleet routing & detours | `demo-vertical-fleet-logistics.sql` | `fractal_agent_detour_classify`, `fractal_search_trajectory`, `fractal_dimension_boxcount` |
| Fire / Rescue: 911 unit & task dispatch | `demo-vertical-telecom-traffic-routing.sql` or `demo-vertical-v2x-warranty-triage.sql` | `fractal_agent_route_task` |
| Forestry: environmental monitoring | `demo-vertical-smart-cities-iot.sql` or `demo-vertical-climatech-risk-exposure.sql` | `fractal_agent_network_coverage_alert` |
| Forestry: aerial drone & ranger deployment | `demo-vertical-agentic-edge-swarm.sql` or `demo-vertical-sovereign-edge-ai.sql` | `fractal_agent_detect_loop`, `fractal_agent_schedule_workload` |
| Telecom: signal coverage & topology | `demo-vertical-smart-cities-iot.sql` or `demo-vertical-satellite-constellation-coverage.sql` | `fractal_agent_network_coverage_alert` |
| Telecom: network anomaly & beaconing detection | `demo-vertical-cybersecurity-threat-detection.sql` or `demo-vertical-rf-spectrum-sensing.sql` | `fractal_dimension_dfa`/`_drift`, `fractal_periodogram`, `fractal_spectrogram_entropy` |
| Telecom: customer churn / support-ticket routing | `demo-vertical-agentic-customer-support.sql` | `fractal_agent_recall_hybrid`, `fractal_agent_recommend_diverse`, `fractal_agent_trajectory_predict` |
| Secure cloud / zero-egress audit trail | `enterprise-qtl-audit.sql` | the QTL ledger functions (`fractal_ledger_load` / `_flush` / `_compact` / `_verify`); FractalSQL Enterprise edition |
| High-assurance communications equipment | `demo-vertical-telecom-traffic-routing.sql` or `demo-vertical-smart-cities-iot.sql` | `fractal_agent_route_task` token-budget accounting, `fractal_agent_network_coverage_alert` |
| Uncrewed systems: land vehicles | `demo-vertical-fleet-logistics.sql` | `fractal_agent_detour_classify` |
| Uncrewed systems: aerial | `demo-vertical-agentic-edge-swarm.sql` | `fractal_agent_detect_loop` |
| Climate Tech: carbon-offset / ESG portfolio construction | `demo-vertical-quant-finance.sql` | `fractal_optimize_portfolio` |
| Climate Tech: climate-driven supply-chain disruption | `demo-vertical-fleet-logistics.sql` or `demo-vertical-critical-inventory-routing.sql` | `fractal_search_trajectory`, `fractal_dimension_boxcount`, `fractal_dimension_dfa` |

## Where next

- **"How does a specific agent work, and what are its inputs?"** → the
  per-agent recipes in [api-agency.md](api-agency.md#the-sixteen-recipes).
- **"How do I build a proprietary agent that isn't in the box?"** →
  [composition-guide.md](composition-guide.md): the six Universal Agents as
  building blocks and worked composition patterns.
- **The six Universal Agents end-to-end** → run `demo/demo-agents.sql`
  through the DuckDB CLI (see the command above); it exercises all sixteen
  registered recipe agents too.
- **A specific industry, against a domain-shaped dataset** →
  `demo/demo-vertical-<name>.sql`, see the table above for the full list
  of forty-two.