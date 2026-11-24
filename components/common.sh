#!/usr/bin/env bash
# Shared helpers, sourced by setup.sh, every component, run/ and bench/ script.
# Loads config/versions.env, config/settings.env and the optional, git-ignored
# config/local.env (local overrides such as HF_TOKEN).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "${REPO_ROOT}/config/versions.env"
if [[ -f "${REPO_ROOT}/config/local.env" ]]; then
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/config/local.env"
fi
# shellcheck source=../config/settings.env
source "${REPO_ROOT}/config/settings.env"

# run/dynamo.sh up records what it started (MODEL, WORKERS, ROUTER_MODE,
# HTTP_PORT) here; bench/ scripts call load_running to test what is running.
RUNNING_FILE="${DYNAMO_STATE_DIR}/running.env"
# shellcheck disable=SC1090
load_running() { [[ -f "${RUNNING_FILE}" ]] && source "${RUNNING_FILE}"; return 0; }

# Installed versions are recorded here, one file per component.
STATE_DIR="${STATE_DIR:-/var/lib/dynamo-lab}"

ts() { date -u +%H:%M:%S; }
log() { printf '\n\033[1;34m==> [%s] %s\033[0m\n' "$(ts)" "$*" >&2; }
ok() { printf '\033[1;32m  ok\033[0m  %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarn\033[0m  %s\n' "$*" >&2; }
die() { printf '\033[1;31mfail\033[0m  %s\n' "$*" >&2; exit 1; }

# Runs a command as root (scripts run as ec2-user and use sudo where needed).
as_root() { if [[ ${EUID} -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

# Retries a command: retry <attempts> <delay-seconds> <command...>
retry() {
  local n="$1" delay="$2" i; shift 2
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    ((i < n)) && { warn "attempt ${i}/${n} failed: $*; retrying in ${delay}s"; sleep "${delay}"; }
  done
  return 1
}

require_mount() {
  mountpoint -q "$1" || die "$1 is not mounted (provision/user-data.sh sets it up; see /var/log/user-data.log)"
}

record_version() { as_root mkdir -p "${STATE_DIR}"; echo "$2" | as_root tee "${STATE_DIR}/$1" >/dev/null; }
installed_version() { cat "${STATE_DIR}/$1" 2>/dev/null || true; }

# GPU index -> NUMA node and that node's CPU list (for pinning each worker).
gpu_numa_node() {
  local bus
  bus="$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader -i "$1" | tr 'A-Z' 'a-z')"
  cat "/sys/bus/pci/devices/${bus:4}/numa_node"
}
numa_cpus() { cat "/sys/devices/system/node/node$1/cpulist"; }
