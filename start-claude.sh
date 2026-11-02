#!/bin/sh
# A Claude Code session in Claude on Qwen (as-claude-qwen): the LiteLLM model
# CLAUDE_QWEN_MODEL, no Anthropic login (so no Remote Control).
# Arguments go to claude, e.g. ./start-claude.sh --resume
set -eu
cd "$(dirname "$0")"
svc=as-claude-qwen
if [ -z "$(docker compose ps -q --status running "$svc")" ]; then
  echo "start-claude: $svc is not running; start the environment with ./run-first.sh" >&2
  exit 1
fi
exec docker compose exec "$svc" claude "$@"
