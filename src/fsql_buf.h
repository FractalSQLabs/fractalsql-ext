/* src/fsql_buf.h -- the extension's one string/array toolkit.
 *
 * Every family builds text and arrays through this, never through raw
 * snprintf into stack buffers whose size a caller guessed. Contract:
 *   - a buffer is always NUL-terminated and never overflows;
 *   - growth is checked for size_t wrap and for the hard cap FSQL_BUF_MAX;
 *   - an allocation failure (or the cap) puts the buffer in a sticky error
 *     state: further appends are no-ops, and fsql_sb_ok() reports false once,
 *     at the end -- so call sites check one flag instead of every append.
 * The unit test (test/buf_test.c) runs it under ASan/UBSan.
 */
#ifndef FSQL_BUF_H
#define FSQL_BUF_H

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define FSQL_BUF_MAX ((size_t)1 << 30)   /* 1 GiB: far above any legitimate result */

/* ------------------------------------------------------------ string builder */

typedef struct {
    char  *p;      /* NUL-terminated; NULL only before the first append */
    size_t len;    /* bytes used, excluding the NUL */
    size_t cap;    /* bytes allocated */
    bool   bad;    /* sticky: out of memory or over the cap */
} fsql_sb;

void        fsql_sb_init(fsql_sb *b);
void        fsql_sb_free(fsql_sb *b);
bool        fsql_sb_ok(const fsql_sb *b);
void        fsql_sb_putn(fsql_sb *b, const char *s, size_t n);
void        fsql_sb_puts(fsql_sb *b, const char *s);
void        fsql_sb_putc(fsql_sb *b, char c);
void        fsql_sb_printf(fsql_sb *b, const char *fmt, ...);
void        fsql_sb_vprintf(fsql_sb *b, const char *fmt, va_list ap);
/* Appends s[0..n) as a JSON string literal body (quotes NOT added): escapes ",
 * \, control bytes; passes UTF-8 through. */
void        fsql_sb_put_json_escaped(fsql_sb *b, const char *s, size_t n);
/* Appends a double the way the C++ build's printf("%.17g"/"%g") callers do, but
 * maps NaN/Inf to null so the output stays valid JSON. */
void        fsql_sb_put_json_double(fsql_sb *b, double d);
/* The text, never NULL ("" for an empty or failed builder). Valid until the next append. */
const char *fsql_sb_cstr(const fsql_sb *b);
/* Takes ownership of the buffer (caller free()s); the builder is reset. NULL if bad. */
char       *fsql_sb_take(fsql_sb *b);
void        fsql_sb_clear(fsql_sb *b);

/* ----------------------------------------------------------- growable arrays */

typedef struct {
    double *p;
    size_t  len, cap;
    bool    bad;
} fsql_vecd;

void   fsql_vecd_init(fsql_vecd *v);
void   fsql_vecd_free(fsql_vecd *v);
bool   fsql_vecd_ok(const fsql_vecd *v);
void   fsql_vecd_push(fsql_vecd *v, double d);
/* Ensures room for n more elements. */
bool   fsql_vecd_reserve(fsql_vecd *v, size_t n);

/* --------------------------------------------------------------- small helpers */

/* malloc(n * size) with overflow check; NULL on overflow or failure. */
void  *fsql_xmalloc_array(size_t n, size_t size);
/* strdup that tolerates NULL (-> NULL). */
char  *fsql_xstrdup(const char *s);
/* Copies s[0..n) into a new NUL-terminated string. */
char  *fsql_xstrndup(const char *s, size_t n);

#endif /* FSQL_BUF_H */
