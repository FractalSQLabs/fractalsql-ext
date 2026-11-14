#include "prompts.h"
#include "errors.h"
#include <vector>
#include <string>

namespace fsqlmcp
{
    struct PromptArg { const char* name; const char* desc; bool required; };
    struct PromptDef { const char* name; const char* desc; std::vector<PromptArg> args; const char* templateStr; };

    static const char* const kLeastPriv =
        "\n\nSafety: point this server at a database you are willing to let the model read, and open it read-only "
        "(FSQL_DUCKDB_READ_ONLY=true) when it should not change anything. File access, INSTALL/LOAD and setting changes "
        "are already blocked by the lock-down. If this flow reaches fractal_sql_agent, auto_execute defaults OFF; only "
        "pass auto_execute:true if you intend it to run the generated SQL on this connection.";

    static const std::vector<PromptDef> kPrompts{
        { "incident_triage", "DevOps/SRE: triage drift on one entity's metric series.",
          { {"table_name","Table holding the metric series.",true}, {"metric_col","Metric column.",true}, {"time_col","Time-ordering column.",true},
            {"filter_col","Entity filter column.",true}, {"filter_val","Entity filter value.",true} },
          "Call fractal_agent_anomaly_triage(table_name={table_name}, metric_col={metric_col}, time_col={time_col}, "
          "filter_col={filter_col}, filter_val={filter_val}). If it flags an anomaly, consider chaining into "
          "fractal_agent_route_task and fractal_agent_outlier_intercept." },
        { "portfolio_rebalance", "FinTech: rebalance a portfolio against its own history.",
          { {"mu","Expected returns.",true}, {"cov","Covariance matrix.",true}, {"cardinality","Max nonzero assets.",true}, {"alloc_table","Allocation-snapshots table.",true},
            {"weights_col","Column holding each snapshot's weights.",true}, {"baseline","The current weights.",true} },
          "Call fractal_agent_rebalance_sibling(mu={mu}, cov={cov}, cardinality={cardinality}, alloc_table={alloc_table}, weights_col={weights_col}, baseline={baseline}). "
          "For several candidate portfolios also try fractal_agent_diverse_portfolios (Enterprise)." },
        { "patient_triage", "MedTech: cohort-restricted patient deterioration triage.",
          { {"table_name","Patient table.",true}, {"emb_col","Embedding column.",true}, {"query_vec","Query vector.",true}, {"baseline_vec","Intake vector.",true}, {"current_vec","Present vector.",true} },
          "Call fractal_agent_patient_deterioration_triage(table_name={table_name}, emb_col={emb_col}, baseline_vec={baseline_vec}, current_vec={current_vec}, query_vec={query_vec})." },
        { "fleet_detour_check", "Fleet logistics: classify a vehicle detour.",
          { {"table_name","Fleet table.",true}, {"emb_col","Embedding column.",true}, {"baseline_vec","Baseline route vector.",true}, {"current_vec","Current route vector.",true}, {"gps_trace","Flattened GPS trace.",true} },
          "Call fractal_agent_detour_classify(table_name={table_name}, emb_col={emb_col}, baseline_vec={baseline_vec}, current_vec={current_vec}, gps_trace={gps_trace})." },
        { "track_anomaly_check", "Maritime/cybersecurity: track-deviation or beaconing check.",
          { {"table_name","Track table.",true}, {"emb_col","Embedding column.",true}, {"baseline_vec","Baseline state.",true}, {"current_vec","Current state.",true}, {"heading_series","Heading series.",true} },
          "Call fractal_agent_track_anomaly(table_name={table_name}, emb_col={emb_col}, baseline_vec={baseline_vec}, current_vec={current_vec}, heading_series={heading_series})." },
        { "sensor_grid_health", "Smart cities: sensor-grid coverage alert.",
          { {"point_cloud","Flattened sensor coordinates.",true}, {"drift_series","Telemetry series.",true} },
          "Call fractal_agent_network_coverage_alert(point_cloud={point_cloud}, drift_series={drift_series})." },
        { "churn_recovery", "Customer support: recall plus diverse recommendations for a churn-risk customer.",
          { {"memory_table","Customer-memory table.",true}, {"catalog_table","Catalog table.",true}, {"emb_col","Embedding column.",true}, {"query_vec","The customer's profile vector.",true} },
          "Call fractal_agent_recall_hybrid(table_name={memory_table}, emb_col={emb_col}, query_vec={query_vec}) for the history, then "
          "fractal_agent_recommend_diverse(catalog_table={catalog_table}, emb_col={emb_col}, query_vec={query_vec})." },
        { "ask_my_data", "Ask a natural-language question of your tables.",
          { {"question","Natural-language question.",true}, {"table_names","Tables to scope to (comma-separated).",false} },
          "Read fractalsql://schema first, then call fractal_agent_data_analyst(question={question}, table_names=[{table_names}])." },
        { "safe_sql_question", "Just show me the SQL. Never executes it.",
          { {"question","Natural-language question.",true}, {"table_names","Tables to scope to (comma-separated).",false} },
          "Call fractal_text_to_sql(question={question}, table_names=[{table_names}]) and show the generated statement without running it." },
        { "diversity_audit", "Self-contained diversify health-check cycle.",
          { {"catalog_table","Catalog table.",true}, {"emb_col","Embedding column.",true}, {"query_vec","The audited query vector.",true}, {"warmup_table","Warmup table.",true}, {"warmup_vec_col","Warmup vector column.",true} },
          "Call fractal_agent_feedback_audit(catalog_table={catalog_table}, emb_col={emb_col}, query_vec={query_vec}, warmup_table={warmup_table}, warmup_vec_col={warmup_vec_col})." },
        { "ciso_ledger_check", "Enterprise: periodic ledger-chain integrity audit.",
          { {"kind","1 (QTL) or 2 (decision audit).",true} },
          "Call fractal_ledger_verify(kind={kind}) and report ok / rows_verified, or the first failure and its reason." }
    };

    Json Prompts::list()
    {
        Json arr = Json::array();
        for( const PromptDef& p : kPrompts )
        {
            Json args = Json::array();
            for( const PromptArg& a : p.args )
                args.push_back( Json{ {"name",a.name}, {"description",a.desc}, {"required",a.required} } );
            arr.push_back( Json{ {"name",p.name}, {"description",p.desc}, {"arguments",args} } );
        }
        return Json{ { "prompts", arr } };
    }

    Json Prompts::get( const std::string& name, const Json& args )
    {
        for( const PromptDef& p : kPrompts )
        {
            if( p.name != name ) continue;
            std::string filled = p.templateStr;
            for( const PromptArg& a : p.args )
            {
                const std::string placeholder = "{" + std::string( a.name ) + "}";
                std::string value;
                if( args.contains( a.name ) && !args.at( a.name ).is_null() )
                    value = args.at( a.name ).is_string()
                        ? args.at( a.name ).get<std::string>()
                        : args.at( a.name ).dump();
                else if( a.required )
                    throw ToolError( ErrorClass::Schema, std::string( "missing required prompt argument: " ) + a.name );
                else
                    value = "(not provided)";
                // Caller-supplied text is DATA, not instructions: it is rendered as a JSON string literal
                // (quoted, with newlines/quotes/control characters escaped) so it cannot break out of its
                // slot or pose as a new instruction line inside the user message.
                if( args.contains( a.name ) && !args.at( a.name ).is_null() )
                    value = Json( value ).dump( -1, ' ', false, Json::error_handler_t::replace );
                // Substitute in ONE left-to-right pass over the original
                // template. The obvious "replace every occurrence, then
                // look again" loop never terminates when the argument's
                // own value contains the placeholder -- a caller that
                // passes "{sql}" as the value of the "sql" argument makes
                // the server spin forever on a request that is supposed
                // to be cheap. A single pass cannot re-scan what it just
                // inserted, so the inserted value is never a candidate.
                std::string out;
                std::size_t pos = 0;
                while( true )
                {
                    const std::size_t hit = filled.find( placeholder, pos );
                    if( hit == std::string::npos ) break;
                    out.append( filled, pos, hit - pos );
                    out += value;
                    pos = hit + placeholder.size();
                }
                out.append( filled, pos, std::string::npos );
                filled.swap( out );
            }
            if( name == "incident_triage" || name == "ask_my_data" || name == "safe_sql_question" )
                filled += kLeastPriv;
            return Json{ { "description", p.desc },
                { "messages", Json::array( { Json{ { "role", "user" }, { "content", { { "type", "text" }, { "text", filled } } } } } ) } };
        }
        throw ToolError( ErrorClass::Schema, "unknown prompt: " + name );
    }
}