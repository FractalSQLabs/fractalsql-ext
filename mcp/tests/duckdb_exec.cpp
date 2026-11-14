// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// duckdb_exec: a minimal SQL runner on the DuckDB C API, for test setup and for inspecting what the extension
// registered. It exists so the MCP tests need no `duckdb` CLI and no Python package: it links only libduckdb.
//
//   duckdb_exec DATABASE [--ext PATH] [--json] [--ro] -- 'SQL' ['SQL' ...]
//   duckdb_exec DATABASE [--ext PATH] [--json] [--ro] -f file.sql
//
// Prints each result as tab-separated rows (or one JSON array of row objects with --json). Exit 1 on the first error.
#include <duckdb.h>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

static std::string jesc( const std::string& s )
{
    std::string o;
    for( unsigned char c : s )
    {
        if( c == '"' ) o += "\\\""; else if( c == '\\' ) o += "\\\\"; else if( c == '\n' ) o += "\\n";
        else if( c == '\t' ) o += "\\t"; else if( c == '\r' ) o += "\\r"; else if( c < 0x20 ) { char b[ 8 ]; std::snprintf( b, sizeof b, "\\u%04x", c ); o += b; }
        else o += static_cast<char>( c );
    }
    return o;
}

int main( int argc, char** argv )
{
    if( argc < 3 ) { std::fprintf( stderr, "usage: duckdb_exec DATABASE [--ext PATH] [--json] [--ro] (-f FILE | -- SQL...)\n" ); return 2; }
    const std::string path = argv[ 1 ];
    std::string ext, file; bool json = false, ro = false; std::vector<std::string> sqls;
    for( int i = 2; i < argc; ++i )
    {
        const std::string a = argv[ i ];
        if( a == "--ext" && i + 1 < argc ) ext = argv[ ++i ];
        else if( a == "--json" ) json = true;
        else if( a == "--ro" ) ro = true;
        else if( a == "-f" && i + 1 < argc ) file = argv[ ++i ];
        else if( a == "--" ) { for( ++i; i < argc; ++i ) sqls.push_back( argv[ i ] ); }
    }
    if( !file.empty() ) { std::ifstream in( file ); std::stringstream ss; ss << in.rdbuf(); sqls.insert( sqls.begin(), ss.str() ); }

    duckdb_config cfg = nullptr;
    duckdb_create_config( &cfg );
    duckdb_set_config( cfg, "allow_unsigned_extensions", "true" );
    if( ro ) duckdb_set_config( cfg, "access_mode", "READ_ONLY" );
    duckdb_database db = nullptr; char* err = nullptr;
    if( duckdb_open_ext( path == ":memory:" ? nullptr : path.c_str(), &db, cfg, &err ) != DuckDBSuccess )
    { std::fprintf( stderr, "open failed: %s\n", err ? err : "?" ); return 1; }
    duckdb_destroy_config( &cfg );
    duckdb_connection con = nullptr;
    duckdb_connect( db, &con );
    auto run = [ & ]( const std::string& sql ) -> bool
    {
        duckdb_result res;
        if( duckdb_query( con, sql.c_str(), &res ) != DuckDBSuccess )
        { std::fprintf( stderr, "ERROR: %s\n", duckdb_result_error( &res ) ); duckdb_destroy_result( &res ); return false; }
        const idx_t cols = duckdb_column_count( &res ), rows = duckdb_row_count( &res );
        if( json ) std::printf( "[" );
        for( idx_t r = 0; r < rows; ++r )
        {
            if( json ) std::printf( "%s{", r ? "," : "" );
            for( idx_t c = 0; c < cols; ++c )
            {
                char* v = duckdb_value_varchar( &res, c, r );
                if( json ) std::printf( "%s\"%s\":%s%s%s", c ? "," : "", jesc( duckdb_column_name( &res, c ) ).c_str(),
                                         v ? "\"" : "", v ? jesc( v ).c_str() : "null", v ? "\"" : "" );
                else std::printf( "%s%s", c ? "\t" : "", v ? v : "NULL" );
                if( v ) duckdb_free( v );
            }
            if( json ) std::printf( "}" ); else std::printf( "\n" );
        }
        if( json ) std::printf( "]\n" );
        duckdb_destroy_result( &res );
        return true;
    };
    if( !ext.empty() && !run( "LOAD '" + ext + "'" ) ) return 1;
    for( const std::string& s : sqls ) if( !run( s ) ) return 1;
    duckdb_disconnect( &con ); duckdb_close( &db );
    return 0;
}
