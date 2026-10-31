#!/bin/sh
set -eu
cd "$(dirname "$0")"

./gen-secrets.sh >/dev/null   # creates missing env files, fills generated secrets
# the bind-mounted directories of the Claude containers (agent and bridge) and Hermes,
# created by you rather than by Docker as root; .claude too, because CLAUDE.md is
# mounted into it
mkdir -p claude-main/data/workspace claude-main/data/claude-home/.claude \
         claude-bridge/workspace claude-bridge/home/.claude \
         hermes/data hermes/workspace
./check-env.sh                # placeholders, values that must match, directory owners
docker compose up -d
docker compose exec as-squid squid -k reconfigure -f /etc/squid/conf/squid.conf

docker compose exec as-claude-main claude --dangerously-skip-permissions --remote-control "main"



# headless
# docker compose exec -T as-claude-main sh -c 'cd /workspace/repo-a && claude -p "Review the changes from the last 24h and list potential bugs" --output-format json' > review.json

