// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// buildAllTools: the full catalog assembly. The order is stable, for reproducible schema hashes.
#include "db.h"
#include "config.h"
#include "adapters/functions.h"

namespace fsqlmcp
{
    std::vector<ToolSpec> buildAllTools( Db& db, const EngineConfig&, const RowLimitConfig& rowCfg )
    {
        std::vector<ToolSpec> out = buildFunctionTools( db, rowCfg );
        classifyStateMutatingTools( out );
        // The context-scoped tools carry the state handle in their schema: it
        // selects the engine context (and therefore the connection) the call
        // runs on. It is added in one place, so the process catalog, every
        // HTTP session's catalog, the manifest and the locks all describe the
        // same argument.
        for( ToolSpec& t : out )
            if( isContextScopedTool( t.name ) )
                t.params.push_back( contextIdParam() );
        return out;
    }
}
