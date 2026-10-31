#!/bin/bash
# Creates the real env files and the local configuration (squid/conf/*,
# hermes/config.yaml, hermes/managed.env, hermes/SOUL.md) from the tracked *.example files when missing, and replaces every
# generated CHANGE_ME_* placeholder with a random value. The same placeholder gets
# the same value in every file (e.g. the PostgreSQL password in litellm-db.env and
# DATABASE_URL). Existing values are never touched, so it is safe to run again.
#
# CLAUDE_OAI_KEY (LiteLLM <-> Claude bridge) is generated too. A key that already has a
# value in one file (e.g. litellm.env) passes that value on to the other files instead
# of a new one.
#
# The Hermes dashboard password is the exception: the container env is readable by the
# agent, so hermes/hermes.env gets only its scrypt hash (needs python3) and the password
# goes to hermes/dashboard-password, which no container mounts.
#
# Left for you: the provider keys, e.g. OPENROUTER_API_KEY (litellm/models/README.md).
#
# Rotating a generated secret: put its placeholder back (e.g.
# LITELLM_API_KEY=CHANGE_ME_LITELLM_KEY_HERMES), run this script, then
# `docker compose up -d`; as-litellm-keys replaces the LiteLLM key and keeps its settings.
# New dashboard password: HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=CHANGE_ME_HERMES_DASHBOARD_PASSWORD_HASH.
#
# Usage: ./gen-secrets.sh
set -euo pipefail
cd "$(dirname "$0")"

# local configuration: your copies; git pull only updates the *.example files
for ex in squid/conf/*.example hermes/config.yaml.example hermes/managed.env.example hermes/SOUL.md.example; do
  f=${ex%.example}
  if [ ! -f "$f" ]; then
    cp "$ex" "$f"
    echo "gen-secrets: created $f from $ex"
    if [ "$f" = hermes/SOUL.md ] && [ -f hermes/data/SOUL.md ] && ! cmp -s hermes/data/SOUL.md "$f"; then
      echo "gen-secrets: Hermes now reads $f (read-only); its persona so far is hermes/data/SOUL.md. Take over what you want: diff -u hermes/data/SOUL.md $f" >&2
    fi
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

# Hermes dashboard password: the hash into hermes.env, the password into a host-only file
ph=CHANGE_ME_HERMES_DASHBOARD_PASSWORD_HASH pwfile=hermes/dashboard-password
if grep -qw "$ph" hermes/hermes.env; then
  if ! command -v python3 >/dev/null; then
    echo "gen-secrets: python3 is needed to hash the Hermes dashboard password; $ph is left in hermes/hermes.env" >&2
  else
    pw=$(hex 24)
    (umask 077 && printf '%s\n' "$pw" >"$pwfile")
    # the same scrypt parameters as Hermes' plugins/dashboard_auth/basic hash_password();
    # single quotes: Compose expands $ in env files
    GEN_PW=$pw python3 - hermes/hermes.env "$ph" <<'PY'
import base64, hashlib, os, re, secrets, sys
path, ph = sys.argv[1], sys.argv[2]
salt = secrets.token_bytes(16)
dk = hashlib.scrypt(os.environ["GEN_PW"].encode(), salt=salt, n=2**14, r=8, p=1, dklen=32, maxmem=0)
h = "scrypt$16384$8$1$%s$%s" % (base64.b64encode(salt).decode(), base64.b64encode(dk).decode())
text = open(path).read()
pat = r"(?m)^([ \t]*HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH[ \t]*=[ \t]*)['\"]?" + ph + r"['\"]?[ \t]*$"
new, n = re.subn(pat, lambda m: m.group(1) + "'" + h + "'", text)
if n != 1:
    sys.exit("gen-secrets: expected one HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=%s line in %s" % (ph, path))
open(path, "w").write(new)
PY
    unset pw
    echo "gen-secrets: HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH generated in hermes/hermes.env, the password in $pwfile"
  fi
fi

left=$(cat "${FILES[@]}" | grep -vE '^[[:space:]]*#' | grep -oE 'CHANGE_ME_[A-Z0-9_]+' | sort -u || true)
if [ -n "$left" ]; then
  echo "gen-secrets: fill in by hand:"
  for ph in $left; do echo "  $ph in $(grep -lw "$ph" "${FILES[@]}" | tr '\n' ' ')"; done
fi
echo "gen-secrets: Hermes dashboard login: HERMES_DASHBOARD_BASIC_AUTH_USERNAME in hermes/hermes.env, the password in hermes/dashboard-password"
