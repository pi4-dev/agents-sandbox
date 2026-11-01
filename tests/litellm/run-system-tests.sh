#!/bin/bash
# litellm/litellm-config.yaml + litellm/callbacks/system_messages.py against a
# real LiteLLM: whatever system messages a client sends (Claude Code on
# /v1/messages, OpenAI clients on /v1/chat/completions), an openai/ deployment
# gets a chat/completions request (not the Responses API) with at most one system
# message, and only as the first message (vLLM Qwen: "System message must be at
# the beginning."). The upstream is tests/litellm/upstream-recorder.py.
#
# Needs docker; pulls the LiteLLM image from docker-compose.yaml.
# Usage: tests/litellm/run-system-tests.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
LITELLM=$(sed -nE 's/.*\$\{LITELLM_IMAGE:-([^}]+)\}.*/\1/p' "$REPO/docker-compose.yaml" | head -n1)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
chmod 755 "$W"

# The repo config with the model includes swapped for one test deployment.
mkdir "$W/models"
sed -E '/^  - models\//d; s|^include:|include:\n  - models/test.yaml|' "$REPO/litellm/litellm-config.yaml" >"$W/config.yaml"
cat >"$W/models/test.yaml" <<'YAML'
model_list:
  - model_name: qwen
    litellm_params: { model: openai/qwen, api_base: "http://127.0.0.1:9999/v1", api_key: x }
YAML
cat >"$W/run.sh" <<'SH'
python3 /t/upstream-recorder.py 9999 >/w/upstream.log 2>&1 &
litellm --config /app/config.yaml --port 4000 >/w/litellm.log 2>&1 &
python3 - <<'PY'
import json, time, urllib.request as u
for _ in range(120):
    try:
        u.urlopen("http://127.0.0.1:4000/health/liveliness"); break
    except Exception:
        time.sleep(1)
def post(path, body):
    r = u.Request("http://127.0.0.1:4000" + path, json.dumps(body).encode(), method="POST",
                  headers={"Authorization": "Bearer sk-test", "content-type": "application/json"})
    try:
        u.urlopen(r)
    except Exception:
        pass
S = lambda c: {"role": "system", "content": c}
U = lambda c: {"role": "user", "content": c}
A = lambda c: {"role": "assistant", "content": c}
sysblocks = [{"type": "text", "text": "You are Claude Code", "cache_control": {"type": "ephemeral"}}, {"type": "text", "text": "Main"}]
post("/v1/messages", {"model": "qwen", "max_tokens": 5, "system": sysblocks, "messages": [U("a")]})
post("/v1/messages", {"model": "qwen", "max_tokens": 5, "system": "S", "messages": [S("X"), U("a"), A("b"), S("Y"), U("c")]})
post("/v1/chat/completions", {"model": "qwen", "max_tokens": 5, "messages": [S("S"), S("X"), U("a"), A("b"), S("Y"), U("c")]})
post("/v1/chat/completions", {"model": "qwen", "max_tokens": 5, "messages": [U("a")]})
PY
SH
docker run --rm -e LITELLM_MASTER_KEY=sk-test -e LITELLM_LOCAL_MODEL_COST_MAP=True --entrypoint sh \
  -v "$W/config.yaml:/app/config.yaml:ro" -v "$W/models:/app/models:ro" \
  -v "$REPO/litellm/callbacks:/app/callbacks:ro" -v "$REPO/tests/litellm/upstream-recorder.py:/t/upstream-recorder.py:ro" \
  -v "$W/run.sh:/t/run.sh:ro" -v "$W:/w" "$LITELLM" /t/run.sh

fail=0
expect() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi
}
mapfile -t got <"$W/upstream.log"
expect "messages, system blocks"                 "${got[0]:-}" "/v1/chat/completions system,user"
expect "messages, system entries in messages"    "${got[1]:-}" "/v1/chat/completions system,user,assistant,user,user"
expect "chat, two leading + one mid system"      "${got[2]:-}" "/v1/chat/completions system,user,assistant,user,user"
expect "chat, no system (untouched)"             "${got[3]:-}" "/v1/chat/completions user"
expect "one upstream request per client request" "${#got[@]}" 4
if [ "$fail" -ne 0 ]; then
  echo "--- upstream"; cat "$W/upstream.log"; echo "--- litellm (tail)"; tail -n 40 "$W/litellm.log"
  exit 1
fi
echo "all system-message tests passed"
