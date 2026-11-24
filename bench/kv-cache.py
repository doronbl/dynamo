#!/usr/bin/env python3
"""KV-cache reuse through the Dynamo router (standard library only).

Sends requests that share a long prefix (a ~DOC_TOKENS-token document) and
reports, per request: latency (max_tokens=1, so latency ~ time to first
token), the worker that served it (Dynamo nvext.worker_id) and the prompt
tokens served from the KV cache (usage.prompt_tokens_details.cached_tokens).

Run it under both router modes to see the difference:
    ./run/dynamo.sh up                     # ROUTER_MODE=round-robin (default)
    python3 bench/kv-cache.py
    ./run/dynamo.sh down && ROUTER_MODE=kv ./run/dynamo.sh up
    python3 bench/kv-cache.py

round-robin: each request goes to the next worker, so a follow-up usually lands
on a GPU that has not seen the prefix (miss, full prefill).
kv: the router sends it to the worker that already holds the prefix (hit).

Environment: API (default http://localhost:8000/v1), MODEL (default: the
first model the API lists), DOC_LINES (default 900, about 25K tokens).
"""
import json
import os
import random
import time
import urllib.request

API = os.environ.get("API", f"http://localhost:{os.environ.get('HTTP_PORT', '8000')}/v1")


def http(path, body=None):
    req = urllib.request.Request(API + path, data=json.dumps(body).encode() if body else None,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.load(r)


def make_doc(seed, n_lines):
    rng = random.Random(seed)
    cities = ["Lyon", "Osaka", "Denver", "Porto", "Tallinn", "Recife", "Perth", "Graz"]
    items = ["valves", "cables", "pumps", "sensors", "filters", "gears", "panels", "relays"]
    return "\n".join(f"Record {i:04d}: warehouse in {rng.choice(cities)} holds {rng.randint(10, 9999)} "
                     f"{rng.choice(items)}, last audited on day {rng.randint(1, 365)}." for i in range(n_lines))


def messages(doc, *turns):
    m = [{"role": "system", "content": "You answer questions about this inventory log:\n" + doc}]
    m += [{"role": "user" if i % 2 == 0 else "assistant", "content": t} for i, t in enumerate(turns)]
    return m


def ask(model, msgs):
    body = {"model": model, "messages": msgs, "max_tokens": 1, "temperature": 0,
            "chat_template_kwargs": {"enable_thinking": False},
            "nvext": {"extra_fields": ["worker_id"]}}
    t0 = time.perf_counter()
    r = http("/chat/completions", body)
    ms = (time.perf_counter() - t0) * 1000
    usage = r.get("usage") or {}
    cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens")
    w = ((r.get("nvext") or {}).get("worker_id") or {})
    worker = w.get("decode_worker_id") or w.get("prefill_worker_id")
    return ms, usage.get("prompt_tokens"), cached, worker


def main():
    model = os.environ.get("MODEL") or http("/models")["data"][0]["id"]
    n_lines = int(os.environ.get("DOC_LINES", "900"))
    doc1, doc2 = make_doc(int(time.time()), n_lines), make_doc(int(time.time()) + 1, n_lines)
    q1, q2, q3 = "How many records mention Osaka?", "What does Record 0042 say?", "And Porto?"
    scenarios = [
        ("1 cold: doc1 + Q1", messages(doc1, q1)),
        ("2 same doc1, new question", messages(doc1, q2)),
        ("3 follow-up turn on doc1", messages(doc1, q1, "About 110.", q3)),
        ("4 exact repeat of 1", messages(doc1, q1)),
        ("5 repeat of 1 again", messages(doc1, q1)),
        ("6 control: new doc2 + Q1", messages(doc2, q1)),
    ]
    ask(model, [{"role": "user", "content": "hi"}])  # warm-up
    print(f"model {model}, document of {n_lines} lines\n")
    print(f"{'scenario':30} {'prompt':>7} {'cached':>7} {'latency ms':>11}  worker")
    for name, msgs in scenarios:
        ms, prompt, cached, worker = ask(model, msgs)
        print(f"{name:30} {prompt or '-':>7} {cached if cached is not None else '-':>7} {ms:11.0f}  {worker}")
    print("\ncached '-' means the API did not report cached tokens; compare the latency instead.")


if __name__ == "__main__":
    main()
