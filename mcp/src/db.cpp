// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "db.h"
#include <optional>
#include "logging.h"
#include <duckdb.h>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <thread>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>

namespace fsqlmcp
{
    // The process-wide database. Every session's connection shares it, so a file database is opened once
    // (DuckDB allows one read-write opener per file) and the extension, the bootstrap and the lock-down
    // happen exactly once, before the first session runs anything.
    struct DbShared
    {
        duckdb_database db = nullptr;
        std::string     key;

        // The extension keeps connections of its own for the functions that run SQL on this database, and its
        // documented host contract is to release them before the database is closed: the engine's shutdown then
        // runs on this thread (checkpoint, close, unlock). Without the release the extension's host-departure
        // monitor closes them from its own thread while this process tears the database down, which crashes the
        // process at exit (a release build masks it; a sanitizer build names it).
        ~DbShared()
        {
            if( !db ) return;
            duckdb_connection rel = nullptr;
            if( duckdb_connect( db, &rel ) == DuckDBSuccess )
            {
                duckdb_result r;
                if( duckdb_query( rel, "SELECT fractal_release()", &r ) == DuckDBSuccess ) duckdb_destroy_result( &r );
                duckdb_disconnect( &rel );
            }
            duckdb_close( &db );
        }
    };

    static std::mutex                 g_sharedMu;
    static std::weak_ptr<DbShared>    g_shared;

    Json Cell::toJson() const
    {
        switch( kind )
        {
            case Kind::Null: return nullptr;
            case Kind::Int:  return i;
            case Kind::Num:  return d;
            case Kind::Bool: return b;
            case Kind::Text: return s;
        }
        return nullptr;
    }

    static std::string lower( std::string s ) { for( char& c : s ) c = static_cast<char>( std::tolower( static_cast<unsigned char>( c ) ) ); return s; }

    ToolError classifyEngineError( int type, const std::string& message )
    {
        const std::string m = lower( message );
        if( type == DUCKDB_ERROR_INTERRUPT || m.find( "interrupted" ) != std::string::npos )
            return ToolError( ErrorClass::Cancelled, "call was cancelled by the client" );
        if( type == DUCKDB_ERROR_OUT_OF_MEMORY )
            return ToolError( ErrorClass::Engine, "the engine ran out of memory: " + sanitizeSecrets( message ) );
        if( m.find( "database has been invalidated" ) != std::string::npos || m.find( "database was shut down" ) != std::string::npos
            || m.find( "connection was closed" ) != std::string::npos )
            return ToolError( ErrorClass::Connectivity, sanitizeSecrets( message ) );
        if( m.find( "could not connect" ) != std::string::npos || m.find( "connection refused" ) != std::string::npos
            || m.find( "timed out" ) != std::string::npos || m.find( "http error" ) != std::string::npos )
            return ToolError( ErrorClass::Connectivity, sanitizeSecrets( message ) );
        // A binder/parser/catalog/IO/permission error: the call reached the engine and was refused.
        return ToolError( ErrorClass::Engine, sanitizeSecrets( message ) );
    }

    static std::string sqlQuote( const std::string& s )
    {
        std::string o = "'";
        for( char c : s ) { if( c == '\'' ) o += "''"; else o.push_back( c ); }
        return o + "'";
    }

    // Runs one statement that needs no parameters; throws a classified ToolError on failure.
    static void execPlain( duckdb_connection con, const std::string& sql )
    {
        duckdb_result res;
        if( duckdb_query( con, sql.c_str(), &res ) != DuckDBSuccess )
        {
            const std::string msg = duckdb_result_error( &res ) ? duckdb_result_error( &res ) : "unknown error";
            const int t = static_cast<int>( duckdb_result_error_type( &res ) );
            duckdb_destroy_result( &res );
            throw classifyEngineError( t, msg );
        }
        duckdb_destroy_result( &res );
    }

    void Db::connect( const EngineConfig& cfg )
    {
        std::lock_guard<std::mutex> lk( mu_ );
        cfg_ = cfg;
        close();
        const std::string key = cfg.database + "|" + cfg.extension + "|" + ( cfg.readOnly ? "ro" : "rw" );

        std::lock_guard<std::mutex> sl( g_sharedMu );
        std::shared_ptr<DbShared> sh = g_shared.lock();
        if( sh && sh->key != key )
            throw ToolError( ErrorClass::Connectivity, "a different database is already open in this process" );
        if( !sh )
        {
            duckdb_config dc = nullptr;
            duckdb_create_config( &dc );
            if( cfg.allowUnsigned ) duckdb_set_config( dc, "allow_unsigned_extensions", "true" );
            if( cfg.readOnly )      duckdb_set_config( dc, "access_mode", "READ_ONLY" );
            if( !cfg.memoryLimit.empty() ) duckdb_set_config( dc, "memory_limit", cfg.memoryLimit.c_str() );
            if( cfg.threads > 0 )   duckdb_set_config( dc, "threads", std::to_string( cfg.threads ).c_str() );
            auto fresh = std::make_shared<DbShared>();
            fresh->key = key;
            char* err = nullptr;
            const bool inMemory = cfg.database == ":memory:";
            if( duckdb_open_ext( inMemory ? nullptr : cfg.database.c_str(), &fresh->db, dc, &err ) != DuckDBSuccess )
            {
                const std::string msg = err ? err : "cannot open the database";
                if( err ) duckdb_free( err );
                duckdb_destroy_config( &dc );
                throw ToolError( ErrorClass::Connectivity, "cannot open DuckDB database '" + cfg.database + "': " + sanitizeSecrets( msg ) );
            }
            duckdb_destroy_config( &dc );

            // The one-time setup runs on its own connection, before any session exists.
            duckdb_connection setup = nullptr;
            if( duckdb_connect( fresh->db, &setup ) != DuckDBSuccess )
                throw ToolError( ErrorClass::Connectivity, "cannot connect to the DuckDB database" );
            try
            {
                // Failures are captured in the catch and thrown after it: a new exception thrown inside a catch
                // funclet crashes the Windows MSVC ASan runtime.
                std::optional<std::string> failure;
                try { execPlain( setup, cfg.extension.empty() ? std::string( "LOAD 'fractalsql'" ) : "LOAD " + sqlQuote( cfg.extension ) ); }
                catch( const ToolError& e ) { failure = e.message; }
                if( failure )
                    throw ToolError( ErrorClass::Connectivity, "failed to load the FractalSQL extension '"
                                     + ( cfg.extension.empty() ? std::string( "fractalsql" ) : cfg.extension ) + "': " + *failure );
                if( !cfg.bootstrap.empty() )
                {
                    std::ifstream in( cfg.bootstrap );
                    if( !in ) throw ToolError( ErrorClass::Connectivity, "cannot read FSQL_DUCKDB_BOOTSTRAP file '" + cfg.bootstrap + "'" );
                    std::stringstream ss; ss << in.rdbuf();
                    failure.reset();
                    try { execPlain( setup, ss.str() ); }
                    catch( const ToolError& e ) { failure = e.message; }
                    if( failure ) throw ToolError( ErrorClass::Connectivity, "the bootstrap SQL failed: " + *failure );
                }
                if( cfg.lockDown )
                {
                    // After this the engine cannot touch a file, fetch or load an extension, or have a setting
                    // changed, whoever asks: a tool argument, or SQL a model wrote.
                    execPlain( setup, "SET autoinstall_known_extensions=false" );
                    execPlain( setup, "SET autoload_known_extensions=false" );
                    execPlain( setup, "SET enable_external_access=false" );
                    execPlain( setup, "SET lock_configuration=true" );
                }
            }
            catch( ... ) { duckdb_disconnect( &setup ); throw; }
            duckdb_disconnect( &setup );
            g_shared = fresh;
            sh = fresh;
        }
        shared_ = sh;
        if( duckdb_connect( shared_->db, &con_ ) != DuckDBSuccess )
        {
            con_ = nullptr;
            throw ToolError( ErrorClass::Connectivity, "cannot connect to the DuckDB database" );
        }
        if( cfg.lockDestructive )
        {
            try { execPlain( con_, "SELECT fractal_lock_destructive()" ); }
            catch( const std::exception& e )
            {
                warnings_.push_back( std::string( "FSQL_MCP_READ_ONLY: engine-side destructive latch not applied (server-side refusal still active): " ) + e.what() );
                std::cerr << "WARN: " << warnings_.back() << "\n";
            }
        }
    }

    void Db::close() noexcept
    {
        if( con_ ) { duckdb_connection c = con_; duckdb_disconnect( &c ); con_ = nullptr; }
        shared_.reset();
    }

    static duckdb_value makeList( duckdb_type elem, const std::vector<duckdb_value>& vals )
    {
        duckdb_logical_type lt = duckdb_create_logical_type( elem );
        // An empty vector's data() is null, and duckdb_create_list_value dereferences it even for zero elements:
        // hand it a valid pointer so an empty list reaches the engine, which reports its own clean error.
        duckdb_value none = nullptr;
        duckdb_value l = duckdb_create_list_value( lt, vals.empty() ? &none : const_cast<duckdb_value*>( vals.data() ), vals.size() );
        duckdb_destroy_logical_type( &lt );
        return l;
    }

    static duckdb_state bindOne( duckdb_prepared_statement st, idx_t pos, const BindValue& v )
    {
        using K = BindValue::Kind;
        switch( v.kind )
        {
            case K::Null: return duckdb_bind_null( st, pos );
            case K::Int:  return duckdb_bind_int64( st, pos, v.i );
            case K::Num:  return duckdb_bind_double( st, pos, v.d );
            case K::Bool: return duckdb_bind_boolean( st, pos, v.b );
            case K::Str:  return duckdb_bind_varchar_length( st, pos, v.s.data(), v.s.size() );
            case K::NumList: case K::IntList: case K::StrList: case K::BlobList:
            {
                std::vector<duckdb_value> es;
                duckdb_type et = DUCKDB_TYPE_DOUBLE;
                if( v.kind == K::NumList )  { et = DUCKDB_TYPE_DOUBLE;  for( double x : v.nums )     es.push_back( duckdb_create_double( x ) ); }
                if( v.kind == K::IntList )  { et = DUCKDB_TYPE_BIGINT;  for( long long x : v.ints )  es.push_back( duckdb_create_int64( x ) ); }
                if( v.kind == K::StrList )  { et = DUCKDB_TYPE_VARCHAR; for( const auto& x : v.strs ) es.push_back( duckdb_create_varchar_length( x.data(), x.size() ) ); }
                if( v.kind == K::BlobList ) { et = DUCKDB_TYPE_BLOB;    for( const auto& x : v.strs ) es.push_back( duckdb_create_blob( reinterpret_cast<const uint8_t*>( x.data() ), x.size() ) ); }
                duckdb_value list = makeList( et, es );
                for( duckdb_value& e : es ) duckdb_destroy_value( &e );
                const duckdb_state rc = duckdb_bind_value( st, pos, list );
                duckdb_destroy_value( &list );
                return rc;
            }
        }
        return DuckDBError;
    }

    static Cell decodeCell( duckdb_result* res, idx_t col, idx_t row )
    {
        Cell c;
        if( duckdb_value_is_null( res, col, row ) ) return c;
        switch( duckdb_column_type( res, col ) )
        {
            case DUCKDB_TYPE_BOOLEAN: c.kind = Cell::Kind::Bool; c.b = duckdb_value_boolean( res, col, row ); return c;
            case DUCKDB_TYPE_TINYINT: case DUCKDB_TYPE_SMALLINT: case DUCKDB_TYPE_INTEGER: case DUCKDB_TYPE_BIGINT:
            case DUCKDB_TYPE_UTINYINT: case DUCKDB_TYPE_USMALLINT: case DUCKDB_TYPE_UINTEGER: case DUCKDB_TYPE_UBIGINT:
            case DUCKDB_TYPE_HUGEINT: case DUCKDB_TYPE_UHUGEINT:
            {
                // Wider than 64 bits: keep the exact digits as text when the value does not fit.
                char* txt = duckdb_value_varchar( res, col, row );
                const std::string digits = txt ? txt : "";
                if( txt ) duckdb_free( txt );
                errno = 0;
                char* end = nullptr;
                const long long v = std::strtoll( digits.c_str(), &end, 10 );
                if( !digits.empty() && *end == '\0' && errno != ERANGE ) { c.kind = Cell::Kind::Int; c.i = v; }
                else { c.kind = Cell::Kind::Text; c.s = digits; }
                return c;
            }
            case DUCKDB_TYPE_FLOAT: case DUCKDB_TYPE_DOUBLE: case DUCKDB_TYPE_DECIMAL:
                c.kind = Cell::Kind::Num; c.d = duckdb_value_double( res, col, row ); return c;
            default: break;
        }
        char* v = duckdb_value_varchar( res, col, row );
        c.kind = Cell::Kind::Text;
        if( v ) { c.s = v; duckdb_free( v ); }
        return c;
    }

    namespace
    {
        // Statement timeout: a runaway statement holds the connection, and its session, until it
        // ends. FSQL_MCP_STATEMENT_TIMEOUT_MS (default 600000 = 10 min, generous because reasoning calls run
        // inside SQL; 0 disables) interrupts it with duckdb_interrupt, the same call $/cancel uses.
        long statementTimeoutMs()
        {
            const char* v = std::getenv( "FSQL_MCP_STATEMENT_TIMEOUT_MS" );
            if( !v || !*v ) return 600000;
            const long n = std::atol( v );
            return n < 0 ? 600000 : n;
        }

        class StatementWatchdog
        {
        public:
            StatementWatchdog( duckdb_connection c, long ms ) : c_( c )
            {
                if( ms <= 0 ) return;
                t_ = std::thread( [ this, ms ] {
                    std::unique_lock<std::mutex> lk( m_ );
                    if( !cv_.wait_for( lk, std::chrono::milliseconds( ms ), [ this ] { return done_; } ) )
                    {
                        fired_ = true;
                        duckdb_interrupt( c_ );
                    }
                } );
            }
            ~StatementWatchdog()
            {
                { std::lock_guard<std::mutex> lk( m_ ); done_ = true; }
                cv_.notify_all();
                if( t_.joinable() ) t_.join();
            }
            StatementWatchdog( const StatementWatchdog& ) = delete;
            StatementWatchdog& operator=( const StatementWatchdog& ) = delete;
            bool fired() const { return fired_.load(); }

        private:
            duckdb_connection       c_;
            std::mutex              m_;
            std::condition_variable cv_;
            bool                    done_ = false;
            std::atomic<bool>       fired_{ false };
            std::thread             t_;
        };
    }

    QueryResult Db::query( const std::string& sql, const std::vector<BindValue>& binds, std::size_t maxRows )
    {
        std::lock_guard<std::mutex> lk( mu_ );
        if( !con_ ) throw ToolError( ErrorClass::Connectivity, "the database connection is not open" );
        duckdb_prepared_statement st = nullptr;
        if( duckdb_prepare( con_, sql.c_str(), &st ) != DuckDBSuccess )
        {
            const std::string msg = duckdb_prepare_error( st ) ? duckdb_prepare_error( st ) : "prepare failed";
            duckdb_destroy_prepare( &st );
            throw classifyEngineError( static_cast<int>( DUCKDB_ERROR_INVALID_INPUT ), msg );
        }
        for( std::size_t i = 0; i < binds.size(); ++i )
        {
            if( bindOne( st, static_cast<idx_t>( i + 1 ), binds[ i ] ) != DuckDBSuccess )
            {
                const std::string msg = duckdb_prepare_error( st ) ? duckdb_prepare_error( st ) : "bind failed";
                duckdb_destroy_prepare( &st );
                throw ToolError( ErrorClass::ServerInternal, "engine parameter bind failed: " + sanitizeSecrets( msg ) );
            }
        }
        duckdb_result res;
        StatementWatchdog watchdog( con_, statementTimeoutMs() );
        if( duckdb_execute_prepared( st, &res ) != DuckDBSuccess )
        {
            const std::string msg = duckdb_result_error( &res ) ? duckdb_result_error( &res ) : "execution failed";
            const int t = static_cast<int>( duckdb_result_error_type( &res ) );
            duckdb_destroy_result( &res );
            duckdb_destroy_prepare( &st );
            if( watchdog.fired() )
                throw ToolError( ErrorClass::Connectivity,
                                 "the statement exceeded FSQL_MCP_STATEMENT_TIMEOUT_MS and was interrupted" );
            throw classifyEngineError( t, msg );
        }
        QueryResult out;
        const idx_t cols = duckdb_column_count( &res ), rows = duckdb_row_count( &res );
        for( idx_t c = 0; c < cols; ++c ) out.columns.emplace_back( duckdb_column_name( &res, c ) );
        const idx_t take = ( maxRows > 0 && rows > maxRows ) ? static_cast<idx_t>( maxRows ) : rows;
        out.rows.reserve( take );
        for( idx_t r = 0; r < take; ++r )
        {
            std::vector<Cell> row; row.reserve( cols );
            for( idx_t c = 0; c < cols; ++c ) row.push_back( decodeCell( &res, c, r ) );
            out.rows.push_back( std::move( row ) );
        }
        duckdb_destroy_result( &res );
        duckdb_destroy_prepare( &st );
        return out;
    }

    void Db::interrupt()
    {
        // Not under mu_: the statement being interrupted holds it. duckdb_interrupt is safe from any thread.
        duckdb_connection c = con_;
        if( c ) duckdb_interrupt( c );
    }

    bool Db::probeAlive()
    {
        try { return !query( "SELECT 1", {} ).rows.empty(); } catch( ... ) { return false; }
    }

    std::string Db::engineVersion()
    {
        try
        {
            QueryResult r = query( "SELECT fractal_version()", {} );
            if( !r.rows.empty() && r.rows[ 0 ][ 0 ].kind == Cell::Kind::Text ) return r.rows[ 0 ][ 0 ].s;
        }
        catch( const ToolError& ) {}
        return {};
    }

    void Db::checkVersionSkew( const std::string& expected )
    {
        if( expected.empty() ) return;
        const std::string got = engineVersion();
        if( got.empty() ) std::cerr << "WARN: the FractalSQL extension did not answer fractal_version(); is it loaded?\n";
        else if( got != expected ) std::cerr << "WARN: version skew: extension " << got << " vs this server built for " << expected << "\n";
    }
}
