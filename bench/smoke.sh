#!/usr/bin/env bash
# Quick end-to-end check of a running Dynamo (./run/dynamo.sh up):
#   1. the model list
#   2. Chat Completions, non-streaming
#   3. Responses API, non-streaming, and streaming (event types)
#   4. a 3-turn chat (the client resends the history each turn)
#   5. which worker served each of 3 x WORKERS requests (round-robin spread)
# Qwen3 thinks first: <think>...</think> is part of the answer text, so the
# requests switch thinking off (enable_thinking=false) to get short answers.
source "$(dirname "$0")/../components/common.sh"
load_running   # MODEL, WORKERS, ROUTER_MODE, HTTP_PORT of the running Dynamo
API="http://localhost:${HTTP_PORT}/v1"
NO_THINK='"chat_template_kwargs": {"enable_thinking": false}'

post() { curl -sS --fail-with-body "${API}/$1" -H 'Content-Type: application/json' -d "$2"; }

log "1. models"
curl -sS --fail "${API}/models" | jq -r '.data[].id'

log "2. chat completions"
post chat/completions "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 17*23? Reply with the number only.\"}],\"max_tokens\":32,\"temperature\":0,${NO_THINK}}" \
  | jq -r '"answer: \(.choices[0].message.content | gsub("\n"; " "))   usage: \(.usage)"'

log "3. responses API"
post responses "{\"model\":\"${MODEL}\",\"input\":\"Name the capital of France in one word.\",\"max_output_tokens\":64,${NO_THINK}}" \
  | jq -r '"status: \(.status)  answer: \([.output[] | select(.type=="message") | .content[].text] | join("") | gsub("\n"; " "))"'
echo -n "streaming event types: "
curl -sS -N "${API}/responses" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"input\":\"Count from 1 to 5.\",\"max_output_tokens\":64,\"stream\":true,${NO_THINK}}" \
  | sed -n 's/^data: //p' | grep -v '^\[DONE\]' | jq -r '.type' | sort | uniq -c | awk '{printf "%s x%s  ", $2, $1}'; echo

log "4. three-turn chat (the full history is sent on every turn)"
history='[]'
for q in "My name is Sam. Say hi in 3 words." "What is my name?" "Spell my name backwards."; do
  history="$(jq -c --arg q "${q}" '. + [{"role":"user","content":$q}]' <<<"${history}")"
  answer="$(post chat/completions "{\"model\":\"${MODEL}\",\"messages\":${history},\"max_tokens\":48,\"temperature\":0,${NO_THINK}}" \
    | jq -r '.choices[0].message.content' | sed '/^$/d' | tr '\n' ' ')"
  echo "user: ${q}"; echo "  assistant: ${answer}"
  history="$(jq -c --arg a "${answer}" '. + [{"role":"assistant","content":$a}]' <<<"${history}")"
done

log "5. which worker served each request (nvext.worker_id), $((WORKERS * 3)) requests"
for ((i = 0; i < WORKERS * 3; i++)); do
  post chat/completions "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1,\"nvext\":{\"extra_fields\":[\"worker_id\"]}}" \
    | jq -r '.nvext.worker_id | (.decode_worker_id // .prefill_worker_id) // "unknown"'
done | sort | uniq -c | awk '{print "  worker " $2 ": " $1 " request(s)"}'
