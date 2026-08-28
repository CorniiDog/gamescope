#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CURRENT_DIR="${GS_PREFIX}/current"
CURRENT_BIN="${CURRENT_DIR}/gamescope"

EXPECTED_SHA_FILE="${GS_STATE_DIR}/expected-sha256"
STEAMOS_VERSION_FILE="${GS_STATE_DIR}/steamos-version"

STEAMOS_VERSION="$(get_steamos_version)"
RELEASE_TAG="$(release_tag_for_steamos)"
ASSET_NAME="$(release_asset_for_steamos)"

BASE_URL="https://github.com/${GS_REPO}/releases/download/${RELEASE_TAG}"

BIN_URL="${BASE_URL}/${ASSET_NAME}"
SHA_URL="${BASE_URL}/${ASSET_NAME}.sha256"

TMP_DIR="$(mktemp -d)"

cleanup()
{
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

need_cmd curl
need_cmd sha256sum

require_steamos
require_nvidia
ensure_sudo

log "SteamOS version: ${STEAMOS_VERSION}"
log "Release tag: ${RELEASE_TAG}"
log "Asset: ${ASSET_NAME}"

TMP_BIN="${TMP_DIR}/${ASSET_NAME}"
TMP_SHA="${TMP_DIR}/${ASSET_NAME}.sha256"

log "Downloading matching gamescope-nvidia release..."

if ! curl \
    -fL \
    --retry 3 \
    --retry-delay 2 \
    "$BIN_URL" \
    -o "$TMP_BIN"
then
    die "No gamescope-nvidia release was found for SteamOS ${STEAMOS_VERSION}."
fi

log "Downloading checksum..."

curl \
    -fL \
    --retry 3 \
    --retry-delay 2 \
    "$SHA_URL" \
    -o "$TMP_SHA" ||
    die "Release exists but checksum file could not be downloaded."

#
# Accept either:
#
# abc123...  gamescope-steamos-X-x86_64
#
# or just:
#
# abc123...
#
EXPECTED_SHA="$(
    awk '{print $1}' "$TMP_SHA" |
        head -n1
)"

[[ "$EXPECTED_SHA" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "Invalid SHA256 file returned by release."

DOWNLOADED_SHA="$(sha256_file "$TMP_BIN")"

if [[ "${DOWNLOADED_SHA,,}" != "${EXPECTED_SHA,,}" ]]; then
    die "Downloaded binary failed SHA256 verification."
fi

ok "Release checksum verified."

chmod 0755 "$TMP_BIN"

#
# If SteamOS itself changed, /usr/bin/gamescope now belongs to the new
# SteamOS release. Preserve that new Valve binary before replacing it.
#
if [[ -f "$STEAMOS_VERSION_FILE" ]]; then
    PREVIOUS_STEAMOS="$(cat "$STEAMOS_VERSION_FILE")"

    if [[ "$PREVIOUS_STEAMOS" != "$STEAMOS_VERSION" ]]; then
        log "SteamOS changed from ${PREVIOUS_STEAMOS} to ${STEAMOS_VERSION}."
        log "Refreshing Valve Gamescope backup."

        sudo mkdir -p "$GS_STOCK_DIR"

        sudo cp --preserve=all             "$GS_SYSTEM_BIN"             "$GS_STOCK_BIN"

        printf '%s\n' "$(sha256_file "$GS_STOCK_BIN")" |
            sudo tee "${GS_STATE_DIR}/stock-sha256" >/dev/null

        printf '%s\n' "$(get_gamescope_package_version)" |
            sudo tee "${GS_STATE_DIR}/stock-package-version" >/dev/null
    fi
fi

disable_readonly_if_needed

restore_ro()
{
    restore_readonly_if_needed
}

trap 'cleanup; restore_ro' EXIT

sudo mkdir -p \
    "$CURRENT_DIR" \
    "$GS_STATE_DIR" \
    "${GS_PREFIX}/bin"

#
# Install the persistent cached binary FIRST.
#
sudo install \
    -o root \
    -g root \
    -m 0755 \
    "$TMP_BIN" \
    "$CURRENT_BIN"

#
# Record expected checksum and compatible SteamOS version.
#
printf '%s\n' "$EXPECTED_SHA" |
    sudo tee "$EXPECTED_SHA_FILE" >/dev/null

printf '%s\n' "$STEAMOS_VERSION" |
    sudo tee "$STEAMOS_VERSION_FILE" >/dev/null

#
# Then replace /usr/bin/gamescope.
#
log "Updating ${GS_SYSTEM_BIN}..."

sudo install \
    -o root \
    -g root \
    -m 0755 \
    "$CURRENT_BIN" \
    "$GS_SYSTEM_BIN"

INSTALLED_SHA="$(sha256_file "$GS_SYSTEM_BIN")"

if [[ "${INSTALLED_SHA,,}" != "${EXPECTED_SHA,,}" ]]; then
    die "Installed Gamescope binary failed checksum verification."
fi

ok "gamescope-nvidia updated successfully."

printf '\nSteamOS:        %s\n' "$STEAMOS_VERSION"
printf 'Release:        %s\n' "$RELEASE_TAG"
printf 'SHA256:         %s\n' "$EXPECTED_SHA"
printf 'System binary:  %s\n' "$GS_SYSTEM_BIN"
printf 'Cached binary:  %s\n\n' "$CURRENT_BIN"
