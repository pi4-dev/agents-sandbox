#!/bin/bash
# End-to-end check of the as-net-blind topology on real containers.
#
# Starts as-dns, as-squid, as-ingress, as-llm-gw, as-zenoh and the netshoot and Hermes sidecars from
# docker-compose.yaml (the *.example env files, a veth as the macvlan parent),
# the real Claude bridge (its image is built; BRIDGE_PULL_POLICY=never uses a
# prebuilt agents-sandbox/claude-bridge), and small stand-ins for Open WebUI, Hermes,
# LiteLLM and the Claude agent (the real networks, namespaces and proxy settings,
# another image). Then checks names, the proxy paths, the ingress,
# and that no container on as-net-blind gets out by routing through a dual-homed
# gateway, even with NET_ADMIN.
#
# Uses the fixed container names of the stack: do not run it next to a running stack.
# Needs root, docker (builds agents-sandbox/squid, pulls Caddy, CoreDNS, netshoot), iproute2.
#
# Usage: sudo tests/compose/run-blind-tests.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
[ "$(id -u)" = 0 ] || { echo "run-blind-tests: run as root" >&2; exit 2; }
img() { sed -nE "s/.*\\\$\\{$1:-([^}]+)\\}.*/\\1/p" "$REPO/docker-compose.yaml" | head -n1; }
NETSHOOT=$(img NETSHOOT_IMAGE)
CADDY=$(img CADDY_IMAGE)
PARENT=asblt$$
LAN_IP=192.19.255.50   # a LAN host on the VLAN, outside HERMES/INGRESS_DASHBOARD_ALLOW_FROM
ADMIN_IP=192.19.255.60 # a LAN host inside both
W=$(mktemp -d)
BRNF=/proc/sys/net/bridge/bridge-nf-call-iptables
BRNF_OLD=

export COMPOSE_PROJECT_NAME=as-net-blind-test COMPOSE_FILE=docker-compose.yaml:blind-test.yaml
cleanup() {
  if [ -n "$BRNF_OLD" ]; then echo "$BRNF_OLD" >"$BRNF"; fi
  docker rm -f asbt-lan asbt-ctl asbt-zsub >/dev/null 2>&1 || true
  (cd "$W" && docker compose down -v --remove-orphans >/dev/null 2>&1) || true
  ip link del "$PARENT" 2>/dev/null || true
  rm -rf "$W"
}
trap cleanup EXIT

# --- a copy of the working tree with the examples as real env files
(
  cd "$REPO"
  git ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' f; do
      if [ -e "$f" ]; then cp --parents "$f" "$W"; fi
    done
)
cd "$W"
cp .env.example .env
while IFS= read -r -d '' f; do cp "$f" "${f%.example}"; done < <(find . -name '*.env.example' -print0)
for f in squid/conf/*.example hermes/config.yaml.example; do cp "$f" "${f%.example}"; done
mkdir -p zenoh/logs && chown 1000:1000 zenoh/logs   # as-zenoh runs as ZENOH_UID (1000)
mkdir -p dns/logs ingress/logs llm-gw/logs litellm/logs
chown 1000:1000 dns/logs ingress/logs llm-gw/logs     # as-dns, as-ingress, as-llm-gw run as LOGS_UID (1000)
# SQUID_DNS_UPSTREAM: nothing answers there, so an allowed request ends in 503
# (a denied one is 403 before any lookup)
sed -i -e "s/^VLAN_PARENT=.*/VLAN_PARENT=$PARENT/" \
       -e "s#^HERMES_DASHBOARD_ALLOW_FROM=.*#HERMES_DASHBOARD_ALLOW_FROM=$ADMIN_IP/32#" \
       -e "s#^INGRESS_DASHBOARD_ALLOW_FROM=.*#INGRESS_DASHBOARD_ALLOW_FROM=$ADMIN_IP/32#" \
       -e "s/^SQUID_DNS_UPSTREAM=.*/SQUID_DNS_UPSTREAM=127.0.0.1/" .env
./ssl/init_ca.sh >/dev/null 2>&1
ip link add "$PARENT" type veth peer name "${PARENT}p"
ip link set "$PARENT" up
ip link set "${PARENT}p" up
cat >blind-test.yaml <<EOF
services:
  as-open-webui:
    image: $CADDY
    env_file: !reset []
    command: ["caddy", "respond", "--listen", ":8080", "WEBUI-OK"]
  as-hermes:
    image: $CADDY
    env_file: !reset []
    volumes: !reset []
    command: ["caddy", "respond", "--listen", ":9119", "HERMES-OK"]
  as-litellm:
    image: $NETSHOOT
    command: ["sleep", "infinity"]
    healthcheck: { test: ["CMD", "true"], interval: 1s }
  as-claude-main:
    image: $NETSHOOT
    build: !reset null
    pull_policy: missing
    env_file: !reset []
    volumes: !reset []
    command: ["sleep", "infinity"]
  as-claude-bridge:
    pull_policy: ${BRIDGE_PULL_POLICY:-build}
  as-squid:
    ulimits: !reset {}    # some sandboxes refuse raising nofile
EOF
envval() { sed -nE "s/^$1=(.*)/\\1/p" .env; }
DNS_IP=$(envval DNS_IP) INGRESS_IP=$(envval INGRESS_IP) PROXY_PORT=3128
BLIND=${COMPOSE_PROJECT_NAME}_as-net-blind VLAN=${COMPOSE_PROJECT_NAME}_as-net-vlan

docker compose build -q as-squid
docker compose up -d --quiet-pull as-dns as-squid as-ingress as-llm-gw as-zenoh as-netshoot-net as-netshoot \
  as-hermes-net as-claude-net as-claude-bridge-net as-claude-qwen-net
docker compose up -d --no-deps as-open-webui as-hermes as-litellm as-claude-main as-claude-bridge

SIDECARS=(as-netshoot-net as-hermes-net as-claude-net as-claude-bridge-net as-claude-qwen-net)
FAIL=0
result() { printf '%s  %s\n' "$1" "$2"; [ "$1" = PASS ] || FAIL=$((FAIL + 1)); }
check() { # check <description> <command...>: the command succeeds
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then result PASS "$what"; else result FAIL "$what"; fi
}
check_not() { # check_not <description> <command...>: the command fails
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then result FAIL "$what"; else result PASS "$what"; fi
}
ipb() { docker inspect -f "{{(index .NetworkSettings.Networks \"$BLIND\").IPAddress}}" "$1"; }
lan_get() { # lan_get <ip> <url>: body and status code seen by a throwaway LAN host
  docker run --rm --network "$VLAN" --ip "$1" "$NETSHOOT" curl -s --max-time 5 -w '\n%{http_code}' "$2" || true
}
attacker() { # attacker <command>: a container on as-net-blind with NET_ADMIN and no sidecar
  docker run --rm --cap-add NET_ADMIN --network "$BLIND" "$NETSHOOT" sh -c "$1"
}

for _ in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "${SIDECARS[@]}" 2>/dev/null | sort -u)" = healthy ] && break
  sleep 1
done
check "sidecars report ready (names resolve through as-dns)" \
  test "$(docker inspect -f '{{.State.Health.Status}}' "${SIDECARS[@]}" | sort -u)" = healthy

for c in as-squid as-ingress; do
  check "$c: ip_forward=0" test "$(docker exec $c cat /proc/sys/net/ipv4/ip_forward)" = 0
done

# --- names and the proxy path, from the agent
check "agent: resolv.conf points at as-dns" docker exec as-netshoot grep -qx "nameserver $DNS_IP" /etc/resolv.conf
check "agent: proxy.as.internal is Squid's as-net-blind address" \
  test "$(docker exec as-netshoot getent hosts proxy.as.internal | awk '{print $1}')" = "$(ipb as-squid)"
check_not "agent: no default route" grep -q default <<<"$(docker exec as-netshoot ip route)"
check_not "agent: llm-proxy.as.internal (LiteLLM's network) does not resolve" \
  docker exec as-netshoot getent hosts llm-proxy.as.internal
check "agent: denied domain -> 403 from Squid" \
  test "$(docker exec as-netshoot curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://evil.example.com/)" = 403
# LiteLLM: Squid through its own network, the provider APIs only from there
LLM=${COMPOSE_PROJECT_NAME}_as-net-litellm-egress
check "LiteLLM: llm-proxy.as.internal is Squid's as-net-litellm-egress address" \
  test "$(docker exec as-litellm getent hosts llm-proxy.as.internal | awk '{print $1}')" = \
       "$(docker inspect -f "{{(index .NetworkSettings.Networks \"$LLM\").IPAddress}}" as-squid)"
# (Squid gives up on the silent resolver after ~20 s)
code() { docker exec "$1" curl -s -o /dev/null -w '%{http_code}' --max-time 45 "$2" || true; }
got=$(code as-litellm http://openrouter.ai/)
check "LiteLLM -> openrouter.ai passes Squid's ACL (503: no DNS in the test; got $got)" test "$got" = 503
got=$(code as-netshoot http://openrouter.ai/)
check "agent -> openrouter.ai -> 403 (got $got)" test "$got" = 403
# as-llm-gw: Hermes reaches LiteLLM only through it. The LiteLLM stand-in answers on
# :4000 with the headers the real one adds: llm_provider-* (the upstream's own) and
# x-litellm-model-* (api_base, the deployment's model), next to x-litellm-key-spend.
docker exec -i as-litellm sh -c 'cat >/tmp/fake-litellm.sh' <<'EOF_FAKE'
while IFS= read -r line; do
  case $line in ''|"$(printf '\r')") break ;; esac
done
body='{"data":[]}'
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nllm_provider-server: envoy\r\nllm_provider-x-upstream: qwen.svc.cluster.local\r\nx-litellm-model-api-base: http://upstream.example/v1\r\nx-litellm-model-name: openai/real-model\r\nx-litellm-key-spend: 0.0\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "${#body}" "$body"
EOF_FAKE
docker exec -d as-litellm socat TCP-LISTEN:4000,fork,reuseaddr EXEC:'sh /tmp/fake-litellm.sh'
sleep 1
heads() { docker exec "$1" curl -s -D - -o /dev/null --noproxy '*' --max-time 5 "$2" || true; }
status() { docker exec "$1" curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 5 "$2" || true; }
upstream_heads() { grep -qi '^llm_provider-server' <<<"$1" && grep -qi '^x-litellm-model-api-base' <<<"$1"; }
direct=$(heads as-netshoot http://litellm.as.internal:4000/v1/models)
check "control: the LiteLLM stand-in sends llm_provider-* and x-litellm-model-*" upstream_heads "$direct"
via=$(heads as-hermes-net http://llm.as.internal:4000/v1/models)
check "Hermes -> as-llm-gw /v1/models -> 200 from LiteLLM" grep -qE '^HTTP/[0-9.]+ 200' <<<"$via"
check_not "as-llm-gw drops llm_provider-* headers" grep -qi '^llm_provider-' <<<"$via"
check_not "as-llm-gw drops x-litellm-model-* headers" grep -qi '^x-litellm-model-' <<<"$via"
check "as-llm-gw keeps x-litellm-key-spend" grep -qi '^x-litellm-key-spend' <<<"$via"
for path in /openapi.json /redoc /health/readiness /.well-known/litellm-ui-config /metrics /key/list /v1/embeddings; do
  got=$(status as-hermes-net "http://llm.as.internal:4000$path")
  check "Hermes -> as-llm-gw $path -> 404, not passed on (got $got)" test "$got" = 404
done
got=$(status as-hermes-net http://litellm.as.internal:4000/v1/models)
check "Hermes -> LiteLLM directly is dropped (got $got)" test "$got" = 000
# as-claude-qwen: Claude Code's Anthropic API through as-llm-gw, nothing of LiteLLM directly
got=$(status as-claude-qwen-net http://llm.as.internal:4000/v1/messages)
check "Claude on Qwen -> as-llm-gw /v1/messages -> LiteLLM (got $got)" test "$got" = 200
got=$(status as-claude-qwen-net http://llm.as.internal:4000/openapi.json)
check "Claude on Qwen -> as-llm-gw /openapi.json -> 404 (got $got)" test "$got" = 404
got=$(status as-claude-qwen-net http://litellm.as.internal:4000/v1/models)
check "Claude on Qwen -> LiteLLM directly is dropped (got $got)" test "$got" = 000
gwlog=$(cat llm-gw/logs/access.log 2>/dev/null || true)
check "llm-gw/logs/access.log has Hermes' /v1/models (200)" \
  grep -qE '"uri":"/v1/models".*"status":200' <<<"$gwlog"
check "llm-gw/logs/access.log has the refused /openapi.json (404)" \
  grep -qE '"uri":"/openapi.json".*"status":404' <<<"$gwlog"

# --- as-zenoh: the message bus. A Zenoh client (the router's version) runs in the network
# namespace of a sidecar, so its firewall applies; the passwords are the example values.
docker build -q -t asbt-zclient - >/dev/null <<EOF_ZC
FROM python:3.13-slim
RUN pip install --no-cache-dir "eclipse-zenoh==$(img ZENOH_VERSION)"
EOF_ZC
cat >"$W/zc.py" <<'EOF_ZC'
import json, sys, time
import zenoh
endpoint, user, password, cmd, key = sys.argv[1:6]
conf = zenoh.Config()
conf.insert_json5("mode", '"client"')
conf.insert_json5("connect/endpoints", json.dumps([endpoint]))
conf.insert_json5("scouting/multicast/enabled", "false")
if user != "-":
    conf.insert_json5("transport/auth/usrpwd", json.dumps({"user": user, "password": password}))
try:
    session = zenoh.open(conf)
except Exception:
    print("REFUSED", flush=True)
    sys.exit(0)
if cmd == "pub":
    session.put(key, sys.argv[6], encoding=zenoh.Encoding.TEXT_PLAIN)
    time.sleep(1)
    print("PUBLISHED", flush=True)
else:
    session.declare_subscriber(key, lambda s: print(f"GOT {s.key_expr} {s.payload.to_string()}", flush=True))
    print("SUBSCRIBED", flush=True)
    time.sleep(float(sys.argv[6]))
session.close()
EOF_ZC
zep=tcp/$(ipb as-zenoh):7447
zpw() { sed -nE "s/^ZENOH_PASSWORD_$1=(.*)/\1/p" zenoh/zenoh.env; }
zc() { # zc <container whose network namespace> <zc.py args>: the client's output
  local ns=$1; shift
  docker run --rm --network "container:$ns" -v "$W/zc.py:/zc.py:ro" asbt-zclient \
    timeout 20 python /zc.py "$zep" "$@" 2>&1 || true
}
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' as-zenoh)" = healthy ] && break
  sleep 2
done
check "as-zenoh is healthy (router and message log)" test "$(docker inspect -f '{{.State.Health.Status}}' as-zenoh)" = healthy
docker run -d --name asbt-zsub --network container:as-claude-net -v "$W/zc.py:/zc.py:ro" asbt-zclient \
  timeout 60 python /zc.py "$zep" claude "$(zpw CLAUDE)" sub 'as/**' 45 >/dev/null
for _ in $(seq 1 20); do docker logs asbt-zsub 2>&1 | grep -q SUBSCRIBED && break; sleep 1; done
check "Claude subscribes to the bus from its namespace" grep -q SUBSCRIBED <<<"$(docker logs asbt-zsub 2>&1)"
check "Hermes publishes under as/hermes" grep -q PUBLISHED <<<"$(zc as-hermes-net hermes "$(zpw HERMES)" pub as/hermes/test 'hello from hermes')"
check "Claude on Qwen publishes under as/claude-qwen" \
  grep -q PUBLISHED <<<"$(zc as-claude-qwen-net claude-qwen "$(zpw CLAUDE_QWEN)" pub as/claude-qwen/test 'hello from qwen')"
zc as-hermes-net hermes "$(zpw HERMES)" pub as/claude/test 'spoofed by hermes' >/dev/null
check "a wrong password is refused" grep -q REFUSED <<<"$(zc as-hermes-net hermes wrong pub as/hermes/test 'wrong password')"
check "no login is refused (as-net-blind container without a sidecar)" grep -q REFUSED <<<"$(docker run --rm \
  --network "$BLIND" -v "$W/zc.py:/zc.py:ro" asbt-zclient timeout 20 python /zc.py "$zep" - - pub as/hermes/test 'anonymous' 2>&1 || true)"
check_not "the bridge's namespace cannot reach the bus" \
  grep -q PUBLISHED <<<"$(zc as-claude-bridge-net claude "$(zpw CLAUDE)" pub as/claude/test 'from the bridge')"
sleep 2
zsub=$(docker logs asbt-zsub 2>&1)
check "Claude receives Hermes' message" grep -q 'GOT as/hermes/test hello from hermes' <<<"$zsub"
check "Claude receives the message of Claude on Qwen" grep -q 'GOT as/claude-qwen/test hello from qwen' <<<"$zsub"
check_not "the ACL drops Hermes' message under as/claude" grep -q spoofed <<<"$zsub"
zlog=$(cat zenoh/logs/messages-*.jsonl 2>/dev/null || true)
check "the message log on the host has Hermes' message" \
  grep -qF '"key":"as/hermes/test","value":"hello from hermes"' <<<"$zlog"
check_not "the log has none of the refused or dropped messages" grep -qE 'spoofed|wrong password|anonymous|from the bridge' <<<"$zlog"
got=$(status as-netshoot "http://$(ipb as-zenoh):8000/@/*/router")
check "as-zenoh's REST (no login, no ACL) is closed to as-net-blind (got $got)" test "$got" = 000
docker rm -f asbt-zsub >/dev/null 2>&1 || true
# Claude: the agent and the bridge in separate namespaces; :9090 from LiteLLM only
# bridge <container> <url> [curl args]: HTTP status (000 = no connection)
bridge() { docker exec "$1" curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 4 "${@:3}" "$2" || true; }
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' as-claude-bridge 2>/dev/null)" = healthy ] && break
  sleep 2
done
check "as-claude-bridge (real image) is healthy" test "$(docker inspect -f '{{.State.Health.Status}}' as-claude-bridge)" = healthy
models=http://claude-bridge.as.internal:9090/v1/models
# the stand-in has LiteLLM's env, CLAUDE_OAI_KEY included (the same value as the bridge's)
got=$(docker exec as-litellm sh -c "curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 4 -H \"Authorization: Bearer \$CLAUDE_OAI_KEY\" $models" || true)
check "LiteLLM -> bridge /v1/models with CLAUDE_OAI_KEY -> 200 (got $got)" test "$got" = 200
got=$(bridge as-litellm "$models")
check "LiteLLM -> bridge without the key -> 401 (got $got)" test "$got" = 401
check "Claude agent -> the bridge by name is dropped" test "$(bridge as-claude-main "$models")" = 000
check "Claude agent -> 127.0.0.1:9090 finds nothing (own namespace)" test "$(bridge as-claude-main http://127.0.0.1:9090/healthz)" = 000
check_not "as-net-blind container without a sidecar -> the bridge is dropped" \
  attacker "curl -sf --max-time 3 http://claude-bridge.as.internal:9090/healthz"
check_not "bridge cannot change its own code" docker exec as-claude-bridge touch /app/server.mjs
check "bridge mounts nothing of claude-main" \
  test -z "$(docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' as-claude-bridge | tr ' ' '\n' | grep claude-main)"
# the agent trusts Squid's CA: an allowed HTTPS request is bumped and verified
# (503: no upstream DNS in the test; without the CA curl fails the handshake, 000)
got=$(code as-netshoot https://api.anthropic.com/)
check "agent: HTTPS through the bump verifies against the proxy CA (got $got)" test "$got" = 503
# as-netshoot: anything out to as-net-blind (ping, any port), nothing in
pings() { docker exec "$1" ping -c 1 -W 2 "$2" >/dev/null 2>&1; }
check "netshoot -> ping LiteLLM (no sidecar)" pings as-netshoot litellm.as.internal
check "netshoot -> ping the Claude agent (sidecar admits netshoot's ping)" pings as-netshoot claude.as.internal
check "netshoot -> ping the bridge" pings as-netshoot claude-bridge.as.internal
check "netshoot -> as-dns TCP 53" docker exec as-netshoot nc -z -w 2 "$DNS_IP" 53
check "netshoot -> ingress's inner leg on any port (TCP reset, not dropped)" \
  grep -q refused <<<"$(docker exec as-netshoot nc -z -v -w 2 ingress.as.internal 8080 2>&1)"
check "netshoot -> ping Hermes (behind its sidecar)" pings as-netshoot hermes.as.internal
check "netshoot -> Hermes :9119 (sidecar admits netshoot on any port)" \
  grep -q HERMES-OK <<<"$(docker exec as-netshoot curl -s --noproxy '*' --max-time 4 http://hermes.as.internal:9119/ || true)"
got=$(bridge as-netshoot "$models")
check "netshoot -> the bridge :9090 reaches it (401: the key is still required; got $got)" test "$got" = 401
docker exec -d as-netshoot socat TCP-LISTEN:7777,fork,reuseaddr SYSTEM:'echo NETSHOOT'
sleep 1
check "control: netshoot's listener answers locally" sh -c "docker exec as-netshoot nc -w 2 127.0.0.1 7777 | grep -q NETSHOOT"
check_not "as-net-blind container without a sidecar -> netshoot :7777 dropped" \
  attacker "nc -w 2 netshoot.as.internal 7777 | grep -q NETSHOOT"
check_not "Claude agent -> netshoot :7777 dropped" sh -c "docker exec as-claude-main nc -w 2 netshoot.as.internal 7777 | grep -q NETSHOOT"
check_not "ping -> netshoot dropped" attacker "ping -c 1 -W 2 netshoot.as.internal"
check "as-dns logged the agent's lookup" \
  grep -q "$(ipb as-netshoot-net):.*proxy.as.internal" <<<"$(docker logs as-dns 2>&1)"
check "dns/logs/queries-<date>.log on the host has the agent's lookup" \
  grep -q "$(ipb as-netshoot-net):.*proxy.as.internal" <<<"$(cat dns/logs/queries-*.log 2>/dev/null || true)"

# --- ingress: the GUIs from the LAN, nothing from inside
check "LAN -> ingress :8080 -> Open WebUI" grep -q WEBUI-OK <<<"$(lan_get $LAN_IP "http://$INGRESS_IP:8080/")"
check "LAN outside HERMES_DASHBOARD_ALLOW_FROM -> ingress :9119 -> 403" \
  grep -qx 403 <<<"$(lan_get $LAN_IP "http://$INGRESS_IP:9119/")"
check "ingress/logs/access.log has the LAN host's refused request (403)" \
  grep -qE "\"remote_ip\":\"$LAN_IP\".*\"host\":\"$INGRESS_IP:9119\".*\"status\":403" <<<"$(cat ingress/logs/access.log 2>/dev/null || true)"
check "admin host -> ingress :9119 -> Hermes (sidecar admits as-ingress)" \
  grep -q HERMES-OK <<<"$(lan_get $ADMIN_IP "http://$INGRESS_IP:9119/")"
# the dashboard: links built from the "# @dashboard" lines of the Caddyfile
has_links() { # has_links <page> <host:port/path>...: the page links to every one
  local page=$1 u; shift
  for u; do grep -qF "href=\"http://$u\"" <<<"$page" || return 1; done
}
dash=$(lan_get $ADMIN_IP "http://$INGRESS_IP/")
check "admin host -> ingress :80 -> dashboard links to :8080, :4000/ui, :9119" \
  has_links "$dash" "$INGRESS_IP:8080/" "$INGRESS_IP:4000/ui" "$INGRESS_IP:9119/"
check "LAN outside INGRESS_DASHBOARD_ALLOW_FROM -> ingress :80 -> 403" \
  grep -qx 403 <<<"$(lan_get $LAN_IP "http://$INGRESS_IP/")"
check_not "ingress :80 does not serve the Caddyfile" \
  grep -q reverse_proxy <<<"$(lan_get $ADMIN_IP "http://$INGRESS_IP/Caddyfile")"
printf '\n# @dashboard Extra | added later\n:8888 {\n\timport common\n\trespond "EXTRA"\n}\n' >>ingress/Caddyfile
docker compose restart as-ingress >/dev/null
for _ in $(seq 1 10); do
  dash=$(lan_get $ADMIN_IP "http://$INGRESS_IP/")
  has_links "$dash" "$INGRESS_IP:8888/" && break
  sleep 1
done
check "a site marked later appears on the dashboard" has_links "$dash" "$INGRESS_IP:8888/"
check_not "as-net-blind -> ingress's inner leg :8080 refused (listens on the VLAN leg only)" \
  attacker "curl -sf --max-time 3 http://$(ipb as-ingress):8080/"
check_not "as-net-blind -> Hermes :9119 directly is dropped (only as-ingress)" \
  attacker "curl -sf --max-time 3 http://$(ipb as-hermes-net):9119/"
check_not "as-net-blind -> Squid's VLAN leg is unreachable" \
  attacker "curl -s --max-time 3 -x http://$(envval PROXY_IP):$PROXY_PORT http://evil.example.com/ -o /dev/null -w '%{http_code}' | grep -q 403"

# --- escape by routing: an as-net-blind container with NET_ADMIN sets a default route
# through each dual-homed container and sends UDP to a LAN host. The host's
# DOCKER-INTERNAL rules would stop it too (when bridged traffic passes iptables), so
# switch that off for the test: the gateways must hold on their own. The control
# (dual-homed, Docker's default ip_forward=1) proves the test can see an escape.
if [ -w "$BRNF" ]; then BRNF_OLD=$(cat "$BRNF"); echo 0 >"$BRNF"; fi
docker run -d --name asbt-lan --network "$VLAN" --ip $LAN_IP "$NETSHOOT" socat -u UDP-RECV:9999 STDOUT >/dev/null
docker run -d --name asbt-ctl --network "$VLAN" --ip 192.19.255.51 "$NETSHOOT" sleep infinity >/dev/null
docker network connect "$BLIND" asbt-ctl
sleep 1
for gw in as-squid as-ingress asbt-ctl; do
  attacker "ip route add default via $(ipb $gw) && echo ESCAPE-$gw | socat -u STDIN UDP-SENDTO:$LAN_IP:9999" || true
done
sleep 1
got=$(docker logs asbt-lan 2>&1)
check "control: a forwarding dual-homed container lets UDP out" grep -q ESCAPE-asbt-ctl <<<"$got"
check_not "no escape through as-squid" grep -q ESCAPE-as-squid <<<"$got"
check_not "no escape through as-ingress" grep -q ESCAPE-as-ingress <<<"$got"

if [ "$FAIL" -gt 0 ]; then
  docker compose ps -a
  docker compose logs --tail 20 as-squid as-ingress as-dns as-netshoot-net as-hermes-net
  echo "run-blind-tests: $FAIL check(s) failed" >&2
  exit 1
fi
echo "run-blind-tests: all checks passed"
