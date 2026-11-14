<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

> **Type note**: the search/analytics/cognition families below all take
> `LIST(DOUBLE)` (float64, this build's vector-argument convention everywhere
> `float8[]` appears in the shared spec) and return `BLOB`, `STRUCT(...)` or
> `LIST(BIGINT)`. The one exception is the
> [vector math](#vector-math-and-quantization) family: `fractal_vector_*`
> takes plain `LIST(FLOAT)` (float32) with `_from_float8_array`/
> `_to_float8_array` bridges. Everything is a plain LIST -- this build has
> no bespoke vector catalog type. Function names/argument order match;
> defaults arrive via arity overloads (DuckDB scalar functions can't declare
> `DEFAULT` clauses).

# Analytics API Reference

The Analytics tier provides mathematical primitives for analyzing the "shape" of data and state, turning raw vectors into structural insights.

---

## Fractal Dimension Analysis

### `fractal_dimension_dfa`
**Detrended Fluctuation Analysis**
Calculates the scaling exponent ($\alpha$) of a time-ordered series to distinguish between white noise, pink noise, and Brownian motion.

**Signature**: `fractal_dimension_dfa(series LIST(DOUBLE)) -> DOUBLE`
**Requirement**: $\ge 16$ points.

#### Using the DFA exponent as a Hurst exponent
There is deliberately no separate Hurst function: the DFA exponent *is* the Hurst exponent for noise-like input. For a series of increments (returns) $\alpha$ IS the Hurst exponent $H$; for a series of levels (prices) $H = \alpha - 1$.

On synthetic fractional Gaussian noise with known $H$ from 0.3 to 0.9, DFA had an overall RMSE of 0.036 at $n = 1024$ (0.068 at $n = 256$), against 0.070 (0.094 at $n = 256$) for classic and bias-corrected rescaled-range (R/S) estimators. On random-walk returns with heavy tails or volatility clustering, DFA called 0-2% of series trending or mean-reverting at a $\pm 0.1$ band, against 7-11% for raw R/S. (Synthetic tests, not market data.)

Caveats: the estimate's standard deviation is about 0.03 at $n = 1024$ (0.06 at $n = 256$); and short-memory autocorrelation inflates $\alpha$ -- DFA's smallest box is 4 samples, so a series with only lag-1 momentum (AR(1), $\varphi = 0.3$) reads about 0.61 although its long-run $H$ is 0.5. Raising the smallest box to 32 brings that to 0.52 at the price of a larger standard deviation; the function does not expose the box size yet.

### `fractal_dimension_boxcount`
**Minkowski-Bouligand Dimension**
Measures the spatial complexity of a point cloud using box-counting.

**Signature**: `fractal_dimension_boxcount(points LIST(DOUBLE), dim INTEGER) -> DOUBLE`
**Requirement**: $\ge 8$ points and a non-degenerate bounding box.

### `fractal_dimension_drift`
**Regime Change Detection**
Detects changes in the DFA exponent between a recent window and the baseline.

**Signature**: `fractal_dimension_drift(series LIST(DOUBLE), win INTEGER) -> STRUCT(drift DOUBLE, recent_alpha DOUBLE, baseline_alpha DOUBLE)`
**Return**: the `{drift, recent_alpha, baseline_alpha}` fields of that struct.

---

## Time-Series and Topology

### `fractal_change_point_detect`
**Change-Point Localization**
DFA's complement: localizes *where* a series' mean and/or variance shifted, instead of only characterizing its overall scaling behavior.

**Signature**: `fractal_change_point_detect(LIST(DOUBLE), INTEGER[, DOUBLE[, INTEGER]]) -> LIST(BIGINT)`
Sliding two-sample test over adjacent windows of `win` samples; flags a boundary when the mean differs by more than `threshold` pooled-standard-deviation units or the variance ratio exceeds `threshold` squared. Returns ascending boundary indices, up to `max_points`. Requires at least `2 * win` points. Defaults via arity overloads (DuckDB scalar functions can't declare `DEFAULT` clauses): 2-arg (threshold 2.0, max_points 64), 3-arg (max_points 64), 4-arg explicit.

### `fractal_periodogram`
**Classical Periodogram**
Power at each positive Fourier frequency, computed by direct $O(n^2)$ DFT (exact, not an FFT approximation).

**Signature**: `fractal_periodogram(series LIST(DOUBLE), max_peaks INTEGER) -> TABLE(freq DOUBLE, power DOUBLE)` -- a DuckDB table function; registered as 1- and 2-arg overloads, so omitting `max_peaks` takes its default 8.
**Return**: only the `max_peaks` bins with highest power, sorted descending. `freq` is cycles per sample in $(0, 0.5]$; `1.0/freq` is samples per cycle. Useful for network-beaconing and retry-loop cadence detection that DFA alone is blind to. Requires at least 4 points.

### `fractal_spectrogram_entropy`
**Short-Time Spectral Entropy**
`fractal_periodogram` says which frequencies dominate a whole series; this says *how ordered* the frequency content is, window by window, and so *when* it changes. A window slides over the series; each frame has its mean removed, is tapered with a periodic Hann window, and its power spectrum (direct $O(\text{window}^2)$ DFT, exact) is turned into a normalized Shannon entropy in $[0, 1]$. Use it for RF interference and jamming, a beacon or retry loop that loses its cadence, or any signal whose structure can degrade.

**Signature**: `fractal_spectrogram_entropy(series LIST(DOUBLE)[, window INTEGER[, hop INTEGER[, max_frames INTEGER]]]) -> LIST(DOUBLE)` -- registered at arities 1 to 4 (DuckDB scalar functions can't declare `DEFAULT` clauses): `window` defaults to 64, `hop` to 32 and `max_frames` to 4096. A NULL series returns NULL.
**Return**: a plain `DOUBLE[]` with one entropy value per frame. Frame `f` covers `series[f*hop .. f*hop + window - 1]`, so a boundary index `f` found downstream is a *frame* index and sample position is `f * hop`. Because it is a plain list it feeds `fractal_change_point_detect` directly.

| Value | Meaning |
|---|---|
| near 0 | energy concentrated in a few frequencies: a beacon, a retry loop, a locked carrier |
| near 1 | energy spread across the band: noise-like, jammed, or a signal that has lost its structure |

Calibration: a pure tone reads about 0.2 to 0.3 (the Hann taper spreads it over a few bins), white noise about 0.9, not 1.0 (a noise periodogram is itself randomly distributed). A constant frame has no spectral energy and reports exactly `0.0`, never NaN.

Limits: `window` in $[8, 512]$, `hop >= 1`, `max_frames` in $[1, 4096]$, `n >= window`, all samples finite; anything else is a clean SQL error. Cost is $O(\text{frames} \times \text{window}^2 / 2)$.

```sql
-- where does a signal's spectral order change? boundary indices are FRAME indices
SELECT fractal_change_point_detect(
         fractal_spectrogram_entropy(list(level ORDER BY seq), 32, 16), 3, 8.0, 16) AS change_points
  FROM rf_capture WHERE channel = 'CH-A';
```

### `fractal_tda_persistence_diagram`
**Topological Persistence**
Topological analysis over a point cloud's Vietoris-Rips filtration, capped at 512 points.

**Signature**: `fractal_tda_persistence_diagram(points LIST(DOUBLE), dim INTEGER, max_dim INTEGER, max_thresh DOUBLE, max_h0_bars INTEGER) -> STRUCT(h0_bars STRUCT(birth DOUBLE, death DOUBLE)[], betti1 BIGINT)` -- `max_dim` and `max_thresh` are required; `max_h0_bars` defaults to 64 via the arity overloads (DuckDB scalar functions can't declare `DEFAULT` clauses): 4-arg (max_h0_bars 64) and 5-arg explicit.
**Return**: `h0_bars` (the birth/death pairs) is an exact 0-dimensional persistence computation (single-linkage clustering). `betti1` (only computed when `max_dim = 1`) is the underlying graph's cycle rank, **not** full simplicial $H_1$: it over-counts true $H_1$ whenever a filled triangle exists in the data. A full simplicial computation (what Ripser/GUDHI do via boundary-matrix reduction) is out of scope.

### `fractal_state_fingerprint`
**SimHash State Fingerprint**
Random-hyperplane SimHash (Charikar 2002): projects a state vector onto `n_bits` random hyperplanes (deterministic from `seed`) and packs the sign of each projection MSB-first into bytes.

**Signature**: `fractal_state_fingerprint(v LIST(DOUBLE)[, n_bits INTEGER[, seed DOUBLE]]) -> BLOB`
Defaults via arity overloads: 1-arg (n_bits 128, seed 0.0), 2-arg (seed 0.0), 3-arg explicit. The seed default is 0.0 here; `fractal_agent_detect_loop`'s own seed default is 42.0, so a 2-arg fingerprint call and a default-seeded detect_loop don't agree bit-for-bit on the same state vector. The `n_bits` default is 128 bits.
Two nearly-identical states collapse to the same or a very low Hamming-distance fingerprint, unlike an exact hash's all-or-nothing sensitivity to floating-point noise.

### `fractal_cycle_detect`
**Streaming Cycle Detection**

> **DuckDB note.** In the other FractalSQL editions
> `fractal_cycle_detect` is a set-returning *scalar* over an array of
> fingerprints. In DuckDB it is a **table function** with the same result shape
> (`SELECT at_index, cycle_len FROM fractal_cycle_detect(fingerprints[, 
> hamming_threshold])`):
> same call semantics, one `FROM` clause instead of a scalar that returns a set.

Brent's algorithm (1980) run over an array of `fractal_state_fingerprint` outputs, fed through one detector in order.

**Call**: `SELECT at_index, cycle_len FROM fractal_cycle_detect(LIST(BLOB)[, hamming_threshold INTEGER])` -- overloads at 1 and 2 arguments; the 1-arg form implies `hamming_threshold = 0` (`:722-724`).
**Return** columns: `at_index INTEGER` -- the position in `fingerprints` where the cycle closed; `cycle_len BIGINT` -- its length. One row per cycle closure. The detector re-arms after each closure, so multiple independent cycles in the same stream are all caught. `hamming_threshold = 0` requires byte-exact fingerprint matches; above that, near-identical states count. Every fingerprint must be the same length.

**Producer idiom**: the fingerprints array is a per-row value built in order, so produce it with one ordered aggregation and feed the scalar subquery to the table function:
```sql
SELECT at_index, cycle_len
FROM fractal_cycle_detect((SELECT list(fingerprint ORDER BY step_no) FROM state_log));
```
Same shape when the fingerprints are stored as hex text: `list(from_hex(fp) ORDER BY rowid)` decodes them back to BLOB inside the same aggregation; `hex(fp)` prints them again on the way out.

These two pair into tolerant "have I basically been in this state before" loop detection; `fractal_agent_detect_loop` composes them (see [api-agency.md](api-agency.md)).

---

## Vector Math and Quantization

This DuckDB build has no bespoke `fractal_vector` catalog type -- vector math is plain scalar functions over `LIST(FLOAT)` (float32, not float8/double). Distance is a named function call, not an operator -- there is no distance operator to overload in SQL here, only `fractal_vector_l2_distance`/`fractal_vector_cosine_distance` called by name.

The basic arithmetic/distance set (`fractal_vector_dot`, `_l2`, `_l2_sq`,
`_cosine_distance`, `_cosine_similarity`, `_norm`, `_normalize`, `_add`,
`_sub`, `_scale`, `_weighted_concat`, `_hamming_distance`) is a plain
`(LIST(FLOAT), ...) -> FLOAT` or `-> LIST(FLOAT)` call per name -- the
exact signature of each follows from that pattern, so they are not repeated
individually here.

### `fractal_vector_dims` / `_from_float8_array` / `_to_float8_array`
**Length and float32/float64 interop**

- `fractal_vector_dims(v FLOAT[]) -> INTEGER`: element count.
- `fractal_vector_from_float8_array(v DOUBLE[]) -> FLOAT[]`: narrows a
  `DOUBLE[]` (as produced by, e.g., `fractal_embed`) down to `FLOAT[]` for
  use with the rest of this section's functions.
- `fractal_vector_to_float8_array(v FLOAT[]) -> DOUBLE[]`: widens back up,
  for feeding a `fractal_vector_*` result into a `DOUBLE[]`-typed function
  elsewhere (e.g. `fractal_search`, `fractal_search_telemetry`).

### `fractal_vector_lp_distance`
**Generalized $L_p$ Distance**

**Signature**: `fractal_vector_lp_distance(a FLOAT[], b FLOAT[], p FLOAT) -> FLOAT`
$(\sum_i |a_i - b_i|^p)^{1/p}$ for $p > 0$. `p = 2` matches `fractal_vector_l2_distance` mathematically but not bit-for-bit (different code path). For $0 < p < 1$ this is **not** a proper metric (the triangle inequality does not hold), so never substitute it silently for `fractal_vector_l2_distance`/`_cosine_distance` as a default distance; use it explicitly where fractional-$p$ contrast at high dimensionality is wanted, such as high-dimensional genomic or embedding similarity.

### `fractal_vector_quantize_int8` / `fractal_vector_quantize_binary`
**Per-Vector Quantization**

- `fractal_vector_quantize_int8(v FLOAT[]) -> JSON TEXT`: symmetric int8 quantization, 4x compression. Returns `{"scale":S,"codes":[...]}`: one raw signed-byte integer per dimension, `v[i] ~= codes[i] * scale`. The wire form is JSON deliberately, so a stored output round-trips without an edition-local decode step.
- `fractal_vector_quantize_binary(v FLOAT[]) -> BLOB`: 1-bit quantization, 32x compression. Bit $i$ is 1 if `v[i] >= 0`, packed MSB-first. Pairs with `fractal_vector_hamming_distance(a BLOB, b BLOB) -> BIGINT` (both blobs must be non-empty and the same length) for cheap candidate filtering ahead of a full-precision re-rank.

---

## Domain-Specific Geometry

These functions take **pre-extracted geometry** (graphs, meshes, skeletons) as input.

| Function | Input | Output | Description |
| --- | --- | --- | --- |
| `fractal_vascular_network` | `node_coords`, `edges`, `arc_length` | `{mean_tortuosity, branch_density, fractal_dimension}` | Vessel network complexity. |
| `fractal_cortical_folding` | `vertices`, `faces` | `{mesh_area, hull_area, gyrification_index}` | Brain surface folding. |
| `fractal_nerve_plexus_metric` | `node_coords`, `dim`, `edges` | `{fiber_length_density, branch_density, fractal_dimension}` | Nerve fiber density. |
| `fractal_morphological_complexity` | `points`, `dim` | `{dimension, lacunarity}` | Pre-segmented mask complexity. |

---

## Portfolio Optimization

### `fractal_optimize_portfolio`
**Cardinality-Constrained Sharpe-Ratio Maximization**

Finds the best $K$ assets in a large universe without brute-force exponential cost.

**Signature**: `fractal_optimize_portfolio(mu LIST(DOUBLE), cov LIST(DOUBLE), k INTEGER, seed BIGINT, use_obl BOOLEAN, diffusion_mode VARCHAR) -> STRUCT(sharpe DOUBLE, weights DOUBLE[])` -- registered as 3- to 6-arg overloads (DuckDB scalar functions can't declare `DEFAULT` clauses); omitted trailing args mean an unseeded run, `use_obl` off, and `diffusion_mode` 'gaussian'.
**Return**: `{sharpe, weights}`.
**`use_obl`**: apply Opposition-Based Learning to each SFS trial candidate. Also evaluate its bound-reflected opposite and keep whichever fits better. Off by default; doubles the fitness-eval cost of the affected diffusion step when enabled.
**`diffusion_mode`**: `'gaussian'` (default, canonical SFS) or `'levy'`: substitutes a heavy-tailed Lévy-flight step (Mantegna's algorithm) for the Gaussian walk, which can help escape local optima on highly multimodal problems at the cost of occasional very large steps.

### `fractal_optimize_portfolio_multimodal`
**Enterprise tier.** Diverse-candidate variant of `fractal_optimize_portfolio`: runs `n_restarts` independent single-best searches and greedy-selects up to `n_restarts` structurally distinct candidates instead of one.

**Signature**: a DuckDB **table function**: positional args
`(mu LIST(DOUBLE), cov LIST(DOUBLE), k INTEGER)` plus named parameters
`n_restarts INTEGER`, `overlap_threshold DOUBLE`, `quality_frac DOUBLE`,
`seed BIGINT`, `use_obl BOOLEAN`, `diffusion_mode VARCHAR`; a named
parameter omitted takes the default listed above:

```sql
-- mu = expected-returns vector, cov = flat row-major covariance, k = cardinality;
-- each named parameter shown takes its default from the list above when omitted.
SELECT sharpe, weights FROM fractal_optimize_portfolio_multimodal(
    mu, cov, k, n_restarts = 8, overlap_threshold = 0.15, quality_frac = 0.90);
```
**Return**: one row per candidate: `sharpe DOUBLE`, `weights DOUBLE[]`.
**`overlap_threshold`**: max allowed selected-asset overlap (0.0–1.0, Jaccard-style) between any two returned candidates.
**`quality_frac`**: a candidate must reach at least `quality_frac` × the best Sharpe found to be kept.
**`use_obl`/`diffusion_mode`**: same knobs as `fractal_optimize_portfolio`, applied uniformly to every restart. Both multimodal variants are gated behind `FRACTALSQL_ENTERPRISE_LIB` (an environment variable naming a library exporting the enterprise symbol set -- see [enterprise.md](enterprise.md)); without it, calling either raises a clear "requires the FractalSQL Enterprise tier" error rather than running.

### `fractal_optimize_portfolio_multimodal_pareto`
**Enterprise tier.** Pareto-front variant of `fractal_optimize_portfolio_multimodal`: runs the same `n_restarts` independent searches, but scores each by decomposed **(return, risk)** instead of scalar Sharpe and reduces them to a genuine non-dominated Pareto front (NSGA-II crowding-distance truncation if the front exceeds `max_front`). This is not the sharpe-threshold + asset-overlap selection that function uses. Purely additive: does not change that function's selection semantics.

**Signature**: the same table-function shape: positional args
`(mu LIST(DOUBLE), cov LIST(DOUBLE), k INTEGER)` plus named parameters
`n_restarts INTEGER`, `max_front INTEGER`, `seed BIGINT`,
`use_obl BOOLEAN`, `diffusion_mode VARCHAR` (same defaults as `fractal_optimize_portfolio_multimodal`).
**Return**: one row per front member: `return DOUBLE`, `risk DOUBLE`,
`sharpe DOUBLE`, `weights DOUBLE[]` -- `sharpe = return/risk` is informational, not the selection criterion.
**`max_front`**: cap on returned front size, `1 <= max_front <= n_restarts`.

### `fractal_optimize_subset`
**Value-Weighted k-Subset Allocation**

Generalizes `fractal_optimize_portfolio`'s cardinality-constrained search into a pluggable-objective optimizer; this SQL entry point hardcodes value-weighted allocation: maximize `sum(weight[i] * item_values[i])` subject to at most `k` of `n_items` nonzero, each `weight <= upper_bounds[i]`, weights summing to 1.0.

**Signature**: `fractal_optimize_subset(item_values LIST(DOUBLE), upper_bounds LIST(DOUBLE), k INTEGER, prev_weights LIST(DOUBLE), turnover_penalty DOUBLE, seed BIGINT) -> STRUCT(score DOUBLE, weights DOUBLE[])` -- registered as 3- to 6-arg overloads; omitted trailing args mean no previous allocation, `turnover_penalty` 0.0, and an unseeded run.
**Return**: `{score, weights}` where `score` is the achieved total value (higher is better). `prev_weights` + `turnover_penalty` (both optional) steer the search away from reallocating when set, for rebalancing use cases. The sum of the `k` largest `upper_bounds` must reach 1.0 or no feasible k-subset exists.

---

## Named Feature Store

**Not available in the DuckDB edition.** Other FractalSQL editions offer a generic per-item vector store for custom
metadata or flagged examples: one function upserts a feature vector against a `doc_id` into a
persistent table, and the other runs a brute-force k-NN scan over that table. DuckDB has no equivalent function
today. To get the same effect, keep the vectors in an ordinary table and rank them with the vector
functions above (for example `ORDER BY fractal_vector_l2_distance(vec, query) LIMIT k`).

### `fractal_store_morphology`
Upserts a vector against a `doc_id`.
**Not built in the DuckDB edition.** Signature in the editions that have it: `fractal_store_morphology(doc_id BIGINT, feature_array DOUBLE[])`

### `fractal_mine_topology_negatives`
Brute-force k-NN scan over the feature store.
**Not built in the DuckDB edition.** Signature in the editions that have it: `fractal_mine_topology_negatives(surrogate_vector DOUBLE[], k INTEGER) -> TABLE(doc_id BIGINT, distance DOUBLE)`
