#!/usr/bin/env bash
#
# scripts/package_mcp_rocky.sh <duckdb_version> [amd64|arm64]
#
# Runs scripts/package_mcp.sh inside rockylinux:9, so the archive's binary is linked against glibc 2.34 and runs on
# every current distro (built on a CI runner's Ubuntu it needs glibc 2.36-2.38 and fails on Rocky 9 / Debian 11).
# This is what the release workflow and the install test use. The container needs only docker.
set -euo pipefail
cd "$(dirname "$0")/.."
DV="${1:?usage: scripts/package_mcp_rocky.sh <duckdb_version> [amd64|arm64]}"
ARCH="${2:-}"
[[ -n "${ARCH}" ]] || case "$(uname -m)" in x86_64|amd64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) echo "unsupported host arch" >&2; exit 2 ;; esac
mkdir -p dist/packages
docker run --rm -v "$PWD":/work -w /work -e LIBDUCKDB_DIR="${LIBDUCKDB_DIR_IN_CONTAINER:-}" rockylinux:9 bash -ec '
    dnf install -qy --enablerepo=crb gcc-c++ make libstdc++-static openssl-devel python3 binutils tar gzip >/dev/null
    bash scripts/package_mcp.sh "'"${DV}"'" "'"${ARCH}"'"
'
# files written by the container are root-owned; hand them back
if [[ "$(id -u)" != 0 ]]; then
    docker run --rm -v "$PWD":/work -w /work rockylinux:9 chown -R "$(id -u):$(id -g)" dist/packages >/dev/null 2>&1 || true
fi
