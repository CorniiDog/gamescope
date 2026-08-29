#!/usr/bin/env bash

set -euo pipefail

REPO="${GS_REPO:-CorniiDog/gamescope-nvidia}"
BRANCH="${GS_BRANCH:-master}"

OUTPUT_DIR="${HOME}"
AUTO_UPLOAD=0
FORCE_REBUILD=0
YES=0
ORIGINAL_ARGS=("$@")

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            [[ $# -ge 2 ]] || {
                echo "[gamescope-nvidia] $1 requires a directory." >&2
                exit 1
            }
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --auto-upload)
            AUTO_UPLOAD=1
            shift
            ;;
        --force-rebuild)
            FORCE_REBUILD=1
            shift
            ;;
        -y|--yes)
            YES=1
            shift
            ;;
        -h|--help)
            ;;
        *)
            ;;
    esac
done

need()
{
    command -v "$1" >/dev/null 2>&1 || {
        echo "[gamescope-nvidia] Missing command: $1" >&2
        exit 1
    }
}

need git

echo "[gamescope-nvidia] Checking ${REPO}:${BRANCH}..."

REMOTE_COMMIT="$(
    git ls-remote \
        "https://github.com/${REPO}.git" \
        "refs/heads/${BRANCH}" |
        awk "{print \$1}"
)"

[[ "$REMOTE_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] || {
    echo "[gamescope-nvidia] Could not determine remote repository revision." >&2
    exit 1
}

need curl

REMOTE_COMMON="$(
    curl -fsSL         "https://raw.githubusercontent.com/${REPO}/${REMOTE_COMMIT}/bootstrap/lib/common.sh"
)" || {
    echo "[gamescope-nvidia] Could not read remote build configuration." >&2
    exit 1
}

REMOTE_CONTAINER_IMAGE="$(
    printf "%s\n" "$REMOTE_COMMON" |
        sed -n 's/^GS_CONTAINER_IMAGE="${GS_CONTAINER_IMAGE:-\(.*\)}"/\1/p' |
        head -n1
)"

[[ -n "$REMOTE_CONTAINER_IMAGE" ]] || {
    echo "[gamescope-nvidia] Could not determine remote build container image." >&2
    exit 1
}

if [[ "$AUTO_UPLOAD" == "1" ]]; then
    if ! command -v gh >/dev/null 2>&1; then
        if [[ "$YES" == "1" ]]; then
            INSTALL_GH_REPLY="y"
        else
            echo
            read -r -p "[gamescope-nvidia] GitHub CLI (gh) is not installed. Install it now? [y/N]: " INSTALL_GH_REPLY
        fi

        case "$INSTALL_GH_REPLY" in
            y|Y|yes|YES|Yes)
                need sudo
                need pacman

                GH_READONLY_WAS_ENABLED=0

                if command -v steamos-readonly >/dev/null 2>&1 &&
                   steamos-readonly status 2>/dev/null | grep -qi enabled; then
                    echo "[gamescope-nvidia] Disabling SteamOS read-only mode temporarily..."
                    sudo steamos-readonly disable
                    GH_READONLY_WAS_ENABLED=1
                fi

                echo "[gamescope-nvidia] Installing GitHub CLI..."

                if ! sudo pacman -Sy --needed --noconfirm github-cli; then
                    if [[ "$GH_READONLY_WAS_ENABLED" == "1" ]]; then
                        sudo steamos-readonly enable || true
                    fi

                    echo "[gamescope-nvidia] GitHub CLI installation failed." >&2
                    exit 1
                fi

                if [[ "$GH_READONLY_WAS_ENABLED" == "1" ]]; then
                    echo "[gamescope-nvidia] Re-enabling SteamOS read-only mode..."
                    sudo steamos-readonly enable
                fi

                command -v gh >/dev/null 2>&1 || {
                    echo "[gamescope-nvidia] GitHub CLI installation completed but gh was not found." >&2
                    exit 1
                }
                ;;
            *)
                echo "[gamescope-nvidia] GitHub CLI is required for --auto-upload."
                exit 1
                ;;
        esac
    fi

    if ! gh auth status --hostname github.com >/dev/null 2>&1; then
        echo "[gamescope-nvidia] GitHub authentication is required for --auto-upload."
        echo
        echo "[gamescope-nvidia] Starting GitHub browser/device authentication..."
        echo

        gh auth login \
            --hostname github.com \
            --git-protocol https \
            --web

        gh auth status --hostname github.com >/dev/null 2>&1 || {
            echo "[gamescope-nvidia] GitHub authentication was not completed." >&2
            exit 1
        }
    fi

    GH_USERNAME="$(gh api user --jq ".login" 2>/dev/null)" || {
        echo "[gamescope-nvidia] Could not determine the authenticated GitHub account." >&2
        exit 1
    }

    echo
    echo "[gamescope-nvidia] Authenticated GitHub account: ${GH_USERNAME}"
    echo "[gamescope-nvidia] Target repository: ${REPO}"
    echo

    if [[ "$YES" == "1" ]]; then
        UPLOAD_REPLY="y"
    else
        read -r -p "[gamescope-nvidia] Continue with release upload? [y/N]: " UPLOAD_REPLY
    fi

    case "$UPLOAD_REPLY" in
        y|Y|yes|YES|Yes)
            ;;
        *)
            echo "[gamescope-nvidia] Upload cancelled."
            exit 0
            ;;
    esac
fi

if [[ -r /etc/os-release ]]; then
    source /etc/os-release
else
    echo "[gamescope-nvidia] Cannot read /etc/os-release." >&2
    exit 1
fi

[[ "${ID:-}" == "steamos" || "${NAME:-}" == *"SteamOS"* ]] || {
    echo "[gamescope-nvidia] This operation is intended for SteamOS." >&2
    exit 1
}

STEAMOS_VERSION="${VERSION_ID:-}"

[[ -n "$STEAMOS_VERSION" ]] || {
    echo "[gamescope-nvidia] Could not determine SteamOS VERSION_ID." >&2
    exit 1
}

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

ASSET_NAME="gamescope-steamos-${STEAMOS_VERSION}-x86_64.tar.gz"
BUNDLE_NAME="${ASSET_NAME%.tar.gz}.zip"
BUNDLE="${OUTPUT_DIR}/${BUNDLE_NAME}"

TMP_DIR="$(mktemp -d)"

cleanup()
{
    rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

CACHE_HIT=0

if [[ "$FORCE_REBUILD" == "0" && -f "$BUNDLE" ]]; then
    need unzip
    need sha256sum

    RELEASE_DIR="${TMP_DIR}/release"
    mkdir -p "$RELEASE_DIR"

    if unzip -q "$BUNDLE" -d "$RELEASE_DIR"; then
        ARCHIVE="${RELEASE_DIR}/${ASSET_NAME}"
        CHECKSUM="${ARCHIVE}.sha256"
        BUILD_INFO="${RELEASE_DIR}/${ASSET_NAME%.tar.gz}.build-info.txt"

        if [[ -f "$ARCHIVE" &&
              -f "$CHECKSUM" &&
              -f "$BUILD_INFO" ]]; then

            CACHED_COMMIT="$(
                grep -m1 "^nvidia_fork_commit=" "$BUILD_INFO" 2>/dev/null |
                    cut -d= -f2-
            )"

            CACHED_STEAMOS="$(
                grep -m1 "^steamos_version=" "$BUILD_INFO" 2>/dev/null |
                    cut -d= -f2-
            )"

            CACHED_CONTAINER="$(
                grep -m1 "^container_image=" "$BUILD_INFO" 2>/dev/null |
                    cut -d= -f2-
            )"

            EXPECTED_SHA="$(
                awk "{print \$1}" "$CHECKSUM" |
                    head -n1
            )"

            ACTUAL_SHA="$(
                sha256sum "$ARCHIVE" |
                    awk "{print \$1}"
            )"

            if [[ "$EXPECTED_SHA" =~ ^[0-9a-fA-F]{64}$ &&
                  "$CACHED_COMMIT" == "$REMOTE_COMMIT" &&
                  "$CACHED_STEAMOS" == "$STEAMOS_VERSION" &&
                  "$CACHED_CONTAINER" == "$REMOTE_CONTAINER_IMAGE" &&
                  "${EXPECTED_SHA,,}" == "${ACTUAL_SHA,,}" ]]; then

                CACHE_HIT=1
                echo "[gamescope-nvidia] Existing build matches GitHub revision ${REMOTE_COMMIT:0:7}."
            fi
        fi
    fi
fi

if [[ "$CACHE_HIT" == "1" ]]; then
    if [[ "$AUTO_UPLOAD" != "1" ]]; then
        echo "[gamescope-nvidia] Already compiled and current."
        echo "[gamescope-nvidia] Bundle: ${BUNDLE}"
        exit 0
    fi

    RELEASE_TAG="steamos-${STEAMOS_VERSION}"

    VALVE_BASE_COMMIT="$(
        grep -m1 "^valve_base_commit=" "$BUILD_INFO" 2>/dev/null |
            cut -d= -f2-
    )"

    VALVE_MASTER_COMMIT="$(
        grep -m1 "^valve_master_at_build=" "$BUILD_INFO" 2>/dev/null |
            cut -d= -f2-
    )"

    CONTAINER_IMAGE="$(
        grep -m1 "^container_image=" "$BUILD_INFO" 2>/dev/null |
            cut -d= -f2-
    )"

    echo "[gamescope-nvidia] Reusing existing build bundle."
    echo "[gamescope-nvidia] Uploading ${RELEASE_TAG}..."

    if gh release view "$RELEASE_TAG" \
        --repo "$REPO" >/dev/null 2>&1; then

        echo "[gamescope-nvidia] Release already exists; replacing matching artifacts."

        gh release upload "$RELEASE_TAG" \
            "$ARCHIVE" \
            "$CHECKSUM" \
            "$BUILD_INFO" \
            --repo "$REPO" \
            --clobber
    else
        gh release create "$RELEASE_TAG" \
            "$ARCHIVE" \
            "$CHECKSUM" \
            "$BUILD_INFO" \
            --repo "$REPO" \
            --target "$REMOTE_COMMIT" \
            --title "gamescope-nvidia - SteamOS ${STEAMOS_VERSION}" \
            --notes "Precompiled gamescope-nvidia build for SteamOS ${STEAMOS_VERSION}.

NVIDIA fork commit: ${REMOTE_COMMIT}
Valve upstream base: ${VALVE_BASE_COMMIT}
Valve master at build: ${VALVE_MASTER_COMMIT}
Container: ${CONTAINER_IMAGE}"
    fi

    echo "[gamescope-nvidia] Release uploaded successfully."
    exit 0
fi

echo "[gamescope-nvidia] No current local build found."
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

chmod +x \
    "${PROJECT_DIR}/bootstrap/compile.sh" \
    "${PROJECT_DIR}/bootstrap/build.sh"

"${PROJECT_DIR}/bootstrap/compile.sh" "${ORIGINAL_ARGS[@]}"
