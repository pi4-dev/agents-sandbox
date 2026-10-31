#!/bin/bash
# Permitted/blocked traffic test for fw/fw.sh in real network namespaces.
#
# Topology: namespace "agent" (runs fw.sh) <-veth-> namespace "lan" holding the
# proxy (10.98.0.10:3128), LiteLLM (10.98.0.20:4000), another LAN host
# (10.98.0.30) and IPv6 (fd98::1). Each scenario starts from fresh namespaces.
# IPv6 checks are skipped when the kernel has no IPv6 stack. The DNS scenarios use
# tests/fw/fakedns.py on 10.98.0.53 in place of as-dns; `ip netns exec` gives the
# agent namespace its own /etc/resolv.conf (/etc/netns/fwt-agent/resolv.conf).
#
# Needs root, iproute2, iptables/ip6tables and python3.
#
# Usage: sudo tests/fw/run-fw-tests.sh [path/to/fw.sh]
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
FW=$(realpath "${1:-$REPO/fw/fw.sh}")
PROBE=$REPO/tests/fw/netprobe.py
FAKEDNS=$REPO/tests/fw/fakedns.py
A=fwt-agent
L=fwt-lan
PROXY=10.98.0.10 LITELLM=10.98.0.20 OTHER=10.98.0.30 GW=10.98.0.1 AGENT=10.98.0.2 DNS=10.98.0.53

[ "$(id -u)" = 0 ] || { echo "run-fw-tests: run as root" >&2; exit 2; }
HAVE_V6=0
[ -d /proc/sys/net/ipv6 ] && HAVE_V6=1

W=$(mktemp -d)
FW_PID=
teardown() {
  if [ -n "$FW_PID" ]; then kill "$FW_PID" 2>/dev/null || true; wait "$FW_PID" 2>/dev/null || true; fi
  FW_PID=
  for ns in $A $L; do
    ip netns pids "$ns" 2>/dev/null | xargs -r kill 2>/dev/null || true
    ip netns del "$ns" 2>/dev/null || true
  done
}
trap 'teardown; rm -rf "$W" /etc/netns/$A' EXIT
mkdir -p /etc/netns/$A

setup() {
  teardown
  ip netns add $A
  ip netns add $L
  ip link add fwt-a0 type veth peer name fwt-l0
  ip link set fwt-a0 netns $A name a0
  ip link set fwt-l0 netns $L name l0
  ip -n $A link set lo up
  ip -n $L link set lo up
  ip -n $A addr add $AGENT/24 dev a0
  for ip in $GW $PROXY $LITELLM $OTHER $DNS; do ip -n $L addr add "$ip/24" dev l0; done
  echo "nameserver 127.0.0.1" >/etc/netns/$A/resolv.conf
  local v6_listen=()
  if [ $HAVE_V6 = 1 ]; then
    ip netns exec $A sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.a0.disable_ipv6=0
    ip netns exec $L sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.l0.disable_ipv6=0
    ip -n $A -6 addr add fd98::2/64 dev a0 nodad
    ip -n $L -6 addr add fd98::1/64 dev l0 nodad
    v6_listen=("[fd98::1]:3128")
  fi
  ip -n $A link set a0 up
  ip -n $L link set l0 up

  ip netns exec $L python3 "$PROBE" listen tcp $PROXY:3128 $PROXY:80 $LITELLM:4000 $LITELLM:5432 \
    $OTHER:22 $OTHER:80 "${v6_listen[@]}" &
  ip netns exec $L python3 "$PROBE" listen udp $GW:53 $GW:5353 &
  ip netns exec $A python3 "$PROBE" listen tcp 0.0.0.0:9090 0.0.0.0:22 127.0.0.1:7000 &
  ip netns exec $A python3 "$PROBE" listen udp 127.0.0.11:53 &
  sleep 0.5
}

# start_fw <extra env...>: runs fw.sh in the agent namespace, waits for ready or exit
start_fw() {
  rm -f "$W/ready"
  ip netns exec $A env PATH="${FW_PATH:-$PATH}" READY_FILE="$W/ready" PROXY_HOST=$PROXY PROXY_PORT=3128 "$@" \
    sh "$FW" >"$W/fw.log" 2>&1 &
  FW_PID=$!
  for _ in $(seq 1 50); do
    [ -f "$W/ready" ] && return 0
    kill -0 "$FW_PID" 2>/dev/null || { wait "$FW_PID" 2>/dev/null || true; FW_PID=; return 1; }
    sleep 0.1
  done
  return 1
}

FAIL=0
result() { # result <PASS|FAIL|SKIP> <text>
  printf '%s  %s\n' "$1" "$2"
  [ "$1" != FAIL ] || FAIL=$((FAIL + 1))
}
# expect <allow|deny> <name> <ns> <netprobe connect args... | ping HOST [--src IP]>
expect() {
  local want=$1 name=$2 ns=$3 got
  shift 3
  local cmd=connect
  if [ "$1" = ping ]; then cmd=ping; shift; fi
  if ip netns exec "$ns" python3 "$PROBE" "$cmd" "$@"; then got=allow; else got=deny; fi
  if [ "$got" = "$want" ]; then result PASS "$(printf '%-5s %s' "$got" "$name")"
  else result FAIL "$(printf '%-5s %s (expected %s)' "$got" "$name" "$want")"; fi
}

echo "== scenario 1: agent rules (ALLOW_IN from LiteLLM, ALLOW_OUT to LiteLLM + one UDP port)"
setup
if start_fw ALLOW_IN="tcp:9090:$LITELLM" ALLOW_OUT="tcp:$LITELLM:4000 udp:$GW:5353" FW_LOG=1; then
  result PASS "fw.sh reports ready"
  expect allow "egress to proxy port"               $A tcp $PROXY 3128
  expect deny  "egress to proxy, other port"        $A tcp $PROXY 80
  expect allow "egress ALLOW_OUT tcp LiteLLM:4000"  $A tcp $LITELLM 4000
  expect deny  "egress LiteLLM other port"          $A tcp $LITELLM 5432
  expect deny  "egress SSH to LAN host"             $A tcp $OTHER 22
  expect deny  "egress direct HTTP to LAN host"     $A tcp $OTHER 80
  expect allow "egress ALLOW_OUT udp :5353"         $A udp $GW 5353
  expect deny  "egress DNS udp to gateway"          $A udp $GW 53
  expect deny  "Docker embedded DNS 127.0.0.11"     $A udp 127.0.0.11 53
  expect allow "loopback inside namespace"          $A tcp 127.0.0.1 7000
  if [ $HAVE_V6 = 1 ]; then expect deny "egress IPv6 to proxy port" $A tcp fd98::1 3128
  else result SKIP "egress IPv6 to proxy port (no IPv6 in kernel)"; fi
  expect allow "ingress :9090 from LiteLLM"         $L tcp $AGENT 9090 --src $LITELLM
  expect deny  "ingress :9090 from other host"      $L tcp $AGENT 9090 --src $OTHER
  expect deny  "ingress :22 from LiteLLM"           $L tcp $AGENT 22 --src $LITELLM
else
  result FAIL "fw.sh reports ready"; cat "$W/fw.log"
fi

echo "== scenario 2: ip6tables broken while IPv6 is active -> must not report ready"
setup
mkdir -p "$W/shim"
printf '#!/bin/sh\nexit 1\n' >"$W/shim/ip6tables"
chmod +x "$W/shim/ip6tables"
if [ $HAVE_V6 = 0 ]; then
  result SKIP "fw.sh refuses ready (no IPv6 in kernel)"
elif FW_PATH="$W/shim:$PATH" start_fw; then
  result FAIL "fw.sh refuses ready (it reported ready)"
  expect deny "egress IPv6 to proxy port" $A tcp fd98::1 3128
else
  result PASS "fw.sh refuses ready"
fi

echo "== scenario 3: ip6tables broken, IPv6 disabled in the namespace -> ready"
setup
if [ $HAVE_V6 = 1 ]; then
  ip netns exec $A sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 \
    net.ipv6.conf.a0.disable_ipv6=1 net.ipv6.conf.lo.disable_ipv6=1
fi
if FW_PATH="$W/shim:$PATH" start_fw; then
  result PASS "fw.sh reports ready"
  expect allow "egress to proxy port" $A tcp $PROXY 3128
  expect deny  "egress SSH to LAN host" $A tcp $OTHER 22
else
  result FAIL "fw.sh reports ready"; cat "$W/fw.log"
fi

echo "== scenario 4: malformed ALLOW_IN -> must not report ready"
setup
if start_fw ALLOW_IN="icmp:1"; then result FAIL "fw.sh rejects ALLOW_IN=icmp:1"
else result PASS "fw.sh rejects ALLOW_IN=icmp:1"; fi

echo "== scenario 5: names via as-dns (PROXY_HOST, ALLOW_IN/ALLOW_OUT by name)"
setup
FAKEDNS_LOG=$W/dns.log ip netns exec $L python3 "$FAKEDNS" $DNS \
  proxy.as.internal=$PROXY litellm.as.internal=$LITELLM &
sleep 0.3
# control: before fw.sh a forged source address reaches the DNS server (in Docker the
# forged address would be the proxy's; here that one is local to the lan namespace)
ip netns exec $A python3 "$PROBE" spoof 10.98.0.77 $DNS spoof-before.attacker.example
if start_fw PROXY_HOST=proxy.as.internal DNS_IP=$DNS DNS_WAIT=5 \
     ALLOW_IN="tcp:9090:litellm.as.internal" ALLOW_OUT="tcp:litellm.as.internal:4000"; then
  result PASS "fw.sh reports ready"
  if grep -qx "nameserver $DNS" /etc/netns/$A/resolv.conf && grep -qx "search as.internal" /etc/netns/$A/resolv.conf; then
    result PASS "resolv.conf points at as-dns with search as.internal"
  else
    result FAIL "resolv.conf points at as-dns with search as.internal"; cat /etc/netns/$A/resolv.conf
  fi
  if [ "$(ip netns exec $A getent hosts proxy | awk '{print $1}')" = $PROXY ]; then
    result PASS "short name 'proxy' resolves inside the namespace"
  else result FAIL "short name 'proxy' resolves inside the namespace"; fi
  if ip netns exec $A getent hosts exfil-data.attacker.example >/dev/null; then
    result FAIL "external name does not resolve"
  else result PASS "external name does not resolve"; fi
  if grep -q ' exfil-data.attacker.example$' "$W/dns.log"; then result PASS "as-dns logged the external query"
  else result FAIL "as-dns logged the external query"; fi
  ip netns exec $A python3 "$PROBE" spoof 10.98.0.77 $DNS spoof-after.attacker.example || true
  sleep 0.5
  if grep -q ' spoof-before.attacker.example$' "$W/dns.log" && ! grep -q ' spoof-after.attacker.example$' "$W/dns.log"; then
    result PASS "forged source address is dropped (control without fw.sh got through)"
  else
    result FAIL "forged source address is dropped"; cat "$W/dns.log"
  fi
  expect allow "egress to proxy (by name)"          $A tcp $PROXY 3128
  expect allow "egress ALLOW_OUT by name"           $A tcp $LITELLM 4000
  expect deny  "egress LiteLLM other port"          $A tcp $LITELLM 5432
  expect deny  "DNS to another server (gateway)"    $A udp $GW 53
  expect allow "ingress ALLOW_IN by name"           $L tcp $AGENT 9090 --src $LITELLM
  expect deny  "ingress from other host"            $L tcp $AGENT 9090 --src $OTHER
else
  result FAIL "fw.sh reports ready"; cat "$W/fw.log"
fi

echo "== scenario 6: as-dns down -> must not report ready"
setup
if start_fw PROXY_HOST=proxy.as.internal DNS_IP=$DNS DNS_WAIT=3; then
  result FAIL "fw.sh refuses ready without DNS"
else
  result PASS "fw.sh refuses ready without DNS"
fi

echo "== scenario 7: peers start later or come back on another address -> rules follow the name"
setup
ip netns exec $L python3 "$FAKEDNS" $DNS proxy.as.internal=$PROXY &
DNS_PID=$!
sleep 0.3
# restart_dns <records...>: the peer containers changed (Docker DNS answers differently)
restart_dns() {
  kill "$DNS_PID"; wait "$DNS_PID" 2>/dev/null || true
  ip netns exec $L python3 "$FAKEDNS" $DNS proxy.as.internal=$PROXY "$@" &
  DNS_PID=$!
  local n
  n=$(grep -c 'rebuilding the rules' "$W/fw.log" || true)
  for _ in $(seq 1 50); do [ "$(grep -c 'rebuilding the rules' "$W/fw.log" || true)" -gt "$n" ] && break; sleep 0.1; done
  sleep 0.3
}
if start_fw PROXY_HOST=proxy.as.internal DNS_IP=$DNS DNS_WAIT=5 FW_REFRESH=1 \
     ALLOW_IN="tcp:9090:litellm.as.internal" ALLOW_OUT="tcp:litellm.as.internal:4000"; then
  result PASS "fw.sh reports ready while LiteLLM is not running yet"
  expect allow "egress to proxy"                        $A tcp $PROXY 3128
  expect deny  "ingress from LiteLLM's future address"  $L tcp $AGENT 9090 --src $LITELLM
  restart_dns litellm.as.internal=$LITELLM               # LiteLLM started
  expect allow "ingress from LiteLLM once it resolves"  $L tcp $AGENT 9090 --src $LITELLM
  expect allow "egress to LiteLLM once it resolves"     $A tcp $LITELLM 4000
  expect deny  "ingress from the other host"            $L tcp $AGENT 9090 --src $OTHER
  restart_dns litellm.as.internal=$OTHER                 # LiteLLM recreated on another address
  expect allow "ingress from LiteLLM (new address)"     $L tcp $AGENT 9090 --src $OTHER
  expect deny  "ingress from the old address"           $L tcp $AGENT 9090 --src $LITELLM
  expect deny  "egress to the old LiteLLM address"      $A tcp $LITELLM 4000
  restart_dns                                            # LiteLLM stopped
  expect deny  "ingress from LiteLLM's last address"    $L tcp $AGENT 9090 --src $OTHER
  expect allow "egress to proxy still allowed"          $A tcp $PROXY 3128
else
  result FAIL "fw.sh reports ready"; cat "$W/fw.log"
fi

echo "== scenario 8: netshoot-style sidecar (everything out to its network, nothing in)"
setup
if start_fw ALLOW_OUT="any:10.98.0.0/24"; then
  result PASS "fw.sh reports ready"
  expect allow "egress any: TCP to a LAN host port"     $A tcp $OTHER 22
  expect allow "egress any: TCP to another port"        $A tcp $LITELLM 5432
  expect allow "egress any: UDP"                        $A udp $GW 53
  expect allow "egress any: ping"                       $A ping $OTHER
  expect deny  "egress outside the network"             $A tcp 10.97.0.1 80
  expect deny  "ingress TCP from the network"           $L tcp $AGENT 9090 --src $LITELLM
  expect deny  "ingress ping from the network"          $L ping $AGENT --src $LITELLM
else
  result FAIL "fw.sh reports ready"; cat "$W/fw.log"
fi

echo "== scenario 9: the side of a target: everything from the diagnostics host (any::), ping only (icmp::)"
setup
if start_fw ALLOW_IN="any::$LITELLM icmp::$GW"; then
  result PASS "fw.sh reports ready"
  expect allow "ingress any:: TCP :9090"                $L tcp $AGENT 9090 --src $LITELLM
  expect allow "ingress any:: TCP :22"                  $L tcp $AGENT 22 --src $LITELLM
  expect allow "ingress any:: ping"                     $L ping $AGENT --src $LITELLM
  expect allow "ingress icmp:: ping"                    $L ping $AGENT --src $GW
  expect deny  "ingress icmp:: TCP is not allowed"      $L tcp $AGENT 9090 --src $GW
  expect deny  "ingress from another host"              $L tcp $AGENT 9090 --src $OTHER
  expect deny  "ingress ping from another host"         $L ping $AGENT --src $OTHER
else
  result FAIL "fw.sh reports ready"; cat "$W/fw.log"
fi

echo "== scenario 10: malformed icmp/any entries -> must not report ready"
for bad in "icmp:8:$LITELLM" "any:80:$LITELLM" "any::"; do
  setup
  if start_fw ALLOW_IN="$bad"; then result FAIL "fw.sh rejects ALLOW_IN=$bad"
  else result PASS "fw.sh rejects ALLOW_IN=$bad"; fi
done

if [ "$FAIL" -gt 0 ]; then
  echo "run-fw-tests: $FAIL check(s) failed" >&2
  exit 1
fi
echo "run-fw-tests: all checks passed"
