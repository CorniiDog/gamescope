#!/usr/bin/env bash

set -euo pipefail

REPO="${GS_REPO:-CorniiDog/gamescope-nvidia}"
BRANCH="${GS_BRANCH:-master}"

TMP_DIR="$(mktemp -d)"

cleanup()
{
    rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

command -v git >/dev/null 2>&1 || {
    echo "[gamescope-nvidia] Missing command: git" >&2
    exit 1
}

echo "[gamescope-nvidia] Downloading ${REPO}:${BRANCH}..."

git clone \
    --quiet \
    --depth 1 \
    --recurse-submodules \
    --shallow-submodules \
    --branch "$BRANCH" \
    "https://github.com/${REPO}.git" \
    "${TMP_DIR}/gamescope-nvidia"

chmod +x "${TMP_DIR}/gamescope-nvidia/bootstrap/compile.sh"

"${TMP_DIR}/gamescope-nvidia/bootstrap/compile.sh" "$@"
