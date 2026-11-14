// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
// The admin/config tier: three tools over the extension's own
// configuration surface (fractal_config_set / fractal_config_get).
//
// The DuckDB column is configured through the process environment, so
// these tools are thin wrappers over the engine's fractal_config_set(key,
// value) and fractal_config_get(key): the write happens inside the
// extension, where the new value is visible to the extension's own
// getenv() on the next call.
//
// Which keys a model may change is the operator's decision, not the
// model's: FSQL_MCP_CONFIG_WRITES (off | safe | all) decides, and the
// safe set is the model names and the think mode -- the keys that name
// a model rather than a destination.
#include <string>
#include "db.h"
#include "mcp_json.h"
#include "tool_registry.h"

namespace fsqlmcp
{
    // Reads one configuration key back. Secrets are refused.
    Json adminGetConfig( Db& db, const Json& args, CallCtx& ctx );

    // Writes one configuration key. Refused unless the config-writes
    // switch allows that key.
    Json adminSetConfig( Db& db, const Json& args, CallCtx& ctx );

    // Configures the reasoning/embedding provider in one call.
    Json adminConfigureReasoning( Db& db, const Json& args, CallCtx& ctx );
}
