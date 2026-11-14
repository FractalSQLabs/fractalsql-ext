// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// db_probe: the connection layer on its own. It checks the error classification, every parameter-binding kind
// (including the empty list that once crashed the process), cell decoding, row caps, the lock-down (no file
// access, no INSTALL/LOAD, settings frozen), interrupt, the shared database handle, and the clean failures for a
// bad extension path, a bad bootstrap file and a closed connection.
//
// Needs FSQL_DUCKDB_EXTENSION (the extension to load) and libduckdb at run time. exit 0 = every check passed.
#include "../src/db.h"
#include <duckdb.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <thread>

// The probe runs on the platform the server was built for, so the handful of
// POSIX-only calls it makes (the process id, the file-existence check, the
// environment setters, the hard exit) are mapped onto their Windows
// equivalents here. Without this the probe does not compile at all under
// MSVC, and the whole Windows MCP gate stops at the build step.
#ifdef _WIN32
  #include <process.h>
  #include <io.h>
  #define FSQL_PROBE_GETPID()      _getpid()
  #define FSQL_PROBE_EXISTS(p)     (_access((p), 0) == 0)
  #define FSQL_PROBE_SETENV(k, v)  _putenv_s((k), (v))
  #define FSQL_PROBE_UNSETENV(k)   _putenv_s((k), "")
  #define FSQL_PROBE_EXIT(code)    _Exit(code)
  // A writable directory for the throwaway bootstrap file, and a path
  // separator DuckDB accepts in a SQL string on Windows (forward slashes).
  static std::string probeTempDir()
  {
      const char* t = std::getenv( "TEMP" );
      if( !t || !*t ) t = std::getenv( "TMP" );
      std::string dir = ( t && *t ) ? std::string( t ) : std::string( "C:/Windows/Temp" );
      for( size_t i = 0; i < dir.size(); ++i ) if( dir[ i ] == '\\' ) dir[ i ] = '/';
      while( !dir.empty() && dir[ dir.size() - 1 ] == '/' ) dir.erase( dir.size() - 1 );
      return dir;
  }
#else
  #include <unistd.h>
  #define FSQL_PROBE_GETPID()      getpid()
  #define FSQL_PROBE_EXISTS(p)     (access((p), F_OK) == 0)
  #define FSQL_PROBE_SETENV(k, v)  setenv((k), (v), 1)
  #define FSQL_PROBE_UNSETENV(k)   unsetenv((k))
  #define FSQL_PROBE_EXIT(code)    _exit(code)
  static std::string probeTempDir() { return std::string( "/tmp" ); }
#endif

using namespace fsqlmcp;

static int g_fail = 0, g_n = 0;
static void check( bool ok, const std::string& what )
{
    ++g_n;
    if( !ok ) { ++g_fail; std::printf( "FAIL: %s\n", what.c_str() ); }
    else std::printf( "OK: %s\n", what.c_str() );
}

static bool throwsClass( Db& db, ErrorClass cls, const std::string& sql, const std::vector<BindValue>& b = {} )
{
    try { db.query( sql, b ); return false; } catch( const ToolError& e ) { return e.errorClass == cls; }
}
static Cell one( Db& db, const std::string& sql, const std::vector<BindValue>& b = {} )
{
    QueryResult r = db.query( sql, b );
    return r.rows.at( 0 ).at( 0 );
}

int main()
{
    const char* ext = std::getenv( "FSQL_DUCKDB_EXTENSION" );
    if( !ext || !*ext ) { std::printf( "db_probe: FSQL_DUCKDB_EXTENSION is not set\n" ); return 2; }

    // ---- the classifier (no database needed)
    check( classifyEngineError( DUCKDB_ERROR_INTERRUPT, "INTERRUPT Error: Interrupted!" ).errorClass == ErrorClass::Cancelled, "classify: an interrupt is a cancellation" );
    check( classifyEngineError( 0, "Binder Error: no such column" ).errorClass == ErrorClass::Engine, "classify: a binder error is an engine error" );
    check( classifyEngineError( 0, "Catalog Error: Table with name x does not exist" ).errorClass == ErrorClass::Engine, "classify: a catalog error is an engine error" );
    check( classifyEngineError( 0, "Out of Memory Error: could not allocate" ).errorClass == ErrorClass::Engine, "classify: out of memory is an engine error" );
    check( classifyEngineError( 0, "FATAL Error: database has been invalidated" ).errorClass == ErrorClass::Connectivity, "classify: an invalidated database is connectivity" );
    check( classifyEngineError( 0, "IO Error: fractalsql: reasoning plugin not configured" ).errorClass == ErrorClass::Engine, "classify: 'plugin not configured' is a clean engine error" );
    check( classifyEngineError( 0, "failed password=hunter2 near x" ).message.find( "hunter2" ) == std::string::npos, "classify: a secret in the message is redacted" );

    // ---- connect failures are clean
    { Db db; EngineConfig c; c.extension = "/no/such/fractalsql.duckdb_extension"; c.allowUnsigned = true;
      bool ok = false; try { db.connect( c ); } catch( const ToolError& e ) { ok = e.errorClass == ErrorClass::Connectivity && e.message.find( "failed to load the FractalSQL extension" ) != std::string::npos; }
      check( ok, "connect: a missing extension file is a clean connectivity error" ); }
    { Db db; EngineConfig c; c.extension = ext; c.allowUnsigned = true; c.bootstrap = "/no/such/file.sql";
      bool ok = false; try { db.connect( c ); } catch( const ToolError& e ) { ok = e.errorClass == ErrorClass::Connectivity && e.message.find( "FSQL_DUCKDB_BOOTSTRAP" ) != std::string::npos; }
      check( ok, "connect: a missing bootstrap file is a clean connectivity error" ); }
    { Db db; EngineConfig c; c.extension = ext; c.allowUnsigned = true; c.database = "/no/such/dir/db.duckdb";
      bool ok = false; try { db.connect( c ); } catch( const ToolError& e ) { ok = e.errorClass == ErrorClass::Connectivity; }
      check( ok, "connect: a database path that cannot be created is a connectivity error" ); }
    { Db db; check( throwsClass( db, ErrorClass::Connectivity, "SELECT 1" ), "query before connect is a connectivity error" ); }
    { EngineConfig c = EngineConfig::fromEnv(); (void)c;
      FSQL_PROBE_SETENV( "FSQL_DUCKDB_READ_ONLY", "true" ); FSQL_PROBE_SETENV( "FSQL_DUCKDB_DATABASE", ":memory:" );
      EngineConfig ro = EngineConfig::fromEnv();
      check( !ro.error.empty(), "config: read-only with an in-memory database is refused" );
      FSQL_PROBE_UNSETENV( "FSQL_DUCKDB_READ_ONLY" ); FSQL_PROBE_UNSETENV( "FSQL_DUCKDB_DATABASE" ); }

    // ---- a real connection: in-memory, the extension loaded, the engine locked down
    std::string boot = probeTempDir() + "/fsql_db_probe_boot_" + std::to_string( FSQL_PROBE_GETPID() ) + ".sql";
    { std::ofstream( boot ) << "CREATE TABLE t AS SELECT i AS id, 'row ' || i AS name FROM range(50) x(i);\n"; }
    EngineConfig cfg; cfg.extension = ext; cfg.allowUnsigned = true; cfg.bootstrap = boot; cfg.lockDown = true;
    Db db;
    try { db.connect( cfg ); }
    catch( const ToolError& e ) { std::printf( "FAIL: connect: %s\n", e.message.c_str() ); return 1; }
    check( db.connected() && db.probeAlive(), "connect: in-memory database with the extension loaded" );
    check( !db.engineVersion().empty(), "the extension answers fractal_version()" );

    // ---- binding, every kind
    check( one( db, "SELECT CAST(? AS BIGINT)", { BindValue::ofInt( 9007199254740993LL ) } ).i == 9007199254740993LL, "bind: a 64-bit integer survives exactly" );
    check( one( db, "SELECT CAST(? AS DOUBLE)", { BindValue::ofNum( 0.1 ) } ).d == 0.1, "bind: a double survives exactly" );
    check( one( db, "SELECT CAST(? AS BOOLEAN)", { BindValue::ofBool( true ) } ).b == true, "bind: a boolean" );
    check( one( db, "SELECT CAST(? AS VARCHAR)", { BindValue::null() } ).kind == Cell::Kind::Null, "bind: NULL comes back NULL" );
    check( one( db, "SELECT CAST(? AS VARCHAR)", { BindValue::ofStr( "it's \"quoted\"; DROP TABLE t; --" ) } ).s == "it's \"quoted\"; DROP TABLE t; --", "bind: an injection-shaped string is data, not SQL" );
    check( one( db, "SELECT count(*) FROM t" ).i == 50, "the injection attempt left the table alone" );
    { std::string big( 1 << 20, 'x' ); check( one( db, "SELECT length(CAST(? AS VARCHAR))", { BindValue::ofStr( big ) } ).i == ( 1 << 20 ), "bind: a 1 MiB string" ); }
    check( one( db, "SELECT list_sum(CAST(? AS DOUBLE[]))", { BindValue::ofNums( { 1, 2, 3.5 } ) } ).d == 6.5, "bind: a list of doubles" );
    check( one( db, "SELECT len(CAST(? AS DOUBLE[]))", { BindValue::ofNums( {} ) } ).i == 0, "bind: an EMPTY list of doubles (this once crashed the process)" );
    check( one( db, "SELECT len(CAST(? AS VARCHAR[]))", { BindValue::ofStrs( {} ) } ).i == 0, "bind: an EMPTY list of strings" );
    check( one( db, "SELECT len(CAST(? AS BIGINT[]))", { BindValue::ofInts( {} ) } ).i == 0, "bind: an EMPTY list of integers" );
    check( one( db, "SELECT len(CAST(? AS BLOB[]))", { BindValue::ofBlobs( {} ) } ).i == 0, "bind: an EMPTY list of blobs" );
    check( one( db, "SELECT list_sum(CAST(? AS BIGINT[]))", { BindValue::ofInts( { 1, 2, 3 } ) } ).i == 6, "bind: a list of integers" );
    check( one( db, "SELECT len(CAST(? AS VARCHAR[]))", { BindValue::ofStrs( { "a", "b" } ) } ).i == 2, "bind: a list of strings" );
    check( one( db, "SELECT octet_length(CAST(? AS BLOB[])[2])", { BindValue::ofBlobs( { std::string( "\x00\x01", 2 ), std::string( "\xff\xfe\xfd", 3 ) } ) } ).i == 3, "bind: a list of blobs keeps NUL and high bytes" );
    check( one( db, "SELECT CAST(? AS DOUBLE[])", { BindValue::ofNums( { 1, 2 } ) } ).kind == Cell::Kind::Text, "decode: a nested type comes back as text" );

    // ---- decoding and row caps
    { QueryResult r = db.query( "SELECT id, name, id * 0.5 AS half, id % 2 = 0 AS even, NULL AS nothing FROM t ORDER BY id", {}, 10 );
      check( r.rows.size() == 10 && r.columns.size() == 5 && r.columns[ 2 ] == "half", "rows: capped at maxRows, columns named" );
      check( r.rows[ 3 ][ 0 ].kind == Cell::Kind::Int && r.rows[ 3 ][ 1 ].s == "row 3" && r.rows[ 3 ][ 2 ].d == 1.5 && r.rows[ 3 ][ 3 ].kind == Cell::Kind::Bool && r.rows[ 3 ][ 4 ].kind == Cell::Kind::Null,
             "decode: int, text, double, boolean and NULL cells" ); }
    check( db.query( "SELECT * FROM t", {} ).rows.size() == 50, "rows: no cap returns everything" );

    // ---- errors come back classified, and the connection survives them
    check( throwsClass( db, ErrorClass::Engine, "SELECT * FROM no_such_table" ), "error: an unknown table is an engine error" );
    check( throwsClass( db, ErrorClass::Engine, "SELEC 1" ), "error: a syntax error is an engine error" );
    check( throwsClass( db, ErrorClass::Engine, "SELECT CAST(? AS INTEGER)", { BindValue::ofStr( "abc" ) } ), "error: a failed cast is an engine error" );
    check( db.probeAlive(), "the connection is still usable after the errors" );

    // ---- the lock-down
    const std::string outCsv = probeTempDir() + "/fsql_db_probe_out.csv";
    const std::string attDb  = probeTempDir() + "/fsql_db_probe_att.duckdb";
    check( throwsClass( db, ErrorClass::Engine, "SELECT * FROM read_csv('/etc/hostname')" ), "lock-down: reading a file is refused" );
    check( throwsClass( db, ErrorClass::Engine, "COPY (SELECT 1) TO '" + outCsv + "'" ), "lock-down: writing a file is refused" );
    check( !FSQL_PROBE_EXISTS( outCsv.c_str() ), "lock-down: and nothing was written" );
    check( throwsClass( db, ErrorClass::Engine, "ATTACH '" + attDb + "' AS other" ), "lock-down: ATTACH is refused" );
    check( throwsClass( db, ErrorClass::Engine, "INSTALL httpfs" ), "lock-down: INSTALL is refused" );
    check( throwsClass( db, ErrorClass::Engine, "SET enable_external_access=true" ), "lock-down: the settings cannot be changed back" );
    check( throwsClass( db, ErrorClass::Engine, "SET threads=1" ), "lock-down: other settings are frozen too" );
    check( one( db, "SELECT count(*) FROM t" ).i == 50, "lock-down: ordinary queries still work" );

    // ---- the database handle is shared, a connection is not
    { Db other; other.connect( cfg );
      check( one( other, "SELECT count(*) FROM t" ).i == 50, "shared handle: a second session sees the same database" );
      db.query( "CREATE TEMP TABLE only_mine AS SELECT 1 AS x", {} );
      check( throwsClass( other, ErrorClass::Engine, "SELECT * FROM only_mine" ), "sessions: a temp table is private to its connection" ); }

    // ---- interrupt
    {
        std::atomic<bool> done{ false }; ErrorClass got = ErrorClass::ServerInternal; bool threw = false;
        std::thread worker( [ & ] {
            // The statement has to be one the optimizer cannot fold away. A plain count(*) over a range() is
            // constant-folded (the function's own statistics give the row count), so it finished before the
            // interrupt could land and there was nothing to cancel. The modulo filter makes the count a real
            // scan, so the statement is still running when the interrupt arrives.
            try { db.query( "SELECT count(*) FROM range(100000000000) AS a(x) WHERE x % 7 = 0", {} ); }
            catch( const ToolError& e ) { threw = true; got = e.errorClass; }
            done = true; } );
        std::this_thread::sleep_for( std::chrono::milliseconds( 300 ) );
        const auto t0 = std::chrono::steady_clock::now();
        db.interrupt();
        for( int i = 0; i < 300 && !done; ++i ) std::this_thread::sleep_for( std::chrono::milliseconds( 100 ) );
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>( std::chrono::steady_clock::now() - t0 ).count();
        const bool finished = done.load();
        if( !finished ) { std::printf( "FAIL: interrupt did not stop the query within 30 s; exiting\n" ); std::fflush( stdout ); FSQL_PROBE_EXIT( 1 ); }
        worker.join();
        // The bound is generous on purpose: what the check is about is that the interrupt STOPS the
        // query and that the engine reports it as a cancellation, not how fast a loaded host gets round
        // to unwinding it. A tight bound here failed on a busy machine that was thrashing, not on a
        // broken engine.
        check( threw && got == ErrorClass::Cancelled && ms < 25000,
               "interrupt: a running query ends as a cancellation (" + std::to_string( (long long) ms ) + " ms, threw=" + std::to_string( (int) threw ) + " class=" + std::to_string( (int) got ) + ")" );
        check( db.probeAlive(), "interrupt: the connection is usable afterwards" );
    }

    db.close();
    check( throwsClass( db, ErrorClass::Connectivity, "SELECT 1" ), "close: a query after close is a connectivity error" );
    std::remove( boot.c_str() );
    std::printf( "db_probe: %d checks, %d failed\n", g_n, g_fail );
    return g_fail ? 1 : 0;
}
