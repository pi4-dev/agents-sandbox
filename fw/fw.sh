#!/bin/sh
# fw.sh: common rules for the network sidecars
#
# Parameters (env):
#   PROXY_HOST, PROXY_PORT  Squid name (or IP) and port (HOST required, PORT defaults to 3128)
#   DNS_IP                address of as-dns, the only DNS server allowed. fw.sh writes
#                         /etc/resolv.conf (shared with the agent container) and waits
#                         until PROXY_HOST resolves. Without DNS_IP: no DNS, IP addresses only.
#   DNS_SEARCH            search domain (default as.internal)
#   DNS_WAIT              seconds to wait for as-dns (default 30)
#   ALLOW_IN              list of "proto:port[:src]"   e.g. "tcp:9090:litellm.as.internal tcp:9119:10.0.0.0/8"
#                         proto: tcp | udp | icmp | any, no port for icmp and any:
#                         icmp = echo requests only ("icmp::host"), any = all traffic from src ("any::host")
#   ALLOW_OUT             list of "proto:dst[:port]"   e.g. "tcp:litellm.as.internal:4000 any:netshoot.as.internal"
#                         proto: tcp | udp | any (any = all traffic to dst, no port)
#                         Names are resolved when the rules are built (rules hold IP
#                         addresses). A name that does not resolve (its container is not
#                         running) gets no rule, so that traffic stays blocked; see FW_REFRESH.
#   FW_REFRESH            seconds between re-resolving those names (default 30, 0 = never).
#                         Docker assigns container addresses, so a peer may start later or
#                         come back on another IP: when the addresses change, the rules
#                         are rebuilt. While a name does not resolve, it is retried every 2 s.
#   FW_LOG                1 = log dropped packets (prefix fw-drop-in / fw-drop-out) to the kernel log of
#                         the host. The kernel drops LOG output from container namespaces unless
#                         net.netfilter.nf_log_all_netns=1 is set on that host (README, "Firewall drop logs").
#   READY_FILE            readiness marker for the healthcheck (default /tmp/ready)
#   /fw.d/*.sh            optional per-container hooks, run after the common rules
set -eu
READY_FILE=${READY_FILE:-/tmp/ready}
rm -f "$READY_FILE"       # a restarted container must not report "ready" before the rules are in place

: "${PROXY_HOST:?fw.sh: PROXY_HOST is not set}"
PROXY_PORT=${PROXY_PORT:-3128}
DNS_IP=${DNS_IP:-}
DNS_SEARCH=${DNS_SEARCH:-as.internal}
DNS_WAIT=${DNS_WAIT:-30}
ALLOW_IN=${ALLOW_IN:-}
ALLOW_OUT=${ALLOW_OUT:-}
FW_LOG=${FW_LOG:-0}
FW_REFRESH=${FW_REFRESH:-30}

die() { echo "fw.sh: $*" >&2; exit 1; }

# ---------- common ----------
base_rules() {
  for C in INPUT OUTPUT FORWARD; do iptables -F "$C"; iptables -P "$C" DROP; done

  # Docker's embedded DNS is blocked (must come before the lo rules): every lookup goes
  # to as-dns, which logs it. On an internal network Docker does not forward queries to
  # the host's DNS, but the agent must not depend on that.
  iptables -A OUTPUT -d 127.0.0.11 -j REJECT
  iptables -A INPUT  -s 127.0.0.11 -j DROP

  iptables -A INPUT  -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
  # anti-spoofing: an outgoing packet must carry an address of this namespace. Otherwise a
  # process with CAP_NET_RAW could pose as another container (e.g. LiteLLM towards the bridge).
  iptables -A OUTPUT -m addrtype ! --src-type LOCAL -j DROP
  iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # ---------- DNS: as-dns only ----------
  if [ -n "$DNS_IP" ]; then
    for p in udp tcp; do
      iptables -A OUTPUT -p "$p" -d "$DNS_IP" --dport 53 -m conntrack --ctstate NEW -j ACCEPT
    done
  fi
}

# peer <name|address|network>: true if iptables can use it now; logs a name that does not resolve
peer() {
  case $1 in *[!0-9./]*) ;; *) return 0 ;; esac
  getent ahostsv4 "$1" >/dev/null 2>&1 && return 0
  echo "fw.sh: $1 does not resolve (not running?), no rule for it yet" >&2
  return 1
}

# rules naming other containers; the refresh loop rebuilds them when addresses change
peer_rules() {
  iptables -A OUTPUT -p tcp -d "$PROXY_HOST" --dport "$PROXY_PORT" -m conntrack --ctstate NEW -j ACCEPT

  # ---------- per container: inbound traffic ----------
  for e in $ALLOW_IN; do
    IFS=: read -r proto port src <<EOF
$e
EOF
    case $proto in
      tcp|udp) [ -n "$port" ] || die "ALLOW_IN: missing port in '$e'" ;;
      icmp|any) [ -z "$port" ] || die "ALLOW_IN: $proto takes no port ('$proto::src'): '$e'" ;;
      *)       die "ALLOW_IN: tcp, udp, icmp or any required in '$e'" ;;
    esac
    [ "$proto" != any ] || [ -n "$src" ] || die "ALLOW_IN: 'any' needs a source ('any::src'): '$e'"
    if [ -n "$src" ] && ! peer "$src"; then continue; fi
    if [ "$proto" = icmp ]; then
      iptables -A INPUT -p icmp --icmp-type echo-request ${src:+-s "$src"} -m conntrack --ctstate NEW -j ACCEPT
    elif [ "$proto" = any ]; then
      iptables -A INPUT -s "$src" -m conntrack --ctstate NEW -j ACCEPT
    else
      iptables -A INPUT -p "$proto" --dport "$port" ${src:+-s "$src"} \
               -m conntrack --ctstate NEW -j ACCEPT
    fi
  done

  # ---------- per container: outbound traffic ----------
  for e in $ALLOW_OUT; do
    IFS=: read -r proto dst port <<EOF
$e
EOF
    [ -n "$dst" ] || die "ALLOW_OUT: missing address in '$e'"
    case $proto in any|tcp|udp) peer "$dst" || continue ;; esac
    case $proto in
      any)     [ -z "$port" ] || die "ALLOW_OUT: 'any' takes no port: '$e'"
               iptables -A OUTPUT -d "$dst" -m conntrack --ctstate NEW -j ACCEPT ;;
      tcp|udp) iptables -A OUTPUT -p "$proto" -d "$dst" ${port:+--dport "$port"} \
                        -m conntrack --ctstate NEW -j ACCEPT ;;
      *)       die "ALLOW_OUT: unknown protocol in '$e'" ;;
    esac
  done

  # ---------- per-container hooks ----------
  for f in /fw.d/*.sh; do
    [ -e "$f" ] || continue
    echo "fw.sh: hook $f"
    # shellcheck source=/dev/null
    . "$f"
  done

  # ---------- log dropped packets (end of the chains, before the DROP policy) ----------
  if [ "$FW_LOG" = 1 ]; then
    iptables -A INPUT  -m limit --limit 10/min -j LOG --log-prefix "fw-drop-in: "
    iptables -A OUTPUT -m limit --limit 10/min -j LOG --log-prefix "fw-drop-out: "
  fi
}

# resolved: one "name=addr,addr," line per host name in the rules ("name=" if it does not resolve)
resolved() {
  {
    echo "$PROXY_HOST"
    for e in $ALLOW_IN; do
      IFS=: read -r _ _ src <<EOF
$e
EOF
      echo "$src"
    done
    for e in $ALLOW_OUT; do
      IFS=: read -r _ dst _ <<EOF
$e
EOF
      echo "$dst"
    done
  } | grep -vE '^([0-9.]+(/[0-9]+)?)?$' | sort -u | while read -r n; do
    printf '%s=%s\n' "$n" "$(getent ahostsv4 "$n" | awk '{print $1}' | sort -u | tr '\n' ,)"
  done
}

base_rules
if [ -n "$DNS_IP" ]; then
  printf 'nameserver %s\nsearch %s\noptions timeout:2 attempts:2\n' "$DNS_IP" "$DNS_SEARCH" >/etc/resolv.conf
  i=0
  until getent hosts "$PROXY_HOST" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt "$DNS_WAIT" ] || die "cannot resolve $PROXY_HOST via $DNS_IP (is as-dns running?)"
    sleep 1
  done
fi
# build_peer_rules: rules from the current addresses; $state = the addresses they were built
# from ("!" when a name changed while building, so the next round rebuilds)
build_peer_rules() {
  state=$(resolved)
  peer_rules
  [ "$(resolved)" = "$state" ] || state='!'
}
build_peer_rules

# ---------- IPv6: everything blocked except lo (fail-closed) ----------
# When ip6tables does not work, report ready only if the namespace has no IPv6
# address besides lo (IPv6 disabled); otherwise IPv6 would be open behind a
# green healthcheck.
ipv6_active() {
  [ -r /proc/net/if_inet6 ] && awk '$6 != "lo" { found = 1 } END { exit !found }' /proc/net/if_inet6
}
if ip6tables -S >/dev/null 2>&1; then
  for C in INPUT OUTPUT FORWARD; do ip6tables -F "$C"; ip6tables -P "$C" DROP; done
  ip6tables -A INPUT  -i lo -j ACCEPT
  ip6tables -A OUTPUT -o lo -j ACCEPT
elif ipv6_active; then
  die "ip6tables does not work but interfaces have IPv6 addresses; refusing to report ready"
else
  echo "fw.sh: ip6tables unavailable, IPv6 inactive in this namespace; skipping"
fi

echo "fw.sh: rules applied:"; iptables -S
ip6tables -S 2>/dev/null || true

touch "$READY_FILE"
trap 'exit 0' TERM INT
if [ "$FW_REFRESH" -le 0 ]; then
  sleep infinity & wait
  exit 0
fi

# ---------- follow peer addresses (Docker assigns them) ----------
while :; do
  wait_for=$FW_REFRESH
  if [ "$FW_REFRESH" -gt 2 ] && { [ "$state" = '!' ] || printf '%s\n' "$state" | grep -q '=$'; }; then
    wait_for=2
  fi
  sleep "$wait_for" & wait $!
  new=$(resolved)
  [ "$new" != "$state" ] || continue
  # the proxy unresolvable for a moment (Squid being recreated): keep the rules until it is back
  if printf '%s\n' "$new" | grep -qx "$PROXY_HOST="; then continue; fi
  echo "fw.sh: peer addresses changed, rebuilding the rules: $(echo "$new" | tr '\n' ' ')"
  base_rules
  build_peer_rules
done
