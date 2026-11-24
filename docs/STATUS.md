# Work status (resume here)

Last update: 2026-11-24. The repository is being switched from **Dynamo in
containers** to a **direct install** (one venv with `ai-dynamo[vllm]`). This commit
is work in progress, pushed early because the instance is a Spot instance.

## Decisions made

- Dynamo and vLLM are installed directly: `pip install ai-dynamo[vllm]==1.6.1` in
  `/data/venvs/dynamo` (it pins vLLM 0.31.0, NIXL 1.4.1, the Run:ai streamer).
  No containers for serving; no separate native-vLLM component.
- User data (`provision/user-data.sh`) prepares storage only and does **not** clone
  the repository.
- Models are downloaded from Hugging Face on every new instance (`./setup.sh models`).
- `claude-code` stays as an optional component.
- `soci` and `bench/soci-pull.sh` stay as an optional experiment (not in
  `./setup.sh all`; serving pulls no images). Removed: `vllm` and `docker` components.
- Commits go straight to `main`. Keep `provision/launch-p5en.bat` simple.

## Done and tested on a p5en (container version, before the switch)

- `./setup.sh all` (base, soci, dynamo image, models), `status`, `verify`.
- `run/dynamo.sh up` with 8 workers serving `Qwen/Qwen3-30B-A3B`: healthy about 2.5 min
  after start (83 s on restart with the compile caches), file-based discovery, no
  etcd/NATS.
- `bench/smoke.sh`: models, Chat Completions, Responses API (streaming too), 3-turn
  chat, round-robin spread exactly 3 requests on each of 8 workers.
- `bench/kv-cache.py`: round-robin = no cache hits; `ROUTER_MODE=kv` = 25,200 cached
  tokens per follow-up, latency about 800 ms -> 20-50 ms, same worker.
- `bench/load.sh`: 8 workers, concurrency 64: about 5,970 output tokens/s.
- `bench/soci-pull.sh` (10 GB vllm-runtime image): Docker 283 s, overlayfs 95 s,
  SOCI parallel pull 73 s.
- ShellCheck (`-S warning`) clean on all scripts.

## In progress: the direct-install switch

Rewritten for the venv, **not yet tested end to end**:
- `components/dynamo.sh` (venv install + verify): **tested, passes** (`./setup.sh uv-python dynamo`,
  about 2 minutes: ai-dynamo 1.6.1, vLLM 0.31.0, torch 2.13.0+cu130, Run:ai streamer).
  `vllm download-kernels` does not exist in vLLM 0.31.0 (warning only; drop that step).
- `components/models.sh` (uses the venv's `hf`).
- `run/dynamo.sh` (plain processes: `setsid`, `numactl`, `CUDA_VISIBLE_DEVICES`,
  logs and PIDs in `/scratch/dynamo/{logs,pids}`, `VLLM_CACHE_ROOT` per worker).
- `bench/load.sh` and `bench/model-load.sh` (venv `vllm`).

## Next steps

1. `./setup.sh all` on the instance (base, uv-python, dynamo, models); fix what fails.
2. `./run/dynamo.sh up`, then `bench/smoke.sh`, `bench/kv-cache.py` (round-robin and
   `ROUTER_MODE=kv`), `bench/load.sh`, `./run/dynamo.sh down`.
3. `bench/model-load.sh` (default loader vs Run:ai streamer; not measured yet).
4. Update `README.md` and `docs/components.md`: they still describe the container
   version in places (Dynamo image, nerdctl, `vllm`/`docker` components).
5. Small fix: `components/uv-python.sh` verify prints "Python Python 3.12.16".
6. ShellCheck again, commit, push.
