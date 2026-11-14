<p align="center">
  <img src="../../FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

# Fuzz corpus

Seed inputs for the fuzz gate (`fuzz_smoke`, gate 21) of both
harnesses: `build_test.ps1 -Fuzz` and `build_test.sh --fuzz`. The two
run the same PRNG over the same corpus, so they generate byte-identical
mutants.

Each file is **one SQL statement** (or one short script) and is used in
two roles by the fuzz driver:

1. **Direct surface** -- the mutated statement is fed to the DuckDB CLI
   as ordinary SQL. The assertion is robustness: the CLI must never
   die abnormally (access violation, abort, sanitizer report), whatever
   the mutation did to the statement.
2. **Model reply** -- the mutated text is written to the mock
   reasoning plugin's reply file and handed to
   `fractal_text_to_sql()`. The assertion is the security boundary:
   the extension's SELECT-only allowlist must still refuse anything
   that is not a single SELECT. A reply that came back as `DELETE ...`
   or `DROP ...` is a fail, not a pass.

The seeds are deliberately split into two groups by filename prefix:

* `01`-`32` -- the extension's own numeric/vector surface, plus the
  argument-shape edge cases (empty array, NULL, NaN, overflow, dimension
  mismatch, wrong type). Every one of these binds against the real
  function of that name: the point of a seed is to reach the
  extension's own code, not to stop at the binder. The numbering has
  gaps (17-19 are unused), so a new seed can take a free number in its
  group without renumbering the rest.
* `40`-`50` -- statements that the allowlist must **refuse**: DDL,
  DML, a data-modifying CTE, `EXPLAIN`, stacked statements, `PRAGMA`,
  `ATTACH`. These are the seeds whose mutants must never come back
  as an executable statement.

Keep the files comment-free: the reply role hands the file's bytes to
the extension verbatim, and a leading `--` comment changes which
branch of the allowlist the text takes.

Nothing here is a test oracle. The corpus exists so the fuzzer has
*something* to mutate; the assertions live in `build_test.ps1`.
