#!/usr/bin/env bash
# Load test of the running Dynamo frontend with `vllm bench serve` from the
# Dynamo venv.
#
#   ./bench/load.sh                       defaults below
#   CONCURRENCY="1 16 64" ./bench/load.sh
#
# Random prompts of INPUT_LEN tokens, exactly OUTPUT_LEN output tokens each.
# Per concurrency level: NUM_PROMPTS = max(20, 5 x concurrency).
# Results (JSON per level) go to bench/results/load-<time>/.
source "$(dirname "$0")/../components/common.sh"
load_running   # MODEL, WORKERS, ROUTER_MODE, HTTP_PORT of the running Dynamo

CONCURRENCY="${CONCURRENCY:-1 64}"
INPUT_LEN="${INPUT_LEN:-1024}"
OUTPUT_LEN="${OUTPUT_LEN:-256}"
OUT="${REPO_ROOT}/bench/results/load-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${OUT}"

curl -sf "http://localhost:${HTTP_PORT}/v1/models" >/dev/null || die "frontend not answering: ./run/dynamo.sh up"
log "load test: ${MODEL}, router ${ROUTER_MODE}, ${WORKERS} worker(s), input ${INPUT_LEN}, output ${OUTPUT_LEN}, concurrency ${CONCURRENCY}"

for c in ${CONCURRENCY}; do
  n=$((c * 5 > 20 ? c * 5 : 20))
  log "concurrency ${c} (${n} prompts)"
  HF_HOME="${MODEL_CACHE_DIR}" HF_HUB_OFFLINE=1 "${DYNAMO_VENV}/bin/vllm" bench serve --backend openai --base-url "http://localhost:${HTTP_PORT}" --endpoint /v1/completions \
      --model "${MODEL}" --dataset-name random --random-input-len "${INPUT_LEN}" --random-output-len "${OUTPUT_LEN}" \
      --ignore-eos --num-prompts "${n}" --max-concurrency "${c}" --num-warmups 2 --seed 42 \
      --percentile-metrics ttft,tpot,itl --metric-percentiles 50,99 \
      --save-result --result-dir "${OUT}" --result-filename "c${c}.json" >"${OUT}/c${c}.log" 2>&1 \
    || { tail -20 "${OUT}/c${c}.log"; die "benchmark failed at concurrency ${c}"; }
done

log "results (${OUT})"
printf '%-6s %6s %12s %10s %10s %10s %10s %12s\n' conc ok "out tok/s" "TTFT p50" "TTFT p99" "TPOT p50" "TPOT p99" "tok/s/user"
for c in ${CONCURRENCY}; do
  jq -r --arg c "${c}" '[$c, .completed, (.output_throughput|floor), (.median_ttft_ms*10|floor/10), (.p99_ttft_ms*10|floor/10), (.median_tpot_ms*100|floor/100), (.p99_tpot_ms*100|floor/100), (1000/.median_tpot_ms|floor)] | @tsv' "${OUT}/c${c}.json" \
    | awk -F'\t' '{printf "%-6s %6s %12s %10s %10s %10s %10s %12s\n", $1,$2,$3,$4,$5,$6,$7,$8}'
done
echo "(TTFT and TPOT in ms)"
