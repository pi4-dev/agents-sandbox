#!/bin/sh
# A Claude Code session in the Claude agent (as-claude-main), with Remote Control.
# Arguments replace the default ones, e.g. ./start-claude-main.sh --resume
# Headless:
#   docker compose exec -T as-claude-main sh -c 'cd /workspace/repo-a && claude -p "Review the changes from the last 24h" --output-format json' > review.json
set -eu
cd "$(dirname "$0")"
svc=as-claude-main
if [ -z "$(docker compose ps -q --status running "$svc")" ]; then
  echo "start-claude-main: $svc is not running; start the environment with ./run-first.sh" >&2
  exit 1
fi
[ "$#" -gt 0 ] || set -- --dangerously-skip-permissions --remote-control main
exec docker compose exec "$svc" claude "$@"
