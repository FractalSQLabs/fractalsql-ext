#!/bin/bash
#
# fractalsql-ext build driver: the pure-C extension, built in the pinned glibc baseline (docker/Dockerfile),
# then laid out as one release cell per supported DuckDB version.
#
#   ./build.sh [amd64|arm64]
#
# Output, in dist/<arch>/ :
#
#   fractalsql.v1.4.5.linux_<arch>.duckdb_extension   1.4 band (C_STRUCT_UNSTABLE): exactly DuckDB 1.4.5
#   fractalsql.v1.5.6.linux_<arch>.duckdb_extension   stable band (C_STRUCT, v1.5.6 header)
#   fractalsql.v2.0.2.linux_<arch>.duckdb_extension   the same stable-band file: it loads on 2.0.0 as well
#
# Two builds, not three: the stable-API band is one binary that DuckDB 1.5.6 and 2.0.0 both accept, so those two
# cells are copies of it. The 1.4 line has an unstable API and gets a build of its own, tied to one 1.4.N
# (L_VERSION in the Makefile; rebuild when a new 1.4.x ships).
#
# Native, without Docker (any Linux or macOS host; not the pinned glibc baseline): make
# Sanitizer builds are not release artifacts: make SAN=address|undefined|thread, or build_test.sh gates 48 and 51.
#
# Env: DIST_DIR (default ./dist), STABLE_VERSIONS (default "v1.5.6 v2.0.0"), BUILDX_CACHE_ARGS.

set -euo pipefail

ARCH="${1:-amd64}"
case "${ARCH}" in
    amd64|arm64) ;;
    *) echo "unknown arch '${ARCH}' -- expected amd64 or arm64" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "unexpected argument '$2' (the profile and sanitizer options went away with the C++ build)" >&2; exit 2; }

DIST_DIR="${DIST_DIR:-./dist}"
STABLE_VERSIONS="${STABLE_VERSIONS:-v1.5.6 v2.0.0}"
OUT_DIR="${DIST_DIR}/${ARCH}"
STAGING_DIR="${OUT_DIR}/.staging"
BUILDX_CACHE_ARGS="${BUILDX_CACHE_ARGS:-}"

rm -rf "${STAGING_DIR}"
mkdir -p "${OUT_DIR}" "${STAGING_DIR}"

echo "------------------------------------------"
echo "Building fractalsql-ext (pure C)"
echo "  arch:            linux/${ARCH}"
echo "  stable band for: ${STABLE_VERSIONS}"
echo "  output:          ${OUT_DIR}"
echo "------------------------------------------"

DOCKER_BUILDKIT=1 docker buildx build \
    --platform "linux/${ARCH}" \
    --build-arg "BUILD_ARCH=${ARCH}" \
    ${BUILDX_CACHE_ARGS} \
    --target export \
    --output "type=local,dest=${STAGING_DIR}" \
    -f "${DOCKERFILE:-docker/Dockerfile}" \
    .

STABLE="${STAGING_DIR}/fractalsql.capi.linux_${ARCH}.duckdb_extension"
[ -f "${STABLE}" ] || { echo "the build did not produce ${STABLE}" >&2; exit 1; }
for v in ${STABLE_VERSIONS}; do
    install -m0644 "${STABLE}" "${OUT_DIR}/fractalsql.${v}.linux_${ARCH}.duckdb_extension"
done
# the 1.4 band keeps the name the build gave it (it already carries its 1.4.N)
found=0
for f in "${STAGING_DIR}"/fractalsql.v1.4.*.linux_"${ARCH}".duckdb_extension; do
    [ -f "$f" ] || continue
    install -m0644 "$f" "${OUT_DIR}/$(basename "$f")"; found=1
done
[ "${found}" -eq 1 ] || { echo "the build did not produce a 1.4 band file" >&2; exit 1; }
rm -rf "${STAGING_DIR}"

echo
echo "Built for ${ARCH}:"
ls -l "${OUT_DIR}"/fractalsql.v*.linux_"${ARCH}".duckdb_extension
