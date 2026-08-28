#!/usr/bin/env bash

set -euo pipefail

GS_PREFIX="${GS_PREFIX:-/opt/gamescope-nvidia}"

GS_CURRENT_BIN="${GS_PREFIX}/current/gamescope"
GS_STATE_DIR="${GS_PREFIX}/state"

GS_EXPECTED_SHA="${GS_STATE_DIR}/expected-sha256"
GS_STEAMOS_VERSION_FILE="${GS_STATE_DIR}/steamos-version"

GS_SYSTEM_BIN="${GS_SYSTEM_BIN:-/usr/bin/gamescope}"

log()
{
    printf '[gamescope-nvidia] %s\n' "$*"
}

fail()
{
    printf '[gamescope-nvidia] ERROR: %s\n' "$*" >&2
    exit 1
}

sha256_file()
{
    sha256sum "$1" | awk '{print $1}'
}

get_steamos_version()
{
    # shellcheck disable=SC1091
    source /etc/os-release

    printf '%s\n' "${VERSION_ID:-unknown}"
}

[[ "$EUID" -eq 0 ]] ||
    fail "integrity-check must run as root."

[[ -x "$GS_CURRENT_BIN" ]] ||
    fail "Cached NVIDIA Gamescope binary is missing."

[[ -f "$GS_EXPECTED_SHA" ]] ||
    fail "Expected checksum is missing."

EXPECTED_SHA="$(cat "$GS_EXPECTED_SHA")"

CACHE_SHA="$(sha256_file "$GS_CURRENT_BIN")"

#
# Never copy a corrupted cache into /usr/bin.
#
if [[ "${CACHE_SHA,,}" != "${EXPECTED_SHA,,}" ]]; then
    fail "Cached NVIDIA Gamescope failed integrity verification."
fi

#
# Detect SteamOS upgrades.
#
CURRENT_STEAMOS="$(get_steamos_version)"

if [[ -f "$GS_STEAMOS_VERSION_FILE" ]]; then

    INSTALLED_STEAMOS="$(cat "$GS_STEAMOS_VERSION_FILE")"

    if [[ "$CURRENT_STEAMOS" != "$INSTALLED_STEAMOS" ]]; then
        log "SteamOS changed from ${INSTALLED_STEAMOS} to ${CURRENT_STEAMOS}."
        log "Checking for a matching gamescope-nvidia release."

        if [[ -x "${GS_PREFIX}/bin/update" ]]; then
            "${GS_PREFIX}/bin/update" ||                 log "No matching release is available yet; leaving Valve Gamescope unchanged."
        fi

        exit 0
    fi

fi

#
# Determine current /usr/bin checksum.
#
if [[ -x "$GS_SYSTEM_BIN" ]]; then
    SYSTEM_SHA="$(sha256_file "$GS_SYSTEM_BIN")"
else
    SYSTEM_SHA="missing"
fi

if [[ "${SYSTEM_SHA,,}" == "${EXPECTED_SHA,,}" ]]; then
    exit 0
fi

log "Gamescope checksum changed."
log "Expected: ${EXPECTED_SHA}"
log "Current:  ${SYSTEM_SHA}"
log "Restoring gamescope-nvidia."

READONLY_WAS_ENABLED=0

if command -v steamos-readonly >/dev/null 2>&1; then

    if steamos-readonly status 2>/dev/null |
        grep -qi enabled
    then
        steamos-readonly disable
        READONLY_WAS_ENABLED=1
    fi

fi

install \
    -o root \
    -g root \
    -m 0755 \
    "$GS_CURRENT_BIN" \
    "$GS_SYSTEM_BIN"

RESTORED_SHA="$(sha256_file "$GS_SYSTEM_BIN")"

if [[ "${RESTORED_SHA,,}" != "${EXPECTED_SHA,,}" ]]; then

    if [[ "$READONLY_WAS_ENABLED" == "1" ]]; then
        steamos-readonly enable || true
    fi

    fail "Gamescope restore checksum verification failed."
fi

if [[ "$READONLY_WAS_ENABLED" == "1" ]]; then
    steamos-readonly enable
fi

log "gamescope-nvidia restored successfully."
