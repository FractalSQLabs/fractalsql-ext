-- demo/demo-fractal-vector.sql
--
-- This build has NO fractal_vector catalog type -- see
-- docs/api-analytics.md (DuckDB
-- has no typmod/varlena type system; its own fixed-size ARRAY already
-- gives the same dimension enforcement, so a bespoke catalog type
-- would be redundant engineering). This file is therefore a
-- float8[]-only walkthrough of the same functions, not a comparison
-- between two storage types:
--   - Section 0's dynamic-dimension block (DDL built from a query
--     result inside server-side procedural SQL) has no plain-SQL-
--     script analog here -- scripts can't branch or build DDL from a
--     query result. This version hardcodes 768
--     (nomic-embed-text's output width); using a different embedding
--     model means editing that width by hand.
--   - Section 3's dimension-mismatch hard-fail demo used a DO/EXCEPTION
--     block to catch the error and keep the script running -- DuckDB
--     SQL scripts have no try/catch. The failing INSERT is shown
--     commented out instead of actually run, so this file stays
--     runnable start-to-finish under `duckdb -bail`.
--   - Section 4's fractal_search_trajectory call runs on its own small
--     fixture instead of on docs_fv: DuckDB table functions take only
--     constant arguments (no subquery, no lateral join column), so the
--     two query vectors cannot be read back out of the table the way
--     the postgres port does it. The fixture carries the same vectors
--     by hand, so the numbers stay readable at a glance.
--   - Section 5's `<->`/`<=>`/`<#>` distance operators and `+`/`-`/`*`
--     arithmetic operators don't exist here -- DuckDB extensions can't
--     define new infix operators. Rewritten as the equivalent named
--     fractal_vector_l2_distance/_cosine_distance/_dot/_add/_sub/_scale calls.
--   - fractal_vector_dims/_from_float8_array/_to_float8_array don't
--     exist in this build at all (not just renamed) -- confirmed absent
--     from docs/api-analytics.md. len() replaces
--     fractal_vector_dims; the array-cast round-trip section is
--     dropped since there's no second type to cast to/from -- typeof()
--     is used instead to show the column's actual type.
--   - Section 6's storage-size comparison is dropped -- there's only
--     one storage representation in this build, so there's nothing to
--     compare.
--   - fractal_vector_* arithmetic functions take LIST(FLOAT) (float4),
--     not LIST(DOUBLE) -- see docs/api-analytics.md. embedding
--     is float8[] (fractal_embed returns LIST(DOUBLE)), so every
--     fractal_vector_* call below on it needs an explicit ::float4[]
--     cast at the call site. fractal_search_trajectory, by contrast, is
--     DOUBLE-based and needs no such cast.
--
-- Prerequisites: extension loaded, reasoning AND embedding configured
-- -- same setup as demo/demo-vectorizer.sql. Confirm before running:
--   SELECT fractal_embed('reply with a short confirmation that this connection works');
--
-- Safe to re-run: the schema is dropped and recreated at the top.

-- (Timing is omitted -- DuckDB's CLI has no per-statement
-- timing dot-command; measure latency at the harness level, e.g.
-- demo/demo-workload.sh.)

-- Re-runnable: tear down a prior run's vectorizer config + queue, then
-- drop the demo tables. The bookkeeping bootstrap mirrors the vectorizer
-- surfaces' own IF NOT EXISTS schema (docs/vectorizer-setup.md)
-- so the DELETEs really are no-ops on a fresh database.
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
DELETE FROM fractal_vectorizer_queue WHERE vectorizer_id IN
    (SELECT id FROM fractal_vectorizers WHERE source_table = 'docs_fv');
DELETE FROM fractal_vectorizers WHERE source_table = 'docs_fv';
DROP TABLE IF EXISTS docs_fv;
DROP SEQUENCE IF EXISTS seq_docs_fv_id;

-- Hardcoded to nomic-embed-text's 768-dim output (see PORT NOTE above
-- for why this width is a constant by hand rather than probed at
-- runtime). Edit this width if your configured embedding model differs.
CREATE SEQUENCE seq_docs_fv_id;
CREATE TABLE docs_fv (
    id       INTEGER PRIMARY KEY DEFAULT nextval('seq_docs_fv_id'),
    body     text NOT NULL,
    embedding float8[768]
);

.print === Section 1: dimension enforcement is automatic ===
.print fractal_vectorizer_create() and process_queue() below need ZERO changes
.print from the plain float8[] demo -- the fixed-size ARRAY column type alone
.print is what makes a dimension mismatch a hard error instead of silent corruption.
INSERT INTO docs_fv (id, body) VALUES
    (nextval('seq_docs_fv_id'), 'FractalSQL runs Stochastic Fractal Search directly inside DuckDB.'),
    (nextval('seq_docs_fv_id'), 'The reasoning plugin speaks the OpenAI chat-completions and embeddings shapes.');

SELECT id, body FROM docs_fv ORDER BY id ASC;

.print
.print === Section 2: create the vectorizer -- exactly like the float8[] demo ===
SELECT fractal_vectorizer_create('docs_fv', 'id', 'body', 'embedding');
SELECT fractal_vectorizer_process_queue();

SELECT id, body, embedding IS NOT NULL AS has_embedding,
       len(embedding) AS dim
FROM docs_fv
ORDER BY id ASC;

.print
.print === Section 3: the hard-fail, shown not run ===
.print A dimension mismatch on this column raises immediately -- no separate
.print validation step, no silent truncation. Shown commented out (not run)
.print so this demo stays runnable start-to-finish under `duckdb -bail`:
.print   INSERT INTO docs_fv (id, body, embedding)
.print   VALUES (nextval(seq_docs_fv_id), [deliberately wrong dimension], [0.1, 0.2]::float8[]);
.print   -- Binder Error: cannot cast a 2-element list to float8[768]
-- INSERT INTO docs_fv (id, body, embedding)
-- VALUES (nextval('seq_docs_fv_id'), 'deliberately wrong dimension', [0.1, 0.2]::float8[]);

.print
.print === Section 4: fractal_search_trajectory over a float8[] column ===
-- The trajectory search asks WHAT CHANGED: it searches the corpus for
-- the rows nearest to (current - baseline), not nearest to the current
-- vector itself.
--
-- DuckDB table functions accept only CONSTANT arguments -- a subquery
-- or a lateral join column in one is a binder error ("Table function
-- cannot contain subqueries" / "does not support lateral join column
-- parameters"). The postgres port of this demo hands the function two
-- rows' own embeddings; that is not expressible here, so the two
-- query vectors are spelled out as literals and the corpus is a small
-- fixed fixture whose vectors are visible by eye.
--
-- The fixture's row 2 carries exactly the drift vector, so it comes
-- back at distance 0.0; row 1 drifts along +x (0.4), row 4 along +z
-- (1.0) and row 3 against the change (2.0, outside the top 3).
--
-- doc_id is the 0-INDEXED scan position in the corpus, so it is
-- resolved back to the row through rowid.
DROP TABLE IF EXISTS fv_traj_docs;
CREATE TABLE fv_traj_docs (id INTEGER, label TEXT, embedding float8[]);
INSERT INTO fv_traj_docs VALUES
    (1, 'drift along +x',            [1.0, 0.0, 0.0]),
    (2, 'drift along the change',    [0.6, 0.8, 0.0]),
    (3, 'drift against the change',  [-0.6, -0.8, 0.0]),
    (4, 'drift along +z',            [0.0, 0.0, 1.0]);

SELECT tr.doc_id, d.id AS doc_id_resolved, d.label, tr.distance
FROM fractal_search_trajectory(
         'fv_traj_docs', 'embedding',
         [0.0, 0.0, 0.0]::float8[],
         [0.6, 0.8, 0.0]::float8[], 3) tr
JOIN fv_traj_docs d ON d.rowid::VARCHAR = tr.doc_id::VARCHAR
ORDER BY tr.distance;

.print
.print === Section 5: fractal_vector_* functions (distances, arithmetic, quantization) ===
.print No <->/<=>/<#> operators or +/-/* operators in this build -- named
.print functions only (see PORT NOTE above). ::float4[] casts because these
.print functions take LIST(FLOAT), and embedding is float8[].
SELECT
    fractal_vector_l2_distance(a.embedding::float4[], b.embedding::float4[])              AS l2_distance,
    fractal_vector_cosine_distance(a.embedding::float4[], b.embedding::float4[]) AS cosine_distance,
    -fractal_vector_dot(a.embedding::float4[], b.embedding::float4[])            AS neg_inner_product,
    fractal_vector_l2_squared(a.embedding::float4[], b.embedding::float4[])           AS l2_squared,
    fractal_vector_cosine_similarity(a.embedding::float4[], b.embedding::float4[]) AS cosine_similarity,
    fractal_vector_norm(a.embedding::float4[])                                  AS norm_a,
    fractal_vector_norm(b.embedding::float4[])                                  AS norm_b
FROM docs_fv a, docs_fv b
WHERE a.id = 1 AND b.id = 2
  AND a.embedding IS NOT NULL AND b.embedding IS NOT NULL;

-- len() replaces fractal_vector_dims (which doesn't exist in this
-- port at all) to confirm arithmetic results preserve the element count.
SELECT
    len(fractal_vector_add(a.embedding::float4[], b.embedding::float4[]))      AS add_dims,
    len(fractal_vector_sub(a.embedding::float4[], b.embedding::float4[]))      AS sub_dims,
    len(fractal_vector_scale(a.embedding::float4[], 2.0::float4))             AS scale_dims,
    len(fractal_vector_normalize(a.embedding::float4[]))                      AS normalize_dims
FROM docs_fv a, docs_fv b
WHERE a.id = 1 AND b.id = 2
  AND a.embedding IS NOT NULL AND b.embedding IS NOT NULL;

-- typeof() shows the column's actual type -- there's no second vector
-- type to cast to/from in this build (fractal_vector_from_float8_array /
-- _to_float8_array don't exist here), so this just confirms the
-- column's storage type rather than demonstrating a round-trip cast.
SELECT typeof(embedding) AS embedding_type FROM docs_fv WHERE id = 1;

.print
.print === Section 6: L_p distance and quantization ===
.print Known 3-dim inputs, so the outputs are readable at a glance.

-- Generalized L_p distance. p=2 here matches fractal_vector_l2_distance's own
-- L2 distance mathematically (0.1414 for these two vectors); p=0.5 is
-- shown for contrast but is NOT a proper metric -- use it explicitly,
-- never as a silent default. bracket-style '[...]' literals cast
-- directly to float4[] here (this build's list-literal syntax);
-- there is no fractal_vector input function to cast through.
SELECT
    fractal_vector_lp_distance(
        '[1,0,0]'::float4[],
        '[0.9,0.1,0]'::float4[], 2.0::float4) AS lp2_distance,
    fractal_vector_lp_distance(
        '[1,0,0]'::float4[],
        '[0.9,0.1,0]'::float4[], 0.5::float4) AS lp_half_distance;

-- Symmetric int8 quantization: 4x compression. The document is JSON:
-- {"scale":S,"codes":[...]} -- one raw signed-byte integer per
-- dimension, dequantize via v[i] ~= codes[i] * scale.
SELECT json_extract(q, '$.scale') AS scale,
       json_extract(q, '$.codes') AS codes
FROM (SELECT fractal_vector_quantize_int8('[1,-2,3]'::float4[]) AS q) t;

-- Binary (1-bit) quantization: 32x compression, bit i = (v[i] >= 0),
-- paired with fractal_vector_hamming_distance for cheap candidate
-- filtering ahead of a full-precision re-rank. These two vectors
-- differ in exactly one sign bit, so the Hamming distance is 1.
SELECT fractal_vector_quantize_binary('[1,-2,3]'::float4[]) AS binary_a,
       fractal_vector_quantize_binary('[1,2,3]'::float4[])  AS binary_b;
SELECT fractal_vector_hamming_distance(
    fractal_vector_quantize_binary('[1,-2,3]'::float4[]),
    fractal_vector_quantize_binary('[1,2,3]'::float4[])
) AS hamming_distance;

.print
.print ================================================================
.print Next: bench/vector_type_head_to_head.py for the same functions
.print exercised at 100k-row scale.
.print
.print This demo is re-runnable: the vectorizer config + queue + table are
.print torn down at the top of the file, so it can be re-run without manual
.print cleanup. The Section 4 fixture table is dropped and recreated by
.print Section 4 itself, so it is re-runnable too; drop it with
.print   DROP TABLE fv_traj_docs;
.print ================================================================
