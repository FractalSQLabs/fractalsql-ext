/* src/fsql_buf.c -- see include/fsql_buf.h. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_buf.h"

/* ------------------------------------------------------------ string builder */

void fsql_sb_init(fsql_sb *b) { b->p = NULL; b->len = 0; b->cap = 0; b->bad = false; }

void fsql_sb_free(fsql_sb *b) { free(b->p); fsql_sb_init(b); }

bool fsql_sb_ok(const fsql_sb *b) { return !b->bad; }

void fsql_sb_clear(fsql_sb *b) {
    b->len = 0;
    if (b->p) b->p[0] = 0;
}

/* Ensures room for `extra` more bytes plus the NUL. */
static bool sb_reserve(fsql_sb *b, size_t extra) {
    if (b->bad) return false;
    if (extra > FSQL_BUF_MAX || b->len > FSQL_BUF_MAX - extra - 1) { b->bad = true; return false; }
    size_t need = b->len + extra + 1;
    if (need <= b->cap) return true;
    size_t cap = b->cap ? b->cap : 64;
    while (cap < need) {
        if (cap > FSQL_BUF_MAX / 2) { cap = FSQL_BUF_MAX; break; }
        cap *= 2;
    }
    if (cap < need) { b->bad = true; return false; }
    char *np = (char *)realloc(b->p, cap);
    if (!np) { b->bad = true; return false; }
    b->p = np;
    b->cap = cap;
    return true;
}

void fsql_sb_putn(fsql_sb *b, const char *s, size_t n) {
    if (n == 0) return;
    if (!s) { b->bad = true; return; }
    if (!sb_reserve(b, n)) return;
    memcpy(b->p + b->len, s, n);
    b->len += n;
    b->p[b->len] = 0;
}

void fsql_sb_puts(fsql_sb *b, const char *s) {
    if (!s) { b->bad = true; return; }          /* a NULL string is a caller bug: make it visible */
    fsql_sb_putn(b, s, strlen(s));
}

void fsql_sb_putc(fsql_sb *b, char c) { fsql_sb_putn(b, &c, 1); }

void fsql_sb_vprintf(fsql_sb *b, const char *fmt, va_list ap) {
    if (b->bad) return;
    va_list ap2;
    va_copy(ap2, ap);
    int n = vsnprintf(NULL, 0, fmt, ap2);
    va_end(ap2);
    if (n < 0) { b->bad = true; return; }
    if (!sb_reserve(b, (size_t)n)) return;
    vsnprintf(b->p + b->len, (size_t)n + 1, fmt, ap);
    b->len += (size_t)n;
}

void fsql_sb_printf(fsql_sb *b, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fsql_sb_vprintf(b, fmt, ap);
    va_end(ap);
}

void fsql_sb_put_json_escaped(fsql_sb *b, const char *s, size_t n) {
    static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
        case '"':  fsql_sb_putn(b, "\\\"", 2); break;
        case '\\': fsql_sb_putn(b, "\\\\", 2); break;
        case '\n': fsql_sb_putn(b, "\\n", 2); break;
        case '\r': fsql_sb_putn(b, "\\r", 2); break;
        case '\t': fsql_sb_putn(b, "\\t", 2); break;
        case '\b': fsql_sb_putn(b, "\\b", 2); break;
        case '\f': fsql_sb_putn(b, "\\f", 2); break;
        default:
            if (c < 0x20) {
                char u[6] = { '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15] };
                fsql_sb_putn(b, u, 6);
            } else {
                fsql_sb_putc(b, (char)c);
            }
        }
    }
}

void fsql_sb_put_json_double(fsql_sb *b, double d) {
    if (isnan(d) || isinf(d)) { fsql_sb_puts(b, "null"); return; }
    fsql_sb_printf(b, "%.17g", d);
}

const char *fsql_sb_cstr(const fsql_sb *b) { return (b->p && !b->bad) ? b->p : ""; }

char *fsql_sb_take(fsql_sb *b) {
    char *out = NULL;
    if (!b->bad) {
        if (!b->p) out = fsql_xstrdup("");
        else { out = b->p; b->p = NULL; }
    }
    fsql_sb_free(b);
    return out;
}

/* ----------------------------------------------------------- growable arrays */

void fsql_vecd_init(fsql_vecd *v) { v->p = NULL; v->len = v->cap = 0; v->bad = false; }
void fsql_vecd_free(fsql_vecd *v) { free(v->p); fsql_vecd_init(v); }
bool fsql_vecd_ok(const fsql_vecd *v) { return !v->bad; }

bool fsql_vecd_reserve(fsql_vecd *v, size_t n) {
    if (v->bad) return false;
    if (n > FSQL_BUF_MAX / sizeof(double) || v->len > FSQL_BUF_MAX / sizeof(double) - n) { v->bad = true; return false; }
    size_t need = v->len + n;
    if (need <= v->cap) return true;
    size_t cap = v->cap ? v->cap : 16;
    while (cap < need) cap *= 2;
    double *np = (double *)realloc(v->p, cap * sizeof(double));
    if (!np) { v->bad = true; return false; }
    v->p = np;
    v->cap = cap;
    return true;
}

void fsql_vecd_push(fsql_vecd *v, double d) {
    if (!fsql_vecd_reserve(v, 1)) return;
    v->p[v->len++] = d;
}

/* --------------------------------------------------------------- small helpers */

void *fsql_xmalloc_array(size_t n, size_t size) {
    if (size != 0 && n > SIZE_MAX / size) return NULL;
    size_t total = n * size;
    return malloc(total ? total : 1);
}

char *fsql_xstrdup(const char *s) { return s ? fsql_xstrndup(s, strlen(s)) : NULL; }

char *fsql_xstrndup(const char *s, size_t n) {
    char *o = (char *)malloc(n + 1);
    if (!o) return NULL;
    if (n) memcpy(o, s, n);
    o[n] = 0;
    return o;
}
