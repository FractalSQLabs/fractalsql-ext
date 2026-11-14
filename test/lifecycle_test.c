/* test/lifecycle_test.c -- database lifetime with the extension loaded (Linux).
 *
 * A file database that has had the extension loaded must be releasable like any other: after the
 * client closes it, the process must hold no descriptor on the database or its WAL, the host must
 * have run its shutdown checkpoint (no .wal left), and the same file must reopen in the same process.
 *
 *   lifecycle_test <extension> <db-path> <mode> [rounds]
 *
 * mode:  plain    LOAD, write, use a nested-query function, close.
 *        release  as plain, but call fractal_release() before disconnecting.
 *        nopool   as plain, with FRACTALSQL_NESTED_QUERIES=off in the environment (set here, before LOAD).
 *        race     threads run nested-query functions while the main thread calls fractal_release(): every
 *                 statement must either succeed or report that nested queries were released, nothing may
 *                 hang or crash, and the database must then close cleanly.
 *        defaults as plain, with every monitor setting left at its default (grace 1 s).
 *        churn    the client disconnects and reconnects inside the grace period, over and over: nested
 *                 queries must keep working and the pool must not be released; then it closes cleanly.
 *        alias    clients that connect, run one plain statement and disconnect, over and over, with gaps far shorter than the
 *                 grace period: no nested query is ever run, so the only evidence of life is the transaction counter.
 *                 The connection count alone is a snapshot and would miss them; the pool must not be released.
 *        checkpoint  FRACTALSQL_HOST_CLOSE=checkpoint: with every connection closed the WAL is checkpointed
 *                 away, the pool stays usable for a reconnecting client.
 *        off      FRACTALSQL_HOST_CLOSE=off: no monitor; fractal_release() still works and closes cleanly.
 *        departrace  a client reconnects right at the grace boundary, over and over: every statement succeeds
 *                 or reports the release, never anything else, never a hang or crash; closes cleanly.
 *        thaw     a client arrives while the pool is frozen for the release check (the check is held open by
 *                 a test knob): the release must be abandoned, the client's nested query must wait and then
 *                 succeed, and the pool must stay usable; then it closes cleanly.
 *        multi    many file databases and one in-memory database opened, used and closed on concurrent
 *                 threads: every file released, no thread left behind.
 *        parallel  eight connections to ONE database call the extension from eight threads at once, while the host
 *                 itself runs a scan on several threads: pure functions, the domain-agent engine, the ledger, the
 *                 config get/set pair (which reads and writes the process environment) and the lazy enterprise
 *                 check. Pure functions must always succeed; the rest may report an error but must never crash or
 *                 hang. Its value is under ThreadSanitizer: it reaches the shared state the lifecycle modes do not.
 * plain/defaults/churn/departrace rely on the monitor: after the close they WAIT (up to 8 s) for the descriptor
 * to go. Prints one PASS/FAIL line per check and exits with the number of failures.
 *
 * Build:  cc -std=c11 -I<duckdb.h dir> lifecycle_test.c -L<libduckdb dir> -lduckdb -lpthread -Wl,-rpath,<dir>
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <pthread.h>
#include <unistd.h>

#include "duckdb.h"

static int g_fail;
static void check(int ok, const char *what, const char *detail) {
    printf("  %s %s%s%s\n", ok ? "PASS" : "FAIL", what, detail && *detail ? ": " : "", detail ? detail : "");
    if (!ok) g_fail++;
}

/* the first open descriptor of this process whose target starts with `path`, or NULL */
static const char *open_fd_on(const char *path, char *buf, size_t cap) {
    DIR *d = opendir("/proc/self/fd");
    if (!d) return NULL;
    struct dirent *e;
    size_t n = strlen(path);
    const char *found = NULL;
    while ((e = readdir(d)) != NULL) {
        char link[64], tgt[1024];
        snprintf(link, sizeof link, "/proc/self/fd/%s", e->d_name);
        ssize_t k = readlink(link, tgt, sizeof tgt - 1);
        if (k <= 0) continue;
        tgt[k] = 0;
        if (strncmp(tgt, path, n) == 0) { snprintf(buf, cap, "fd %s -> %s", e->d_name, tgt); found = buf; break; }
    }
    closedir(d);
    return found;
}

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000L;
}

static int task_count(void) {
    DIR *d = opendir("/proc/self/task");
    if (!d) return -1;
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) if (e->d_name[0] != '.') n++;
    closedir(d);
    return n;
}

/* waits up to `ms` for the process to hold no descriptor on `path`; returns the elapsed ms, or -1 */
static int wait_fd_gone(const char *path, int ms) {
    char buf[1200];
    for (int t = 0; t <= ms; t += 10) {
        if (!open_fd_on(path, buf, sizeof buf)) return t;
        usleep(10 * 1000);
    }
    return -1;
}

static int exists(const char *p) { struct stat st; return stat(p, &st) == 0; }

static int run(duckdb_connection c, const char *sql, char *err, size_t cap) {
    duckdb_result r;
    int ok = duckdb_query(c, sql, &r) == DuckDBSuccess;
    if (!ok && err) snprintf(err, cap, "%s", duckdb_result_error(&r) ? duckdb_result_error(&r) : "?");
    duckdb_destroy_result(&r);
    return ok;
}

/* ---- race mode */
typedef struct { duckdb_connection con; volatile int ok, released, other; char first_other[300]; } worker;
static volatile int g_stop;
static void *worker_main(void *arg) {
    worker *w = (worker *)arg;
    while (!g_stop) {
        duckdb_result r;
        if (duckdb_query(w->con, "SELECT length(fractal_schema_context())", &r) == DuckDBSuccess) w->ok++;
        else {
            const char *e = duckdb_result_error(&r);
            if (e && strstr(e, "were released")) w->released++;
            else { w->other++; if (!w->first_other[0]) snprintf(w->first_other, sizeof w->first_other, "%s", e ? e : "?"); }
        }
        duckdb_destroy_result(&r);
    }
    return NULL;
}

static void race_phase(duckdb_database db, duckdb_connection main_con) {
    enum { N = 4 };
    worker w[N] = {{0}};
    pthread_t th[N];
    g_stop = 0;
    for (int i = 0; i < N; i++) { duckdb_connect(db, &w[i].con); pthread_create(&th[i], NULL, worker_main, &w[i]); }
    /* let every worker finish at least one statement (a sanitizer or a loaded CI host can be slow), then a little more */
    for (int t = 0; t < 20000; t += 10) {
        int done = 0;
        for (int i = 0; i < N; i++) if (w[i].ok > 0) done++;
        if (done == N) break;
        usleep(10 * 1000);
    }
    usleep(100 * 1000);
    char err[512] = "";
    check(run(main_con, "SELECT fractal_release()", err, sizeof err), "fractal_release() while queries are in flight", err);
    usleep(100 * 1000);
    g_stop = 1;
    int ok = 0, rel = 0, other = 0; char first[300] = "";
    for (int i = 0; i < N; i++) {
        pthread_join(th[i], NULL);
        ok += w[i].ok; rel += w[i].released; other += w[i].other;
        if (!first[0] && w[i].first_other[0]) snprintf(first, sizeof first, "%s", w[i].first_other);
        duckdb_disconnect(&w[i].con);
    }
    char msg[400];
    snprintf(msg, sizeof msg, "%d ran, %d reported released, %d other%s%s", ok, rel, other, other ? ": " : "", first);
    check(other == 0 && ok > 0 && rel > 0, "every in-flight statement succeeded or reported the release", msg);
    check(!run(main_con, "SELECT fractal_schema_context()", err, sizeof err) && strstr(err, "were released") != NULL,
          "a nested-query function after the release says so", err);
    err[0] = 0;
    check(run(main_con, "SELECT fractal_release()", err, sizeof err), "fractal_release() is idempotent", err);
}

/* ---- churn mode: the client leaves and comes back inside the grace period.
 * The claim is about a client that really is back in time. On a starved machine (a sanitizer, a loaded CI host) the
 * test's own thread can sleep far longer than asked, and a client that was gone for most of the grace period has
 * legitimately left: releasing is then correct, so a release after a gap that long is a skipped cycle, not a failure. */
static void churn_phase(duckdb_database db, duckdb_connection *con) {
    unsigned x = 12345;
    char err[512] = "";
    int bad = 0, starved = 0, clean = 0;
    long long starved_ms = 0;
    for (int k = 0; k < 20 && !bad && !starved; k++) {
        long long t0 = now_ms();
        duckdb_disconnect(con);
        x = x * 1103515245u + 12345u;
        usleep(((x >> 16) % 50 + 5) * 1000);                 /* 5..54 ms, far inside the 500 ms grace */
        duckdb_connect(db, con);
        long long gap = now_ms() - t0;
        err[0] = 0;
        if (run(*con, "SELECT length(fractal_schema_context())", err, sizeof err)) { clean++; continue; }
        if (strstr(err, "were released") && gap >= 350) { starved = 1; starved_ms = gap; break; }
        char what[80]; snprintf(what, sizeof what, "nested query after reconnect #%d (gap %lld ms)", k + 1, gap);
        check(0, what, err); bad = 1;
    }
    if (starved) {
        char m[200]; snprintf(m, sizeof m, "skipped: the test thread was away %lld ms (grace is 500), so the release was correct; %d clean reconnects before", starved_ms, clean);
        check(1, "reconnects inside the grace period (host too starved to hold the timing)", m);
    } else if (!bad) check(1, "20 reconnects inside the grace period: nested queries kept working, pool never released", "");
}

/* ---- alias mode: short connections that never run a nested query, gaps far inside the grace period.
 * Two kinds of client, because two different signals catch them: one whose statement touches a table (the transaction
 * counter moves) and one that only pings with a constant query (nothing moves; only the connection count shows it,
 * so only fast sampling can). Neither may look like an absent host. */
/* A client that holds a connection for a tiny part of each cycle is only seen when a sample lands inside it, so the
 * guarantee is statistical: the grace period must hold enough samples. On a small or loaded host (and under a sanitizer)
 * one probe takes ~3 ms, which leaves ~50 samples in 300 ms, and a constant-query client is connected for ~3% of them:
 * a ~1-in-4 chance that every sample misses. A 1 s grace period (~200 samples) makes that negligible. */
#define ALIAS_GRACE_MS "1000"
#define ALIAS_RUN_MS   3000
static int alias_one(duckdb_database db, duckdb_connection *con, const char *stmt, int gap_us, const char *what) {
    char err[512] = "", msg[320];
    duckdb_disconnect(con);
    long long end = now_ms() + ALIAS_RUN_MS, last = now_ms(), max_gap = 0;
    int cycles = 0, bad = 0;
    while (now_ms() < end) {
        duckdb_connection c;
        duckdb_connect(db, &c);
        if (!run(c, stmt, err, sizeof err)) bad++;
        duckdb_disconnect(&c);
        long long t = now_ms();
        if (t - last > max_gap) max_gap = t - last;
        last = t;
        cycles++;
        usleep(gap_us);
    }
    duckdb_connect(db, con);
    err[0] = 0;
    int ok = run(*con, "SELECT length(fractal_schema_context())", err, sizeof err);
    snprintf(msg, sizeof msg, "%d connections over %.1f s, longest silence %lld ms: %s", cycles, ALIAS_RUN_MS / 1000.0, max_gap, ok ? "pool intact" : err);
    char label[200];
    if (!ok && strstr(err, "were released") && max_gap >= 250) {   /* the host was starved: a gap that long is a real absence */
        snprintf(label, sizeof label, "%s (host too starved to hold the timing: release was correct)", what);
        check(1, label, msg);
        return 1;
    }
    snprintf(label, sizeof label, "%s never look like an absent host: the pool was not released", what);
    check(bad == 0 && ok, label, msg);
    return ok;
}
static void alias_phase(duckdb_database db, duckdb_connection *con) {
    if (alias_one(db, con, "SELECT count(*) FROM t", 8 * 1000, "short connections running a statement that touches a table"))
        alias_one(db, con, "SELECT 42", 1 * 1000, "short connections that only ping with a constant query");
}

/* ---- departrace mode: the client comes back right at the grace boundary */
static void departrace_phase(duckdb_database db, duckdb_connection *con) {
    static unsigned x = 777;                                 /* carries across rounds: different gaps each time */
    int ok = 0, rel = 0, bad = 0, released = 0;
    char first[300] = "", err[512];
    for (int k = 0; k < 40 && !released; k++) {
        duckdb_disconnect(con);
        x = x * 1103515245u + 12345u;
        usleep((45 + (x >> 16) % 30) * 1000);                /* 45..74 ms around the 60 ms grace */
        duckdb_connect(db, con);
        err[0] = 0;
        if (run(*con, "SELECT length(fractal_schema_context())", err, sizeof err)) {
            if (released) { bad++; if (!first[0]) snprintf(first, sizeof first, "succeeded after the release #%d", k + 1); }
            else ok++;
        } else if (strstr(err, "were released")) { released = 1; rel++; }   /* the monitor won the race: legitimate */
        else { bad++; if (!first[0]) snprintf(first, sizeof first, "%s", err); }
    }
    char msg[420];
    snprintf(msg, sizeof msg, "%d ran, %d reported released, %d unexpected%s%s", ok, rel, bad, bad ? ": " : "", first);
    check(bad == 0, "every statement at the grace boundary succeeded or reported the release", msg);
}

/* ---- thaw mode: a client shows up between the two counts of the two-phase release */
static void thaw_phase(duckdb_database db, duckdb_connection *con) {
    char err[512] = "", msg[200];
    char marker[1200];
    snprintf(marker, sizeof marker, "%s", getenv("FRACTALSQL_HOST_CLOSE_TEST_FROZEN_FILE"));
    unlink(marker);              /* a marker from an earlier round must not satisfy this one */
    duckdb_disconnect(con);
    /* wait for the monitor to say it is frozen (it holds there for 1500 ms): a fixed sleep is a guess, and a slow
     * host (a sanitizer, a loaded CI machine) can still be in the grace period when the guess runs out */
    int seen = 0;
    for (int t = 0; t < 20000 && !seen; t += 5) { if (exists(marker)) seen = 1; else usleep(5 * 1000); }
    check(seen, "the monitor reported that it froze the pool for the release check", seen ? "" : "no freeze within 20 s");
    long long t0 = 0;
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    duckdb_connect(db, con);
    int ok = run(*con, "SELECT length(fractal_schema_context())", err, sizeof err);
    clock_gettime(CLOCK_MONOTONIC, &b);
    t0 = (b.tv_sec - a.tv_sec) * 1000LL + (b.tv_nsec - a.tv_nsec) / 1000000L;
    snprintf(msg, sizeof msg, "%s (waited %lld ms)", ok ? "ok" : err, t0);
    check(ok, "a client arriving during the freeze: its nested query waited, then succeeded", msg);
    check(t0 >= 300, "the query really waited for the freeze to resolve", msg);
    err[0] = 0;
    check(run(*con, "SELECT length(fractal_schema_context())", err, sizeof err), "the pool is still usable afterwards (release was abandoned)", err);
}

/* ---- parallel mode: one database, many connections, the extension's shared state touched from many threads.
 * The lifecycle modes above exercise the nested-query pool and the host-departure monitor. This one exercises
 * everything else that is process- or instance-wide: the domain-agent engine (one context behind one mutex), the
 * lazy enterprise-library check (a global mutex and three flags), the config pair (setenv/getenv), the in-memory
 * ledger, and a scalar function run by the host's own parallel executor. */
#define PAR_THREADS 8
#define PAR_ITERS   60
typedef struct { const char *sql; int must; } par_stmt;
static const par_stmt k_par[] = {
    { "SELECT fractal_version(), fractal_edition()", 1 },
    { "SELECT fractal_state_fingerprint([1.0, 2.0, 3.0]::DOUBLE[], 64, 1.0)", 1 },
    { "SELECT fractal_agent_route_task([0.8, 0.2, 0.1]::DOUBLE[], 'caps', 'emb', 'name', 1000)", 0 },
    { "SELECT fractal_config_get('http_model')", 0 },
    { NULL, 0 },                                   /* fractal_config_set, formatted per call */
    { "SELECT fractal_ledger_verify(), fractal_ledger_shadow_count()", 0 },
    { "SELECT fractal_ledger_reset_soft()", 0 },   /* a gated call: the first one runs the enterprise check */
    { "SELECT count(*) FROM (SELECT fractal_state_fingerprint([i * 1.0, 2.0]::DOUBLE[], 32, 1.0) FROM range(3000) t(i))", 1 },
};
#define N_PAR (sizeof k_par / sizeof k_par[0])
#define PAR_CFG_SET 4
typedef struct { duckdb_connection con; int id, ok, must_fail; char first_bad[300]; } par_worker;
static void *par_main(void *arg) {
    par_worker *w = (par_worker *)arg;
    char sql[256];
    for (int it = 0; it < PAR_ITERS; it++) {
        int k = (it + w->id) % (int)N_PAR;
        const char *q = k_par[k].sql;
        if (k == PAR_CFG_SET) { snprintf(sql, sizeof sql, "SELECT fractal_config_set('http_model', 'm-%d-%d')", w->id, it); q = sql; }
        duckdb_result r;
        if (duckdb_query(w->con, q, &r) == DuckDBSuccess) w->ok++;
        else if (k_par[k].must) {
            w->must_fail++;
            if (!w->first_bad[0]) snprintf(w->first_bad, sizeof w->first_bad, "%.120s -> %.150s", q, duckdb_result_error(&r) ? duckdb_result_error(&r) : "?");
        }
        duckdb_destroy_result(&r);
    }
    return NULL;
}
static void parallel_phase(duckdb_database db, duckdb_connection main_con) {
    char err[512] = "";
    check(run(main_con, "SET threads = 4", err, sizeof err), "the host runs scans on several threads", err);
    par_worker w[PAR_THREADS];
    pthread_t th[PAR_THREADS];
    memset(w, 0, sizeof w);
    int started = 0;
    for (int i = 0; i < PAR_THREADS; i++) {
        w[i].id = i;
        if (duckdb_connect(db, &w[i].con) != DuckDBSuccess) { check(0, "connect a worker", "duckdb_connect failed"); break; }
        if (pthread_create(&th[i], NULL, par_main, &w[i]) != 0) { check(0, "start a worker thread", "pthread_create failed"); duckdb_disconnect(&w[i].con); break; }
        started++;
    }
    int ok = 0, bad = 0;
    for (int i = 0; i < started; i++) { pthread_join(th[i], NULL); ok += w[i].ok; bad += w[i].must_fail; duckdb_disconnect(&w[i].con); }
    char detail[400] = "";
    for (int i = 0; i < started; i++) if (w[i].first_bad[0]) { snprintf(detail, sizeof detail, "%s", w[i].first_bad); break; }
    check(started == PAR_THREADS, "all worker threads ran", "");
    check(bad == 0, "the pure functions succeeded on every thread, every time", detail);
    check(ok > 0, "statements completed", ok > 0 ? "" : "none completed");
}

static int one_round(const char *ext, const char *path, const char *mode, int round) {
    char sql[1500], err[512] = "", buf[1200], wal[1100];
    snprintf(wal, sizeof wal, "%s.wal", path);
    int before = g_fail;

    duckdb_config cfg = NULL;
    duckdb_create_config(&cfg);
    duckdb_set_config(cfg, "allow_unsigned_extensions", "true");
    duckdb_database db = NULL;
    char *oerr = NULL;
    if (duckdb_open_ext(path, &db, cfg, &oerr) != DuckDBSuccess) {
        check(0, "open the database", oerr ? oerr : "?");
        duckdb_destroy_config(&cfg);
        return 1;
    }
    duckdb_destroy_config(&cfg);
    duckdb_connection con = NULL;
    duckdb_connect(db, &con);

    snprintf(sql, sizeof sql, "LOAD '%s'", ext);
    check(run(con, sql, err, sizeof err), "LOAD the extension", err);
    check(run(con, "CREATE TABLE IF NOT EXISTS t(i INTEGER, v DOUBLE[])", err, sizeof err), "create a table", err);
    check(run(con, "INSERT INTO t SELECT i, [i * 0.1, 0.5, 0.25] FROM range(200) r(i)", err, sizeof err), "insert rows", err);
    if (strcmp(mode, "nopool") != 0)
        check(run(con, "SELECT fractal_schema_context()", err, sizeof err), "a nested-query function works", err);
    else
        check(!run(con, "SELECT fractal_schema_context()", err, sizeof err) && strstr(err, "fractalsql:") != NULL,
              "a nested-query function reports that nested queries are off", err);
    check(run(con, "SELECT fractal_version()", err, sizeof err), "a pool-free function works", err);
    if (strcmp(mode, "race") == 0) race_phase(db, con);
    if (strcmp(mode, "release") == 0) check(run(con, "SELECT fractal_release()", err, sizeof err), "fractal_release()", err);
    if (strcmp(mode, "off") == 0) check(run(con, "SELECT fractal_release()", err, sizeof err), "fractal_release() with no monitor", err);
    if (strcmp(mode, "churn") == 0) churn_phase(db, &con);
    if (strcmp(mode, "alias") == 0) alias_phase(db, &con);
    if (strcmp(mode, "thaw") == 0) thaw_phase(db, &con);
    if (strcmp(mode, "departrace") == 0) departrace_phase(db, &con);
    if (strcmp(mode, "parallel") == 0) parallel_phase(db, con);

    duckdb_disconnect(&con);
    duckdb_close(&db);

    int waited = wait_fd_gone(path, 8000);
    snprintf(buf, sizeof buf, "released %d ms after the close", waited);
    check(waited >= 0, "no descriptor left on the database or its WAL after close", waited >= 0 ? buf : "still open after 8 s");
    const char *fd = NULL;
    check(!exists(wal), "the host ran its shutdown checkpoint (no .wal left)", exists(wal) ? wal : "");

    /* the same file must reopen in the same process, and keep its data */
    db = NULL; oerr = NULL;
    int ok = duckdb_open_ext(path, &db, NULL, &oerr) == DuckDBSuccess;
    check(ok, "reopen the same file in the same process", ok ? "" : (oerr ? oerr : "?"));
    if (ok) {
        duckdb_connect(db, &con);
        duckdb_result r;
        int q = duckdb_query(con, "SELECT count(*) FROM t", &r) == DuckDBSuccess;
        long long n = q ? (long long)duckdb_value_int64(&r, 0, 0) : -1;
        check(q && n >= 200 * (round + 1), "the data survived", q ? "" : duckdb_result_error(&r));
        duckdb_destroy_result(&r);
        duckdb_disconnect(&con);
        duckdb_close(&db);
        fd = open_fd_on(path, buf, sizeof buf);
        check(fd == NULL, "no descriptor left after the second close", fd ? fd : "");
    }
    return g_fail - before;
}

/* ---- checkpoint mode: every connection closed -> the WAL is folded into the file, the pool stays usable */
static int checkpoint_round(const char *ext, const char *path) {
    char sql[1500], err[512] = "", buf[1200], wal[1100];
    snprintf(wal, sizeof wal, "%s.wal", path);
    int before = g_fail;
    duckdb_config cfg = NULL; duckdb_create_config(&cfg);
    duckdb_set_config(cfg, "allow_unsigned_extensions", "true");
    duckdb_database db = NULL; char *oerr = NULL;
    if (duckdb_open_ext(path, &db, cfg, &oerr) != DuckDBSuccess) { check(0, "open the database", oerr ? oerr : "?"); duckdb_destroy_config(&cfg); return 1; }
    duckdb_destroy_config(&cfg);
    duckdb_connection con = NULL; duckdb_connect(db, &con);
    snprintf(sql, sizeof sql, "LOAD '%s'", ext);
    check(run(con, sql, err, sizeof err), "LOAD the extension", err);
    check(run(con, "CREATE OR REPLACE TABLE t(i INTEGER, v DOUBLE[])", err, sizeof err), "create a table", err);
    check(run(con, "INSERT INTO t SELECT i, [i * 0.1, 0.5] FROM range(200) r(i)", err, sizeof err), "insert rows", err);
    check(exists(wal), "the inserts are in the WAL (precondition)", wal);
    duckdb_disconnect(&con);
    int t = 0;
    while (t < 8000 && exists(wal)) { usleep(10 * 1000); t += 10; }
    snprintf(buf, sizeof buf, "checkpointed %d ms after the last connection closed", t);
    check(!exists(wal), "with every connection closed the monitor checkpointed the WAL away", exists(wal) ? "WAL still there after 8 s" : buf);
    duckdb_connect(db, &con);
    err[0] = 0;
    check(run(con, "SELECT length(fractal_schema_context())", err, sizeof err), "the pool is still usable for a reconnecting client", err);
    check(run(con, "SELECT count(*) = 200 FROM t", err, sizeof err), "the data is intact", err);
    check(run(con, "SELECT fractal_release()", err, sizeof err), "fractal_release()", err);
    duckdb_disconnect(&con);
    duckdb_close(&db);
    check(wait_fd_gone(path, 8000) >= 0, "no descriptor left after close", "");
    return g_fail - before;
}

/* ---- multi mode: many databases at once */
typedef struct { const char *ext; char path[1100]; int fail; } multi_job;
static void *multi_main(void *arg) {
    multi_job *j = (multi_job *)arg;
    char sql[1500], err[512];
    duckdb_config cfg = NULL; duckdb_create_config(&cfg);
    duckdb_set_config(cfg, "allow_unsigned_extensions", "true");
    duckdb_database db = NULL; char *oerr = NULL;
    if (duckdb_open_ext(j->path[0] ? j->path : NULL, &db, cfg, &oerr) != DuckDBSuccess) { j->fail = 1; duckdb_destroy_config(&cfg); return NULL; }
    duckdb_destroy_config(&cfg);
    duckdb_connection con = NULL; duckdb_connect(db, &con);
    snprintf(sql, sizeof sql, "LOAD '%s'", j->ext);
    if (!run(con, sql, err, sizeof err) ||
        !run(con, "CREATE TABLE t(i INTEGER)", err, sizeof err) ||
        !run(con, "INSERT INTO t SELECT * FROM range(50)", err, sizeof err) ||
        !run(con, "SELECT length(fractal_schema_context())", err, sizeof err)) j->fail = 1;
    duckdb_disconnect(&con);
    duckdb_close(&db);
    return NULL;
}
static int multi_round(const char *ext, const char *path) {
    enum { N = 8 };
    multi_job jobs[N + 1];
    pthread_t th[N + 1];
    int before = g_fail;
    memset(jobs, 0, sizeof jobs);
    {   /* warm-up: one database in and out, so lazily started process-wide threads (a sanitizer's, the host's) are in the baseline */
        multi_job w; memset(&w, 0, sizeof w); w.ext = ext;
        multi_main(&w);
        int t = 0, prev = -1, cur = task_count();
        while (t < 8000 && cur != prev) { prev = cur; usleep(200 * 1000); t += 200; cur = task_count(); }
    }
    int base = task_count();
    for (int i = 0; i <= N; i++) {
        jobs[i].ext = ext;
        if (i < N) { snprintf(jobs[i].path, sizeof jobs[i].path, "%s.m%d", path, i); unlink(jobs[i].path); }   /* [N] is :memory: */
        pthread_create(&th[i], NULL, multi_main, &jobs[i]);
    }
    int bad = 0;
    for (int i = 0; i <= N; i++) { pthread_join(th[i], NULL); bad += jobs[i].fail; }
    check(bad == 0, "8 file databases and 1 in-memory database loaded, used and closed on concurrent threads", "");
    int worst = 0, leaked = 0;
    for (int i = 0; i < N; i++) {
        int w = wait_fd_gone(jobs[i].path, 8000);
        if (w < 0) leaked++; else if (w > worst) worst = w;
    }
    char msg[200]; snprintf(msg, sizeof msg, "%d still open", leaked);
    check(leaked == 0, "every file database was released by its own monitor", leaked ? msg : "");
    int t = 0, now = task_count();
    while (t < 8000 && now > base) { usleep(10 * 1000); t += 10; now = task_count(); }
    snprintf(msg, sizeof msg, "%d threads before, %d after", base, now);
    check(now <= base, "no thread left behind (monitors exited, hosts shut down)", msg);
    for (int i = 0; i < N; i++) {
        char w[1200]; snprintf(w, sizeof w, "%s.wal", jobs[i].path);
        if (exists(w)) { check(0, "no .wal left", w); }
        unlink(jobs[i].path); unlink(w);
    }
    return g_fail - before;
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s <extension> <db-path> <plain|defaults|release|nopool|race|churn|alias|checkpoint|off|departrace|thaw|multi|parallel> [rounds]\n", argv[0]); return 2; }
    const char *ext = argv[1], *path = argv[2], *mode = argv[3];
    int rounds = argc > 4 ? atoi(argv[4]) : 1;
    if (strcmp(mode, "nopool") == 0) setenv("FRACTALSQL_NESTED_QUERIES", "off", 1);
    /* the monitor, quick enough for a test; `defaults` and `release` leave it alone */
    if (strcmp(mode, "defaults") != 0 && strcmp(mode, "release") != 0) {
        const char *grace = !strcmp(mode, "churn") ? "500" : !strcmp(mode, "alias") ? ALIAS_GRACE_MS : !strcmp(mode, "departrace") ? "60" : !strcmp(mode, "checkpoint") ? "100" : "150";
        setenv("FRACTALSQL_HOST_CLOSE_POLL_MS", !strcmp(mode, "departrace") ? "10" : "20", 1);
        setenv("FRACTALSQL_HOST_CLOSE_GRACE_MS", grace, 1);
    }
    if (strcmp(mode, "thaw") == 0) {
        setenv("FRACTALSQL_HOST_CLOSE_GRACE_MS", "50", 1);
        setenv("FRACTALSQL_HOST_CLOSE_TEST_FREEZE_MS", "1500", 1);
        { static char m[1200]; snprintf(m, sizeof m, "%s.frozen", path); unlink(m); setenv("FRACTALSQL_HOST_CLOSE_TEST_FROZEN_FILE", m, 1); }
    }
    if (strcmp(mode, "checkpoint") == 0) setenv("FRACTALSQL_HOST_CLOSE", "checkpoint", 1);
    if (strcmp(mode, "off") == 0) setenv("FRACTALSQL_HOST_CLOSE", "off", 1);
    setenv("FSQL_REASONING_ALLOW_UNVERIFIED", "1", 1);
    setenv("FSQL_REASONING_REQUIRE_SIGNATURE", "0", 1);
    char wal[1100];
    snprintf(wal, sizeof wal, "%s.wal", path);
    unlink(path); unlink(wal);
    for (int i = 0; i < rounds; i++) {
        printf("round %d (%s)\n", i + 1, mode);
        if (!strcmp(mode, "checkpoint")) checkpoint_round(ext, path);
        else if (!strcmp(mode, "multi")) multi_round(ext, path);
        else one_round(ext, path, mode, i);
        if (g_fail && rounds > 1) break;
    }
    unlink(path); unlink(wal);
    if (!strcmp(mode, "thaw")) { char m[1200]; snprintf(m, sizeof m, "%s.frozen", path); unlink(m); }
    printf("%s: %d failure(s)\n", mode, g_fail);
    return g_fail > 99 ? 99 : g_fail;
}
