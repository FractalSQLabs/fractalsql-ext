<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# Docker & the Demo Learning Path

Try FractalSQL without installing anything beyond one file and a CLI.
`docker/Dockerfile` in this repo is a **multi-platform build tool**: it
produces one `.duckdb_extension` artifact per (DuckDB version,
architecture, glibc profile) cell for CI/release, the same way
`build.sh` does locally. It is not a runtime demo environment -- there
is no `docker-compose.yml` and no server here. That is by design: a
DuckDB extension is a file you `LOAD`, so once the `.duckdb_extension`
file exists, "the demo environment" is simply the `duckdb` CLI on your
own machine plus that file -- every demo and benchmark in `demo/` and
`bench/` runs directly against it, no container needed.

This page covers both halves: building the extension (Docker, or
`build.sh` without Docker), then running the demos in a learning path
that goes from plain vector search to agentic workflows.

## 🛠️ Prerequisites

- The `duckdb` CLI, matching the ABI cell your extension was built for
  (the current cell is `v1.5.6` -- use a CLI from the DuckDB
  `v1.5.6` release for the artifacts below).
- A built `fractalsql.<duckdb-version>.<platform>.duckdb_extension`
  (step 1 of the setup guide), or a release artifact if you skipped
  the build.
- Python 3.9+ only if you want the `bench/` head-to-head runs.
- Ollama or another LLM endpoint only for the cognition demos (opt-in,
  step 3).

---

## 🚀 Setup Guide

### 1. Build the extension

`build.sh` drives `docker/Dockerfile` to build the extension in a pinned
glibc 2.34 baseline (rockylinux:9) without needing a local toolchain:

```bash
./build.sh amd64     # linux/amd64
./build.sh arm64     # linux/arm64
```

The extension is plain C and calls DuckDB through the function table the
engine hands it when the extension loads, so no DuckDB source is compiled
and a build takes seconds, not the half hour the earlier design needed.
Two binaries come out of it: the stable-API band (loads on DuckDB 1.5.6
and 2.0.0) and the 1.4 band (exactly DuckDB 1.4.5). `build.sh` lays them
out as one file per supported DuckDB version:

```
dist/<arch>/fractalsql.v1.4.5.linux_<arch>.duckdb_extension
dist/<arch>/fractalsql.v1.5.6.linux_<arch>.duckdb_extension
dist/<arch>/fractalsql.v2.0.2.linux_<arch>.duckdb_extension
```

Without Docker, `make` builds both bands natively into `dist/<platform>/`
(Linux and macOS; `scripts\windows\build.bat` on Windows). The glibc
ceiling, the size ceiling and the single exported symbol are checked
inside the image.

No Docker needed? The same per-cell artifacts ship prebuilt on
[GitHub Releases](https://github.com/FractalSQLabs/fractalsql-ext/releases)
-- grab the cell matching your DuckDB version and platform (see the
README's build matrix for what each cell is).

### 2. Verify the extension is alive

```bash
duckdb -unsigned -c "
LOAD '$(pwd)/dist/amd64/fractalsql.v1.5.6.linux_amd64.duckdb_extension';
SELECT fractal_edition(), fractal_version();"
```

You should see:

```
Community | 2.0.2
```

**Quick test** (works with no model; base Sniper search needs no LLM):
```bash
duckdb -unsigned -c "
LOAD '/path/to/fractalsql.v1.5.6.linux_amd64.duckdb_extension';
SELECT fractal_sfs_converge([0.6, 0.8, 0.0]::DOUBLE[], [0.6, 0.8, 0.0]::DOUBLE[]);
"
```

### 3. Cognition -- configure a model (opt-in)

Reasoning (`fractal_reason`, `fractal_embed`,
`fractal_text_to_sql`) needs a model, reached through the reasoning
plugin. Point `FRACTALSQL_REASONING_PLUGIN` at the plugin and
`FSQL_REASONING_HTTP_URL` / `FSQL_REASONING_HTTP_MODEL` (etc.) at your
provider. Configuration is process environment only -- the env vars are
read once when the `duckdb` process starts, not per statement -- so set
them in the shell before invoking `duckdb`; there is no config file to
reload. If you're running Ollama, start it however you normally would
(`ollama serve`, or its own Docker image --
`docker run -d -p 11434:11434 ollama/ollama` if you want it
containerized; that's an upstream Ollama image, not something this repo
provides) and pull a chat model plus an embedding model
(for example `ollama pull gpt-oss:20b` and `ollama pull nomic-embed-text`;
nothing pulls a model for you). Until a model is reachable, cognition
calls fail with a clean not-configured/model-not-found error, not a
broken install; CPU-only inference can take minutes per call on modest
hardware. Or point the env vars at a cloud OpenAI-compatible endpoint
instead -- the full provider walkthrough is in
[reasoning-setup.md](reasoning-setup.md).

**Quick test** (now that a model is present, from the shell that has
`FRACTALSQL_REASONING_PLUGIN` set):

```sql
SELECT fractal_reason('Reply with exactly: FSQL_LIVE_OK') AS reply;
```

Nothing to enable or restart after that -- the extension is loaded per
connection and the model is reachable through the plugin.

---

## 🎓 The Learning Path

Run the demos in this order to see the progression from a vector search
tool to an agentic analytics engine. Most of them dispatch to the model
from step 3, so pull it before the pass. Every command is the same
pipeline, so define it once:

```bash
EXT=$(pwd)/dist/amd64/fractalsql.v1.5.6.linux_amd64.duckdb_extension
run_demo() { { echo "LOAD '$EXT';"; cat "demo/$1"; } | duckdb -bail -unsigned; }
run_demo_lenient() { { echo "LOAD '$EXT';"; cat "demo/$1"; } | duckdb -unsigned; }
```

`-bail` stops the shell at the first error, which is the right default:
a demo that fails tells you where it failed instead of carrying on past
it. Two kinds of demo need the flag dropped, for different reasons.

- **Enterprise-tier calls.** `demo-agents.sql`, `enterprise-qtl-audit.sql`,
  `enterprise-stress.sql` and
  `demo-vertical-periodicity-portfolio-selection.sql` call a gated
  function, which prints its activation error on a community build --
  with or without a model configured. Run those with `run_demo_lenient`.
- **Model-backed calls.** The cognition and agency demos dispatch to the
  reasoning endpoint. With the model from step 3 they run clean under
  `run_demo`; on a run with no model configured they print a clean
  "reasoning endpoint not configured" error where the call sits, and
  `run_demo_lenient` carries the shell past it so the rest of the file
  still runs.

Or run every demo in `demo/` in one pass:

```bash
docker compose exec demo /demo/run_demo.sh
```

Logs each file to `/tmp/fractalsql_demo_run/` inside the container and
prints a final `N ok, M failed` tally. The four enterprise-gated demos
run without `-bail`, so the shell carries on past their intentional
activation error and the rest of each file still runs; the runner then
asserts how many errors each log holds, so a new, unexpected error
fails the file instead of hiding behind the first one. Every other demo
runs with `-bail`, so its first error stops it and a non-zero exit is a
failure. Pull the model from step 3 before the pass: the
reasoning-dependent sections need it, and without one they print a
clean model-not-found error and the runner counts that file as a
failure rather than hiding it. `run_demo.sh --help` lists the known ones
plus `--only`/`--skip`/`--quiet` flags and how to also exercise
`response-modes.sql` (skipped by default -- see
[Response modes](../demo/README.md#response-modes) for why it
needs separate treatment).

The pass runs every file against one database file, one process per file,
and starts each process with `checkpoint_threshold` set to `1KB`, so every
commit is checkpointed and the file is complete when the process exits. That
matters because DuckDB 1.4.x and 1.5.x cannot replay the write-ahead log of
some schemas the demos create (foreign keys together with `COMMENT ON`, as in
`demo-text-to-sql.sql`): without it, the next file can fail to open the
database. The demo image's startup file sets the same value. Set
`FSQL_DEMO_CHECKPOINT_THRESHOLD` to another size, or to an empty string for
DuckDB's default, if you want to change it.

The two lakehouse demos read their tables from `/lake`. To use another
directory, set `LAKE_DIR` in the environment of the pass and write the
fixtures to it; see [Iceberg](lakehouse-iceberg.md#running-the-demo) and
[DuckLake](lakehouse-ducklake.md#writing-the-demo-table).

### Level 1: Geometric Discovery
*Focus: Using the fractal core and domain-specific geometry to find structure in noise.*
- **Goal**: Learn to use SFS for high-precision convergence and the domain-specific geometry metrics (vascular, cortical, nerve).
- **Demos**:
  ```bash
  # MedTech: Clinical Telemetry & Patient Monitoring
  run_demo demo-vertical-medtech-clinical.sql
  # Maritime: AIS & Radar Tracking
  run_demo demo-vertical-maritime-defense.sql
  # Fleet: Last-Mile Delivery
  run_demo demo-vertical-fleet-logistics.sql
  # Smart Cities: IoT Sensor Grids
  run_demo demo-vertical-smart-cities-iot.sql
  ```

### Level 2: Cognitive Synthesis
*Focus: Composing search with LLM reasoning to generate human-readable insights.*
- **Goal**: Learn to feed Scout Discovery results into `fractal_reason` and use `fractal_text_to_sql` for safe data exploration.
- **Demos**:
  ```bash
  # Recommendations: Advanced Discovery Engines
  run_demo demo-vertical-recommendation-search.sql
  # Sovereign: Edge & Autonomous Systems AI
  run_demo demo-vertical-sovereign-edge-ai.sql
  # BI: The Full Reasoning Loop (Question -> SQL -> Result -> Reason)
  run_demo demo-business-intelligence.sql
  ```

### Level 3: Autonomous Agency
*Focus: Building self-correcting, safe, and predictive agentic workflows.*
- **Goal**: Learn to use loop detection (SimHash fingerprints + cycle detection), trajectory prediction, self-correcting SQL agents, and the sixteen recipe agents registered with the extension itself -- no separate install step. See [api-agency.md](api-agency.md).
- **Demos**:
  ```bash
  # DevOps: Autonomous Incident Triage & Self-Healing
  run_demo demo-vertical-agentic-ops-devops.sql
  # Support: Stateful Session & Churn Drift
  run_demo demo-vertical-agentic-customer-support.sql
  # FinTech: MCTS Scenario Exploration & Safe Execution
  run_demo demo-vertical-agentic-fintech-mcts.sql
  # Cyber: Threat Detection & Triage
  run_demo demo-vertical-cybersecurity-threat-detection.sql
  # Edge Swarm: quantized swarm memory, loop detection, task routing (no reasoning needed)
  run_demo demo-vertical-agentic-edge-swarm.sql
  # The sixteen registered recipe agents (already in the loaded extension -- no install step)
  # (enterprise-tier call -- run it with run_demo_lenient)
  run_demo_lenient demo-agents.sql
  ```

See [Agent Recipes](api-agency.md#which-agent-should-i-use) for what each agent
does and when to use it. The verticals' per-industry walkthroughs are
catalogued one per industry in [starter-kits.md](starter-kits.md).

### Other demos in the repo

`demo/` also contains `demo.sql` (the base five-minute walkthrough of
Sniper, Scout, and reasoning in one script),
`response-modes.sql` (the `text`/`code`/`json` response-mode pass),
`demo-text-to-sql.sql`, the `text-to-sql-spike-*.sql` series (a step-by-step
walkthrough of the stages -- the recommended path is `demo-text-to-sql.sql`),
`demo-fractal-vector.sql` (a `float8[]`-only walkthrough of the vector
functions and the vectorizer), `demo-vectorizer.sql` (the automatic
embedding-pipeline walkthrough -- see
[vectorizer-setup.md](vectorizer-setup.md)),
`demo-vertical-biotech-genomics.sql` (TDA + L_p on a 60-point 3D
embedding, no reasoning needed), `benchmark.sql` and
`benchmark-api-reference.sql` (the API-surface smoke pass -- it calls
the reasoning-backed functions directly). The enterprise-tier
`enterprise-qtl-audit.sql`, `enterprise-stress.sql` and
`demo-vertical-periodicity-portfolio-selection.sql` run with
`run_demo_lenient`: their gated calls print their own activation errors
while the shell carries on. Everything else runs with `run_demo`, as in
the Learning Path above -- or with `run_demo_lenient` on a run with no
model configured.
`demo/demo-workload.sh` (the sustained concurrent-load tester) is a
bash script, not SQL -- run it directly, e.g. `demo/demo-workload.sh --help`.

---

## 📊 Validation & Benchmarks

### Scout Discovery vs. naive top-K (in-database demo)
See how Scout Discovery captures more distinct clusters than standard
top-K search -- `demo/benchmark.sql` runs both directly against a
synthetic cluster corpus:

```bash
run_demo benchmark.sql
```

### Full API surface
`demo/benchmark-api-reference.sql` exercises the callable function
surface (Search, Reason, Agents, Analytics) in one pass against small
generated fixtures. Run it without `-bail` so the reasoning-dependent
calls each print their own error on a model-less run and the shell
carries on:

```bash
{ echo "LOAD '$EXT';"; cat demo/benchmark-api-reference.sql; } | duckdb -unsigned
```

### Head-to-head benchmark vs. HNSW (no Docker needed)
`bench/` runs the HNSW-vs-Scout comparison at 100k-vector scale
directly against a local DuckDB file -- no container, no separate
benchmark database. `bench/head_to_head.py` measures search latency and
island recall against DuckDB's `vss` HNSW index (it needs network
access once so DuckDB can `INSTALL vss` -- a DuckDB Labs extension,
not part of this repo), and `bench/vector_type_head_to_head.py`
measures the `FLOAT[dim]`-vs-`DOUBLE[]` storage axis separately:

```bash
pip install -r bench/requirements.txt
python3 bench/data_gen.py        # ~20s to populate 100k rows and index them
python3 bench/head_to_head.py    # ~10s for 5 queries
python3 bench/vector_type_head_to_head.py
```

See [bench/README.md](../bench/README.md) for the measured numbers, the
output shape, and the tuning knobs.

---

## 🧹 Cleanup

The demos deliberately leave their tables in place so you can poke at
the results (demos are re-runnable -- each recreates its own fixtures at
the top of every section). When you're done,
[demo/README.md's Cleanup section](../demo/README.md#cleanup) has the
full one-per-statement `DROP TABLE` list.

Nothing else accumulates:

- The extension is a per-connection `LOAD` -- nothing persisted, nothing
  registered with the OS.
- The in-memory enterprise ledger lives inside the connection; it is
  gone when the session closes.
- Docker's own footprint is only the build cache (layer cache from the
  Dockerfile's caching strategy; see its header comment). `docker
  builder prune` reclaims it. An `ollama` container from step 3 is the
  usual `docker rm` + `docker rmi`.

---

## If you want a containerized demo environment

Nothing here prevents building one -- a `Dockerfile` that starts `FROM`
a slim base, copies in the built `.duckdb_extension` plus `demo/`,
installs a DuckDB CLI from the matching DuckDB release (the `v1.5.6`
release for the current ABI cell), and sets an entrypoint that runs a
chosen demo would give the same one-command demo experience, minus the
server. That doesn't exist in this repo yet; if you build one,
consider contributing it back -- it's the main demo-environment gap
this repo has.