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

STEAMOS_VERSION="$(get_steamos_version)"
RELEASE_TAG="$(release_tag_for_steamos)"
ASSET_NAME="$(release_asset_for_steamos)"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log "Detected SteamOS ${STEAMOS_VERSION}."

if [[ "$FORCE_SOURCE" == "0" ]]; then
    BASE_URL="https://github.com/${GS_REPO}/releases/download/${RELEASE_TAG}"
    BIN="${TMP_DIR}/${ASSET_NAME}"
    SHA="${BIN}.sha256"

    log "Checking for ${RELEASE_TAG}..."

    if curl -fsSL --retry 2 "${BASE_URL}/${ASSET_NAME}" -o "$BIN" &&
       curl -fsSL --retry 2 "${BASE_URL}/${ASSET_NAME}.sha256" -o "$SHA"; then

        EXPECTED="$(awk '{print $1}' "$SHA" | head -n1)"
        ACTUAL="$(sha256_file "$BIN")"

        [[ "$EXPECTED" =~ ^[0-9a-fA-F]{64}$ ]] ||
            die "Invalid release checksum."

        [[ "${EXPECTED,,}" == "${ACTUAL,,}" ]] ||
            die "Release checksum verification failed."

        chmod 0755 "$BIN"

        ok "Compatible precompiled release found."

        exec "${SCRIPT_DIR}/install.sh" --binary "$BIN"
    fi

    warn "No compatible precompiled release found."
fi

log "Building from source..."

"${SCRIPT_DIR}/build.sh"

exec "${SCRIPT_DIR}/install.sh" \
    --binary "${PROJECT_ROOT}/${GS_BUILD_DIR_NAME}/src/gamescope"
