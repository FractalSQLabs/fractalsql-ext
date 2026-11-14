#!/usr/bin/env bash
#
# scripts/package_mcp.sh -- fractalsql-ext-mcp release archive (Linux).
#
#   scripts/package_mcp.sh <duckdb_version> [amd64|arm64]     e.g.  scripts/package_mcp.sh v1.5.6 amd64
#
# Builds the MCP server (mcp/) against the matching libduckdb release and writes
#   dist/packages/fractalsql-ext-mcp-<duckdb_version>-linux_<arch>.tar.gz
# holding the binary, libduckdb.so (the binary finds it beside itself through RPATH=$ORIGIN), the schema and safety
# locks, the manifest, the README and the licences. The server loads the extension named by FSQL_DUCKDB_EXTENSION
# (the matching fractalsql.<duckdb_version>.linux_<arch>.duckdb_extension from the same release).
#
# LIBDUCKDB_DIR may point at an unpacked libduckdb-linux-<arch>.zip (duckdb.h + libduckdb.so); otherwise it is
# downloaded. OpenSSL's headers and a C++17 compiler are the only other requirements.
set -euo pipefail
cd "$(dirname "$0")/.."

DV="${1:?usage: scripts/package_mcp.sh <duckdb_version> [amd64|arm64]}"
ARCH="${2:-}"
if [[ -z "${ARCH}" ]]; then
    case "$(uname -m)" in x86_64|amd64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) echo "unsupported host arch" >&2; exit 2 ;; esac
fi
case "${ARCH}" in amd64|arm64) ;; *) echo "unknown arch '${ARCH}'" >&2; exit 2 ;; esac

VERSION="$(sed -n 's/^#define FSQL_MCP_VERSION *"\(.*\)"/\1/p' mcp/src/version.h)"
[[ -n "${VERSION}" ]] || { echo "cannot read the MCP version from mcp/src/version.h" >&2; exit 1; }
for f in LICENSE THIRD-PARTY-NOTICES.md mcp/README.md mcp/manifest.json mcp/.mcp-schema-lock mcp/.mcp-safety-annotations-lock; do
    [[ -f "${f}" ]] || { echo "missing ${f} -- refusing to package without it" >&2; exit 1; }
done

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
LIBDIR="${LIBDUCKDB_DIR:-${WORK}/libduckdb}"
if [[ ! -f "${LIBDIR}/duckdb.h" ]]; then
    bash "$(dirname "$0")/fetch_duckdb.sh" libs "${DV}" linux "${ARCH}" "${LIBDIR}"
fi
[[ -f "${LIBDIR}/libduckdb.so" ]] || { echo "no libduckdb.so in ${LIBDIR}" >&2; exit 1; }

# libstdc++ is linked statically (libgcc_s stays dynamic: a static libgcc raises the glibc floor); libssl/libcrypto stay dynamic (the host's OpenSSL), libduckdb.so rides along.
make -C mcp CXXFLAGS="-O2" SANFLAGS="-static-libstdc++" DUCKDB_DIR="${LIBDIR}" RPATH='$$ORIGIN' \
    BUILD="${WORK}/obj" OUT="${WORK}/fractalsql-ext-mcp"
strip "${WORK}/fractalsql-ext-mcp"
# the binary must resolve libduckdb.so through its own directory, not the build directory
RP="$(readelf -d "${WORK}/fractalsql-ext-mcp" | sed -n 's/.*RUNPATH.*\[\(.*\)\]/\1/p; s/.*RPATH.*\[\(.*\)\]/\1/p' | head -1)"
case "${RP}" in *ORIGIN*) ;; *) echo "RPATH is '${RP}', expected \$ORIGIN" >&2; exit 1 ;; esac

NAME="fractalsql-ext-mcp-${DV}-linux_${ARCH}"
STAGE="${WORK}/${NAME}"
install -Dm0755 "${WORK}/fractalsql-ext-mcp" "${STAGE}/fractalsql-ext-mcp"
install -Dm0755 "${LIBDIR}/libduckdb.so" "${STAGE}/libduckdb.so"
install -Dm0644 mcp/README.md                        "${STAGE}/README.md"
install -Dm0644 mcp/manifest.json                    "${STAGE}/manifest.json"
install -Dm0644 mcp/.mcp-schema-lock                 "${STAGE}/.mcp-schema-lock"
install -Dm0644 mcp/.mcp-safety-annotations-lock     "${STAGE}/.mcp-safety-annotations-lock"
install -Dm0644 LICENSE                              "${STAGE}/LICENSE"
install -Dm0644 THIRD-PARTY-NOTICES.md               "${STAGE}/LICENSE-THIRD-PARTY"
cat > "${STAGE}/RUN.txt" <<TXT
fractalsql-ext-mcp ${VERSION} (built against DuckDB ${DV}, linux_${ARCH})

  FSQL_DUCKDB_EXTENSION=/path/to/fractalsql.${DV}.linux_${ARCH}.duckdb_extension \\
  FSQL_DUCKDB_ALLOW_UNSIGNED=true ./fractalsql-ext-mcp

Needs OpenSSL's runtime library (libssl.so.3). Use the extension built for the same DuckDB version (${DV}).
TXT

mkdir -p dist/packages
tar -C "${WORK}" -czf "dist/packages/${NAME}.tar.gz" "${NAME}"
( cd dist/packages && sha256sum "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256" )
echo "wrote dist/packages/${NAME}.tar.gz"
