#!/bin/sh
# fw.sh: wspólne regly dla sidecarów sieciowych
#
# Parametry (env):
#   PROXY_IP, PROXY_PORT  adres i port Squida (PROXY wymagany, PORT domyslnie 3128)
#   ALLOW_IN              lista "proto:port[:src]"   np. "tcp:9090:192.19.255.20 tcp:9119:10.0.0.0/8"
#   ALLOW_OUT             lista "proto:dst[:port]"   np. "tcp:192.19.255.20:4000 any:192.19.255.33"
#                         proto: tcp | udp | any (any = caly ruch do dst, bez portu)
#   FW_LOG                1 = loguj odrzucone pakiety (prefiks fw-drop-in / fw-drop-out, w dmesg hosta)
#   /fw.d/*.sh            opcjonalne hooki per kontener, wykonywane po regulach wspólnych
set -eu
rm -f /tmp/ready          # restart kontenera nie może zlosic "ready" przed nalożeniem reul

: "${PROXY_IP:?fw.sh: PROXY_IP nie ustawione}"
PROXY_PORT=${PROXY_PORT:-3128}
ALLOW_IN=${ALLOW_IN:-}
ALLOW_OUT=${ALLOW_OUT:-}
FW_LOG=${FW_LOG:-0}

die() { echo "fw.sh: $*" >&2; exit 1; }

# ---------- wspólne ----------
for C in INPUT OUTPUT FORWARD; do iptables -F "$C"; iptables -P "$C" DROP; done

# Docker embedded DNS zablokowany (musi byc przed regulami dla lo): nazwy rozwiazuje Squid
iptables -A OUTPUT -d 127.0.0.11 -j REJECT
iptables -A INPUT  -s 127.0.0.11 -j DROP

iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

iptables -A OUTPUT -p tcp -d "$PROXY_IP" --dport "$PROXY_PORT" -m conntrack --ctstate NEW -j ACCEPT

# ---------- per kontener: ruch przychodzacy ----------
for e in $ALLOW_IN; do
  IFS=: read -r proto port src <<EOF
$e
EOF
  case $proto in tcp|udp) ;; *) die "ALLOW_IN: wymagany tcp/udp w '$e'" ;; esac
  [ -n "$port" ] || die "ALLOW_IN: brak portu w '$e'"
  iptables -A INPUT -p "$proto" --dport "$port" ${src:+-s "$src"} \
           -m conntrack --ctstate NEW -j ACCEPT
done

# ---------- per kontener: ruch wychodzacy ----------
for e in $ALLOW_OUT; do
  IFS=: read -r proto dst port <<EOF
$e
EOF
  [ -n "$dst" ] || die "ALLOW_OUT: brak adresu w '$e'"
  case $proto in
    any)     [ -z "$port" ] || die "ALLOW_OUT: 'any' nie przyjmuje portu: '$e'"
             iptables -A OUTPUT -d "$dst" -m conntrack --ctstate NEW -j ACCEPT ;;
    tcp|udp) iptables -A OUTPUT -p "$proto" -d "$dst" ${port:+--dport "$port"} \
                      -m conntrack --ctstate NEW -j ACCEPT ;;
    *)       die "ALLOW_OUT: nieznany protokol w '$e'" ;;
  esac
done

# ---------- hooki per kontener ----------
for f in /fw.d/*.sh; do
  [ -e "$f" ] || continue
  echo "fw.sh: hook $f"
  . "$f"
done

# ---------- logowanie odrzuconych (na koncu lanuchów, przed politya DROP) ----------
if [ "$FW_LOG" = 1 ]; then
  iptables -A INPUT  -m limit --limit 10/min -j LOG --log-prefix "fw-drop-in: "
  iptables -A OUTPUT -m limit --limit 10/min -j LOG --log-prefix "fw-drop-out: "
fi

# ---------- IPv6: wszystko zablokowane poza lo ----------
for C in INPUT OUTPUT FORWARD; do
  ip6tables -F "$C" 2>/dev/null || true
  ip6tables -P "$C" DROP 2>/dev/null || true
done
ip6tables -A INPUT  -i lo -j ACCEPT 2>/dev/null || true
ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true

echo "fw.sh: reguly nalożone:"; iptables -S

touch /tmp/ready
trap 'exit 0' TERM INT
sleep infinity & wait

