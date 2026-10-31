#!/bin/sh
# Reload Squid's configuration (squid.conf + ACL lists) without restarting the container.
# Changes to docker-compose.yaml (mounts, image) need:
#   docker compose up -d --force-recreate as-squid
set -eu
cd "$(dirname "$0")/.."

docker compose exec as-squid squid -k parse -f /etc/squid/conf/squid.conf
docker compose exec as-squid squid -k reconfigure -f /etc/squid/conf/squid.conf
echo "squid: configuration reloaded"
