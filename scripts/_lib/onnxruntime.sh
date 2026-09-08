#!/usr/bin/env bash

# StudioCast ONNX Runtime bootstrap, shared by the distro setup helpers.
# Expects: log(), require_cmd(), ORT_VERSION, ORT_ARCH, ORT_FLAVOR.

onnxruntime_package_name() {
  local arch="$1"
  local flavor="$2"
  local version="$3"

  if [[ "${flavor}" == "cpu" ]]; then
    printf 'onnxruntime-linux-%s-%s\n' "${arch}" "${version}"
  else
    printf 'onnxruntime-linux-%s-%s-%s\n' "${arch}" "${flavor}" "${version}"
  fi

}
# pkg-config only reads the directories it was compiled with. Debian keeps
# /usr/local/lib/pkgconfig on that list; Fedora does not ship any /usr/local
# entry at all, so the file has to go where pkg-config actually looks.
onnxruntime_pkgconfig_dir() {
  local path dir
  path="$(pkg-config --variable pc_path pkg-config 2>/dev/null || true)"

  local IFS=':'
  for dir in ${path}; do
    case "${dir}" in
      /usr/local/*) printf '%s\n' "${dir}"; return 0 ;;
    esac
  done

  for dir in ${path}; do
    if [[ -d "${dir}" ]]; then
      printf '%s\n' "${dir}"
      return 0
    fi
  done

  printf '/usr/local/lib/pkgconfig\n'
}

ensure_onnxruntime_available() {
  require_cmd curl
  require_cmd pkg-config
  require_cmd tar

  if pkg-config --exists onnxruntime; then
    log "onnxruntime already available via pkg-config; skipping ONNX Runtime install."
    return 0
  fi

  local ort_name
  ort_name="$(onnxruntime_package_name "${ORT_ARCH}" "${ORT_FLAVOR}" "${ORT_VERSION}")"
  local ort_tgz="${ort_name}.tgz"
  local ort_url="https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/${ort_tgz}"

  # Install location for the extracted upstream tarball.
  local ort_prefix="/opt/studiocast/onnxruntime/${ORT_VERSION}"
  local ort_root="${ort_prefix}/${ort_name}"

  ORT_TMPDIR="$(mktemp -d)"
  trap 'rm -rf "${ORT_TMPDIR:-}"' EXIT
  local tmpdir="${ORT_TMPDIR}"

  log "Installing ONNX Runtime ${ORT_VERSION} (${ORT_FLAVOR}) from: ${ort_url}"
  log "  -> ${ort_root}"
  if [[ "${ORT_FLAVOR}" == "gpu" ]]; then
    log "Note: ORT flavor 'gpu' requires a working NVIDIA driver/CUDA runtime stack at runtime."
  fi

  curl -fsSL "${ort_url}" -o "${tmpdir}/${ort_tgz}"

  sudo mkdir -p "${ort_prefix}"
  sudo tar -xzf "${tmpdir}/${ort_tgz}" -C "${ort_prefix}"

  if [[ ! -f "${ort_root}/include/onnxruntime_cxx_api.h" ]]; then
    echo "[setup] ERROR: ONNX Runtime headers not found at ${ort_root}/include/onnxruntime_cxx_api.h"
    exit 1
  fi

  local ort_libdir="${ort_root}/lib"
  if [[ -d "${ort_root}/lib64" ]]; then
    ort_libdir="${ort_root}/lib64"
  fi

  if [[ ! -e "${ort_libdir}/libonnxruntime.so" ]]; then
    local sofile
    sofile="$(ls -1 "${ort_libdir}"/libonnxruntime.so.* 2>/dev/null | head -n 1 || true)"
    if [[ -z "${sofile}" ]]; then
      echo "[setup] ERROR: libonnxruntime.so not found under ${ort_libdir}"
      exit 1
    fi
    sudo ln -sf "$(basename "${sofile}")" "${ort_libdir}/libonnxruntime.so"
  fi

  # Make the shared library discoverable for runtime linking.
  printf '%s\n' "${ort_libdir}" > "${tmpdir}/studiocast-onnxruntime.conf"
  sudo install -m 0644 "${tmpdir}/studiocast-onnxruntime.conf" \
    /etc/ld.so.conf.d/studiocast-onnxruntime.conf
  sudo ldconfig

  # Provide a pkg-config file so our CMake can pick it up via pkg_check_modules(onnxruntime).
  local ort_pcdir
  ort_pcdir="$(onnxruntime_pkgconfig_dir)"
  cat > "${tmpdir}/onnxruntime.pc" <<EOF
prefix=${ort_root}
exec_prefix=\${prefix}
libdir=${ort_libdir}
includedir=\${prefix}/include

Name: onnxruntime
Description: ONNX Runtime
Version: ${ORT_VERSION}
Libs: -L\${libdir} -lonnxruntime
Cflags: -I\${includedir}
EOF

  sudo mkdir -p "${ort_pcdir}"
  sudo install -m 0644 "${tmpdir}/onnxruntime.pc" "${ort_pcdir}/onnxruntime.pc"

  if ! pkg-config --exists onnxruntime; then
    echo "[setup] ERROR: wrote ${ort_pcdir}/onnxruntime.pc but pkg-config still cannot see it."
    echo "[setup] pkg-config search path: $(pkg-config --variable pc_path pkg-config)"
    exit 1
  fi

  log "ONNX Runtime installed; pkg-config reports: $(pkg-config --modversion onnxruntime)"
}
