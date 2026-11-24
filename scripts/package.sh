#!/usr/bin/env bash
#
# scripts/package.sh -- fractalsql-ext packaging.
#
# DuckDB extensions are NOT system-installed. There's no .deb / .rpm /
# .msi -- distribution is just the single-file .duckdb_extension per
# (duckdb_version, platform) cell. This script emits two artifacts per
# cell into dist/packages/:
#
#   1. The raw extension file, copied with the version/platform tag in
#      its name so it survives a Release upload with identity intact:
#
#        dist/packages/fractalsql.v1.5.6.linux_amd64.duckdb_extension
#
#   2. A per-(duckdb_version, platform) .zip bundle containing the
#      extension + LICENSE + LICENSE-THIRD-PARTY + README.txt:
#
#        dist/packages/fractalsql-ext-v1.5.6-linux_amd64.zip
#
#   3. Standalone notice assets, so the raw extension is published with
#      its licence files beside it rather than only inside the .zip:
#
#        dist/packages/LICENSE
#        dist/packages/LICENSE-THIRD-PARTY
#
# Assumes build.sh has already produced:
#   dist/${ARCH}/fractalsql.${DUCKDB_VERSION}.linux_${ARCH}.duckdb_extension   (build.sh lays out one per DuckDB version)
#
# Usage:
#   scripts/package.sh [amd64|arm64]     # default: amd64
#
# Per-version override (v1.4.5, v1.5.6 or v2.0.0):
#   DUCKDB_VERSION=v2.0.0 scripts/package.sh amd64
#
# LICENSE staging note
#   Files staged via `install -Dm0644` into a scratch dir before
#   zipping. Explicit src=dst zip mappings with absolute paths run
#   into the same chroot trap as fpm -C, so keep staging explicit.

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="2.0.2"
DIST_DIR="dist/packages"
mkdir -p "${DIST_DIR}"

PKG_ARCH="${1:-amd64}"
case "${PKG_ARCH}" in
    amd64|arm64) ;;
    *)
        echo "unknown arch '${PKG_ARCH}' -- expected amd64 or arm64" >&2
        exit 2
        ;;
esac

DUCKDB_VERSION="${DUCKDB_VERSION:-v1.5.6}"
PLATFORM_TAG="linux_${PKG_ARCH}"
EXT_NAME="fractalsql.${DUCKDB_VERSION}.${PLATFORM_TAG}.duckdb_extension"
SRC_EXT="dist/${PKG_ARCH}/${EXT_NAME}"

if [[ ! -f "${SRC_EXT}" ]]; then
    echo "missing ${SRC_EXT} -- run:" >&2
    echo "    ./build.sh ${PKG_ARCH}" >&2
    echo "then:" >&2
    echo "    DUCKDB_VERSION=${DUCKDB_VERSION} scripts/package.sh ${PKG_ARCH}" >&2
    exit 1
fi

for f in LICENSE THIRD-PARTY-NOTICES.md; do
    if [[ ! -f "${f}" ]]; then
        echo "missing ${f} -- refusing to package without it" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------
# Artifact 1: raw extension file, version/platform-tagged filename,
# copied straight into dist/packages/.
# ---------------------------------------------------------------------
install -Dm0644 "${SRC_EXT}" "${DIST_DIR}/${EXT_NAME}"
echo "staged ${DIST_DIR}/${EXT_NAME}"

# ---------------------------------------------------------------------
# Artifact 3: standalone LICENSE and LICENSE-THIRD-PARTY release
# assets.
#
# The raw extension is a single file with nothing beside it, so the
# notices have to travel as assets of their own -- otherwise the
# published .duckdb_extension carries no notice file and the Apache-2.0
# section 4(d) obligation is unmet for anyone who downloads it directly.
#
# These are the version-complete documents, so they are byte-identical in
# every matrix cell. The per-build copy -- the one that names this
# cell's DuckDB version and DuckDB copyright line -- is the one inside
# the .zip below.
# ---------------------------------------------------------------------
install -Dm0644 LICENSE                "${DIST_DIR}/LICENSE"
install -Dm0644 THIRD-PARTY-NOTICES.md "${DIST_DIR}/LICENSE-THIRD-PARTY"
echo "staged ${DIST_DIR}/LICENSE and ${DIST_DIR}/LICENSE-THIRD-PARTY"

# ---------------------------------------------------------------------
# The reasoning plugin (optional tier) and its detached Ed25519 signature. The plugin loads only
# when <plugin>.sig (exactly 64 bytes) sits beside it, so the two always ship together: as
# the .zip below. The release workflow unpacks that .zip into the release bundle (with the MCP server added),
# and easy_install installs the plugin from the bundle.
# ---------------------------------------------------------------------
case "${PKG_ARCH}" in
    amd64) PLUGIN_INC="linux-x86_64" ;;
    arm64) PLUGIN_INC="linux-aarch64" ;;
esac
PLUGIN_SRC="include/${PLUGIN_INC}/fractalsql-reasoning-http.so"
PLUGIN_SIG="${PLUGIN_SRC}.sig"
[ -f "${PLUGIN_SRC}" ] || { echo "missing ${PLUGIN_SRC}: re-run the vendored-artifact deploy step" >&2; exit 1; }
if [ ! -f "${PLUGIN_SIG}" ] || [ "$(wc -c < "${PLUGIN_SIG}")" -ne 64 ]; then
    echo "missing or invalid ${PLUGIN_SIG} (needs 64 bytes): re-run the vendored-artifact deploy step" >&2
    exit 1
fi
install -Dm0755 "${PLUGIN_SRC}" "${DIST_DIR}/fractalsql-reasoning-http.${PLATFORM_TAG}.so"
install -Dm0644 "${PLUGIN_SIG}" "${DIST_DIR}/fractalsql-reasoning-http.${PLATFORM_TAG}.so.sig"
echo "staged ${DIST_DIR}/fractalsql-reasoning-http.${PLATFORM_TAG}.so and its .sig"

# ---------------------------------------------------------------------
# Artifact 2: .zip bundle with LICENSE + LICENSE-THIRD-PARTY + README.
# ---------------------------------------------------------------------
ZIP_NAME="fractalsql-ext-${DUCKDB_VERSION}-${PLATFORM_TAG}.zip"
ZIP_OUT="${DIST_DIR}/${ZIP_NAME}"

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

install -Dm0644 "${SRC_EXT}"                "${STAGE}/${EXT_NAME}"
install -Dm0755 "${PLUGIN_SRC}"             "${STAGE}/fractalsql-reasoning-http.so"
install -Dm0644 "${PLUGIN_SIG}"             "${STAGE}/fractalsql-reasoning-http.so.sig"
install -Dm0644 LICENSE                     "${STAGE}/LICENSE"

# The third-party notice is rendered per build so it names the DuckDB version this cell is for. No DuckDB code is
# compiled into the extension any more (it calls the engine through its C extension API), so there is no DuckDB
# copyright line to capture.
bash scripts/render_notices.sh \
    THIRD-PARTY-NOTICES.md "${STAGE}/LICENSE-THIRD-PARTY" \
    "${VERSION}" "${DUCKDB_VERSION}" "${PLATFORM_TAG}"

install -Dm0644 sql/load_extension.sql      "${STAGE}/load_extension.sql"
cat > "${STAGE}/README.txt" <<EOF
fractalsql-ext ${VERSION} Community (${DUCKDB_VERSION} / ${PLATFORM_TAG})

This archive ships an UNSIGNED DuckDB extension. Load it with the
-unsigned CLI flag (DuckDB 1.1+ rejects a runtime SET for this):

    duckdb -unsigned \\
        -cmd "LOAD '\$(pwd)/${EXT_NAME}';"

SQL surface:
    fractal_edition()          VARCHAR   -- 'Community'
    fractal_version()          VARCHAR   -- '${VERSION}'
    fractal_sfs_converge(vec, query)    DOUBLE    -- SFS-refined cosine distance

Programmatic (Python):
    import duckdb
    con = duckdb.connect(config={'allow_unsigned_extensions': True})
    con.load_extension('/path/to/${EXT_NAME}')
    con.sql("SELECT fractal_edition(), fractal_version()").show()

This file is for DuckDB ${DUCKDB_VERSION}. The loader refuses a file built for a
different DuckDB release line.

Licensing:
    LICENSE                Apache-2.0, this archive's source-code terms.
    LICENSE-THIRD-PARTY    Notices for the bundled third-party components.

DuckDB is a trademark of the DuckDB Foundation. FractalSQL is not
affiliated with or endorsed by the DuckDB Foundation.

See load_extension.sql in this archive for more examples.
EOF

(
    cd "${STAGE}"
    zip -9 -r "${OLDPWD}/${ZIP_OUT}" . > /dev/null
)
rm -rf "${STAGE}"
trap - EXIT

echo "built ${ZIP_OUT}"
echo
echo "Done. Artifacts in ${DIST_DIR}:"
ls -l "${DIST_DIR}"
