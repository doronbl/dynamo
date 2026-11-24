#!/usr/bin/env bash
# Runs NVIDIA Dynamo on this instance as plain processes from the Dynamo venv
# (components/dynamo.sh): one frontend (OpenAI API + router) and WORKERS vLLM
# workers, one GPU each.
#
#   ./run/dynamo.sh up        start (waits until the API serves MODEL)
#   ./run/dynamo.sh down      stop all of them
#   ./run/dynamo.sh status    processes, worker health, served models
#   ./run/dynamo.sh logs <frontend|worker-N> [tail args, e.g. -f or -n 100]
#
# Settings (config/settings.env, or the environment for one run):
#   MODEL, WORKERS, ROUTER_MODE (round-robin | kv | ...), HTTP_PORT,
#   MAX_MODEL_LEN, WORKER_EXTRA_ARGS
#   for example:  ROUTER_MODE=kv WORKERS=4 ./run/dynamo.sh up
#
# How the pieces find each other on one host (no etcd, no NATS):
#   discovery   files in DYNAMO_STATE_DIR/discovery (DYN_DISCOVERY_BACKEND=file)
#   requests    TCP from the frontend to the workers
#   KV events   ZMQ, one port per worker (ROUTER_MODE=kv only)
# Each worker gets BASE + index for its system (health/metrics), NIXL and
# KV-event ports, CUDA_VISIBLE_DEVICES=<index>, and runs under numactl on its
# GPU's NUMA node. Logs and PIDs: DYNAMO_STATE_DIR/{logs,pids}.
source "$(dirname "$0")/../components/common.sh"

KV_DIR="${DYNAMO_STATE_DIR}/discovery"
LOG_DIR="${DYNAMO_STATE_DIR}/logs"
PID_DIR="${DYNAMO_STATE_DIR}/pids"
PY="${DYNAMO_VENV}/bin/python"

alive() { [[ -f "${PID_DIR}/$1.pid" ]] && kill -0 "$(<"${PID_DIR}/$1.pid")" 2>/dev/null; }
running() { local f; for f in "${PID_DIR}"/*.pid; do [[ -e "${f}" ]] || continue; alive "$(basename "${f}" .pid)" && basename "${f}" .pid; done; }

# start <name> <env assignments...> -- <command...>: runs it in its own session
# (so `down` can stop it and all its child processes), output to LOG_DIR/<name>.log.
start() {
  local name="$1"; shift
  local envs=()
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
  env "${envs[@]}" setsid "$@" >"${LOG_DIR}/${name}.log" 2>&1 </dev/null &
  echo $! >"${PID_DIR}/${name}.pid"
}

common_env() {
  COMMON=(DYN_DISCOVERY_BACKEND=file "DYN_FILE_KV=${KV_DIR}" "HF_HOME=${MODEL_CACHE_DIR}" HF_HUB_OFFLINE=1)
  [[ -n "${HF_TOKEN}" ]] && COMMON+=("HF_TOKEN=${HF_TOKEN}")
  return 0
}

start_frontend() {
  start frontend "${COMMON[@]}" -- \
    "${PY}" -m dynamo.frontend --http-port "${HTTP_PORT}" --router-mode "${ROUTER_MODE}"
  ok "frontend: http://localhost:${HTTP_PORT} (router ${ROUTER_MODE}), log ${LOG_DIR}/frontend.log"
}

start_worker() {
  local i="$1" node sys_port args=()
  node="$(gpu_numa_node "${i}")"
  sys_port=$((WORKER_SYSTEM_PORT_BASE + i))
  args=(--model "${MODEL}")
  [[ -n "${MAX_MODEL_LEN}" ]] && args+=(--max-model-len "${MAX_MODEL_LEN}")
  if [[ "${ROUTER_MODE}" == "kv" ]]; then
    args+=(--kv-events-config "{\"publisher\":\"zmq\",\"topic\":\"kv-events\",\"endpoint\":\"tcp://*:$((WORKER_KV_EVENTS_PORT_BASE + i))\",\"enable_kv_cache_events\":true}")
  fi
  # shellcheck disable=SC2206
  args+=(${WORKER_EXTRA_ARGS})
  mkdir -p "${SCRATCH_DIR}/vllm-cache/worker-${i}"
  start "worker-${i}" "${COMMON[@]}" \
    "CUDA_VISIBLE_DEVICES=${i}" \
    DYN_SYSTEM_ENABLED=true "DYN_SYSTEM_PORT=${sys_port}" 'DYN_SYSTEM_USE_ENDPOINT_HEALTH_STATUS=["generate"]' \
    "VLLM_NIXL_SIDE_CHANNEL_PORT=$((WORKER_NIXL_PORT_BASE + i))" \
    "VLLM_CACHE_ROOT=${SCRATCH_DIR}/vllm-cache/worker-${i}" -- \
    numactl --cpunodebind="${node}" --membind="${node}" "${PY}" -m dynamo.vllm "${args[@]}"
  ok "worker ${i}: GPU ${i}, NUMA node ${node}, health http://localhost:${sys_port}/health"
}

worker_healthy() { curl -sf -o /dev/null "http://localhost:$((WORKER_SYSTEM_PORT_BASE + $1))/health"; }

wait_ready() {
  local deadline=$((SECONDS + ${STARTUP_TIMEOUT:-1800})) i pending start=${SECONDS}
  log "waiting for ${WORKERS} worker(s) to load ${MODEL} (the first start compiles kernels, a few minutes)"
  while :; do
    pending=0
    for ((i = 0; i < WORKERS; i++)); do
      worker_healthy "${i}" && continue
      pending=$((pending + 1))
      alive "worker-${i}" || { tail -30 "${LOG_DIR}/worker-${i}.log" >&2; die "worker ${i} exited (log: ${LOG_DIR}/worker-${i}.log)"; }
    done
    alive frontend || { tail -30 "${LOG_DIR}/frontend.log" >&2; die "frontend exited (log: ${LOG_DIR}/frontend.log)"; }
    ((pending == 0)) && break
    ((SECONDS > deadline)) && die "timeout: ${pending} worker(s) not healthy"
    sleep 5
  done
  until curl -sf "http://localhost:${HTTP_PORT}/v1/models" | jq -e --arg m "${MODEL}" '.data[] | select(.id == $m)' >/dev/null 2>&1; do
    ((SECONDS > deadline)) && die "timeout: frontend does not list ${MODEL}"
    sleep 2
  done
  ok "all ${WORKERS} worker(s) healthy after $((SECONDS - start)) s"
  ok "frontend serves ${MODEL} on http://localhost:${HTTP_PORT}/v1 (chat/completions, completions, responses)"
}

stop_all() {
  local name pid t
  for name in $(running); do
    pid="$(<"${PID_DIR}/${name}.pid")"
    kill -TERM -- "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
  done
  for ((t = 0; t < 30; t++)); do [[ -z "$(running)" ]] && break; sleep 1; done
  for name in $(running); do kill -KILL -- "-$(<"${PID_DIR}/${name}.pid")" 2>/dev/null || true; done
}

cmd="${1:-status}"
case "${cmd}" in
  up)
    mkdir -p "${LOG_DIR}" "${PID_DIR}"
    [[ -z "$(running)" ]] || die "already running: $(running | xargs); run ./run/dynamo.sh down first"
    require_mount "${SCRATCH_DIR}"
    [[ -x "${PY}" ]] || die "no Dynamo venv at ${DYNAMO_VENV}: run ./setup.sh dynamo"
    gpus="$(nvidia-smi -L | wc -l)"
    ((WORKERS >= 1 && WORKERS <= gpus)) || die "WORKERS=${WORKERS}, but this instance has ${gpus} GPU(s)"
    [[ -d "${MODEL_CACHE_DIR}/hub/models--${MODEL//\//--}" ]] || die "${MODEL} not downloaded: MODELS=${MODEL} ./setup.sh models"
    rm -rf "${KV_DIR}"; mkdir -p "${KV_DIR}"; rm -f "${PID_DIR}"/*.pid
    common_env
    log "starting Dynamo ${DYNAMO_VERSION} (vLLM ${DYNAMO_VLLM_VERSION}): ${WORKERS} worker(s), model ${MODEL}, router ${ROUTER_MODE}"
    start_frontend
    for ((i = 0; i < WORKERS; i++)); do start_worker "${i}"; done
    wait_ready
    # What is running now, for the bench/ scripts (load_running in components/common.sh).
    printf 'MODEL=%q\nWORKERS=%q\nROUTER_MODE=%q\nHTTP_PORT=%q\n' "${MODEL}" "${WORKERS}" "${ROUTER_MODE}" "${HTTP_PORT}" >"${RUNNING_FILE}"
    ;;
  down)
    names="$(running | xargs)"
    stop_all
    rm -rf "${KV_DIR}" "${RUNNING_FILE}"; rm -f "${PID_DIR}"/*.pid
    ok "stopped${names:+: ${names}}"
    ;;
  status)
    load_running
    names="$(running | xargs)"; echo "processes: ${names:-none}"
    for ((i = 0; i < WORKERS; i++)); do
      if worker_healthy "${i}"; then echo "worker ${i}: healthy"; else echo "worker ${i}: not healthy"; fi
    done
    curl -sf "http://localhost:${HTTP_PORT}/v1/models" | jq -r '.data[].id' 2>/dev/null | sed 's/^/serving: /' || echo "frontend: not answering"
    ;;
  logs)
    shift; target="${1:?usage: ./run/dynamo.sh logs <frontend|worker-N> [tail args]}"; shift
    [[ $# -gt 0 ]] || set -- -n 50
    tail "$@" "${LOG_DIR}/${target}.log"
    ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
