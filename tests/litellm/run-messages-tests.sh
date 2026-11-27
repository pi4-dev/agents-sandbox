#!/bin/bash
# litellm/litellm-config.yaml and litellm/run.sh against a real LiteLLM:
# - run.sh loads every litellm/models/*.yaml (no include: in the config; an old
#   include: block left in the config is dropped, other files are not loaded);
# - Claude Code's /v1/messages
# reaches an openai/ deployment as one chat/completions request with the system
# prompt as the first message, not as a Responses API request (an upstream may
# rebuild that into several system messages; vLLM Qwen: "System message must be
# at the beginning."). The upstream is tests/litellm/upstream-recorder.py.
#
# Needs docker; pulls the LiteLLM image from docker-compose.yaml.
# Usage: tests/litellm/run-messages-tests.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
LITELLM=$(sed -nE 's/.*\$\{LITELLM_IMAGE:-([^}]+)\}.*/\1/p' "$REPO/docker-compose.yaml" | head -n1)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
chmod 777 "$W"   # the LiteLLM image runs as a non-root UID (65532) and writes here

# The repo config plus an include: block of the old kind (a file that is not there:
# run.sh must drop it), and a models directory with two endpoint files and a README.
mkdir "$W/models"
{ cat "$REPO/litellm/litellm-config.yaml"; printf 'include:\n  - models/gone.yaml\n'; } >"$W/config.yaml"
cat >"$W/models/test.yaml" <<'YAML'
model_list:
  - model_name: qwen
    litellm_params: { model: openai/qwen, api_base: "http://127.0.0.1:9999/v1", api_key: x }
YAML
cat >"$W/models/second.yaml" <<'YAML'
model_list:
  - model_name: second
    litellm_params: { model: openai/second, api_base: "http://127.0.0.1:9999/v1", api_key: x }
YAML
# a file of the bridge profile: run.sh loads it only while that profile is active
cat >"$W/models/tagged.yaml" <<'YAML'
# @profile bridge
model_list:
  - model_name: tagged
    litellm_params: { model: openai/tagged, api_base: "http://127.0.0.1:9999/v1", api_key: x }
YAML
echo "not a model file" >"$W/models/README.md"
cat >"$W/run.sh" <<'SH'
python3 /t/upstream-recorder.py 9999 >/w/upstream.log 2>&1 &
sh /scripts/run.sh --port 4000 >/w/litellm.log 2>&1 &
python3 - <<'PY'
import json, time, urllib.request as u
for _ in range(120):
    try:
        u.urlopen("http://127.0.0.1:4000/health/liveliness"); break
    except Exception:
        time.sleep(1)
r = u.Request("http://127.0.0.1:4000/v1/models", headers={"Authorization": "Bearer sk-test"})
try:
    ids = sorted(m["id"] for m in json.load(u.urlopen(r))["data"])
except Exception as e:
    ids = [repr(e)]
open("/w/models.txt", "w").write(" ".join(ids))
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
post("/v1/messages", {"model": "qwen", "max_tokens": 5, "system": "S", "messages": [U("a"), A("b"), U("c")]})
post("/v1/chat/completions", {"model": "qwen", "max_tokens": 5, "messages": [S("S"), U("a")]})
PY
SH
docker run --rm -e LITELLM_MASTER_KEY=sk-test -e LITELLM_LOCAL_MODEL_COST_MAP=True -e AS_PROFILES=,claude, --entrypoint sh \
  -v "$W/config.yaml:/app/config.yaml:ro" -v "$W/models:/app/models:ro" \
  -v "$REPO/tests/litellm/upstream-recorder.py:/t/upstream-recorder.py:ro" \
  -v "$REPO/litellm/run.sh:/scripts/run.sh:ro" -v "$W/run.sh:/t/run.sh:ro" -v "$W:/w" "$LITELLM" /t/run.sh

fail=0
expect() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi
}
expect "run.sh: every models/*.yaml loaded, but a file of an inactive profile" "$(cat "$W/models.txt" 2>/dev/null)" "qwen second"
# which files run.sh includes for each AS_PROFILES (",<COMPOSE_PROFILES>,"; unset outside Compose)
printf '#!/bin/sh\nexit 0\n' >"$W/stub.sh"; chmod 755 "$W/stub.sh"
included() { # included <AS_PROFILES|-unset->: model file names in the generated config
  local e=(); [ "$1" = -unset- ] || e=(-e "AS_PROFILES=$1")
  docker run --rm "${e[@]}" -e LITELLM_CONFIG_OUT=/w/inc.yaml --entrypoint sh -v "$W/config.yaml:/app/config.yaml:ro" \
    -v "$W/models:/app/models:ro" -v "$REPO/litellm/run.sh:/scripts/run.sh:ro" -v "$W/stub.sh:/app/docker/prod_entrypoint.sh:ro" \
    -v "$W:/w" "$LITELLM" /scripts/run.sh >/dev/null 2>&1
  sed -n 's#^  - /app/models/##p' "$W/inc.yaml" | tr '\n' ' ' | sed 's/ $//'
}
expect "run.sh: profile bridge active -> its file"   "$(included ,claude,bridge,)" "second.yaml tagged.yaml test.yaml"
expect "run.sh: every profile (*) -> its file"        "$(included ,*,)"             "second.yaml tagged.yaml test.yaml"
expect "run.sh: no profile -> not its file"           "$(included ,,)"              "second.yaml test.yaml"
expect "run.sh: AS_PROFILES unset (no Compose) -> all" "$(included -unset-)"        "second.yaml tagged.yaml test.yaml"
expect "run.sh: a longer name is not the profile"     "$(included ,bridge2,)"       "second.yaml test.yaml"
mapfile -t got <"$W/upstream.log"
expect "messages, system blocks"                 "${got[0]:-}" "/v1/chat/completions system,user"
expect "messages, conversation"                   "${got[1]:-}" "/v1/chat/completions system,user,assistant,user"
expect "chat/completions unchanged"              "${got[2]:-}" "/v1/chat/completions system,user"
expect "one upstream request per client request" "${#got[@]}" 3
if [ "$fail" -ne 0 ]; then
  echo "--- upstream"; cat "$W/upstream.log"; echo "--- litellm (tail)"; tail -n 40 "$W/litellm.log"
  exit 1
fi
echo "all /v1/messages routing tests passed"
