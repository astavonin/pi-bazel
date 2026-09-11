# pi-bazel

Bazel cross-compilation from an x86_64 Linux host to a Raspberry Pi 5, for networking and video applications built on Boost and GStreamer.

The goal is a **stable, predictable, reproducible** build: the compiler and all pure-source dependencies are hermetic, and the small set of device-coupled system libraries comes from a pinned, checksummed sysroot rather than from whatever happens to be installed on the build machine.

## Build and test

Requires [bazelisk](https://github.com/bazelbuild/bazelisk) on `PATH`; it reads `.bazelversion` and fetches Bazel 9.2.0 itself. Nothing else needs installing — the compiler, its runtime libraries and the sysroot are all fetched and checksummed by the build.

```sh
# Host: build and run the unit tests on x86_64.
bazel test --config=host //...

# Cross: build the aarch64 binary.
bazel build --config=pi //src/hello
file bazel-bin/src/hello/hello        # ELF 64-bit LSB pie executable, ARM aarch64

# Device: deploy to the Pi over ssh, run it, and check the result.
bazel test --config=pi //...
```

The device test needs the Pi reachable as the ssh alias `pi` with key-based auth. Point it elsewhere with `--test_env=PI_SSH_HOST=<host>`. A Bazel test cannot read `~/.ssh/config` by default, so `.bazelrc` forwards `HOME` and `SSH_AUTH_SOCK` explicitly under `--config=pi`.

`--config=ci` composes with either and adds network isolation plus strict dependency checking:

```sh
bazel build --config=ci --config=host //...
```

### What runs where

`bazel test //...` is correct under both configurations — targets that do not belong to the selected platform are skipped rather than failing:

```
bazel test --config=host //...    hello_test PASSED · device_smoke SKIPPED
bazel test --config=pi //...      device_smoke PASSED · hello_test SKIPPED
```

Naming a target that does not belong to the current platform is an error rather than a silent skip:

```
$ bazel test --config=pi //src/hello:hello_test
ERROR: Target //src/hello:hello_test is incompatible and cannot be built, but was explicitly requested.
```

The device test reports three distinguishable failures, because an unreachable Pi, a bad artifact, and a broken test harness call for different responses. The label is the first line of output:

```
DEVICE-UNREACHABLE: ssh to 'pi' failed          # exit 2 — the toolchain is not implicated
SMOKE-FAILED: c++ runtime present: ...          # exit 1 — the device answered, the artifact was wrong
HARNESS-FAILED: could not resolve ... via rlocation  # exit 3 — a build-graph fault, neither device nor artifact
```

### First build

The first build fetches two LLVM distributions — the x86_64 host toolchain and an aarch64 one used only as a library donor — plus ICU and a sysroot. Budget roughly **3.8 GB of downloads and around 62 GB in `~/.cache/bazel`** (LLVM X64 1.9 GB + ARM64 1.8 GB + ICU + sysroot; the cache is larger than the download total because it also holds extracted trees and build outputs), and a correspondingly slow first run. Subsequent builds hit the repository cache.

## Target

| Property | Value |
|---|---|
| Board | Raspberry Pi 5 (`ssh pi`) |
| OS | Debian 13 (trixie) |
| Architecture | aarch64, Cortex-A76 |
| glibc | 2.41 |
| System GCC | 14.2 |
| Kernel | 6.12 |

Built with Bazel 9.2.0 via bazelisk, Clang 23.1.0, `-std=c++23`.

The Pi 5 has **no hardware H.264 or H.265 encoder** — that block was removed relative to the Pi 4. Video encoding is software x264 on the four A76 cores.

### Cameras

| | Sensor | Link | Native | Access |
|---|---|---|---|---|
| cam0 | IMX708 (Camera Module 3) | CSI | 4608×2592, 10-bit RGGB | libcamera |
| cam1 | IMX477 (HQ Camera) | CSI | 4056×3040, 12-bit RGGB | libcamera |
| usb | Logitech C920 | USB 2.0 | MJPG 1080p30 / YUYV 1080p5 | `v4l2src` |

The two CSI cameras require **libcamera** — the `/dev/video*` CFE nodes carry raw Bayer, and the PiSP hardware ISP is reachable only through libcamera's `rpi/pisp` pipeline handler. They are reached via GStreamer's `libcamerasrc`, so libcamera's C++ API never appears on the link line. The stack is fully open source: libcamera is LGPL-2.1+, libpisp is BSD-2-Clause.

### Measured encode capacity

Real pipeline, 20 s runs, output to local files:

| Configuration | CPU used | Idle | Frames delivered |
|---|---|---|---|
| 2 × CSI 1080p30 | 29% | 71% | 589, 587 / 600 |
| \+ C920 1080p30 → x264 | 82.5% | 17.5% | 587, 586, 552 / 600 |
| \+ C920 720p30 → x264 | **51%** | 49% | 588, 587, 599 / 600 |
| \+ C920 1080p30 MJPEG passthrough | 35% | 65% | 589, 588, 572 / 600 — but 90 Mbps on the wire |

**Recommended: 2 × CSI 1080p30 + C920 at 720p30.** The USB camera is disproportionately expensive because its MJPEG frames are decoded on the CPU, while CSI frames arrive from the PiSP by DMA for free.

The constant ~11-frame shortfall on CSI streams is startup settling, not encode drops — it appears identically in the single-camera case.

Measured against near-static scenes (1.2–5 Mbps), so these are floors. RTSP, SRT and network I/O are not included.

## Build strategy

| Layer | Source | Hermetic |
|---|---|---|
| Compiler — Clang 23.1.0, lld, static libc++ 23 | `toolchains_llvm` v1.9.0, checksummed download | yes |
| Boost, GoogleTest, fmt/spdlog | Bazel Central Registry, built from source | yes |
| GStreamer, glib, DRM (all C) | pinned Debian-snapshot sysroot tarball, sha256 | pinned, not source-built |

The C++ runtime is **statically linked libc++ 23**, not the sysroot's libstdc++. This works because nothing on the link line crosses a C++ ABI — GStreamer, glib and gobject are all C, and libcamera is reached through the `libcamerasrc` plugin rather than linked. Code is compiled at `-std=c++23`, the newest standard with substantially complete libc++ library support.

C++26 is deferred: reflection and contracts are currently GCC-16-mainline-only and Clang has neither. The toolchain is registered per-platform in Bazel, so swapping or adding one later is not a rewrite.

Binaries are compiled against the pinned interim sysroot's glibc 2.24 headers and run on the Pi's 2.41 — glibc is forward-compatible in that direction. `M02`'s Debian trixie sysroot raises this floor.

## Media stack

GStreamer 1.26, linked thin: the build depends only on `libgstreamer-1.0`, `libgstapp-1.0`, `libgstrtspserver-1.0`, `libglib-2.0` and `libgobject-2.0` from the sysroot. Every codec and protocol plugin is loaded at runtime from the device, so plugins never enter the build graph.

- **RTSP** — `gst-rtsp-server`
- **SRT** — `srtsrc` / `srtsink` from `gstreamer1.0-plugins-bad`, against the gnutls flavour of libsrt
- **Capture** — `libcamerasrc` (RPi-packaged, 0.5.2) or `v4l2src`

Because `libcamerasrc` is a runtime plugin, libcamera's C++ API never appears on the link line.

## Repository layout

```
MODULE.bazel          bzlmod dependency graph   ┐
MODULE.bazel.lock     resolved dependency lock  │ Bazel requires
.bazelrc              named configurations      │ these at the root
.bazelversion         pinned Bazel release      ┘

bazel/                build machinery
├── platforms/        host and //bazel/platforms:pi5 definitions
├── toolchains/       LLVM toolchain registration, sysroot wiring
├── sysroot/          mmdebstrap-based sysroot builder and package pins (M02, not yet created)
└── deploy/           scp + ssh deploy and on-device test runner

third_party/          BUILD files for sysroot-provided C libraries
src/                  application code
planning/             milestone and issue tracking (not committed)
```

Build machinery lives under a single `bazel/` folder rather than scattered across the root. The exceptions are deliberate: the four files Bazel mandates at the root, and `third_party/`, which stays at the root by long-standing Bazel convention.

## Status

**M00 workspace bootstrap and hermetic cross toolchain — done.** `bazel test --config=host //...` and `bazel test --config=pi //...` are both green, including an `sh_test` that deploys and runs the cross-built binary on the device over ssh.

Settled so far:

- Bazel 9.2.0 via bazelisk, Clang 23.1.0, statically linked libc++ 23 at `-std=c++23`
- `toolchains_llvm` v1.9.0 pinned to LLVM 23.1.0, with an interim Chromium sysroot for C libraries only (`M02` replaces it with the Debian trixie snapshot)
- GStreamer for the media layer, with libcamera reached through `libcamerasrc` rather than linked

`ld.lld` from the LLVM 23.1.0 release binaries needs `libicui18n.so.70`, which Ubuntu 24.04 does not ship (it has ICU 74). Resolved: `bazel/toolchains/llvm_distribution.bzl` fetches the official LLVM tarball and the upstream ICU 70 tarball, merges the three ICU shared objects into the LLVM tree's `lib/` (where `ld.lld`'s own `RUNPATH` finds them), and self-checks `ld.lld --version` at fetch time.

Next: `M02`, the reproducible Debian trixie arm64 sysroot that replaces the interim one pinned here.
