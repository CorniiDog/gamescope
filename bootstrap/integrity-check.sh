#!/usr/bin/env bash

set -euo pipefail

GS_PREFIX="${GS_PREFIX:-/opt/gamescope-nvidia}"

GS_CURRENT_BIN="${GS_PREFIX}/current/gamescope"
GS_STATE_DIR="${GS_PREFIX}/state"
GS_LIB_DIR="${GS_PREFIX}/lib"
GS_RUNTIME_SHA="${GS_STATE_DIR}/runtime-sha256"

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

is_sha256()
{
    [[ "${1:-}" =~ ^[0-9a-fA-F]{64}$ ]]
}

get_steamos_version()
{
    # shellcheck disable=SC1091
    source /etc/os-release

    printf '%s\n' "${VERSION_ID:-unknown}"
}

[[ "$EUID" -eq 0 ]] ||
    fail "integrity-check must run as root."

command -v flock >/dev/null 2>&1 ||
    fail "Required command not found: flock"

touch /run/lock/gamescope-nvidia.lock
chmod 0666 /run/lock/gamescope-nvidia.lock
exec 9>/run/lock/gamescope-nvidia.lock

if ! flock -n 9; then
    log "Another gamescope-nvidia lifecycle operation is running; skipping this integrity check."
    exit 0
fi

[[ -x "$GS_CURRENT_BIN" ]] ||
    fail "Cached NVIDIA Gamescope binary is missing."

[[ -f "$GS_EXPECTED_SHA" ]] ||
    fail "Expected checksum is missing."

EXPECTED_SHA="$(cat "$GS_EXPECTED_SHA")"
is_sha256 "$EXPECTED_SHA" || fail "Recorded expected Gamescope checksum is invalid."

CACHE_SHA="$(sha256_file "$GS_CURRENT_BIN")"

#
# Never copy a corrupted cache into /usr/bin.
#
if [[ "${CACHE_SHA,,}" != "${EXPECTED_SHA,,}" ]]; then
    fail "Cached NVIDIA Gamescope failed integrity verification."
fi

#
# Verify bundled runtime libraries before trusting the cached build.
#
[[ -f "$GS_RUNTIME_SHA" ]] ||
    fail "Runtime library checksum manifest is missing."

while read -r EXPECTED_RUNTIME_SHA RUNTIME_NAME; do
    if [[ -z "$EXPECTED_RUNTIME_SHA" && -z "$RUNTIME_NAME" ]]; then
        continue
    fi

    [[ -n "$EXPECTED_RUNTIME_SHA" && -n "$RUNTIME_NAME" ]] ||
        fail "Runtime checksum manifest contains a malformed entry."

    RUNTIME_NAME="${RUNTIME_NAME# }"

    [[ "$EXPECTED_RUNTIME_SHA" =~ ^[0-9a-fA-F]{64}$ ]] ||
        fail "Runtime checksum manifest contains an invalid SHA256 value."

    [[ -n "$RUNTIME_NAME" ]] ||
        fail "Runtime checksum manifest contains an empty filename."

    [[ "$RUNTIME_NAME" != "." && "$RUNTIME_NAME" != ".." ]] ||
        fail "Runtime checksum manifest contains an invalid filename: ${RUNTIME_NAME}"

    [[ "$RUNTIME_NAME" != */* ]] ||
        fail "Runtime checksum manifest contains a path instead of a filename: ${RUNTIME_NAME}"

    RUNTIME_FILE="${GS_LIB_DIR}/${RUNTIME_NAME}"

    [[ -f "$RUNTIME_FILE" ]] ||
        fail "Bundled runtime library is missing: ${RUNTIME_NAME}"

    ACTUAL_RUNTIME_SHA="$(sha256_file "$RUNTIME_FILE")"

    if [[ "${ACTUAL_RUNTIME_SHA,,}" != "${EXPECTED_RUNTIME_SHA,,}" ]]; then
        fail "Bundled runtime library failed integrity verification: ${RUNTIME_NAME}"
    fi
done < "$GS_RUNTIME_SHA"


#
# Detect SteamOS upgrades.
#
CURRENT_STEAMOS="$(get_steamos_version)"

if [[ -f "$GS_STEAMOS_VERSION_FILE" ]]; then

    INSTALLED_STEAMOS="$(cat "$GS_STEAMOS_VERSION_FILE")"

    if [[ "$CURRENT_STEAMOS" != "$INSTALLED_STEAMOS" ]]; then
        log "SteamOS changed from ${INSTALLED_STEAMOS} to ${CURRENT_STEAMOS}."
        log "Installed gamescope-nvidia was built for a different SteamOS version."
        log "Leaving Valve Gamescope unchanged."
        log "Rerun the gamescope-nvidia installer to install a compatible build."
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
RESTORE_TMP=""

cleanup()
{
    if [[ -n "$RESTORE_TMP" ]]; then
        rm -f "$RESTORE_TMP" 2>/dev/null || true
    fi

    if [[ "$READONLY_WAS_ENABLED" == "1" ]]; then
        steamos-readonly enable || true
    fi
}

trap cleanup EXIT

if command -v steamos-readonly >/dev/null 2>&1; then

    if steamos-readonly status 2>/dev/null |
        grep -qi enabled
    then
        steamos-readonly disable
        READONLY_WAS_ENABLED=1
    fi

fi

RESTORE_TMP="${GS_SYSTEM_BIN}.gamescope-nvidia-restore.$$"

install \
    -o root \
    -g root \
    -m 0755 \
    "$GS_CURRENT_BIN" \
    "$RESTORE_TMP"

mv -f \
    "$RESTORE_TMP" \
    "$GS_SYSTEM_BIN"

RESTORE_TMP=""

RESTORED_SHA="$(sha256_file "$GS_SYSTEM_BIN")"

if [[ "${RESTORED_SHA,,}" != "${EXPECTED_SHA,,}" ]]; then
    fail "Gamescope restore checksum verification failed."
fi

if [[ "$READONLY_WAS_ENABLED" == "1" ]]; then
    steamos-readonly enable
    READONLY_WAS_ENABLED=0
fi

log "gamescope-nvidia restored successfully."
