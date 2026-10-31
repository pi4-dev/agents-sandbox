#!/bin/bash
# Creates the real env files and the local configuration (squid/conf/*,
# hermes/config.yaml, hermes/managed.env) from the tracked *.example files when missing, and replaces every
# generated CHANGE_ME_* placeholder with a random value. The same placeholder gets
# the same value in every file (e.g. the PostgreSQL password in litellm-db.env and
# DATABASE_URL). Existing values are never touched, so it is safe to run again.
#
# CLAUDE_OAI_KEY (LiteLLM <-> Claude bridge) is generated too. A key that already has a
# value in one file (e.g. litellm.env) passes that value on to the other files instead
# of a new one.
#
# Left for you: the provider keys, e.g. OPENROUTER_API_KEY (litellm/models/README.md).
#
# Rotating a generated secret: put its placeholder back (e.g.
# LITELLM_API_KEY=CHANGE_ME_LITELLM_KEY_HERMES), run this script, then
# `docker compose up -d`; as-litellm-keys replaces the LiteLLM key and keeps its settings.
#
# Usage: ./gen-secrets.sh
set -euo pipefail
cd "$(dirname "$0")"

# local configuration: your copies; git pull only updates the *.example files
for ex in squid/conf/*.example hermes/config.yaml.example hermes/managed.env.example; do
  f=${ex%.example}
  if [ ! -f "$f" ]; then
    cp "$ex" "$f"
    echo "gen-secrets: created $f from $ex"
  elif [ "$ex" -nt "$f" ] && ! cmp -s "$ex" "$f"; then
    echo "gen-secrets: $ex changed after your $f; review: diff -u $f $ex" >&2
  fi
done

FILES=(.env claude-main/claude.env claude-bridge/claude-bridge.env hermes/hermes.env litellm/litellm.env litellm/litellm-db.env open-webui/open-webui.env)
for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    install -m 600 "$f.example" "$f"
    echo "gen-secrets: created $f from $f.example"
  fi
done

hex() { openssl rand -hex "$1"; }
declare -A GEN=(
  [CHANGE_ME_LITELLM_MASTER_KEY]="sk-$(hex 24)"
  [CHANGE_ME_LITELLM_SALT_KEY]="$(hex 32)"
  [CHANGE_ME_POSTGRES_PASSWORD]="$(hex 24)"
  [CHANGE_ME_LITELLM_KEY_HERMES]="sk-$(hex 24)"
  [CHANGE_ME_LITELLM_KEY_OPEN_WEBUI]="sk-$(hex 24)"
  [CHANGE_ME_WEBUI_SECRET_KEY]="$(hex 32)"
  [CHANGE_ME_HERMES_DASHBOARD_USER]="admin"
  [CHANGE_ME_HERMES_DASHBOARD_PASSWORD]="$(hex 24)"
  [CHANGE_ME_HERMES_DASHBOARD_SECRET]="$(hex 32)"
  [CHANGE_ME_CLAUDE_OAI_KEY]="sk-$(hex 24)"
)

# existing <ph>: the value already set elsewhere for the key(s) holding placeholder <ph>
existing() {
  local keys k v
  keys=$(sed -nE "s/^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*$1[[:space:]]*\$/\1/p" "${FILES[@]}" | sort -u)
  for k in $keys; do
    v=$(sed -nE "s/^[[:space:]]*${k}[[:space:]]*=[[:space:]]*//p" "${FILES[@]}" | { grep -v CHANGE_ME || true; } | sort -u)
    if [ -n "$v" ] && [ "$(wc -l <<<"$v")" = 1 ]; then printf '%s' "$v"; return; fi
  done
}

for ph in "${!GEN[@]}"; do
  hits=()
  for f in "${FILES[@]}"; do
    if grep -qw "$ph" "$f"; then hits+=("$f"); fi
  done
  [ ${#hits[@]} -gt 0 ] || continue
  val=$(existing "$ph")
  if [ -n "$val" ]; then
    sed -i "s/\\b$ph\\b/$(sed 's/[\/&]/\\&/g' <<<"$val")/g" "${hits[@]}"
    echo "gen-secrets: ${ph#CHANGE_ME_} copied from the existing value into ${hits[*]}"
    continue
  fi
  sed -i "s/\\b$ph\\b/${GEN[$ph]}/g" "${hits[@]}"
  echo "gen-secrets: ${ph#CHANGE_ME_} generated in ${hits[*]}"
done

left=$(cat "${FILES[@]}" | grep -vE '^[[:space:]]*#' | grep -oE 'CHANGE_ME_[A-Z0-9_]+' | sort -u || true)
if [ -n "$left" ]; then
  echo "gen-secrets: fill in by hand:"
  for ph in $left; do echo "  $ph in $(grep -lw "$ph" "${FILES[@]}" | tr '\n' ' ')"; done
fi
echo "gen-secrets: Hermes dashboard login is in hermes/hermes.env (HERMES_DASHBOARD_BASIC_AUTH_*)"
