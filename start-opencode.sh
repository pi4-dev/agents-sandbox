#!/bin/sh
# An opencode session in as-opencode (the model from opencode/opencode.jsonc), with a
# private server for this session (--standalone) instead of a shared background service.
# Arguments replace the default ones, e.g. ./start-opencode.sh run "Explain this repo"
set -eu
cd "$(dirname "$0")"
svc=as-opencode
if [ -z "$(docker compose ps -q --status running "$svc")" ]; then
  echo "start-opencode: $svc is not running; it needs the opencode profile (COMPOSE_PROFILES in .env), then ./run-first.sh" >&2
  exit 1
fi
[ "$#" -gt 0 ] || set -- --standalone
exec docker compose exec "$svc" opencode "$@"
