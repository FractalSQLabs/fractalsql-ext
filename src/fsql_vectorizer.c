/* src/fsql_vectorizer.c
 *
 * Embeddings and the "vectorizer" family: keep a text column's embeddings in sync as rows are
 * added, without a background worker.
 *
 *   fractal_embed(input VARCHAR) -> DOUBLE[]
 *   fractal_vectorizer_create(source_table, source_pk_col, text_col, embedding_col
 *                             [, options]) -> BIGINT          (3-arg form detects the PK)
 *   fractal_vectorizer_drop / _pause / _resume(vectorizer_id BIGINT) -> BOOLEAN
 *   fractal_vectorizer_process_queue([batch_size INTEGER [, stale_after_secs INTEGER]]) -> BIGINT
 *   fractal_vectorizer_status() -> TABLE(id, source_table, enabled, pending, processing, done, failed)
 *
 * Identifiers are validated, never free-form: every dot-separated segment matches
 * [A-Za-z_][A-Za-z0-9_]*, at most 63 characters per segment and 256 per name; a table may be
 * schema-qualified (two segments), a column may not. Anything else is refused with
 * "fractalsql: invalid identifier" before it reaches a statement.
 *
 * The options argument is a JSON object that is PARSED, not just stored: max_embeds_per_window
 * (<= 0 or absent = uncapped) and window_secs (default 3600). Unknown keys are refused.
 *
 * DuckDB has no triggers, so process_queue() opens with a diff scan (text present, embedding
 * missing, pk not yet queued) and enqueues what it finds; create() runs the same scan once as a
 * backfill. All bookkeeping goes through nested queries on the instance's pooled connections.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 */

#include <ctype.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_duckdb_internal.h"

#define ERRCAP 4096
#define IDENT_MAX_SEGMENT 63
#define IDENT_MAX_TOTAL   256
#define MAX_BATCH         100000

static void fail(duckdb_function_info info, const char *msg) { duckdb_scalar_function_set_error(info, msg); }

/* ------------------------------------------------------------------ */
/* fractal_embed                                                        */
/* ------------------------------------------------------------------ */

/* The first '[' onward: numbers separated by space/comma/newline up to ']'. false on a non-number. */
static bool parse_double_array(const char *json, fsql_vecd *out) {
    const char *p = strchr(json, '[');
    if (!p) return false;
    p++;
    while (*p) {
        while (*p == ' ' || *p == ',' || *p == '\n' || *p == '\r' || *p == '\t') p++;
        if (*p == ']' || !*p) break;
        char *end = NULL;
        double d = strtod(p, &end);
        if (end == p) return false;
        fsql_vecd_push(out, d);
        p = end;
    }
    return fsql_vecd_ok(out);
}

static void embed_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    idx_t n = duckdb_data_chunk_get_size(in);
    const duckdb_string_t *d = (const duckdb_string_t *)fsql_col_data(in, 0);
    const uint64_t *v = fsql_col_validity(in, 0);
    fsql_list_out w;
    fsql_list_out_open(&w, out);
    for (idx_t i = 0; i < n; i++) {
        if (!fsql_valid(v, i)) { fsql_list_out_put_null(&w, i); continue; }
        size_t len; const char *s = fsql_str_data(&d[i], &len);
        if (len > FSQL_MAX_INPUT_BYTES) { fail(info, "fractalsql: fractal_embed: input exceeds the 4 MiB limit"); break; }
        char *resp = NULL, err[1024];
        if (fsql_reasoning_generate(FSQL_REASONING_TIER_EMBED, s, len, "{}", 2, &resp, err, sizeof err) != FSQL_REASONING_OK) {
            fail(info, err); break;
        }
        fsql_vecd vec; fsql_vecd_init(&vec);
        bool ok = parse_double_array(resp, &vec) && vec.len > 0;
        free(resp);
        if (!ok) {
            fsql_vecd_free(&vec);
            fail(info, "fractalsql: fractal_embed got a non-numeric-array response -- is FSQL_REASONING_HTTP_EMBED_URL "
                       "pointing at an embeddings endpoint?");
            break;
        }
        bool put = fsql_list_out_put(&w, i, vec.p, vec.len);
        fsql_vecd_free(&vec);
        if (!put) { fail(info, "fractalsql: out of memory"); break; }
    }
    fsql_list_out_close(&w);
}

/* ------------------------------------------------------------------ */
/* Identifiers and SQL text                                             */
/* ------------------------------------------------------------------ */

static void put_literal(fsql_sb *b, const char *s, size_t n) {
    fsql_sb_putc(b, '\'');
    for (size_t i = 0; i < n; i++) { if (s[i] == '\'') fsql_sb_putc(b, '\''); fsql_sb_putc(b, s[i]); }
    fsql_sb_putc(b, '\'');
}
static void put_lit(fsql_sb *b, const char *s) { put_literal(b, s, strlen(s)); }

typedef struct { char seg[3][IDENT_MAX_SEGMENT + 1]; int n; } ident;

static bool ident_char_ok(char c, bool first) {
    return c == '_' || isalpha((unsigned char)c) || (!first && isdigit((unsigned char)c));
}

/* Splits on '.'; n is the TOTAL segment count (only the first three are kept). */
static bool split_ident(const char *s, ident *o) {
    size_t len = strlen(s);
    o->n = 0;
    if (len == 0 || len > IDENT_MAX_TOTAL) return false;
    size_t sl = 0;
    char cur[IDENT_MAX_SEGMENT + 1];
    for (size_t i = 0; i < len; i++) {
        char c = s[i];
        if (c == '.') {
            if (sl == 0) return false;
            cur[sl] = 0;
            if (o->n < 3) memcpy(o->seg[o->n], cur, sl + 1);
            o->n++; sl = 0;
            continue;
        }
        if (!ident_char_ok(c, sl == 0)) return false;
        if (sl >= IDENT_MAX_SEGMENT) return false;
        cur[sl++] = c;
    }
    if (sl == 0) return false;
    cur[sl] = 0;
    if (o->n < 3) memcpy(o->seg[o->n], cur, sl + 1);
    o->n++;
    return true;
}

static void invalid_ident(const char *s, char *err) {
    bool printable = *s != 0;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) if (*p < 0x20 || *p > 0x7e) { printable = false; break; }
    if (printable) snprintf(err, ERRCAP, "fractalsql: invalid identifier: %s", s);
    else snprintf(err, ERRCAP, "fractalsql: invalid identifier");
}

static void put_segments(fsql_sb *b, const ident *id) {
    int k = id->n < 3 ? id->n : 3;
    for (int i = 0; i < k; i++) { if (i) fsql_sb_putc(b, '.'); fsql_sb_putc(b, '"'); fsql_sb_puts(b, id->seg[i]); fsql_sb_putc(b, '"'); }
}

/* Appends the quoted table (1 or 2 segments) / column (exactly 1) to `b`; 0 ok, -1 + err. */
static int quote_table(const char *s, fsql_sb *b, char *err) {
    ident id;
    if (!split_ident(s, &id) || id.n > 2) { invalid_ident(s, err); return -1; }
    put_segments(b, &id);
    return 0;
}
static int quote_column(const char *s, fsql_sb *b, char *err) {
    ident id;
    if (!split_ident(s, &id) || id.n != 1) { invalid_ident(s, err); return -1; }
    put_segments(b, &id);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Options                                                              */
/* ------------------------------------------------------------------ */

typedef struct { int64_t max_embeds_per_window, window_secs; } vopts;

static void ws(const char *s, size_t n, size_t *i) { while (*i < n && (s[*i] == ' ' || s[*i] == '\t' || s[*i] == '\n' || s[*i] == '\r')) (*i)++; }

/* Reads a JSON string at s[*i] into `out` (cleared first). */
static bool read_string(const char *s, size_t n, size_t *i, fsql_sb *out) {
    if (*i >= n || s[*i] != '"') return false;
    (*i)++;
    fsql_sb_clear(out);
    while (*i < n) {
        char c = s[(*i)++];
        if (c == '"') return true;
        if (c == '\\') {
            if (*i >= n) return false;
            char e = s[(*i)++];
            switch (e) {
            case '"': fsql_sb_putc(out, '"'); break;
            case '\\': fsql_sb_putc(out, '\\'); break;
            case '/': fsql_sb_putc(out, '/'); break;
            case 'b': fsql_sb_putc(out, '\b'); break;
            case 'f': fsql_sb_putc(out, '\f'); break;
            case 'n': fsql_sb_putc(out, '\n'); break;
            case 'r': fsql_sb_putc(out, '\r'); break;
            case 't': fsql_sb_putc(out, '\t'); break;
            default: return false;
            }
            continue;
        }
        fsql_sb_putc(out, c);
    }
    return false;
}

static bool read_int(const char *s, size_t n, size_t *i, int64_t *out) {
    size_t start = *i;
    if (*i < n && (s[*i] == '-' || s[*i] == '+')) (*i)++;
    size_t digits = 0;
    while (*i < n && s[*i] >= '0' && s[*i] <= '9') { (*i)++; digits++; }
    if (digits == 0) { *i = start; return false; }
    if (*i < n && (s[*i] == '.' || s[*i] == 'e' || s[*i] == 'E')) { *i = start; return false; }
    char tmp[64]; size_t l = *i - start;
    if (l >= sizeof tmp) l = sizeof tmp - 1;
    memcpy(tmp, s + start, l); tmp[l] = 0;
    *out = (int64_t)strtoll(tmp, NULL, 10);
    return true;
}

static bool skip_value(const char *s, size_t n, size_t *i) {
    if (*i >= n) return false;
    if (s[*i] == '"') { fsql_sb t; fsql_sb_init(&t); bool ok = read_string(s, n, i, &t); fsql_sb_free(&t); return ok; }
    if (s[*i] == '{' || s[*i] == '[') {
        char close = s[*i] == '{' ? '}' : ']';
        int depth = 0;
        while (*i < n) {
            char d = s[*i];
            if (d == '"') { fsql_sb t; fsql_sb_init(&t); bool ok = read_string(s, n, i, &t); fsql_sb_free(&t); if (!ok) return false; continue; }
            if (d == '{' || d == '[') depth++;
            else if (d == '}' || d == ']') { depth--; if (depth == 0) { (*i)++; return d == close; } }
            (*i)++;
        }
        return false;
    }
    size_t start = *i;
    while (*i < n && s[*i] != ',' && s[*i] != '}' && s[*i] != ']' && s[*i] != ' ' && s[*i] != '\t' && s[*i] != '\n' && s[*i] != '\r') (*i)++;
    return *i > start;
}

static int parse_options(const char *s, vopts *o, char *err) {
    static const char bad[] = "fractalsql: vectorizer options: malformed JSON";
    size_t n = strlen(s), i = 0;
    o->max_embeds_per_window = 0; o->window_secs = 3600;
    ws(s, n, &i);
    if (i >= n) return 0;
    if (s[i] != '{') { snprintf(err, ERRCAP, "fractalsql: vectorizer options must be a JSON object"); return -1; }
    i++;
    fsql_sb key; fsql_sb_init(&key);
    int rc = -1;
    for (;;) {
        ws(s, n, &i);
        if (i >= n) { snprintf(err, ERRCAP, "%s", bad); goto done; }
        if (s[i] == '}') { i++; break; }
        if (!read_string(s, n, &i, &key)) { snprintf(err, ERRCAP, "%s", bad); goto done; }
        ws(s, n, &i);
        if (i >= n || s[i] != ':') { snprintf(err, ERRCAP, "%s", bad); goto done; }
        i++;
        ws(s, n, &i);
        if (i >= n) { snprintf(err, ERRCAP, "%s", bad); goto done; }
        const char *k = fsql_sb_cstr(&key);
        if (!strcmp(k, "max_embeds_per_window") || !strcmp(k, "window_secs")) {
            int64_t value = 0;
            if (!read_int(s, n, &i, &value)) { snprintf(err, ERRCAP, "fractalsql: vectorizer option '%s' must be an integer", k); goto done; }
            if (!strcmp(k, "max_embeds_per_window")) {
                if (value < 0) { snprintf(err, ERRCAP, "fractalsql: vectorizer option '%s' must not be negative", k); goto done; }
                o->max_embeds_per_window = value;
            } else {
                if (value < 1) { snprintf(err, ERRCAP, "fractalsql: vectorizer option '%s' must be a positive number of seconds", k); goto done; }
                o->window_secs = value;
            }
        } else {
            if (!skip_value(s, n, &i)) { snprintf(err, ERRCAP, "%s", bad); goto done; }
            snprintf(err, ERRCAP, "fractalsql: unknown vectorizer option '%s'", k);
            goto done;
        }
        ws(s, n, &i);
        if (i >= n) { snprintf(err, ERRCAP, "%s", bad); goto done; }
        if (s[i] == ',') { i++; continue; }
        if (s[i] == '}') { i++; break; }
        snprintf(err, ERRCAP, "%s", bad); goto done;
    }
    ws(s, n, &i);
    if (i != n) { snprintf(err, ERRCAP, "%s", bad); goto done; }
    rc = 0;
done:
    fsql_sb_free(&key);
    return rc;
}

/* ------------------------------------------------------------------ */
/* Nested-query helpers                                                 */
/* ------------------------------------------------------------------ */

static int run(fsql_instance *inst, const char *sql, char *err) {
    fsql_qres r;
    if (fsql_nested_query(inst, sql, &r, err, ERRCAP)) return -1;
    fsql_qres_free(&r);
    return 0;
}

static int64_t cell_i64(duckdb_data_chunk ch, idx_t c, idx_t row) {
    return ((const int64_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(ch, c)))[row];
}
static char *cell_str(duckdb_data_chunk ch, idx_t c, idx_t row) {
    duckdb_vector v = duckdb_data_chunk_get_vector(ch, c);
    if (!fsql_valid(duckdb_vector_get_validity(v), row)) return fsql_xstrdup("");
    size_t n; const char *p = fsql_str_data(&((const duckdb_string_t *)duckdb_vector_get_data(v))[row], &n);
    return fsql_xstrndup(p, n);
}

/* Runs `sql` and returns the first cell of the first row as int64; *found = a row came back. */
static int first_i64(fsql_instance *inst, const char *sql, int64_t *val, bool *found, char *err) {
    fsql_qres r;
    *found = false;
    if (fsql_nested_query(inst, sql, &r, err, ERRCAP)) return -1;
    duckdb_data_chunk ch = fsql_qres_next_chunk(&r);
    if (ch) {
        if (duckdb_data_chunk_get_size(ch) > 0) { *val = cell_i64(ch, 0, 0); *found = true; }
        duckdb_destroy_data_chunk(&ch);
    }
    fsql_qres_free(&r);
    return 0;
}

static int ensure_tables(fsql_instance *inst, char *err) {
    static const char *const ddl[] = {
        "CREATE SEQUENCE IF NOT EXISTS fractal_vectorizer_id_seq START 1",
        "CREATE TABLE IF NOT EXISTS fractal_vectorizers ("
        "  id BIGINT PRIMARY KEY,"
        "  source_table VARCHAR NOT NULL,"
        "  source_pk_col VARCHAR NOT NULL,"
        "  text_col VARCHAR NOT NULL,"
        "  embedding_col VARCHAR NOT NULL,"
        "  options VARCHAR NOT NULL DEFAULT '{}',"
        "  enabled BOOLEAN NOT NULL DEFAULT true,"
        "  created_at TIMESTAMP NOT NULL DEFAULT now(),"
        "  UNIQUE (source_table, text_col, embedding_col)"
        ")",
        "CREATE TABLE IF NOT EXISTS fractal_vectorizer_queue ("
        "  vectorizer_id BIGINT NOT NULL,"
        "  pk_value VARCHAR NOT NULL,"
        "  status VARCHAR NOT NULL DEFAULT 'pending',"
        "  enqueued_at TIMESTAMP NOT NULL DEFAULT now(),"
        "  started_at TIMESTAMP,"
        "  error VARCHAR"
        ")",
        "CREATE TABLE IF NOT EXISTS fractal_vectorizer_rate ("
        "  vectorizer_id BIGINT PRIMARY KEY,"
        "  window_started_at TIMESTAMP NOT NULL,"
        "  used BIGINT NOT NULL DEFAULT 0"
        ")",
    };
    for (size_t i = 0; i < sizeof ddl / sizeof ddl[0]; i++) if (run(inst, ddl[i], err)) return -1;
    return 0;
}

/* ------------------------------------------------------------------ */
/* create / drop / pause / resume                                       */
/* ------------------------------------------------------------------ */

/* The single-column PRIMARY KEY of `table`, malloc'd. */
static char *detect_pk(fsql_instance *inst, const char *table, char *err) {
    fsql_sb sb; fsql_sb_init(&sb);
    char *res = NULL;
    fsql_sb_puts(&sb, "SELECT 1 FROM ");
    if (quote_table(table, &sb, err)) goto done;
    fsql_sb_puts(&sb, " LIMIT 0");
    if (run(inst, fsql_sb_cstr(&sb), err)) goto done;
    ident id;
    split_ident(table, &id);
    fsql_sb_clear(&sb);
    fsql_sb_puts(&sb, "SELECT constraint_column_names FROM duckdb_constraints() WHERE constraint_type = 'PRIMARY KEY' AND table_name = ");
    put_lit(&sb, id.seg[id.n == 2 ? 1 : 0]);
    if (id.n == 2) { fsql_sb_puts(&sb, " AND schema_name = "); put_lit(&sb, id.seg[0]); }
    fsql_qres r;
    if (fsql_nested_query(inst, fsql_sb_cstr(&sb), &r, err, ERRCAP)) goto done;
    duckdb_data_chunk ch = fsql_qres_next_chunk(&r);
    if (!ch || duckdb_data_chunk_get_size(ch) == 0) {
        if (ch) duckdb_destroy_data_chunk(&ch);
        fsql_qres_free(&r);
        snprintf(err, ERRCAP, "fractalsql: %s has no declared PRIMARY KEY -- pass source_pk_col explicitly to fractal_vectorizer_create", table);
        goto done;
    }
    duckdb_vector lv = duckdb_data_chunk_get_vector(ch, 0);
    duckdb_list_entry e = ((const duckdb_list_entry *)duckdb_vector_get_data(lv))[0];
    if (e.length != 1) {
        duckdb_destroy_data_chunk(&ch); fsql_qres_free(&r);
        snprintf(err, ERRCAP, "fractalsql: %s has a composite primary key -- fractal_vectorizer_create needs a single-column key", table);
        goto done;
    }
    duckdb_vector child = duckdb_list_vector_get_child(lv);
    size_t n; const char *p = fsql_str_data(&((const duckdb_string_t *)duckdb_vector_get_data(child))[e.offset], &n);
    res = fsql_xstrndup(p, n);
    duckdb_destroy_data_chunk(&ch);
    fsql_qres_free(&r);
done:
    fsql_sb_free(&sb);
    return res;
}

static int create_one(fsql_instance *inst, const char *source_table, const char *source_pk, const char *text_col,
                      const char *emb_col, const char *options, int64_t *new_id, char *err) {
    fsql_sb qs, qt, qe, qp, sql;
    fsql_sb_init(&qs); fsql_sb_init(&qt); fsql_sb_init(&qe); fsql_sb_init(&qp); fsql_sb_init(&sql);
    char *pk_col = NULL;
    int rc = -1;
    vopts vo;
    if (quote_table(source_table, &qs, err) || quote_column(text_col, &qt, err) || quote_column(emb_col, &qe, err)) goto done;
    if (parse_options(options, &vo, err)) goto done;
    if (*source_pk) pk_col = fsql_xstrdup(source_pk);
    else { pk_col = detect_pk(inst, source_table, err); if (!pk_col) goto done; }
    if (quote_column(pk_col, &qp, err)) goto done;

    fsql_sb_puts(&sql, "SELECT id FROM fractal_vectorizers WHERE source_table = ");
    put_lit(&sql, source_table);
    fsql_sb_puts(&sql, " AND text_col = "); put_lit(&sql, text_col);
    fsql_sb_puts(&sql, " AND embedding_col = "); put_lit(&sql, emb_col);
    int64_t existing; bool found;
    if (first_i64(inst, fsql_sb_cstr(&sql), &existing, &found, err)) goto done;
    if (found) {
        snprintf(err, ERRCAP, "fractalsql: fractal_vectorizer_create: a vectorizer for %s.%s -> %s already exists (id=%" PRId64 ")",
                 fsql_sb_cstr(&qs), fsql_sb_cstr(&qt), fsql_sb_cstr(&qe), existing);
        goto done;
    }
    fsql_sb_clear(&sql);
    fsql_sb_puts(&sql, "INSERT INTO fractal_vectorizers (id, source_table, source_pk_col, text_col, embedding_col, options) "
                       "VALUES (nextval('fractal_vectorizer_id_seq'), ");
    put_lit(&sql, source_table); fsql_sb_puts(&sql, ", ");
    put_lit(&sql, pk_col);       fsql_sb_puts(&sql, ", ");
    put_lit(&sql, text_col);     fsql_sb_puts(&sql, ", ");
    put_lit(&sql, emb_col);      fsql_sb_puts(&sql, ", ");
    put_lit(&sql, options);      fsql_sb_puts(&sql, ") RETURNING id");
    if (first_i64(inst, fsql_sb_cstr(&sql), new_id, &found, err)) goto done;
    if (!found) { snprintf(err, ERRCAP, "fractalsql: fractal_vectorizer_create: insert returned no id"); goto done; }

    fsql_sb_clear(&sql);
    fsql_sb_printf(&sql, "INSERT INTO fractal_vectorizer_queue (vectorizer_id, pk_value) SELECT %" PRId64 ", CAST(%s AS VARCHAR) FROM %s WHERE %s IS NOT NULL AND %s IS NULL",
                   *new_id, fsql_sb_cstr(&qp), fsql_sb_cstr(&qs), fsql_sb_cstr(&qt), fsql_sb_cstr(&qe));
    if (run(inst, fsql_sb_cstr(&sql), err)) goto done;
    rc = 0;
done:
    free(pk_col);
    fsql_sb_free(&qs); fsql_sb_free(&qt); fsql_sb_free(&qe); fsql_sb_free(&qp); fsql_sb_free(&sql);
    return rc;
}

static void create_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    fsql_instance *inst = fsql_scalar_instance(info);
    idx_t n = duckdb_data_chunk_get_size(in), nc = duckdb_data_chunk_get_column_count(in);
    char err[ERRCAP];
    if (ensure_tables(inst, err)) { fail(info, err); return; }
    int64_t *res = (int64_t *)duckdb_vector_get_data(out);
    for (idx_t i = 0; i < n; i++) {
        char *a[5] = { NULL, NULL, NULL, NULL, NULL };
        for (idx_t c = 0; c < nc; c++) {
            size_t l; const char *p = fsql_str_data(&((const duckdb_string_t *)fsql_col_data(in, c))[i], &l);
            a[c] = fsql_xstrndup(p, l);
            if (!a[c]) {
                for (idx_t d = 0; d < c; d++) free(a[d]);
                fail(info, "fractalsql: out of memory"); return;
            }
        }
        /* 3 args: (table, text, embedding); 4+: (table, pk, text, embedding[, options]) */
        int rc;
        if (nc == 3) rc = create_one(inst, a[0], "", a[1], a[2], "{}", &res[i], err);
        else         rc = create_one(inst, a[0], a[1], a[2], a[3], nc > 4 ? a[4] : "{}", &res[i], err);
        for (idx_t c = 0; c < nc; c++) free(a[c]);
        if (rc) { fail(info, err); return; }
    }
}

static int require_exists(fsql_instance *inst, int64_t id, const char *fn, char *err) {
    char sql[128]; int64_t v; bool found;
    snprintf(sql, sizeof sql, "SELECT 1 FROM fractal_vectorizers WHERE id = %" PRId64, id);
    if (first_i64(inst, sql, &v, &found, err)) return -1;
    if (!found) { snprintf(err, ERRCAP, "fractalsql: %s: no vectorizer with id %" PRId64, fn, id); return -1; }
    return 0;
}

static void drop_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    fsql_instance *inst = fsql_scalar_instance(info);
    idx_t n = duckdb_data_chunk_get_size(in);
    const int64_t *ids = (const int64_t *)fsql_col_data(in, 0);
    bool *res = (bool *)duckdb_vector_get_data(out);
    char err[ERRCAP], sql[160];
    if (ensure_tables(inst, err)) { fail(info, err); return; }
    for (idx_t i = 0; i < n; i++) {
        if (require_exists(inst, ids[i], "fractal_vectorizer_drop", err)) { fail(info, err); return; }
        snprintf(sql, sizeof sql, "DELETE FROM fractal_vectorizer_queue WHERE vectorizer_id = %" PRId64, ids[i]);
        if (run(inst, sql, err)) { fail(info, err); return; }
        snprintf(sql, sizeof sql, "DELETE FROM fractal_vectorizer_rate WHERE vectorizer_id = %" PRId64, ids[i]);
        if (run(inst, sql, err)) { fail(info, err); return; }
        snprintf(sql, sizeof sql, "DELETE FROM fractal_vectorizers WHERE id = %" PRId64, ids[i]);
        if (run(inst, sql, err)) { fail(info, err); return; }
        res[i] = true;
    }
}

static void set_enabled(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out, bool enabled, const char *fn) {
    fsql_instance *inst = fsql_scalar_instance(info);
    idx_t n = duckdb_data_chunk_get_size(in);
    const int64_t *ids = (const int64_t *)fsql_col_data(in, 0);
    bool *res = (bool *)duckdb_vector_get_data(out);
    char err[ERRCAP], sql[160];
    if (ensure_tables(inst, err)) { fail(info, err); return; }
    for (idx_t i = 0; i < n; i++) {
        if (require_exists(inst, ids[i], fn, err)) { fail(info, err); return; }
        snprintf(sql, sizeof sql, "UPDATE fractal_vectorizers SET enabled = %s WHERE id = %" PRId64, enabled ? "true" : "false", ids[i]);
        if (run(inst, sql, err)) { fail(info, err); return; }
        res[i] = true;
    }
}
static void pause_fn(duckdb_function_info i, duckdb_data_chunk in, duckdb_vector o)  { set_enabled(i, in, o, false, "fractal_vectorizer_pause"); }
static void resume_fn(duckdb_function_info i, duckdb_data_chunk in, duckdb_vector o) { set_enabled(i, in, o, true, "fractal_vectorizer_resume"); }

/* ------------------------------------------------------------------ */
/* process_queue                                                        */
/* ------------------------------------------------------------------ */

typedef struct {
    int64_t id;
    char *q_source, *q_pk, *q_text, *q_emb;
    vopts opts;
} vcfg;

static void vcfg_free(vcfg *c) { free(c->q_source); free(c->q_pk); free(c->q_text); free(c->q_emb); }

static char *sb_dup_quoted(int (*q)(const char *, fsql_sb *, char *), const char *s, char *err) {
    fsql_sb b; fsql_sb_init(&b);
    char *r = NULL;
    if (!q(s, &b, err)) r = fsql_sb_take(&b);
    fsql_sb_free(&b);
    return r;
}

/* true: a slot in the rate window was consumed (or no cap). */
static int rate_gate(fsql_instance *inst, const vcfg *c, bool *ok, char *err) {
    char sql[512];
    *ok = true;
    if (c->opts.max_embeds_per_window <= 0) return 0;
    snprintf(sql, sizeof sql,
             "UPDATE fractal_vectorizer_rate SET used = 0, window_started_at = now() WHERE vectorizer_id = %" PRId64
             " AND (now()::TIMESTAMP - window_started_at) >= INTERVAL '%" PRId64 " seconds'", c->id, c->opts.window_secs);
    if (run(inst, sql, err)) return -1;
    snprintf(sql, sizeof sql, "UPDATE fractal_vectorizer_rate SET used = used + 1 WHERE vectorizer_id = %" PRId64 " AND used < %" PRId64,
             c->id, c->opts.max_embeds_per_window);
    int64_t updated = 0; bool found;
    if (first_i64(inst, sql, &updated, &found, err)) return -1;
    *ok = found && updated > 0;
    return 0;
}

/* 1 claimed, 0 lost the race, -1 error. */
static int claim_row(fsql_instance *inst, int64_t vid, const char *pk, char *err) {
    fsql_sb sb; fsql_sb_init(&sb);
    fsql_sb_printf(&sb, "UPDATE fractal_vectorizer_queue SET status = 'processing', started_at = now() WHERE vectorizer_id = %" PRId64 " AND pk_value = ", vid);
    put_lit(&sb, pk);
    fsql_sb_puts(&sb, " AND status = 'pending' RETURNING pk_value");
    fsql_qres r;
    int rc;
    if (fsql_nested_query(inst, fsql_sb_cstr(&sb), &r, err, ERRCAP)) {
        rc = strstr(err, "conflict") ? 0 : -1;
    } else {
        duckdb_data_chunk ch = fsql_qres_next_chunk(&r);
        rc = (ch && duckdb_data_chunk_get_size(ch) > 0) ? 1 : 0;
        if (ch) duckdb_destroy_data_chunk(&ch);
        fsql_qres_free(&r);
    }
    fsql_sb_free(&sb);
    return rc;
}

static int process_queue(fsql_instance *inst, int64_t batch, int64_t stale, int64_t *total, char *err) {
    fsql_sb sql; fsql_sb_init(&sql);
    vcfg *cfgs = NULL; size_t ncfg = 0, capcfg = 0;
    int rc = -1;
    char msg[ERRCAP];
    *total = 0;

    fsql_sb_printf(&sql, "UPDATE fractal_vectorizer_queue SET status = 'pending', started_at = NULL WHERE status = 'processing' "
                         "AND started_at < now()::TIMESTAMP - INTERVAL '%" PRId64 " seconds'", stale);
    if (run(inst, fsql_sb_cstr(&sql), err)) goto done;

    fsql_qres vr;
    if (fsql_nested_query(inst, "SELECT id, source_table, source_pk_col, text_col, embedding_col, options FROM fractal_vectorizers WHERE enabled = true",
                          &vr, err, ERRCAP)) goto done;
    for (duckdb_data_chunk ch = fsql_qres_next_chunk(&vr); ch; ch = fsql_qres_next_chunk(&vr)) {
        idx_t rows = duckdb_data_chunk_get_size(ch);
        if (rows == 0) { duckdb_destroy_data_chunk(&ch); break; }
        for (idx_t i = 0; i < rows; i++) {
            vcfg c; memset(&c, 0, sizeof c);
            c.id = cell_i64(ch, 0, i);
            char *st = cell_str(ch, 1, i), *pk = cell_str(ch, 2, i), *tx = cell_str(ch, 3, i), *em = cell_str(ch, 4, i), *op = cell_str(ch, 5, i);
            int bad = 0;
            if (!(c.q_source = sb_dup_quoted(quote_table, st, err))) bad = 1;
            else if (!(c.q_pk = sb_dup_quoted(quote_column, pk, err))) bad = 1;
            else if (!(c.q_text = sb_dup_quoted(quote_column, tx, err))) bad = 1;
            else if (!(c.q_emb = sb_dup_quoted(quote_column, em, err))) bad = 1;
            else if (parse_options(op, &c.opts, err)) bad = 1;
            free(st); free(pk); free(tx); free(em); free(op);
            if (!bad) {
                fsql_sb_clear(&sql);
                fsql_sb_printf(&sql, "INSERT INTO fractal_vectorizer_rate (vectorizer_id, window_started_at, used) VALUES (%" PRId64 ", now(), 0) "
                                     "ON CONFLICT (vectorizer_id) DO NOTHING", c.id);
                if (run(inst, fsql_sb_cstr(&sql), err)) bad = 1;
            }
            if (!bad && ncfg == capcfg) {
                size_t nc2 = capcfg ? capcfg * 2 : 8;
                vcfg *np = (vcfg *)realloc(cfgs, nc2 * sizeof *np);
                if (!np) { snprintf(err, ERRCAP, "fractalsql: out of memory"); bad = 1; } else { cfgs = np; capcfg = nc2; }
            }
            if (bad) { vcfg_free(&c); duckdb_destroy_data_chunk(&ch); fsql_qres_free(&vr); goto done; }
            cfgs[ncfg++] = c;
        }
        duckdb_destroy_data_chunk(&ch);
    }
    fsql_qres_free(&vr);

    for (size_t k = 0; k < ncfg; k++) {
        const vcfg *c = &cfgs[k];
        fsql_sb_clear(&sql);
        fsql_sb_printf(&sql, "INSERT INTO fractal_vectorizer_queue (vectorizer_id, pk_value) SELECT DISTINCT %" PRId64 ", CAST(s.%s AS VARCHAR) "
                             "FROM %s s WHERE s.%s IS NOT NULL AND s.%s IS NULL "
                             "AND NOT EXISTS (SELECT 1 FROM fractal_vectorizer_queue q WHERE q.vectorizer_id = %" PRId64 " AND q.pk_value = CAST(s.%s AS VARCHAR))",
                       c->id, c->q_pk, c->q_source, c->q_text, c->q_emb, c->id, c->q_pk);
        if (run(inst, fsql_sb_cstr(&sql), err)) goto done;
    }

    fsql_sb_clear(&sql);
    fsql_sb_printf(&sql, "SELECT q.vectorizer_id, q.pk_value FROM fractal_vectorizer_queue q JOIN fractal_vectorizers v ON v.id = q.vectorizer_id "
                         "WHERE q.status = 'pending' AND v.enabled = true ORDER BY q.enqueued_at, q.vectorizer_id LIMIT %" PRId64, batch);
    fsql_qres cr;
    if (fsql_nested_query(inst, fsql_sb_cstr(&sql), &cr, err, ERRCAP)) goto done;
    for (duckdb_data_chunk ch = fsql_qres_next_chunk(&cr); ch; ch = fsql_qres_next_chunk(&cr)) {
        idx_t rows = duckdb_data_chunk_get_size(ch);
        if (rows == 0) { duckdb_destroy_data_chunk(&ch); break; }
        for (idx_t i = 0; i < rows; i++) {
            int64_t vid = cell_i64(ch, 0, i);
            char *pk = cell_str(ch, 1, i);
            const vcfg *c = NULL;
            for (size_t k = 0; k < ncfg; k++) if (cfgs[k].id == vid) { c = &cfgs[k]; break; }
            if (!c) { free(pk); continue; }
            bool ok;
            int g = rate_gate(inst, c, &ok, err);
            if (g) { free(pk); duckdb_destroy_data_chunk(&ch); fsql_qres_free(&cr); goto done; }
            if (!ok) { free(pk); continue; }
            int cl = claim_row(inst, vid, pk, err);
            if (cl < 0) { free(pk); duckdb_destroy_data_chunk(&ch); fsql_qres_free(&cr); goto done; }
            if (cl == 0) { free(pk); continue; }

            fsql_sb_clear(&sql);
            fsql_sb_printf(&sql, "UPDATE %s SET %s = CASE WHEN strlen(CAST(%s AS VARCHAR)) > %d "
                                 "THEN error('fractal_vectorizer_process_queue: source text exceeds the 4 MiB embed limit') "
                                 "ELSE fractal_embed(%s) END WHERE CAST(%s AS VARCHAR) = ",
                           c->q_source, c->q_emb, c->q_text, FSQL_MAX_INPUT_BYTES, c->q_text, c->q_pk);
            put_lit(&sql, pk);
            if (!run(inst, fsql_sb_cstr(&sql), msg)) {
                fsql_sb_clear(&sql);
                fsql_sb_printf(&sql, "UPDATE fractal_vectorizer_queue SET status = 'done', error = NULL WHERE vectorizer_id = %" PRId64 " AND pk_value = ", vid);
                put_lit(&sql, pk);
            } else {
                fsql_sb_clear(&sql);
                fsql_sb_puts(&sql, "UPDATE fractal_vectorizer_queue SET status = 'failed', error = ");
                put_lit(&sql, msg);
                fsql_sb_printf(&sql, " WHERE vectorizer_id = %" PRId64 " AND pk_value = ", vid);
                put_lit(&sql, pk);
            }
            free(pk);
            if (run(inst, fsql_sb_cstr(&sql), err)) { duckdb_destroy_data_chunk(&ch); fsql_qres_free(&cr); goto done; }
            (*total)++;
        }
        duckdb_destroy_data_chunk(&ch);
    }
    fsql_qres_free(&cr);

    /* housekeeping is best effort */
    run(inst, "DELETE FROM fractal_vectorizer_queue WHERE (status = 'done' AND enqueued_at < now() - INTERVAL 1 HOUR) "
              "OR (status = 'failed' AND enqueued_at < now() - INTERVAL 1 DAY)", msg);
    rc = 0;
done:
    for (size_t k = 0; k < ncfg; k++) vcfg_free(&cfgs[k]);
    free(cfgs);
    fsql_sb_free(&sql);
    return rc;
}

static void process_queue_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    fsql_instance *inst = fsql_scalar_instance(info);
    idx_t n = duckdb_data_chunk_get_size(in), nc = duckdb_data_chunk_get_column_count(in);
    char err[ERRCAP];
    if (ensure_tables(inst, err)) { fail(info, err); return; }
    int64_t batch = 100, stale = 600;
    if (nc > 0 && fsql_valid(fsql_col_validity(in, 0), 0)) batch = ((const int32_t *)fsql_col_data(in, 0))[0];
    if (nc > 1 && fsql_valid(fsql_col_validity(in, 1), 0)) stale = ((const int32_t *)fsql_col_data(in, 1))[0];
    if (batch < 1 || batch > MAX_BATCH) { snprintf(err, sizeof err, "fractalsql: batch_size must be 1..%d", MAX_BATCH); fail(info, err); return; }
    if (stale <= 0) { fail(info, "fractalsql: stale_after must be a positive number of seconds"); return; }
    int64_t total;
    if (process_queue(inst, batch, stale, &total, err)) { fail(info, err); return; }
    int64_t *res = (int64_t *)duckdb_vector_get_data(out);
    for (idx_t i = 0; i < n; i++) res[i] = total;
}

/* ------------------------------------------------------------------ */
/* fractal_vectorizer_status()                                          */
/* ------------------------------------------------------------------ */

typedef struct { fsql_qres q; bool started; duckdb_data_chunk cur; idx_t pos; } status_state;

static void status_state_free(void *p) {
    status_state *s = (status_state *)p;
    if (s->cur) duckdb_destroy_data_chunk(&s->cur);
    if (s->started) fsql_qres_free(&s->q);
    free(s);
}

static void status_bind(duckdb_bind_info info) {
    char err[ERRCAP];
    if (ensure_tables(fsql_bind_instance(info), err)) { duckdb_bind_set_error(info, err); return; }
    duckdb_logical_type bi = duckdb_create_logical_type(DUCKDB_TYPE_BIGINT), vc = duckdb_create_logical_type(DUCKDB_TYPE_VARCHAR),
                        bo = duckdb_create_logical_type(DUCKDB_TYPE_BOOLEAN);
    duckdb_bind_add_result_column(info, "id", bi);
    duckdb_bind_add_result_column(info, "source_table", vc);
    duckdb_bind_add_result_column(info, "enabled", bo);
    duckdb_bind_add_result_column(info, "pending", bi);
    duckdb_bind_add_result_column(info, "processing", bi);
    duckdb_bind_add_result_column(info, "done", bi);
    duckdb_bind_add_result_column(info, "failed", bi);
    duckdb_destroy_logical_type(&bi); duckdb_destroy_logical_type(&vc); duckdb_destroy_logical_type(&bo);
}

static void status_init(duckdb_init_info info) {
    status_state *s = (status_state *)calloc(1, sizeof *s);
    if (!s) { duckdb_init_set_error(info, "fractalsql: out of memory"); return; }
    duckdb_init_set_init_data(info, s, status_state_free);
}

static void status_fn(duckdb_function_info info, duckdb_data_chunk out) {
    status_state *s = (status_state *)duckdb_function_get_init_data(info);
    char err[ERRCAP];
    if (!s->started) {
        if (fsql_nested_query(fsql_table_instance(info), 
            "SELECT v.id, v.source_table, v.enabled, "
            "count(*) FILTER (WHERE q.status = 'pending'), count(*) FILTER (WHERE q.status = 'processing'), "
            "count(*) FILTER (WHERE q.status = 'done'), count(*) FILTER (WHERE q.status = 'failed') "
            "FROM fractal_vectorizers v LEFT JOIN fractal_vectorizer_queue q ON q.vectorizer_id = v.id "
            "GROUP BY v.id, v.source_table, v.enabled ORDER BY v.id", &s->q, err, sizeof err)) {
            duckdb_function_set_error(info, err); duckdb_data_chunk_set_size(out, 0); return;
        }
        s->started = true;
    }
    idx_t cap = duckdb_vector_size(), k = 0;
    int64_t *c[7]; bool *en = (bool *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(out, 2));
    c[0] = (int64_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(out, 0));
    for (int j = 3; j < 7; j++) c[j] = (int64_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(out, j));
    duckdb_vector sv = duckdb_data_chunk_get_vector(out, 1);
    while (k < cap) {
        if (!s->cur) { s->cur = fsql_qres_next_chunk(&s->q); s->pos = 0; if (!s->cur) break; }
        idx_t rows = duckdb_data_chunk_get_size(s->cur);
        if (s->pos >= rows) { duckdb_destroy_data_chunk(&s->cur); s->cur = NULL; continue; }
        idx_t i = s->pos++;
        c[0][k] = cell_i64(s->cur, 0, i);
        char *t = cell_str(s->cur, 1, i);
        if (!t) { duckdb_function_set_error(info, "fractalsql: out of memory"); duckdb_data_chunk_set_size(out, 0); return; }
        fsql_set_str(sv, k, t, strlen(t));
        free(t);
        en[k] = ((const bool *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(s->cur, 2)))[i];
        for (int j = 3; j < 7; j++) c[j][k] = cell_i64(s->cur, (idx_t)j, i);
        k++;
    }
    duckdb_data_chunk_set_size(out, k);
}

/* ------------------------------------------------------------------ */
/* Registration                                                         */
/* ------------------------------------------------------------------ */

#define V FSQL_T_VARCHAR
static const fsql_scalar_def kVecDefs[] = {
    { "fractal_embed", 1, { V }, FSQL_T_LIST_DOUBLE, embed_fn, NULL, 0 },
    { "fractal_vectorizer_create", 3, { V, V, V },          FSQL_T_BIGINT, create_fn, NULL, FSQL_FN_VOLATILE },
    { "fractal_vectorizer_create", 4, { V, V, V, V },       FSQL_T_BIGINT, create_fn, NULL, FSQL_FN_VOLATILE },
    { "fractal_vectorizer_create", 5, { V, V, V, V, V },    FSQL_T_BIGINT, create_fn, NULL, FSQL_FN_VOLATILE },
    { "fractal_vectorizer_drop",   1, { FSQL_T_BIGINT }, FSQL_T_BOOLEAN, drop_fn,   NULL, FSQL_FN_VOLATILE },
    { "fractal_vectorizer_pause",  1, { FSQL_T_BIGINT }, FSQL_T_BOOLEAN, pause_fn,  NULL, FSQL_FN_VOLATILE },
    { "fractal_vectorizer_resume", 1, { FSQL_T_BIGINT }, FSQL_T_BOOLEAN, resume_fn, NULL, FSQL_FN_VOLATILE },
    { "fractal_vectorizer_process_queue", 0, { 0 },                              FSQL_T_BIGINT, process_queue_fn, NULL, FSQL_FN_VOLATILE },
    { "fractal_vectorizer_process_queue", 1, { FSQL_T_INTEGER },                 FSQL_T_BIGINT, process_queue_fn, NULL, FSQL_FN_VOLATILE },
    { "fractal_vectorizer_process_queue", 2, { FSQL_T_INTEGER, FSQL_T_INTEGER }, FSQL_T_BIGINT, process_queue_fn, NULL, FSQL_FN_VOLATILE },
};
static const fsql_table_def kVecTables[] = {
    { "fractal_vectorizer_status", 0, { 0 }, status_bind, status_init, status_fn },
};

bool fsql_vectorizer_register(duckdb_connection con, const char **err) {
    return fsql_register_scalars(con, kVecDefs, (int)(sizeof kVecDefs / sizeof kVecDefs[0]), err) &&
           fsql_register_tables(con, kVecTables, (int)(sizeof kVecTables / sizeof kVecTables[0]), err);
}
