#!/usr/bin/env bash
set -euo pipefail

# StudioCast Fedora-family setup helper (Fedora, Nobara, RHEL/CentOS-like).
#
# This script is invoked via ./scripts/setup.sh.
# It installs build/runtime prerequisites and configures v4l2loopback.

usage() {
  cat <<'EOF'
Usage:
  ./scripts/setup.sh [options]

Options:
  --deps                 Install build/runtime deps (Qt/CMake/Ninja/etc + Pulse utils).
  --v4l2loopback          Ensure v4l2loopback module is available (kernel module or akmod).
  --load-loopback         Load v4l2loopback now (creates /dev/videoN).
  --persist-loopback      Persist module load/options across reboot.

  --video-nr N            v4l2loopback device number (default: 10).
  --label TEXT            v4l2loopback card label (default: "StudioCast Camera").
  --exclusive-caps 0|1    v4l2loopback exclusive_caps (default: 1).

  --onnxruntime-version V ONNX Runtime version to install (default: 1.17.3).
  --onnxruntime-flavor    cpu|gpu (default: auto; gpu if nvidia-smi works, else cpu).
  --onnxruntime-arch A    x64|aarch64 (default: auto from uname -m).

  --build                 Configure + build StudioCast (dev convenience).
  --build-dir DIR         Build directory (default: ./cmake-build-debug).
  --build-type TYPE       CMake build type (default: Debug).

  --maxine                Run Maxine helper (see scripts/setup/maxine.sh).
  -y, --yes               Assume yes for dnf installs.
  -h, --help              Show help.

Examples:
  ./scripts/setup.sh --deps --v4l2loopback --load-loopback --persist-loopback
  ./scripts/setup.sh --deps --onnxruntime-flavor gpu
EOF
}

YES=0
DO_DEPS=0
DO_V4L2=0
DO_LOAD_LOOP=0
DO_PERSIST_LOOP=0
VIDEO_NR=10
LABEL="StudioCast Camera"
EXCLUSIVE_CAPS=1
DO_BUILD=0
BUILD_DIR="./cmake-build-debug"
BUILD_TYPE="Debug"
DO_MAXINE=0
MAXINE_ARGS=()
PARSE_MAXINE_ARGS=0

# ONNX Runtime install defaults.
# - Prefer GPU flavor if an NVIDIA driver is present.
# - Let users override via CLI flags.
ORT_VERSION="${ORT_VERSION:-1.17.3}"

if [[ -z "${ORT_ARCH:-}" ]]; then
  case "$(uname -m)" in
    x86_64|amd64) ORT_ARCH="x64" ;;
    aarch64|arm64) ORT_ARCH="aarch64" ;;
    *) ORT_ARCH="x64" ;;
  esac
fi

if [[ -z "${ORT_FLAVOR:-}" ]]; then
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    ORT_FLAVOR="gpu"
  else
    ORT_FLAVOR="cpu"
  fi
fi

log() { echo "[setup] $*"; }

if [[ "${STUDIOCAST_GUI_SUDO_STDIN:-0}" == "1" ]]; then
  sudo() {
    command sudo -S -p "${STUDIOCAST_GUI_SUDO_PROMPT:-[sudo] password for %u: }" "$@"
  }
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[setup] Missing required command: $1"; exit 1; }
}

_studiocast_lib="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../_lib" && pwd)"
# shellcheck source=../_lib/onnxruntime.sh
source "${_studiocast_lib}/onnxruntime.sh"
# shellcheck source=../_lib/v4l2loopback.sh
source "${_studiocast_lib}/v4l2loopback.sh"

DNF="dnf"
command -v dnf >/dev/null 2>&1 || DNF="yum"
DNF_ARGS=()

dnf_install() {
  sudo "${DNF}" install "${DNF_ARGS[@]}" "$@"
}

ensure_onnxruntime_fedora() {
  # Fedora ships onnxruntime-devel with a CMake config package, so CMake picks it
  # up with no /opt bootstrap. That build is CPU-only, so the gpu flavor still
  # needs the upstream tarball for the CUDA execution provider.
  if [[ "${ORT_FLAVOR}" == "cpu" ]]; then
    if dnf_install onnxruntime-devel; then
      log "ONNX Runtime installed from distro packages (CPU execution provider only)."
      return 0
    fi
    log "onnxruntime-devel unavailable from ${DNF}; falling back to the upstream tarball."
  elif rpm -q onnxruntime-devel >/dev/null 2>&1; then
    # find_package(onnxruntime CONFIG) resolves before pkg-config, so the RPM
    # would silently win and the downloaded CUDA build would never be linked.
    echo "[setup] ERROR: onnxruntime-devel is installed and ships a CMake config" >&2
    echo "[setup]        package, which takes priority over the upstream CUDA build." >&2
    echo "[setup]        Installing the gpu flavor now would download ~250MB that" >&2
    echo "[setup]        CMake then ignores." >&2
    echo "[setup]" >&2
    echo "[setup] Pick one:" >&2
    echo "[setup]   sudo ${DNF} remove onnxruntime-devel   # then re-run for the CUDA build" >&2
    echo "[setup]   ./scripts/setup.sh --deps --onnxruntime-flavor cpu   # keep the distro build" >&2
    exit 2
  fi

  ensure_onnxruntime_available

  if [[ "${ORT_FLAVOR}" == "gpu" ]]; then
    log "Note: the CUDA execution provider also needs a CUDA runtime + cuDNN,"
    log "      which Fedora does not package. See docs/open_source_video_models_install.md."
  fi
}

ensure_v4l2loopback_available() {
  log "Ensuring v4l2loopback availability..."

  # Nobara and some Fedora spins ship v4l2loopback in the stock kernel.
  if have_module; then
    log "v4l2loopback module is available for this kernel (no akmod needed)."
    dnf_install v4l2loopback v4l-utils || true
    return 0
  fi

  # akmod fallback: rebuilds the module for every installed kernel.
  # Provided by RPM Fusion free (Fedora) or Terra (Nobara).
  log "v4l2loopback not found in kernel modules; installing akmod fallback."
  dnf_install akmod-v4l2loopback v4l2loopback v4l-utils \
    "kernel-devel-$(uname -r)"

  if command -v akmods >/dev/null 2>&1; then
    sudo akmods --kernels "$(uname -r)" || true
  fi
  sudo depmod -a || true

  if have_module; then
    log "v4l2loopback is now available (akmod)."
  else
    echo "[setup] ERROR: v4l2loopback still not available after akmod install."
    echo "[setup] The akmod build may need a reboot into a matching kernel."
    echo "[setup] Check: akmods --force --kernels \$(uname -r) && sudo depmod -a"
    echo "[setup] If akmod-v4l2loopback was not found, enable RPM Fusion free:"
    echo "[setup]   sudo dnf install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-\$(rpm -E %fedora).noarch.rpm"
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  if [[ "$PARSE_MAXINE_ARGS" -eq 1 ]]; then
    MAXINE_ARGS+=("$1"); shift; continue
  fi

  case "$1" in
    --deps) DO_DEPS=1; shift ;;
    --v4l2loopback) DO_V4L2=1; DO_DEPS=1; shift ;;
    --load-loopback) DO_LOAD_LOOP=1; shift ;;
    --persist-loopback) DO_PERSIST_LOOP=1; shift ;;
    --video-nr) VIDEO_NR="${2:-}"; shift 2 ;;
    --label) LABEL="${2:-}"; shift 2 ;;
    --exclusive-caps) EXCLUSIVE_CAPS="${2:-}"; shift 2 ;;
    --onnxruntime-version) ORT_VERSION="${2:-}"; shift 2 ;;
    --onnxruntime-flavor) ORT_FLAVOR="${2:-}"; shift 2 ;;
    --onnxruntime-arch) ORT_ARCH="${2:-}"; shift 2 ;;
    --build) DO_BUILD=1; shift ;;
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    --build-type) BUILD_TYPE="${2:-}"; shift 2 ;;
    --maxine) DO_MAXINE=1; shift ;;
    -y|--yes) YES=1; shift ;;
    --) PARSE_MAXINE_ARGS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

if [[ "${ORT_FLAVOR}" != "cpu" && "${ORT_FLAVOR}" != "gpu" ]]; then
  echo "[setup] ERROR: --onnxruntime-flavor must be one of: cpu|gpu (got: '${ORT_FLAVOR}')" >&2
  exit 2
fi

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  log "Detected ${PRETTY_NAME:-unknown} (ID=${ID:-unknown}, VERSION_ID=${VERSION_ID:-unknown})."
fi

if [[ "$YES" -eq 1 ]]; then
  DNF_ARGS+=("-y")
fi

if [[ "$DO_DEPS" -eq 1 ]]; then
  log "Installing build/runtime dependencies..."
  dnf_install \
    gcc-c++ make cmake ninja-build pkgconf-pkg-config \
    git curl ca-certificates tar \
    qt6-qtbase-devel qt6-qtbase-gui qt6-qttools-devel \
    libxkbcommon-devel \
    pulseaudio-libs-devel pulseaudio-utils \
    clang clang-tools-extra \
    v4l-utils \
    blas-devel lapack-devel \
    sqlite-devel \
    libjpeg-turbo-devel libpng-devel \
    libyuv-devel

  # dlib is optional (Open Video Eye Contact landmarks) and is not packaged in
  # current Fedora repos. Install it yourself and pass -Ddlib_DIR=... if wanted.
  if ! ldconfig -p 2>/dev/null | grep -q 'libdlib\.so'; then
    log "Note: dlib not found. Open Video Eye Contact stays unavailable unless you build dlib manually."
  fi

  ensure_onnxruntime_fedora
fi

if [[ "$DO_V4L2" -eq 1 ]]; then
  ensure_v4l2loopback_available
fi

if [[ "$DO_LOAD_LOOP" -eq 1 ]]; then
  if ! have_module; then
    ensure_v4l2loopback_available
  fi
  load_v4l2loopback_now
fi

if [[ "$DO_PERSIST_LOOP" -eq 1 ]]; then
  if ! have_module; then
    ensure_v4l2loopback_available
  fi
  persist_v4l2loopback
fi

if [[ "$DO_BUILD" -eq 1 ]]; then
  log "Configuring + building into: $BUILD_DIR (type: $BUILD_TYPE)"
  cmake -S . -B "$BUILD_DIR" -G Ninja -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DSTUDIOCAST_ENABLE_OPEN_CUDA=ON \
    -DSTUDIOCAST_ENABLE_OPEN_AUDIO=ON
  cmake --build "$BUILD_DIR"
  log "Built. Useful commands:"
  echo "  $BUILD_DIR/studiocast --version"
  echo "  $BUILD_DIR/studiocastd"
  echo "  $BUILD_DIR/studiocastctl status"
  echo "  $BUILD_DIR/studiocast-maxine install-hints"
fi

if [[ "$DO_MAXINE" -eq 1 ]]; then
  log "Running Maxine setup helper..."
  ./scripts/setup/maxine.sh --build-dir "$BUILD_DIR" "${MAXINE_ARGS[@]}"
fi

log "Done."
