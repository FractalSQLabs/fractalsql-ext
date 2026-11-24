/* src/fsql_ledger.c
 *
 * The ledger family: the per-connection hash-chained ledger store (this TU is its storage VFS),
 * the QTL Truth/Shadow ledger controls and the CISO decision-audit chain. (The diversify /
 * feedback functions that share the per-connection core context live in fsql_sovereign.c.)
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * SQL surface (scalar functions have no void return type, so the actions return BOOLEAN true; JSON
 * results are VARCHAR carrying JSON text -- these are small, fixed-shape documents):
 *
 *   fractal_ledger_flush() / _load() / _compact() / _reset_soft() / _reset_hard() -> BOOLEAN
 *   fractal_ledger_truth_count() / _shadow_count() -> BIGINT
 *   fractal_ledger_verify([kind INTEGER]) -> VARCHAR (json)
 *   fractal_lock_destructive() -> VARCHAR ('locked')
 *   fractal_audit_log(entry_type VARCHAR, payload VARCHAR [, actor VARCHAR]) -> BOOLEAN
 *   fractal_audit_unpack(blob BLOB) -> VARCHAR (json)
 *
 * The ledger here is in-memory and per connection by design: it has no cross-process durability.
 * Writes go through the storage VFS into hash-chained rows (each row's hash covers the previous
 * row's hash, so a deleted, reordered or edited row is detected by fractal_ledger_verify).
 *
 * The enterprise actions (flush/load/compact/reset/count/audit) resolve their entry points from
 * FRACTALSQL_ENTERPRISE_LIB (fsql_enterprise.c) and report the dormant-tier error without it.
 *
 * Destructive actions refuse once fractal_lock_destructive() has run: on the connection it ran on,
 * AND on every other connection of the same database (the latch is per database, so SQL a
 * reasoning agent generated on a fresh connection cannot undo it). Nothing clears it.
 */

#include <ctype.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if !defined(_WIN32)
#  include <syslog.h>
#endif

#include "fsql_duckdb_internal.h"
#include "fsql_vendored_begin.h"
#include "fsql_hmac.h"
#include "fsql_audit_redact.h"
#include "fsql_vendored_end.h"

#include "fsql_ledger_store.h"

/* --- the storage VFS the core's ledger writes through --------------- */

static int vfs_write(fsql_storage_user_ctx user, int kind, const void *payload, size_t len) {
    if (len > 0x7fffffffu) {
        fprintf(stderr, "fractalsql: ledger payload too large to persist (%zu bytes)\n", len);
        return -1;
    }
    if (ledger_append((ledger_store *)user, kind, payload, len) != 0) {
        fprintf(stderr, "fractalsql: ledger is full (FSQL_DUCKDB_LEDGER_MAX_BYTES); append refused\n");
        return -1;
    }
    return 0;
}

static int vfs_read(fsql_storage_user_ctx user, int kind, const void **payload_out, size_t *len_out) {
    chain *c = store_find((ledger_store *)user, kind);
    if (!c || c->n == 0) return FSQL_ESTORAGE_UNAVAILABLE;
    chain_entry *latest = &c->e[c->n - 1];
    *payload_out = latest->blob;
    *len_out = latest->len;
    return FSQL_OK;
}

static int vfs_seal(fsql_storage_user_ctx user) { (void)user; return 0; }   /* in-memory: nothing to fsync */

/* --- per-connection state ------------------------------------------- */

static void conn_init(void *p) {
    FsqlConn *c = (FsqlConn *)p;
    fsql_mu_init(&c->mu);
    ledger_store *s = (ledger_store *)calloc(1, sizeof *s);
    c->store = s;
    c->vfs.user_ctx = s;
    c->vfs.write_entry = vfs_write;
    c->vfs.read_entry = vfs_read;
    c->vfs.seal_ledger = vfs_seal;
    /* fsql_new_sovereign copies the VFS struct by value, so it is complete before this call */
    c->ctx = s ? fsql_new_sovereign(&c->vfs, /*reasoning*/ NULL) : NULL;
}

static void conn_destroy(void *p) {
    FsqlConn *c = (FsqlConn *)p;
    /* fsql_free may re-enter seal_ledger, so the store must outlive the context */
    if (c->ctx) fsql_free(c->ctx);
    store_free((ledger_store *)c->store);
    c->ctx = NULL; c->store = NULL;
}

FsqlConn *fsql_conn_get(fsql_instance *inst, idx_t conn_id) {
    return (FsqlConn *)fsql_conn_state(inst, conn_id, sizeof(FsqlConn), conn_init, conn_destroy);
}

void fsql_ledger_fail(duckdb_function_info info, const char *fn_name, const char *fmt, ...) {
    char what[900];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(what, sizeof what, fmt, ap);
    va_end(ap);
    fsql_fn_error(info, "fractalsql: %s: %s", fn_name, what);
}

int fsql_conn_sync_retention(FsqlConn *c, char *err, size_t err_cap) {
    const char *e = getenv("FRACTALSQL_LEDGER_RETENTION");
    const int want = (e && strcmp(e, "exact") == 0) ? 1 : 0;
    if (want == c->retention_applied) return 0;
    const FsqlEnterpriseApi *api = fsql_enterprise_ensure();
    if (!api || !api->ledger_set_retention) {
        if (err) snprintf(err, err_cap,
            "ledger_retention 'exact' needs a FractalSQL Enterprise core library that exports fsql_ledger_set_retention "
            "(set FRACTALSQL_ENTERPRISE_LIB to a current library, or set ledger_retention to fade)");
        return -1;
    }
    fsql_mu_lock(&c->mu);
    int rc = api->ledger_set_retention(c->ctx, want);
    fsql_mu_unlock(&c->mu);
    if (rc != FSQL_OK) {
        if (err) snprintf(err, err_cap, "the enterprise library refused the ledger retention mode (rc=%d)", rc);
        return -1;
    }
    c->retention_applied = want;
    return 0;
}

/* The connection's state, or fails the call. */
static FsqlConn *need_conn(duckdb_function_info info, const char *fn) {
    FsqlConn *c = fsql_conn_get(fsql_scalar_instance(info), fsql_exec_conn_id(info));
    if (!c || !c->ctx) { fsql_ledger_fail(info, fn, "fsql_new_sovereign failed (OOM?)"); return NULL; }
    char rerr[400];
    if (fsql_conn_sync_retention(c, rerr, sizeof rerr) != 0) { fsql_ledger_fail(info, fn, "%s", rerr); return NULL; }
    return c;
}

/* rc != OK -> "<what> rc=N: <core error>" through the standard wrapper. 0 ok, -1 failed. */
static int core_rc(duckdb_function_info info, FsqlConn *c, const char *fn, int rc, const char *what) {
    if (rc == FSQL_OK) return 0;
    const char *e = fsql_last_error(c->ctx);
    fsql_ledger_fail(info, fn, "%s rc=%d: %s", what, rc, (e && *e) ? e : "(no detail)");
    return -1;
}

static int destructive_check(duckdb_function_info info, const FsqlConn *c) {
    if (c->destructive_locked || fsql_instance_latched(fsql_scalar_instance(info))) {
        fsql_fn_error(info, "fractalsql: destructive ledger operations are locked on this connection "
                            "(fractal_lock_destructive() was called; it cannot be undone)");
        return -1;
    }
    return 0;
}

static const FsqlEnterpriseApi *need_enterprise(duckdb_function_info info, const char *fn) {
    const FsqlEnterpriseApi *ent = fsql_enterprise_ensure();
    if (!ent) {
        char m[600];
        fsql_enterprise_not_loaded_msg(fn, m, sizeof m);
        fsql_fn_error(info, "%s", m);
    }
    return ent;
}

/* ------------------------------------------------------------------ */
/* Ledger actions (enterprise-gated)                                    */
/* ------------------------------------------------------------------ */

/* The five zero-argument destructive/maintenance actions share one shape. Zero-argument functions run
 * once per chunk and answer every row alike. */
typedef int (*ent_ledger_fn)(fsql_ctx *);

static void ledger_action(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out, const char *fn,
                          size_t ent_off, const char *core_name, bool destructive, bool tolerate_unavailable) {
    FsqlConn *c = need_conn(info, fn);
    if (!c) return;
    if (destructive && destructive_check(info, c)) return;
    const FsqlEnterpriseApi *ent = need_enterprise(info, fn);
    if (!ent) return;
    ent_ledger_fn f = *(ent_ledger_fn const *)((const char *)ent + ent_off);
    fsql_mu_lock(&c->mu);
    int rc = f(c->ctx);
    int bad = 0;
    if (rc != FSQL_OK && !(tolerate_unavailable && rc == FSQL_ESTORAGE_UNAVAILABLE)) bad = core_rc(info, c, fn, rc, core_name);
    fsql_mu_unlock(&c->mu);
    if (bad) return;
    bool *res = (bool *)duckdb_vector_get_data(out);
    for (idx_t i = 0, n = duckdb_data_chunk_get_size(in); i < n; i++) res[i] = true;
}

#define LEDGER_ACTION(NAME, FN, FIELD, CORE, DESTRUCTIVE, TOLERATE) \
    static void NAME(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) { \
        ledger_action(info, in, out, FN, offsetof(FsqlEnterpriseApi, FIELD), CORE, DESTRUCTIVE, TOLERATE); }

/* load overwrites live ledger state, so it is destructive; a store with nothing in it yet is not an error */
LEDGER_ACTION(ledger_flush_fn,      "fractal_ledger_flush",      ledger_flush,      "fsql_ledger_flush",      true,  false)
LEDGER_ACTION(ledger_load_fn,       "fractal_ledger_load",       ledger_load,       "fsql_ledger_load",       true,  true)
LEDGER_ACTION(ledger_compact_fn,    "fractal_ledger_compact",    ledger_compact,    "fsql_ledger_compact",    true,  false)
LEDGER_ACTION(ledger_reset_soft_fn, "fractal_ledger_reset_soft", ledger_reset_soft, "fsql_ledger_reset_soft", true,  false)
LEDGER_ACTION(ledger_reset_hard_fn, "fractal_ledger_reset_hard", ledger_reset_hard, "fsql_ledger_reset_hard", true,  false)

typedef int (*ent_count_fn)(const fsql_ctx *, size_t *);

static void ledger_count(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out, const char *fn,
                         size_t ent_off, const char *core_name) {
    FsqlConn *c = need_conn(info, fn);
    if (!c) return;
    const FsqlEnterpriseApi *ent = need_enterprise(info, fn);
    if (!ent) return;
    ent_count_fn f = *(ent_count_fn const *)((const char *)ent + ent_off);
    size_t cnt = 0;
    fsql_mu_lock(&c->mu);
    int rc = f(c->ctx, &cnt);
    int bad = core_rc(info, c, fn, rc, core_name);
    fsql_mu_unlock(&c->mu);
    if (bad) return;
    int64_t *res = (int64_t *)duckdb_vector_get_data(out);
    for (idx_t i = 0, n = duckdb_data_chunk_get_size(in); i < n; i++) res[i] = (int64_t)cnt;
}

static void ledger_truth_count_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    ledger_count(info, in, out, "fractal_ledger_truth_count", offsetof(FsqlEnterpriseApi, ledger_truth_count), "fsql_ledger_truth_count");
}
static void ledger_shadow_count_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    ledger_count(info, in, out, "fractal_ledger_shadow_count", offsetof(FsqlEnterpriseApi, ledger_shadow_count), "fsql_ledger_shadow_count");
}

/* fractal_lock_destructive() -> 'locked'. One-way: once set, the destructive ledger functions (flush, load,
 * compact, reset_soft, reset_hard, audit_log) refuse on this connection and on every other connection of the
 * database; nothing clears it. The MCP server sets it on its own connections when FSQL_MCP_READ_ONLY=true. */
static void lock_destructive_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    FsqlConn *c = fsql_conn_get(fsql_scalar_instance(info), fsql_exec_conn_id(info));
    if (!c) { fsql_fn_error(info, "fractalsql: out of memory"); return; }
    c->destructive_locked = 1;
    fsql_instance_latch(fsql_scalar_instance(info));
    for (idx_t i = 0, n = duckdb_data_chunk_get_size(in); i < n; i++) fsql_set_str(out, i, "locked", 6);
}

/* ------------------------------------------------------------------ */
/* fractal_ledger_verify([kind])                                        */
/* ------------------------------------------------------------------ */

static void ledger_verify_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    FsqlConn *c = need_conn(info, "fractal_ledger_verify");
    if (!c) return;
    idx_t n = duckdb_data_chunk_get_size(in);
    idx_t ncols = duckdb_data_chunk_get_column_count(in);
    const int32_t *kd = ncols > 0 ? (const int32_t *)fsql_col_data(in, 0) : NULL;
    const uint64_t *kv = ncols > 0 ? fsql_col_validity(in, 0) : NULL;
    for (idx_t i = 0; i < n; i++) {
        int kind = (kd && fsql_valid(kv, i)) ? kd[i] : 1;
        char json[256];
        fsql_mu_lock(&c->mu);
        ledger_chain_verdict(store_find((ledger_store *)c->store, kind), json, sizeof json);
        fsql_mu_unlock(&c->mu);
        fsql_set_str(out, i, json, strlen(json));
    }
}

/* ------------------------------------------------------------------ */
/* fractal_audit_log(entry_type, payload [, actor])                     */
/* ------------------------------------------------------------------ */

#define AUDIT_LOG_KIND 2

/* A strict JSON well-formedness check (RFC 8259 grammar, depth <= 64) -- the payload is stored verbatim
 * inside a record, so a malformed one would corrupt the whole record. */
typedef struct { const char *p, *end; int depth; } jcheck;

static void j_ws(jcheck *c) { while (c->p < c->end && (*c->p == ' ' || *c->p == '\t' || *c->p == '\n' || *c->p == '\r')) c->p++; }
static bool j_lit(jcheck *c, const char *w) {
    size_t n = strlen(w);
    if ((size_t)(c->end - c->p) < n || memcmp(c->p, w, n) != 0) return false;
    c->p += n; return true;
}
static bool j_str(jcheck *c) {
    if (c->p >= c->end || *c->p != '"') return false;
    c->p++;
    while (c->p < c->end) {
        unsigned char ch = (unsigned char)*c->p++;
        if (ch == '"') return true;
        if (ch < 0x20) return false;
        if (ch == '\\') {
            if (c->p >= c->end) return false;
            char e = *c->p++;
            if (e == 'u') {
                for (int i = 0; i < 4; i++) { if (c->p >= c->end || !isxdigit((unsigned char)*c->p)) return false; c->p++; }
            } else if (!strchr("\"\\/bfnrt", e)) return false;
        }
    }
    return false;
}
static bool j_num(jcheck *c) {
    const char *q = c->p;
    if (q < c->end && *q == '-') q++;
    if (q >= c->end) return false;
    if (*q == '0') q++;
    else if (*q >= '1' && *q <= '9') { while (q < c->end && isdigit((unsigned char)*q)) q++; }
    else return false;
    if (q < c->end && *q == '.') {
        q++;
        if (q >= c->end || !isdigit((unsigned char)*q)) return false;
        while (q < c->end && isdigit((unsigned char)*q)) q++;
    }
    if (q < c->end && (*q == 'e' || *q == 'E')) {
        q++;
        if (q < c->end && (*q == '+' || *q == '-')) q++;
        if (q >= c->end || !isdigit((unsigned char)*q)) return false;
        while (q < c->end && isdigit((unsigned char)*q)) q++;
    }
    c->p = q; return true;
}
static bool j_value(jcheck *c) {
    if (++c->depth > 64) return false;
    j_ws(c);
    if (c->p >= c->end) return false;
    bool ok = false;
    if (*c->p == '{') {
        c->p++; j_ws(c);
        if (c->p < c->end && *c->p == '}') { c->p++; ok = true; }
        else {
            for (;;) {
                j_ws(c); if (!j_str(c)) break;
                j_ws(c); if (c->p >= c->end || *c->p != ':') break; c->p++;
                if (!j_value(c)) break;
                j_ws(c); if (c->p >= c->end) break;
                if (*c->p == ',') { c->p++; continue; }
                if (*c->p == '}') { c->p++; ok = true; }
                break;
            }
        }
    } else if (*c->p == '[') {
        c->p++; j_ws(c);
        if (c->p < c->end && *c->p == ']') { c->p++; ok = true; }
        else {
            for (;;) {
                if (!j_value(c)) break;
                j_ws(c); if (c->p >= c->end) break;
                if (*c->p == ',') { c->p++; continue; }
                if (*c->p == ']') { c->p++; ok = true; }
                break;
            }
        }
    } else if (*c->p == '"') ok = j_str(c);
    else if (*c->p == 't') ok = j_lit(c, "true");
    else if (*c->p == 'f') ok = j_lit(c, "false");
    else if (*c->p == 'n') ok = j_lit(c, "null");
    else ok = j_num(c);
    c->depth--;
    return ok;
}
static bool payload_well_formed(const char *s, size_t n) {
    jcheck c = { s, s + n, 0 };
    if (!j_value(&c)) return false;
    j_ws(&c);
    return c.p == c.end;
}

/* The payload with an "_actor" member appended: inside an object it is added as the last member; a non-object
 * is wrapped as {"value": <it>, "_actor": ...}. */
static void entry_with_actor(fsql_sb *o, const char *pay, size_t n, const char *actor_block) {
    size_t b = 0, e = n;
    while (b < e && isspace((unsigned char)pay[b])) b++;
    while (e > b && isspace((unsigned char)pay[e - 1])) e--;
    if (b < e && pay[b] == '{' && pay[e - 1] == '}') {
        size_t q = b + 1;
        while (q < e - 1 && isspace((unsigned char)pay[q])) q++;
        if (q == e - 1) { fsql_sb_printf(o, "{\"_actor\":%s}", actor_block); return; }
        fsql_sb_putn(o, pay + b, (e - 1) - b);
        fsql_sb_printf(o, ",\"_actor\":%s}", actor_block);
        return;
    }
    fsql_sb_puts(o, "{\"value\":");
    fsql_sb_putn(o, pay + b, e - b);
    fsql_sb_printf(o, ",\"_actor\":%s}", actor_block);
}

static void audit_log_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    FsqlConn *c = need_conn(info, "fractal_audit_log");
    if (!c) return;
    if (destructive_check(info, c)) return;
    if (!need_enterprise(info, "fractal_audit_log")) return;
    idx_t n = duckdb_data_chunk_get_size(in);
    idx_t ncols = duckdb_data_chunk_get_column_count(in);
    bool *res = (bool *)duckdb_vector_get_data(out);
    const duckdb_string_t *td = (const duckdb_string_t *)fsql_col_data(in, 0), *pd = (const duckdb_string_t *)fsql_col_data(in, 1);
    const uint64_t *tv = fsql_col_validity(in, 0), *pv = fsql_col_validity(in, 1);
    const duckdb_string_t *ad = ncols > 2 ? (const duckdb_string_t *)fsql_col_data(in, 2) : NULL;
    const uint64_t *av = ncols > 2 ? fsql_col_validity(in, 2) : NULL;
    for (idx_t i = 0; i < n; i++) {
        if (!fsql_valid(tv, i) || !fsql_valid(pv, i)) { fsql_set_null(out, i); continue; }
        size_t tl, pl, al = 0;
        const char *type = fsql_str_data(&td[i], &tl), *pay = fsql_str_data(&pd[i], &pl), *actor = "";
        if (ad && fsql_valid(av, i)) actor = fsql_str_data(&ad[i], &al);
        if (!payload_well_formed(pay, pl)) { fsql_fn_error(info, "fractalsql: fractal_audit_log: payload must be well-formed JSON"); return; }
        /* the chain's actor attribution cannot be forged from inside the payload */
        for (size_t k = 0; pl >= 8 && k + 8 <= pl; k++)
            if (memcmp(pay + k, "\"_actor\"", 8) == 0) { fsql_fn_error(info, "fractalsql: fractal_audit_log: payload may not contain the reserved key \"_actor\""); return; }

        fsql_sb actor_block, esc_actor, esc_type, entry, record;
        fsql_sb_init(&actor_block); fsql_sb_init(&esc_actor); fsql_sb_init(&esc_type); fsql_sb_init(&entry); fsql_sb_init(&record);
        fsql_sb_put_json_escaped(&esc_actor, actor, al);
        fsql_sb_put_json_escaped(&esc_type, type, tl);
        fsql_sb_printf(&actor_block, "{\"client\":\"%s\",\"attested\":false}", fsql_sb_cstr(&esc_actor));
        entry_with_actor(&entry, pay, pl, fsql_sb_cstr(&actor_block));
        fsql_sb_printf(&record, "{\"type\":\"%s\",\"entry\":%s}", fsql_sb_cstr(&esc_type), fsql_sb_cstr(&entry));
        int bad = 0;
        if (!fsql_sb_ok(&record)) { fsql_ledger_fail(info, "fractal_audit_log", "out of memory"); bad = 1; }
        if (!bad && fsql_audit_redact_mode() != FSQL_AUDIT_REDACT_NONE) {
            char *redacted = fsql_audit_redact_json(fsql_sb_cstr(&record));
            if (redacted) { fsql_sb_clear(&record); fsql_sb_puts(&record, redacted); free(redacted); }
        }
        if (!bad) {
            fsql_mu_lock(&c->mu);
            int rc = ledger_append((ledger_store *)c->store, AUDIT_LOG_KIND, record.p ? record.p : "", record.len);
            fsql_mu_unlock(&c->mu);
            if (rc) {
                fsql_fn_error(info, "fractalsql: fractal_audit_log: fractalsql: fractal_audit_log: the ledger is full (FSQL_DUCKDB_LEDGER_MAX_BYTES)");
                bad = 1;
            }
        }
        fsql_sb_free(&actor_block); fsql_sb_free(&esc_actor); fsql_sb_free(&esc_type); fsql_sb_free(&entry); fsql_sb_free(&record);
        if (bad) return;
        res[i] = true;
    }
}

/* fractal_audit_unpack(blob) -> json */
#define AUDIT_START_CAP 4096
#define AUDIT_MAX_CAP   ((size_t)256 * 1024 * 1024)

static void audit_unpack_fn(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    const FsqlEnterpriseApi *ent = need_enterprise(info, "fractal_audit_unpack");
    if (!ent) return;
    idx_t n = duckdb_data_chunk_get_size(in);
    const duckdb_string_t *bd = (const duckdb_string_t *)fsql_col_data(in, 0);
    const uint64_t *bv = fsql_col_validity(in, 0);
    for (idx_t i = 0; i < n; i++) {
        if (!fsql_valid(bv, i)) { fsql_set_null(out, i); continue; }
        size_t blen; const char *blob = fsql_str_data(&bd[i], &blen);
        char *latest_copy = NULL;
        size_t ws = 0;
        while (ws < blen && (blob[ws] == ' ' || blob[ws] == '\t' || blob[ws] == '\r' || blob[ws] == '\n')) ws++;
        if (ws == blen) {   /* '' means the last blob the ledger sealed on this connection */
            FsqlConn *c = need_conn(info, "fractal_audit_unpack");
            if (!c) return;
            fsql_mu_lock(&c->mu);
            chain *ch = store_find((ledger_store *)c->store, 1);
            if (ch && ch->n > 0) {
                chain_entry *le = &ch->e[ch->n - 1];
                latest_copy = (char *)malloc(le->len ? le->len : 1);
                if (latest_copy) { memcpy(latest_copy, le->blob, le->len); blen = le->len; }
            }
            int had = ch && ch->n > 0;
            fsql_mu_unlock(&c->mu);
            if (!had) {
                fsql_ledger_fail(info, "fractal_audit_unpack", "fractalsql: the chain holds no sealed blob to decode yet; fractal_ledger_flush seals one");
                return;
            }
            if (!latest_copy) { fsql_ledger_fail(info, "fractal_audit_unpack", "out of memory"); return; }
            blob = latest_copy;
        }
        size_t cap = AUDIT_START_CAP;
        char *buf = NULL;
        int done = 0;
        while (!done) {
            char *nb = (char *)realloc(buf, cap);
            if (!nb) { free(buf); free(latest_copy); fsql_ledger_fail(info, "fractal_audit_unpack", "out of memory"); return; }
            buf = nb;
            size_t cap_io = cap;
            int rc = ent->audit_unpack(blob, blen, buf, &cap_io);
            if (rc == FSQL_OK) {
                if (cap_io > cap) {
                    free(buf); free(latest_copy);
                    fsql_ledger_fail(info, "fractal_audit_unpack", "fractalsql: fsql_audit_unpack reported an out-of-range length -- refusing the result");
                    return;
                }
                fsql_set_str(out, i, buf, cap_io);
                done = 1;
            } else if (rc == FSQL_ETRUNCATED) {
                size_t next = cap_io > cap ? cap_io : cap * 2;
                if (next <= cap || next > AUDIT_MAX_CAP) {
                    free(buf); free(latest_copy);
                    fsql_ledger_fail(info, "fractal_audit_unpack", "fractalsql: fsql_audit_unpack failed (rc=%d, out of memory)", FSQL_ERR_OOM);
                    return;
                }
                cap = next;
            } else {
                free(buf); free(latest_copy);
                fsql_ledger_fail(info, "fractal_audit_unpack", "fsql_audit_unpack rc=%d", rc);
                return;
            }
        }
        free(buf); free(latest_copy);
    }
}

/* ------------------------------------------------------------------ */
/* Registration                                                         */
/* ------------------------------------------------------------------ */

#define V  FSQL_FN_VOLATILE
static const fsql_scalar_def kLedgerDefs[] = {
    { "fractal_ledger_flush",       0, { 0 }, FSQL_T_BOOLEAN, ledger_flush_fn,       fsql_bind_capture_conn, V },
    { "fractal_ledger_load",        0, { 0 }, FSQL_T_BOOLEAN, ledger_load_fn,        fsql_bind_capture_conn, V },
    { "fractal_ledger_compact",     0, { 0 }, FSQL_T_BOOLEAN, ledger_compact_fn,     fsql_bind_capture_conn, V },
    { "fractal_ledger_reset_soft",  0, { 0 }, FSQL_T_BOOLEAN, ledger_reset_soft_fn,  fsql_bind_capture_conn, V },
    { "fractal_ledger_reset_hard",  0, { 0 }, FSQL_T_BOOLEAN, ledger_reset_hard_fn,  fsql_bind_capture_conn, V },
    { "fractal_lock_destructive",   0, { 0 }, FSQL_T_VARCHAR, lock_destructive_fn,   fsql_bind_capture_conn, V },
    { "fractal_ledger_truth_count", 0, { 0 }, FSQL_T_BIGINT,  ledger_truth_count_fn, fsql_bind_capture_conn, 0 },
    { "fractal_ledger_shadow_count",0, { 0 }, FSQL_T_BIGINT,  ledger_shadow_count_fn,fsql_bind_capture_conn, 0 },

    { "fractal_ledger_verify",      0, { 0 },               FSQL_T_VARCHAR, ledger_verify_fn, fsql_bind_capture_conn, 0 },
    { "fractal_ledger_verify",      1, { FSQL_T_INTEGER },  FSQL_T_VARCHAR, ledger_verify_fn, fsql_bind_capture_conn, 0 },

    { "fractal_audit_log",          2, { FSQL_T_VARCHAR, FSQL_T_VARCHAR },                 FSQL_T_BOOLEAN, audit_log_fn, fsql_bind_capture_conn, V },
    { "fractal_audit_log",          3, { FSQL_T_VARCHAR, FSQL_T_VARCHAR, FSQL_T_VARCHAR }, FSQL_T_BOOLEAN, audit_log_fn, fsql_bind_capture_conn, V },

    { "fractal_audit_unpack",       1, { FSQL_T_BLOB }, FSQL_T_VARCHAR, audit_unpack_fn, fsql_bind_capture_conn, 0 },
};
#undef V

bool fsql_ledger_register(duckdb_connection con, const char **err) {
    return fsql_register_scalars(con, kLedgerDefs, (int)(sizeof kLedgerDefs / sizeof kLedgerDefs[0]), err);
}
