#!/bin/sh
# as-litellm: the config LiteLLM starts with is /app/config.yaml (litellm/litellm-config.yaml,
# the settings) with an `include:` of every /app/models/*.yaml (litellm/models/, one file
# per API endpoint), in name order. A new model file needs no config edit, only
# `docker compose restart as-litellm`. An `include:` left in litellm-config.yaml (from
# before) is dropped: the model files come from the directory alone.
# A model file with a line "# @profile <name>" is loaded only while that Compose profile is
# active (AS_PROFILES, ",<COMPOSE_PROFILES>,"; unset: every profile), e.g. claude-local.yaml
# (profile bridge): without the bridge, LiteLLM does not offer a model nobody serves.
# Arguments go to LiteLLM after --config (the image's entrypoint starts it; either name).
set -eu
BASE=${LITELLM_BASE_CONFIG:-/app/config.yaml}
MODELS=${LITELLM_MODELS_DIR:-/app/models}
OUT=${LITELLM_CONFIG_OUT:-/tmp/config.yaml}
PROFILES=$(printf '%s' "${AS_PROFILES-,*,}" | tr -d ' ')   # Compose allows "a, b"

# active <profile>: listed in AS_PROFILES, or every profile ("*")
active() { case $PROFILES in *",$1,"* | *",*,"*) return 0 ;; esac; return 1; }

[ -f "$BASE" ] || { echo "as-litellm: $BASE is missing" >&2; exit 1; }
{
  n=0
  for f in "$MODELS"/*.yaml; do
    [ -f "$f" ] || continue
    p=$(sed -n 's/^#[[:space:]]*@profile[[:space:]][[:space:]]*\([A-Za-z0-9_-][A-Za-z0-9_-]*\).*/\1/p' "$f" | head -n1)
    if [ -n "$p" ] && ! active "$p"; then
      echo "as-litellm: skipping $f (profile $p is not active)" >&2
      continue
    fi
    [ "$n" -gt 0 ] || echo "include:"
    printf '  - %s\n' "$f"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || echo "as-litellm: no model files in $MODELS" >&2
  echo
  # the base config without its own top-level include: block
  awk '/^include:/ { skip = 1; next } skip && /^[^[:space:]#]/ { skip = 0 } !skip' "$BASE"
} >"$OUT"
echo "as-litellm: models from $(grep -c '^  - ' "$OUT" || true) file(s) in $MODELS" >&2
# the image's entrypoint: /app/docker/prod_entrypoint.sh in images before 2026-11,
# /app/docker-entrypoint.sh (proxy by default) since
for entry in /app/docker/prod_entrypoint.sh /app/docker-entrypoint.sh; do
  [ -f "$entry" ] && exec "$entry" --config "$OUT" "$@"
done
echo "as-litellm: no LiteLLM entrypoint in the image (/app/docker/prod_entrypoint.sh, /app/docker-entrypoint.sh)" >&2
exit 1
