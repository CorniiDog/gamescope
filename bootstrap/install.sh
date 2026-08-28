#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SOURCE_BIN="${PROJECT_ROOT}/${GS_BUILD_DIR_NAME}/src/gamescope"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary)
            [[ $# -ge 2 ]] || die "--binary requires a path."
            SOURCE_BIN="$2"
            shift 2
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

CURRENT_DIR="${GS_PREFIX}/current"
CURRENT_BIN="${CURRENT_DIR}/gamescope"
MAINTENANCE_DIR="${GS_PREFIX}/bin"

require_steamos
require_nvidia
ensure_sudo

verify_system_gamescope

[[ -x "$SOURCE_BIN" ]] ||
    die "Built Gamescope binary not found: $SOURCE_BIN"

log "Gamescope NVIDIA installer"
log "Source: ${SOURCE_BIN}"
log "Target: ${GS_SYSTEM_BIN}"

disable_readonly_if_needed

cleanup()
{
    restore_readonly_if_needed
}

trap cleanup EXIT

sudo mkdir -p \
    "$GS_STOCK_DIR" \
    "$GS_STATE_DIR" \
    "$CURRENT_DIR" \
    "$MAINTENANCE_DIR/lib"

#
# Backup the original Valve binary exactly once.
#
if [[ ! -f "$GS_STOCK_BIN" ]]; then

    log "Backing up Valve Gamescope..."

    STOCK_SHA="$(sha256_file "$GS_SYSTEM_BIN")"
    STOCK_VERSION="$(get_gamescope_package_version)"

    sudo cp \
        --preserve=all \
        "$GS_SYSTEM_BIN" \
        "$GS_STOCK_BIN"

    printf '%s\n' "$STOCK_SHA" |
        sudo tee "${GS_STATE_DIR}/stock-sha256" >/dev/null

    printf '%s\n' "$STOCK_VERSION" |
        sudo tee "${GS_STATE_DIR}/stock-package-version" >/dev/null

    ok "Stock Gamescope backed up."

else

    log "Existing stock backup found."

fi

#
# Cache the patched binary outside SteamOS-managed paths.
#
log "Caching patched Gamescope..."

sudo install \
    -o root \
    -g root \
    -m 0755 \
    "$SOURCE_BIN" \
    "$CURRENT_BIN"

PATCHED_SHA="$(sha256_file "$CURRENT_BIN")"

printf '%s\n' "$PATCHED_SHA" |
    sudo tee "${GS_STATE_DIR}/patched-sha256" >/dev/null

printf '%s\n' "$PATCHED_SHA" |
    sudo tee "${GS_STATE_DIR}/expected-sha256" >/dev/null

printf '%s\n' "$(get_steamos_version)" |
    sudo tee "${GS_STATE_DIR}/steamos-version" >/dev/null

#
# Replace only the SteamOS Gamescope binary.
#
log "Installing patched Gamescope..."

sudo install \
    -o root \
    -g root \
    -m 0755 \
    "$CURRENT_BIN" \
    "$GS_SYSTEM_BIN"

#
# Verify copy.
#
INSTALLED_SHA="$(sha256_file "$GS_SYSTEM_BIN")"

if [[ "$INSTALLED_SHA" != "$PATCHED_SHA" ]]; then
    die "Installed binary checksum does not match source binary."
fi

#
# Metadata
#
cat <<EOF | sudo tee "${GS_STATE_DIR}/install-info" >/dev/null
version=1
repository=${GS_REPO}
branch=${GS_BRANCH}
system_binary=${GS_SYSTEM_BIN}
stock_binary=${GS_STOCK_BIN}
installed_sha256=${INSTALLED_SHA}
installed_at=$(date --iso-8601=seconds)
EOF

log "Installing maintenance tools..."

sudo install -o root -g root -m 0755 "${SCRIPT_DIR}/update.sh" "${MAINTENANCE_DIR}/update"
sudo install -o root -g root -m 0755 "${SCRIPT_DIR}/uninstall.sh" "${MAINTENANCE_DIR}/uninstall"
sudo install -o root -g root -m 0755 "${SCRIPT_DIR}/integrity-check.sh" "${MAINTENANCE_DIR}/integrity-check"
sudo install -o root -g root -m 0644 "${SCRIPT_DIR}/lib/common.sh" "${MAINTENANCE_DIR}/lib/common.sh"

log "Installing integrity monitor..."

sudo tee /etc/systemd/system/gamescope-nvidia-integrity.service >/dev/null <<'EOF'
[Unit]
Description=gamescope-nvidia binary integrity check
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/opt/gamescope-nvidia/bin/integrity-check
EOF

sudo tee /etc/systemd/system/gamescope-nvidia-integrity.path >/dev/null <<'EOF'
[Unit]
Description=Watch Gamescope binary for replacement

[Path]
PathChanged=/usr/bin/gamescope
Unit=gamescope-nvidia-integrity.service

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/gamescope-nvidia-integrity.timer >/dev/null <<'EOF'
[Unit]
Description=Periodic gamescope-nvidia integrity check

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
Persistent=true
Unit=gamescope-nvidia-integrity.service

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now gamescope-nvidia-integrity.path
sudo systemctl enable --now gamescope-nvidia-integrity.timer

ok "Patched Gamescope installed successfully."

printf '\nSteamOS continues launching:\n\n'
printf '    exec gamescope \\\\\n\n'

printf 'System binary:\n\n'
printf '    %s\n\n' "$GS_SYSTEM_BIN"

log "Version:"
"$GS_SYSTEM_BIN" --version || true
