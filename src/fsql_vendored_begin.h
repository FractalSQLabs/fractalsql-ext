/* Include before a vendored header-only helper (fsql_hmac.h, fsql_ed25519.h, fsql_audit_redact.h);
 * include fsql_vendored_end.h after it. Those headers define static helpers that a given TU may not all
 * use, and the build is otherwise warning-clean. */
#if defined(__GNUC__) || defined(__clang__)
#  pragma GCC diagnostic push
#  pragma GCC diagnostic ignored "-Wunused-function"
#endif
