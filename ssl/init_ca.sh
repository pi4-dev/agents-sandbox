#!/bin/bash
set -euo pipefail

if [[ -e squid-ca.key && "${1:-}" != "--force" ]]; then
  echo "CA juz istnieje (ssl/squid-ca.key). uzyj --forcez żeby wygenerc nowe." >&2
  exit 1
fi

umask 077   # klucz od początku powstaje z prawami 600, bez okna czasowego

openssl req -x509 -new -nodes -sha256 -days 3650 \
  -newkey rsa:4096 \
  -subj "/CN=Internal Proxy CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout squid-ca.key -out squid-ca.crt

sudo chown 13:13 squid-ca.key && sudo chmod 400 squid-ca.key   # tylko Squid (proxy)
chmod 644 squid-ca.crt                                          # dla klientów

rm -f squid-ca.pem ca.crt   # stare formaty, żeby nic ich przypadkiem nie montowało

openssl x509 -in squid-ca.crt -noout -subject -enddate
