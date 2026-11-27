#!/bin/bash
# litellm/guardrails/presidio.yaml against a real LiteLLM and real Presidio containers
# (the images from docker-compose.yaml), on an internal network like as-net-presidio:
# - run.sh includes the guardrail only with the presidio profile;
# - blocked: card numbers, IBANs, API keys, tokens, passwords, private keys and PESEL never
#   reach the model, in chat/completions, /v1/messages (system, text, tool_result), streams
#   and /v1/responses, and no request field turns the guardrail off;
# - permitted: ordinary agent text (code, hashes, UUIDs, versions) reaches it unchanged;
# - fail closed: with the analyzer down, requests are refused and nothing reaches the model.
# The model is tests/litellm/upstream-bodies.py; the checks are tests/litellm/presidio-client.py.
#
# Needs docker; pulls the LiteLLM and Presidio images (about 2 GB).
# Usage: tests/litellm/run-presidio-tests.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
img() { sed -nE "s/.*\\\$\\{$1:-([^}]+)\\}.*/\\1/p" "$REPO/docker-compose.yaml" | head -n1; }
LITELLM=$(img LITELLM_IMAGE)
ANALYZER=$(img PRESIDIO_ANALYZER_IMAGE)
ANONYMIZER=$(img PRESIDIO_ANONYMIZER_IMAGE)
[ -n "$LITELLM" ] && [ -n "$ANALYZER" ] && [ -n "$ANONYMIZER" ] || { echo "images not found in docker-compose.yaml" >&2; exit 1; }
W=$(mktemp -d)
P=presidio-test-$$
cleanup() {
  docker rm -f "$P-litellm" "$P-analyzer" "$P-anonymizer" >/dev/null 2>&1 || true
  docker network rm "$P" >/dev/null 2>&1 || true
  rm -rf "$W"
}
trap cleanup EXIT
chmod 777 "$W"   # the LiteLLM image runs as a non-root UID (65532) and writes here
mkdir "$W/models"
cat >"$W/models/test.yaml" <<'YAML'
model_list:
  - model_name: test
    litellm_params: { model: openai/test, api_base: "http://127.0.0.1:9999/v1", api_key: x }
YAML

fail=0
expect() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi
}

# --- run.sh: the guardrail only with its profile ---
printf '#!/bin/sh\nexit 0\n' >"$W/stub.sh"; chmod 755 "$W/stub.sh"
guardrails() { # guardrails <AS_PROFILES>: guardrail files in the generated config
  docker run --rm -e "AS_PROFILES=$1" -e LITELLM_CONFIG_OUT=/w/inc.yaml --entrypoint sh \
    -v "$REPO/litellm/litellm-config.yaml:/app/config.yaml:ro" -v "$W/models:/app/models:ro" \
    -v "$REPO/litellm/guardrails:/app/guardrails:ro" -v "$REPO/litellm/run.sh:/scripts/run.sh:ro" \
    -v "$W/stub.sh:/app/docker/prod_entrypoint.sh:ro" -v "$W:/w" "$LITELLM" /scripts/run.sh >/dev/null 2>&1
  sed -n 's#^  - /app/guardrails/##p' "$W/inc.yaml" | tr '\n' ' ' | sed 's/ $//'
}
expect "run.sh: profile presidio -> its guardrail" "$(guardrails ,claude,presidio,)" "presidio.yaml"
expect "run.sh: every profile (*) -> its guardrail" "$(guardrails ,*,)" "presidio.yaml"
expect "run.sh: no presidio profile -> no guardrail" "$(guardrails ,claude,webui,)" ""

# --- LiteLLM with the guardrail, Presidio on an internal network (as-net-presidio) ---
docker network create --internal "$P" >/dev/null
docker run -d --name "$P-analyzer" --network "$P" --network-alias presidio-analyzer.as.internal \
  --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true "$ANALYZER" >/dev/null
docker run -d --name "$P-anonymizer" --network "$P" --network-alias presidio-anonymizer.as.internal \
  --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true "$ANONYMIZER" >/dev/null
for c in analyzer anonymizer; do
  for _ in $(seq 1 120); do
    docker exec "$P-$c" curl -fsS http://127.0.0.1:3000/health >/dev/null 2>&1 && break
    sleep 1
  done
done
docker run -d --name "$P-litellm" --network "$P" -e LITELLM_MASTER_KEY=sk-test -e LITELLM_LOCAL_MODEL_COST_MAP=True \
  -e AS_PROFILES=,presidio, --entrypoint sh \
  -v "$REPO/litellm/litellm-config.yaml:/app/config.yaml:ro" -v "$W/models:/app/models:ro" \
  -v "$REPO/litellm/guardrails:/app/guardrails:ro" -v "$REPO/litellm/run.sh:/scripts/run.sh:ro" \
  -v "$REPO/tests/litellm:/t:ro" -v "$W:/w" "$LITELLM" \
  -c 'python3 /t/upstream-bodies.py 9999 /w/bodies.jsonl & exec sh /scripts/run.sh --port 4000 >/w/litellm.log 2>&1' >/dev/null

docker exec "$P-litellm" python3 /t/presidio-client.py /w/bodies.jsonl masking || fail=1
docker stop "$P-analyzer" >/dev/null
docker exec "$P-litellm" python3 /t/presidio-client.py /w/bodies.jsonl fail-closed || fail=1

if [ "$fail" -ne 0 ]; then
  echo "--- litellm (tail)"; tail -n 40 "$W/litellm.log"
  exit 1
fi
echo "all Presidio masking tests passed"
