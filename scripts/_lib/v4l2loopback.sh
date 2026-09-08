#!/usr/bin/env bash

# StudioCast v4l2loopback module handling, shared by the distro setup helpers.
# Expects: log(), require_cmd(), VIDEO_NR, LABEL, EXCLUSIVE_CAPS.

have_module() {
  # Does the module exist for this running kernel?
  modinfo v4l2loopback >/dev/null 2>&1
}

load_v4l2loopback_now() {
  require_cmd modprobe
  log "Loading v4l2loopback now (video_nr=${VIDEO_NR}, label=${LABEL}, exclusive_caps=${EXCLUSIVE_CAPS})..."
  sudo modprobe -r v4l2loopback 2>/dev/null || true
  sudo modprobe v4l2loopback "video_nr=${VIDEO_NR}" "card_label=${LABEL}" "exclusive_caps=${EXCLUSIVE_CAPS}"
  log "Loaded. Devices:"
  if command -v v4l2-ctl >/dev/null 2>&1; then
    v4l2-ctl --list-devices || true
  fi
  ls -l "/dev/video${VIDEO_NR}" 2>/dev/null || true
}

persist_v4l2loopback() {
  log "Persisting v4l2loopback across reboot..."

  # Staged through a temp dir on purpose: `sudo tee` would eat stdin, which is
  # the password channel when the GUI installer runs us with sudo -S.
  local tmpdir
  tmpdir="$(mktemp -d)"

  printf 'v4l2loopback\n' > "${tmpdir}/modules-load.conf"
  sudo install -m 0644 "${tmpdir}/modules-load.conf" \
    /etc/modules-load.d/v4l2loopback.conf

  cat > "${tmpdir}/modprobe.conf" <<EOF
# StudioCast v4l2loopback options
options v4l2loopback video_nr=${VIDEO_NR} card_label="${LABEL}" exclusive_caps=${EXCLUSIVE_CAPS}
EOF
  sudo install -m 0644 "${tmpdir}/modprobe.conf" \
    /etc/modprobe.d/studiocast-v4l2loopback.conf

  rm -rf "${tmpdir}"

  log "Wrote:"
  log "  /etc/modules-load.d/v4l2loopback.conf"
  log "  /etc/modprobe.d/studiocast-v4l2loopback.conf"
  log "You can verify after reboot with:"
  log "  modinfo v4l2loopback | head"
  log "  ls -l /dev/video${VIDEO_NR}"
}
