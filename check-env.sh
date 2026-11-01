#!/bin/bash
# Checks env files for leftover placeholders, values that must match across
# files, and that IP addresses appear only in .env and squid/conf/lan.hosts
# (everything else uses *.as.internal names, Docker network aliases served by as-dns).
#
#   ./check-env.sh             your real files (.env, */*.env); start-main.sh runs it
#   ./check-env.sh --examples  tracked *.example files use only CHANGE_ME_* (CI)
#
# Values are never printed, only file and key names.
set -euo pipefail
cd "$(dirname "$0")"

SERVICE_ENVS=(claude-main/claude claude-bridge/claude-bridge hermes/hermes litellm/litellm litellm/litellm-db open-webui/open-webui zenoh/zenoh)

if [ "${1:-}" = --examples ]; then mode=examples sfx=.example; else mode=local sfx=; fi
fail=0
err() { echo "check-env: $*" >&2; fail=1; }

# urlenc <s>: percent-encoding as used for a password inside DATABASE_URL
urlenc() {
  local s=$1 i c out=
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in [A-Za-z0-9._~-]) out+=$c ;; *) printf -v c '%%%02X' "'$c"; out+=$c ;; esac
  done
  printf '%s' "$out"
}

# get <file> <KEY>: last value of KEY (KEY=value or KEY: value), without quotes and inline comment
get() {
  sed -nE "s/^[[:space:]]*$2[[:space:]]*[=:][[:space:]]*//p" "$1" | tail -n1 |
    sed -E -e 's/[[:space:]]+#.*$//' -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'\$/\1/"
}

envs=(".env$sfx")
for s in "${SERVICE_ENVS[@]}"; do envs+=("$s.env$sfx"); done
present=()
for f in "${envs[@]}"; do
  if [ -f "$f" ]; then present+=("$f")
  elif [ $mode = local ]; then err "missing $f (cp $f.example $f)"
  else err "missing $f"; fi
done

# --- placeholders (comments are ignored) ---
scan() { # scan <file> <allow CHANGE_ME_*: yes|no>
  local file=$1 allow=$2 n line tok key where
  while IFS=: read -r n line; do
    line=${line%%[[:space:]]#*}   # inline comment
    key=${line%%[=:]*}
    where="in ${key##*[[:space:]]}"
    if [[ $file == *.txt || $file == *.txt.example ]]; then where="in an active rule"; fi
    while read -r tok; do
      [ -n "$tok" ] || continue
      if [ "$allow" = yes ] && [[ $tok =~ ^CHANGE_ME_[A-Z0-9_]+$ ]]; then continue; fi
      if [ "$allow" = yes ]; then err "$file:$n: placeholder '$tok' does not follow CHANGE_ME_<NAME>"
      else err "$file:$n: placeholder left $where (./gen-secrets.sh fills the generated ones)"; fi
    done < <(grep -oiE '[a-z0-9_]*change[_ -]?me[a-z0-9_]*' <<<"$line" || true)
    if grep -qE '<[A-Za-z0-9_-]+>' <<<"$line"; then
      err "$file:$n: angle-bracket placeholder $where (use CHANGE_ME_<NAME>)"
    fi
  done < <(grep -nvE '^[[:space:]]*(#|$)' "$file" || true)
}
allow=no
[ $mode = examples ] && allow=yes
for f in "${present[@]}"; do scan "$f" $allow; done
# config files are not placeholders: an active CHANGE_ME line there would be live config
for f in proxy.env hermes/config.yaml"$sfx" hermes/managed.env"$sfx" litellm/litellm-config.yaml litellm/models/*.yaml squid/conf/*.txt"$sfx"; do
  [ -f "$f" ] && scan "$f" no
done

# --- local configuration: your copies of the config *.example files ---
if [ $mode = local ]; then
  for ex in squid/conf/*.example hermes/config.yaml.example hermes/managed.env.example hermes/SOUL.md.example; do
    f=${ex%.example}
    if [ ! -f "$f" ]; then err "missing $f (./gen-secrets.sh creates it from $ex)"
    elif [ "$ex" -nt "$f" ] && ! cmp -s "$ex" "$f"; then
      echo "check-env: warning: $ex changed after your $f (git pull?); review: diff -u $f $ex" >&2
    fi
  done
  # Hermes' firewall lets it reach LiteLLM only through as-llm-gw
  if [ -f hermes/config.yaml ] && grep -vE '^[[:space:]]*#' hermes/config.yaml | grep -q 'litellm\.as\.internal'; then
    err "hermes/config.yaml: litellm.as.internal is dropped by Hermes' firewall; use the gateway: api: \"http://llm.as.internal:4000/v1\""
  fi
fi

# --- values that must match ---
db=litellm/litellm-db.env$sfx ll=litellm/litellm.env$sfx
if [ -f "$db" ] && [ -f "$ll" ]; then
  url=$(get "$ll" DATABASE_URL)
  user=$(get "$db" POSTGRES_USER) pass=$(get "$db" POSTGRES_PASSWORD)
  if [[ $url != "postgresql://$user:$pass@"* && $url != "postgresql://$(urlenc "$user"):$(urlenc "$pass")@"* ]]; then
    err "DATABASE_URL in $ll does not use POSTGRES_USER/POSTGRES_PASSWORD from $db"
  fi
  if ! [[ $url =~ /$(get "$db" POSTGRES_DB)(\?|$) ]]; then
    err "DATABASE_URL in $ll does not name POSTGRES_DB from $db"
  fi
  br=claude-bridge/claude-bridge.env$sfx
  if [ -f "$br" ] && [ "$(get "$ll" CLAUDE_OAI_KEY)" != "$(get "$br" CLAUDE_OAI_KEY)" ]; then
    err "CLAUDE_OAI_KEY differs between $ll and $br (LiteLLM and the bridge need the same key)"
  fi
  master=$(get "$ll" LITELLM_MASTER_KEY)
  # client keys: registered by as-litellm-keys, so they must be valid LiteLLM virtual keys
  seen=
  for pair in "hermes/hermes.env$sfx LITELLM_API_KEY" "open-webui/open-webui.env$sfx OPENAI_API_KEY"; do
    read -r f k <<<"$pair"
    [ -f "$f" ] || continue
    v=$(get "$f" "$k")
    if [ -n "$master" ] && [ "$v" = "$master" ]; then
      err "$k in $f is LITELLM_MASTER_KEY; give each client its own LiteLLM virtual key"
    fi
    if [ $mode = local ] && [[ $v != CHANGE_ME* ]] && ! [[ $v =~ ^sk-.{13,}$ ]]; then
      err "$k in $f must start with sk- and have at least 16 characters (LiteLLM rule)"
    fi
    if [ -n "$v" ] && [ "$v" = "$seen" ]; then
      err "$k in $f is the same key as another client; each client needs its own"
    fi
    seen=$v
  done
  if [ $mode = local ] && [ -n "$master" ] && [[ $master != sk-* ]]; then
    echo "check-env: warning: LITELLM_MASTER_KEY should start with sk- (LiteLLM convention)" >&2
  fi
fi

# --- Hermes dashboard login: every process with Hermes' UID, the agent included, reads the
#     container env, so hermes.env holds a password hash and no session secret ---
he=hermes/hermes.env$sfx
if [ -f "$he" ]; then
  has() { grep -qE "^[[:space:]]*$1[[:space:]]*=" "$he"; }
  if has HERMES_DASHBOARD_BASIC_AUTH_PASSWORD && has HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH; then
    err "$he: HERMES_DASHBOARD_BASIC_AUTH_PASSWORD wins over HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH; delete it"
  elif has HERMES_DASHBOARD_BASIC_AUTH_PASSWORD; then
    echo "check-env: warning: $he: plaintext HERMES_DASHBOARD_BASIC_AUTH_PASSWORD, readable by the agent in the container env. Replace the line with HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=CHANGE_ME_HERMES_DASHBOARD_PASSWORD_HASH and run ./gen-secrets.sh" >&2
  fi
  if has HERMES_DASHBOARD_BASIC_AUTH_SECRET; then
    echo "check-env: warning: $he: HERMES_DASHBOARD_BASIC_AUTH_SECRET is readable by the agent in the container env and signs dashboard sessions; delete the line (you log in again after each restart)" >&2
  fi
  raw=$(sed -nE 's/^[[:space:]]*HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH[[:space:]]*=[[:space:]]*//p' "$he" | tail -n1 |
        sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//')
  if [ -n "$raw" ] && [[ $raw != *CHANGE_ME* ]]; then
    h=
    if [[ $raw == \'*\' ]]; then h=${raw:1:${#raw}-2}
    elif [[ $raw == *'$$'* ]]; then h=${raw//\$\$/\$}
    else err "$he: put HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH in single quotes; Compose expands the \$ in it otherwise"
    fi
    re='^scrypt\$[0-9]+\$[0-9]+\$[0-9]+\$[A-Za-z0-9+/]+=*\$[A-Za-z0-9+/]+=*$'
    if [ -n "$h" ] && ! [[ $h =~ $re ]]; then
      err "$he: HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH is not a scrypt\$N\$r\$p\$salt\$hash value (./gen-secrets.sh makes one)"
    fi
  fi
fi

# --- LiteLLM model sets: litellm/models/*.yaml pulled in by include: ---
cfg=litellm/litellm-config.yaml
names=() vars=()
while read -r inc; do
  f=litellm/$inc
  if [ ! -f "$f" ]; then err "$cfg includes $inc, which does not exist"; continue; fi
  while read -r n; do names+=("$n"); done < <(sed -nE 's/^[[:space:]]*-[[:space:]]*model_name:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' "$f")
  while read -r v; do vars+=("$v|$f"); done < <(grep -vE '^[[:space:]]*#' "$f" | grep -oE 'os\.environ/[A-Za-z0-9_]+' | sed 's#os.environ/##' | sort -u)
done < <(sed -nE 's/^[[:space:]]*-[[:space:]]*(models\/[^[:space:]#]+).*/\1/p' "$cfg")
dups=$(printf '%s\n' "${names[@]}" | sort | uniq -d)
[ -z "$dups" ] || err "model_name used in more than one place in litellm/models: $(echo "$dups" | tr '\n' ' ')"
for f in litellm/models/*.yaml; do
  grep -qE "^[[:space:]]*-[[:space:]]*models/$(basename "$f")([[:space:]]|$)" "$cfg" ||
    echo "check-env: warning: $f is not under include: in $cfg (not loaded)" >&2
done
if [ -f "$ll" ]; then
  for pair in "${vars[@]}"; do
    v=${pair%%|*} f=${pair#*|}
    grep -qE "^[[:space:]]*${v}[[:space:]]*[=:]" "$ll" || err "$f uses os.environ/$v, which is missing in $ll"
  done
fi

# --- .env has every key of .env.example ---
if [ $mode = local ] && [ -f .env ]; then
  while read -r k; do
    grep -qE "^[[:space:]]*${k}[[:space:]]*[=:]" .env || err "missing $k in .env (see .env.example)"
  done < <(sed -nE 's/^([A-Z0-9_]+)[[:space:]]*[=:].*/\1/p' .env.example)
fi

# --- service env files: keys new in the examples (a warning; some may be left out on purpose) ---
if [ $mode = local ]; then
  for svc in "${SERVICE_ENVS[@]}"; do
    [ -f "$svc.env" ] || continue
    while read -r k; do
      grep -qE "^[[:space:]]*${k}[[:space:]]*[=:]" "$svc.env" ||
        echo "check-env: warning: $k from $svc.env.example is not in $svc.env" >&2
    done < <(sed -nE 's/^([A-Za-z0-9_]+)[[:space:]]*[=:].*/\1/p' "$svc.env.example")
  done
fi

# --- Claude directories: the containers run as node (UID 1000) and must write their home ---
# (Claude Code stores the login in ~/.claude/.credentials.json and ~/.claude.json)
if [ $mode = local ]; then
  bridge_ws=$(get .env CLAUDE_BRIDGE_WORKSPACE) bridge_home=$(get .env CLAUDE_BRIDGE_HOME)
  for d in claude-main/data/workspace claude-main/data/claude-home "${bridge_ws:-./claude-bridge/workspace}" \
           "${bridge_home:-./claude-bridge/home}"; do
    d=${d#./}
    if [ ! -d "$d" ]; then
      echo "check-env: warning: $d is missing; Docker would create it as root and the container could not write it (start-main.sh creates it)" >&2
    elif bad=$(find "$d" ! -uid 1000 -print -quit 2>/dev/null) && [ -n "$bad" ]; then
      echo "check-env: warning: $bad is not owned by UID 1000 (node in the container), which cannot write it; in a home the Claude login is not saved. Fix: sudo chown -R 1000:1000 $d" >&2
    fi
  done
fi

# --- Hermes directories: the upstream entrypoint drops to PUID/PGID from hermes.env ---
if [ $mode = local ]; then
  puid=1000 pgid=1000
  if [ -f hermes/hermes.env ]; then
    v=$(get hermes/hermes.env PUID); puid=${v:-1000}
    v=$(get hermes/hermes.env PGID); pgid=${v:-1000}
  fi
  # the workspace is checked to the bottom; in data only the directory itself and its
  # first level, because Hermes' own init may leave root-owned files deeper down
  for d in hermes/workspace hermes/data; do
    depth=(); [ "$d" = hermes/data ] && depth=(-maxdepth 1)
    if [ ! -d "$d" ]; then
      echo "check-env: warning: $d is missing; Docker would create it as root and Hermes (PUID $puid) could not write it (start-main.sh creates it)" >&2
    elif bad=$(find "$d" "${depth[@]}" ! -uid "$puid" -print -quit 2>/dev/null) && [ -n "$bad" ]; then
      echo "check-env: warning: $bad is not owned by UID $puid (PUID in hermes/hermes.env), so Hermes cannot write it. Fix: sudo chown -R $puid:$pgid $d" >&2
    fi
  done
  # single-file mounts Hermes reads as PUID inside the container; unreadable, it does not
  # start (managed.env) or runs without its persona (SOUL.md)
  for f in hermes/managed.env hermes/SOUL.md; do
    if [ -f "$f" ] && [ -z "$(find "$f" \( -uid "$puid" -perm -u=r \) -o \( -gid "$pgid" -perm -g=r \) -o -perm -o=r 2>/dev/null)" ]; then
      echo "check-env: warning: $f is not readable by UID $puid (PUID in hermes/hermes.env), so Hermes cannot load it. Fix: chmod 644 $f" >&2
    fi
  done
fi

# --- message bus: each system's password equals its login in zenoh.env, every login has an ACL ---
ze=zenoh/zenoh.env$sfx
if [ -f "$ze" ]; then
  for pair in "hermes/hermes.env$sfx ZENOH_PASSWORD_HERMES" "claude-main/claude.env$sfx ZENOH_PASSWORD_CLAUDE"; do
    read -r f k <<<"$pair"
    if [ -f "$f" ] && [ "$(get "$f" "$k")" != "$(get "$ze" "$k")" ]; then
      err "$k differs between $f and $ze (the system logs in to as-zenoh with it)"
    fi
  done
  logins=$(sed -nE 's/^[[:space:]]*ZENOH_PASSWORD_([A-Z0-9_]+)[[:space:]]*=.*/\1/p' "$ze" | tr '[:upper:]' '[:lower:]' | sort -u)
  acl=$(grep -vE '^[[:space:]]*//' zenoh/conf/zenoh.json5 | grep -oE 'usernames:[[:space:]]*\[[^]]*\]' |
        grep -oE '"[^"]+"' | tr -d '"' | sort -u)
  if [ "$logins" != "$acl" ]; then
    msg="logins in $ze ($(tr '\n' ' ' <<<"$logins")) and ACL subjects in zenoh/conf/zenoh.json5 ($(tr '\n' ' ' <<<"$acl")) differ"
    if [ $mode = examples ]; then err "$msg"; else echo "check-env: warning: $msg" >&2; fi
  fi
fi
if [ $mode = local ]; then
  zuid=$(get .env ZENOH_UID 2>/dev/null || true); zuid=${zuid:-1000}
  if [ ! -d zenoh/logs ]; then
    echo "check-env: warning: zenoh/logs is missing; Docker would create it as root and as-zenoh (UID $zuid) could not log (start-main.sh creates it)" >&2
  elif [ "$(stat -c %u zenoh/logs)" != "$zuid" ]; then
    echo "check-env: warning: zenoh/logs is not owned by UID $zuid (ZENOH_UID), so as-zenoh cannot write the message log. Fix: sudo chown $zuid zenoh/logs" >&2
  fi
fi

# --- dns/local.d: a forward to anything but Docker's DNS reopens DNS as a way out ---
for f in dns/local.d/*.conf; do
  [ -f "$f" ] || continue
  if grep -vE '^[[:space:]]*#' "$f" | grep -E '(^|[[:space:]])forward[[:space:]]' | grep -vqE 'forward[[:space:]]+[^[:space:]]+[[:space:]]+127\.0\.0\.11[[:space:]]*$'; then
    echo "check-env: warning: $f forwards queries out of as-net-blind (agents can tunnel data through DNS)" >&2
  fi
done

# --- addresses live only in .env and squid/conf/lan.hosts; everything else uses names ---
ipv4='([0-9]{1,3}\.){3}[0-9]{1,3}'
for f in "${present[@]}" proxy.env docker-compose.yaml compose.hermes-privileged.yaml hermes/config.yaml* hermes/managed.env* zenoh/conf/* \
         litellm/litellm-config.yaml litellm/models/*.yaml dns/Corefile ingress/Caddyfile ingress/dashboard.html squid/conf/* \
         claude-main/policy/*; do
  [ -f "$f" ] || continue
  case $f in .env|.env.example|squid/conf/lan.hosts|squid/conf/lan.hosts.example) continue ;; esac
  while IFS=: read -r n line; do
    line=${line%%[[:space:]]#*}
    if grep -oE "$ipv4" <<<"$line" | grep -vqE '^(127\.|0\.0\.0\.0$)'; then
      err "$f:$n: literal IP address; use a *.as.internal name (LAN hosts: squid/conf/lan.hosts)"
    fi
  done < <(grep -nvE '^[[:space:]]*(#|//|$)' "$f" || true)
done

[ "$fail" = 0 ] && echo "check-env: $mode files OK"
exit "$fail"
