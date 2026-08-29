#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_steamos
ensure_sudo
acquire_lifecycle_lock


CURRENT_STEAMOS="$(get_steamos_version)"
INSTALLED_STEAMOS=""

if [[ -f "${GS_STATE_DIR}/steamos-version" ]]; then
    INSTALLED_STEAMOS="$(cat "${GS_STATE_DIR}/steamos-version")"
fi

[[ -n "$INSTALLED_STEAMOS" ]] ||
    die "Installed SteamOS version provenance is missing. Refusing to overwrite or remove installation state automatically."


# Validate what uninstall is going to preserve or restore before changing services/state.
if [[ "$CURRENT_STEAMOS" != "$INSTALLED_STEAMOS" ]]; then
    [[ -f "${GS_STATE_DIR}/patched-sha256" ]] ||
        die "SteamOS changed, but patched Gamescope provenance is missing. Refusing to uninstall automatically."

    PREVIOUS_PATCHED_SHA="$(cat "${GS_STATE_DIR}/patched-sha256")"
    is_sha256 "$PREVIOUS_PATCHED_SHA" ||
        die "Recorded patched Gamescope checksum is invalid."

    [[ -x "$GS_SYSTEM_BIN" ]] ||
        die "Current SteamOS Gamescope binary is missing or not executable."

    CURRENT_SYSTEM_SHA="$(sha256_file "$GS_SYSTEM_BIN")"

    if [[ "${CURRENT_SYSTEM_SHA,,}" == "${PREVIOUS_PATCHED_SHA,,}" ]]; then
        die "SteamOS changed, but /usr/bin/gamescope still matches the previous patched binary. Refusing to remove recovery state."
    fi
else
    [[ -f "$GS_STOCK_BIN" ]] ||
        die "Stock Gamescope backup not found: $GS_STOCK_BIN"

    [[ -f "${GS_STATE_DIR}/stock-sha256" ]] ||
        die "Recorded Valve Gamescope checksum is missing."

    EXPECTED_STOCK_SHA="$(cat "${GS_STATE_DIR}/stock-sha256")"
    is_sha256 "$EXPECTED_STOCK_SHA" ||
        die "Recorded Valve Gamescope checksum is invalid."

    STOCK_SHA="$(sha256_file "$GS_STOCK_BIN")"

    [[ "${STOCK_SHA,,}" == "${EXPECTED_STOCK_SHA,,}" ]] ||
        die "Valve Gamescope backup checksum does not match recorded stock checksum. Refusing to uninstall."
fi

log "Disabling gamescope-nvidia integrity monitoring..."

sudo systemctl disable --now gamescope-nvidia-integrity.path 2>/dev/null || true
sudo systemctl disable --now gamescope-nvidia-integrity.timer 2>/dev/null || true
sudo systemctl stop gamescope-nvidia-integrity.service 2>/dev/null || true

sudo rm -f \
    /etc/systemd/system/gamescope-nvidia-integrity.service \
    /etc/systemd/system/gamescope-nvidia-integrity.path \
    /etc/systemd/system/gamescope-nvidia-integrity.timer

sudo systemctl daemon-reload


if [[ -n "$INSTALLED_STEAMOS" && "$CURRENT_STEAMOS" != "$INSTALLED_STEAMOS" ]]; then
    log "SteamOS changed from ${INSTALLED_STEAMOS} to ${CURRENT_STEAMOS}."
    log "Preserving the current SteamOS Gamescope binary."
else
    log "Restoring Valve Gamescope..."

    disable_readonly_if_needed

    RESTORE_TMP=""

    cleanup()
    {
        if [[ -n "${RESTORE_TMP:-}" ]]; then
            sudo rm -f "$RESTORE_TMP" 2>/dev/null || true
        fi

        restore_readonly_if_needed
    }

    trap cleanup EXIT

    RESTORE_TMP="${GS_SYSTEM_BIN}.gamescope-nvidia-restore.$$"

    sudo cp \
        --preserve=all \
        "$GS_STOCK_BIN" \
        "$RESTORE_TMP"

    sudo mv -f \
        "$RESTORE_TMP" \
        "$GS_SYSTEM_BIN"
    RESTORE_TMP=""

    RESTORED_SHA="$(sha256_file "$GS_SYSTEM_BIN")"

    if [[ "$RESTORED_SHA" != "$STOCK_SHA" ]]; then
        die "Restored binary checksum verification failed."
    fi

    ok "Valve Gamescope restored."
fi

log "Removing bootstrap state..."

sudo rm -rf "$GS_PREFIX"

ok "gamescope-nvidia removed successfully."
