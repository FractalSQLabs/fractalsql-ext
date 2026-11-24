<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# FractalSQL Enterprise -- CISO Decision Audit & Quantized Ternary Ledger (QTL)

> **Mechanism note.** In this DuckDB build the ledger/audit SQL
> surface is gated behind an environment-variable-selected separate core
> library -- a deliberate product-
> tiering decision. What's **not** available in this build: HMAC ledger-key
> authentication, detached-signature verification, and table-backed
> persistence -- see the notes inline below for what this build does
> instead.

QTL is a hash-chained, tamper-evident audit ledger for agent and optimizer
decisions. The mechanism is described in full below.

The core FractalSQL extension (Discovery, Cognition, and Agency) ships in
the FractalSQL Community edition and works fine on its own; none of it needs
anything described on this page. This tier exists for regulated environments
that need to prove what an agent decided, not just claim it:
every optimizer call and agent decision can write a tamper-evident record a
CISO or auditor can verify, rather than a log line they simply have to trust.

This is delivered as a drop-in core library: **no rebuild**. The same
extension binary ships the SQL signatures; whether they do real work
depends entirely on an environment variable read once, lazily, on first
use per process.

**Community build (default):** eight of the nine functions below are
present but **dormant** (`fractal_ledger_verify` is the exception -- see its
table row). Calling one of the eight returns a clear, actionable error:

```
IO Error: fractalsql: fractal_ledger_flush requires the FractalSQL
Enterprise tier -- set FRACTALSQL_ENTERPRISE_LIB to the absolute path of
a compiled enterprise core library to enable this function. All
Community/Sovereign search, diversify, and single-restart portfolio
optimization functions continue to work regardless.
```

**Enterprise build:** point the env var at a library exporting the eleven
enterprise symbol names -- the eight ledger/audit symbols backing the
eight dormant functions of the community build, plus three multimodal
portfolio-optimization symbols backing
`fractal_optimize_portfolio_multimodal*` -- before the process
starts -- there's no
config file to reload, so this must be set in the environment the DuckDB
process itself runs in:

```bash
export FRACTALSQL_ENTERPRISE_LIB=/path/to/libfractalsql-enterprise-sovereign-c.so
duckdb  # or however your client launches
```

The eight then activate and operate on the same in-memory context the
community search engine already built (seven ledger-management functions
plus `fractal_audit_unpack` for CISO decode). **Persistence**:
this build's ledger is an **in-memory storage VFS scoped to the DuckDB
connection** -- deliberately connection-local: no cross-process durability, and
nothing survives past the connection closing. `fractal_ledger_verify()`
here walks that in-memory
chain rather than a persisted table. If you need durable, queryable audit
history, write `fractal_audit_unpack()`'s decoded JSON to your own table
after each flush -- this build doesn't do that for you.

| Function | Purpose |
| --- | --- |
| `fractal_ledger_flush()` | Encode truth + shadow ledgers into a QTL blob and append it to the chain. |
| `fractal_ledger_load()` | Hydrate the in-memory ledgers from the chain's latest entry (verifies only the tip, O(1)). |
| `fractal_ledger_verify()` | **Not enterprise-gated** -- it reads this build's in-memory chain directly, not through the gated library surface. Callable on a community build; walks the ENTIRE in-memory chain (O(n), on demand) and returns the audit report as JSON text (`VARCHAR`). In practice it reports an empty/trivial chain on a community build, since nothing gated (`fractal_ledger_flush`) has written to it. |
| `fractal_ledger_compact()` | Decay every Shadow weight by x0.9 (the ledger's forgetting step; Truth weights are untouched). In `exact` retention it does nothing. |
| `fractal_ledger_reset_soft()` | Soft-reset ledger counters without dropping history. |
| `fractal_ledger_reset_hard()` | Hard-reset the ledgers to empty. |
| `fractal_ledger_truth_count()` | Truth-side entry count (`bigint`). |
| `fractal_ledger_shadow_count()` | Shadow-side entry count (`bigint`). |
| `fractal_audit_unpack(blob)` | Decode a persisted QTL blob (`BLOB`) into its audit JSON (`VARCHAR`). Pass `''` to decode the last blob `fractal_ledger_flush()` sealed on this connection. |
| `fractal_lock_destructive()` | **Not enterprise-gated.** One-way latch: returns `'locked'`, after which the four destructive functions above (`flush`, `compact`, `reset_soft`, `reset_hard`) refuse on this connection. See below. |

**Retention: fade or exact.** By default the ledger *fades*: compaction decays the Shadow weights, and when a ledger is
full the lowest-significance entry is evicted to make room. Set `ledger_retention` to `exact` when every recorded entry
must be kept as it was written:

```sql
SELECT fractal_config_set('ledger_retention', 'exact');    -- or 'fade' (the default)
```

In `exact` mode compaction changes nothing and nothing is evicted; a report for a handle that is not yet in a full
ledger is refused with a "ledger full" error rather than displacing another entry, and a handle that is already
recorded still accepts more weight. The mode is written into every flushed ledger, so `fractal_ledger_load()` restores
the mode the ledger was recorded with. Set it before the first report of a connection. `exact` needs an enterprise
library that supports it: with an older library the first ledger call is refused instead of quietly running the default.
Like every key, it is process-wide and is also read from the `FRACTALSQL_LEDGER_RETENTION` environment variable.

**Locking the destructive functions.** `fractal_lock_destructive()` is a
**one-way latch, per connection**: after it returns `'locked'`,
`fractal_ledger_flush()`, `fractal_ledger_compact()`,
`fractal_ledger_reset_soft()` and `fractal_ledger_reset_hard()` refuse
with `destructive ledger operations are locked on this connection`,
whether or not an enterprise core is loaded. Nothing in SQL clears it, so
SQL that runs later on the connection -- including SQL a reasoning agent
generated -- cannot undo it; closing the connection does. The check runs
before the enterprise library resolution, so a locked connection refuses
identically on a community build. There is deliberately no unlock
function. (This edition has no trigger machinery and no
direct-only-style registration flag, so do not embed the destructive
functions in a view either: the lock is the enforcement mechanism, not a
schema restriction. Keep destructive calls in top-level statements
drivers control.) The read-side functions (`load`, `verify`,
`truth_count`, `shadow_count`, `audit_unpack`, `audit_log`) keep working
after the latch.

**Removing the library re-dormants the surface**: unset the env var (or
point it at a missing path) and restart the process -- there's no config
file to signal and no live-reload path, so this needs a fresh process.
The functions return to the *enterprise
tier not loaded* error with no recompile. The search engine and every
community primitive keep working unchanged; only the ledger/audit surface
is gated.

**`fractal_audit_log(entry_type, payload)`**: the general decision-audit
chain. A second, independent append-only chain in this connection's
in-memory ledger (`kind=2`, same hash-chain guarantees as the QTL chain,
verify with `fractal_ledger_verify(2)`) for provenance records rather than
QTL blobs. In this build, the `fractal_optimize_portfolio_multimodal`
(and pareto) functions are enterprise-gated for calling permission
(`fractal_text_to_sql` is NOT gated -- it is community surface, see
[text-to-sql-setup.md](text-to-sql-setup.md)); the multimodal functions don't
themselves call `fractal_audit_log` -- no decision of theirs is
auto-logged, so none of them depend on the ledger to keep working.

The sixteen named recipe agents each best-effort audit-log their own
decision (wrapped so a missing enterprise tier never breaks the agent):
every recipe body's audit write goes
through a best-effort path that never fails the recipe.

**`fractal_optimize_portfolio_multimodal()`** (enterprise tier): like
`fractal_optimize_portfolio` but runs several independent restarts and
returns up to `n_restarts` structurally distinct portfolios instead of
one: candidates within `quality_frac` of the best Sharpe found, no two
sharing more than `overlap_threshold` of their assets. Same entropy
engine as the single-best version; the gate gives access to the
multi-restart + diverse-selection capability, not a different algorithm.
**Paired recipe agent** (enterprise tier): `fractal_agent_diverse_portfolios`,
one of the sixteen registered recipe agents -- see
[Diverse portfolios](api-agency.md#diverse-portfolios--fractal_agent_diverse_portfolios)
in [api-agency.md](api-agency.md).

**`fractal_optimize_portfolio_multimodal_pareto()`** (enterprise tier):
Pareto-front variant of the function above: same `n_restarts`
independent searches, but scores each by decomposed **return/risk**
instead of scalar Sharpe and reduces them to a genuine non-dominated
Pareto front (NSGA-II crowding-distance truncation past `max_front`)
rather than sharpe-threshold + asset-overlap selection. Purely
additive, doesn't change that function's semantics. Both
`fractal_optimize_portfolio_multimodal*` functions also accept `use_obl`
(Opposition-Based Learning: evaluate each SFS trial candidate's
bound-reflected opposite, keep whichever fits better) and
`diffusion_mode` (`'gaussian'` default or `'levy'`, a heavy-tailed
Mantegna-algorithm step that can help escape local optima on highly
multimodal problems).

**Append-only chain, not a snapshot.** The ledger is a genuine history:
every entry links to its predecessor via `entry_hash = SHA256(prev_hash ||
blob || mac)`, held in this connection's in-memory chain (not a table -- see
the persistence note above). `entry_hash` covers the blob unconditionally,
so a byte-flip anywhere in history is structurally detectable within the
chain's lifetime. **Not implemented in this build**: HMAC-SHA256
ledger-key authentication of the QTL blobs -- it depends on durable,
cross-process storage this build's in-memory-only ledger doesn't have a use
for yet. If you need it, that's real follow-on work tied to first giving
this build's ledger actual persistence (see the note above). External
ledger anchoring *is* available: it does not depend on durable storage
here, because it publishes the head off the host rather than keeping a
second copy of it in this process. See "Data at rest" below.

**Enterprise library signature.** Before `FRACTALSQL_ENTERPRISE_LIB` is
loaded, the extension verifies a detached Ed25519 signature (`<library>.sig`,
exactly 64 raw bytes) over the library's bytes against the FractalSQLabs
signing key, and re-verifies after the load. A missing signature refuses the
load; set `FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0` in the process
environment to accept an unsigned library. A present signature that
does not verify is always refused.

### Data at rest

**The chain is in memory, so it leaves nothing behind.** In this engine
the ledger is held per connection, in process memory, and is gone when the
process exits: there is no ledger file, no CSV mirror and no separate head
record to protect. The only thing that leaves the host is the audit text
the chain holds -- and that can be reduced with `FSQL_AUDIT_REDACT`
(`none` by default, `hash` or `truncate`), which stores a fingerprint of
the question, the generated SQL, the analysis and the rows instead of the
text itself. The values returned to the caller are never redacted.

**The protection against a truncated chain is published off the host.**
With `FSQL_LEDGER_ANCHOR_LOG=stderr` (or `syslog`, where the platform has
one) the extension emits one JSON line on every append:

```json
{"event":"ledger_head","kind":2,"rows":17,"hash":"<hex of the newest entry hash>"}
```

`kind` is the chain that was appended to (1 is the truth-and-shadow chain,
2 the decision-audit chain), `rows` is how many entries that chain holds
after the append, and `hash` is the newest entry hash. A chain whose tail
was dropped no longer matches the last line published, so a truncation is
visible from the log even though it is invisible from the engine alone.
Turn it on when the chain is evidence.

**Confidentiality at rest comes from the storage layer.** The project
does not encrypt the records inside the chain. The database file and
anything else the deployment writes is covered by the encryption of the
volume or disk it lives on, or -- for the database file specifically -- by
DuckDB's own file encryption when the deployment uses it. This server opens
its database by path and passes no key, so an encrypted file is not one it
can open; protect the file it opens with volume encryption.

---

For enterprise editions, licensing, and support, contact
**enterprise@fractalsqlabs.com**.
