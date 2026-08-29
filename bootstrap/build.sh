#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

BUILD_DIR="${PROJECT_ROOT}/${GS_BUILD_DIR_NAME}"
OUTPUT_BIN="${BUILD_DIR}/src/gamescope"

need_cmd podman
need_cmd git

[[ -f "${PROJECT_ROOT}/meson.build" ]] ||
    die "meson.build not found at project root."

log "Preparing Gamescope source tree..."

(
    cd "$PROJECT_ROOT"

    git submodule update --init --recursive
)

mkdir -p "$BUILD_DIR"

log "Building Gamescope using ${GS_CONTAINER_IMAGE}..."

podman run \
    --rm \
    --security-opt label=disable \
    -v "${PROJECT_ROOT}:/src" \
    -w /src \
    "${GS_CONTAINER_IMAGE}" \
    bash -euxo pipefail -c '

        dnf install -y \
            gcc \
            gcc-c++ \
            clang \
            git \
            cmake \
            meson \
            ninja-build \
            pkgconf-pkg-config \
            glslang \
            wayland-devel \
            wayland-protocols-devel \
            libdrm-devel \
            libinput-devel \
            libseat-devel \
            libxkbcommon-devel \
            libcap-devel \
            pipewire-devel \
            pixman-devel \
            lcms2-devel \
            libavif-devel \
            vulkan-loader-devel \
            vulkan-headers \
            libliftoff-devel \
            libdecor-devel \
            libdisplay-info-devel \
            libeis-devel \
            SDL2-devel \
            hwdata-devel \
            luajit-devel \
            libX11-devel \
            libX11-xcb \
            libXcomposite-devel \
            libXcursor-devel \
            libXdamage-devel \
            libXext-devel \
            libXfixes-devel \
            libXi-devel \
            libXmu-devel \
            libXrender-devel \
            libXres-devel \
            libXtst-devel \
            libXxf86vm-devel \
            libxcb-devel \
            xcb-util-devel \
            xcb-util-wm-devel \
            xcb-util-keysyms-devel \
            xorg-x11-server-Xwayland \
            xorg-x11-server-Xwayland-devel \
            edid-decode \
            google-benchmark-devel \
            patchelf

        if [[ -d "'"${GS_BUILD_DIR_NAME}"'/meson-private" ]]; then
            meson setup \
                -Denable_tests=false \
                --reconfigure \
                "'"${GS_BUILD_DIR_NAME}"'"
        else
            rm -rf "'"${GS_BUILD_DIR_NAME}"'"

            meson setup \
                -Denable_tests=false \
                "'"${GS_BUILD_DIR_NAME}"'"
        fi

        ninja \
            -C "'"${GS_BUILD_DIR_NAME}"'"

        mkdir -p "'"${GS_BUILD_DIR_NAME}"'/runtime"

        RUNTIME_LIBS=(
            libdisplay-info.so.2
        )

        for runtime_lib in "${RUNTIME_LIBS[@]}"; do
            runtime_path="/usr/lib64/${runtime_lib}"

            [[ -f "$runtime_path" ]] || {
                printf "Required bundled runtime library not found: %s\n" "$runtime_path" >&2
                exit 1
            }

            cp -L \
                "$runtime_path" \
                "'"${GS_BUILD_DIR_NAME}"'/runtime/${runtime_lib}"
        done

        patchelf \
            --set-rpath "'"${GS_PREFIX}"'/lib" \
            "'"${GS_BUILD_DIR_NAME}"'/src/gamescope"
    '

[[ -x "$OUTPUT_BIN" ]] ||
    die "Build completed but binary was not found: $OUTPUT_BIN"

ok "Build successful."

printf '\nBinary:\n'
printf '  %s\n\n' "$OUTPUT_BIN"

LD_LIBRARY_PATH="${BUILD_DIR}/runtime" "$OUTPUT_BIN" --version
