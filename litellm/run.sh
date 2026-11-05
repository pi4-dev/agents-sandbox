#!/bin/sh
# as-litellm: the config LiteLLM starts with is /app/config.yaml (litellm/litellm-config.yaml,
# the settings) with an `include:` of every /app/models/*.yaml (litellm/models/, one file
# per API endpoint), in name order. A new model file needs no config edit, only
# `docker compose restart as-litellm`. An `include:` left in litellm-config.yaml (from
# before) is dropped: the model files come from the directory alone.
# Arguments go to LiteLLM after --config (the image's entrypoint starts it).
set -eu
BASE=${LITELLM_BASE_CONFIG:-/app/config.yaml}
MODELS=${LITELLM_MODELS_DIR:-/app/models}
OUT=${LITELLM_CONFIG_OUT:-/tmp/config.yaml}

[ -f "$BASE" ] || { echo "as-litellm: $BASE is missing" >&2; exit 1; }
{
  n=0
  for f in "$MODELS"/*.yaml; do
    [ -f "$f" ] || continue
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
exec /app/docker/prod_entrypoint.sh --config "$OUT" "$@"
