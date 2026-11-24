#!/usr/bin/env bash
# Model load time from the local NVMe RAID0: vLLM's default loader vs the
# Run:ai Model Streamer. Starts a plain `vllm serve` from the Dynamo venv on
# one free GPU for each loader, with a cold page cache each time (the model
# files are dropped from RAM first), and reports vLLM's "Model loading took"
# line plus the time until the server is healthy.
#
#   ./bench/model-load.sh
#   GPU=7 LOADERS="runai_streamer" RUNAI_CONCURRENCY=32 ./bench/model-load.sh
source "$(dirname "$0")/../components/common.sh"

GPU="${GPU:-0}"
PORT="${PORT:-9100}"
LOADERS="${LOADERS:-auto runai_streamer}"
RUNAI_CONCURRENCY="${RUNAI_CONCURRENCY:-16}"
OUT="${REPO_ROOT}/bench/results/model-load-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${OUT}"

used="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i "${GPU}")"
((used < 2000)) || die "GPU ${GPU} is in use (${used} MiB); pick a free one with GPU=<n> or ./run/dynamo.sh down"
# Loaders read the files directly, so pass the snapshot folder of the model.
snap="$(ls -d "${MODEL_CACHE_DIR}/hub/models--${MODEL//\//--}/snapshots/"* 2>/dev/null | head -1)"
[[ -n "${snap}" ]] || die "${MODEL} not downloaded: ./setup.sh models"
node="$(gpu_numa_node "${GPU}")"
PID=""
trap '[[ -n "${PID}" ]] && kill -TERM -- "-${PID}" 2>/dev/null; true' EXIT

declare -A LOAD TOTAL
for loader in ${LOADERS}; do
  log "loader ${loader}: dropping the page cache, starting vllm serve on GPU ${GPU}"
  sync; echo 3 | as_root tee /proc/sys/vm/drop_caches >/dev/null
  extra=(--load-format "${loader}")
  [[ "${loader}" == runai_streamer ]] && extra+=(--model-loader-extra-config "{\"concurrency\": ${RUNAI_CONCURRENCY}}")
  start=${SECONDS}
  CUDA_VISIBLE_DEVICES="${GPU}" HF_HOME="${MODEL_CACHE_DIR}" HF_HUB_OFFLINE=1 \
    VLLM_CACHE_ROOT="${SCRATCH_DIR}/vllm-cache/worker-${GPU}" \
    setsid numactl --cpunodebind="${node}" --membind="${node}" \
    "${DYNAMO_VENV}/bin/vllm" serve "${snap}" --served-model-name "${MODEL}" --port "${PORT}" "${extra[@]}" \
    >"${OUT}/${loader}.log" 2>&1 </dev/null &
  PID=$!
  until curl -sf -o /dev/null "http://localhost:${PORT}/health"; do
    kill -0 "${PID}" 2>/dev/null || { tail -30 "${OUT}/${loader}.log"; die "vllm serve exited"; }
    sleep 2
  done
  TOTAL[${loader}]=$((SECONDS - start))
  LOAD[${loader}]="$(grep -oE 'Model loading took [0-9.]+ GiB memory and [0-9.]+ seconds' "${OUT}/${loader}.log" | tail -1)"
  ok "${loader}: ${LOAD[${loader}]:-no 'Model loading took' line}; healthy after ${TOTAL[${loader}]} s"
  kill -TERM -- "-${PID}" 2>/dev/null; while kill -0 "${PID}" 2>/dev/null; do sleep 1; done; PID=""
done

log "summary: ${MODEL} ($(du -shL "${snap}" | cut -f1)) from ${MODEL_CACHE_DIR}, logs in ${OUT}"
for l in ${LOADERS}; do printf '  %-16s %-60s server healthy after %s s\n' "${l}" "${LOAD[${l}]:-?}" "${TOTAL[${l}]}"; done
