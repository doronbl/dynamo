# shellcheck shell=bash disable=SC2154  # sourced by setup.sh after components/common.sh (config variables)
# soci: SOCI snapshotter in parallel pull mode, and nerdctl using it by default.
#
# The AMI wires SOCI into containerd but ships it with parallel pull turned
# off and nerdctl on the plain overlayfs snapshotter. In parallel pull mode
# SOCI downloads and unpacks the layers of every image concurrently (no SOCI
# index needed). Docker never uses SOCI: it has its own image store.
#
# provision/user-data.sh already moved the containerd and SOCI image stores
# onto the NVMe RAID0 (/scratch), on every boot, before containerd starts.

SOCI_CFG=/etc/soci-snapshotter-grpc/config.toml
NERDCTL_CFG=/etc/nerdctl/nerdctl.toml

desc() { echo "SOCI parallel pull + nerdctl default snapshotter soci (optional: container experiments)"; }
deps() { echo base; }
desired_version() { echo "parallel-pull"; }

parallel_enabled() {
  as_root awk '/^\[/ { s = ($0 == "[pull_modes.parallel_pull_unpack]") } s && /^enable *=/' "${SOCI_CFG}" \
    | grep -qE 'enable *= *true'
}

install() {
  [[ -f "${SOCI_CFG}" ]] || die "${SOCI_CFG} not found: this AMI has no SOCI snapshotter"
  local changed=0
  if ! parallel_enabled; then
    # Flips "enable" only inside [pull_modes.parallel_pull_unpack].
    as_root sed -i '/^\[pull_modes\.parallel_pull_unpack\]/,/^\[/ s/^enable = false/enable = true/' "${SOCI_CFG}"
    changed=1
  fi
  if ! grep -qs '^snapshotter = "soci"' "${NERDCTL_CFG}"; then
    as_root mkdir -p "$(dirname "${NERDCTL_CFG}")"
    echo 'snapshotter = "soci"' | as_root tee "${NERDCTL_CFG}" >/dev/null
  fi
  if ((changed)); then
    log "restarting soci-snapshotter and containerd"
    as_root systemctl restart soci-snapshotter containerd
  fi
  as_root systemctl enable --now soci-snapshotter containerd >/dev/null 2>&1 || true
}

verify() {
  parallel_enabled || die "parallel pull is not enabled in ${SOCI_CFG}"
  ok "parallel pull enabled: $(as_root grep -A6 '^\[pull_modes.parallel_pull_unpack\]' "${SOCI_CFG}" | grep -E 'max_concurrent_downloads_per_image|max_concurrent_unpacks_per_image' | tr -s ' ' | cut -d'#' -f1 | xargs)"
  ${NERDCTL} info 2>/dev/null | grep -q 'Storage Driver: soci' || die "nerdctl does not use the soci snapshotter"
  ok "nerdctl storage driver: soci"
  if mountpoint -q "${SCRATCH_DIR}"; then
    mountpoint -q /var/lib/soci-snapshotter-grpc || die "/var/lib/soci-snapshotter-grpc is not on ${SCRATCH_DIR} (see scratch-nvme.service)"
    ok "image stores on $(findmnt -no SOURCE /var/lib/soci-snapshotter-grpc)"
  fi
}
