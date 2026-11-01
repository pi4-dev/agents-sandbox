#!/bin/sh
# as-hermes: s6-overlay cont-init hook, mounted as /etc/cont-init.d/00-proxy-ca. It runs as
# root at every start, before Hermes drops to its PUID. Squid bumps all TLS, so its CA
# (mounted at /usr/local/share/ca-certificates/proxy-ca.crt) goes into the system store:
# curl, git, OpenSSL and Hermes itself (truststore) use it; SSL_CERT_FILE,
# REQUESTS_CA_BUNDLE and NODE_EXTRA_CA_CERTS in docker-compose.yaml cover libraries with
# their own bundle (certifi, Node). A failure must not stop Hermes from starting.
if [ ! -s /usr/local/share/ca-certificates/proxy-ca.crt ]; then
  echo "as-hermes: no proxy CA at /usr/local/share/ca-certificates/proxy-ca.crt (ssl/init_ca.sh)" >&2
elif ! update-ca-certificates >/dev/null 2>&1; then
  echo "as-hermes: update-ca-certificates failed; HTTPS through Squid will not verify" >&2
fi
exit 0
