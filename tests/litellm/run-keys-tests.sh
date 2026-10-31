#!/bin/bash
# as-litellm-keys (litellm/litellm-keys.py) against a real LiteLLM + PostgreSQL:
# pre-generated client keys get registered with LLM API routes only (no /model/info),
# a registered full-access key gets restricted, a second run changes nothing, a changed
# value rotates the key and keeps the settings made in the LiteLLM UI, invalid
# values stop the job, and client key values never travel in a URI (the job
# talks to LiteLLM through tests/litellm/uri-logger.py, an access-logging proxy).
# LITELLM_TEST_LOG=DEBUG runs LiteLLM with debug logging.
#
# Needs docker; pulls the LiteLLM and PostgreSQL images from docker-compose.yaml.
# Usage: tests/litellm/run-keys-tests.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
img() { sed -nE "s/.*\\\$\\{$1:-([^}]+)\\}.*/\\1/p" "$REPO/docker-compose.yaml" | head -n1; }
LITELLM=$(img LITELLM_IMAGE)
POSTGRES=$(img POSTGRES_IMAGE)
P=as-keys-test-$$
PORT=4401
W=$(mktemp -d)
chmod 755 "$W"
cleanup() {
  docker rm -f "$P-db" "$P-app" "$P-log" >/dev/null 2>&1 || true
  docker network rm "$P" >/dev/null 2>&1 || true
  rm -rf "$W"
}
trap cleanup EXIT

MASTER=sk-$(openssl rand -hex 24)
cat >"$W/config.yaml" <<'EOF'
model_list:
  - model_name: alpha
    litellm_params: { model: openai/a, api_base: "http://127.0.0.1:9/v1", api_key: x }
  - model_name: other
    litellm_params: { model: openai/b, api_base: "http://127.0.0.1:9/v1", api_key: x }
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF
chmod 644 "$W/config.yaml"

docker network create "$P" >/dev/null
docker run -d --name "$P-db" --network "$P" -e POSTGRES_DB=litellm -e POSTGRES_USER=litellm \
  -e POSTGRES_PASSWORD=pw "$POSTGRES" >/dev/null
for _ in $(seq 1 60); do docker exec "$P-db" pg_isready -U litellm >/dev/null 2>&1 && break; sleep 1; done
docker run -d --name "$P-app" --network "$P" --network-alias as-litellm -p "127.0.0.1:$PORT:4000" \
  -e LITELLM_LOG="${LITELLM_TEST_LOG:-INFO}" -e LITELLM_MASTER_KEY="$MASTER" -e LITELLM_SALT_KEY="$(openssl rand -hex 32)" \
  -e DATABASE_URL=postgresql://litellm:pw@"$P-db":5432/litellm \
  -v "$W/config.yaml:/app/config.yaml:ro" "$LITELLM" --config /app/config.yaml --port 4000 >/dev/null
for _ in $(seq 1 120); do
  curl -sf "http://127.0.0.1:$PORT/health/liveliness" >/dev/null 2>&1 && break
  sleep 2
done
mkdir -m 777 "$W/log"
docker run -d --name "$P-log" --network "$P" --network-alias uri-logger --entrypoint python3 \
  -v "$REPO/tests/litellm/uri-logger.py:/t/uri-logger.py:ro" -v "$W/log:/log" \
  "$LITELLM" /t/uri-logger.py 8080 http://as-litellm:4000 /log/uris.log >/dev/null

FAIL=0
result() { printf '%s  %s\n' "$1" "$2"; [ "$1" = PASS ] || FAIL=$((FAIL + 1)); }
# job <hermes key> <open-webui key>: run litellm-keys.py the way as-litellm-keys does
job() {
  docker run --rm --network "$P" --entrypoint python3 \
    -v "$REPO/litellm/litellm-keys.py:/scripts/litellm-keys.py:ro" \
    -e LITELLM_URL=http://uri-logger:8080 -e LITELLM_MASTER_KEY="$MASTER" \
    -e LITELLM_CLIENT_KEYS="hermes=LITELLM_API_KEY open-webui=OPENAI_API_KEY" \
    -e LITELLM_API_KEY="$1" -e OPENAI_API_KEY="$2" "$LITELLM" /scripts/litellm-keys.py 2>&1
}
models() { # models <key>: model ids visible to the key, or the HTTP status on failure
  local out code
  out=$(curl -s -w '\n%{http_code}' -H "Authorization: Bearer $1" "http://127.0.0.1:$PORT/v1/models")
  code=${out##*$'\n'}
  if [ "$code" = 200 ]; then python3 -c 'import json,sys; print(",".join(sorted(m["id"] for m in json.load(sys.stdin)["data"])))' <<<"${out%$'\n'*}"
  else echo "HTTP $code"; fi
}
expect() { if [ "$2" = "$3" ]; then result PASS "$1"; else result FAIL "$1 (got '$2', expected '$3')"; fi; }
code() { # code <key> <GET path | POST path json>: HTTP status
  if [ $# -gt 2 ]; then
    curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
      -X POST -d "$3" "http://127.0.0.1:$PORT$2"
  else
    curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $1" "http://127.0.0.1:$PORT$2"
  fi
}
denied() { case $1 in 401|403) echo denied ;; *) echo "allowed ($1)" ;; esac; }
# info routes that reveal the upstream (api_base, settings) must be closed to client keys
upstream_info() { # upstream_info <key>: "denied" when every info route is refused
  local r out=denied
  for r in /model/info /v1/model/info /v2/model/info /model_group/info; do
    [ "$(denied "$(code "$1" $r)")" = denied ] || out="allowed: $r"
  done
  echo "$out"
}
CHAT='{"model":"alpha","messages":[{"role":"user","content":"hi"}]}'

HK=sk-$(openssl rand -hex 24) OK=sk-$(openssl rand -hex 24)
# the Hermes key registered with full access (no routes)
curl -s -o /dev/null -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' \
  "http://127.0.0.1:$PORT/key/generate" -d "{\"key\":\"$HK\",\"key_alias\":\"hermes\"}"
expect "control: a full-access key reads /model/info" "$(denied "$(code "$HK" /model/info)")" "allowed (200)"
out=$(job "$HK" "$OK")
expect "first run creates the Open WebUI key" "$(grep -c ': created' <<<"$out")" 1
expect "first run restricts the full-access Hermes key" "$(grep -c 'hermes: already registered, restricted' <<<"$out")" 1
expect "pre-generated Hermes key works" "$(models "$HK")" "alpha,other"
expect "pre-generated Open WebUI key works" "$(models "$OK")" "alpha,other"
for who in HK OK; do
  k=${!who}
  expect "$who: upstream info routes refused" "$(upstream_info "$k")" denied
  expect "$who: chat completions allowed" "$(denied "$(code "$k" /v1/chat/completions "$CHAT")" | cut -c1-7)" allowed
  expect "$who: key management refused" "$(denied "$(code "$k" /key/list)")" denied
done
expect "master key still reads /model/info" "$(code "$MASTER" /model/info)" 200
routes=$(curl -s -H "Authorization: Bearer $MASTER" "http://127.0.0.1:$PORT/key/list?key_alias=hermes&return_full_object=true" |
  python3 -c 'import json,sys; k=json.load(sys.stdin)["keys"][0]; print(k.get("key_type"), k.get("allowed_routes"))')
echo "info: hermes key_type/allowed_routes: $routes"
out=$(job "$HK" "$OK")
expect "second run changes nothing" "$(grep -c 'already registered$' <<<"$out")" 2

# what an admin would do in the LiteLLM UI: restrict the Hermes key to one model
curl -s -o /dev/null -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' \
  "http://127.0.0.1:$PORT/key/update" -d "{\"key\":\"$HK\",\"models\":[\"alpha\"]}"
expect "UI-style restriction applies" "$(models "$HK")" "alpha"

NEW=sk-$(openssl rand -hex 24)
out=$(job "$NEW" "$OK")
expect "changed value rotates the key" "$(grep -c 'hermes: rotated' <<<"$out")" 1
expect "old Hermes key is revoked" "$(models "$HK")" "HTTP 401"
expect "new Hermes key keeps the UI restriction" "$(models "$NEW")" "alpha"
expect "new Hermes key keeps the route restriction" "$(upstream_info "$NEW")" denied
expect "Open WebUI key untouched" "$(models "$OK")" "alpha,other"
aliases=$(curl -s -H "Authorization: Bearer $MASTER" "http://127.0.0.1:$PORT/key/list?return_full_object=true" |
  python3 -c 'import json,sys; print(",".join(sorted(k["key_alias"] for k in json.load(sys.stdin)["keys"])))')
expect "exactly one key per alias" "$aliases" "hermes,open-webui"

# client key values must never be in a URI (access logs) nor in LiteLLM's own logs
expect "the job's requests went through the URI logger" "$(grep -c '^POST /key/generate' "$W/log/uris.log")" 2
for where in uris logs; do
  if [ $where = uris ]; then text=$(cat "$W/log/uris.log"); else text=$(docker logs "$P-app" 2>&1); fi
  leaked=0
  for k in "$HK" "$OK" "$NEW"; do
    if grep -qF -- "$k" <<<"$text"; then
      leaked=$((leaked + 1))
      grep -F -- "$k" <<<"$text" | sed "s/$k/<KEY>/g" | cut -c1-120 | head -2 >&2
    fi
  done
  expect "no client key value in $([ $where = uris ] && echo 'request URIs' || echo "LiteLLM's log")" "$leaked" 0
done

for bad in CHANGE_ME_LITELLM_KEY_HERMES sk-short "$MASTER"; do
  if job "$bad" "$OK" >/dev/null; then result FAIL "invalid Hermes key is rejected"
  else result PASS "invalid Hermes key is rejected"; fi
done

if [ "$FAIL" -gt 0 ]; then
  echo "run-keys-tests: $FAIL check(s) failed" >&2
  exit 1
fi
echo "run-keys-tests: all checks passed"
