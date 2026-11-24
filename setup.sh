#!/usr/bin/env bash
# Installs and checks the components in components/.
#
#   ./setup.sh all                 the default set, in dependency order
#   ./setup.sh soci dynamo         just these (their dependencies first)
#   ./setup.sh status              installed vs configured version of each
#   ./setup.sh verify [names...]   run the checks only, install nothing
#   ./setup.sh list                components and what they do
#
# Every component is safe to run again. Run as ec2-user; scripts use sudo
# where they need root.
source "$(dirname "$0")/components/common.sh"

# Default set: what serving Qwen3-30B-A3B with Dynamo on this instance needs.
ALL="base uv-python dynamo models"
# Optional: run them by name.
OPTIONAL="claude-code soci"

component_file() { echo "${REPO_ROOT}/components/$1.sh"; }

# Loads one component in a subshell and calls one of its functions.
call() {
  local name="$1" fn="$2" f
  f="$(component_file "${name}")"
  [[ -f "${f}" ]] || die "unknown component: ${name} (see ./setup.sh list)"
  # shellcheck disable=SC1090
  ( source "${f}"; "${fn}" )
}

# Appends the component to ORDER after its dependencies, each name once.
declare -A SEEN=()
ORDER=""
resolve() {
  local name="$1" dep
  [[ -n "${SEEN[${name}]:-}" ]] && return 0
  SEEN[${name}]=1
  for dep in $(call "${name}" deps); do resolve "${dep}"; done
  ORDER+="${name} "
}

install_one() {
  local name="$1" want
  want="$(call "${name}" desired_version)"
  log "${name}: $(call "${name}" desc)"
  call "${name}" install
  call "${name}" verify
  record_version "${name}" "${want}"
  ok "${name} ${want}"
}

cmd="${1:-help}"
case "${cmd}" in
  list)
    for n in ${ALL} ${OPTIONAL}; do printf '  %-12s %s\n' "${n}" "$(call "${n}" desc)"; done
    echo; echo "default set (./setup.sh all): ${ALL}"
    ;;
  status)
    printf '%-12s %-36s %-36s %s\n' COMPONENT INSTALLED CONFIGURED STATE
    for n in ${ALL} ${OPTIONAL}; do
      have="$(installed_version "${n}")"; want="$(call "${n}" desired_version)"
      if [[ -z "${have}" ]]; then state="not installed"
      elif [[ "${have}" == "${want}" ]]; then state="ok"
      else state="OUT OF DATE (run ./setup.sh ${n})"; fi
      printf '%-12s %-36s %-36s %s\n' "${n}" "${have:--}" "${want}" "${state}"
    done
    ;;
  verify)
    shift; names="${*:-${ALL}}"; rc=0
    for n in ${names}; do
      log "verify ${n}"
      if call "${n}" verify; then ok "${n}"; else warn "${n} failed"; rc=1; fi
    done
    exit "${rc}"
    ;;
  help|-h|--help)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    # shellcheck disable=SC2086
    [[ "${cmd}" == "all" ]] && set -- ${ALL}
    for n in "$@"; do resolve "${n}"; done
    log "install order: ${ORDER}"
    for n in ${ORDER}; do install_one "${n}"; done
    log "done"; "$0" status
    ;;
esac
