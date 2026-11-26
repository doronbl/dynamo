# dynamo

Building blocks for LLM inference experiments with **NVIDIA Dynamo** on a single
**p5en.48xlarge Spot instance** (8 x H200, 16 EFA interfaces, 8 x 3.8 TB NVMe).

1. Launch the instance from Windows with `provision/launch-p5en.bat`. Its user data
   (`provision/user-data.sh`) only prepares storage.
2. Log in, clone this repository, run `./setup.sh all`.
3. Start Dynamo with `./run/dynamo.sh up` and use the scripts in `bench/`.

```
client ──HTTP :8000──► Dynamo frontend (OpenAI API, router: round-robin | kv)
                          │  TCP requests, file-based discovery (no etcd, no NATS)
          ┌───────────────┼───────────────┐ ... 8 workers
          ▼               ▼               ▼
     vLLM worker 0   vLLM worker 1   vLLM worker 7      one H200 each (process), pinned
     (process)       (process)       (process)          to the GPU's NUMA node; model
                                                        from /scratch/hf (NVMe RAID0)

Dynamo and vLLM are installed directly in one Python venv (/data/venvs/dynamo):
plain processes you can inspect, debug and change. No containers.
```

## Repository layout

| Path | Contents |
|---|---|
| `provision/launch-p5en.bat` | Launches the Spot instance (EFA interfaces, EBS volumes, Elastic IP). Your account values go in `provision/launch.local.bat` (git-ignored, see the `.example`) |
| `provision/user-data.sh` | Minimal cloud-init: `/data` EBS volume (home folder on it) and the NVMe RAID0 at `/scratch`, rebuilt on every boot |
| `config/versions.env` | **Every pinned version** (Dynamo, the vLLM it pins, CUDA build, Python) |
| `config/settings.env` | Everything else: paths, model, number of workers, router mode, ports |
| `config/local.env` | Your local overrides and secrets such as `HF_TOKEN` (git-ignored, see the `.example`) |
| `setup.sh` + `components/` | One small script per component, installed in dependency order |
| `run/dynamo.sh` | Starts and stops the Dynamo frontend and workers |
| `bench/` | Smoke test, load test, KV-cache and model-load benchmarks; optional SOCI pull experiment |
| `docs/components.md` | What each component does and why |
| `docs/STATUS.md` | Work status, measured results and next steps |

## Quick start

```bash
# on your Windows machine: copy provision\launch.local.bat.example to launch.local.bat, fill it in, then
provision\launch-p5en.bat

# on the instance, after "sudo cloud-init status --wait" (log out and in once if you logged in early)
cd /data/workspace && git clone https://github.com/doronbl/dynamo.git && cd dynamo
cp config/local.env.example config/local.env    # optional: add HF_TOKEN
./setup.sh all          # base, uv-python, dynamo, models  (pip install ~2 min + model download)
./run/dynamo.sh up      # frontend + 8 workers serving Qwen/Qwen3-30B-A3B
./bench/smoke.sh        # end-to-end checks
```

### Test a new instance

```bash
./setup.sh status                    # every default component "ok"
./setup.sh verify                    # GPUs, mounts, venv versions, model files
./run/dynamo.sh up && ./bench/smoke.sh
python3 bench/kv-cache.py            # round-robin: no cache reuse across workers
./bench/load.sh                      # throughput and latency at concurrency 1 and 64
./run/dynamo.sh down
ROUTER_MODE=kv ./run/dynamo.sh up && python3 bench/kv-cache.py   # kv: follow-ups hit the cache
./run/dynamo.sh down && ./bench/model-load.sh                    # needs a free GPU
```

Expected results from a p5en are in [`docs/STATUS.md`](docs/STATUS.md).

Then call the OpenAI-compatible API on `http://localhost:8000/v1` (Chat Completions,
Completions, Responses), for example:

```bash
curl -s localhost:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "Qwen/Qwen3-30B-A3B", "max_tokens": 200,
  "messages": [{"role": "user", "content": "Explain the KV cache in two sentences."}]}' | jq -r '.choices[0].message.content'
```

## What runs at boot and what runs later

**User data does only what must exist before you log in, or must be redone on every
boot.** Everything else is a component that you install when you choose.

| Item | Where | Why |
|---|---|---|
| `/data` EBS volume, home folder on `/data` | user data | Must be in place before the first login |
| NVMe RAID0 at `/scratch`, containerd and SOCI image stores on it | user data, as `scratch-nvme.service` (every boot) | Instance-store drives are blank after a stop/start, and the image stores (used only if you run containers) must move before containerd starts |
| Dynamo + vLLM venv, models, tools | `./setup.sh <component>` | Slow, versioned, and something you will want to re-run or change |
| SOCI parallel pull (optional) | `./setup.sh soci` | A config change plus a service restart: safe at any time, before the first container pull |
| Serving and benchmarks | `run/`, `bench/` | Runtime choices, not installation |

## Components

```
./setup.sh list                 # components and what they do
./setup.sh all                  # the default set: base uv-python dynamo models
./setup.sh claude-code soci     # optional ones, by name (dependencies first)
./setup.sh status               # installed vs configured version of each
./setup.sh verify               # checks only
```

| Component | Default | Installs | Depends on |
|---|---|---|---|
| `base` | yes | `numactl`, `jq`, `git`; checks GPUs, `/data`, `/scratch` | |
| `uv-python` | yes | uv and Python (caches on `/data`) | base |
| `dynamo` | yes | venv `/data/venvs/dynamo` with `ai-dynamo[vllm]`: Dynamo, the vLLM it pins, NIXL, FlashInfer, Run:ai streamer, PyTorch + CUDA wheels | uv-python |
| `models` | yes | Downloads `MODELS` from Hugging Face into `/scratch/hf` (once per instance, shared by all workers) | dynamo |
| `claude-code` | no | Claude Code using Amazon Bedrock in the instance's Region | base |
| `soci` | no | SOCI parallel pull for container images (experiment only: serving uses no containers) | base |

Every component script has the same shape: `desc`, `deps`, `desired_version`,
`install` (safe to run again) and `verify`. `setup.sh` records each installed version in
`/var/lib/dynamo-lab/`.

### Changing a version

All versions are in `config/versions.env`, and the scripts never hard-code one.
Dynamo pins its vLLM: `ai-dynamo[vllm]==1.6.1` requires `vllm==0.31.0`. To move to a new
Dynamo release, set `DYNAMO_VERSION`, look up the vLLM it requires on
[PyPI](https://pypi.org/project/ai-dynamo/) and set `DYNAMO_VLLM_VERSION`, then:

```bash
./setup.sh status     # dynamo: OUT OF DATE
./setup.sh dynamo     # installs into the venv and checks both versions
```

A wrong `DYNAMO_VLLM_VERSION` fails at install time (pip cannot satisfy both pins), and
`./setup.sh verify dynamo` checks the installed versions against the config.

## Serving: `run/dynamo.sh`

```bash
./run/dynamo.sh up                          # settings from config/settings.env
ROUTER_MODE=kv ./run/dynamo.sh up           # KV-cache-aware routing (workers publish KV events)
WORKERS=4 MODEL=Qwen/Qwen3-0.6B ./run/dynamo.sh up   # the model must be downloaded first
./run/dynamo.sh status
./run/dynamo.sh logs worker-3 -n 100      # or -f to follow
./run/dynamo.sh down
```

- One process per worker: `CUDA_VISIBLE_DEVICES=N`, run under
  `numactl --cpunodebind --membind` on the GPU's NUMA node, its own system port (health
  and metrics, `8081 + N`), NIXL port and, with `ROUTER_MODE=kv`, KV-event port.
- Each process runs in its own session, so `down` stops it together with the child
  processes vLLM starts. Logs: `/scratch/dynamo/logs/`, PIDs: `/scratch/dynamo/pids/`.
- Discovery uses files in `/scratch/dynamo/discovery` (`DYN_DISCOVERY_BACKEND=file`):
  no etcd and no NATS on a single host. Dynamo recommends etcd and NATS for
  multi-node setups.
- Workers start with `HF_HUB_OFFLINE=1`: they use the model that `./setup.sh models`
  downloaded and never download it themselves.
- Each worker keeps its vLLM compile cache in `/scratch/vllm-cache/worker-N`
  (`VLLM_CACHE_ROOT`), so a restart on the same instance skips most of the compilation.

## Benchmarks: `bench/`

| Script | Measures |
|---|---|
| `bench/smoke.sh` | Models list, Chat Completions, Responses API (streaming too), a 3-turn chat, and which worker served each request |
| `bench/load.sh` | `vllm bench serve` (from the venv): throughput, TTFT and TPOT at several concurrency levels |
| `bench/kv-cache.py` | Prefix-cache reuse: latency and serving worker for requests sharing a long prefix. Run it with `ROUTER_MODE=round-robin` and `kv` to compare |
| `bench/soci-pull.sh` | Optional experiment: container image pull time, overlayfs vs SOCI parallel pull (and Docker). Needs `./setup.sh soci` |
| `bench/model-load.sh` | Model load time from the NVMe RAID0: vLLM's default loader vs the Run:ai Model Streamer. Needs a free GPU |

Results are written to `bench/results/` (git-ignored).

## Notes

- **Spot:** an interruption ends the instance (`SPOT_INTERRUPT=terminate`). Everything
  is scripted, so a new instance is `launch-p5en.bat` + `./setup.sh all` again, with a
  fresh model download.
- **Hugging Face:** a `HF_TOKEN` in `config/local.env` raises the download rate limits.
- **Thinking output:** Qwen3 writes `<think>…</think>` before its answer. Send
  `"chat_template_kwargs": {"enable_thinking": false}` for short answers (the bench
  scripts do).
- **EFA and placement groups:** for one instance, EFA and a cluster placement group are
  not needed. The launcher keeps EFA (`EFA_COUNT`) for later multi-node experiments and
  has no placement group by default, which leaves more Spot capacity to choose from.
