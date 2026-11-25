# Components: what each one does and why

Short notes per building block, in install order. Versions are in
`config/versions.env`, settings in `config/settings.env`.

## Storage (provision/user-data.sh)

- **`/data`**: the EBS data volume. It holds your home folder (bind-mounted to
  `/home/ec2-user`), `/data/workspace`, uv's caches and optional venvs. It survives a
  stop/start and lives as long as the volume does (`DATA_VOLUME_DELETE` in the launcher).
- **`/scratch`**: the 8 instance-store NVMe drives of a p5en as one RAID0 XFS volume
  (about 28 TB). It is very fast and **blank after every stop/start or on a new
  instance**, so it holds only caches: container images, models, vLLM compile caches.
- **Why the image stores move:** containerd (`/var/lib/containerd`) and the SOCI
  snapshotter (`/var/lib/soci-snapshotter-grpc`) are bind-mounted onto `/scratch`, so
  a 10 GB image unpacks on NVMe instead of the 50 GB root volume (only relevant when
  you run containers, for example the SOCI experiment).
  `scratch-nvme.service` does this on every boot, before containerd starts.

## base

The AWS Deep Learning AMI already has the NVIDIA driver (and containerd, SOCI,
nerdctl and Docker for container work). `base` adds `numactl` (NUMA pinning of the
workers), `jq` and `git`, and checks the GPUs and both mounts.

## uv-python

[uv](https://docs.astral.sh/uv/) installs Python and Python packages quickly. Its
Python builds and package cache are on `/data`, on the same filesystem as the venvs,
so uv clones files from the cache instead of copying them.

## dynamo

NVIDIA Dynamo is a serving layer above inference engines such as vLLM. It provides an
OpenAI-compatible **frontend** with a **router** (round-robin, KV-cache-aware and
others) and runs the engines as **workers**.

Here it is installed directly with pip into one virtual environment,
`/data/venvs/dynamo`: `ai-dynamo[vllm]==DYNAMO_VERSION`. The `[vllm]` extra pins the
vLLM release Dynamo was tested with (1.6.1 -> vLLM 0.31.0) and brings
NIXL (the library that moves KV cache between workers), FlashInfer (attention
kernels) and the Run:ai Model Streamer. PyTorch and the CUDA libraries come as pip
wheels built for `CUDA_VARIANT` (`cu130`); the AMI only provides the NVIDIA driver,
which must support that CUDA version (`nvidia-smi` shows the highest it supports).
The same venv has `vllm serve`, `vllm bench serve` and the `hf` CLI.

Because it is a plain venv, you can read and change the code
(`/data/venvs/dynamo/lib/python3.12/site-packages/dynamo/`, `.../vllm/`), run any piece
by hand (`source /data/venvs/dynamo/bin/activate; python -m dynamo.vllm --help`) and
attach a debugger or profiler to the running processes.

**Single host, no etcd/NATS:** the frontend finds workers through files in a shared
directory (`DYN_DISCOVERY_BACKEND=file`), requests use TCP, and KV events (for
`ROUTER_MODE=kv`) use ZMQ. Multi-node setups use etcd and NATS, or Kubernetes.

## models

Downloads the Hugging Face models listed in `MODELS` into `/scratch/hf`, **once per
instance**, with the venv's `hf` CLI. Every worker uses that directory as its Hugging
Face cache (`HF_HOME`) and starts with `HF_HUB_OFFLINE=1`, so the 8 workers never
download 8 copies.

## claude-code (optional)

Installs Claude Code for ec2-user and configures it for Amazon Bedrock in the
instance's Region (from instance metadata). Model IDs are `CLAUDE_*` in
`config/settings.env`; the instance role needs Bedrock invoke permissions.

## soci (optional)

The **SOCI snapshotter** is a containerd plugin that pulls **container images**
faster. Serving here uses no containers, so it is only an experiment
(`bench/soci-pull.sh`); it matters for container-based setups such as EKS, where every
new node pulls a large image.
- **Parallel pull and unpack** (what the component enables): downloads and unpacks the
  layers of any image concurrently, no preparation of the image needed. Measured on a
  p5en for the 10 GB Dynamo image: Docker 283 s, containerd overlayfs 95 s, SOCI 73 s.
- **Lazy loading** (not used): starts a container before its image is fully
  downloaded, but needs a SOCI index built for the image.

The AMI ships SOCI with parallel pull off and nerdctl on the plain `overlayfs`
snapshotter; the component turns parallel pull on and makes `soci` nerdctl's default.
Docker never uses SOCI: it has its own image store.

## run/dynamo.sh: how one request flows

1. The client sends `POST /v1/chat/completions` (or `/v1/responses`) to the frontend
   on port 8000.
2. The frontend applies the chat template, tokenizes the prompt and asks the router
   for a worker. **round-robin** takes the next worker in turn; **kv** picks the
   worker that already holds the longest matching prefix in its KV cache (from the KV
   events the workers publish), weighed against its current load.
3. The worker (one vLLM engine on one GPU) processes the prompt (prefill), then
   generates tokens one by one (decode) and streams them back over TCP.
4. The frontend turns tokens into text and streams them to the client.

The API is stateless: for a multi-turn chat the client sends the whole history each
time. With round-robin, a follow-up usually lands on another GPU and recomputes the
history; with kv it returns to the GPU that already holds it. `bench/kv-cache.py`
shows the difference.
