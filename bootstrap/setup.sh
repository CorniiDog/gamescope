#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

FORCE_SOURCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-from-source)
            FORCE_SOURCE=1
            shift
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

require_steamos
require_nvidia
ensure_sudo
verify_system_gamescope
need_cmd curl
need_cmd sha256sum
need_cmd tar

STEAMOS_VERSION="$(get_steamos_version)"
RELEASE_TAG="$(release_tag_for_steamos)"
ASSET_NAME="$(release_asset_for_steamos)"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log "Detected SteamOS ${STEAMOS_VERSION}."

if [[ "$FORCE_SOURCE" == "0" ]]; then
    BASE_URL="https://github.com/${GS_REPO}/releases/download/${RELEASE_TAG}"
    ARCHIVE="${TMP_DIR}/${ASSET_NAME}"
    SHA="${ARCHIVE}.sha256"
    RELEASE_DIR="${TMP_DIR}/release"

    log "Checking for ${RELEASE_TAG}..."

    ARCHIVE_HTTP="$(curl -sS -L --retry 2 -w '%{http_code}' "${BASE_URL}/${ASSET_NAME}" -o "$ARCHIVE")" ||
        die "Failed to contact GitHub while checking for a precompiled release."

    if [[ "$ARCHIVE_HTTP" == "404" ]]; then
        rm -f "$ARCHIVE"
        warn "No compatible precompiled release found."
    elif [[ "$ARCHIVE_HTTP" != "200" ]]; then
        die "Unexpected HTTP ${ARCHIVE_HTTP} while downloading release asset."
    else
        SHA_HTTP="$(curl -sS -L --retry 2 -w '%{http_code}' "${BASE_URL}/${ASSET_NAME}.sha256" -o "$SHA")" ||
            die "Failed to download checksum for the precompiled release."

        [[ "$SHA_HTTP" == "200" ]] ||
            die "Release asset exists, but checksum download returned HTTP ${SHA_HTTP}."

        EXPECTED="$(awk '{print $1}' "$SHA" | head -n1)"
        ACTUAL="$(sha256_file "$ARCHIVE")"

        [[ "$EXPECTED" =~ ^[0-9a-fA-F]{64}$ ]] ||
            die "Invalid release checksum."

        [[ "${EXPECTED,,}" == "${ACTUAL,,}" ]] ||
            die "Release checksum verification failed."

        while IFS= read -r archive_entry; do
            [[ "$archive_entry" != /* ]] ||
                die "Release archive contains an absolute path: ${archive_entry}"

            [[ "$archive_entry" != ".." && "$archive_entry" != ../* && "$archive_entry" != */../* && "$archive_entry" != */.. ]] ||
                die "Release archive contains a path traversal entry: ${archive_entry}"
        done < <(tar -tzf "$ARCHIVE")

        mkdir -p "$RELEASE_DIR"
        tar -xzf "$ARCHIVE" -C "$RELEASE_DIR"

        BIN="${RELEASE_DIR}/src/gamescope"
        RUNTIME_DIR="${RELEASE_DIR}/runtime"

        [[ -f "$BIN" ]] ||
            die "Release archive does not contain src/gamescope."

        chmod 0755 "$BIN"

        [[ -d "$RUNTIME_DIR" ]] ||
            die "Release archive does not contain its runtime libraries."

        compgen -G "${RUNTIME_DIR}/*" >/dev/null ||
            die "Release archive runtime directory is empty."

        ok "Compatible precompiled release found."

        "${SCRIPT_DIR}/install.sh" --binary "$BIN"
        exit 0
    fi
fi

log "Building from source..."

"${SCRIPT_DIR}/build.sh"

"${SCRIPT_DIR}/install.sh" \
    --binary "${PROJECT_ROOT}/${GS_BUILD_DIR_NAME}/src/gamescope"
