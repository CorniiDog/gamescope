#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SOURCE_BIN="${PROJECT_ROOT}/${GS_BUILD_DIR_NAME}/src/gamescope"
MAINTENANCE_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary)
            [[ $# -ge 2 ]] || die "--binary requires a path."
            SOURCE_BIN="$2"
            shift 2
            ;;
        --maintenance-only)
            MAINTENANCE_ONLY=1
            shift
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

install_maintenance()
{
    log "Installing maintenance tools..."

    sudo mkdir -p "$MAINTENANCE_DIR/lib"

    sudo rm -f "${MAINTENANCE_DIR}/update"

    MAINT_TMP_SUFFIX=".gamescope-nvidia-install.$$"

    sudo rm -f \
        "${MAINTENANCE_DIR}"/uninstall.gamescope-nvidia-install.* \
        "${MAINTENANCE_DIR}"/integrity-check.gamescope-nvidia-install.* \
        "${MAINTENANCE_DIR}"/lib/common.sh.gamescope-nvidia-install.*

    sudo install -o root -g root -m 0755 "${SCRIPT_DIR}/uninstall.sh" "${MAINTENANCE_DIR}/uninstall${MAINT_TMP_SUFFIX}"
    sudo install -o root -g root -m 0755 "${SCRIPT_DIR}/integrity-check.sh" "${MAINTENANCE_DIR}/integrity-check${MAINT_TMP_SUFFIX}"
    sudo install -o root -g root -m 0644 "${SCRIPT_DIR}/lib/common.sh" "${MAINTENANCE_DIR}/lib/common.sh${MAINT_TMP_SUFFIX}"

    sudo mv -f "${MAINTENANCE_DIR}/uninstall${MAINT_TMP_SUFFIX}" "${MAINTENANCE_DIR}/uninstall"
    sudo mv -f "${MAINTENANCE_DIR}/integrity-check${MAINT_TMP_SUFFIX}" "${MAINTENANCE_DIR}/integrity-check"
    sudo mv -f "${MAINTENANCE_DIR}/lib/common.sh${MAINT_TMP_SUFFIX}" "${MAINTENANCE_DIR}/lib/common.sh"

    sudo rm -f \
        "${MAINTENANCE_DIR}/uninstall${MAINT_TMP_SUFFIX}" \
        "${MAINTENANCE_DIR}/integrity-check${MAINT_TMP_SUFFIX}" \
        "${MAINTENANCE_DIR}/lib/common.sh${MAINT_TMP_SUFFIX}"

    log "Installing integrity monitor..."

    UNIT_TMP_SUFFIX=".gamescope-nvidia-install.$$"

    sudo rm -f \
        /etc/systemd/system/gamescope-nvidia-integrity.service.gamescope-nvidia-install.* \
        /etc/systemd/system/gamescope-nvidia-integrity.path.gamescope-nvidia-install.* \
        /etc/systemd/system/gamescope-nvidia-integrity.timer.gamescope-nvidia-install.*

    sudo tee "/etc/systemd/system/gamescope-nvidia-integrity.service${UNIT_TMP_SUFFIX}" >/dev/null <<EOF
[Unit]
Description=gamescope-nvidia binary integrity check
After=local-fs.target

[Service]
Type=oneshot
Environment=GS_PREFIX=${GS_PREFIX}
Environment=GS_SYSTEM_BIN=${GS_SYSTEM_BIN}
ExecStart=${MAINTENANCE_DIR}/integrity-check
EOF

    sudo tee "/etc/systemd/system/gamescope-nvidia-integrity.path${UNIT_TMP_SUFFIX}" >/dev/null <<EOF
[Unit]
Description=Watch Gamescope binary for replacement

[Path]
PathChanged=${GS_SYSTEM_BIN}
Unit=gamescope-nvidia-integrity.service

[Install]
WantedBy=multi-user.target
EOF

    sudo tee "/etc/systemd/system/gamescope-nvidia-integrity.timer${UNIT_TMP_SUFFIX}" >/dev/null <<'EOF'
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

    sudo mv -f "/etc/systemd/system/gamescope-nvidia-integrity.service${UNIT_TMP_SUFFIX}" /etc/systemd/system/gamescope-nvidia-integrity.service
    sudo mv -f "/etc/systemd/system/gamescope-nvidia-integrity.path${UNIT_TMP_SUFFIX}" /etc/systemd/system/gamescope-nvidia-integrity.path
    sudo mv -f "/etc/systemd/system/gamescope-nvidia-integrity.timer${UNIT_TMP_SUFFIX}" /etc/systemd/system/gamescope-nvidia-integrity.timer

    sudo rm -f \
        "/etc/systemd/system/gamescope-nvidia-integrity.service${UNIT_TMP_SUFFIX}" \
        "/etc/systemd/system/gamescope-nvidia-integrity.path${UNIT_TMP_SUFFIX}" \
        "/etc/systemd/system/gamescope-nvidia-integrity.timer${UNIT_TMP_SUFFIX}"

    UNIT_TMP_SUFFIX=""

    sudo systemctl daemon-reload
    sudo systemctl enable --now gamescope-nvidia-integrity.path
    sudo systemctl enable --now gamescope-nvidia-integrity.timer
}


require_steamos
require_nvidia
ensure_sudo
acquire_lifecycle_lock

if [[ "$MAINTENANCE_ONLY" == "1" ]]; then
    [[ -d "$GS_PREFIX" ]] ||
        die "gamescope-nvidia is not installed; maintenance-only update cannot continue."

    SOURCE_REVISION="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown\n')"
    BUILD_REVISION="$(git -C "$PROJECT_ROOT" ls-files -s -- . ':(exclude)bootstrap/**' 2>/dev/null | sha256sum | awk '{print $1}')"

    [[ -f "${GS_STATE_DIR}/build-revision" ]] ||
        die "Installed build revision is missing; maintenance-only update cannot continue."

    INSTALLED_BUILD_REVISION="$(cat "${GS_STATE_DIR}/build-revision")"

    [[ "$INSTALLED_BUILD_REVISION" =~ ^[0-9a-fA-F]{64}$ ]] ||
        die "Installed build revision is invalid; maintenance-only update cannot continue."

    [[ -f "${GS_STATE_DIR}/expected-sha256" ]] ||
        die "Installed Gamescope checksum is missing; maintenance-only update cannot continue."

    EXPECTED_SHA="$(cat "${GS_STATE_DIR}/expected-sha256")"
    is_sha256 "$EXPECTED_SHA" ||
        die "Installed Gamescope checksum is invalid; maintenance-only update cannot continue."

    [[ -x "$CURRENT_BIN" && -x "$GS_SYSTEM_BIN" ]] ||
        die "Installed Gamescope binaries are missing; maintenance-only update cannot continue."

    [[ "$(sha256_file "$CURRENT_BIN")" == "${EXPECTED_SHA,,}" ]] ||
        die "Cached patched Gamescope failed integrity verification; maintenance-only update cannot continue."

    [[ "$(sha256_file "$GS_SYSTEM_BIN")" == "${EXPECTED_SHA,,}" ]] ||
        die "System Gamescope differs from the installed patched binary; maintenance-only update cannot continue."

    [[ -f "${GS_STATE_DIR}/steamos-version" ]] ||
        die "Installed SteamOS provenance is missing; maintenance-only update cannot continue."

    [[ "$(cat "${GS_STATE_DIR}/steamos-version")" == "$(get_steamos_version)" ]] ||
        die "SteamOS changed; maintenance-only update cannot continue."

    [[ -f "${GS_STATE_DIR}/repository" && -f "${GS_STATE_DIR}/branch" ]] ||
        die "Repository provenance is missing; maintenance-only update cannot continue."

    [[ "$(cat "${GS_STATE_DIR}/repository")" == "$GS_REPO" && "$(cat "${GS_STATE_DIR}/branch")" == "$GS_BRANCH" ]] ||
        die "Repository or branch provenance changed; maintenance-only update cannot continue."

    [[ "$BUILD_REVISION" == "$INSTALLED_BUILD_REVISION" ]] ||
        die "Gamescope build inputs changed; maintenance-only update is not allowed."

    install_maintenance

    MAINT_STATE_SUFFIX=".gamescope-nvidia-maintenance.$$"

    cleanup_maintenance_state()
    {
        if [[ -n "${MAINT_STATE_SUFFIX:-}" ]]; then
            sudo rm -f "${GS_STATE_DIR}"/*"${MAINT_STATE_SUFFIX}" 2>/dev/null || true
        fi
    }

    trap cleanup_maintenance_state EXIT

    printf '%s\n' "$SOURCE_REVISION" |
        sudo tee "${GS_STATE_DIR}/source-revision${MAINT_STATE_SUFFIX}" >/dev/null

    printf '%s\n' "$BUILD_REVISION" |
        sudo tee "${GS_STATE_DIR}/build-revision${MAINT_STATE_SUFFIX}" >/dev/null

    printf '%s\n' "$GS_REPO" |
        sudo tee "${GS_STATE_DIR}/repository${MAINT_STATE_SUFFIX}" >/dev/null

    printf '%s\n' "$GS_BRANCH" |
        sudo tee "${GS_STATE_DIR}/branch${MAINT_STATE_SUFFIX}" >/dev/null

    sudo mv -f "${GS_STATE_DIR}/source-revision${MAINT_STATE_SUFFIX}" "${GS_STATE_DIR}/source-revision"
    sudo mv -f "${GS_STATE_DIR}/build-revision${MAINT_STATE_SUFFIX}" "${GS_STATE_DIR}/build-revision"
    sudo mv -f "${GS_STATE_DIR}/repository${MAINT_STATE_SUFFIX}" "${GS_STATE_DIR}/repository"
    sudo mv -f "${GS_STATE_DIR}/branch${MAINT_STATE_SUFFIX}" "${GS_STATE_DIR}/branch"

    MAINT_STATE_SUFFIX=""
    trap - EXIT

    ok "Maintenance components updated without rebuilding Gamescope."
    exit 0
fi
need_cmd ldd

verify_system_gamescope

[[ -x "$SOURCE_BIN" ]] ||
    die "Built Gamescope binary not found: $SOURCE_BIN"

[[ -d "$SOURCE_RUNTIME_DIR" ]] ||
    die "Candidate Gamescope runtime directory not found: ${SOURCE_RUNTIME_DIR}"

compgen -G "${SOURCE_RUNTIME_DIR}/*" >/dev/null ||
    die "Candidate Gamescope runtime directory is empty: ${SOURCE_RUNTIME_DIR}"

MISSING_LIBS="$(LD_LIBRARY_PATH="$SOURCE_RUNTIME_DIR" ldd "$SOURCE_BIN" 2>&1 | grep "not found" || true)"

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
    if [[ -n "${RUNTIME_SHA_TMP:-}" ]]; then
        rm -f "$RUNTIME_SHA_TMP" 2>/dev/null || true
    fi

    if [[ -n "${INSTALL_TMP:-}" ]]; then
        sudo rm -f "$INSTALL_TMP" 2>/dev/null || true
    fi

    if [[ -n "${STATE_SUFFIX:-}" ]]; then
        sudo rm -f "${GS_STATE_DIR}"/*"${STATE_SUFFIX}" 2>/dev/null || true
    fi

    if [[ "${RUNTIME_SWAPPED:-0}" == "1" && -n "${RUNTIME_OLD:-}" && -d "$RUNTIME_OLD" ]]; then
        sudo rm -rf "$LIB_DIR" 2>/dev/null || true
        sudo mv "$RUNTIME_OLD" "$LIB_DIR" 2>/dev/null || true
        RUNTIME_SWAPPED=0
    fi

    if [[ -n "${RUNTIME_STAGE:-}" ]]; then
        sudo rm -rf "$RUNTIME_STAGE" 2>/dev/null || true
    fi

    if [[ -n "${RUNTIME_OLD:-}" && -d "$RUNTIME_OLD" && "${RUNTIME_SWAPPED:-0}" != "1" ]]; then
        sudo rm -rf "$RUNTIME_OLD" 2>/dev/null || true
    fi

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
# Determine whether the Valve backup belongs to this SteamOS version.
#
CURRENT_STEAMOS="$(get_steamos_version)"
PREVIOUS_STEAMOS=""

if [[ -f "${GS_STATE_DIR}/steamos-version" ]]; then
    PREVIOUS_STEAMOS="$(cat "${GS_STATE_DIR}/steamos-version")"
fi

REFRESH_STOCK=0

if [[ -f "$GS_STOCK_BIN" && -z "$PREVIOUS_STEAMOS" ]]; then
    die "Valve Gamescope backup exists, but its SteamOS version provenance is missing. Refusing to continue."
fi

if [[ ! -f "$GS_STOCK_BIN" ]]; then
    REFRESH_STOCK=1
elif [[ -n "$PREVIOUS_STEAMOS" && "$CURRENT_STEAMOS" != "$PREVIOUS_STEAMOS" ]]; then
    log "SteamOS changed from ${PREVIOUS_STEAMOS} to ${CURRENT_STEAMOS}."

    if [[ -f "${GS_STATE_DIR}/patched-sha256" ]]; then
        CURRENT_SYSTEM_SHA="$(sha256_file "$GS_SYSTEM_BIN")"
        PREVIOUS_PATCHED_SHA="$(cat "${GS_STATE_DIR}/patched-sha256")"
        is_sha256 "$PREVIOUS_PATCHED_SHA" || die "Recorded patched Gamescope checksum is invalid."

        if [[ "$CURRENT_SYSTEM_SHA" == "$PREVIOUS_PATCHED_SHA" ]]; then
            die "SteamOS changed, but /usr/bin/gamescope still matches the previous patched binary. Refusing to overwrite the Valve backup."
        fi
    fi

    REFRESH_STOCK=1
fi

if [[ "$REFRESH_STOCK" -eq 1 ]]; then
    STOCK_MISSING_LIBS="$(ldd "$GS_SYSTEM_BIN" 2>&1 | grep "not found" || true)"

    if [[ -n "$STOCK_MISSING_LIBS" ]]; then
        printf "%s\n" "$STOCK_MISSING_LIBS" >&2
        die "Current SteamOS Gamescope is not runnable. Refusing to save it as Valve stock."
    fi

    if [[ -f "$GS_STOCK_BIN" ]]; then
        log "Refreshing Valve Gamescope backup for SteamOS ${CURRENT_STEAMOS}..."
    else
        log "Backing up Valve Gamescope..."
    fi

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

    ok "Valve Gamescope backup saved."
else
    [[ -f "${GS_STATE_DIR}/stock-sha256" ]] ||
        die "Recorded Valve Gamescope checksum is missing."

    EXPECTED_STOCK_SHA="$(cat "${GS_STATE_DIR}/stock-sha256")"
    is_sha256 "$EXPECTED_STOCK_SHA" || die "Recorded Valve Gamescope checksum is invalid."
    ACTUAL_STOCK_SHA="$(sha256_file "$GS_STOCK_BIN")"

    if [[ "${ACTUAL_STOCK_SHA,,}" != "${EXPECTED_STOCK_SHA,,}" ]]; then
        die "Existing Valve Gamescope backup checksum does not match recorded stock checksum."
    fi

    STOCK_MISSING_LIBS="$(ldd "$GS_STOCK_BIN" 2>&1 | grep "not found" || true)"

    if [[ -n "$STOCK_MISSING_LIBS" ]]; then
        printf "%s\n" "$STOCK_MISSING_LIBS" >&2
        die "Existing stock Gamescope backup is not runnable. Refusing to continue."
    fi

    log "Existing stock backup found for SteamOS ${CURRENT_STEAMOS}."
fi

#
# Cache the patched binary outside SteamOS-managed paths.
#
RUNTIME_STAGE="${GS_PREFIX}/lib.gamescope-nvidia-new.$$"
RUNTIME_OLD="${GS_PREFIX}/lib.gamescope-nvidia-old.$$"
RUNTIME_SWAPPED=0

sudo rm -rf "$RUNTIME_STAGE" "$RUNTIME_OLD"
sudo mkdir -p "$RUNTIME_STAGE"

if [[ -d "$SOURCE_RUNTIME_DIR" ]]; then
    log "Staging bundled runtime libraries..."

    for runtime_lib in "$SOURCE_RUNTIME_DIR"/*; do
        [[ -f "$runtime_lib" ]] || continue

        sudo install \
            -o root \
            -g root \
            -m 0755 \
            "$runtime_lib" \
            "$RUNTIME_STAGE/$(basename "$runtime_lib")"
    done
fi

RUNTIME_SHA_TMP="$(mktemp)"

for runtime_lib in "$RUNTIME_STAGE"/*; do
    [[ -f "$runtime_lib" ]] || continue
    printf '%s  %s\n' "$(sha256_file "$runtime_lib")" "$(basename "$runtime_lib")" >> "$RUNTIME_SHA_TMP"
done

log "Publishing bundled runtime libraries..."
sudo mv "$LIB_DIR" "$RUNTIME_OLD"
sudo mv "$RUNTIME_STAGE" "$LIB_DIR"
RUNTIME_STAGE=""
RUNTIME_SWAPPED=1


log "Caching patched Gamescope..."

sudo install \
    -o root \
    -g root \
    -m 0755 \
    "$SOURCE_BIN" \
    "$CURRENT_BIN"

PATCHED_SHA="$(sha256_file "$CURRENT_BIN")"
SOURCE_REVISION="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown\n')"
BUILD_REVISION="$(git -C "$PROJECT_ROOT" ls-files -s -- . ':(exclude)bootstrap/**' 2>/dev/null | sha256sum | awk '{print $1}')"
INSTALL_STEAMOS="$(get_steamos_version)"


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
INSTALL_TMP=""

#
# Verify copy.
#
INSTALLED_SHA="$(sha256_file "$GS_SYSTEM_BIN")"

if [[ "$INSTALLED_SHA" != "$PATCHED_SHA" ]]; then
    die "Installed binary checksum does not match source binary."
fi

# Binary and runtime are now a verified pair; discard runtime rollback copy.
sudo rm -rf "$RUNTIME_OLD"
RUNTIME_OLD=""
RUNTIME_SWAPPED=0

#
# Publish installation state only after /usr/bin/gamescope was successfully verified.
#
STATE_SUFFIX=".gamescope-nvidia-new.$$"

printf '%s\n' "$PATCHED_SHA" | sudo tee "${GS_STATE_DIR}/patched-sha256${STATE_SUFFIX}" >/dev/null
printf '%s\n' "$PATCHED_SHA" | sudo tee "${GS_STATE_DIR}/expected-sha256${STATE_SUFFIX}" >/dev/null
printf '%s\n' "$INSTALL_STEAMOS" | sudo tee "${GS_STATE_DIR}/steamos-version${STATE_SUFFIX}" >/dev/null
printf '%s\n' "$SOURCE_REVISION" | sudo tee "${GS_STATE_DIR}/source-revision${STATE_SUFFIX}" >/dev/null
printf '%s\n' "$GS_REPO" | sudo tee "${GS_STATE_DIR}/repository${STATE_SUFFIX}" >/dev/null
printf '%s\n' "$GS_BRANCH" | sudo tee "${GS_STATE_DIR}/branch${STATE_SUFFIX}" >/dev/null
printf '%s\n' "$BUILD_REVISION" | sudo tee "${GS_STATE_DIR}/build-revision${STATE_SUFFIX}" >/dev/null

sudo install -o root -g root -m 0644 "$RUNTIME_SHA_TMP" "${GS_STATE_DIR}/runtime-sha256${STATE_SUFFIX}"

sudo mv -f "${GS_STATE_DIR}/patched-sha256${STATE_SUFFIX}" "${GS_STATE_DIR}/patched-sha256"
sudo mv -f "${GS_STATE_DIR}/expected-sha256${STATE_SUFFIX}" "${GS_STATE_DIR}/expected-sha256"
sudo mv -f "${GS_STATE_DIR}/steamos-version${STATE_SUFFIX}" "${GS_STATE_DIR}/steamos-version"
sudo mv -f "${GS_STATE_DIR}/source-revision${STATE_SUFFIX}" "${GS_STATE_DIR}/source-revision"
sudo mv -f "${GS_STATE_DIR}/repository${STATE_SUFFIX}" "${GS_STATE_DIR}/repository"
sudo mv -f "${GS_STATE_DIR}/branch${STATE_SUFFIX}" "${GS_STATE_DIR}/branch"
sudo mv -f "${GS_STATE_DIR}/build-revision${STATE_SUFFIX}" "${GS_STATE_DIR}/build-revision"
sudo mv -f "${GS_STATE_DIR}/runtime-sha256${STATE_SUFFIX}" "${GS_STATE_DIR}/runtime-sha256"
STATE_SUFFIX=""

rm -f "$RUNTIME_SHA_TMP"
RUNTIME_SHA_TMP=""


#
# Metadata
#
cat <<EOF | sudo tee "${GS_STATE_DIR}/install-info" >/dev/null
version=1
repository=${GS_REPO}
branch=${GS_BRANCH}
container_image=${GS_CONTAINER_IMAGE}
system_binary=${GS_SYSTEM_BIN}
stock_binary=${GS_STOCK_BIN}
installed_sha256=${INSTALLED_SHA}
installed_at=$(date --iso-8601=seconds)
EOF

install_maintenance

ok "Patched Gamescope installed successfully."

printf '\nSteamOS continues launching:\n\n'
printf '    exec gamescope \\\\\n\n'

printf 'System binary:\n\n'
printf '    %s\n\n' "$GS_SYSTEM_BIN"

log "Version:"
"$GS_SYSTEM_BIN" --version || true
