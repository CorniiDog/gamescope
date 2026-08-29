#!/usr/bin/env bash

set -euo pipefail

REPO="${GS_REPO:-CorniiDog/gamescope-nvidia}"
BRANCH="${GS_BRANCH:-master}"

TMP_DIR="$(mktemp -d)"

cleanup()
{
    rm -rf "$TMP_DIR" 2>/dev/null || sudo rm -rf "$TMP_DIR"
}

trap cleanup EXIT

need()
{
    command -v "$1" >/dev/null 2>&1 || {
        echo "[gamescope-nvidia] Missing command: $1" >&2
        exit 1
    }
}

need git
need sha256sum
need sudo

GS_PREFIX="${GS_PREFIX:-/opt/gamescope-nvidia}"
GS_SYSTEM_BIN="${GS_SYSTEM_BIN:-/usr/bin/gamescope}"
GS_CURRENT_BIN="${GS_PREFIX}/current/gamescope"
GS_EXPECTED_SHA="${GS_PREFIX}/state/expected-sha256"
GS_STEAMOS_VERSION_FILE="${GS_PREFIX}/state/steamos-version"
GS_SOURCE_REVISION_FILE="${GS_PREFIX}/state/source-revision"
GS_BUILD_REVISION_FILE="${GS_PREFIX}/state/build-revision"
GS_REPOSITORY_FILE="${GS_PREFIX}/state/repository"
GS_BRANCH_FILE="${GS_PREFIX}/state/branch"

#
# A normal second invocation should be cheap and idempotent.
# Explicit arguments such as --build-from-source intentionally bypass this.
#
if [[ $# -eq 0 &&
      -x "$GS_CURRENT_BIN" &&
      -x "$GS_SYSTEM_BIN" &&
      -f "$GS_EXPECTED_SHA" &&
      -f "$GS_STEAMOS_VERSION_FILE" &&
      -f "$GS_SOURCE_REVISION_FILE" &&
      -f "$GS_BUILD_REVISION_FILE" &&
      -f "$GS_REPOSITORY_FILE" &&
      -f "$GS_BRANCH_FILE" ]]; then

    [[ -r /etc/os-release ]] || {
        echo "[gamescope-nvidia] /etc/os-release is unavailable; skipping installed-state fast path." >&2
        CURRENT_STEAMOS="unknown"
    }

    if [[ -r /etc/os-release ]]; then
        source /etc/os-release
        if [[ "${ID:-}" != "steamos" ]]; then
            echo "[gamescope-nvidia] This installer requires SteamOS." >&2
            exit 1
        fi
        CURRENT_STEAMOS="${VERSION_ID:-unknown}"
    fi
    INSTALLED_STEAMOS="$(cat "$GS_STEAMOS_VERSION_FILE")"
    INSTALLED_REVISION="$(cat "$GS_SOURCE_REVISION_FILE")"
    INSTALLED_REPO="$(cat "$GS_REPOSITORY_FILE")"
    INSTALLED_BRANCH="$(cat "$GS_BRANCH_FILE")"
    REMOTE_REVISION="$(git ls-remote "https://github.com/${REPO}.git" "refs/heads/${BRANCH}" 2>/dev/null | cut -f1 || true)"
    EXPECTED_SHA="$(cat "$GS_EXPECTED_SHA")"

    if [[ ! "$EXPECTED_SHA" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "[gamescope-nvidia] Installed checksum state is invalid; skipping fast path." >&2
        EXPECTED_SHA="invalid"
    fi
    CACHE_SHA="$(sha256sum "$GS_CURRENT_BIN" | awk '{print $1}')"
    SYSTEM_SHA="$(sha256sum "$GS_SYSTEM_BIN" | awk '{print $1}')"

    if [[ "$CURRENT_STEAMOS" == "$INSTALLED_STEAMOS" &&
          "$REPO" == "$INSTALLED_REPO" &&
          "$BRANCH" == "$INSTALLED_BRANCH" &&
          "${CACHE_SHA,,}" == "${EXPECTED_SHA,,}" ]]; then

        if [[ "${SYSTEM_SHA,,}" == "${EXPECTED_SHA,,}" ]]; then
            if [[ -z "$REMOTE_REVISION" ]]; then
                echo "[gamescope-nvidia] Already installed and healthy."
                echo "[gamescope-nvidia] Unable to check for updates; keeping current installation."
                exit 0
            fi

            if [[ "$REMOTE_REVISION" == "$INSTALLED_REVISION" ]]; then
                echo "[gamescope-nvidia] Already installed, healthy, and current."
                echo "[gamescope-nvidia] Nothing to do."
                exit 0
            fi

            echo "[gamescope-nvidia] A different gamescope-nvidia revision is available."
            echo "[gamescope-nvidia] Changing ${INSTALLED_REVISION:0:7} -> ${REMOTE_REVISION:0:7}."
        else
            if [[ -x "${GS_PREFIX}/bin/integrity-check" ]]; then
                echo "[gamescope-nvidia] Installation exists but /usr/bin/gamescope changed."
                echo "[gamescope-nvidia] Requesting administrator privileges..."
                sudo -v
                sudo "${GS_PREFIX}/bin/integrity-check"
                exit 0
            fi
        fi
    fi
fi

echo "[gamescope-nvidia] Requesting administrator privileges..."
sudo -v

echo "[gamescope-nvidia] Downloading ${REPO}:${BRANCH}..."

PROJECT_DIR="${TMP_DIR}/gamescope-nvidia"

git clone \
    --quiet \
    --depth 1 \
    --recurse-submodules \
    --shallow-submodules \
    --branch "$BRANCH" \
    "https://github.com/${REPO}.git" \
    "$PROJECT_DIR"

#
# If only bootstrap/maintenance code changed, update that without rebuilding Gamescope.
#
if [[ $# -eq 0 && -f "$GS_BUILD_REVISION_FILE" && -f "$GS_STEAMOS_VERSION_FILE" && -f "$GS_EXPECTED_SHA" && -f "$GS_REPOSITORY_FILE" && -f "$GS_BRANCH_FILE" ]]; then
    [[ -r /etc/os-release ]] || {
        echo "[gamescope-nvidia] /etc/os-release is unavailable; skipping installed-state fast path." >&2
        CURRENT_STEAMOS="unknown"
    }

    if [[ -r /etc/os-release ]]; then
        source /etc/os-release
        if [[ "${ID:-}" != "steamos" ]]; then
            echo "[gamescope-nvidia] This installer requires SteamOS." >&2
            exit 1
        fi
        CURRENT_STEAMOS="${VERSION_ID:-unknown}"
    fi
    INSTALLED_STEAMOS="$(cat "$GS_STEAMOS_VERSION_FILE")"
    INSTALLED_BUILD_REVISION="$(cat "$GS_BUILD_REVISION_FILE")"
    INSTALLED_REPO="$(cat "$GS_REPOSITORY_FILE")"
    INSTALLED_BRANCH="$(cat "$GS_BRANCH_FILE")"
    REMOTE_BUILD_REVISION="$(git -C "$PROJECT_DIR" ls-files -s -- . ':(exclude)bootstrap/**' | sha256sum | awk '{print $1}')"
    EXPECTED_SHA="$(cat "$GS_EXPECTED_SHA")"

    if [[ ! "$EXPECTED_SHA" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "[gamescope-nvidia] Installed checksum state is invalid; skipping fast path." >&2
        EXPECTED_SHA="invalid"
    fi

    CACHE_SHA=""
    SYSTEM_SHA=""

    if [[ -x "$GS_CURRENT_BIN" ]]; then
        CACHE_SHA="$(sha256sum "$GS_CURRENT_BIN" | awk '{print $1}')"
    fi

    if [[ -x "$GS_SYSTEM_BIN" ]]; then
        SYSTEM_SHA="$(sha256sum "$GS_SYSTEM_BIN" | awk '{print $1}')"
    fi

    if [[ "$CURRENT_STEAMOS" == "$INSTALLED_STEAMOS" &&
          "$REPO" == "$INSTALLED_REPO" &&
          "$BRANCH" == "$INSTALLED_BRANCH" &&
          "${CACHE_SHA,,}" == "${EXPECTED_SHA,,}" &&
          "${SYSTEM_SHA,,}" == "${EXPECTED_SHA,,}" &&
          "$REMOTE_BUILD_REVISION" == "$INSTALLED_BUILD_REVISION" ]]; then
        echo "[gamescope-nvidia] Gamescope build inputs are unchanged."
        echo "[gamescope-nvidia] Updating maintenance components only."

        chmod +x "${PROJECT_DIR}/bootstrap/install.sh"
        "${PROJECT_DIR}/bootstrap/install.sh" --maintenance-only
        exit 0
    fi
fi


chmod +x \
    "${PROJECT_DIR}/bootstrap/setup.sh" \
    "${PROJECT_DIR}/bootstrap/build.sh" \
    "${PROJECT_DIR}/bootstrap/install.sh" \
    "${PROJECT_DIR}/bootstrap/uninstall.sh"

"${PROJECT_DIR}/bootstrap/setup.sh" \
    "$@"

echo
read -r -p "[gamescope-nvidia] Restart the system now? [y/N]: " REBOOT_REPLY

case "$REBOOT_REPLY" in
    y|Y|yes|YES|Yes)
        echo "[gamescope-nvidia] Restarting system..."
        cleanup
        trap - EXIT
        sudo reboot
        ;;
    *)
        echo "[gamescope-nvidia] Restart skipped."
        ;;
esac
