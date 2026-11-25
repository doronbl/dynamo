# shellcheck shell=bash disable=SC2154  # sourced by setup.sh after components/common.sh (config variables)
# dynamo: NVIDIA Dynamo and the vLLM it pins, in one virtual environment.
#
# pip installs ai-dynamo[vllm]==DYNAMO_VERSION. The [vllm] extra pins vLLM
# (DYNAMO_VLLM_VERSION, with FlashInfer, OpenTelemetry and the Run:ai Model
# Streamer) and NIXL (KV-cache transfer library). PyTorch and the CUDA
# libraries come as pip wheels built for CUDA_VARIANT; the AMI provides only
# the NVIDIA driver. The venv also has `vllm serve`, `vllm bench` and `hf`.
#
# Processes, not containers: run/dynamo.sh starts `python -m dynamo.frontend`
# and one `python -m dynamo.vllm` per GPU from this venv. On one host they need
# no etcd and no NATS: file-based discovery in DYNAMO_STATE_DIR
# (DYN_DISCOVERY_BACKEND=file), requests over TCP, KV events over ZMQ.

desc() { echo "Dynamo ${DYNAMO_VERSION} + vLLM ${DYNAMO_VLLM_VERSION} (${CUDA_VARIANT}) in ${DYNAMO_VENV}"; }
deps() { echo uv-python; }
desired_version() { echo "${DYNAMO_VERSION}+vllm${DYNAMO_VLLM_VERSION}+${CUDA_VARIANT}"; }

install() {
  export PATH="${HOME}/.local/bin:${PATH}"
  # shellcheck disable=SC1091
  source /etc/profile.d/dynamo-lab-uv.sh
  as_root mkdir -p "$(dirname "${DYNAMO_VENV}")"
  as_root chown "$(id -u):$(id -g)" "$(dirname "${DYNAMO_VENV}")"
  [[ -x "${DYNAMO_VENV}/bin/python" ]] || uv venv --python "${PYTHON_VERSION}" "${DYNAMO_VENV}"
  # The extra index has vLLM wheels built for CUDA_VARIANT; --torch-backend
  # picks the matching PyTorch build. vllm is listed explicitly so a wrong
  # DYNAMO_VLLM_VERSION fails here, at install time.
  VIRTUAL_ENV="${DYNAMO_VENV}" retry 2 30 uv pip install \
    "ai-dynamo[vllm]==${DYNAMO_VERSION}" "vllm==${DYNAMO_VLLM_VERSION}" \
    --extra-index-url "https://wheels.vllm.ai/${DYNAMO_VLLM_VERSION}/${CUDA_VARIANT}" \
    --torch-backend="${CUDA_VARIANT}"
  # FlashInfer (attention and sampling kernels) compiles its kernels on first use
  # unless its prebuilt kernels are installed: flashinfer-cubin and
  # flashinfer-jit-cache, for the exact flashinfer-python version vLLM pulled in.
  local fi_version
  fi_version="$("${DYNAMO_VENV}/bin/python" -c 'import importlib.metadata as m; print(m.version("flashinfer-python"))')"
  VIRTUAL_ENV="${DYNAMO_VENV}" retry 2 30 uv pip install --no-deps \
    "flashinfer-cubin==${fi_version}" "flashinfer-jit-cache==${fi_version}+${CUDA_VARIANT}" \
    --extra-index-url https://flashinfer.ai/whl --extra-index-url "https://flashinfer.ai/whl/${CUDA_VARIANT}"
  mkdir -p "${DYNAMO_STATE_DIR}" 2>/dev/null || { as_root mkdir -p "${DYNAMO_STATE_DIR}"; as_root chown "$(id -u):$(id -g)" "${DYNAMO_STATE_DIR}"; }
}

verify() {
  [[ -x "${DYNAMO_VENV}/bin/python" ]] || die "no venv at ${DYNAMO_VENV}"
  local out dyn vllm torch cuda gpus
  out="$(CUDA_VISIBLE_DEVICES=0 "${DYNAMO_VENV}/bin/python" -c '
import importlib.metadata as m, torch
print(m.version("ai-dynamo"), m.version("vllm"), torch.__version__, torch.version.cuda, torch.cuda.device_count())' 2>/dev/null | tail -1)"
  read -r dyn vllm torch cuda gpus <<<"${out}"
  [[ "${dyn}" == "${DYNAMO_VERSION}" ]] || die "venv has ai-dynamo '${dyn}', config says ${DYNAMO_VERSION}"
  [[ "${vllm}" == "${DYNAMO_VLLM_VERSION}" ]] || die "venv has vLLM '${vllm}', config says ${DYNAMO_VLLM_VERSION} (must be the version ai-dynamo pins)"
  [[ "${gpus}" == "1" ]] || die "PyTorch sees ${gpus:-no} GPU(s) with CUDA_VISIBLE_DEVICES=0 (driver vs ${CUDA_VARIANT}?)"
  "${DYNAMO_VENV}/bin/python" -c 'import dynamo.frontend, dynamo.vllm, runai_model_streamer' 2>/dev/null \
    || die "cannot import dynamo.frontend, dynamo.vllm or runai_model_streamer"
  "${DYNAMO_VENV}/bin/python" -c 'import importlib.metadata as m; v = m.version("flashinfer-python"); assert m.version("flashinfer-cubin") == v and m.version("flashinfer-jit-cache").startswith(v + "+")' 2>/dev/null \
    || die "FlashInfer prebuilt kernels (flashinfer-cubin, flashinfer-jit-cache) missing or not matching flashinfer-python"
  ok "ai-dynamo ${dyn}, vLLM ${vllm}, torch ${torch} (CUDA ${cuda}), FlashInfer prebuilt kernels, Run:ai streamer, GPU visible"
  ok "use it: source ${DYNAMO_VENV}/bin/activate"
}
