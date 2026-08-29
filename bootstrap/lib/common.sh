#!/usr/bin/env bash

set -euo pipefail

PROJECT_NAME="gamescope-nvidia"

GS_REPO="${GS_REPO:-CorniiDog/gamescope-nvidia}"
GS_BRANCH="${GS_BRANCH:-master}"

GS_PREFIX="${GS_PREFIX:-/opt/gamescope-nvidia}"
GS_STOCK_DIR="${GS_PREFIX}/stock"
GS_STATE_DIR="${GS_PREFIX}/state"

GS_SYSTEM_BIN="${GS_SYSTEM_BIN:-/usr/bin/gamescope}"
GS_STOCK_BIN="${GS_STOCK_DIR}/gamescope"

GS_BUILD_DIR_NAME="${GS_BUILD_DIR_NAME:-build-bootstrap}"
GS_CONTAINER_IMAGE="${GS_CONTAINER_IMAGE:-registry.fedoraproject.org/fedora@sha256:63773f454664cd77e239f8e0b13ae7f18effe9e3d6612a325b5646eb3bda11f1}"

PROJECT_ROOT="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.."
    pwd
)"

log()
{
    printf '\033[1;34m[gamescope-nvidia]\033[0m %s\n' "$*"
}

ok()
{
    printf '\033[1;32m[gamescope-nvidia]\033[0m %s\n' "$*"
}

warn()
{
    printf '\033[1;33m[gamescope-nvidia]\033[0m %s\n' "$*" >&2
}

die()
{
    printf '\033[1;31m[gamescope-nvidia]\033[0m %s\n' "$*" >&2
    exit 1
}

need_cmd()
{
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}

is_steamos()
{
    [[ -r /etc/os-release ]] || return 1

    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID:-}" == "steamos" ]] ||
        [[ "${NAME:-}" == *"SteamOS"* ]]
}

require_steamos()
{
    is_steamos ||
        die "This operation is intended for SteamOS."
}

has_nvidia()
{
    [[ -d /sys/module/nvidia_drm ]] ||
        command -v nvidia-smi >/dev/null 2>&1 ||
        lspci 2>/dev/null | grep -qi NVIDIA
}

require_nvidia()
{
    has_nvidia ||
        die "No NVIDIA GPU or NVIDIA DRM driver was detected."
}

ensure_sudo()
{
    need_cmd sudo

    log "Requesting administrator privileges..."
    sudo -v
}

readonly_status()
{
    if ! command -v steamos-readonly >/dev/null 2>&1; then
        printf 'unknown\n'
        return
    fi

    if steamos-readonly status 2>/dev/null | grep -qi enabled; then
        printf 'enabled\n'
    else
        printf 'disabled\n'
    fi
}

disable_readonly_if_needed()
{
    GS_READONLY_WAS_ENABLED=0

    if [[ "$(readonly_status)" == "enabled" ]]; then
        log "Disabling SteamOS read-only mode temporarily..."
        sudo steamos-readonly disable
        GS_READONLY_WAS_ENABLED=1
    fi
}

restore_readonly_if_needed()
{
    if [[ "${GS_READONLY_WAS_ENABLED:-0}" == "1" ]]; then
        log "Re-enabling SteamOS read-only mode..."

        sudo steamos-readonly enable ||
            warn "Failed to re-enable SteamOS read-only mode."
    fi
}

sha256_file()
{
    local file="$1"

    sha256sum "$file" | awk '{print $1}'
}

is_sha256()
{
    [[ "${1:-}" =~ ^[0-9a-fA-F]{64}$ ]]
}

get_gamescope_package_version()
{
    if command -v pacman >/dev/null 2>&1; then
        pacman -Q gamescope 2>/dev/null | awk '{print $2}' || true
    fi
}

verify_system_gamescope()
{
    [[ -e "$GS_SYSTEM_BIN" ]] ||
        die "System Gamescope binary not found: $GS_SYSTEM_BIN"

    [[ -x "$GS_SYSTEM_BIN" ]] ||
        die "System Gamescope is not executable: $GS_SYSTEM_BIN"
}

get_steamos_version()
{
    [[ -r /etc/os-release ]] ||
        die "Cannot read /etc/os-release."

    (
        # shellcheck disable=SC1091
        source /etc/os-release

        if [[ -n "${VERSION_ID:-}" ]]; then
            printf '%s\n' "$VERSION_ID"
            exit 0
        fi

        exit 1
    ) || die "Could not determine SteamOS VERSION_ID."
}

release_tag_for_steamos()
{
    printf 'steamos-%s\n' "$(get_steamos_version)"
}

release_asset_for_steamos()
{
    printf 'gamescope-steamos-%s-x86_64.tar.gz\n' "$(get_steamos_version)"
}

as_root()
{
    if [[ "$EUID" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

acquire_lifecycle_lock()
{
    need_cmd flock

    local lock_file="/run/lock/gamescope-nvidia.lock"

    as_root touch "$lock_file"
    as_root chmod 0666 "$lock_file"

    exec 9>"$lock_file"

    flock -n 9 ||
        die "Another gamescope-nvidia install, uninstall, or integrity operation is already running."
}
