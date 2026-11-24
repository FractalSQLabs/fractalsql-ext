<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# FractalSQL Feature Specification

FractalSQL is a tiered capability framework that runs discovery, reasoning, and agentic workflows inside the DuckDB process: no external RAG middleware shuffling data between the database and the LLM. It provides a progression from basic vector discovery to autonomous agentic reasoning.

---

## 🏗️ Capability Tiering Model

FractalSQL ships in two editions, each unlocking more of the four capability tiers described below (Discovery → Cognition → Agency → Analytics). The editions are a *build/licensing* axis; the capability tiers are a *functional* axis. A single install belongs to one edition and exposes whichever capability tiers that edition includes.

| Tier | Focus | Key Capabilities | Build / Requirement |
| --- | --- | --- | --- |
| **FractalSQL Community** | Discovery, Cognition, Agency, Analytics | SFS Core, Sniper Search, Scout Discovery, In-DB Reasoning, Embeddings, the six Universal Agent primitives, plus the vectorizer, analytics, and geometry families | The `fractalsql` extension, everything most installs need |
| **FractalSQL Enterprise** | Governance | Tamper-evident decision ledger (hash chain), audit trail | Community edition extension + a library at `FRACTALSQL_ENTERPRISE_LIB`, gated by that env var. See [FractalSQL Enterprise](enterprise.md) |

> **No Minimal edition.** Every binary in this build registers the full
> surface unconditionally (one registration
> chain), so nothing surfaces as an edition-gated "no such function"
> error. The only variant control is the build-time `CORE_VARIANT`
> Makefile variable (`community-sovereign-c` default,
> `community-minimal-c` search-only override)
> for embedders that link the vendored core archive directly. The
> shipped extension artifact is a single-edition Community build plus
> the runtime-gated Enterprise surface.

> **16 named recipe agents** (`fractal_agent_route_task`,
> `fractal_agent_outlier_intercept`, etc.) -- this build registers all
> sixteen itself, each a native scalar function composing the six
> Universal Agent primitives below server-side and returning one JSON
> document. They load with the extension -- no separate install step;
> the `demo/demo-*.sql` scripts call them directly by their
> `fractal_agent_*` names. See [docs/api-agency.md](api-agency.md) for
> the per-agent recipes and `demo/demo-agents.sql` for all sixteen
> exercised end to end.

---

## 🔍 Tier 1: Discovery

FractalSQL has two ways to find rows. The **Stochastic Fractal Search (SFS)** engine treats
the problem as continuous optimization and powers `fractal_sfs_converge` and the diverse
**Scout** discovery; the **IVF index** gives fast, verified nearest-neighbour search over
your stored rows, like an index lookup in standard HNSW or IVFFlat, with exact distances
and a recall you can measure.

### Indexed Search (`fractal_search`, `fractal_index_*`)

`fractal_index_create(table, column)` builds an index over the table's embedding column, and `fractal_search(table, column, query, k)` returns the `k` nearest rows to a query vector. With an index the search reads a few cells instead of every row, and it re-scores every candidate against the stored vector, so the distances it returns are **exact**: the index only chooses which rows to look at, it does not approximate the answer. Without an index the same call scans the table and returns the same distances, only slower. The nearest-row agents can search through an index too, off by default — see [Agency](api-agency.md). Building, refreshing and checking an index, and the search options, are in [Discovery](api-discovery.md#fractal_search-the-indexed-search).



### Sniper Search (`fractal_sfs_converge`)
Pure SFS convergence to the single best point minimizing cosine distance to a query over a unit box. It is a "precision" tool for finding the absolute global minimum.

### Scout Discovery (`fractal_search_explore`)
Scans a stored corpus and returns a diverse population of results: an SFS population search blended with **Maximal Marginal Relevance (MMR)** re-ranking, so the results cover the data's distinct basins of attraction instead of the "mode collapse" common in top-K search.

### Table-Backed Telemetry (`fractal_search_telemetry`)
A deterministic primitive that returns the $K$ nearest real table rows to a query. This is the ground-truth layer used by all higher-order agentic functions.

---

## 🧠 Tier 2: Cognition

The Cognition tier adds a reasoning bridge to the SFS core, allowing it to call LLMs and embedding models via a pluggable C provider interface. This enables reasoning to happen *beside* the data.

### In-Database Reasoning (`fractal_reason`)
Dispatches a query and a context payload to a configured LLM provider. Because it runs inside the backend, you can feed it the results of a Scout search or a SQL query in one statement. 

**Provider-agnostic**: the same `fractal_reason()` call works against **AWS Bedrock (SigV4)**, **Azure OpenAI**, **GCP Vertex AI**, or **local Ollama**. Switch providers via config without changing a single line of SQL. Local providers keep data on your own infrastructure; cloud providers send it to that provider under your own account and agreement (BAA-covered where your compliance posture requires it).

### Semantic Embeddings (`fractal_embed`)
Generates vectors from text using a purpose-trained embedding model. This removes the need for an external embedding pipeline for many RAG use cases.

### Safe Text-to-SQL (`fractal_text_to_sql`)
Generates SQL from natural language through a three-stage safety pipeline (parse check, statement-type allowlist, prepare/bind EXPLAIN check) and returns the validated SQL text without executing it. `fractal_sql_agent` (a Universal Agent) covers the related self-correcting variant, which does execute. See [`text-to-sql-setup.md`](text-to-sql-setup.md).

---

## 🤖 Tier 3: Agency

The Agency tier composes the Discovery and Cognition primitives into autonomous routines. This build ships 16 installable named recipes on top of the 6 reusable Universal Agent primitives below, registering all sixteen with the extension itself -- each a native scalar composing the primitives server-side and returning one JSON document (an array of objects for the recall/recommend/diverse-portfolios recipes). See [`docs/api-agency.md`](api-agency.md) for the full registry and the call shape, and `demo/demo-agents.sql` for all sixteen exercised end to end. The table below summarizes each recipe.

### Agents (the sixteen recipes)

| Agent | Recipe | Reasoning |
| --- | --- | --- |
| `fractal_agent_anomaly_triage` | drift exponent on one entity's series → reasoning triage | ✓ |
| `fractal_agent_regime_triage` | DFA + drift over one series → reasoning triage | ✓ |
| `fractal_agent_track_anomaly` | trajectory deviation + heading DFA → reasoning triage | ✓ |
| `fractal_agent_detour_classify` | trajectory deviation + box-counting → reasoning classify | ✓ |
| `fractal_agent_network_coverage_alert` | spatial morphology + telemetry drift → reasoning alert | ✓ |
| `fractal_agent_allocate` | SFS Sharpe optimizer → reasoning rationale | ✓ |
| `fractal_agent_rebalance_sibling` | optimizer + trajectory search → reasoning rationale | ✓ |
| `fractal_agent_diverse_portfolios` (enterprise) | multimodal optimizer → reasoning tradeoff summary | ✓ |
| `fractal_agent_route_task` | nearest-capability search + budget accounting → reasoning rationale | ✓ |
| `fractal_agent_schedule_workload` | `fractal_sfs_converge` refine + `fractal_search_telemetry` nearest node → reasoning rationale | ✓ |
| `fractal_agent_outlier_intercept` | distance-to-bad-state safety barrier → reasoning justification | ✓ |
| `fractal_agent_patient_deterioration_triage` | cohort search + trajectory drift → reasoning triage | ✓ |
| `fractal_agent_data_analyst` | NL → SQL → reasoning analysis (SQL runs only with an explicit `auto_execute`) | ✓ |
| `fractal_agent_recall_hybrid` | cohort-restricted vector recall | -- |
| `fractal_agent_recommend_diverse` | repulsion-diverse top-k | -- |
| `fractal_agent_feedback_audit` | diversify loop + collapse detection | -- |

### Universal Agents

The six building blocks the agents above compose. Call them directly to build your own recipe.

| Function | What it does |
| --- | --- |
| `fractal_search_agent` | Embed a query, Scout-search a table, and reason over the matched rows. |
| `fractal_rag_agent` | Focused single-turn RAG: embed, Scout-search, and reason over the result. |
| `fractal_sql_agent` | Self-correcting NL-to-SQL, retrying on `EXPLAIN`/execution failure. |
| `fractal_agent_plan_explore` | MCTS-style exploration of multiple non-overlapping strategy trajectories. |
| `fractal_agent_trajectory_predict` | Forecasts future state from a delta against historical telemetry. |
| `fractal_agent_detect_loop` | Flags infinite/repetitive agent loops via SimHash state fingerprints and Brent's cycle detector, with a DFA drift check. |

### Safe Agency & Guardrails

To prevent "hallucination-driven" database corruption, the Agent Tier implements two primary guardrails:

1. **The Prepare-Check Barrier**: `fractal_sql_agent`'s auto-execute path parses and binds the generated SQL (a prepare step) before running it -- a parser or binder error is caught and fed back to the LLM as retry feedback rather than executing a malformed statement.
2. **The Deterministic Allowlist**: `fractal_text_to_sql`'s standalone pipeline (statement-type restriction via a configured allowed-statements list) rejects disallowed statement types before anything is executed -- see [`text-to-sql-setup.md`](text-to-sql-setup.md).

---

## 📐 Tier 4: Analytics

The final tier provides mathematical primitives for analyzing the "shape" of data and state, turning raw vectors into actionable structural insights.

### Fractal Dimension Analysis
- **DFA (`fractal_dimension_dfa`)**: Analyzes the scaling exponent of a time series to distinguish between noise, random walks, and structured signals.
- **Box-Counting (`fractal_dimension_boxcount`)**: Measures the Minkowski-Bouligand dimension of a point cloud to evaluate spatial complexity.
- **Drift (`fractal_dimension_drift`)**: Detects regime changes by comparing the DFA exponent of a recent window against a baseline.
- **Change-Point Localization (`fractal_change_point_detect`)**: Localizes where a series' mean or variance shifted, complementing DFA's overall characterization.
- **Periodogram (`fractal_periodogram`)**: Exact power spectrum (direct DFT) for cadence detection such as beaconing or retry loops.
- **Spectral entropy (`fractal_spectrogram_entropy`)**: Per-window Shannon entropy of the power spectrum (0 = ordered tone, ~0.9 = noise); pair with `fractal_change_point_detect` to find when order is lost.

### Topology and State Fingerprints
- **Persistence (`fractal_tda_persistence_diagram`)**: Exact 0-dimensional persistence over a point cloud's Vietoris-Rips filtration, plus the graph cycle rank as an informational Betti-number estimate.
- **SimHash (`fractal_state_fingerprint`)**: Folds a state vector into a Hamming-comparable fingerprint where nearly-identical states collide.
- **Cycle Detection (`fractal_cycle_detect`)**: Streaming Brent's algorithm over a fingerprint stream, one output per cycle closure.

### Vector Math
- **$L_p$ Distance (`fractal_vector_lp_distance`)**: Generalized distance over `FLOAT[]` (plain vector arithmetic functions -- this build has no bespoke vector catalog type, see the Storage note below) for any $p > 0$.
- **Quantization (`fractal_vector_quantize_int8` / `_binary`)**: 4x/32x per-vector compression with optional Hamming pre-filtering ahead of a full-precision re-rank.

### Domain-Specific Geometry
FractalSQL provides optimized routines for pre-extracted biological and technical geometry:
- **Vascular Networks**: Tortuosity and branch-density for vessel graphs.
- **Cortical Folding**: Gyrification Index for brain-surface meshes.
- **Nerve Plexus**: Density and dimension for fiber skeletons.
- **Morphological Complexity**: Combined box-counting and lacunarity for segmented masks.

### Portfolio Optimization
`fractal_optimize_portfolio` uses the SFS engine to solve cardinality-constrained Sharpe-ratio maximization. It finds the best $K$ assets in a large universe without the exponential cost of a brute-force search.
`fractal_optimize_subset` generalizes the same search to value-weighted allocation over any scored item list with per-item bounds.

---

## 📈 Benchmarks & Scaling

### HNSW vs. Scout Discovery
In a benchmark of 100k vectors, dim=128, across 50 Gaussian clusters, measured directly against current Scout (DuckDB's `vss` HNSW index, `ef_search=40`, `LIMIT 50`, vs Scout population=50, iterations=8 -- see `bench/README.md` for the full methodology and how to reproduce it):
- **HNSW** (top-50) typically discovered **1 distinct cluster**, averaging ~12 ms per query.
- **Scout** (pop=50) typically discovered **6-9 clusters** (measured average 6.2), averaging ~1553 ms per query, on the order of **100x slower** (measured 131.7x in the documented run).

That tradeoff is the whole point of Scout Mode, not a hidden cost: it's $O(N \times d)$ (linear scan) by design, and it's the only way here to guarantee your LLM receives a genuinely diverse set of perspectives rather than a single collapsed cluster. It is not a drop-in replacement for HNSW. Use it where diversity matters more than latency (e.g. curated sub-corpora, not full-corpus top-k at scale).

### Storage: `FLOAT[dim]` vs `DOUBLE[]`
This build has no bespoke vector catalog type -- DuckDB's own column types are the storage story. Fixed-size arrays (`double[3]`, `float[32]`, ...) enforce their width at write time, which keeps dimension drift out at `CREATE TABLE`; that is also the type the `vss` HNSW index attaches to. The search/analytics and `fractal_vector_*` families consume plain `FLOAT[]`/`DOUBLE[]` values (check each function's signature -- `bench/README.md` documents which end of the two the search entry points take). The `fractal_vector_` prefix on those function names is just naming -- there is no `fractal_vector` type behind them.

`bench/vector_type_head_to_head.py` measures this storage axis directly at real row counts: on-disk bytes/row (via a checkpointed file-size delta) and bulk-insert throughput for `FLOAT[dim]` vs `DOUBLE[]`, with `--n`/`--dim` knobs. The realized gap depends on dimension and row count -- measure on your own data before treating either number as a promise (see `bench/README.md`'s "FLOAT[dim] vs DOUBLE[] at scale" section). The HNSW-vs-Scout comparison above covers the search-latency axis separately.

---

## 📚 API Reference

(Detailed argument tables, defaults, and ranges are available in the **[Detailed API Reference](api-discovery.md)**.)

**Discovery**
- `fractal_sfs_converge(query, ...)`: Sniper Mode convergence. $\rightarrow$ **[api-discovery.md](api-discovery.md)**
- `fractal_search_explore(table, col, query, ...)`: Scout Mode diverse exploration. $\rightarrow$ **[api-discovery.md](api-discovery.md)**
- `fractal_search_telemetry(table, col, query, k)`: Ground-truth row retrieval. $\rightarrow$ **[api-discovery.md](api-discovery.md)**

**Cognition**
- `fractal_reason(query, context)`: LLM dispatch. $\rightarrow$ **[api-cognition.md](api-cognition.md)**
- `fractal_embed(input)`: Semantic vector generation. $\rightarrow$ **[api-cognition.md](api-cognition.md)**
- `fractal_text_to_sql(question, table_names?)`: Safe SQL generation (real parser-based allowlist, never executes). $\rightarrow$ **[api-cognition.md](api-cognition.md)**

**Agency**
- `fractal_search_agent(...)` / `fractal_rag_agent(...)` / `fractal_sql_agent(...)`: three of the six Universal Agents. $\rightarrow$ **[api-agency.md](api-agency.md)**
- `fractal_agent_plan_explore(...)` / `_trajectory_predict(...)` / `_detect_loop(...)`: the other three Universal Agents. $\rightarrow$ **[api-agency.md](api-agency.md)**
- The 16 registered recipes (`fractal_agent_data_analyst`, `_route_task`, `_regime_triage`, `_recommend_diverse`, etc.), each returning one JSON document. $\rightarrow$ **[api-agency.md](api-agency.md#which-agent-should-i-use)**

**Analytics**
- `fractal_dimension_dfa(series)`: DFA scaling exponent. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_dimension_boxcount(points, dim)`: Box-counting dimension. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_dimension_drift(series, win)`: Regime change detection. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_change_point_detect(series, win, ...)`: Change-point localization. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_periodogram(series, max_peaks?)`: Exact power spectrum. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_spectrogram_entropy(series, window?, hop?, max_frames?)`: Short-time spectral entropy per frame. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_tda_persistence_diagram(points, dim, ...)`: Point-cloud persistence. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_state_fingerprint(v, ...)` / `fractal_cycle_detect(fingerprints, ...)`: SimHash + Brent cycle detection. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_vector_lp_distance(a, b, p)` / `fractal_vector_quantize_int8(v)` / `_binary(v)`: Vector math and quantization. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_optimize_portfolio(...)`: Cardinality-constrained optimization. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_vascular_network(...)`: Vessel tortuosity/density. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_cortical_folding(...)`: Gyrification Index. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_nerve_plexus_metric(...)`: Fiber plexus density. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_morphological_complexity(...)`: Mask complexity. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
