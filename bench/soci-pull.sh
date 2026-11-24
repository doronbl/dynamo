#!/usr/bin/env bash
# Image pull time (optional SOCI experiment; serving does not use containers):
# containerd's plain overlayfs snapshotter vs SOCI parallel
# pull (and Docker, when it is running). Removes SOCI_TEST_IMAGE first for each
# run. Needs ./setup.sh soci. No containers may be running. The image is pulled
# with SOCI last.
#
#   ./bench/soci-pull.sh                 overlayfs, then soci
#   MODES="soci" ./bench/soci-pull.sh    one mode only
source "$(dirname "$0")/../components/common.sh"

IMAGE="${IMAGE:-${SOCI_TEST_IMAGE}}"
MODES="${MODES:-overlayfs soci}"
[[ -z "$(${NERDCTL} ps -q 2>/dev/null)" ]] || die "containers are running; stop them first"

remove_everywhere() {
  local s
  for s in overlayfs soci; do ${NERDCTL} --snapshotter "${s}" rmi -f "${IMAGE}" >/dev/null 2>&1 || true; done
}

declare -A RESULT
if systemctl is-active --quiet docker; then
  log "docker pull (Docker's own image store, no SOCI)"
  as_root docker rmi -f "${IMAGE}" >/dev/null 2>&1 || true
  start=${SECONDS}; as_root docker pull -q "${IMAGE}" >/dev/null; RESULT[docker]=$((SECONDS - start))
  as_root docker rmi -f "${IMAGE}" >/dev/null 2>&1 || true
  ok "docker: ${RESULT[docker]} s"
fi
for mode in ${MODES}; do
  log "nerdctl pull with the ${mode} snapshotter"
  remove_everywhere
  start=${SECONDS}; ${NERDCTL} --snapshotter "${mode}" pull --quiet "${IMAGE}" >/dev/null; RESULT[${mode}]=$((SECONDS - start))
  ok "${mode}: ${RESULT[${mode}]} s"
done
[[ "${MODES##* }" == "soci" ]] || { log "restoring the image with SOCI"; remove_everywhere; ${NERDCTL} pull --quiet "${IMAGE}" >/dev/null; }

log "summary: ${IMAGE}"
for k in "${!RESULT[@]}"; do printf '  %-10s %4s s\n' "${k}" "${RESULT[${k}]}"; done
