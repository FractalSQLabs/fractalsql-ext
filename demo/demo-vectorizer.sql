-- demo/demo-vectorizer.sql
-- Runnable walkthrough of fractal_vectorizer_create() /
-- fractal_vectorizer_process_queue() / fractal_vectorizer_status().
-- See ../docs/vectorizer-setup.md for the full API reference.
--
-- Prerequisites: extension loaded, reasoning AND embedding configured.
-- Local Ollama example pairing a chat model with a real embedding
-- model from the same host (never reuse the chat model for embeddings
-- -- a purpose-trained model matters). This build configures the
-- reasoning plugin via environment variables, read once at process
-- start:
--
--   ollama pull gpt-oss:20b
--   ollama pull nomic-embed-text
--
--   FRACTALSQL_REASONING_PLUGIN=/path/to/fractalsql-reasoning-http.so
--   FSQL_REASONING_HTTP_URL=http://127.0.0.1:11434/v1/chat/completions
--   FSQL_REASONING_HTTP_MODEL=gpt-oss:20b
--   FSQL_REASONING_HTTP_MODE=embedding   (a SEPARATE process/session
--       from the chat examples above: this build's fractal_embed and
--       fractal_reason share one loaded plugin instance, so genuinely
--       running both chat and embedding needs two different sessions
--       each configured for its own mode, not one session doing both)
--   FSQL_REASONING_HTTP_ALLOW_PLAINTEXT=1   (dev/local Ollama only)
--
-- Confirm before running this script (in an embedding-mode session):
--   SELECT fractal_embed('reply with a short confirmation that this connection works');
--
-- Enqueue mechanism -- read before this file surprises you: DuckDB has
-- no trigger mechanism, so nothing here queues a row the instant
-- it's written.
-- fractal_vectorizer_process_queue() does a diff scan instead --
-- "text_col IS NOT NULL AND embedding_col IS NULL AND not already
-- queued" -- every time it's called. Two real consequences this demo
-- shows directly: (1) a newly-INSERTed row isn't "queued" until the
-- next process_queue() call, which both discovers AND processes it in
-- one step; (2) editing a row whose embedding_col is already non-NULL
-- does NOT re-queue it -- the diff scan only catches rows that have
-- never been embedded, not rows whose source text drifted after being
-- embedded once. There's no content-hash/staleness tracking in this
-- port to catch that -- if you need re-embedding on edit, NULL out
-- embedding_col yourself when you update the text column, or treat
-- this as a real, open gap for the src/ owner to close.
--
-- Safe to re-run: the schema is dropped and recreated at the top,
-- along with this demo's own vectorizer registration and queue rows.

-- (Timing is omitted -- DuckDB's CLI has no per-statement
-- timing dot-command; measure latency at the harness level, e.g.
-- demo/demo-workload.sh.)

-- Idempotent cleanup -- no DO block (DuckDB has no procedural SQL):
-- this demo always uses the same (source_table, text_col,
-- embedding_col) tuple, so a plain DELETE by that tuple is idempotent
-- without needing a lookup step. The bookkeeping bootstrap mirrors the
-- vectorizer surfaces' own IF NOT EXISTS schema
-- (docs/vectorizer-setup.md) so the DELETEs are no-ops
-- on a fresh database.
CREATE SEQUENCE IF NOT EXISTS fractal_vectorizer_id_seq START 1;
CREATE TABLE IF NOT EXISTS fractal_vectorizers (
  id BIGINT PRIMARY KEY,
  source_table VARCHAR NOT NULL,
  source_pk_col VARCHAR NOT NULL,
  text_col VARCHAR NOT NULL,
  embedding_col VARCHAR NOT NULL,
  options VARCHAR NOT NULL DEFAULT '{}',
  enabled BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (source_table, text_col, embedding_col)
);
CREATE TABLE IF NOT EXISTS fractal_vectorizer_queue (
  vectorizer_id BIGINT NOT NULL,
  pk_value VARCHAR NOT NULL,
  status VARCHAR NOT NULL DEFAULT 'pending',
  enqueued_at TIMESTAMP NOT NULL DEFAULT now(),
  started_at TIMESTAMP,
  error VARCHAR
);
DELETE FROM fractal_vectorizer_queue
 WHERE vectorizer_id IN (
    SELECT id FROM fractal_vectorizers
     WHERE source_table = 'docs' AND text_col = 'body' AND embedding_col = 'embedding'
 );
DELETE FROM fractal_vectorizers
 WHERE source_table = 'docs' AND text_col = 'body' AND embedding_col = 'embedding';

DROP TABLE IF EXISTS docs;
DROP SEQUENCE IF EXISTS seq_docs_id;
CREATE SEQUENCE seq_docs_id;
CREATE TABLE docs (
    id        INTEGER PRIMARY KEY DEFAULT nextval('seq_docs_id'),
    body      text NOT NULL,
    embedding float8[]
);
COMMENT ON TABLE docs IS 'Toy document store -- one row per short passage';

.print === Section 1: some rows BEFORE the vectorizer exists ===
.print fractal_vectorizer_create() backfills existing rows automatically --
.print these three will be queued the moment it runs, no separate step needed.
INSERT INTO docs (body) VALUES
    ('FractalSQL runs Stochastic Fractal Search directly inside DuckDB.'),
    ('The reasoning plugin speaks the OpenAI chat-completions and embeddings shapes.'),
    ('fractal_text_to_sql never executes what it generates -- that is always separate.');

SELECT id, body FROM docs ORDER BY id ASC;

.print
.print === Section 2: create the vectorizer (source_table, source_pk_col, text_col, embedding_col) ===
SELECT fractal_vectorizer_create('docs', 'id', 'body', 'embedding');

.print
.print Backfilled queue (all 3 rows above -- none had an embedding yet):
SELECT status, count(*) FROM fractal_vectorizer_queue GROUP BY status;

.print
.print === Section 3: a NEW row after the vectorizer exists ===
.print No trigger here -- it is NOT queued yet. The next process_queue()
.print call's diff scan is what discovers it (see the header note above).
INSERT INTO docs (body) VALUES
    ('Sniper Search refines a query point; Scout Mode returns a diverse population instead.');

SELECT status, count(*) FROM fractal_vectorizer_queue GROUP BY status;

.print
.print === Section 4: process the queue ===
.print This is the one function you put on a schedule (OS cron, Windows
.print Task Scheduler, your own app -- see docs/vectorizer-setup.md).
.print Running it manually here for the demo -- this single call both
.print discovers the Section 3 row (diff scan) and embeds everything
.print still pending (including it):
SELECT fractal_vectorizer_process_queue();

.print
.print === Section 5: check the results ===
SELECT id, body, embedding IS NOT NULL AS has_embedding,
       CASE WHEN embedding IS NOT NULL THEN len(embedding) END AS dim
FROM docs
ORDER BY id ASC;

.print
.print Status view -- one row per vectorizer, queue counts by state:
SELECT * FROM fractal_vectorizer_status();

.print
.print === Section 6: edit a row -- NOT re-queued (see header note) ===
.print Row 1 already has an embedding, so the diff scan (embedding_col IS
.print NULL) does not see it as pending, even though its text changed.
UPDATE docs SET body = body || ' (edited)' WHERE id = 1;
SELECT status, count(*) FROM fractal_vectorizer_queue GROUP BY status;
SELECT fractal_vectorizer_process_queue();
SELECT * FROM fractal_vectorizer_status();

.print
.print To actually force row 1 to re-embed, null its embedding out first,
.print then process_queue() picks it up like any other pending row:
UPDATE docs SET embedding = NULL WHERE id = 1;
SELECT fractal_vectorizer_process_queue();
SELECT id, body, embedding IS NOT NULL AS has_embedding FROM docs WHERE id = 1;

.print
.print ================================================================
.print Next: docs/vectorizer-setup.md for the BYO-scheduler examples --
.print nothing here ran fractal_vectorizer_process_queue() on a schedule,
.print this demo called it manually once per section.
.print
.print Clean up:
.print   SELECT id FROM fractal_vectorizers WHERE source_table = 'docs';  -- find the id
.print   SELECT fractal_vectorizer_drop(<that id>);
.print   DROP TABLE docs;
.print ================================================================
