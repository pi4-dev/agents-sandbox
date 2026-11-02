#!/bin/sh
# Prepare and start the environment: secrets, bind-mounted directories, env
# checks, every container. Agent sessions: ./start-main.sh, ./start-claude.sh.
set -eu
cd "$(dirname "$0")"

./gen-secrets.sh >/dev/null   # creates missing env files, fills generated secrets
# the bind-mounted directories of the Claude containers (agent, bridge, Qwen), Hermes, as-zenoh
# and the access logs of as-dns, as-ingress, as-llm-gw and as-litellm,
# created by you rather than by Docker as root; .claude too, because CLAUDE.md is
# mounted into it
mkdir -p claude-main/data/workspace claude-main/data/claude-home/.claude \
         claude-bridge/workspace claude-bridge/home/.claude \
         claude-qwen/data/workspace claude-qwen/data/claude-home/.claude \
         hermes/data hermes/workspace zenoh/logs dns/logs ingress/logs llm-gw/logs litellm/logs
./check-env.sh                # placeholders, values that must match, directory owners
docker compose up -d
docker compose exec as-squid squid -k reconfigure -f /etc/squid/conf/squid.conf
