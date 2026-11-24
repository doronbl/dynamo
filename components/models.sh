# shellcheck shell=bash disable=SC2154  # sourced by setup.sh after components/common.sh (config variables)
# models: download MODELS from Hugging Face into MODEL_CACHE_DIR on the NVMe RAID0.
#
# Every new instance downloads again (the RAID0 is instance storage). The
# workers use this directory as their HF_HOME and start with HF_HUB_OFFLINE=1,
# so the model is downloaded once per instance, not once per worker.
# Uses the `hf` CLI from the Dynamo venv. Set HF_TOKEN (config/local.env) for
# higher Hugging Face rate limits.

desc() { echo "download ${MODELS} into ${MODEL_CACHE_DIR}"; }
deps() { echo dynamo; }
desired_version() { echo "${MODELS// /,}"; }

snapshot_dir() { ls -d "${MODEL_CACHE_DIR}/hub/models--${1//\//--}/snapshots/"* 2>/dev/null | head -1; }

install() {
  require_mount "${SCRATCH_DIR}"
  mkdir -p "${MODEL_CACHE_DIR}" 2>/dev/null || { as_root mkdir -p "${MODEL_CACHE_DIR}"; as_root chown "$(id -u):$(id -g)" "${MODEL_CACHE_DIR}"; }
  [[ -n "${HF_TOKEN}" ]] || warn "HF_TOKEN not set: anonymous downloads have lower rate limits"
  local m start
  for m in ${MODELS}; do
    start=${SECONDS}
    log "downloading ${m}"
    HF_HOME="${MODEL_CACHE_DIR}" HF_TOKEN="${HF_TOKEN}" retry 3 30 "${DYNAMO_VENV}/bin/hf" download "${m}" >/dev/null
    ok "${m}: $(du -shL "$(snapshot_dir "${m}")" | cut -f1) in $((SECONDS - start)) s"
  done
}

verify() {
  local m dir
  for m in ${MODELS}; do
    dir="$(snapshot_dir "${m}")"
    [[ -n "${dir}" && -f "${dir}/config.json" ]] || die "${m} not in ${MODEL_CACHE_DIR}"
    ls "${dir}"/*.safetensors >/dev/null 2>&1 || die "${m}: no .safetensors files in ${dir}"
    ok "${m}: $(ls "${dir}"/*.safetensors | wc -l) safetensors files, $(du -shL "${dir}" | cut -f1)"
  done
}
