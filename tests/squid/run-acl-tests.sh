#!/bin/bash
# Offline allow/deny regression test for the Squid ACLs and SSL-bump policy.
#
# Runs the real squid binary with squid/conf (paths remapped into a temp dir)
# in front of a fake upstream on 127.0.0.1. Squid's hosts_file maps every test
# hostname to the fake upstream, so nothing leaves the machine. A request counts
# as ALLOWED only when the fake upstream answered it.
#
# Needs root (binds :80/:443/:3128, adds addresses on lo), squid-openssl,
# openssl, curl, python3 and iproute2.
#
# Without an argument it tests the tracked squid/conf/*.example files (what a fresh
# checkout gets); with a directory, the files in it (e.g. your squid/conf copies).
#
# Usage: sudo tests/squid/run-acl-tests.sh [squid-conf-dir]
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
CONF_DIR=$(cd "${1:-$REPO/squid/conf}" && pwd)
EXAMPLES=1
[ -n "${1:-}" ] && EXAMPLES=0
ERRORS_DIR=$REPO/squid/errors
BLIND_NET=172.31.250.0/24  # BLIND_SUBNET in .env.example
LLM_NET=172.31.251.0/24    # LLM_EGRESS_SUBNET: LiteLLM <-> Squid only
CLIENT_IP=172.31.250.130   # agent address inside localnet (as-net-blind)
LLM_LEG=172.31.251.2       # Squid's own address on as-net-litellm-egress
LITELLM_IP=172.31.251.10   # LiteLLM on as-net-litellm-egress: the only client of llm_api_domains.txt
OUTSIDE_IP=172.31.1.10     # inside a /16 around the networks, outside both /24s
PTR_IP=127.0.0.2           # address whose reverse name is an allowlisted host
BADCERT_IP=127.0.0.3       # upstream with a certificate Squid does not trust
NAMES=(api.anthropic.com claude.ai claude.com platform.claude.com statsig.anthropic.com
       code.claude.com github.com api.github.com raw.githubusercontent.com
       objects.githubusercontent.com ftp.pl.debian.org security.debian.org evil.example.com
       openrouter.ai llm.lan.internal pypi.org files.pythonhosted.org upload.pypi.org)

[ "$(id -u)" = 0 ] || { echo "run-acl-tests: run as root" >&2; exit 2; }

W=$(mktemp -d)
chmod 755 "$W"
SQUID_PID=
UP_PID=
BAD_PID=
LAN_PID=
cleanup() {
  if [ -n "$SQUID_PID" ]; then kill "$SQUID_PID" 2>/dev/null || true; wait "$SQUID_PID" 2>/dev/null || true; fi
  if [ -n "$UP_PID" ]; then kill "$UP_PID" 2>/dev/null || true; fi
  if [ -n "$BAD_PID" ]; then kill "$BAD_PID" 2>/dev/null || true; fi
  if [ -n "$LAN_PID" ]; then kill "$LAN_PID" 2>/dev/null || true; fi
  ip addr del "$CLIENT_IP/32" dev lo 2>/dev/null || true
  ip addr del "$OUTSIDE_IP/32" dev lo 2>/dev/null || true
  ip addr del "$LITELLM_IP/32" dev lo 2>/dev/null || true
  ip addr del "$LLM_LEG/32" dev lo 2>/dev/null || true
  rm -rf "$W"
}
trap cleanup EXIT

# --- layout mirroring the container: /etc/squid/{conf,errors,ssl}, /var/lib/squid
mkdir -p "$W/etc/conf" "$W/etc/errors" "$W/etc/ssl" "$W/lib" "$W/log"
printf '%s\n' "$BLIND_NET" "$LLM_NET" >"$W/lib/localnet.txt"  # what entrypoint.sh writes from SQUID_LOCALNET
echo "$LLM_NET" >"$W/lib/litellm_net.txt"                     # ... from SQUID_LITELLM_NET
echo "dns_nameservers 127.0.0.1" >"$W/lib/dns.conf"            # ... from SQUID_DNS_UPSTREAM
if [ $EXAMPLES = 1 ]; then
  for f in "$CONF_DIR"/*.example; do cp "$f" "$W/etc/conf/$(basename "${f%.example}")"; done
else
  cp "$CONF_DIR"/* "$W/etc/conf/"
fi
cp "$ERRORS_DIR"/* "$W/etc/errors/"
CONF=$W/etc/conf/squid.conf
sed -i -e "s#/etc/squid/#$W/etc/#g" -e "s#/var/lib/squid/#$W/lib/#g" "$CONF"

# --- proxy CA (what ssl/init_ca.sh creates) and a CA + cert for the fake upstream
openssl req -x509 -new -nodes -sha256 -days 2 -newkey rsa:2048 -subj "/CN=Test Proxy CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout "$W/etc/ssl/squid-ca.key" -out "$W/etc/ssl/squid-ca.crt" 2>/dev/null
openssl req -x509 -new -nodes -sha256 -days 2 -newkey rsa:2048 -subj "/CN=Test Upstream CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout "$W/upstream-ca.key" -out "$W/upstream-ca.crt" 2>/dev/null
san=$(printf 'DNS:%s,' "${NAMES[@]}" registry.npmjs.org); san=${san%,}
openssl req -new -nodes -newkey rsa:2048 -subj "/CN=upstream" \
  -keyout "$W/upstream.key" -out "$W/upstream.csr" 2>/dev/null
openssl x509 -req -sha256 -days 2 -in "$W/upstream.csr" -CA "$W/upstream-ca.crt" -CAkey "$W/upstream-ca.key" \
  -CAcreateserial -extfile <(echo "subjectAltName=$san") -out "$W/upstream.crt" 2>/dev/null
openssl req -x509 -new -nodes -sha256 -days 2 -newkey rsa:2048 -subj "/CN=statsig.anthropic.com" \
  -addext "subjectAltName=DNS:statsig.anthropic.com" -keyout "$W/bad.key" -out "$W/bad.crt" 2>/dev/null

# --- name resolution: everything -> fake upstream; PTR_IP reverse-resolves to npm;
#     statsig.anthropic.com -> upstream with an untrusted (self-signed) certificate
{
  echo "127.0.0.1 localhost ${NAMES[*]/statsig.anthropic.com}"
  echo "$PTR_IP registry.npmjs.org"
  echo "$BADCERT_IP statsig.anthropic.com"
} > "$W/hosts"

cat >> "$CONF" <<EOF

# ---- test overlay (tests/squid/run-acl-tests.sh) ----
access_log stdio:$W/log/access.log
cache_log $W/log/cache.log
pid_filename $W/squid.pid
hosts_file $W/hosts
dns_nameservers 127.0.0.1
dns_timeout 2 seconds
connect_timeout 3 seconds
tls_outgoing_options cafile=$W/upstream-ca.crt
EOF

/usr/lib/squid/security_file_certgen -c -s "$W/lib/ssl_db" -M 16MB >/dev/null
chown -R proxy:proxy "$W/lib" "$W/log"
chown proxy:proxy "$W/etc/ssl/squid-ca.key"
chmod 400 "$W/etc/ssl/squid-ca.key"
chmod -R a+rX "$W/etc" "$W/hosts" "$W/upstream-ca.crt"

ip addr add "$CLIENT_IP/32" dev lo 2>/dev/null || true
ip addr add "$OUTSIDE_IP/32" dev lo 2>/dev/null || true
ip addr add "$LITELLM_IP/32" dev lo 2>/dev/null || true
ip addr add "$LLM_LEG/32" dev lo 2>/dev/null || true

python3 "$REPO/tests/squid/upstream.py" --addr 127.0.0.1 --addr "$PTR_IP" \
  --cert "$W/upstream.crt" --key "$W/upstream.key" &
UP_PID=$!
python3 "$REPO/tests/squid/upstream.py" --addr "$BADCERT_IP" --cert "$W/bad.crt" --key "$W/bad.key" &
BAD_PID=$!
# a LAN LLM server on a port other than 80/443 (llm.lan.internal -> 127.0.0.1)
python3 "$REPO/tests/squid/upstream.py" --addr 127.0.0.1 --http-port 8000 --https-port 8443 \
  --cert "$W/upstream.crt" --key "$W/upstream.key" &
LAN_PID=$!

squid -k parse -f "$CONF" >"$W/log/parse.log" 2>&1 || { cat "$W/log/parse.log"; exit 1; }
squid -N -f "$CONF" >"$W/log/stderr.log" 2>&1 &
SQUID_PID=$!

for _ in $(seq 1 50); do
  curl -s -o /dev/null --max-time 1 http://127.0.0.1:3128/ && break
  kill -0 "$SQUID_PID" 2>/dev/null || { echo "squid exited:"; tail -20 "$W/log/cache.log" "$W/log/stderr.log"; exit 1; }
  sleep 0.2
done

FAIL=0
# precondition: the untrusted upstream is up, so a deny for it can only come from certificate checks
if curl -sk --noproxy '*' --max-time 5 --resolve "statsig.anthropic.com:443:$BADCERT_IP" \
     https://statsig.anthropic.com/ | grep -q '^UPSTREAM-OK'; then
  echo "PASS  precondition: untrusted upstream answers directly"
else
  echo "FAIL  precondition: untrusted upstream answers directly"; FAIL=$((FAIL + 1))
fi

# check <allow|deny> <name> <method> <url> [extra curl args]
# PROXY_ADDR: the Squid address the client connects to (default: the as-net-blind leg)
check() {
  local expect=$1 name=$2 method=$3 url=$4 out code got data=()
  shift 4
  case $method in POST|PUT|PATCH) data=(--data x) ;; esac
  out=$(curl -sS --path-as-is --max-time 10 --proxy "http://${PROXY_ADDR:-127.0.0.1}:3128" --noproxy '' \
          --cacert "$W/etc/ssl/squid-ca.crt" --interface "$CLIENT_IP" \
          -X "$method" "${data[@]}" -o - -w '\n%{http_code}' "$@" "$url" 2>&1) || true
  code=${out##*$'\n'}
  if grep -q '^UPSTREAM-OK' <<<"$out"; then got=allow; else got=deny; fi
  if [ "$got" = "$expect" ]; then
    printf 'PASS  %-5s  %3s  %s\n' "$got" "$code" "$name"
  else
    printf 'FAIL  %-5s  %3s  %s (expected %s)\n' "$got" "$code" "$name" "$expect"
    FAIL=$((FAIL + 1))
  fi
}

check allow "Anthropic API"                        GET    https://api.anthropic.com/v1/models
check allow "Anthropic API POST /v1/messages"      POST   https://api.anthropic.com/v1/messages
check allow "claude.ai"                            GET    https://claude.ai/
check allow "npm metadata (npm install)"           GET    https://registry.npmjs.org/left-pad
check allow "npm audit POST (npm install)"         POST   https://registry.npmjs.org/-/npm/v1/security/advisories/bulk
check deny  "npm publish (PUT)"                    PUT    https://registry.npmjs.org/some-pkg
check deny  "npm unpublish (DELETE)"               DELETE https://registry.npmjs.org/some-pkg/-rev/1-abc
check deny  "npm login (POST)"                     POST   https://registry.npmjs.org/-/v1/login
check allow "PyPI index (pip install)"             GET    https://pypi.org/simple/eclipse-zenoh/
check allow "PyPI files (pip install)"             GET    https://files.pythonhosted.org/packages/ab/cd/eclipse_zenoh.whl
check deny  "PyPI POST"                            POST   https://pypi.org/account/login/
check deny  "PyPI files PUT"                       PUT    https://files.pythonhosted.org/packages/x
check deny  "PyPI upload (upload.pypi.org)"        POST   https://upload.pypi.org/legacy/
check deny  "domain not on allowlist (https)"      GET    https://evil.example.com/
check deny  "domain not on allowlist (http)"       GET    http://evil.example.com/
check deny  "Host header differs from CONNECT"     GET    https://api.anthropic.com/ -H "Host: evil.example.com"
check deny  "CONNECT to port other than 443"       GET    https://api.anthropic.com:8443/
check deny  "upstream certificate not trusted"     GET    https://statsig.anthropic.com/
check allow "GitHub allowed org (web)"             GET    https://github.com/Azure/repo
check allow "GitHub allowed org (API)"             GET    https://api.github.com/repos/Azure/repo
check allow "raw.githubusercontent allowed org"    GET    https://raw.githubusercontent.com/Azure/x/main/f
check allow "git fetch (git-upload-pack)"          POST   https://github.com/Azure/repo.git/git-upload-pack
check deny  "git push (git-receive-pack)"          POST   https://github.com/Azure/repo.git/git-receive-pack
check deny  "GitHub other org (web)"               GET    https://github.com/otherorg/repo
check deny  "GitHub other org (API)"               GET    https://api.github.com/repos/otherorg/repo
check deny  "GitHub API outside /repos/<org>"      GET    https://api.github.com/user
check deny  "GitHub API write"                     POST   https://api.github.com/repos/Azure/repo/issues
check deny  "githubusercontent host not listed"    GET    https://objects.githubusercontent.com/x
check deny  "path traversal /../"                  GET    https://github.com/Azure/../otherorg/repo
check deny  "path traversal %2e%2e"                GET    https://github.com/Azure/%2e%2e/otherorg/repo
check deny  "path traversal ..%2f"                 GET    https://github.com/Azure/..%2fotherorg/repo
# Cloudflare's /cdn-cgi/trace echoes the client's (the proxy's) public address. Each variant
# below reached it on api.anthropic.com: Cloudflare decodes %XX of unreserved characters,
# turns \ into /, merges slashes and drops dot segments.
check deny  "Cloudflare /cdn-cgi/trace"            GET    https://api.anthropic.com/cdn-cgi/trace
check deny  "/cdn-cgi/ on claude.ai"               GET    https://claude.ai/cdn-cgi/trace
check deny  "/cdn-cgi/ on npm"                     GET    https://registry.npmjs.org/cdn-cgi/trace
check deny  "/cdn-cgi/ as /%63dn-cgi/"             GET    https://api.anthropic.com/%63dn-cgi/trace
check deny  "/cdn-cgi/ as /cdn%2Dcgi/"             GET    https://api.anthropic.com/cdn%2Dcgi/trace
check deny  "/cdn-cgi/ fully encoded"              GET    https://api.anthropic.com/%63%64%6E%2D%63%67%69/%74%72%61%63%65
check deny  "/cdn-cgi/ after //"                   GET    https://api.anthropic.com//cdn-cgi/trace
check deny  "/cdn-cgi/ after /./"                  GET    https://api.anthropic.com/./cdn-cgi/trace
check deny  "/cdn-cgi/ after /%2e/"                GET    https://api.anthropic.com/%2e/cdn-cgi/trace
check deny  "/cdn-cgi/ after a backslash"          GET    'https://api.anthropic.com/\cdn-cgi/trace'
check allow "control: cdn in a path, no cdn-cgi"   GET    https://github.com/Azure/cdn-tools
check allow "Debian mirror (http)"                 GET    http://ftp.pl.debian.org/debian/dists/
check allow "Debian security (https)"              GET    https://security.debian.org/debian-security/dists/
check deny  "IP literal whose PTR is allowlisted"  GET    "http://$PTR_IP/exfil?d=secret"
check deny  "client outside localnet"              GET    https://api.anthropic.com/v1/models --interface "$OUTSIDE_IP"
# LiteLLM = its own leg (LLM_LEG) and its own network as source
L=$LLM_LEG
PROXY_ADDR=$L check allow "LiteLLM -> LLM provider API"      POST https://openrouter.ai/api/v1/chat/completions --interface "$LITELLM_IP"
PROXY_ADDR=$L check allow "LiteLLM -> shared allowlist"      GET  https://api.anthropic.com/v1/models --interface "$LITELLM_IP"
PROXY_ADDR=$L check deny  "LiteLLM -> domain not on any list" GET https://evil.example.com/ --interface "$LITELLM_IP"
PROXY_ADDR=$L check allow "LiteLLM -> LAN host, port 8000"   POST http://llm.lan.internal:8000/v1/chat/completions --interface "$LITELLM_IP"
check deny  "agent -> LLM provider API"            POST   https://openrouter.ai/api/v1/chat/completions
check deny  "agent -> LLM provider API (GET)"      GET    https://openrouter.ai/api/v1/models
check deny  "agent -> LAN host, port 8000"         GET    http://llm.lan.internal:8000/v1/models
check deny  "agent -> LAN host, port 80"           GET    http://llm.lan.internal/
# an agent that routes to Squid's LiteLLM leg address (needs NET_ADMIN, e.g. privileged Hermes)
PROXY_ADDR=$L check deny "agent via LiteLLM's leg -> LLM provider API" POST https://openrouter.ai/api/v1/chat/completions
PROXY_ADDR=$L check deny "agent via LiteLLM's leg -> LAN host"         GET  http://llm.lan.internal:8000/v1/models
# a source address from LiteLLM's network arriving on the agents' leg (forged source)
check deny  "LiteLLM network on the agents' leg"   POST   https://openrouter.ai/api/v1/chat/completions --interface "$LITELLM_IP"

# the deny page must say that the proxy policy blocked the request
page=$(curl -sS --max-time 10 --proxy http://127.0.0.1:3128 --noproxy '' --interface "$CLIENT_IP" \
         -w '\n%{http_code}' http://evil.example.com/ 2>&1) || true
if [ "${page##*$'\n'}" = 403 ] && grep -q 'Blocked by agents-sandbox proxy policy' <<<"$page"; then
  echo "PASS  deny page is a 403 naming the proxy policy"
else
  echo "FAIL  deny page is a 403 naming the proxy policy (got: $(tr '\n' ' ' <<<"$page" | cut -c1-80))"
  FAIL=$((FAIL + 1))
fi

if [ "$FAIL" -gt 0 ]; then
  echo "--- access.log"; cat "$W/log/access.log"
  echo "--- cache.log (tail)"; tail -20 "$W/log/cache.log"
  echo "run-acl-tests: $FAIL check(s) failed" >&2
  exit 1
fi
echo "run-acl-tests: all checks passed"
