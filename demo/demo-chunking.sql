-- demo/demo-chunking.sql
-- Long text, chunked: split documents into passages, embed the passages, and answer a question from the right passages.
--
--   1. fractal_chunk_text on its own: how a text is cut (no model needed).
--   2. A chunk table filled from the documents, then embedded by the vectorizer.
--   3. A question answered from one document only (meta_filter on parent_id), with the passages it was drawn from.
--   4. The same table through an index: fractal_index_ensure, then agent_use_index.
--
-- DuckDB has no triggers, so the chunk table is filled with INSERT ... SELECT over fractal_chunk_text rather than kept in step by the vectorizer.
-- Prerequisites: extension loaded, reasoning AND embedding configured (see demo/demo-vectorizer.sql for the local-Ollama example).
-- Safe to re-run: the demo tables are dropped and recreated.

.print === 1. How fractal_chunk_text cuts a text ===
SELECT c->>'$.no' AS no, c->>'$.start' AS start, c->>'$.end' AS "end", c->>'$.text' AS chunk
  FROM (SELECT unnest(from_json(fractal_chunk_text('First paragraph here.' || chr(10) || chr(10) || 'Second one is short.' || chr(10) || chr(10) || 'Third paragraph is a bit longer than the others are.', 40, 0), '["JSON"]')) AS c);
SELECT c->>'$.no' AS no, c->>'$.text' AS chunk
  FROM (SELECT unnest(from_json(fractal_chunk_text('One. Two sentences! Is this three? Yes.  Four is a long one that keeps on going and going.', 30, 5, 'sentence'), '["JSON"]')) AS c);

.print
.print === 2. A chunk table, then the vectorizer ===
DROP TABLE IF EXISTS chunk_demo_docs_chunks;
DROP TABLE IF EXISTS chunk_demo_docs;
CREATE TABLE chunk_demo_docs (id BIGINT PRIMARY KEY, title VARCHAR, body VARCHAR);
INSERT INTO chunk_demo_docs VALUES
 (1, 'Heartbeat runbook', 'A node that stops heartbeating is first marked suspect. The coordinator waits for three missed beats before it acts.' || chr(10) || chr(10) || 'If the node is still silent, drain its work to the other nodes and open an incident. Do not restart it until the drain has finished, or its in-flight work is lost.' || chr(10) || chr(10) || 'After the restart, watch the node for ten minutes. If it misses another beat, replace the hardware.'),
 (2, 'Backup runbook', 'Backups run nightly at two in the morning. Each backup is verified by restoring it into a scratch database and comparing row counts.' || chr(10) || chr(10) || 'A failed verification pages the on-call engineer. Never delete the previous good backup until the next one has verified.'),
 (3, 'Billing runbook', 'Invoices are generated on the first of the month. A customer who disputes an invoice gets it frozen until the dispute is closed.');
CREATE TABLE chunk_demo_docs_chunks (id BIGINT PRIMARY KEY, parent_id BIGINT, chunk_no INTEGER, chunk_text VARCHAR, embedding DOUBLE[]);
INSERT INTO chunk_demo_docs_chunks
SELECT row_number() OVER (ORDER BY d.id, (c->>'$.no')::INTEGER), d.id, (c->>'$.no')::INTEGER, c->>'$.text', NULL
  FROM chunk_demo_docs d, unnest(from_json(fractal_chunk_text(d.body, 220, 20), '["JSON"]')) AS t(c);
SELECT count(*) AS chunks_created FROM chunk_demo_docs_chunks;
SELECT fractal_vectorizer_create('chunk_demo_docs_chunks', 'id', 'chunk_text', 'embedding') AS vectorizer_id;
SELECT fractal_vectorizer_process_queue(1000) AS chunks_embedded;

.print
.print === 3. A question answered from one document, with the passages it used ===
SELECT answer, source_row_ids, used_index FROM fractal_rag_agent('What should I do before restarting a silent node?', 'chunk_demo_docs_chunks', 'embedding', '{}');
SELECT answer, source_row_ids FROM fractal_rag_agent('What should I do before restarting a silent node?', 'chunk_demo_docs_chunks', 'embedding', '{"parent_id": 1}');

.print
.print === 4. The same table through an index ===
SELECT fractal_index_ensure('chunk_demo_docs_chunks', 'embedding', '{"vector_format": "FP32", "id_col": "id"}') AS ensured;
SELECT fractal_index_ensure('chunk_demo_docs_chunks', 'embedding') AS ensured_again;
SELECT fractal_config_set('agent_use_index', 'on');
SELECT used_index, source_row_ids FROM fractal_rag_agent('What should I do before restarting a silent node?', 'chunk_demo_docs_chunks', 'embedding', '{}');
SELECT fractal_config_set('agent_use_index', 'off');

.print
.print Tables left in place for inspection. Clean up with:
.print   SELECT fractal_index_drop('chunk_demo_docs_chunks_embedding'); DROP TABLE chunk_demo_docs_chunks; DROP TABLE chunk_demo_docs;
