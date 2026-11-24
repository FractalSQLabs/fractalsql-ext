#!/usr/bin/env bash
#
# scripts/render_notices.sh -- emit the LICENSE-THIRD-PARTY notice for
# one build.
#
# The notices template (THIRD-PARTY-NOTICES.md) is version-complete:
# section 6 states the DuckDB copyright line for every DuckDB tag this
# project builds against, in a table. This script adds the per-build
# header on top of it -- the DuckDB version this build was made against
# and the exact copyright line that DuckDB tag's LICENSE carries -- so
# the shipped notice identifies its own build instead of leaving the
# reader to infer it from a filename.
#
# The copyright line is read from the template's own table, so there is
# one source of truth: adding a DuckDB tag means editing the table in
# section 6 and nothing else. If the build also captured the DuckDB
# tag's LICENSE file, the line is taken from that file instead, so the
# notice reflects the tag that was actually compiled rather than a
# table entry. A tag that is in neither place is a hard error, not a
# guess.
#
# Usage:
#   scripts/render_notices.sh <template> <output> \
#       <extension-version> <duckdb-version> <platform-tag> \
#       [duckdb-license-file]
#
#   <template>              notices template, normally THIRD-PARTY-NOTICES.md
#   <output>                file to write
#   <extension-version>     this project's extension version, e.g. 2.0.2
#   <duckdb-version>        the DuckDB tag built against, e.g. v1.5.6
#   <platform-tag>          e.g. linux_amd64
#   [duckdb-license-file]   optional: the DuckDB tag's LICENSE file,
#                           captured from the DuckDB source tree at build
#                           time. When given, the copyright line is read
#                           from it.

set -euo pipefail

if [ "$#" -lt 5 ] || [ "$#" -gt 6 ]; then
    echo "usage: $0 <template> <output> <ext-version> <duckdb-version> <platform-tag> [duckdb-license-file]" >&2
    exit 2
fi

TEMPLATE="$1"
OUTPUT="$2"
EXT_VERSION="$3"
DUCKDB_VERSION="$4"
PLATFORM_TAG="$5"
DUCKDB_LICENSE_FILE="${6:-}"

if [ ! -f "${TEMPLATE}" ]; then
    echo "missing notices template ${TEMPLATE}" >&2
    exit 1
fi

# ---------------------------------------------------------------------
# Resolve the DuckDB copyright line for this build.
#
# Order of preference:
#   1. the DuckDB tag's own LICENSE file, if the build captured one
#   2. the per-tag table in section 6 of the template
# ---------------------------------------------------------------------
COPYRIGHT_LINE=""

if [ -n "${DUCKDB_LICENSE_FILE}" ] && [ -f "${DUCKDB_LICENSE_FILE}" ]; then
    COPYRIGHT_LINE="$(grep -m1 -E '^[[:space:]]*Copyright' "${DUCKDB_LICENSE_FILE}" || true)"
    if [ -n "${COPYRIGHT_LINE}" ]; then
        COPYRIGHT_LINE="$(printf '%s' "${COPYRIGHT_LINE}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    fi
fi

if [ -z "${COPYRIGHT_LINE}" ]; then
    COPYRIGHT_LINE="$(awk -F'|' -v want="${DUCKDB_VERSION}" '
        /^[[:space:]]*\|[[:space:]]*v[0-9]/ {
            tag = $2; line = $3;
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", tag);
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line);
            if (tag == want) { print line; exit }
        }
    ' "${TEMPLATE}")"
fi

if [ -z "${COPYRIGHT_LINE}" ]; then
    echo "no DuckDB copyright line for '${DUCKDB_VERSION}'." >&2
    echo "Add a row for it to the table in section 6 of ${TEMPLATE}," >&2
    echo "or pass the DuckDB tag's LICENSE file as the last argument." >&2
    exit 1
fi

# ---------------------------------------------------------------------
# Write the rendered notice: per-build header, then the template.
# ---------------------------------------------------------------------
{
    cat <<EOF
================================================================================
fractalsql-ext ${EXT_VERSION} Community -- third-party notices
================================================================================

This file is the LICENSE-THIRD-PARTY notice for the artifact named below,
and for that artifact only.

  Extension file:    fractalsql.${DUCKDB_VERSION}.${PLATFORM_TAG}.duckdb_extension
  Extension version: ${EXT_VERSION}
  DuckDB version:    ${DUCKDB_VERSION}
  DuckDB copyright:  ${COPYRIGHT_LINE}
  Platform:          ${PLATFORM_TAG}

No DuckDB code is compiled or linked into this extension: it calls DuckDB
through the C extension API. The only DuckDB material in the build is the
MIT-licensed API headers; the copyright line above is the one carried by
that DuckDB tag's LICENSE file, and section 6 of the notices below lists the
line for every DuckDB tag this project builds against.

A release bundle also carries the MCP server (mcp/), a standalone program that
runs on DuckDB's own shared library, distributed unmodified from the official
DuckDB release of the tag above. For it, the bundle's licenses/duckdb/ holds
that tag's LICENSE and the licences of the third-party components in DuckDB's
source tree. Sections 6 and 8 to 10 of the notices below cover the MCP server.

================================================================================

EOF
    cat "${TEMPLATE}"
} > "${OUTPUT}"
