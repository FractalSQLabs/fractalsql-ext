// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// fractalsql-ext-mcp's connection layer: DuckDB's C API (libduckdb), the FractalSQL extension loaded
// into the process, then the engine locked down so nothing a caller or a model-written statement does
// can read or write a file, install or load another extension, or change a setting. One database handle
// per process; one connection per MCP session (over stdio exactly one), every statement under that
// connection's own mutex.
#pragma once
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <variant>
#include <vector>
#include "config.h"
#include "errors.h"
#include "mcp_json.h"

struct _duckdb_database; struct _duckdb_connection;

namespace fsqlmcp
{
    static const char* const kMcpPluginName       = "fractalsql-ext-mcp";
    static const char* const kEngineVersionExpect = "2.0.0";

    // A value bound to a `?` parameter. Lists are bound as DOUBLE / BIGINT / VARCHAR / BLOB lists and the
    // statement's CAST(? AS ...) narrows them to what the function wants.
    struct BindValue
    {
        enum class Kind { Null, Int, Num, Bool, Str, NumList, IntList, StrList, BlobList } kind = Kind::Null;
        long long                 i = 0;
        double                    d = 0;
        bool                      b = false;
        std::string               s;
        std::vector<double>       nums;
        std::vector<long long>    ints;
        std::vector<std::string>  strs;     // StrList and BlobList (raw bytes)

        static BindValue null() { return {}; }
        static BindValue ofInt( long long v ) { BindValue x; x.kind = Kind::Int; x.i = v; return x; }
        static BindValue ofNum( double v ) { BindValue x; x.kind = Kind::Num; x.d = v; return x; }
        static BindValue ofBool( bool v ) { BindValue x; x.kind = Kind::Bool; x.b = v; return x; }
        static BindValue ofStr( std::string v ) { BindValue x; x.kind = Kind::Str; x.s = std::move( v ); return x; }
        static BindValue ofNums( std::vector<double> v ) { BindValue x; x.kind = Kind::NumList; x.nums = std::move( v ); return x; }
        static BindValue ofInts( std::vector<long long> v ) { BindValue x; x.kind = Kind::IntList; x.ints = std::move( v ); return x; }
        static BindValue ofStrs( std::vector<std::string> v ) { BindValue x; x.kind = Kind::StrList; x.strs = std::move( v ); return x; }
        static BindValue ofBlobs( std::vector<std::string> v ) { BindValue x; x.kind = Kind::BlobList; x.strs = std::move( v ); return x; }
    };

    // One decoded cell: NULL, integer, double, bool or text (everything else, including nested types, as text).
    struct Cell
    {
        enum class Kind { Null, Int, Num, Bool, Text } kind = Kind::Null;
        long long i = 0; double d = 0; bool b = false; std::string s;
        Json toJson() const;
    };

    struct QueryResult
    {
        std::vector<std::string>        columns;
        std::vector<std::vector<Cell>>  rows;
    };

    // Maps an engine error (type tag and text) onto the error taxonomy. Exposed for the probe.
    ToolError classifyEngineError( int duckdbErrorType, const std::string& message );

    struct DbShared;   // the process-wide database handle and its settings

    class Db
    {
    public:
        Db() = default;
        Db( const Db& ) = delete;
        Db& operator=( const Db& ) = delete;
        ~Db() { close(); }

        // Opens (or joins) the process's database, loads the extension, runs the bootstrap, locks the
        // engine down, and prepares this session's connection. Raises Connectivity with a clean message.
        void connect( const EngineConfig& cfg );

        // Runs one parameterised statement and returns up to maxRows rows (0 = no cap). Raises ToolError.
        QueryResult query( const std::string& sql, const std::vector<BindValue>& binds, std::size_t maxRows = 0 );

        // $/cancel: interrupts the statement running on this connection (DuckDB's duckdb_interrupt).
        void interrupt();
        bool connected() const { return con_ != nullptr; }
        bool probeAlive();
        void close() noexcept;
        const EngineConfig& config() const { return cfg_; }
        const std::vector<std::string>& startupWarnings() const { return warnings_; }

        std::string engineVersion();
        void checkVersionSkew( const std::string& expected );

    private:
        EngineConfig                cfg_;
        std::shared_ptr<DbShared>   shared_;
        _duckdb_connection*         con_ = nullptr;
        std::mutex                  mu_;
        std::vector<std::string>    warnings_;
    };
}
