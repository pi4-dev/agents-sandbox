#!/bin/bash
# as-llm-gw -> as-headroom -> as-litellm, with the repo's llm-gw/Caddyfile, LiteLLM config
# and litellm/run.sh, the Headroom image from docker-compose.yaml (offline: no model
# downloads in CI) and tests/headroom/upstream.py as the model:
# - chat (/v1/chat/completions) and messages (/v1/messages), plain and streamed, through
#   the gateway; count_tokens and models straight to LiteLLM;
# - a large repetitive tool output (chat format) reaches the model smaller than without
#   Headroom; messages requests go through Headroom;
# - a client's X-Headroom-* headers (x-headroom-base-url) are dropped, responses carry no
#   x-headroom-* header; Headroom refuses callers without the token.
#
# Needs docker. Usage: tests/headroom/run-headroom-tests.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
img() { sed -nE "s/.*\\\$\\{$1:-([^}]+)\\}.*/\\1/p" "$REPO/docker-compose.yaml" | head -n1; }
LITELLM=$(img LITELLM_IMAGE)
HEADROOM=$(img HEADROOM_IMAGE)
CADDY=$(img CADDY_IMAGE)
NETSHOOT=$(img NETSHOOT_IMAGE)
P=as-headroom-test-$$
TOKEN=$(openssl rand -hex 16)
W=$(mktemp -d)
chmod 755 "$W"
cleanup() {
  docker rm -f "$P-model" "$P-litellm" "$P-headroom" "$P-gw" >/dev/null 2>&1 || true
  docker network rm "$P" >/dev/null 2>&1 || true
  rm -rf "$W" 2>/dev/null || sudo rm -rf "$W" 2>/dev/null || true
}
trap cleanup EXIT

mkdir "$W/models" "$W/data"
chmod 777 "$W/data"
cat >"$W/models/test.yaml" <<'YAML'
model_list:
  - model_name: qwen
    litellm_params: { model: openai/qwen, api_base: "http://model.test:9000/v1", api_key: x }
YAML

docker network create "$P" >/dev/null
docker run -d --name "$P-model" --network "$P" --network-alias model.test --entrypoint python3 \
  -v "$REPO/tests/headroom/upstream.py:/t/upstream.py:ro" "$LITELLM" -u /t/upstream.py 9000 >/dev/null
docker run -d --name "$P-litellm" --network "$P" --network-alias litellm.as.internal \
  -e LITELLM_MASTER_KEY=sk-test -e LITELLM_LOCAL_MODEL_COST_MAP=True --entrypoint /bin/sh \
  -v "$REPO/litellm/litellm-config.yaml:/app/config.yaml:ro" -v "$W/models:/app/models:ro" \
  -v "$REPO/litellm/run.sh:/scripts/run.sh:ro" "$LITELLM" /scripts/run.sh --port 4000 >/dev/null
# as in docker-compose.yaml, plus HEADROOM_OFFLINE (no Squid here)
docker run -d --name "$P-headroom" --network "$P" --network-alias headroom.as.internal \
  --user 1000:1000 --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true \
  -e HEADROOM_PROXY_TOKEN="$TOKEN" -e HEADROOM_HOST=0.0.0.0 -e HEADROOM_PORT=8787 \
  -e ANTHROPIC_TARGET_API_URL=http://litellm.as.internal:4000 -e OPENAI_TARGET_API_URL=http://litellm.as.internal:4000/v1 \
  -e HEADROOM_BEACON=off -e HEADROOM_TELEMETRY=off -e DO_NOT_TRACK=1 -e HEADROOM_UPDATE_CHECK=off \
  -e HEADROOM_NO_SUBSCRIPTION_TRACKING=1 -e HEADROOM_NO_CCR=1 -e HOME=/data -e HEADROOM_WORKSPACE_DIR=/data/workspace \
  -e HF_HOME=/data/hf -e HEADROOM_OFFLINE=1 -v "$W/data:/data" "$HEADROOM" --no-rate-limit --no-cache >/dev/null
docker run -d --name "$P-gw" --network "$P" --network-alias llm.as.internal -e HEADROOM_PROXY_TOKEN="$TOKEN" \
  --tmpfs /var/log/caddy:mode=1777 -v "$REPO/llm-gw:/etc/caddy:ro" "$CADDY" >/dev/null

client() { docker run --rm --network "$P" -v "$W:/w" "$NETSHOOT" "$@"; }
for _ in $(seq 1 90); do
  client sh -c 'curl -sf http://litellm.as.internal:4000/health/liveliness >/dev/null && curl -sf -H "X-Headroom-Proxy-Token: '"$TOKEN"'" http://headroom.as.internal:8787/readyz >/dev/null' && break
  sleep 2
done

# request bodies: a tool output of 300 near-identical JSON records, chat and messages format
python3 - "$W" <<'PY'
import json, sys
w = sys.argv[1]
rows = json.dumps([{"id": i, "status": "ok", "region": "eu-west-1", "latency_ms": 12,
                    "message": "request completed successfully"} for i in range(300)])
call = {"id": "call_1", "type": "function", "function": {"name": "list_requests", "arguments": "{}"}}
def chat(q):
    return {"model": "qwen", "messages": [
    {"role": "user", "content": q},
    {"role": "assistant", "content": None, "tool_calls": [call]},
    {"role": "tool", "tool_call_id": "call_1", "content": rows}]}
def msgs(q):
    return {"model": "qwen", "max_tokens": 50, "messages": [
    {"role": "user", "content": q},
    {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_1", "name": "list_requests", "input": {}}]},
    {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_1", "content": rows}]}]}
# one conversation per file: Headroom's cache mode treats an equal start as the same
# conversation and leaves a turn it has seen differently uncompressed
for name, make in (("chat", chat), ("msgs", msgs)):
    for kind in ("base", "gw", "stream", "short", "hdr"):
        body = make(f"Which requests failed? ({name} {kind})")
        if kind == "stream":
            body["stream"] = True
        json.dump(body, open(f"{w}/{name}-{kind}.json", "w"))
PY

fail=0
expect() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi
}
# call <url> <body file|-> [curl args]: prints the HTTP status, keeps body and headers in /w
call() {
  local url=$1 body=$2; shift 2
  local data=(); [ "$body" = - ] || data=(-H 'content-type: application/json' --data-binary "@/w/$body")
  client curl -s -o /w/out -D /w/hdrs -w '%{http_code}' -H 'Authorization: Bearer sk-test' \
    -H 'anthropic-version: 2023-06-01' "${data[@]}" "$@" "$url"
}
# has <name> <grep -E pattern> <file>: the file matches
has() { if grep -qiE "$2" "$3"; then expect "$1" ok ok; else expect "$1" "$(head -c 200 "$3" | tr '\n' ' ')" "/$2/"; fi; }
last_chars() { tail -n1 "$W/model.log" | sed -nE 's/.* chars=([0-9]+)$/\1/p'; }
log_model() { docker logs "$P-model" >"$W/model.log" 2>&1; }
GW=http://llm.as.internal:4000
LL=http://litellm.as.internal:4000

expect "baseline: chat straight to LiteLLM" "$(call "$LL/v1/chat/completions" chat-base.json)" 200
log_model; base=$(last_chars)
expect "gw: chat through Headroom" "$(call "$GW/v1/chat/completions" chat-gw.json)" 200
has "gw: chat answer" '"hello"' "$W/out"
log_model; gw=$(last_chars)
if [ -n "$base" ] && [ -n "$gw" ] && [ "$gw" -lt "$base" ]; then expect "tool output compressed ($base -> $gw chars)" ok ok
else expect "tool output compressed" "base=$base gw=$gw" "gw < base"; fi
expect "gw: no x-headroom-* response header" "$(grep -ci '^x-headroom' "$W/hdrs" || true)" 0

expect "gw: chat stream" "$(call "$GW/v1/chat/completions" chat-stream.json)" 200
has "gw: chat stream ends with [DONE]" 'data: \[DONE\]' "$W/out"
expect "gw: /chat/completions" "$(call "$GW/chat/completions" chat-short.json)" 200

expect "gw: messages through Headroom" "$(call "$GW/v1/messages?beta=true" msgs-gw.json)" 200
has "gw: messages answer" '"type": *"message"' "$W/out"
# Headroom 0.42.0 leaves this synthetic tool_result as it is on the Anthropic path
# (transforms=none), so only the route is checked here: the request went through Headroom
expect "messages went through Headroom" \
  "$(docker logs "$P-headroom" 2>&1 | grep -c 'event=proxy_inbound_request .*path=/v1/messages ')" 1
expect "gw: messages stream" "$(call "$GW/v1/messages" msgs-stream.json)" 200
has "gw: messages stream ends with message_stop" 'message_stop' "$W/out"

expect "gw: count_tokens (LiteLLM)" "$(call "$GW/v1/messages/count_tokens" msgs-base.json)" 200
expect "gw: /v1/models (LiteLLM)" "$(call "$GW/v1/models" -)" 200
expect "gw: /openapi.json stays closed" "$(call "$GW/openapi.json" -)" 404

log_model; n=$(wc -l <"$W/model.log")
expect "client x-headroom-base-url is dropped" \
  "$(call "$GW/v1/chat/completions" chat-hdr.json -H 'X-Headroom-Base-Url: http://evil.test' -H 'X-Headroom-Proxy-Token: wrong')" 200
log_model
expect "... the request still reached the model" "$(( $(wc -l <"$W/model.log") - n ))" 1
expect "Headroom without the token" "$(call http://headroom.as.internal:8787/v1/chat/completions chat-hdr.json)" 401
expect "Headroom with a wrong token" "$(call http://headroom.as.internal:8787/v1/chat/completions chat-hdr.json -H 'X-Headroom-Proxy-Token: wrong')" 401

if [ "$fail" -ne 0 ]; then
  echo "--- model"; cat "$W/model.log"
  echo "--- headroom (tail)"; docker logs "$P-headroom" 2>&1 | tail -n 30
  echo "--- litellm (tail)"; docker logs "$P-litellm" 2>&1 | tail -n 20
  echo "--- gw (tail)"; docker logs "$P-gw" 2>&1 | tail -n 10
  exit 1
fi
echo "all Headroom tests passed"
