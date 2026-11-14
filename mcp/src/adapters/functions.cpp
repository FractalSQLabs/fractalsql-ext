// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
//
// The tool catalog. It is data, not code: tools.spec.json (compiled in as tools_spec.inc) lists every function the
// extension registers with its parameters and how each is bound and returned. ONE encoder turns a tool call into a
// prepared statement with an explicit CAST on every parameter, so DuckDB resolves the right overload; ONE decoder
// turns the result back into JSON (structs, lists and table functions go through to_json). A function is added
// by adding a spec entry.
#include "functions.h"
#include "admin.h"
#include <cmath>
#include <deque>
#include <map>
#include <set>
#include "../vectors.h"
#include "../logging.h"
#include "../version.h"
#include "tools_spec.inc"

namespace fsqlmcp
{
namespace
{
    struct SpecParam
    {
        std::string name, type, duck, desc;
        bool        required = true, named = false;
        Json        def = nullptr;
        std::vector<std::string> needs;   // other parameters that must be given whenever this one is
    };
    struct SpecTool
    {
        std::string name, category, kind, cls, out, ret, desc;
        bool        readOnly = true, destructive = false, openWorld = false;
        bool        secret = false;   // args/result may carry content a client should not echo or log casually
        std::vector<SpecParam> params;
        bool        rows() const { return kind == "table"; }
    };

    constexpr std::size_t kMaxElems = 4u << 20;
    constexpr std::size_t kMaxText  = 4u << 20;

    std::deque<SpecTool>& specs()
    {
        static std::deque<SpecTool> v = []
        {
            std::deque<SpecTool> out;
            const Json j = Json::parse( kToolsSpecJson );
            for( const Json& t : j.at( "tools" ) )
            {
                SpecTool s;
                s.name = t.at( "name" ); s.category = t.at( "category" ); s.kind = t.at( "kind" ); s.cls = t.at( "class" );
                s.out = t.at( "out" ); s.ret = t.value( "ret", std::string() ); s.desc = t.at( "desc" );
                s.readOnly = t.at( "readOnly" ); s.destructive = t.at( "destructive" ); s.openWorld = t.at( "openWorld" );
                s.secret = t.value( "secret", false );
                for( const Json& p : t.at( "params" ) )
                {
                    SpecParam q;
                    q.name = p.at( "name" ); q.type = p.at( "type" ); q.duck = p.at( "duck" ); q.desc = p.value( "desc", std::string() );
                    q.required = p.at( "required" ); q.named = p.value( "named", false );
                    q.def = p.contains( "default" ) ? p.at( "default" ) : Json( nullptr );
                    if( p.contains( "needs" ) ) for( const Json& n : p.at( "needs" ) ) q.needs.push_back( n.get<std::string>() );
                    s.params.push_back( std::move( q ) );
                }
                out.push_back( std::move( s ) );
            }
            return out;
        }();
        return v;
    }

    // ------------------------------------------------------------------ encoding
    double finiteNumber( const Json& raw, const std::string& what )
    {
        const Json e = vectors::coerceNumber( raw );
        if( !e.is_number() || e.is_boolean() || !std::isfinite( e.get<double>() ) )
            throw ToolError( ErrorClass::Schema, what + " contains a non-numeric or non-finite element: " + raw.dump().substr( 0, 40 ) );
        return e.get<double>();
    }

    // A flat array, or rows of equal width (flattened; the width is returned through `width`, 0 when flat).
    std::vector<double> numList( const Json& v, const std::string& name, std::size_t& width )
    {
        width = 0;
        if( !v.is_array() ) throw ToolError( ErrorClass::Schema, name + " must be a JSON array of numbers" );
        if( v.empty() ) throw ToolError( ErrorClass::Schema, name + " must not be an empty array" );
        std::vector<double> out;
        if( !v[ 0 ].is_array() )
        {
            if( v.size() > kMaxElems ) throw ToolError( ErrorClass::Schema, name + " has too many elements" );
            out.reserve( v.size() );
            for( const Json& e : v ) out.push_back( finiteNumber( e, name ) );
            return out;
        }
        for( std::size_t r = 0; r < v.size(); ++r )
        {
            const Json& row = v[ r ];
            if( !row.is_array() || row.empty() ) throw ToolError( ErrorClass::Schema, name + " row " + std::to_string( r ) + " must be a non-empty array of numbers" );
            if( r == 0 ) width = row.size();
            else if( row.size() != width )
                throw ToolError( ErrorClass::Schema, name + " row " + std::to_string( r ) + " has " + std::to_string( row.size() ) + " values, expected " + std::to_string( width ) );
            if( out.size() + row.size() > kMaxElems ) throw ToolError( ErrorClass::Schema, name + " has too many elements" );
            for( const Json& e : row ) out.push_back( finiteNumber( e, name ) );
        }
        return out;
    }

    std::string hexToBytes( const std::string& h, const std::string& name )
    {
        if( h.empty() || h.size() % 2 != 0 ) throw ToolError( ErrorClass::Schema, name + " must be a non-empty hex string of even length" );
        auto nib = [ & ]( char c ) -> int
        {
            if( c >= '0' && c <= '9' ) return c - '0';
            if( c >= 'a' && c <= 'f' ) return c - 'a' + 10;
            if( c >= 'A' && c <= 'F' ) return c - 'A' + 10;
            throw ToolError( ErrorClass::Schema, name + " is not valid hex" );
        };
        std::string out;
        for( std::size_t i = 0; i < h.size(); i += 2 ) out.push_back( static_cast<char>( ( nib( h[ i ] ) << 4 ) | nib( h[ i + 1 ] ) ) );
        return out;
    }

    // One provided argument -> a bind value and the SQL fragment that receives it.
    BindValue encode( const SpecParam& p, const Json& v, std::string& frag, std::map<std::string, std::size_t>& widths )
    {
        const std::string cast = "CAST(? AS " + p.duck + ")";
        frag = cast;
        if( p.type == "str" )
        {
            if( !v.is_string() ) throw ToolError( ErrorClass::Schema, p.name + " must be a string" );
            if( v.get<std::string>().size() > kMaxText ) throw ToolError( ErrorClass::Schema, p.name + " is too long" );
            return BindValue::ofStr( v.get<std::string>() );
        }
        if( p.type == "json" || p.type == "jsonstr" )
        {
            if( v.is_string() ) return BindValue::ofStr( v.get<std::string>() );
            std::string t = v.dump();
            if( t.size() > kMaxText ) throw ToolError( ErrorClass::Schema, p.name + " is too long" );
            return BindValue::ofStr( std::move( t ) );
        }
        if( p.type == "int" )
        {
            if( !v.is_number_integer() ) throw ToolError( ErrorClass::Schema, p.name + " must be an integer" );
            return BindValue::ofInt( v.get<long long>() );
        }
        if( p.type == "num" ) return BindValue::ofNum( finiteNumber( v, p.name ) );
        if( p.type == "bool" )
        {
            if( !v.is_boolean() ) throw ToolError( ErrorClass::Schema, p.name + " must be true or false" );
            return BindValue::ofBool( v.get<bool>() );
        }
        if( p.type == "vec" )
        {
            std::size_t w = 0;
            std::vector<double> nums = numList( v, p.name, w );
            widths[ p.name ] = w;
            return BindValue::ofNums( std::move( nums ) );
        }
        if( p.type == "ints" )
        {
            if( !v.is_array() || v.empty() ) throw ToolError( ErrorClass::Schema, p.name + " must be a non-empty JSON array of integers" );
            if( v.size() > kMaxElems ) throw ToolError( ErrorClass::Schema, p.name + " has too many elements" );
            std::vector<long long> out;
            for( const Json& e : v )
            {
                if( !e.is_number_integer() || e.get<long long>() < 0 ) throw ToolError( ErrorClass::Schema, p.name + " must contain non-negative integers" );
                out.push_back( e.get<long long>() );
            }
            return BindValue::ofInts( std::move( out ) );
        }
        if( p.type == "strs" )
        {
            if( !v.is_array() ) throw ToolError( ErrorClass::Schema, p.name + " must be a JSON array of strings" );
            std::vector<std::string> out;
            for( const Json& e : v ) { if( !e.is_string() ) throw ToolError( ErrorClass::Schema, p.name + " must contain only strings" ); out.push_back( e.get<std::string>() ); }
            return BindValue::ofStrs( std::move( out ) );
        }
        if( p.type == "hex" )
        {
            if( !v.is_string() ) throw ToolError( ErrorClass::Schema, p.name + " must be a hex string" );
            hexToBytes( v.get<std::string>(), p.name );              // validates
            frag = "unhex(?)";
            return BindValue::ofStr( v.get<std::string>() );
        }
        if( p.type == "hexlist" )
        {
            if( !v.is_array() || v.empty() ) throw ToolError( ErrorClass::Schema, p.name + " must be a non-empty array of hex strings" );
            std::vector<std::string> out;
            for( const Json& e : v ) { if( !e.is_string() ) throw ToolError( ErrorClass::Schema, p.name + " must contain only hex strings" ); out.push_back( hexToBytes( e.get<std::string>(), p.name ) ); }
            return BindValue::ofBlobs( std::move( out ) );
        }
        throw ToolError( ErrorClass::ServerInternal, "unknown parameter type '" + p.type + "' in the tool spec" );
    }

    JsonType jsonTypeOf( const SpecParam& p )
    {
        if( p.type == "str" || p.type == "hex" ) return JsonType::String;
        if( p.type == "int" ) return JsonType::Integer;
        if( p.type == "num" ) return JsonType::Number;
        if( p.type == "bool" ) return JsonType::Boolean;
        if( p.type == "json" ) return JsonType::Object;
        if( p.type == "jsonstr" ) return JsonType::String;
        return JsonType::Array;
    }

    // The element kind of an array parameter, by the spec's parameter type.
    // A vector argument is accepted either as a flat list of numbers or as
    // the rows of a matrix (see numList), so its elements are a number or an
    // array of numbers; the schema says so, and the validator holds to it.
    JsonType itemTypeOf( const SpecParam& p )
    {
        if( p.type == "ints" ) return JsonType::Integer;
        if( p.type == "strs" || p.type == "hexlist" ) return JsonType::String;
        return JsonType::NumberOrArray;
    }

    // ------------------------------------------------------------------ decoding
    Json parseOrText( const std::string& s )
    {
        try { return Json::parse( s ); } catch( ... ) { return Json{ { "text", s } }; }
    }

    Json wrapNonObject( Json v, const SpecTool& t )
    {
        if( v.is_object() ) return v;
        if( v.is_array() )
        {
            const bool vec = t.name.rfind( "fractal_vector_", 0 ) == 0 || t.name == "fractal_embed" || t.name == "fractal_search";
            if( vec ) return Json{ { "vector", v }, { "dim", v.size() } };
            return Json{ { "items", v } };
        }
        return Json{ { "value", std::move( v ) } };
    }

    Json decode( const SpecTool& t, const QueryResult& r, bool truncated )
    {
        if( t.rows() )
        {
            Json rows = Json::array();
            for( const auto& row : r.rows )
                if( !row.empty() ) rows.push_back( row[ 0 ].kind == Cell::Kind::Text ? parseOrText( row[ 0 ].s ) : row[ 0 ].toJson() );
            Json out{ { "rows", rows }, { "row_count", rows.size() } };
            if( truncated ) out[ "truncated" ] = true;
            return out;
        }
        if( r.rows.empty() || r.rows[ 0 ].empty() ) return Json{ { "value", nullptr } };
        const Cell& c = r.rows[ 0 ][ 0 ];
        if( t.out == "hex" )
        {
            if( c.kind == Cell::Kind::Null ) return Json{ { "value", nullptr } };
            return Json{ { "hex", c.s }, { "bytes", c.s.size() / 2 } };
        }
        if( t.out == "scalar" ) return Json{ { "value", c.toJson() } };
        if( t.out == "text" ) return Json{ { c.kind == Cell::Kind::Text ? "text" : "value", c.toJson() } };
        if( c.kind == Cell::Kind::Null ) return Json{ { "value", nullptr } };
        if( c.kind != Cell::Kind::Text ) return Json{ { "value", c.toJson() } };
        if( t.out == "json_text" ) { Json j = parseOrText( c.s ); return j.is_object() ? j : wrapNonObject( std::move( j ), t ); }
        // native: to_json() text of a struct, list or number
        try { return wrapNonObject( Json::parse( c.s ), t ); } catch( ... ) { return Json{ { "text", c.s } }; }
    }

    // ------------------------------------------------------------------ the handler
    Json run( Db& db, const SpecTool& t, const Json& args, const RowLimitConfig& rowCfg )
    {
        if( t.kind == "custom" )
        {
            // fractal_version: one tool for what the extension reports as two functions, matching the other editions.
            QueryResult r = db.query( "SELECT fractal_version(), fractal_edition(), version()", {} );
            Json out{ { "plugin", kMcpPluginName }, { "plugin_version", FSQL_MCP_VERSION } };
            if( !r.rows.empty() && r.rows[ 0 ].size() >= 3 )
            {
                out[ "version" ] = r.rows[ 0 ][ 0 ].toJson();
                out[ "edition" ] = r.rows[ 0 ][ 1 ].toJson();
                out[ "duckdb_version" ] = r.rows[ 0 ][ 2 ].toJson();
            }
            return out;
        }
        std::map<std::string, std::size_t> widths;
        std::map<std::string, std::pair<std::string, BindValue>> provided;     // name -> (fragment, value)
        for( const SpecParam& p : t.params )
        {
            if( !args.contains( p.name ) ) continue;
            std::string frag;
            BindValue bv = encode( p, args.at( p.name ), frag, widths );
            provided.emplace( p.name, std::make_pair( frag, std::move( bv ) ) );
        }
        // Some arguments only make sense together (a filter column without its value would make the extension read a null).
        for( const SpecParam& p : t.params )
            if( provided.count( p.name ) )
                for( const std::string& n : p.needs )
                    if( !provided.count( n ) ) throw ToolError( ErrorClass::Schema, p.name + " requires " + n + " to be given as well" );
        // A width the caller did not give is taken from nested rows if there were any.
        for( const SpecParam& p : t.params )
        {
            if( p.name != "dim" || provided.count( "dim" ) ) continue;
            std::size_t w = 0;
            for( const auto& kv : widths ) if( kv.second > 0 ) { w = kv.second; break; }
            if( w == 0 ) throw ToolError( ErrorClass::Schema, "dim is required when the points are a flat array (nested rows carry their own width)" );
            std::string frag = "CAST(? AS " + p.duck + ")";
            provided.emplace( "dim", std::make_pair( frag, BindValue::ofInt( static_cast<long long>( w ) ) ) );
        }
        std::vector<BindValue> binds;
        std::string argSql;
        auto push = [ & ]( const std::string& pre, const std::string& frag, BindValue&& bv )
        {
            if( !argSql.empty() ) argSql += ", ";
            argSql += pre + frag;
            binds.push_back( std::move( bv ) );
        };
        // positional arguments up to the last one given; an earlier skipped optional takes its documented default
        int last = -1;
        for( std::size_t i = 0; i < t.params.size(); ++i )
            if( !t.params[ i ].named && provided.count( t.params[ i ].name ) ) last = static_cast<int>( i );
        // The C extension API cannot overload a table function, so a table function is only callable at its full
        // arity: a trailing optional text/JSON positional that was not given is still passed, as NULL when it
        // has no default and as its default otherwise.
        if( t.kind == "table" )
        {
            int tail = last;
            for( std::size_t i = static_cast<std::size_t>( last + 1 ); i < t.params.size(); ++i )
            {
                const SpecParam& p = t.params[ i ];
                if( p.named ) continue;
                if( !p.required && ( p.type == "str" || p.type == "json" ) ) tail = static_cast<int>( i );
                else { tail = last; break; }
            }
            last = tail;
        }
        for( int i = 0; i <= last; ++i )
        {
            const SpecParam& p = t.params[ static_cast<std::size_t>( i ) ];
            if( p.named ) continue;
            auto it = provided.find( p.name );
            if( it != provided.end() ) { push( "", it->second.first, std::move( it->second.second ) ); continue; }
            if( p.required ) throw ToolError( ErrorClass::Schema, "missing required argument: " + p.name );
            if( p.def.is_null() )
            {
                // A skipped optional text column or JSON document is "not given": the engine reads a NULL that way.
                if( p.type == "str" || p.type == "json" ) { push( "", "CAST(? AS " + p.duck + ")", BindValue::null() ); continue; }
                throw ToolError( ErrorClass::Schema, p.name + " is required when a later optional argument is given" );
            }
            std::string frag; std::map<std::string, std::size_t> ignore;
            BindValue bv = encode( p, p.def, frag, ignore );
            push( "", frag, std::move( bv ) );
        }
        for( const SpecParam& p : t.params )
        {
            if( !p.named ) continue;
            auto it = provided.find( p.name );
            if( it != provided.end() ) push( p.name + " := ", it->second.first, std::move( it->second.second ) );
        }
        for( const SpecParam& p : t.params )                  // required positionals the loop above could not reach
            if( !p.named && p.required && !provided.count( p.name ) ) throw ToolError( ErrorClass::Schema, "missing required argument: " + p.name );

        std::size_t cap = 0;
        const std::string call = t.name + "(" + argSql + ")";
        std::string sql;
        if( t.rows() )
        {
            const long long want = args.value( "limit", 100LL );
            const long long ceiling = rowCfg.maxRowsCeiling > 0 ? rowCfg.maxRowsCeiling : 1000;
            if( want < 1 ) throw ToolError( ErrorClass::Schema, "limit must be at least 1" );
            if( want > ceiling )
                throw ToolError( ErrorClass::Schema, "limit must be <= the server row ceiling (" + std::to_string( ceiling ) + "); raise FSQL_MCP_MAX_ROWS_CEILING if you really need more" );
            cap = static_cast<std::size_t>( want );
            sql = "SELECT to_json(t) FROM (SELECT * FROM " + call + ") t LIMIT " + std::to_string( cap + 1 );
        }
        else if( t.out == "native" ) sql = "SELECT to_json(" + call + ")";
        else if( t.out == "hex" ) sql = "SELECT hex(" + call + ")";
        else sql = "SELECT " + call;

        QueryResult r = db.query( sql, binds, cap ? cap + 1 : 0 );
        bool truncated = false;
        if( cap && r.rows.size() > cap ) { r.rows.resize( cap ); truncated = true; }
        return decode( t, r, truncated );
    }

    // The analyst takes the execution flag as its fifth argument, so its call is built here rather
    // than through run(): the flag always reaches the engine, and an optional argument the caller
    // left out is passed as NULL (a NULL table_names means "every visible table").
    Json runAnalyst( Db& db, const SpecTool& t, const Json& args, bool auto_execute )
    {
        std::map<std::string, std::size_t> widths;
        std::vector<BindValue> binds;
        std::string argSql;
        auto push = [ & ]( const std::string& frag, BindValue&& bv )
        {
            if( !argSql.empty() ) argSql += ", ";
            argSql += frag;
            binds.push_back( std::move( bv ) );
        };
        for( const SpecParam& p : t.params )
        {
            const auto it = args.find( p.name );
            if( it != args.end() && !it->is_null() )
            {
                std::string frag;
                BindValue bv = encode( p, *it, frag, widths );
                push( frag, std::move( bv ) );
                continue;
            }
            if( p.required ) throw ToolError( ErrorClass::Schema, "missing required argument: " + p.name );
            if( p.def.is_null() ) { push( "CAST(NULL AS " + p.duck + ")", BindValue::null() ); continue; }
            std::string frag; std::map<std::string, std::size_t> ignore;
            BindValue bv = encode( p, p.def, frag, ignore );
            push( frag, std::move( bv ) );
        }
        argSql += ", ";
        argSql += auto_execute ? "TRUE" : "FALSE";
        QueryResult r = db.query( "SELECT " + t.name + "(" + argSql + ")", binds );
        return decode( t, r, false );
    }
}   // namespace

std::vector<ToolSpec> buildFunctionTools( Db& db, const RowLimitConfig& rowCfg )
{
    std::vector<ToolSpec> out;
    for( const SpecTool& t : specs() )
    {
        ToolSpec s;
        s.name = t.name; s.category = t.category; s.toolClass = t.cls == "expensive" ? ToolClass::Expensive : ToolClass::Cheap;
        s.description = t.desc;
        s.readOnlyHint = t.readOnly; s.destructiveHint = t.destructive; s.openWorldHint = t.openWorld;
        s.secretHint = t.secret;
        for( const SpecParam& p : t.params )
        {
            // dim is derivable from nested rows, so it is never required in the schema; run() enforces it when needed.
            const bool req = p.required && p.name != "dim";
            s.params.push_back( ToolParam{ p.name, jsonTypeOf( p ), req, p.def, p.desc, false, itemTypeOf( p ) } );
        }
        if( t.rows() )
            s.params.push_back( ToolParam{ "limit", JsonType::Integer, false, 100,
                "Maximum rows to return (default 100, hard ceiling FSQL_MCP_MAX_ROWS_CEILING, default 1000). A result that would have exceeded this carries truncated:true.", false } );
        const SpecTool* tp = &t;
        Db* dbp = &db;
        const RowLimitConfig rc = rowCfg;
        if( t.name == "fractal_agent_data_analyst" )
        {
            // Running the generated SQL is an explicit per-call opt-in. Without auto_execute=true
            // the statement is generated and validated by fractal_sql_agent but never run.
            s.params.push_back( ToolParam{ "auto_execute", JsonType::Boolean, false, false,
                "Default false: only generate and validate the SQL (no execution, no analysis). true is an explicit opt-in to run the generated SQL under this connection's role and analyse the real result.", false } );
            static std::deque<std::string> ownedDesc;           // description is a view; keep the text alive
            ownedDesc.push_back( std::string( t.desc ) + " auto_execute defaults to FALSE: the call then only generates and validates SQL (analysis null). Pass auto_execute=true to run it." );
            s.description = ownedDesc.back();
            s.handler = [ dbp, tp, rc ]( const Json& a, CallCtx& )
            {
                const bool exec = a.contains( "auto_execute" ) && a.at( "auto_execute" ).is_boolean() && a.at( "auto_execute" ).get<bool>();
                Json a2 = a;
                a2.erase( "auto_execute" );
                if( exec ) return runAnalyst( *dbp, *tp, a2, true );
                const SpecTool* sa = nullptr;
                for( const SpecTool& c : specs() ) if( c.name == "fractal_sql_agent" ) { sa = &c; break; }
                if( !sa ) throw ToolError( ErrorClass::Schema, "fractal_sql_agent is not available in this build" );
                if( !a2.contains( "table_names" ) || a2.at( "table_names" ).is_null() )
                    throw ToolError( ErrorClass::Schema, "table_names is required unless auto_execute=true" );
                a2.erase( "context" );
                if( !a2.contains( "max_retries" ) || a2.at( "max_retries" ).is_null() ) a2[ "max_retries" ] = 2;   // the analyst declares it optional (default 2); fractal_sql_agent requires it
                a2[ "auto_execute" ] = false;
                Json r = run( *dbp, *sa, a2, rc );
                if( r.is_object() ) { r[ "auto_execute" ] = false; r[ "analysis" ] = nullptr; }
                return r;
            };
            out.push_back( std::move( s ) );
            continue;
        }
        if( t.name == "fractal_audit_log" )
        {
            // Pass the MCP client key as the chain entry's actor label.
            s.handler = [ dbp, tp ]( const Json& a, CallCtx& ctx )
            {
                const Json& pj = a.at( "payload" );
                std::vector<BindValue> binds;
                binds.push_back( BindValue::ofStr( a.at( "entry_type" ).get<std::string>() ) );
                binds.push_back( BindValue::ofStr( pj.is_string() ? pj.get<std::string>() : pj.dump() ) );
                binds.push_back( BindValue::ofStr( ctx.clientKey ) );
                QueryResult r = dbp->query( "SELECT fractal_audit_log(CAST(? AS VARCHAR), CAST(? AS VARCHAR), CAST(? AS VARCHAR))", binds, 0 );
                return decode( *tp, r, false );
            };
            out.push_back( std::move( s ) );
            continue;
        }
        if( t.name == "fractal_config_get" || t.name == "fractal_config_set"
            || t.name == "fractal_configure_reasoning" )
        {
            // The admin/config tier: the write happens inside the engine
            // (fractal_config_set), so the new value is in force from the next
            // call on. The tools are not context-scoped: the configuration
            // is the environment the extension reads, not a connection's
            // state.
            Db* dbp = &db;
            const std::string name = t.name;
            s.handler = [ dbp, name ]( const Json& a, CallCtx& ctx )
            {
                if( name == "fractal_config_get" ) return adminGetConfig( *dbp, a, ctx );
                if( name == "fractal_config_set" ) return adminSetConfig( *dbp, a, ctx );
                return adminConfigureReasoning( *dbp, a, ctx );
            };
            // A write can carry a credential (the provider token), so the
            // arguments and the answer may hold sensitive content.
            if( name != "fractal_config_get" ) s.secretHint = true;
            out.push_back( std::move( s ) );
            continue;
        }
        s.handler = [ dbp, tp, rc ]( const Json& a, CallCtx& ) { return run( *dbp, *tp, a, rc ); };
        out.push_back( std::move( s ) );
    }
    return out;
}

}   // namespace fsqlmcp
