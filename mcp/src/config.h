// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <cctype>
#include <cerrno>
#include <cstdlib>
#include <string>

namespace fsqlmcp
{
    static inline std::string envOr( const char* name, const std::string& def )
    {
        const char* v = std::getenv( name );
        return ( v && *v ) ? std::string( v ) : def;
    }

    // Case-insensitive boolean env reader: true/1/on/yes (any case). Every
    // security-relevant switch (FSQL_MCP_READ_ONLY, HTTP_TLS, ...) goes
    // through this so "True" / "TRUE" / "1" cannot silently leave a
    // protection off.
    static inline bool envBoolOr( const char* name, bool def )
    {
        const char* v = std::getenv( name );
        if( !v || !*v ) return def;
        std::string s( v );
        for( char& c : s ) c = static_cast<char>( ::tolower( static_cast<unsigned char>( c ) ) );
        return s == "true" || s == "1" || s == "on" || s == "yes";
    }
    static inline int envIntOr( const char* name, int def )
    {
        const char* v = std::getenv( name );
        return ( v && *v ) ? std::atoi( v ) : def;
    }

    // A knob that must be a whole number of at least `minValue`. Unset or empty keeps the default; anything
    // else that is not such a number (text, a fraction, a negative, zero where zero would admit nobody) is
    // refused with the variable named. envIntOr's atoi turns "abc" into 0, and a concurrency limit of 0
    // makes every call wait out the whole queue timeout, so those knobs are checked here instead of
    // silently becoming a hang.
    static inline bool envIntAtLeast( const char* name, int def, int minValue, int* out, std::string* err )
    {
        const char* v = std::getenv( name );
        if( !v || !*v ) { *out = def; return true; }
        char* end = nullptr;
        errno = 0;
        const long n = std::strtol( v, &end, 10 );
        if( end == v || *end != '\0' || errno == ERANGE || n < minValue || n > 2147483647L )
        {
            *err = std::string( name ) + " must be a whole number of at least " + std::to_string( minValue )
                   + " (got '" + v + "')";
            return false;
        }
        *out = static_cast<int>( n );
        return true;
    }

    static inline bool envTruthy( const char* name, bool def )
    {
        const char* v = std::getenv( name );
        if( !v || !*v ) return def;
        const std::string s( v );
        return s == "1" || s == "true" || s == "on" || s == "yes";
    }

    // How the server opens DuckDB. The extension runs inside this process, so the database file, the
    // extension and the lock-down below are the whole security surface.
    struct EngineConfig
    {
        std::string database  = ":memory:";   // FSQL_DUCKDB_DATABASE: a file path or :memory:
        std::string extension;                // FSQL_DUCKDB_EXTENSION: a path to fractalsql.duckdb_extension, or empty for LOAD 'fractalsql'
        std::string bootstrap;                // FSQL_DUCKDB_BOOTSTRAP: a SQL file run once after the extension loads, before the lock-down
        bool        readOnly = false;         // FSQL_DUCKDB_READ_ONLY: open the database file read-only
        bool        lockDown = true;          // FSQL_DUCKDB_LOCK_DOWN (default on): no file access, no INSTALL/LOAD, settings frozen
        bool        allowUnsigned = false;    // FSQL_DUCKDB_ALLOW_UNSIGNED: needed for a locally built, unsigned extension file
        std::string memoryLimit;              // FSQL_DUCKDB_MEMORY_LIMIT, e.g. 2GB
        int         threads = 0;              // FSQL_DUCKDB_THREADS (0 = DuckDB's default)

        // FSQL_MCP_READ_ONLY=true also latches the extension's destructive ledger functions per connection.
        bool lockDestructive = false;

        // Empty on success; otherwise the configuration error to print before exiting 2.
        std::string error;

        static EngineConfig fromEnv()
        {
            EngineConfig c;
            c.database  = envOr( "FSQL_DUCKDB_DATABASE", ":memory:" );
            c.extension = envOr( "FSQL_DUCKDB_EXTENSION", "" );
            c.bootstrap = envOr( "FSQL_DUCKDB_BOOTSTRAP", "" );
            c.readOnly  = envTruthy( "FSQL_DUCKDB_READ_ONLY", false );
            c.lockDown  = envTruthy( "FSQL_DUCKDB_LOCK_DOWN", true );
            // A path to an extension file is almost always a local build; a bare name is a signed install.
            c.allowUnsigned = envTruthy( "FSQL_DUCKDB_ALLOW_UNSIGNED", false );
            c.memoryLimit = envOr( "FSQL_DUCKDB_MEMORY_LIMIT", "" );
            std::string e;
            if( !envIntAtLeast( "FSQL_DUCKDB_THREADS", 0, 0, &c.threads, &e ) ) c.error = e;
            else if( c.threads > 1024 ) c.error = "FSQL_DUCKDB_THREADS must be between 0 (DuckDB's default) and 1024 (got " + std::to_string( c.threads ) + ")";
            c.lockDestructive = envBoolOr( "FSQL_MCP_READ_ONLY", false );   // same predicate as ServerConfig::readOnlyMode
            if( c.readOnly && c.database == ":memory:" ) c.error = "FSQL_DUCKDB_READ_ONLY needs FSQL_DUCKDB_DATABASE to name a database file";
            return c;
        }
    };
}
