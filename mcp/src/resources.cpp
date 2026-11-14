// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "resources.h"
#include "db.h"
#include "config.h"
#include "errors.h"
#include "version.h"
#include <cstdlib>
#include <string>

namespace fsqlmcp
{
    static Db* g_db = nullptr;
    static thread_local Db* t_db = nullptr;    // per-HTTP-session binding
    static EngineConfig g_cfg;

    static Db* currentDb() { return t_db ? t_db : g_db; }

    void Resources::setEngineDb( Db* db ) { g_db = db; }
    void Resources::setEngineConfig( const EngineConfig& cfg ) { g_cfg = cfg; }
    void Resources::bindThreadDb( Db* db ) { t_db = db; }

    Json Resources::list()
    {
        return Json{ { "resources", Json::array( {
            Json{ { "uri", "fractalsql://agents" },
                  { "name", "FractalSQL agents catalog" },
                  { "description", "Static catalog: which agent to use for which problem (the sixteen recipes and the building blocks, with their "
                                   "one-line purpose and whether they need a model), so a client can pull the whole picture in one read." },
                  { "mimeType", "application/json" } },
            Json{ { "uri", "fractalsql://schema" },
                  { "name", "Live schema context" },
                  { "description", "fractal_schema_context()'s own live output: the tables, columns, keys and comments visible to this connection. "
                                   "Read it before composing a fractal_text_to_sql or fractal_sql_agent call. Not cached." },
                  { "mimeType", "text/plain" } },
            Json{ { "uri", "fractalsql://config" },
                  { "name", "Resolved server state (non-secret)" },
                  { "description", "The extension version and edition, the DuckDB version, which database is open and whether it is read-only or locked down, "
                                   "which provider keys are set (as booleans) and whether the enterprise tier is loaded. Never a token, key or URL." },
                  { "mimeType", "application/json" } },
        } ) } };
    }

    Json Resources::templates()
    {
        return Json{ { "resourceTemplates", Json::array( {
            Json{ { "uriTemplate", "fractalsql://ledger/{kind}" },
                  { "name", "Ledger audit report" },
                  { "description", "fractal_ledger_verify(kind)'s own JSON audit report. kind=1 is the QTL chain, kind=2 the decision-audit chain. "
                                   "A read-only forensic query." },
                  { "mimeType", "application/json" } },
        } ) } };
    }

    static Json wrapRead( const std::string& uri, const char* mime, const std::string& text )
    {
        return Json{ { "contents", Json::array( { Json{ { "uri", uri }, { "mimeType", mime }, { "text", text } } } ) } };
    }

    static const char* const kAgentsJson =
        "{\n"
        "  \"recipes\": [\n"
        "    {\"tool\": \"fractal_agent_anomaly_triage\", \"use\": \"Is this entity's metric series drifting? Drift plus a written triage.\", \"model\": true},\n"
        "    {\"tool\": \"fractal_agent_allocate\", \"use\": \"Pick a cardinality-constrained portfolio and explain it.\", \"model\": true},\n"
        "    {\"tool\": \"fractal_agent_route_task\", \"use\": \"Route a task to the nearest capability under a token budget.\", \"model\": true},\n"
        "    {\"tool\": \"fractal_agent_outlier_intercept\", \"use\": \"Block a proposed state that is too close to a known-bad one.\", \"model\": true},\n"
        "    {\"tool\": \"fractal_agent_recall_hybrid\", \"use\": \"Retrieve the nearest memories, optionally within a cohort.\", \"model\": false},\n"
        "    {\"tool\": \"fractal_agent_recommend_diverse\", \"use\": \"Recommend items that are relevant and mutually diverse.\", \"model\": false},\n"
        "    {\"tool\": \"fractal_agent_data_analyst\", \"use\": \"Ask a natural-language question of your tables.\", \"model\": true},\n"
        "    {\"tool\": \"fractal_agent_patient_deterioration_triage\", \"use\": \"Cohort search plus the drift from baseline to now.\", \"model\": true},\n"
        "    {\"tool\": \"fractal_agent_feedback_audit\", \"use\": \"Check that diversification is actually working.\", \"model\": false},\n"
        "    {\"tool\": \"fractal_agent_schedule_workload\", \"use\": \"Place a workload on the nearest-capability node.\", \"model\": true},\n"
        "    {\"tool\": \"fractal_agent_rebalance_sibling\", \"use\": \"Rebalance a portfolio against the most similar past allocation.\", \"model\": true},\n"
        "    {\"tool\": \"fractal_agent_detour_classify\", \"use\": \"Did this vehicle detour, and how complex is its GPS trace?\", \"model\": true},\n"
        "    {\"tool\": \"fractal_agent_track_anomaly\", \"use\": \"Is this track deviating, and is its heading persistent?\", \"model\": true},\n"
        "    {\"tool\": \"fractal_agent_network_coverage_alert\", \"use\": \"Sensor-grid coverage and telemetry drift.\", \"model\": true},\n"
        "    {\"tool\": \"fractal_agent_regime_triage\", \"use\": \"Has the regime of any series changed?\", \"model\": true},\n"
        "    {\"tool\": \"fractal_agent_diverse_portfolios\", \"use\": \"Several different near-optimal portfolios (enterprise).\", \"model\": true}\n"
        "  ],\n"
        "  \"building_blocks\": [\n"
        "    {\"tool\": \"fractal_agent_plan_explore\", \"use\": \"Branch a seed state into the nearest strategies.\", \"model\": \"embedding\"},\n"
        "    {\"tool\": \"fractal_agent_trajectory_predict\", \"use\": \"Project the next state from a table of states.\", \"model\": false},\n"
        "    {\"tool\": \"fractal_agent_detect_loop\", \"use\": \"Is an agent stuck repeating itself?\", \"model\": false},\n"
        "    {\"tool\": \"fractal_search_agent\", \"use\": \"Embed, search, answer from the hits.\", \"model\": true},\n"
        "    {\"tool\": \"fractal_rag_agent\", \"use\": \"Search a table and answer from the hits.\", \"model\": true}\n"
        "  ],\n"
        "  \"note\": \"Agents that use a model return the computed half plus reasoning_step_failed when the model does not answer.\"\n"
        "}\n";

    static bool isSet( const char* name ) { const char* v = std::getenv( name ); return v && *v; }

    Json Resources::read( const std::string& uri )
    {
        if( uri == "fractalsql://agents" ) return wrapRead( uri, "application/json", kAgentsJson );
        Db* db = currentDb();
        if( !db ) throw ToolError( ErrorClass::ServerInternal, "no engine connection bound for resources" );

        if( uri == "fractalsql://schema" )
        {
            QueryResult r = db->query( "SELECT fractal_schema_context()", {} );
            std::string text;
            if( !r.rows.empty() && r.rows[ 0 ][ 0 ].kind == Cell::Kind::Text ) text = r.rows[ 0 ][ 0 ].s;
            return wrapRead( uri, "text/plain", text );
        }
        if( uri == "fractalsql://config" )
        {
            Json out{ { "plugin", kMcpPluginName }, { "plugin_version", FSQL_MCP_VERSION } };
            out[ "extension_version" ] = db->engineVersion();
            try { QueryResult e = db->query( "SELECT fractal_edition()", {} ); out[ "edition" ] = e.rows.at( 0 ).at( 0 ).toJson(); } catch( const std::exception& ) { out[ "edition" ] = nullptr; }
            try { QueryResult v = db->query( "SELECT version()", {} ); out[ "duckdb_version" ] = v.rows.at( 0 ).at( 0 ).toJson(); } catch( const std::exception& ) {}
            out[ "database" ] = g_cfg.database == ":memory:" ? Json( ":memory:" ) : Json( "file" );
            out[ "read_only" ] = g_cfg.readOnly;
            out[ "locked_down" ] = g_cfg.lockDown;
            Json prov = Json::object();
            prov[ "reasoning_plugin" ] = isSet( "FRACTALSQL_REASONING_PLUGIN" );
            prov[ "reasoning_url" ] = isSet( "FSQL_REASONING_HTTP_URL" );
            prov[ "embed_url" ] = isSet( "FSQL_REASONING_HTTP_EMBED_URL" );
            prov[ "enterprise_library" ] = isSet( "FRACTALSQL_ENTERPRISE_LIB" );
            out[ "providers_configured" ] = prov;
            bool enterprise = false;
            try { db->query( "SELECT fractal_ledger_truth_count()", {} ); enterprise = true; } catch( const std::exception& ) {}
            out[ "enterprise_tier" ] = enterprise;
            return wrapRead( uri, "application/json", out.dump( 2 ) );
        }
        const std::string kLedger = "fractalsql://ledger/";
        if( uri.rfind( kLedger, 0 ) == 0 )
        {
            const std::string kind = uri.substr( kLedger.size() );
            if( kind != "1" && kind != "2" ) throw ToolError( ErrorClass::Schema, "ledger kind must be 1 or 2" );
            QueryResult r = db->query( "SELECT fractal_ledger_verify(CAST(? AS INTEGER))", { BindValue::ofInt( kind == "1" ? 1 : 2 ) } );
            std::string text = ( !r.rows.empty() && r.rows[ 0 ][ 0 ].kind == Cell::Kind::Text ) ? r.rows[ 0 ][ 0 ].s : "{}";
            return wrapRead( uri, "application/json", text );
        }
        throw ToolError( ErrorClass::Schema, "unknown resource: " + uri );
    }
}
