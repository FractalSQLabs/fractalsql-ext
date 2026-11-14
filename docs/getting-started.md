<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# Getting Started: From Zero to Your First Search

This guide takes you from a build to a running agentic analytics extension in
a few minutes: no server, no cluster, no auth. By the end you will have:

- the `fractalsql` extension loaded into a DuckDB session,
- a diverse vector search that runs with **no model** connected,
- a live reasoning call against a real LLM, and
- the six composable "Universal Agent" building blocks working end to end.

> **The 16 named recipe agents are already here.** On top of the six
> Universal Agents below, this build registers all sixteen domain-specific
> recipe agents (`fractal_agent_route_task`, `fractal_agent_outlier_intercept`,
> etc.) itself, each a native scalar function composing those primitives
> server-side and returning one JSON document. No separate install step:
> they appear the moment the extension loads --
> [docs/api-agency.md](api-agency.md) has the per-agent recipes and
> `demo/demo-agents.sql` exercises all sixteen end to end.

---

## 1. Load the extension

Build it yourself (see [README](../README.md) for the full matrix), grab a
prebuilt `.duckdb_extension` from a release, or let the
`easy_install` script do all three ([Install without
Docker](#5-install-without-docker) below). Then, from the DuckDB CLI or
any client library:

```sql
LOAD '/path/to/fractalsql.v1.5.6.linux_amd64.duckdb_extension';

SELECT fractal_edition(), fractal_version();
```

```
  fractal_edition() | fractal_version()
------------------------+------------------------
       Community        |         2.0.0
```

No `CREATE EXTENSION`, no server restart, no config file -- `LOAD` registers
every function in the current session immediately.

---

## 2. Your first search (no model needed)

FractalSQL's core is a **Stochastic Fractal Search** optimizer, in two
flavours that solve different problems:

- **Sniper** (`fractal_search`): per-row cosine distance to an SFS-refined
  point -- the ORDER BY/LIMIT nearest-neighbor pattern.
- **Scout**: discover the *diverse* structure of your own data, finding
  distinct "islands" instead of collapsing to one neighbourhood -- two
  entry points: the `fractal_search_explore(emb, query)` **aggregate** over a
  table you `SELECT` from, and the
  `fractal_search_explore('table', 'emb_col', query, options)` **table
  function** that scans a named table/column directly.

Scout is what makes FractalSQL different from a plain vector search. Try it
on a tiny toy corpus:

```sql
CREATE TABLE demo_vecs (id INTEGER, emb DOUBLE[]);
INSERT INTO demo_vecs VALUES
  (1, [0.1, 0.1, 0.1]),
  (2, [0.9, 0.9, 0.9]),
  (3, [0.2, 0.8, 0.2]);

-- Sniper: nearest neighbor by cosine distance to a refined query point.
SELECT id, fractal_search(emb, [0.5, 0.5, 0.5]::DOUBLE[]) AS dist
FROM demo_vecs
ORDER BY dist
LIMIT 3;

-- Scout: discover the distinct basins in the data (not just the closest row).
SELECT UNNEST(fractal_search_explore(emb, [0.5, 0.5, 0.5]::DOUBLE[])) AS point
FROM demo_vecs;
```

Scout gives back a spread of vectors drawn from the distinct clusters in
your table -- the opposite of a top-K query that returns rows all from the
same neighbourhood.

→ For the table-function form scanning a real table by name
(`fractal_search_explore(table, vector_col, query, options)`), see
[docs/api-discovery.md](api-discovery.md#fractal_search_explore-aggregate-form).

---

## 3. Turn on reasoning

Search finds data; **reasoning** turns it into insight. Reasoning is opt-in
and configured through an environment variable rather than a config file --
this extension is embedded, there's no server process to restart:

```bash
export FRACTALSQL_REASONING_PLUGIN=/path/to/fractalsql-reasoning-http.so
```

Point that plugin at your provider (Ollama locally, or a cloud OpenAI-
compatible endpoint) via the plugin's own env vars -- see
[docs/reasoning-setup.md](reasoning-setup.md) for the full list
(`FSQL_REASONING_HTTP_URL`, `FSQL_REASONING_HTTP_MODEL`, etc.). Then, from
the same shell that has `FRACTALSQL_REASONING_PLUGIN` set:

```sql
LOAD '/path/to/fractalsql.v1.5.6.linux_amd64.duckdb_extension';
SELECT fractal_reason('Reply with exactly: FSQL_LIVE_OK') AS reply;
```

```
    reply
--------------
 FSQL_LIVE_OK
```

The embedder works the same plugin, in embedding mode
(`FSQL_REASONING_HTTP_MODE=embedding` -- see
[docs/reasoning-setup.md](reasoning-setup.md) for why this build can't run
chat and embedding through the same loaded plugin instance at once):

```sql
SELECT len(fractal_embed('hello world')) AS embed_dim;
--  768
```

---

## 4. Your first agent

The six **Universal Agents** compose search + reasoning into self-correcting
routines; the 16 named recipes, registered with the extension itself, build
further on them. Both Universal-Agent call shapes below take the
natural-language question FIRST, then the table/column to search -- the
question text is what gets embedded via the reasoning plugin, not a literal
vector:

```sql
SELECT * FROM fractal_search_agent('a point near the middle of the space', 'demo_vecs', 'emb', 3, 15);
SELECT * FROM fractal_rag_agent('What clusters exist?', 'demo_vecs', 'emb', '');
```

→ For the full list of six, their signatures, and worked examples, see
[docs/api-agency.md](api-agency.md#building-blocks-the-six-universal-agents).
For runnable end-to-end scripts, see `demo/demo-agents.sql` and the
`demo/demo-vertical-*.sql` files (they call the registered 16 recipes
directly).

---

## 5. Install without Docker

### Option A: one command

Run the easy-install script for your platform. It detects the platform and
the DuckDB release to match (from your `duckdb` CLI's own version if that
is a release cell, else a prompt, else the `--duckdb-version` flag --
the default cell is `v1.5.6`), downloads the matching
release bundle `fractalsql-ext-<duckdb-version>-<platform>` from GitHub
Releases, verifies it against the release's `SHA256SUMS`, installs the
extension from it into DuckDB's own extension directory

```
~/.duckdb/extensions/<duckdb-version>/<platform>/fractalsql.duckdb_extension
```

(so a `-unsigned` CLI finds it by name: `LOAD 'fractalsql'`; the licence notices sit beside it as
`fractalsql-LICENSE*`, and `--uninstall` removes only FractalSQL's files, never other extensions),

smoke-tests the load, and prints the exact `LOAD` line:

```bash
# Linux / macOS, from a clone:
./scripts/easy_install.sh
```

```powershell
# Windows
pwsh -File .\scripts\windows\easy_install.ps1
```

The script also installs the MCP server from the bundle's `mcp/` folder, next to the DuckDB library it runs on
(`~/.duckdb/fractalsql-mcp/<duckdb-version>/<platform>/`, `%USERPROFILE%\.duckdb\fractalsql-mcp\...` on Windows),
and prints the command that starts it; `--no-mcp` (`-NoMcp`) skips it. `--uninstall` removes it with the rest.

`--with-reasoning` also fetches the optional reasoning plugin into the same
directory and prints the
`FRACTALSQL_REASONING_PLUGIN` export to use it -- see
[docs/reasoning-setup.md](reasoning-setup.md) for the provider config
that comes after. Other flags cover the rest (`--duckdb-version`,
`--platform`, `--release`, `--uninstall`, `--dry-run`, `--no-verify`,
`--yes`) for non-interactive or CI use; run with `--help` for the full
list. Re-running is safe -- it just re-copies the file. The script never
phones home: no telemetry, everything stays local to your box.

### Option B: manual / air-gapped

For anything that can't run a downloaded script (a compliance
environment, an air-gapped box, or just wanting to see every step),
download the release bundle matching your DuckDB version + platform cell
(for example `fractalsql-ext-v1.5.6-linux_amd64.tar.gz`, or `.zip` on
Windows) from
[GitHub Releases](https://github.com/FractalSQLabs/fractalsql-ext/releases),
unpack it, and copy the `fractalsql.<duckdb-version>.<platform>.duckdb_extension`
file inside to the layout above as `fractalsql.duckdb_extension`. A DuckDB
extension is not a system package: there is no `.deb`, `.rpm` or `.msi` here
and nothing is registered with the OS -- install means "the file sits where
DuckDB's own load path expects it", and uninstall means "delete the file".

With the file in place, any session resolves the short form:

```sql
LOAD 'fractalsql';
SELECT fractal_edition(), fractal_version();
```

or load by full path, which works from any directory
(`LOAD '/path/to/fractalsql.v1.5.6.linux_amd64.duckdb_extension';`).

### macOS

The same one-command install works on macOS: run `./scripts/easy_install.sh`
(Option A). The platform cells are `osx_arm64` (Apple Silicon) and `osx_amd64`
(Intel), and the release bundle is a `.tar.gz`:

```bash
tar xzf fractalsql-ext-v1.5.6-osx_arm64.tar.gz
```

A few macOS specifics:

- **A DuckDB to load it into.** The extension loads into the DuckDB you already
  have, at the same version as the bundle (`brew install duckdb` if you have none).
  It is unsigned, so start the CLI with `-unsigned`.
- **Quarantine.** A bundle downloaded through a browser is marked quarantined by
  macOS. Clear it before loading: `xattr -dr com.apple.quarantine <unpacked folder>`.
  Downloads made by `easy_install.sh` (curl) are not marked.
- **The MCP server needs Homebrew's OpenSSL.** The optional server in the bundle's
  `mcp/` folder uses `openssl@3`: `brew install openssl@3`. The extension itself
  does not need OpenSSL, and the bundle carries the `libduckdb.dylib` the server runs on.

---

## 6. Closing a file database cleanly

The text-to-SQL, agent and vectorizer functions run SQL on your database through a few connections the extension keeps.
Once your last connection closes, the extension notices (after about a second of quiet) and releases them, so DuckDB can
run its shutdown checkpoint and release the file. A long-lived client such as a notebook, an application or the
interactive shell needs to do nothing.

A short-lived process is different: a script, or `duckdb mydb.duckdb -c "..."`, can exit within milliseconds, before that
second has passed. End such a session with one more statement:

```sql
SELECT fractal_release();
```

`fractal_release()` closes those connections at once and returns `true`. Things to know:

- It is final for that database: the functions that need the connections then report that nested queries were released,
  and they cannot be reopened. Call it as the **last** statement.
- It cannot be called from inside a nested query, and it is refused on a database that has a destructive-action latch set.
- On DuckDB 2.x, a one-shot command-line run that ends without it can, rarely, crash while exiting. Calling
  `fractal_release()` last, or starting the process with `FRACTALSQL_NESTED_QUERIES=off`, avoids that.

These settings are read once, when the extension loads:

| Variable | Default | Meaning |
|---|---|---|
| `FRACTALSQL_NESTED_QUERIES` | on | `off` (also `0`, `false`, `no`) keeps no connections at all. The functions that run SQL on your database then report that nested queries are off; everything else works. |
| `FRACTALSQL_HOST_CLOSE` | `release` | What the extension does once every client has gone: `release` frees its connections (final), `checkpoint` runs a `CHECKPOINT` each idle spell and keeps them (reversible, for hosts that reconnect to the same database), `off` leaves them until `fractal_release()` or exit. |
| `FRACTALSQL_HOST_CLOSE_GRACE_MS` | `1000` | How long the database must stay client-free before that happens. |
| `FRACTALSQL_HOST_CLOSE_POLL_MS` | `50` | How often the extension checks (5 to 5000). |

---

## Where next

The documentation is a linear path. You just finished this guide.

| Step | Question | Go to |
|------|----------|-------|
| 1 | *"How do I apply this to **my** industry?"* | **[docs/starter-kits.md](starter-kits.md)** |
| 2 | *"How does a specific agent work, and what are its inputs?"* | **[docs/api-agency.md](api-agency.md)** (*[Discovery](api-discovery.md) / [Analytics](api-analytics.md) / [Cognition](api-cognition.md) for the other tiers*) |
| 3 | *"How do I configure reasoning, embeddings, or the vectorizer?"* | **[docs/reasoning-setup.md](reasoning-setup.md)** and **[docs/vectorizer-setup.md](vectorizer-setup.md)** |
| 4 | *"How do I build a proprietary agent that isn't in the box?"* | **[docs/composition-guide.md](composition-guide.md)** |
| 5 | *"What's gated behind the enterprise tier?"* | **[docs/enterprise.md](enterprise.md)** |

If you want the extension-build walkthrough (profiles, libc variants), see
the build-tooling notes in **[docs/docker-demo.md](docker-demo.md)**.
