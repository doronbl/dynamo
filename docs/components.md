# Components: what each one does and why

Short notes per building block. Versions are in `config/versions.env`, settings in
`config/settings.env`.

## Storage (provision/user-data.sh)

- **`/data`**: the EBS data volume. It holds your home folder (bind-mounted to
  `/home/ec2-user`), `/data/workspace`, uv's caches and optional venvs. It survives a
  stop/start and lives as long as the volume does (`DATA_VOLUME_DELETE` in the launcher).
- **`/scratch`**: the 8 instance-store NVMe drives of a p5en as one RAID0 XFS volume
  (about 28 TB). It is very fast and **blank after every stop/start or on a new
  instance**, so it holds only caches: container images, models, vLLM compile caches.
- **Why the image stores move:** containerd (`/var/lib/containerd`) and the SOCI
  snapshotter (`/var/lib/soci-snapshotter-grpc`) are bind-mounted onto `/scratch`, so
  a 10 GB image unpacks on NVMe instead of the 50 GB root volume.
  `scratch-nvme.service` does this on every boot, before containerd starts.

## base

The AWS Deep Learning AMI already has the NVIDIA driver, containerd, the SOCI
snapshotter, nerdctl, Docker and the NVIDIA container toolkit. `base` adds `numactl`
(NUMA pinning), `jq` and `git`, and checks the GPUs and both mounts.

## soci

The **SOCI snapshotter** is a containerd plugin that pulls images faster.
- **Parallel pull and unpack** (what this repository uses): downloads and unpacks the
  layers of any image concurrently. No preparation of the image is needed.
- **Lazy loading** (not used here): starts a container before its image is fully
  downloaded, but needs a SOCI index built for the image.

The AMI ships SOCI with parallel pull off and nerdctl on the plain `overlayfs`
snapshotter. The component turns parallel pull on and makes `soci` nerdctl's default.
Docker never uses SOCI: it has its own image store. Compare them with
`bench/soci-pull.sh`.

## dynamo

NVIDIA Dynamo is a serving layer above inference engines such as vLLM. It provides an
OpenAI-compatible **frontend** with a **router** (round-robin, KV-cache-aware and
others) and runs the engines as **workers**. Here it runs from NVIDIA's
`vllm-runtime` image, which contains Dynamo, vLLM, the CUDA libraries and the Run:ai
Model Streamer, so none of that is installed on the host.

The image is pinned **by digest**: a tag such as `1.6.1` could be re-pushed, a digest
cannot. The `verify` step runs the image and checks that its Dynamo and vLLM versions
match `config/versions.env`.

**Single host, no etcd/NATS:** the frontend finds workers through files in a shared
directory (`DYN_DISCOVERY_BACKEND=file`), requests use TCP, and KV events (for
`ROUTER_MODE=kv`) use ZMQ. Multi-node setups use etcd and NATS, or Kubernetes.

## models

Downloads the Hugging Face models listed in `MODELS` into `/scratch/hf`, **once per
instance**. Every worker mounts that directory as its Hugging Face cache and starts
with `HF_HUB_OFFLINE=1`, so the 8 workers never download 8 copies. The download runs
in the Dynamo image, which has the `hf` CLI.

## uv-python (optional)

[uv](https://docs.astral.sh/uv/) installs Python and Python packages quickly. Its
Python builds and package cache are on `/data`, on the same filesystem as the venvs,
so uv clones files from the cache instead of copying them.

## vllm (optional)

Native vLLM in `/data/venvs/vllm`, pinned to `VLLM_VERSION` and built against
`VLLM_CUDA_VARIANT`. It is **not needed to serve with Dynamo**. Use it for plain
`vllm serve` experiments or to try a newer vLLM than the Dynamo image has. The venv
brings its own CUDA libraries; the AMI's driver must support the CUDA version
(`nvidia-smi` shows the highest it supports).

## docker (optional)

Moves Docker's storage to `/data/docker` and registers the NVIDIA runtime. Only for
comparisons: the Dynamo scripts use nerdctl, which uses containerd and SOCI.

## claude-code (optional)

Installs Claude Code for ec2-user and configures it for Amazon Bedrock in the
instance's Region (from instance metadata). Model IDs are `CLAUDE_*` in
`config/settings.env`; the instance role needs Bedrock invoke permissions.

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
