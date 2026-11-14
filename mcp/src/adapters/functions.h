// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <vector>
#include "../tool_registry.h"
#include "../rows.h"
#include "../db.h"
#include "../config.h"

namespace fsqlmcp
{
    // The whole tool catalog: one tool per extension function, built from tools.spec.json.
    std::vector<ToolSpec> buildFunctionTools( Db& db, const RowLimitConfig& rowCfg );
}
