#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# Download one DuckDB release asset and unpack it.
#
#   scripts/fetch_duckdb.sh cli|libs VERSION OS ARCH DEST
#
#   VERSION  a release tag, e.g. v1.5.6 or v2.0.0
#   OS       linux | osx | windows
#   ARCH     amd64 | arm64 | universal (osx); "aarch64" is accepted for arm64
#   DEST     directory to unpack into (created)
#
# cli   leaves the `duckdb` command line client in DEST.
# libs  leaves libduckdb (.so/.dylib/.dll) and the C headers in DEST.
#
# DuckDB renamed its release assets in 2.0.0: up to 1.x they are duckdb_cli-<os>-<arch>.zip and
# libduckdb-<os>-<arch>.zip; from 2.0.0 they are duckdb-cli-<os>-<arch>.tar.gz and
# duckdb-shared-libs-<os>-<arch>.tar.gz. Every arm64 asset is named "arm64", never "aarch64".
set -euo pipefail

[ $# -eq 5 ] || { sed -n 4,20p "$0" >&2; exit 2; }
kind="$1"; ver="$2"; os="$3"; arch="$4"; dest="$5"
[ "$arch" = aarch64 ] && arch=arm64
major="${ver#v}"; major="${major%%.*}"
base="https://github.com/duckdb/duckdb/releases/download/${ver}"

case "$kind" in
  cli)  new="duckdb-cli-${os}-${arch}.tar.gz";         old="duckdb_cli-${os}-${arch}.zip" ;;
  libs) new="duckdb-shared-libs-${os}-${arch}.tar.gz"; old="libduckdb-${os}-${arch}.zip" ;;
  *) echo "fetch_duckdb: unknown kind '$kind' (cli or libs)" >&2; exit 2 ;;
esac

mkdir -p "$dest"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fsql-fetch-duckdb.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

if [ "$major" -ge 2 ]; then
  curl -fsSL --proto '=https' --retry 3 "${base}/${new}" -o "$tmp/asset"
  tar -xzf "$tmp/asset" -C "$dest"
else
  curl -fsSL --proto '=https' --retry 3 "${base}/${old}" -o "$tmp/asset"
  if command -v unzip >/dev/null 2>&1; then
    unzip -oq "$tmp/asset" -d "$dest"
  else
    python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$tmp/asset" "$dest"
  fi
fi
[ "$kind" = cli ] && chmod +x "$dest/duckdb" 2>/dev/null || true
echo "fetch_duckdb: ${kind} ${ver} ${os}-${arch} -> ${dest}"
