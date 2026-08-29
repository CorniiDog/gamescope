#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_steamos
ensure_sudo

[[ -f "$GS_STOCK_BIN" ]] ||
    die "Stock Gamescope backup not found: $GS_STOCK_BIN"

log "Disabling gamescope-nvidia integrity monitoring..."

sudo systemctl disable --now gamescope-nvidia-integrity.path 2>/dev/null || true
sudo systemctl disable --now gamescope-nvidia-integrity.timer 2>/dev/null || true
sudo systemctl stop gamescope-nvidia-integrity.service 2>/dev/null || true

sudo rm -f     /etc/systemd/system/gamescope-nvidia-integrity.service     /etc/systemd/system/gamescope-nvidia-integrity.path     /etc/systemd/system/gamescope-nvidia-integrity.timer

sudo systemctl daemon-reload

log "Restoring Valve Gamescope..."

disable_readonly_if_needed

cleanup()
{
    restore_readonly_if_needed
}

trap cleanup EXIT

STOCK_SHA="$(sha256_file "$GS_STOCK_BIN")"

RESTORE_TMP="${GS_SYSTEM_BIN}.gamescope-nvidia-restore.$$"

sudo cp \
    --preserve=all \
    "$GS_STOCK_BIN" \
    "$RESTORE_TMP"

sudo mv -f \
    "$RESTORE_TMP" \
    "$GS_SYSTEM_BIN"

RESTORED_SHA="$(sha256_file "$GS_SYSTEM_BIN")"

if [[ "$RESTORED_SHA" != "$STOCK_SHA" ]]; then
    die "Restored binary checksum verification failed."
fi

ok "Valve Gamescope restored."

log "Removing bootstrap state..."

sudo rm -rf "$GS_PREFIX"

ok "gamescope-nvidia removed successfully."
