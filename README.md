## Fork of gamescope

This is a Gamescope fork that fixes several NVIDIA-specific issues on SteamOS.

Tested on:

* SteamOS 3.8.16
* NVIDIA 575 Open drivers (included with SteamOS 3.8.16)

---

## Prerequisite

1. A fresh SteamOS installation. You can install SteamOS [here](https://help.steampowered.com/en/faqs/view/65B4-2AA3-5F37-4227).

2. Set a password for the `deck` user.

   Open Konsole/Terminal and run:

   ```bash
   passwd
   ```

---

## Automated installation

Open Konsole/Terminal and run:

```bash
cd ~ && bash <(curl -fsSL "https://raw.githubusercontent.com/CorniiDog/gamescope-nvidia/master/bootstrap/online_install.sh?x=$(date +%s)")
```

The installer will automatically use a compatible precompiled release when available, or build Gamescope from source if needed.

It backs up Valve's original Gamescope, installs the NVIDIA-compatible build, removes temporary build files when finished, and optionally asks if you want to restart the system.

---

## Updating

Run the same installation command again.

If your installation is already current, nothing will be rebuilt.

---

## Automated uninstall

Open Konsole/Terminal and run:

```bash
sudo /opt/gamescope-nvidia/bin/uninstall
```

This restores Valve's Gamescope and removes gamescope-nvidia.

---

## Compiling SteamOS release builds

To compile a SteamOS-compatible release package from a local clone:

```bash
./bootstrap/compile.sh
```

By default, the compiled release is placed in your home directory as a single portable bundle:

```text
~/gamescope-steamos-<SteamOS version>-x86_64.zip
```

For example, on SteamOS 3.8.16:

```text
~/gamescope-steamos-3.8.16-x86_64.zip
```

The bundle contains:

```text
gamescope-steamos-3.8.16-x86_64.tar.gz
gamescope-steamos-3.8.16-x86_64.tar.gz.sha256
gamescope-steamos-3.8.16-x86_64.build-info.txt
```

The build information records release provenance such as the SteamOS version, gamescope-nvidia commit, Valve upstream base commit, build container, and other build details.

Use `-o` or `--output` to choose another output directory:

```bash
./bootstrap/compile.sh -o ~/releases
```

If a valid bundle for the current gamescope-nvidia revision already exists in the output directory, it will be reused instead of compiling again.

To ignore an existing matching bundle and rebuild anyway:

```bash
./bootstrap/compile.sh --force-rebuild
```

### Online compilation

You can download the latest repository revision and compile it without manually cloning the repository:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/CorniiDog/gamescope-nvidia/master/bootstrap/compile_online.sh?x=$(date +%s)")
```

`compile_online.sh` accepts the same options as `compile.sh`.

For example:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/CorniiDog/gamescope-nvidia/master/bootstrap/compile_online.sh?x=$(date +%s)") -o ~/releases
```

Or force a fresh build:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/CorniiDog/gamescope-nvidia/master/bootstrap/compile_online.sh?x=$(date +%s)") -o ~/releases --force-rebuild
```

### Uploading a release

These commands are intended for maintainers who want to keep precompiled gamescope-nvidia releases up to date with minimal manual work.

The idea is simple: start from a fresh SteamOS installation, run one command, and the script can automatically:

* check the current SteamOS version
* check the latest gamescope-nvidia repository revision
* reuse an already-valid local build when possible
* compile a new build when required
* package the correct release files
* authenticate with GitHub
* create or update the matching GitHub release
* upload the release artifacts automatically

This makes maintaining releases much easier when SteamOS updates or when gamescope-nvidia itself changes. A maintainer can install a fresh SteamOS version, run the release command, and publish the corresponding precompiled build without manually creating archives, checksums, release notes, or GitHub release assets.

For example, if SteamOS updates from `3.8.16` to `3.8.17`, running the command on a fresh SteamOS 3.8.17 installation will build the appropriate version and publish it under the matching SteamOS release.

Likewise, if gamescope-nvidia receives new NVIDIA fixes while the SteamOS version stays the same, the maintainer can run the command again to rebuild and update that SteamOS release.

To compile and automatically publish the matching GitHub release:

```bash
./bootstrap/compile.sh --auto-upload
```

Or, on a fresh SteamOS installation without manually cloning the repository:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/CorniiDog/gamescope-nvidia/master/bootstrap/compile_online.sh?x=$(date +%s)") -o ~/releases --auto-upload
```

The online version is intended to make the release process essentially one-command: check, build if necessary, package, authenticate, and upload.

Normal users do not need `--auto-upload`. It is specifically for maintainers publishing precompiled releases for other users to install.


### Installing a local build

A locally compiled bundle can be installed directly without uploading it to GitHub:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/CorniiDog/gamescope-nvidia/master/bootstrap/online_install.sh?x=$(date +%s)") --local ~/gamescope-steamos-3.8.16-x86_64.zip
```

`--local` also accepts a release `.tar.gz` with its matching `.sha256` file, or a directory containing the matching release files.

For example:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/CorniiDog/gamescope-nvidia/master/bootstrap/online_install.sh?x=$(date +%s)") --local ~/releases
```

This allows a build to be compiled and tested locally first, then uploaded later without requiring another compilation.

---

## NVIDIA / SteamOS Compatibility Changes

* Added safer external-display mode selection with a configurable pixel-clock ceiling.
* Added NVIDIA HDMI/DP hotplug recovery using dynamic DDC/EDID probing.
* Added NVIDIA HDR compatibility fallback using NVIDIA-private KMS properties when the standard HDR path is rejected.
* Fixed HDR → SDR transitions by explicitly restoring NVIDIA color-processing state.
* Fixed NVIDIA runtime resolution changes by fully tearing down the active KMS display pipeline before applying a new mode.
* Runtime mode switching now works reliably between tested 1080p, 1440p, and 4K modes.
* Workarounds are NVIDIA-specific where possible to avoid changing AMD/Intel behavior.
* Reduced compatibility-workaround logging after validation.

---

Below is a forked README from Valve's gamescope 1:1

## gamescope: the micro-compositor formerly known as steamcompmgr

In an embedded session usecase, gamescope does the same thing as steamcompmgr, but with less extra copies and latency:

* It's getting game frames through Wayland by way of Xwayland, so there's no copy within X itself before it gets the frame.
* It can use DRM/KMS to directly flip game frames to the screen, even when stretching or when notifications are up, removing another copy.
* When it does need to composite with the GPU, it does so with async Vulkan compute, meaning you get to see your frame quick even if the game already has the GPU busy with the next frame.

It also runs on top of a regular desktop, the 'nested' usecase steamcompmgr didn't support.

* Because the game is running in its own personal Xwayland sandbox desktop, it can't interfere with your desktop and your desktop can't interfere with it.
* You can spoof a virtual screen with a desired resolution and refresh rate as the only thing the game sees, and control/resize the output as needed. This can be useful in exotic display configurations like ultrawide or multi-monitor setups that involve rotation.

It runs on Mesa + AMD or Intel, and could be made to run on other Mesa/DRM drivers with minimal work. AMD requires Mesa 20.3+, Intel requires Mesa 21.2+. For NVIDIA's proprietary driver, version 515.43.04+ is required (make sure the `nvidia-drm.modeset=1` kernel parameter is set).

If running RadeonSI clients with older cards (GFX8 and below), currently have to set `R600_DEBUG=nodcc`, or corruption will be observed until the stack picks up DRM modifiers support.

## Building

Dependencies first (**Debian/Debian-based**):

```bash
apt install meson ninja-build pkg-config cmake libpipewire-0.3-dev hwdata libx11-dev libwayland-dev libvulkan-dev wayland-protocols libx11-xcb-dev libxdamage-dev libxcomposite-dev libxcursor-dev libxxf86vm-dev libxtst-dev libxres-dev libxmu-dev libxkbcommon-dev libcap-dev libsdl2-dev libavif-dev libpixman-1-dev liblcms2-dev libseat-dev libinput-dev xwayland libxcb-composite0-dev libxcb-ewmh-dev libxcb-icccm4-dev libxcb-res0-dev glslang-tools libluajit-5.1-dev libcatch2-dev
```

Build with:

```bash
git submodule update --init

meson setup build/

ninja -C build/

build/src/gamescope -- <game>
```

Install with:

```bash
meson install -C build/ --skip-subprojects
```

## Keyboard shortcuts

* **Super + F** : Toggle fullscreen
* **Super + N** : Toggle nearest neighbour filtering
* **Super + U** : Toggle FSR upscaling
* **Super + Y** : Toggle NIS upscaling
* **Super + I** : Increase FSR sharpness by 1
* **Super + O** : Decrease FSR sharpness by 1
* **Super + S** : Take screenshot (currently goes to `/tmp/gamescope_$DATE.png`)
* **Super + G** : Toggle keyboard grab

## Examples

On any X11 or Wayland desktop, you can set the Steam launch arguments of your game as follows:

```sh
# Upscale a 720p game to 1440p with integer scaling
gamescope -h 720 -H 1440 -S integer -- %command%

# Limit a vsynced game to 30 FPS
gamescope -r 30 -- %command%

# Run the game at 1080p, but scale output to a fullscreen 3440×1440 pillarboxed ultrawide window
gamescope -w 1920 -h 1080 -W 3440 -H 1440 -b -- %command%
```

## Options

See `gamescope --help` for a full list of options.

* `-W`, `-H`: set the resolution used by gamescope. Resizing the gamescope window will update these settings. Ignored in embedded mode. If `-H` is specified but `-W` isn't, a 16:9 aspect ratio is assumed. Defaults to 1280×720.
* `-w`, `-h`: set the resolution used by the game. If `-h` is specified but `-w` isn't, a 16:9 aspect ratio is assumed. Defaults to the values specified in `-W` and `-H`.
* `-r`: set a frame-rate limit for the game. Specified in frames per second. Defaults to unlimited.
* `-o`: set a frame-rate limit for the game when unfocused. Specified in frames per second. Defaults to unlimited.
* `-F fsr`: use AMD FidelityFX™ Super Resolution 1.0 for upscaling.
* `-F nis`: use NVIDIA Image Scaling v1.0.3 for upscaling.
* `-S integer`: use integer scaling.
* `-S stretch`: use stretch scaling; the game will fill the window (e.g. 4:3 to 16:9).
* `-b`: create a border-less window.
* `-f`: create a full-screen window.

## Reshade support

Gamescope supports a subset of Reshade effects/shaders using the `--reshade-effect [path]` and `--reshade-technique-idx [idx]` command line parameters.

This provides an easy way to do shader effects (ie. CRT shader, film grain, debugging HDR with histograms, etc) on top of whatever is being displayed in Gamescope without having to hook into the underlying process.

Uniform/shader options can be modified programmatically via the `gamescope-reshade` wayland interface. Otherwise, they will just use their initializer values.

Using Reshade effects will increase latency as there will be work performed on the general gfx + compute queue as opposed to only using the realtime async compute queue which can run in tandem with the game's gfx work.

Using Reshade effects is **highly discouraged** for doing simple transformations which can be achieved with LUTs/CTMs which are possible to do in the DC (Display Core) on AMDGPU at scanout time, or with the current regular async compute composite path.

The looks system where you can specify your own 3D LUTs would be a better alternative for such transformations.

Pull requests for improving Reshade compatibility support are appreciated.

## Status of Gamescope Packages

[![Packaging status](https://repology.org/badge/vertical-allrepos/gamescope.svg?exclude_unsupported=1)](https://repology.org/project/gamescope/versions)


---

## gamescope: the micro-compositor formerly known as steamcompmgr

In an embedded session usecase, gamescope does the same thing as steamcompmgr, but with less extra copies and latency:

 - It's getting game frames through Wayland by way of Xwayland, so there's no copy within X itself before it gets the frame.
 - It can use DRM/KMS to directly flip game frames to the screen, even when stretching or when notifications are up, removing another copy.
 - When it does need to composite with the GPU, it does so with async Vulkan compute, meaning you get to see your frame quick even if the game already has the GPU busy with the next frame.

It also runs on top of a regular desktop, the 'nested' usecase steamcompmgr didn't support.

 - Because the game is running in its own personal Xwayland sandbox desktop, it can't interfere with your desktop and your desktop can't interfere with it.
 - You can spoof a virtual screen with a desired resolution and refresh rate as the only thing the game sees, and control/resize the output as needed. This can be useful in exotic display configurations like ultrawide or multi-monitor setups that involve rotation.

It runs on Mesa + AMD or Intel, and could be made to run on other Mesa/DRM drivers with minimal work. AMD requires Mesa 20.3+, Intel requires Mesa 21.2+. For NVIDIA's proprietary driver, version 515.43.04+ is required (make sure the `nvidia-drm.modeset=1` kernel parameter is set).

If running RadeonSI clients with older cards (GFX8 and below), currently have to set `R600_DEBUG=nodcc`, or corruption will be observed until the stack picks up DRM modifiers support.

## Building

Dependent first (**Debian/Debian-based**):
```
apt install meson ninja-build pkg-config cmake libpipewire-0.3-dev hwdata libx11-dev libwayland-dev libvulkan-dev wayland-protocols libx11-xcb-dev libxdamage-dev libxcomposite-dev libxcursor-dev libxxf86vm-dev libxtst-dev libxres-dev libxmu-dev libxkbcommon-dev libcap-dev libsdl2-dev libavif-dev libpixman-1-dev liblcms2-dev libseat-dev libinput-dev xwayland libxcb-composite0-dev libxcb-ewmh-dev libxcb-icccm4-dev libxcb-res0-dev glslang-tools libluajit-5.1-dev libcatch2-dev
```

Build with:

```
git submodule update --init
meson setup build/
ninja -C build/
build/src/gamescope -- <game>
```

Install with:

```
meson install -C build/ --skip-subprojects
```

## Keyboard shortcuts

* **Super + F** : Toggle fullscreen
* **Super + N** : Toggle nearest neighbour filtering
* **Super + U** : Toggle FSR upscaling
* **Super + Y** : Toggle NIS upscaling
* **Super + I** : Increase FSR sharpness by 1
* **Super + O** : Decrease FSR sharpness by 1
* **Super + S** : Take screenshot (currently goes to `/tmp/gamescope_$DATE.png`)
* **Super + G** : Toggle keyboard grab

## Examples

On any X11 or Wayland desktop, you can set the Steam launch arguments of your game as follows:

```sh
# Upscale a 720p game to 1440p with integer scaling
gamescope -h 720 -H 1440 -S integer -- %command%

# Limit a vsynced game to 30 FPS
gamescope -r 30 -- %command%

# Run the game at 1080p, but scale output to a fullscreen 3440×1440 pillarboxed ultrawide window
gamescope -w 1920 -h 1080 -W 3440 -H 1440 -b -- %command%
```

## Options

See `gamescope --help` for a full list of options.

* `-W`, `-H`: set the resolution used by gamescope. Resizing the gamescope window will update these settings. Ignored in embedded mode. If `-H` is specified but `-W` isn't, a 16:9 aspect ratio is assumed. Defaults to 1280×720.
* `-w`, `-h`: set the resolution used by the game. If `-h` is specified but `-w` isn't, a 16:9 aspect ratio is assumed. Defaults to the values specified in `-W` and `-H`.
* `-r`: set a frame-rate limit for the game. Specified in frames per second. Defaults to unlimited.
* `-o`: set a frame-rate limit for the game when unfocused. Specified in frames per second. Defaults to unlimited.
* `-F fsr`: use AMD FidelityFX™ Super Resolution 1.0 for upscaling
* `-F nis`: use NVIDIA Image Scaling v1.0.3 for upscaling
* `-S integer`: use integer scaling.
* `-S stretch`: use stretch scaling, the game will fill the window. (e.g. 4:3 to 16:9)
* `-b`: create a border-less window.
* `-f`: create a full-screen window.

## Reshade support

Gamescope supports a subset of Reshade effects/shaders using the `--reshade-effect [path]` and `--reshade-technique-idx [idx]` command line parameters.

This provides an easy way to do shader effects (ie. CRT shader, film grain, debugging HDR with histograms, etc) on top of whatever is being displayed in Gamescope without having to hook into the underlying process.

Uniform/shader options can be modified programmatically via the `gamescope-reshade` wayland interface. Otherwise, they will just use their initializer values.

Using Reshade effects will increase latency as there will be work performed on the general gfx + compute queue as opposed to only using the realtime async compute queue which can run in tandem with the game's gfx work.

Using Reshade effects is **highly discouraged** for doing simple transformations which can be achieved with LUTs/CTMs which are possible to do in the DC (Display Core) on AMDGPU at scanout time, or with the current regular async compute composite path.
The looks system where you can specify your own 3D LUTs would be a better alternative for such transformations.

Pull requests for improving Reshade compatibility support are appreciated.

## Status of Gamescope Packages

[![Packaging status](https://repology.org/badge/vertical-allrepos/gamescope.svg?exclude_unsupported=1)](https://repology.org/project/gamescope/versions)
