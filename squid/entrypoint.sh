#!/bin/sh
set -e

CONF=${SQUID_CONF:-/etc/squid/conf/squid.conf}
[ -f "$CONF" ] || {
  echo "entrypoint: $CONF is missing; run ./gen-secrets.sh (creates squid/conf/* from the *.example files)" >&2
  exit 1
}
DB=/var/lib/squid/ssl_db
CERTGEN=/usr/lib/squid/security_file_certgen
# seconds between `squid -k rotate` runs (0 = no rotation)
ROTATE_INTERVAL=${SQUID_LOG_ROTATE_INTERVAL:-86400}

# 1. Database of dynamically generated certificates (first start only)
if [ ! -d "$DB" ]; then
  echo "entrypoint: creating $DB"
  "$CERTGEN" -c -s "$DB" -M 16MB
fi
chown -R proxy:proxy "$DB"

# 2. Proxy client networks (acl localnet) from .env
: "${SQUID_LOCALNET:?entrypoint: SQUID_LOCALNET is not set}"
# shellcheck disable=SC2086  # space-separated list of networks -> one per line
printf '%s\n' $SQUID_LOCALNET >/var/lib/squid/localnet.txt
# LiteLLM's network (as-net-litellm-egress): the only leg allowed to reach llm_api_domains.txt
: "${SQUID_LITELLM_NET:?entrypoint: SQUID_LITELLM_NET is not set}"
printf '%s\n' "$SQUID_LITELLM_NET" >/var/lib/squid/litellm_net.txt
# resolvers for internet names (Squid asks them directly, over its VLAN leg)
: "${SQUID_DNS_UPSTREAM:?entrypoint: SQUID_DNS_UPSTREAM is not set}"
echo "dns_nameservers $SQUID_DNS_UPSTREAM" >/var/lib/squid/dns.conf

# 3. Log directory
mkdir -p /var/log/squid
chown -R proxy:proxy /var/log/squid

# 4. Validate the config: a readable error instead of a silent restart
squid -k parse -f "$CONF"

# 5. Log rotation (logfile_rotate in squid.conf sets the number of copies)
if [ "$ROTATE_INTERVAL" -gt 0 ]; then
  (
    while sleep "$ROTATE_INTERVAL"; do
      squid -k rotate -f "$CONF" || echo "entrypoint: squid -k rotate failed" >&2
    done
  ) &
fi

# 6. Squid in the foreground (handles SIGTERM itself)
exec squid -N -d 1 -f "$CONF"
