# shellcheck shell=bash disable=SC2154  # sourced by setup.sh after components/common.sh (config variables)
# base: OS packages and a sanity check of what provision/user-data.sh set up.
#
# The AMI (AWS Deep Learning AMI, AL2023) already has the NVIDIA driver,
# containerd, the SOCI snapshotter, nerdctl, Docker and the NVIDIA container
# toolkit. This adds the few tools the other scripts use.

PACKAGES="numactl jq git"

desc() { echo "OS packages (${PACKAGES}) and checks of GPUs and storage"; }
deps() { :; }
desired_version() { echo "${PACKAGES// /,}"; }

install() {
  # shellcheck disable=SC2086
  retry 5 15 as_root dnf install -y -q ${PACKAGES}
}

verify() {
  local gpus
  gpus="$(nvidia-smi -L | wc -l)"
  [[ "${gpus}" -ge 1 ]] || die "nvidia-smi sees no GPUs"
  ok "${gpus} GPU(s): $(nvidia-smi --query-gpu=name --format=csv,noheader -i 0), driver $(nvidia-smi --query-gpu=driver_version --format=csv,noheader -i 0)"
  require_mount "${DATA_DIR}"
  require_mount "${SCRATCH_DIR}"
  ok "${DATA_DIR}: $(df -h --output=size,avail "${DATA_DIR}" | tail -1 | xargs) | ${SCRATCH_DIR}: $(df -h --output=size,avail "${SCRATCH_DIR}" | tail -1 | xargs) (size, free)"
  # shellcheck disable=SC2086
  rpm -q ${PACKAGES} >/dev/null || die "missing packages: ${PACKAGES}"
}
