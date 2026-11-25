# shellcheck shell=bash disable=SC2154  # sourced by setup.sh after components/common.sh (config variables)
# uv-python: uv (Python package manager) and Python PYTHON_VERSION for ec2-user.
#
# uv's Python builds and package cache live on /data, so the cache and the
# virtual environments are on the same filesystem (uv clones files from the
# cache instead of copying them).

ENV_FILE=/etc/profile.d/dynamo-lab-uv.sh

desc() { echo "uv + Python ${PYTHON_VERSION}"; }
deps() { echo base; }
desired_version() { echo "python-${PYTHON_VERSION}"; }

install() {
  require_mount "${DATA_DIR}"
  as_root tee "${ENV_FILE}" >/dev/null <<EOF
export UV_PYTHON_INSTALL_DIR=${DATA_DIR}/uv/python
export UV_CACHE_DIR=${DATA_DIR}/uv/cache
EOF
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  as_root mkdir -p "${UV_PYTHON_INSTALL_DIR}" "${UV_CACHE_DIR}"
  as_root chown -R "$(id -u):$(id -g)" "${DATA_DIR}/uv"
  export PATH="${HOME}/.local/bin:${PATH}"
  command -v uv >/dev/null || retry 3 10 bash -c 'curl -fsSL https://astral.sh/uv/install.sh | sh'
  uv self update >/dev/null 2>&1 || warn "uv self update failed"
  uv python install "${PYTHON_VERSION}" --default
}

verify() {
  export PATH="${HOME}/.local/bin:${PATH}"
  command -v uv >/dev/null || die "uv not on PATH"
  ok "$(uv --version), $("$(uv python find "${PYTHON_VERSION}")" -V 2>&1)"
}
