#!/bin/bash
# Creates the CA for Squid's SSL-bump: ssl/squid-ca.key (UID 13 = proxy only) and ssl/squid-ca.crt.
# After a rotation (--force): docker compose build as-claude-main as-claude-bridge
#                       docker compose up -d --force-recreate as-squid as-litellm as-claude-main as-claude-bridge
set -euo pipefail
cd "$(dirname "$0")"   # files always go to ssl/, whatever the current directory

if [[ -e squid-ca.key && "${1:-}" != "--force" ]]; then
  echo "CA already exists (ssl/squid-ca.key). Use --force to generate a new one." >&2
  exit 1
fi

umask 077   # the key is created with mode 600 from the start, no time window

# Generate next to the current files and replace them with mv: the current key belongs to UID 13
# with mode 400, so openssl could not overwrite it; a rename needs only directory write access.
trap 'rm -f squid-ca.key.new squid-ca.crt.new' EXIT
openssl req -x509 -new -nodes -sha256 -days 3650 \
  -newkey rsa:4096 \
  -subj "/CN=Internal Proxy CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout squid-ca.key.new -out squid-ca.crt.new

sudo chown 13:13 squid-ca.key.new && sudo chmod 400 squid-ca.key.new   # Squid (proxy) only
chmod 644 squid-ca.crt.new                                              # for clients
mv -f squid-ca.key.new squid-ca.key
mv -f squid-ca.crt.new squid-ca.crt

openssl x509 -in squid-ca.crt -noout -subject -enddate
