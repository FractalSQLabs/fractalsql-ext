<p align="center">
  <img src="../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# Cognition API Reference

The Cognition tier provides the provider bridge that connects the SFS core to Large Language Models (LLMs) and embedding providers. Built into the extension.

---

## `fractal_reason`
**LLM Dispatch**

Dispatches a natural language query and a context payload to the configured LLM reasoning plugin.

### Signature
```sql
-- DuckDB scalar function, no SQL-level defaults -- registered as two
-- arities; call with 1 arg (context defaults to '{}') or 2.
fractal_reason(query   VARCHAR) -> VARCHAR
fractal_reason(query   VARCHAR, context VARCHAR) -> VARCHAR
```

### Arguments
| Argument | Type | Description |
| --- | --- | --- |
| `query` | `VARCHAR` | (Required) The question or instruction for the LLM. |
| `context` | `VARCHAR` | Optional. A JSON payload containing search results, schema, or other data. Omit for `'{}'`. |

Requires `FRACTALSQL_REASONING_PLUGIN` (an environment variable read at
process start -- this extension is embedded, so there is no config file to
reload) set to the
absolute path of a compiled `fractalsql-reasoning-*.so` before the process
starts.

### Reasoning Effort
Hybrid-thinker models' internal reasoning trace is throttled via
`FSQL_REASONING_HTTP_THINK` and related env vars the plugin itself reads --
see [Reasoning Setup: Reasoning Effort (THINK)](reasoning-setup.md#reasoning-effort-think).

---

## `fractal_embed`
**Semantic Vector Generation**

Generates a high-dimensional vector from text using the configured embedding model.

### Signature
```sql
fractal_embed(input VARCHAR) -> DOUBLE[]
```

### Requirements
Requires the same `FRACTALSQL_REASONING_PLUGIN` as `fractal_reason`, with
the plugin itself configured for embedding mode
(`FSQL_REASONING_HTTP_MODE=embedding`, `FSQL_REASONING_HTTP_MODEL` set to an
embedding model). **This build dispatches `fractal_reason` and
`fractal_embed` through the same loaded plugin instance**: both calls go
through that one plugin's current HTTP mode/model settings, so a single
process cannot point chat and embedding at different endpoints
(`FSQL_REASONING_HTTP_MODE` switches the whole plugin between the two
modes; see [reasoning-setup.md](reasoning-setup.md)). Run two separate
processes (or accept single-mode-at-a-time) if you need both.

---

## `fractal_text_to_sql`
**Safe Text-to-SQL**

Turns a natural-language question into a single, validated SQL statement via
GENERATE → ALLOWLIST → EXPLAIN → RETRY (see
[text-to-sql-setup.md](text-to-sql-setup.md) for the full pipeline).
ALLOWLIST uses DuckDB's own parser (statement count/type), and
EXPLAIN runs `EXPLAIN <sql>` to catch a bad candidate
without executing it. Never executes the returned SQL itself.
`fractal_sql_agent` (see
[api-agency.md](api-agency.md)) shares this same validation pipeline and
adds a caller-chosen retry limit plus an optional execute step.

### Signature
```sql
-- DuckDB scalar function, no SQL-level defaults -- registered as two
-- arities; call with 1 arg (table_names omitted) or 2.
fractal_text_to_sql(question VARCHAR) -> VARCHAR
fractal_text_to_sql(question VARCHAR, table_names VARCHAR[]) -> VARCHAR
```

### Arguments
| Argument | Type | Description |
| --- | --- | --- |
| `question` | `VARCHAR` | (Required) The natural-language question. |
| `table_names` | `VARCHAR[]` | Optional. Tables the generator may reference; omit for every table. |

Returns the validated SQL as plain text. Raises an error if 3 attempts
(fixed) are exhausted without a validated candidate. Set
`FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update` to also
allow `INSERT`/`UPDATE` candidates (default: `SELECT` only) -- `DELETE` and
DDL/utility statements are rejected in both modes.

### Safety Pipeline
1. **Parse-Check** (ALLOWLIST stage): the candidate statement is parsed with
DuckDB's real `Parser` -- multi-statement and DDL/utility candidates are
rejected here, before any preparation, and the parse error text becomes the
retry feedback.
2. **Allowlist**: the parsed statement type is gated by
`FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS` (select-only by default;
`select_insert_update` widens it) -- see
[text-to-sql-setup.md](text-to-sql-setup.md).
3. **EXPLAIN-Check** (EXPLAIN stage): `EXPLAIN <sql>`
binds and plans the candidate without executing it; a binder/planner error is
caught and fed back to the plugin as retry feedback (RETRY stage, 3 fixed
attempts).

---

## `fractal_schema_context`
**Schema Introspection**

Builds a plain-text description of the database schema for use as LLM context. Pure catalog introspection -- no LLM call.

### Signature
```sql
-- DuckDB scalar function, no SQL-level defaults -- registered as three
-- arities; call with 0, 1, or 2 args.
fractal_schema_context() -> VARCHAR
fractal_schema_context(table_names VARCHAR[]) -> VARCHAR
fractal_schema_context(table_names VARCHAR[], query_hint VARCHAR) -> VARCHAR
```

### Arguments
| Argument | Type | Description |
| --- | --- | --- |
| `table_names` | `VARCHAR[]` | Optional. Tables to describe. Omit (or pass an empty/NULL list) to describe every table in `information_schema.columns`. |
| `query_hint` | `VARCHAR` | Optional. Accepted for forward compatibility with future ranking passes; not yet used. |

Reads DuckDB's own `information_schema.columns` and `duckdb_constraints()` --
reports columns, types, NOT NULL/PRIMARY KEY, and foreign keys. It does not
include table/column comment text. Capped
at 512 requested `table_names` -- pass a
smaller, scoped list if you hit the limit.

> **DuckDB note.** In the other FractalSQL editions
> `fractal_schema_context(table_names, query_hint)` has SQL-level `DEFAULT NULL`
> clauses. DuckDB scalar functions can't declare `DEFAULT` clauses, so this
> build provides the **same three call shapes as arity overloads** --
> `()`, `(table_names)`, `(table_names, query_hint)`. Pass the args
> explicitly for the scoped form; omit them for full-schema introspection.
