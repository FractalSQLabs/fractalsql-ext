/* src/fsql_port.h -- the few OS differences the extension cares about.
 * POSIX and MSVC (C mode) only; everything else is plain C11. */
#ifndef FSQL_PORT_H
#define FSQL_PORT_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef _WIN32
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
typedef SRWLOCK fsql_mu_t;
#  define FSQL_MU_INIT SRWLOCK_INIT
#  define fsql_mu_init(m)   InitializeSRWLock(m)
#  define fsql_mu_lock(m)   AcquireSRWLockExclusive(m)
#  define fsql_mu_unlock(m) ReleaseSRWLockExclusive(m)
#  define fsql_strcasecmp   _stricmp
#  define fsql_strncasecmp  _strnicmp
#  define FSQL_UNUSED
#else
#  include <pthread.h>
#  include <strings.h>
typedef pthread_mutex_t fsql_mu_t;
#  define FSQL_MU_INIT PTHREAD_MUTEX_INITIALIZER
#  define fsql_mu_init(m)   pthread_mutex_init((m), NULL)
#  define fsql_mu_lock(m)   pthread_mutex_lock(m)
#  define fsql_mu_unlock(m) pthread_mutex_unlock(m)
#  define fsql_strcasecmp   strcasecmp
#  define fsql_strncasecmp  strncasecmp
#  define FSQL_UNUSED __attribute__((unused))
#endif

/* Thread-local storage and a condition variable with a millisecond timeout. */
#ifdef _WIN32
#  if defined(_MSC_VER)
#    define FSQL_TLS __declspec(thread)
#  else
#    define FSQL_TLS _Thread_local        /* MinGW and others: __declspec(thread) is not honoured in this position */
#  endif
typedef CONDITION_VARIABLE fsql_cv_t;
#  define FSQL_CV_INIT CONDITION_VARIABLE_INIT
#  define fsql_cv_init(cv)  InitializeConditionVariable(cv)
static inline void fsql_cv_broadcast(fsql_cv_t *cv) { WakeAllConditionVariable(cv); }
/* Waits with the mutex held; 0 = woken, -1 = timed out. */
static inline int fsql_cv_wait_ms(fsql_cv_t *cv, fsql_mu_t *mu, unsigned ms) {
    return SleepConditionVariableSRW(cv, mu, ms, 0) ? 0 : -1;
}
#else
#  include <errno.h>
#  include <time.h>
#  define FSQL_TLS _Thread_local
typedef pthread_cond_t fsql_cv_t;
#  define FSQL_CV_INIT PTHREAD_COND_INITIALIZER
#  define fsql_cv_init(cv)  pthread_cond_init((cv), NULL)
static inline void fsql_cv_broadcast(fsql_cv_t *cv) { pthread_cond_broadcast(cv); }
static inline int fsql_cv_wait_ms(fsql_cv_t *cv, fsql_mu_t *mu, unsigned ms) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += ms / 1000;
    ts.tv_nsec += (long)(ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
    return pthread_cond_timedwait(cv, mu, &ts) == ETIMEDOUT ? -1 : 0;
}
#endif


/* A joinable thread. fn returns void*; fsql_thread_detach_self() is called by the thread itself when
 * nobody will join it. */
#ifdef _WIN32
#  include <stdlib.h>
typedef HANDLE fsql_thread_t;
typedef struct { void *(*fn)(void *); void *arg; } fsql_thr_tramp;
static inline DWORD WINAPI fsql_thr_main(LPVOID p) {
    fsql_thr_tramp t = *(fsql_thr_tramp *)p;
    free(p);
    t.fn(t.arg);
    return 0;
}
static inline int fsql_thread_start(fsql_thread_t *t, void *(*fn)(void *), void *arg) {
    fsql_thr_tramp *tr = (fsql_thr_tramp *)malloc(sizeof *tr);
    if (!tr) return -1;
    tr->fn = fn; tr->arg = arg;
    *t = CreateThread(NULL, 0, fsql_thr_main, tr, 0, NULL);
    if (!*t) { free(tr); return -1; }
    return 0;
}
static inline void fsql_thread_join(fsql_thread_t t)        { WaitForSingleObject(t, INFINITE); CloseHandle(t); }
static inline void fsql_thread_detach_self(fsql_thread_t t) { CloseHandle(t); }
#else
typedef pthread_t fsql_thread_t;
static inline int fsql_thread_start(fsql_thread_t *t, void *(*fn)(void *), void *arg) { return pthread_create(t, NULL, fn, arg) == 0 ? 0 : -1; }
static inline void fsql_thread_join(fsql_thread_t t)        { pthread_join(t, NULL); }
static inline void fsql_thread_detach_self(fsql_thread_t t) { (void)t; pthread_detach(pthread_self()); }
#endif

/* Monotonic milliseconds, for elapsed-time reporting. */
#ifdef _WIN32
static inline long long fsql_monotonic_ms(void) { return (long long)GetTickCount64(); }
#else
static inline long long fsql_monotonic_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000L;
}
#endif

/* printf-style format checking where the compiler supports it */
#if defined(__GNUC__) || defined(__clang__)
#  define FSQL_PRINTF(fmt_idx, first_arg) __attribute__((format(printf, fmt_idx, first_arg)))
#else
#  define FSQL_PRINTF(fmt_idx, first_arg)
#endif

#endif /* FSQL_PORT_H */
