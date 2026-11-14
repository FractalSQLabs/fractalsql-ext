#!/bin/sh
#
# scripts/easy_install.sh -- the "easy button" for FractalSQL on DuckDB.
#
# One command takes a bare Linux or macOS box from nothing to a loaded
# extension: it downloads the release artifact that matches the local
# platform and the DuckDB version you target, verifies it, places it in
# DuckDB's local extension directory, and prints the exact LOAD line.
#
# A DuckDB extension is not a system package: there is no .deb, .rpm or
# .msi here and nothing is registered with the OS. Install means "the
# file sits where DuckDB's own layout expects it" and uninstall means
# "delete the file".
#
# Usage (release asset):
#   curl -fsSL <easy_install.sh URL> | sh
#
# Usage (repo checkout / already-downloaded copy):
#   ./scripts/easy_install.sh [flags]
#
# Flags (all optional):
#   --duckdb <path>          duckdb CLI to use (also env DUCKDB_BIN)
#   --duckdb-version <ver>   DuckDB release to match, e.g. v1.5.6
#                            (default: detected from the CLI if its
#                            version is a shipped cell, else v1.5.6)
#   --platform <tag>         DuckDB platform tag override
#                            (linux_amd64 | linux_arm64 | osx_amd64 |
#                            osx_arm64; normally detected)
#   --release <tag>          FractalSQL release tag to download from
#                            (default: the latest release)
#   --from-dir <dir>         take the extension (and LICENSE notices) from this
#                            directory instead of downloading a release; the
#                            file name is the release asset name. For CI and
#                            for installing a build you made yourself
#   --no-mcp                 do not install the MCP server (installed by default,
#                            from the bundle's mcp/ folder, next to its DuckDB
#                            library; see docs/mcp-plugin.md)
#   --with-reasoning         also fetch the reasoning plugin
#                            (fractalsql-reasoning-http). Optional tier;
#                            needs libcurl on the host and an LLM
#                            endpoint -- see docs/reasoning-setup.md
#   --uninstall              remove the installed files
#   --dry-run                print what would happen, change nothing
#   --no-verify              skip the LOAD smoke test
#   --yes                    answer "yes" to the uninstall prompt
#   -h, --help
#
# Env vars:
#   DUCKDB_BIN               duckdb CLI to target (same as --duckdb)
#
# No telemetry. This script never reports what it found or what it did.

set -eu

# --- constants -----------------------------------------------------------
REPO="FractalSQLabs/fractalsql-ext"
BASE_URL="https://github.com/${REPO}"
DUCKDB_VERSION_DEFAULT="v1.5.6"
# The DuckDB releases this build's CI uploads (release.yml).
SUPPORTED_DUCKDB_VERSIONS="v1.4.5 v1.5.6 v2.0.0"
# DuckDB's own extension directory (its default extension_directory). A file here as
# <root>/<duckdb_version>/<platform>/fractalsql.duckdb_extension is what `LOAD 'fractalsql'` finds.
INSTALL_ROOT="${HOME}/.duckdb/extensions"
# The MCP server (one per DuckDB version and platform, because it runs on that version's libduckdb) goes to
# <root>/<duckdb_version>/<platform>/, with its library, lock files and manifest beside it.
MCP_ROOT="${HOME}/.duckdb/fractalsql-mcp"
# Where earlier versions of this script wrote. Nothing but our own files ever lived there; it is cleaned up on
# install and on uninstall.
LEGACY_ROOT="${HOME}/.duckdb/extensions.local/fractalsql"

# --- output helpers --------------------------------------------------------
# Plain text output: easy_install output gets pasted into issues, so no
# ANSI colouring and no unicode glyph guessing. Keep the markers plain.

log()  { printf '==> %s\n' "$1"; }
ok()   { printf '  ok: %s\n' "$1"; }
warn() { printf '  warn: %s\n' "$1" >&2; }
err()  { printf '  error: %s\n' "$1" >&2; }
die()  { local msg="$1"; err "${msg}"; exit 1; }

confirm() {  # confirm "question" -> 0=yes 1=no
    if [ "${YES}" -eq 1 ]; then ok "$1 -> yes (--yes)"; return 0; fi
    [ -e /dev/tty ] || die "'$1' needs an answer but there is no terminal (run non-interactively with --yes)."
    reply=""
    printf '%s [y/N] ' "$1" > /dev/tty
    read -r reply < /dev/tty || true
    case "$reply" in
        y|Y|yes|Yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# --- version ---------------------------------------------------------------
# Stamped in by release.yml (the placeholder below is replaced with the tag's version before this file is uploaded
# as a release asset). A stamped script installs the release it was published with, so the copy on the v2.0.0 release
# page installs v2.0.0 and not whatever is latest; --release still overrides. Run from a checkout (unstamped) it
# keeps the old default of the latest release.
FSQL_VERSION="@@FSQL_VERSION@@"
FSQL_STAMPED=1
case "${FSQL_VERSION}" in @@*) FSQL_STAMPED=0; FSQL_VERSION="" ;; esac

# --- state -----------------------------------------------------------------
DUCKDB_BIN="${DUCKDB_BIN:-}"
TARGET_DUCKDB_VERSION=""
PLATFORM_TAG=""
RELEASE_TAG=""
WITH_REASONING=0
WITH_MCP=1
MCP_DIR=""
FROM_DIR=""
UNINSTALL=0
DRY_RUN=0
NO_VERIFY=0
YES=0

usage() { sed -n '3,51p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# --- arg parsing -----------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --duckdb)          DUCKDB_BIN="$2"; shift 2 ;;
        --duckdb-version)  TARGET_DUCKDB_VERSION="$2"; shift 2 ;;
        --platform)        PLATFORM_TAG="$2"; shift 2 ;;
        --release)         RELEASE_TAG="$2"; shift 2 ;;
        --from-dir)        FROM_DIR="${2:?--from-dir needs a directory}"; shift 2 ;;
        --with-reasoning)  WITH_REASONING=1; shift ;;
        --no-mcp)          WITH_MCP=0; shift ;;
        --uninstall)       UNINSTALL=1; shift ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --no-verify)       NO_VERIFY=1; shift ;;
        --yes)             YES=1; shift ;;
        -h|--help)         usage ;;
        *) die "unknown flag: $1 (see --help)" ;;
    esac
done

EXT_NAME="fractalsql.duckdb_extension"
if [ -z "${RELEASE_TAG}" ] && [ "${FSQL_STAMPED}" = 1 ]; then RELEASE_TAG="v${FSQL_VERSION}"; fi

# --- duckdb CLI detection ---------------------------------------------------
# Optional: without a CLI the script still downloads and places the file,
# it just cannot auto-detect the version or smoke-test the load.
resolve_duckdb() {
    if [ -z "${DUCKDB_BIN}" ]; then
        if command -v duckdb >/dev/null 2>&1; then
            DUCKDB_BIN="duckdb"
        else
            DUCKDB_BIN=""
        fi
    else
        [ -x "${DUCKDB_BIN}" ] || [ -n "$(command -v "${DUCKDB_BIN}" 2>/dev/null)" ] \
            || die "DUCKDB_BIN/--duckdb is '${DUCKDB_BIN}' but that is not executable."
    fi
}

# Try to read the CLI's own DuckDB version (first token of --version).
duckdb_cli_version() {
    [ -n "${DUCKDB_BIN}" ] || return 1
    "${DUCKDB_BIN}" --version 2>/dev/null | awk 'NR==1 {print $1}'
}

# --- platform detection -----------------------------------------------------
# Maps to the DuckDB platform tags used in release artifact names:
# linux_amd64, linux_arm64, osx_amd64, osx_arm64, windows_amd64.
detect_platform() {
    if [ -n "${PLATFORM_TAG}" ]; then
        case "${PLATFORM_TAG}" in
            linux_amd64|linux_arm64|osx_amd64|osx_arm64) ;;
            *) die "unknown --platform '${PLATFORM_TAG}' (expected linux_amd64, linux_arm64, osx_amd64, or osx_arm64). For Windows use scripts/windows/easy_install.ps1." ;;
        esac
        return
    fi
    ARCH="$(uname -m)"
    case "${ARCH}" in
        x86_64|amd64)   ARCH_TAG="amd64" ;;
        arm64|aarch64)  ARCH_TAG="arm64" ;;
        *) die "unsupported architecture: ${ARCH}" ;;
    esac
    case "$(uname -s)" in
        Linux)  PLATFORM_TAG="linux_${ARCH_TAG}" ;;
        Darwin) PLATFORM_TAG="osx_${ARCH_TAG}" ;;
        CYGWIN*|MINGW*|MSYS*)
            die "this is Windows (via an MSYS/Cygwin shell). Run scripts/windows/easy_install.ps1 from PowerShell instead."
            ;;
        *) die "unsupported OS family: $(uname -s). This script covers Linux and macOS; Windows uses easy_install.ps1." ;;
    esac
}

# DuckDB's own extension layout:
#   ~/.duckdb/extensions/<duckdb_version>/<platform>/fractalsql.duckdb_extension
# With the file there, LOAD 'fractalsql' resolves the short name (run the CLI with -unsigned: the
# extension is not signed by DuckDB). The directory is shared with every other extension, so every
# file this script adds beside the extension carries a fractalsql prefix and uninstall removes exactly
# those files and nothing else. A custom `SET extension_directory` is not known to this script.
cell_dir() {
    printf '%s/%s/%s' "${INSTALL_ROOT}" "${TARGET_DUCKDB_VERSION}" "${PLATFORM_TAG}"
}

# --- which DuckDB release to match -----------------------------------------
# Normalize to the "vX.Y.Z" asset spelling regardless of how the version
# arrived (flag, prompt, or CLI detection), so "1.5.6" and "v1.5.6" hit
# the same release cell.
normalize_duckdb_version() {
    TARGET_DUCKDB_VERSION="v$(printf '%s' "${TARGET_DUCKDB_VERSION}" | sed 's/^[vV]*//')"
}

resolve_duckdb_version() {
    if [ -n "${TARGET_DUCKDB_VERSION}" ]; then
        normalize_duckdb_version
        return
    fi
    # Prefer the version a found CLI actually runs.
    CLI_VERSION="$(duckdb_cli_version || true)"
    if [ -n "${CLI_VERSION:-}" ]; then
        for v in ${SUPPORTED_DUCKDB_VERSIONS}; do
            if [ "${CLI_VERSION#v}" = "${v#v}" ]; then
                TARGET_DUCKDB_VERSION="${v}"
                log "duckdb CLI reports ${CLI_VERSION}; matching its release cell."
                return
            fi
        done
        warn "duckdb CLI reports ${CLI_VERSION}, which is not a cell this release ships (supported: ${SUPPORTED_DUCKDB_VERSIONS})."
    fi
    TARGET_DUCKDB_VERSION="${DUCKDB_VERSION_DEFAULT}"
    # Interactive prompt only when a terminal is attached and no CLI
    # could answer the question for us.
    if [ -t 0 ] && [ -e /dev/tty ] && [ "${UNINSTALL}" -ne 1 ]; then
        printf 'DuckDB version to target [%s] (supported: %s): ' \
            "${TARGET_DUCKDB_VERSION}" "${SUPPORTED_DUCKDB_VERSIONS}" > /dev/tty
        reply=""
        read -r reply < /dev/tty || true
        case "${reply}" in
            "") ;;
            *) TARGET_DUCKDB_VERSION="${reply}" ;;
        esac
    fi
    normalize_duckdb_version
}

# --- download helpers --------------------------------------------------------
# Every call goes out over https only (--proto '=https'), matching the
# release-hosting contract.
fetch() {  # fetch <url> <outfile>
    if [ -n "${FROM_DIR}" ]; then   # --from-dir: the asset is a file in that directory, named like the release asset
        if [ -f "${FROM_DIR}/$(basename "$1")" ]; then
            if [ "${DRY_RUN}" -eq 1 ]; then log "(--dry-run) would copy: ${FROM_DIR}/$(basename "$1")"; printf 'dry-run placeholder\n' > "$2"
            else log "Using $(basename "$1") from ${FROM_DIR}"; cp "${FROM_DIR}/$(basename "$1")" "$2"; fi
            return 0
        fi
        return 1
    fi
    command -v curl >/dev/null 2>&1 \
        || die "no curl on PATH. Install curl and re-run."
    if [ "${DRY_RUN}" -eq 1 ]; then
        log "(--dry-run) would download: $1"
        # Write a token body so later dry-run steps have a file to talk about.
        printf 'dry-run placeholder\n' > "$2"
        return 0
    fi
    log "Downloading $(basename "$2")..."
    if ! curl -fsSL --proto '=https' "$1" -o "$2"; then
        rm -f "$2"
        return 1
    fi
}

# Verify <file> against the release's SHA256SUMS. Missing SHA256SUMS or no line for the file: warn.
# Mismatch: hard stop.
sha_tool() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        printf ''
    fi
}

verify_sha256() {  # verify_sha256 <file> <SHA256SUMS-url>
    if [ "${DRY_RUN}" -eq 1 ]; then
        log "(--dry-run) skipping checksum comparison."
        return 0
    fi
    tmp="$(mktemp "${TMPDIR:-/tmp}/fsql_sha.XXXXXX")"
    if ! fetch "$2" "${tmp}" 2>/dev/null; then
        warn "no SHA256SUMS listed for this release; verification skipped (checksum your download some other way)."
        rm -f "${tmp}"
        return 0
    fi
    name="$(basename "$1")"
    expected="$(awk -v n="${name}" '$2 == n || $2 == "*" n {print $1; exit}' "${tmp}")"
    rm -f "${tmp}"
    if [ -z "${expected}" ]; then
        warn "SHA256SUMS has no line for ${name}; verification skipped."
        return 0
    fi
    actual="$(sha_tool "$1")"
    if [ -z "${actual}" ]; then
        warn "no sha256sum/shasum on PATH; cannot compare the checksum."
        return 0
    fi
    if [ "${expected}" != "${actual}" ]; then
        die "sha256 mismatch for ${name} (expected ${expected}, got ${actual}). Delete the file and retry."
    fi
    ok "sha256 verified."
}

# --- install / uninstall -----------------------------------------------------
# --- the MCP server -----------------------------------------------------------
mcp_dir() { printf '%s/%s/%s' "${MCP_ROOT}" "${TARGET_DUCKDB_VERSION}" "${PLATFORM_TAG}"; }

# The server needs OpenSSL at run time: Homebrew's openssl@3 on macOS, the system libssl on Linux. libduckdb is
# beside the binary. Say what is missing now, instead of leaving a dynamic-linker error for later. Not fatal: the
# extension itself does not use OpenSSL and is already installed.
mcp_check_libs() {  # mcp_check_libs <binary>
    case "$(uname -s)" in
        Darwin)
            lib="$(otool -L "$1" 2>/dev/null | awk '/libssl/ {print $1; exit}')"
            if [ -n "${lib}" ] && [ ! -f "${lib}" ]; then
                warn "the MCP server needs Homebrew's openssl@3, which is not installed (${lib} is missing). Install it:  brew install openssl@3"
            fi ;;
        Linux)
            missing="$(ldd "$1" 2>/dev/null | awk '/not found/ {print $1}' | tr '\n' ' ')"
            if [ -n "${missing}" ]; then
                warn "the MCP server cannot find: ${missing}. Install OpenSSL's runtime library (libssl3 on Debian/Ubuntu, openssl-libs on RHEL) and re-run."
            fi ;;
    esac
}

install_mcp() {
    [ "${WITH_MCP}" -eq 1 ] || { log "Skipping the MCP server (--no-mcp)."; return 0; }
    if [ "${DRY_RUN}" -eq 1 ]; then
        log "(--dry-run) would install the MCP server from the bundle's mcp/ into $(mcp_dir)/"
        return 0
    fi
    if [ ! -d "${SRC_DIR}/mcp" ]; then
        warn "no mcp/ folder in ${SRC_DIR} (a bare --from-dir has none); the MCP server was not installed."
        return 0
    fi
    MCP_DIR="$(mcp_dir)"
    mkdir -p "${MCP_DIR}"
    cp -R "${SRC_DIR}/mcp/." "${MCP_DIR}/"
    chmod +x "${MCP_DIR}/fractalsql-ext-mcp" 2>/dev/null || true
    ok "Installed the MCP server into ${MCP_DIR}"
    mcp_check_libs "${MCP_DIR}/fractalsql-ext-mcp"
}

print_mcp() {
    [ -n "${MCP_DIR}" ] && [ "${DRY_RUN}" -ne 1 ] || return 0
    log "Start the MCP server (stdio) against the installed extension with:"
    printf '  FSQL_DUCKDB_EXTENSION=%s FSQL_DUCKDB_ALLOW_UNSIGNED=true %s/fractalsql-ext-mcp\n' "${INSTALLED_PATH}" "${MCP_DIR}"
    printf '  (add --http PORT for the HTTP transport; see %s/README.md)\n' "${MCP_DIR}"
}

install_cell() {
    EXT_ASSET="fractalsql.${TARGET_DUCKDB_VERSION}.${PLATFORM_TAG}.duckdb_extension"
    BUNDLE_DIR_NAME="fractalsql-ext-${TARGET_DUCKDB_VERSION}-${PLATFORM_TAG}"
    BUNDLE_ASSET="${BUNDLE_DIR_NAME}.tar.gz"
    if [ -n "${RELEASE_TAG}" ]; then
        ASSET_BASE="${BASE_URL}/releases/download/${RELEASE_TAG}"
    else
        ASSET_BASE="${BASE_URL}/releases/latest/download"
    fi

    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fsql_ext.XXXXXX")"
    trap 'rm -rf "${TMP_DIR}"' EXIT INT TERM

    # One bundle per (DuckDB version, platform): the extension, the reasoning plugin with its .sig, the MCP
    # server and the licences. Only the extension (and, on request, the plugin) is installed from it.
    SRC_DIR=""
    if fetch "${ASSET_BASE}/${BUNDLE_ASSET}" "${TMP_DIR}/${BUNDLE_ASSET}"; then
        verify_sha256 "${TMP_DIR}/${BUNDLE_ASSET}" "${ASSET_BASE}/SHA256SUMS"
        if [ "${DRY_RUN}" -eq 1 ]; then
            log "(--dry-run) would unpack ${BUNDLE_ASSET}"
            SRC_DIR="${TMP_DIR}/${BUNDLE_DIR_NAME}"; mkdir -p "${SRC_DIR}"
            printf 'dry-run placeholder\n' > "${SRC_DIR}/${EXT_ASSET}"
        else
            command -v tar >/dev/null 2>&1 || die "no tar on PATH. Install tar and re-run."
            tar -xzf "${TMP_DIR}/${BUNDLE_ASSET}" -C "${TMP_DIR}" \
                || die "could not unpack ${BUNDLE_ASSET} (a damaged download? delete it and retry)."
            SRC_DIR="${TMP_DIR}/${BUNDLE_DIR_NAME}"
            [ -f "${SRC_DIR}/${EXT_ASSET}" ] || die "${BUNDLE_ASSET} does not contain ${EXT_ASSET}."
        fi
    elif [ -n "${FROM_DIR}" ] && [ -f "${FROM_DIR}/${EXT_ASSET}" ]; then
        # --from-dir may also point at a directory holding the bare extension (a local build under dist/).
        SRC_DIR="${FROM_DIR}"
        log "Using ${EXT_ASSET} from ${FROM_DIR}"
    else
        die "download failed: ${BUNDLE_ASSET}. Check that the release page (https://github.com/${REPO}/releases) has a bundle for DuckDB ${TARGET_DUCKDB_VERSION} / ${PLATFORM_TAG}, or pass --duckdb-version for a still-listed cell."
    fi

    DEST_DIR="$(cell_dir)"
    if [ "${DRY_RUN}" -eq 1 ]; then
        log "(--dry-run) would install ${EXT_ASSET} into ${DEST_DIR}/"
    else
        mkdir -p "${DEST_DIR}"
        cp "${SRC_DIR}/${EXT_ASSET}" "${DEST_DIR}/${EXT_NAME}"
        ok "Installed ${DEST_DIR}/${EXT_NAME}"
        if [ -d "${LEGACY_ROOT}" ]; then
            rm -rf "${LEGACY_ROOT}"
            ok "Removed the old install under ${LEGACY_ROOT} (earlier versions of this script put the extension there; DuckDB never looked in it)."
        fi
    fi
    INSTALLED_PATH="${DEST_DIR}/${EXT_NAME}"

    # Optional reasoning tier: the plugin ships in the bundle together with its detached Ed25519 signature
    # (fractalsql-reasoning-http.so and .so.sig). The plugin loads only with the .sig beside it, so both are
    # installed. The default flow stays extension-only.
    if [ "${WITH_REASONING}" -eq 1 ]; then
        PLUGIN_NAME="fractalsql-reasoning-http.so"
        if [ "${DRY_RUN}" -eq 1 ]; then
            log "(--dry-run) would install ${PLUGIN_NAME} and ${PLUGIN_NAME}.sig into ${DEST_DIR}/"
        else
            [ -f "${SRC_DIR}/${PLUGIN_NAME}" ] && [ -f "${SRC_DIR}/${PLUGIN_NAME}.sig" ] \
                || die "the reasoning plugin and its .sig are not in ${SRC_DIR}. Check that the release bundle ${BUNDLE_ASSET} carries them."
            cp "${SRC_DIR}/${PLUGIN_NAME}" "${DEST_DIR}/${PLUGIN_NAME}"
            cp "${SRC_DIR}/${PLUGIN_NAME}.sig" "${DEST_DIR}/${PLUGIN_NAME}.sig"
            ok "Installed ${DEST_DIR}/${PLUGIN_NAME} (with its .sig)"
        fi
        PLUGIN_PATH="${DEST_DIR}/${PLUGIN_NAME}"
    else
        log "Skipping the reasoning plugin (optional tier). To add it later, re-run with --with-reasoning; configuration is documented in docs/reasoning-setup.md (env vars only: FRACTALSQL_REASONING_PLUGIN plus FSQL_REASONING_HTTP_*)."
    fi

    # The licence notices travel in the bundle. Write them into the install directory next to the extension --
    # and next to the plugin, which lands in the same directory -- so the installed copy carries the notices.
    # A source without them (a bare --from-dir) is not a hard error: warn and carry on.
    for NOTICE in LICENSE LICENSE-THIRD-PARTY; do
        if [ "${DRY_RUN}" -eq 1 ]; then
            log "(--dry-run) would write fractalsql-${NOTICE} into ${DEST_DIR}/"
        elif [ -f "${SRC_DIR}/${NOTICE}" ]; then
            cp "${SRC_DIR}/${NOTICE}" "${DEST_DIR}/fractalsql-${NOTICE}"
            ok "Installed ${DEST_DIR}/fractalsql-${NOTICE}"
        else
            warn "no ${NOTICE} in ${SRC_DIR}; the notices are not installed beside the extension."
        fi
    done

    install_mcp
}

uninstall_flow() {
    local d f; d="$(cell_dir)"
    log "This deletes FractalSQL's files from ${d}/ (${EXT_NAME}, the notices and the reasoning plugin if present),"
    log "the MCP server in $(mcp_dir)/, and the old ${LEGACY_ROOT}/ if it exists. Other extensions in that directory are not touched."
    if confirm "Remove them?"; then
        if [ "${DRY_RUN}" -eq 1 ]; then
            log "(--dry-run) not actually removing."
        else
            for f in "${EXT_NAME}" fractalsql-LICENSE fractalsql-LICENSE-THIRD-PARTY \
                     fractalsql-reasoning-http.so fractalsql-reasoning-http.so.sig fractalsql-reasoning-http.dylib; do
                rm -f "${d}/${f}"
            done
            rm -rf "$(mcp_dir)"
            rmdir "${MCP_ROOT}/${TARGET_DUCKDB_VERSION}" "${MCP_ROOT}" 2>/dev/null || true
            rm -rf "${LEGACY_ROOT}"
            ok "Removed. DuckDB extensions leave no other trace."
        fi
    fi
}

# --- load snippet + proof -----------------------------------------------------
# With the file under DuckDB's extension.local layout, LOAD 'fractalsql'
# resolves the short path. The full-path form inside the LOAD is the
# unambiguous one, so the printed one-liner uses it.
print_load() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        return 0
    fi
    log "Load it (and check the version) with:"
    printf '  duckdb -unsigned -c "LOAD '\''%s'\''; SELECT fractal_edition(), fractal_version();"\n' "${INSTALLED_PATH}"
    printf '  (short form from any session, since the file sits in DuckDB'\''s own extension directory:\n   duckdb -unsigned -c "LOAD '\''fractalsql'\''")\n'
}

# Attempt the LOAD with the found CLI and print edition + version. Never
# required: --no-verify, or no CLI on the machine, skips it.
run_proof() {
    [ "${NO_VERIFY}" -eq 0 ] || { log "Skipping the LOAD proof (--no-verify)."; return 0; }
    [ -n "${DUCKDB_BIN}" ] || { log "No duckdb CLI found; after installing it, print this script's LOAD line and run it yourself."; return 0; }
    if [ "${DRY_RUN}" -eq 1 ]; then return 0; fi
    log "Smoke-testing the load with ${DUCKDB_BIN}..."
    PROOF_OUT="$(${DUCKDB_BIN} -unsigned -c "LOAD '${INSTALLED_PATH}'; SELECT fractal_edition(), fractal_version();" 2>&1 || true)"
    printf '%s\n' "${PROOF_OUT}" | sed 's/^/  /'
    case "${PROOF_OUT}" in
        *Community*)
            ok "Proof: the extension reports the FractalSQL Community edition." ;;
        *)
            warn "The LOAD output above does not show 'Community'. If the platform tag or DuckDB version does not match your build, the loader refuses the file with an ABI error." ;;
    esac
}

# --- reasoning wizard -----------------------------------------------------------
# With --with-reasoning and an interactive terminal: prompt for the chat
# endpoint and model (Ollama-shaped defaults) plus embedding model and
# token, print the export lines, and offer a live round-trip through the
# fresh install. Non-interactive shells (CI, `curl | sh`) skip the
# prompts; the export lines are what a human needs either way.

ask() {  # ask <label> <default> => answered or default value
    local label="$1" dflt="$2" reply=""
    printf '%s [%s] ' "${label}" "${dflt}" > /dev/tty
    read -r reply < /dev/tty || true
    if [ -n "${reply}" ]; then printf '%s' "${reply}"; else printf '%s' "${dflt}"; fi
}

ask_secret() {  # ask_secret <label> => masked single line, not echoed
    local label="$1" reply=""
    printf '%s (masked input) ' "${label}" > /dev/tty
    # -s on read is a bashism; this script is /bin/sh, so toggle the
    # terminal echo instead (best effort -- a pipe-backed tty stub just
    # prints the token, which is still never logged).
    stty -echo < /dev/tty 2>/dev/null || true
    read -r reply < /dev/tty || true
    stty echo < /dev/tty 2>/dev/null || true
    printf '\n' > /dev/tty
    printf '%s' "${reply}"
}

run_reasoning_wizard() {
    [ "${WITH_REASONING}" -eq 1 ] || return 0
    [ -n "${PLUGIN_PATH}" ] || return 0
    [ "${DRY_RUN}" -ne 1 ] || return 0
    if [ ! -e /dev/tty ]; then
        log "non-interactive shell: reasoning prompts skipped; set FSQL_REASONING_HTTP_URL / FSQL_REASONING_HTTP_MODEL before starting duckdb (docs/reasoning-setup.md)."
        return 0
    fi

    log "Reasoning provider setup:"
    RW_URL="$(ask "Chat URL" "http://127.0.0.1:11434/v1/chat/completions")"
    RW_MODEL="$(ask "Chat model" "gpt-oss:20b")"
    RW_EMBED_MODEL="$(ask "Embedding model" "nomic-embed-text")"
    RW_TOKEN="$(ask_secret "API token (empty for none)")"

    log "Set these in the shell that starts duckdb (per process):"
    printf '  export FSQL_REASONING_HTTP_URL=%s\n' "${RW_URL}"
    if [ -n "${RW_TOKEN}" ]; then
        printf '  export FSQL_REASONING_HTTP_TOKEN=<your token>\n'
    fi
    printf '  export FSQL_REASONING_HTTP_MODEL=%s\n' "${RW_MODEL}"
    printf '  export FSQL_REASONING_HTTP_EMBED_MODEL=%s\n' "${RW_EMBED_MODEL}"
    case "${RW_URL}" in
        http://*) log "That URL is plain http, so also export FSQL_REASONING_HTTP_ALLOW_PLAINTEXT=on for local endpoints." ;;
    esac

    if [ ! "${NO_VERIFY}" -eq 0 ] && [ -n "${DUCKDB_BIN}" ] \
       && confirm "Run a live reasoning smoke test (SELECT fractal_reason('say ok'))? A cloud endpoint may incur cost, and a cold local model can take minutes."; then
        export FRACTALSQL_REASONING_PLUGIN="${PLUGIN_PATH}"
        export FSQL_REASONING_HTTP_URL="${RW_URL}"
        if [ -n "${RW_TOKEN}" ]; then export FSQL_REASONING_HTTP_TOKEN="${RW_TOKEN}"; fi
        export FSQL_REASONING_HTTP_MODEL="${RW_MODEL}"
        export FSQL_REASONING_HTTP_EMBED_MODEL="${RW_EMBED_MODEL}"
        case "${RW_URL}" in
            http://*) export FSQL_REASONING_HTTP_ALLOW_PLAINTEXT=on ;;
        esac
        log "Reasoning smoke test: fractal_reason('say ok')..."
        RW_OUT="$(${DUCKDB_BIN} -unsigned -c "LOAD '${INSTALLED_PATH}'; SELECT fractal_reason('say ok');" 2>&1 || true)"
        unset FSQL_REASONING_HTTP_URL FSQL_REASONING_HTTP_TOKEN FSQL_REASONING_HTTP_MODEL
        unset FSQL_REASONING_HTTP_EMBED_MODEL FSQL_REASONING_HTTP_ALLOW_PLAINTEXT
        # The plugin prints one line per settled config value before the
        # model's actual answer, and the answer sits at the tail of the
        # captured output, so show the tail and not the head.
        printf '%s\n' "${RW_OUT}" | sed 's/^/  /' | tail -5
        case "${RW_OUT}" in
            *[Ee]rror*|"not configured"*)
                warn "That output does not look like a model reply."
                warn "If it looks like a timeout on a slow or cold model, retry after the model warms up, or raise the wait ceilings first: FSQL_REASONING_HTTP_TIMEOUT_MS (total) and FSQL_REASONING_HTTP_LOW_SPEED_SECS (slow-response window), set in the shell before starting duckdb. See docs/reasoning-setup.md 'Handling Constrained Hardware'." ;;
            *)
                ok "Reasoning round-trip returned a reply (tail above)." ;;
        esac
    else
        ok "Reasoning configured on paper; run the smoke yourself with the exports above."
    fi
}

# --- main ---------------------------------------------------------------------
main() {
    resolve_duckdb
    detect_platform
    resolve_duckdb_version

    log "Platform: ${PLATFORM_TAG} | DuckDB target: ${TARGET_DUCKDB_VERSION} | install root: ${INSTALL_ROOT}"

    if [ "${UNINSTALL}" -eq 1 ]; then
        uninstall_flow
        exit 0
    fi

    install_cell
    print_load
    print_mcp
    run_proof

    if [ "${WITH_REASONING}" -eq 1 ] && [ "${DRY_RUN}" -ne 1 ]; then
        log "Reasoning plugin at ${PLUGIN_PATH}. Activate it per process:"
        printf '  export FRACTALSQL_REASONING_PLUGIN=%s\n' "${PLUGIN_PATH}"
        log "Then set FSQL_REASONING_HTTP_URL / FSQL_REASONING_HTTP_MODEL (etc.) -- full walkthrough in docs/reasoning-setup.md."
        run_reasoning_wizard
    fi

    ok "Done. Re-running this script is safe; it just re-copies the extension."
}

main "$@"