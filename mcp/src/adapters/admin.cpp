// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
//
// The admin/config tier: three tools over the extension's own
// configuration surface.
//
// The DuckDB column has no `SET fractalsql.*` options: the extension is
// configured through the process environment (FRACTALSQL_REASONING_PLUGIN,
// FSQL_REASONING_HTTP_*, FRACTALSQL_ENTERPRISE_LIB), the same way the
// operator configures it on the command line. These tools are the
// documented, named way to read and change that configuration through
// the MCP boundary, and they are thin wrappers over the engine's own
// fractal_config_set(key, value) / fractal_config_get(key): the write happens
// inside the extension, where the new value is visible to the
// extension's getenv() on the very next call.
//
// The switch
//   FSQL_MCP_CONFIG_WRITES decides what a model may change:
//     off   nothing may be written;
//     safe (the default) only the model names and the think mode --
//           the keys that name a model, not a destination;
//     all  anything may be, including the endpoint URLs.
//   A key this build does not know about is refused in safe mode too:
//   an unknown key is a typo, and a typo must not widen what a tool may
//   write.
//
// Secrets
//   http_token is a credential. It can be set (an operator may point
//   the extension at a token) and it is never read back: a read of a
//   secret key is refused, and every log line that carries a value
//   carries "***" in its place.
//
// Scope
//   The configuration is process-wide, not per-connection: it is the
//   environment the extension reads, so it is shared by every
//   connection this process opens, and it is gone when the process
//   exits.
#include "admin.h"
#include "../logging.h"
#include "../policy.h"

#include <algorithm>
#include <cstdio>
#include <functional>
#include <string>
#include <vector>

namespace fsqlmcp
{
    namespace
    {
        // The documented configuration keys of this edition: the short
        // name, the environment variable it names, whether the value is
        // a secret, and whether it changes the enterprise tier's
        // posture. The same table is in the extension (the engine owns
        // the mapping); this copy is what the policy switch is checked
        // against and what the refusal messages name.
        struct ConfigKey
        {
            const char* key;
            const char* env;
            bool       secret;
            bool       enterprise;
        };

        const ConfigKey kConfigKeys[] = {
            { "reasoning_plugin",    "FRACTALSQL_REASONING_PLUGIN",       false, false },
            { "http_url",            "FSQL_REASONING_HTTP_URL",           false, false },
            { "http_model",          "FSQL_REASONING_HTTP_MODEL",         false, false },
            { "http_embed_url",      "FSQL_REASONING_HTTP_EMBED_URL",     false, false },
            { "http_embed_model",    "FSQL_REASONING_HTTP_EMBED_MODEL",   false, false },
            { "http_think",          "FSQL_REASONING_HTTP_THINK",         false, false },
            { "http_think_provider", "FSQL_REASONING_HTTP_THINK_PROVIDER", false, false },
            { "http_native_url",     "FSQL_REASONING_HTTP_NATIVE_URL",    false, false },
            { "http_num_ctx",        "FSQL_REASONING_HTTP_NUM_CTX",       false, false },
            { "http_response_mode",  "FSQL_REASONING_HTTP_RESPONSE_MODE", false, false },
            { "http_allow_plaintext","FSQL_REASONING_HTTP_ALLOW_PLAINTEXT", false, false },
            { "http_token",          "FSQL_REASONING_HTTP_TOKEN",         true,  false },
            { "enterprise_lib",      "FRACTALSQL_ENTERPRISE_LIB",         false, true },
            { "ledger_retention",    "FRACTALSQL_LEDGER_RETENTION",       false, true },
        };

        const std::size_t kConfigKeyCount = sizeof( kConfigKeys ) / sizeof( kConfigKeys[ 0 ] );

        // The key, or null when this build does not know it. The
        // environment variable's own name is accepted as a spelling of
        // the key too.
        const ConfigKey* findKey( const std::string& key )
        {
            for( std::size_t i = 0; i < kConfigKeyCount; i++ )
                if( key == kConfigKeys[ i ].key || key == kConfigKeys[ i ].env ) return &kConfigKeys[ i ];
            return nullptr;
        }

        std::string keyList()
        {
            std::string out;
            for( std::size_t i = 0; i < kConfigKeyCount; i++ )
            {
                if( i ) out += ", ";
                out += kConfigKeys[ i ].key;
            }
            return out;
        }

        const ConfigKey& requireKey( const std::string& key )
        {
            const ConfigKey* k = findKey( key );
            if( !k )
                throw ToolError( ErrorClass::Schema,
                    "unknown config key '" + key + "': the documented keys are " + keyList() );
            return *k;
        }

        // A short, non-reversible tag of the calling client, for the
        // refusal log: enough to tell two clients apart in an incident,
        // never the credential itself.
        std::string clientTag( const std::string& clientKey )
        {
            if( clientKey.empty() ) return std::string();
            char buf[ 24 ];
            std::snprintf( buf, sizeof buf, "c-%08zx",
                           std::hash<std::string>{}( clientKey ) & 0xffffffffu );
            return buf;
        }

        // The scope of the configuration on this column, said the same
        // way in every answer.
        const char* const kScope =
            "process-wide (the environment the DuckDB extension reads: every connection this server "
            "process opens sees it, and it is gone when the process exits)";

        // The engine's current value for a key: the empty string when the
        // key is not configured. A secret is never read, so its value is
        // reported as "***".
        std::string engineValue( Db& db, const ConfigKey& k )
        {
            if( k.secret ) return "***";
            QueryResult r = db.query( "SELECT fractal_config_get(CAST(? AS VARCHAR))", { BindValue::ofStr( k.key ) } );
            if( r.rows.empty() || r.rows[ 0 ].empty() ) return std::string();
            const Cell& c = r.rows[ 0 ][ 0 ];
            if( c.kind == Cell::Kind::Null ) return std::string();
            return c.s;
        }

        // Write the key. The engine owns the write, so the new value is
        // visible to the extension's own getenv() on the next call.
        void engineSet( Db& db, const ConfigKey& k, const std::string& value )
        {
            db.query( "SELECT fractal_config_set(CAST(? AS VARCHAR), CAST(? AS VARCHAR))",
                      { BindValue::ofStr( k.key ), BindValue::ofStr( value ) } );
        }

        // The refusal: it names the key, says what it is set to now, and
        // says where to set it instead -- the operator's own
        // configuration, not a tool call a model can make.
        void refuseConfigWrite( Db& db, const ConfigKey& k, CallCtx& ctx )
        {
            const std::string current = engineValue( db, k );
            logging::configRefused( k.key, configWritesModeName(), clientTag( ctx.clientKey ) );
            throw ToolError( ErrorClass::Schema,
                "config write refused: '" + std::string( k.key ) + "' may not be written through this tool while "
                "FSQL_MCP_CONFIG_WRITES=" + std::string( configWritesModeName() ) + ". The safe set is the "
                "chat model name (http_model), the embedding model name (http_embed_model) and the think mode "
                "(http_think); the endpoint URLs, the plugin path, the token and the enterprise key are not in "
                "it. '" + std::string( k.key ) + "' is currently set to '" + ( current.empty() ? "not set" : current ) +
                "'. Set it in the server's own environment (the FSQL_REASONING_HTTP_* variables the extension "
                "reads) instead of through this tool, or run the server with FSQL_MCP_CONFIG_WRITES=all if you "
                "really want this tool to write it." );
        }
    }

    Json adminGetConfig( Db& db, const Json& args, CallCtx& )
    {
        const std::string key = args.at( "key" ).get<std::string>();
        const ConfigKey& k = requireKey( key );
        if( k.secret )
            throw ToolError( ErrorClass::Schema,
                "'" + key + "' is a secret and is never read back through any MCP tool or resource; "
                "it is a credential, and no read may turn it into output. Check the environment that set "
                "it instead" );
        const std::string value = engineValue( db, k );
        Json out{ { "key", key },
                  { "value", value.empty() ? Json( nullptr ) : Json( value ) },
                  { "scope", kScope } };
        return out;
    }

    Json adminSetConfig( Db& db, const Json& args, CallCtx& ctx )
    {
        const std::string key = args.at( "key" ).get<std::string>();
        const ConfigKey& k = requireKey( key );
        if( k.enterprise && !args.value( "allow_secrets", false ) )
            throw ToolError( ErrorClass::Schema,
                "'" + key + "' changes the enterprise tier's posture (the library it loads): pass "
                "allow_secrets=true to make the operator's explicit intent explicit; a client UI prompts a "
                "human first for these changes" );
        // The switch: a key the current mode does not allow is refused
        // before anything is changed.
        if( !configWriteAllowed( k.env ) ) refuseConfigWrite( db, k, ctx );
        const std::string oldVal = engineValue( db, k );
        const std::string newVal = args.at( "value" ).get<std::string>();
        engineSet( db, k, newVal );
        // Every successful config change is logged with the old and the
        // new value, so a silent endpoint swap (http_url repointed at an
        // attacker endpoint, where every subsequent reasoning call sends
        // prompts and embeddings) is catchable after the fact even if no
        // one watched it live. A secret value is redacted in the log.
        logging::configChange( k.key, k.secret ? "***" : oldVal, k.secret ? "***" : newVal );
        Json out{ { "key", key },
                  { "old", oldVal.empty() ? Json( nullptr ) : Json( oldVal ) },
                  { "new", k.secret ? Json( "***" ) : Json( newVal ) },
                  { "scope", kScope } };
        return out;
    }

    Json adminConfigureReasoning( Db& db, const Json& args, CallCtx& ctx )
    {
        static const std::vector<std::pair<const char*, const char*>> kFieldMap{
            { "provider_url", "http_url" }, { "embed_url", "http_embed_url" },
            { "model", "http_model" }, { "embed_model", "http_embed_model" },
            { "think_mode", "http_think" }, { "allow_plaintext", "http_allow_plaintext" },
        };
        // Collect first, apply second: a call that names a key the
        // config-writes switch refuses changes nothing at all.
        std::vector<std::pair<const ConfigKey*, std::string>> pending;
        for( const auto& kv : kFieldMap )
        {
            if( !args.contains( kv.first ) || args.at( kv.first ).is_null() ) continue;
            const ConfigKey& k = requireKey( kv.second );
            // allow_plaintext is a boolean; the plugin reads the flag as "1".
            pending.emplace_back( &k, std::string( kv.first ) == "allow_plaintext"
                ? ( args.at( kv.first ).get<bool>() ? "1" : "0" )
                : args.at( kv.first ).get<std::string>() );
        }
        if( pending.empty() )
            throw ToolError( ErrorClass::Schema,
                "nothing to set: pass at least one of provider_url, embed_url, model, embed_model, "
                "allow_plaintext, think_mode" );
        for( const auto& p : pending )
            if( !configWriteAllowed( p.first->env ) ) refuseConfigWrite( db, *p.first, ctx );
        Json applied = Json::object();
        for( const auto& p : pending )
        {
            const std::string oldVal = engineValue( db, *p.first );
            engineSet( db, *p.first, p.second );
            logging::configChange( p.first->key, oldVal, p.second );
            applied[ p.first->key ] = Json{ { "old", oldVal.empty() ? Json( nullptr ) : Json( oldVal ) },
                                           { "new", p.second } };
        }
        Json out{ { "applied", applied }, { "scope", kScope },
                  { "note", "this tool never touches the provider token (http_token) or the enterprise key: "
                            "the token belongs in the server's environment, and the enterprise tier's posture "
                            "is an operator action." } };
        return out;
    }
}
