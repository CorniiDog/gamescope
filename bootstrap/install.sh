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
LIB_DIR="${GS_PREFIX}/lib"
SOURCE_RUNTIME_DIR=""
if [[ "$(basename "$(dirname "$SOURCE_BIN")")" == "src" ]]; then
    SOURCE_RUNTIME_DIR="$(dirname "$(dirname "$SOURCE_BIN")")/runtime"
fi

require_steamos
require_nvidia
ensure_sudo
need_cmd ldd

verify_system_gamescope

[[ -x "$SOURCE_BIN" ]] ||
    die "Built Gamescope binary not found: $SOURCE_BIN"

if [[ -d "$SOURCE_RUNTIME_DIR" ]]; then
    MISSING_LIBS="$(LD_LIBRARY_PATH="$SOURCE_RUNTIME_DIR" ldd "$SOURCE_BIN" 2>&1 | grep "not found" || true)"
else
    MISSING_LIBS="$(ldd "$SOURCE_BIN" 2>&1 | grep "not found" || true)"
fi

if [[ -n "$MISSING_LIBS" ]]; then
    printf "%s\n" "$MISSING_LIBS" >&2
    die "Candidate Gamescope binary has missing runtime libraries. Refusing to install."
fi

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
    "$LIB_DIR" \
    "$MAINTENANCE_DIR/lib"

#
# Validate any existing stock backup before trusting it.
#
if [[ -f "$GS_STOCK_BIN" ]]; then
    STOCK_MISSING_LIBS="$(ldd "$GS_STOCK_BIN" 2>&1 | grep "not found" || true)"

    if [[ -n "$STOCK_MISSING_LIBS" ]]; then
        printf "%s\n" "$STOCK_MISSING_LIBS" >&2
        die "Existing stock Gamescope backup is not runnable. Refusing to continue."
    fi
fi

#
# Never mistake our previously patched binary for Valve stock.
#
if [[ ! -f "$GS_STOCK_BIN" && -f "${GS_STATE_DIR}/patched-sha256" ]]; then
    CURRENT_SYSTEM_SHA="$(sha256_file "$GS_SYSTEM_BIN")"
    PREVIOUS_PATCHED_SHA="$(cat "${GS_STATE_DIR}/patched-sha256")"

    if [[ "$CURRENT_SYSTEM_SHA" == "$PREVIOUS_PATCHED_SHA" ]]; then
        die "Current system Gamescope matches the previous patched binary. Refusing to save it as Valve stock."
    fi
fi

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
if [[ -d "$SOURCE_RUNTIME_DIR" ]]; then
    log "Installing bundled runtime libraries..."

    for runtime_lib in "$SOURCE_RUNTIME_DIR"/*; do
        [[ -f "$runtime_lib" ]] || continue

        sudo install \
            -o root \
            -g root \
            -m 0755 \
            "$runtime_lib" \
            "$LIB_DIR/$(basename "$runtime_lib")"
    done
fi

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

INSTALL_TMP="${GS_SYSTEM_BIN}.gamescope-nvidia-install.$$"

sudo install \
    -o root \
    -g root \
    -m 0755 \
    "$CURRENT_BIN" \
    "$INSTALL_TMP"

sudo mv -f \
    "$INSTALL_TMP" \
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
