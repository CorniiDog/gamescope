#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

OUTPUT_DIR="${HOME}"
AUTO_UPLOAD=0
FORCE_REBUILD=0

usage()
{
    cat <<EOF_USAGE
Usage: ./bootstrap/compile.sh [options]

Options:
  -o, --output DIR    Output directory (default: ~/)
      --auto-upload   Create/update the matching GitHub release
      --force-rebuild Ignore existing matching build artifacts
  -h, --help          Show this help
EOF_USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            [[ $# -ge 2 ]] || die "$1 requires a directory."
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
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

need_cmd git
need_cmd podman
need_cmd tar
need_cmd sha256sum
need_cmd zip
need_cmd unzip

require_steamos

if [[ "$AUTO_UPLOAD" == "1" ]]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo
        read -r -p "[gamescope-nvidia] GitHub CLI (gh) is not installed. Install it now? [y/N]: " INSTALL_GH_REPLY

        case "$INSTALL_GH_REPLY" in
            y|Y|yes|YES|Yes)
                need_cmd sudo
                need_cmd pacman

                GH_READONLY_WAS_ENABLED=0

                if command -v steamos-readonly >/dev/null 2>&1 &&
                   steamos-readonly status 2>/dev/null | grep -qi enabled; then
                    log "Disabling SteamOS read-only mode temporarily..."
                    sudo steamos-readonly disable
                    GH_READONLY_WAS_ENABLED=1
                fi

                log "Installing GitHub CLI..."

                if ! sudo pacman -Sy --needed --noconfirm github-cli; then
                    if [[ "$GH_READONLY_WAS_ENABLED" == "1" ]]; then
                        sudo steamos-readonly enable || true
                    fi

                    die "GitHub CLI installation failed."
                fi

                if [[ "$GH_READONLY_WAS_ENABLED" == "1" ]]; then
                    log "Re-enabling SteamOS read-only mode..."
                    sudo steamos-readonly enable
                fi

                command -v gh >/dev/null 2>&1 ||
                    die "GitHub CLI installation completed but gh was not found."
                ;;
            *)
                die "GitHub CLI is required for --auto-upload."
                ;;
        esac
    fi

    if ! gh auth status --hostname github.com >/dev/null 2>&1; then
        log "GitHub authentication is required for --auto-upload."
        echo
        echo "[gamescope-nvidia] Starting GitHub browser/device authentication..."
        echo

        gh auth login             --hostname github.com             --git-protocol https             --web

        gh auth status --hostname github.com >/dev/null 2>&1 ||
            die "GitHub authentication was not completed."
    fi

    GH_USERNAME="$(gh api user --jq ".login" 2>/dev/null)" ||
        die "Could not determine the authenticated GitHub account."

    echo
    echo "[gamescope-nvidia] Authenticated GitHub account: ${GH_USERNAME}"
    echo "[gamescope-nvidia] Target repository: ${GS_REPO}"
    echo

    read -r -p "[gamescope-nvidia] Continue with release upload? [y/N]: " UPLOAD_REPLY

    case "$UPLOAD_REPLY" in
        y|Y|yes|YES|Yes)
            ;;
        *)
            die "Upload cancelled."
            ;;
    esac

    [[ -z "$(git -C "$PROJECT_ROOT" status --porcelain)" ]] ||
        die "Git working tree is not clean. Commit changes before --auto-upload."
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

STEAMOS_VERSION="$(get_steamos_version)"
RELEASE_TAG="$(release_tag_for_steamos)"
ASSET_NAME="$(release_asset_for_steamos)"

BUILD_DIR="${PROJECT_ROOT}/${GS_BUILD_DIR_NAME}"
BINARY="${BUILD_DIR}/src/gamescope"
RUNTIME_DIR="${BUILD_DIR}/runtime"

BUNDLE_NAME="${ASSET_NAME%.tar.gz}.zip"
BUNDLE="${OUTPUT_DIR}/${BUNDLE_NAME}"

NVIDIA_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
CACHE_HIT=0

WORK_DIR="$(mktemp -d)"
RELEASE_FILES_DIR="${WORK_DIR}/release-files"
PACKAGE_DIR="${WORK_DIR}/package"

ARCHIVE="${RELEASE_FILES_DIR}/${ASSET_NAME}"
CHECKSUM="${ARCHIVE}.sha256"
BUILD_INFO="${RELEASE_FILES_DIR}/${ASSET_NAME%.tar.gz}.build-info.txt"

metadata_value()
{
    local file="$1"
    local key="$2"

    grep -m1 "^${key}=" "$file" 2>/dev/null | cut -d= -f2-
}

if [[ "$FORCE_REBUILD" == "0" && -f "$BUNDLE" ]]; then
    mkdir -p "$RELEASE_FILES_DIR"

    if unzip -q "$BUNDLE" -d "$RELEASE_FILES_DIR"; then
        BUNDLE_ARCHIVE="${RELEASE_FILES_DIR}/${ASSET_NAME}"
        BUNDLE_CHECKSUM="${BUNDLE_ARCHIVE}.sha256"
        BUNDLE_INFO="${RELEASE_FILES_DIR}/${ASSET_NAME%.tar.gz}.build-info.txt"

        if [[ -f "$BUNDLE_ARCHIVE" &&
              -f "$BUNDLE_CHECKSUM" &&
              -f "$BUNDLE_INFO" ]]; then

            CACHED_COMMIT="$(metadata_value "$BUNDLE_INFO" nvidia_fork_commit)"
            CACHED_STEAMOS="$(metadata_value "$BUNDLE_INFO" steamos_version)"
            CACHED_CONTAINER="$(metadata_value "$BUNDLE_INFO" container_image)"
            CACHED_SHA="$(awk '{print $1}' "$BUNDLE_CHECKSUM" | head -n1)"

            if [[ "$CACHED_SHA" =~ ^[0-9a-fA-F]{64}$ &&
                  "$CACHED_COMMIT" == "$NVIDIA_COMMIT" &&
                  "$CACHED_STEAMOS" == "$STEAMOS_VERSION" &&
                  "$CACHED_CONTAINER" == "$GS_CONTAINER_IMAGE" &&
                  "${CACHED_SHA,,}" == "$(sha256_file "$BUNDLE_ARCHIVE")" ]]; then

                CACHE_HIT=1
                VALVE_BASE_COMMIT="$(metadata_value "$BUNDLE_INFO" valve_base_commit)"
                VALVE_MASTER_COMMIT="$(metadata_value "$BUNDLE_INFO" valve_master_at_build)"

                ARCHIVE="$BUNDLE_ARCHIVE"
                CHECKSUM="$BUNDLE_CHECKSUM"
                BUILD_INFO="$BUNDLE_INFO"

                log "Existing build bundle matches the current repository revision."
                log "Skipping compilation."
            fi
        fi
    fi

    if [[ "$CACHE_HIT" == "0" ]]; then
        rm -rf "$RELEASE_FILES_DIR"
        mkdir -p "$RELEASE_FILES_DIR"
    fi
fi

cleanup()
{
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT

if [[ "$CACHE_HIT" == "0" ]]; then
    log "Building gamescope-nvidia for SteamOS ${STEAMOS_VERSION}..."
    log "Output directory: ${OUTPUT_DIR}"

    "${SCRIPT_DIR}/build.sh"

    [[ -x "$BINARY" ]] ||
        die "Built Gamescope binary not found: ${BINARY}"

    [[ -d "$RUNTIME_DIR" ]] ||
        die "Built runtime directory not found: ${RUNTIME_DIR}"

    compgen -G "${RUNTIME_DIR}/*" >/dev/null ||
        die "Built runtime directory is empty."

    #
    # Repository provenance.
    #
    if [[ "$(git -C "$PROJECT_ROOT" rev-parse --is-shallow-repository)" == "true" ]]; then
        log "Fetching repository history for provenance..."

        git -C "$PROJECT_ROOT" fetch \
            --quiet \
            --unshallow \
            --recurse-submodules=no \
            origin
    fi

    NVIDIA_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
    NVIDIA_BRANCH="$(git -C "$PROJECT_ROOT" branch --show-current || true)"
    NVIDIA_BRANCH="${NVIDIA_BRANCH:-detached}"

    VALVE_MASTER_COMMIT="$(
        git ls-remote \
            https://github.com/ValveSoftware/gamescope.git \
            refs/heads/master |
            awk '{print $1}'
    )"

    [[ "$VALVE_MASTER_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] ||
        die "Could not determine current Valve Gamescope master commit."

    #
    # Fetch Valve master into a temporary local ref so we can determine
    # the actual upstream commit this fork descends from.
    #
    VALVE_TEMP_REF="refs/gamescope-nvidia-build/valve-master"

    git -C "$PROJECT_ROOT" fetch \
        --quiet \
        --no-tags \
        --recurse-submodules=no \
        https://github.com/ValveSoftware/gamescope.git \
        "master:${VALVE_TEMP_REF}"

    VALVE_BASE_COMMIT="$(
        git -C "$PROJECT_ROOT" merge-base HEAD "$VALVE_TEMP_REF"
    )"

    git -C "$PROJECT_ROOT" update-ref -d "$VALVE_TEMP_REF"

    [[ "$VALVE_BASE_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] ||
        die "Could not determine Valve upstream base commit."

    #
    # Gather versions from the exact build container.
    #
    CONTAINER_INFO="$(
        podman run --rm \
            "$GS_CONTAINER_IMAGE" \
            bash -c '
                source /etc/os-release
                printf "fedora_version=%s\n" "${VERSION_ID:-unknown}"
                printf "gcc_version=%s\n" "$(gcc --version 2>/dev/null | head -n1 || printf unavailable)"
                printf "glibc_version=%s\n" "$(ldd --version 2>/dev/null | head -n1 || printf unavailable)"
            '
    )"

    GAMESCOPE_VERSION="$(
        LD_LIBRARY_PATH="$RUNTIME_DIR" "$BINARY" --version 2>&1 |
            head -n1
    )"

    BUILD_TIMESTAMP="$(date --iso-8601=seconds)"

    #
    # Build metadata.
    #
    {
        printf 'gamescope-nvidia build information\n'
        printf '\n'
        printf 'built_at=%s\n' "$BUILD_TIMESTAMP"
        printf 'steamos_version=%s\n' "$STEAMOS_VERSION"
        printf 'release_tag=%s\n' "$RELEASE_TAG"
        printf 'release_asset=%s\n' "$ASSET_NAME"
        printf '\n'
        printf 'repository=%s\n' "$GS_REPO"
        printf 'branch=%s\n' "$NVIDIA_BRANCH"
        printf 'nvidia_fork_commit=%s\n' "$NVIDIA_COMMIT"
        printf 'valve_base_commit=%s\n' "$VALVE_BASE_COMMIT"
        printf 'valve_master_at_build=%s\n' "$VALVE_MASTER_COMMIT"
        printf '\n'
        printf 'container_image=%s\n' "$GS_CONTAINER_IMAGE"
        printf '%s\n' "$CONTAINER_INFO"
        printf 'gamescope_version=%s\n' "$GAMESCOPE_VERSION"
        printf '\n'
        printf 'runtime_libraries:\n'

        for runtime_lib in "$RUNTIME_DIR"/*; do
            [[ -f "$runtime_lib" ]] || continue

            printf '  %s  %s\n' \
                "$(sha256_file "$runtime_lib")" \
                "$(basename "$runtime_lib")"
        done
    } > "$BUILD_INFO"

    #
    # Package exactly what the online installer needs, plus provenance.
    #
    mkdir -p \
        "${PACKAGE_DIR}/src" \
        "${PACKAGE_DIR}/runtime"

    install -m 0755 \
        "$BINARY" \
        "${PACKAGE_DIR}/src/gamescope"

    cp -a \
        "${RUNTIME_DIR}/." \
        "${PACKAGE_DIR}/runtime/"

    cp \
        "$BUILD_INFO" \
        "${PACKAGE_DIR}/BUILD-INFO.txt"

    mkdir -p "$RELEASE_FILES_DIR"

    rm -f "$ARCHIVE" "$CHECKSUM"

    tar -C "$PACKAGE_DIR" \
        -czf "$ARCHIVE" \
        src \
        runtime \
        BUILD-INFO.txt

    (
        cd "$RELEASE_FILES_DIR"
        sha256sum "$ASSET_NAME" > "$(basename "$CHECKSUM")"
    )

    EXPECTED="$(awk '{print $1}' "$CHECKSUM")"
    ACTUAL="$(sha256_file "$ARCHIVE")"

    [[ "$EXPECTED" == "$ACTUAL" ]] ||
        die "Generated release archive failed checksum verification."

    #
    # Add the final archive checksum to the external build-info file.
    #
    printf 'archive_sha256=%s\n' "$ACTUAL" >> "$BUILD_INFO"

    rm -f "$BUNDLE"

    (
        cd "$RELEASE_FILES_DIR"
        zip -q "$BUNDLE" \
            "$ASSET_NAME" \
            "${ASSET_NAME}.sha256" \
            "${ASSET_NAME%.tar.gz}.build-info.txt"
    )

    ok "Build artifacts created."
fi

printf '\n'
printf 'Bundle:     %s\n' "$BUNDLE"
printf 'Archive:    %s\n' "$ARCHIVE"
printf 'Checksum:   %s\n' "$CHECKSUM"
printf 'Build info: %s\n' "$BUILD_INFO"
printf '\n'
printf 'NVIDIA commit: %s\n' "$NVIDIA_COMMIT"
printf 'Valve base:    %s\n' "$VALVE_BASE_COMMIT"

if [[ "$AUTO_UPLOAD" != "1" ]]; then
    printf '\n'
    log "GitHub upload skipped. Use --auto-upload to publish this build."
    exit 0
fi

log "Uploading ${RELEASE_TAG} to GitHub..."

if gh release view "$RELEASE_TAG" \
    --repo "$GS_REPO" >/dev/null 2>&1; then

    log "Release already exists; replacing matching artifacts."

    gh release upload "$RELEASE_TAG" \
        "$ARCHIVE" \
        "$CHECKSUM" \
        "$BUILD_INFO" \
        --repo "$GS_REPO" \
        --clobber
else
    gh release create "$RELEASE_TAG" \
        "$ARCHIVE" \
        "$CHECKSUM" \
        "$BUILD_INFO" \
        --repo "$GS_REPO" \
        --target "$NVIDIA_COMMIT" \
        --title "gamescope-nvidia - SteamOS ${STEAMOS_VERSION}" \
        --notes "Precompiled gamescope-nvidia build for SteamOS ${STEAMOS_VERSION}.

NVIDIA fork commit: ${NVIDIA_COMMIT}
Valve upstream base: ${VALVE_BASE_COMMIT}
Valve master at build: ${VALVE_MASTER_COMMIT}
Container: ${GS_CONTAINER_IMAGE}"
fi

ok "Release uploaded successfully."
