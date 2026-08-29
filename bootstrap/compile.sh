#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

OUTPUT_DIR="${HOME}"
AUTO_UPLOAD=0

usage()
{
    cat <<EOF_USAGE
Usage: ./bootstrap/compile.sh [options]

Options:
  -o, --output DIR    Output directory (default: ~/)
      --auto-upload   Create/update the matching GitHub release
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

require_steamos

if [[ "$AUTO_UPLOAD" == "1" ]]; then
    need_cmd gh

    gh auth status >/dev/null 2>&1 ||
        die "GitHub CLI is not authenticated. Run: gh auth login"

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

ARCHIVE="${OUTPUT_DIR}/${ASSET_NAME}"
CHECKSUM="${ARCHIVE}.sha256"
BUILD_INFO="${OUTPUT_DIR}/${ASSET_NAME%.tar.gz}.build-info.txt"

PACKAGE_DIR="$(mktemp -d)"

cleanup()
{
    rm -rf "$PACKAGE_DIR"
}

trap cleanup EXIT

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

    git -C "$PROJECT_ROOT" fetch         --quiet         --unshallow         origin
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

rm -f "$ARCHIVE" "$CHECKSUM"

tar -C "$PACKAGE_DIR" \
    -czf "$ARCHIVE" \
    src \
    runtime \
    BUILD-INFO.txt

(
    cd "$OUTPUT_DIR"
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

ok "Build artifacts created."

printf '\n'
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
