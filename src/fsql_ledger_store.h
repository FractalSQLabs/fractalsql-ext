/* src/fsql_ledger_store.h -- the in-memory hash-chained ledger store and its verifier, as plain C with no DuckDB types, so that
 * the store can be unit-tested (test/ledger_unit.c builds chains, tampers with them and checks the verdicts) and used by
 * fsql_ledger.c unchanged. Header-only: every function is static.
 *
 * One chain per kind; each row carries its sequence number, the hash of the previous row and its own hash
 * SHA-256(prev_hash || payload), so an edited, deleted, reordered or re-linked row is detected by ledger_chain_verdict().
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
#ifndef FSQL_LEDGER_STORE_H
#define FSQL_LEDGER_STORE_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if !defined(_WIN32)
#  include <syslog.h>
#endif

#include "fsql_port.h"
#include "fsql_vendored_begin.h"
#include "fsql_hmac.h"
#include "fsql_vendored_end.h"

/* ------------------------------------------------------------------ */
/* The ledger store: hash-chained rows, one chain per kind              */
/* ------------------------------------------------------------------ */

typedef struct {
    uint8_t *blob;
    size_t   len;
    uint8_t  hash[32];         /* this row's entry hash (SHA-256)                              */
    uint8_t  prev_hash[32];    /* the previous row's entry hash (all zero for the first)       */
    uint64_t id;               /* the row's sequence number within its chain                   */
} chain_entry;

typedef struct {
    int          kind;
    chain_entry *e;
    size_t       n, cap;
    uint64_t     next_id;
} chain;

typedef struct {
    chain  *chains;
    size_t  nchains, cap;
    size_t  total_bytes;
} ledger_store;

/* Hard ceiling on the in-memory ledger, so a runaway writer cannot exhaust memory. Default 256 MiB; set
 * FSQL_DUCKDB_LEDGER_MAX_BYTES, which the config key ledger_max_bytes sets (0 = unlimited). Read on every append, so the key takes
 * effect at once. */
static size_t ledger_max_bytes(void) {
    const char *e = getenv("FSQL_DUCKDB_LEDGER_MAX_BYTES");
    size_t v = (size_t)256 * 1024 * 1024;
    if (e && *e) {
        char *end = NULL;
        unsigned long long x = strtoull(e, &end, 10);
        if (end && *end == '\0') v = (size_t)x;
    }
    return v;
}

/* Optional publication of every ledger head, so a tampered or truncated chain can be compared against an
 * outside record: FSQL_LEDGER_ANCHOR_LOG=stderr|syslog. Off by default. Read once. */
#define ANCHOR_OFF    0
#define ANCHOR_STDERR 1
#define ANCHOR_SYSLOG 2
static int anchor_mode(void) {
    static int init, mode;
    if (!init) {
        const char *e = getenv("FSQL_LEDGER_ANCHOR_LOG");
        mode = ANCHOR_OFF;
        if (e && *e) {
            if (fsql_strcasecmp(e, "stderr") == 0) mode = ANCHOR_STDERR;
            else if (fsql_strcasecmp(e, "syslog") == 0) mode = ANCHOR_SYSLOG;
        }
        init = 1;
    }
    return mode;
}

static void anchor_publish(int kind, size_t rows, const uint8_t hash[32]) {
    int mode = anchor_mode();
    if (mode == ANCHOR_OFF) return;
    char hex[65];
    for (int i = 0; i < 32; i++) snprintf(hex + (size_t)i * 2, 3, "%02x", hash[i]);
    char line[256];
    int n = snprintf(line, sizeof line, "{\"event\":\"ledger_head\",\"kind\":%d,\"rows\":%llu,\"hash\":\"%s\"}",
                     kind, (unsigned long long)rows, hex);
    if (n < 0 || (size_t)n >= sizeof line) return;
#if !defined(_WIN32)
    if (mode == ANCHOR_SYSLOG) { syslog(LOG_INFO, "%s", line); return; }
#endif
    fprintf(stderr, "%s\n", line);
    fflush(stderr);
}

/* SHA-256(prev_hash || data): each row's hash covers the previous row's. */
static void chain_hash(const uint8_t prev[32], const void *data, size_t len, uint8_t out[32]) {
    fsql_sha256_ctx c;
    fsql_sha256_init(&c);
    fsql_sha256_update(&c, prev, 32);
    fsql_sha256_update(&c, (const uint8_t *)data, len);
    fsql_sha256_final(&c, out);
}

static chain *store_find(ledger_store *s, int kind) {
    for (size_t i = 0; i < s->nchains; i++) if (s->chains[i].kind == kind) return &s->chains[i];
    return NULL;
}

static chain *store_get(ledger_store *s, int kind) {
    chain *c = store_find(s, kind);
    if (c) return c;
    if (s->nchains == s->cap) {
        size_t nc = s->cap ? s->cap * 2 : 8;
        chain *np = (chain *)realloc(s->chains, nc * sizeof *np);
        if (!np) return NULL;
        s->chains = np; s->cap = nc;
    }
    c = &s->chains[s->nchains++];
    memset(c, 0, sizeof *c);
    c->kind = kind;
    return c;
}

/* 0 ok, -1 ledger full / out of memory. */
static int ledger_append(ledger_store *s, int kind, const void *payload, size_t len) {
    size_t cap = ledger_max_bytes();
    if (cap > 0 && s->total_bytes + len > cap) return -1;             /* ledger full */
    chain *c = store_get(s, kind);
    if (!c) return -1;
    if (c->n == c->cap) {
        size_t nc = c->cap ? c->cap * 2 : 16;
        chain_entry *ne = (chain_entry *)realloc(c->e, nc * sizeof *ne);
        if (!ne) return -1;
        c->e = ne; c->cap = nc;
    }
    chain_entry *e = &c->e[c->n];
    memset(e, 0, sizeof *e);
    e->blob = (uint8_t *)malloc(len ? len : 1);
    if (!e->blob) return -1;
    if (len) memcpy(e->blob, payload, len);
    e->len = len;
    if (c->n) memcpy(e->prev_hash, c->e[c->n - 1].hash, 32);
    chain_hash(e->prev_hash, payload, len, e->hash);
    e->id = c->next_id++;
    c->n++;
    s->total_bytes += len;
    anchor_publish(kind, c->n, e->hash);
    return 0;
}

static void store_free(ledger_store *s) {
    if (!s) return;
    for (size_t i = 0; i < s->nchains; i++) {
        for (size_t k = 0; k < s->chains[i].n; k++) free(s->chains[i].e[k].blob);
        free(s->chains[i].e);
    }
    free(s->chains);
    free(s);
}

/* NULL when the row is sound, else why not. */
static const char *verify_row(const chain_entry *row, const uint8_t expect_prev[32], int64_t expect_id) {
    if (expect_id >= 0 && (int64_t)row->id != expect_id) return "sequence gap (a row was deleted)";
    if (memcmp(row->prev_hash, expect_prev, 32) != 0) return "chain-link break (prev_hash mismatch)";
    uint8_t re[32];
    chain_hash(expect_prev, row->blob, row->len, re);
    if (memcmp(re, row->hash, 32) != 0) return "entry_hash mismatch (blob or mac tampered)";
    return NULL;
}


/* The verdict for one chain, as the JSON fractal_ledger_verify returns: {"ok":true,"rows_verified":N} for a sound (or empty) chain,
 * else {"ok":false,"first_failure_id":ID,"reason":"..."}. `ch` may be NULL (no such chain). */
static void ledger_chain_verdict(const chain *ch, char *json, size_t cap) {
    if (!ch || ch->n == 0) { snprintf(json, cap, "{\"ok\":true,\"rows_verified\":0}"); return; }
    uint8_t expect_prev[32] = {0};
    int64_t expect_id = -1;
    for (size_t r = 0; r < ch->n; r++) {
        const char *reason = verify_row(&ch->e[r], expect_prev, expect_id);
        if (reason) {
            snprintf(json, cap, "{\"ok\":false,\"first_failure_id\":%llu,\"reason\":\"%s\"}",
                     (unsigned long long)ch->e[r].id, reason);
            return;
        }
        memcpy(expect_prev, ch->e[r].hash, 32);
        expect_id = (int64_t)ch->e[r].id + 1;
    }
    snprintf(json, cap, "{\"ok\":true,\"rows_verified\":%llu}", (unsigned long long)ch->n);
}

#endif /* FSQL_LEDGER_STORE_H */
