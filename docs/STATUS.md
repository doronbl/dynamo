# Status and measured results

Last update: 2026-11-25. Everything below was run on a p5en.48xlarge (8 x H200, AWS Deep
Learning AMI AL2023, driver 595) in us-east-2.

## Current state: complete and tested

Dynamo and vLLM are installed directly (no containers): one venv
`/data/venvs/dynamo` with `ai-dynamo[vllm]==1.6.1`, which pins vLLM 0.31.0, NIXL 1.4.1,
FlashInfer 0.7.0.post1 (plus its prebuilt kernels) and the Run:ai Model Streamer.

| Step | Result |
|---|---|
| `./setup.sh all` (base, uv-python, dynamo, models) | Passes; the venv install takes about 2 minutes (pip) plus about 1 minute for the FlashInfer prebuilt kernels |
| `./run/dynamo.sh up` (frontend + 8 workers, `Qwen/Qwen3-30B-A3B`) | All 8 healthy after 143 s on the first start, 76 s on a restart (compile caches) |
| `./run/dynamo.sh down` | Stops every process, nothing left running |
| `bench/smoke.sh` | Models, Chat Completions, Responses API (streaming too), 3-turn chat all correct; round-robin put exactly 3 of 24 requests on each worker |
| `bench/kv-cache.py`, `ROUTER_MODE=round-robin` | Every request on a different worker, 0 cached tokens, 0.76–1.38 s per request (25K-token prompt) |
| `bench/kv-cache.py`, `ROUTER_MODE=kv` | All on the worker holding the prefix, 25,200 cached tokens per follow-up, 17–46 ms instead of about 780 ms |
| `bench/load.sh` (input 1024, output 256) | Concurrency 1: 225 tok/s, TTFT p50 53 ms. Concurrency 64: **6,582 tok/s** total, 119 tok/s per user, TTFT p50 59 ms |
| `bench/model-load.sh` (57 GiB from the NVMe RAID0, cold page cache) | Default loader **15.3 s**, Run:ai streamer 23.3 s (concurrency 16). Server healthy after 85 s and 90 s |
| `bench/soci-pull.sh` (optional; 10 GB `vllm-runtime` image) | Docker 283 s, containerd overlayfs 95 s, **SOCI parallel pull 73 s** |
| ShellCheck (`-S warning`) | Clean on all scripts |

Not run on a fresh instance end to end: `provision/launch-p5en.bat` (Windows) and the
new minimal `provision/user-data.sh`. The user data keeps the storage steps of the
user data this instance booted with, unchanged apart from removing everything else.

## Lessons from testing (already handled in the scripts)

- FlashInfer compiles some kernels at runtime and needs `ninja` from the venv: every
  process gets the venv's `bin` first on `PATH`, and the prebuilt kernel packages
  (`flashinfer-cubin`, `flashinfer-jit-cache`) are installed to keep compilation short.
- `vllm download-kernels` does not exist in vLLM 0.31.0; the component installs the
  FlashInfer kernel packages directly.
- Hugging Face snapshot folders are symlinks into `blobs/`: pass the snapshot path,
  not a copy of the folder.
- From local NVMe the default loader beats the Run:ai streamer; Run:ai is meant for
  streaming from remote storage (S3), the next experiment.

## Ideas for next experiments

- Run:ai streamer from S3 (`--load-format runai_streamer` with an `s3://` model path).
- Disaggregated serving (separate prefill and decode workers, KV transfer with NIXL).
- Larger models with tensor or expert parallelism across GPUs.
- etcd/NATS discovery, to match a multi-node setup.
