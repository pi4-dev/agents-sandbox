#!/bin/sh
# as-zenoh: the Zenoh router (zenoh.json5) and the message log, in one container.
#
# - Login dictionary: one user per ZENOH_PASSWORD_<NAME> in the environment
#   (zenoh/zenoh.env), user <name> in lower case, written to /tmp (tmpfs).
# - Message log: the REST plugin, on 127.0.0.1 only, streams every put and delete of
#   the bus as server-sent events; each one becomes a line in
#   $LOG_DIR/messages-<UTC date>.jsonl (zenoh/logs/ on the host):
#     {"received":"<UTC time>","event":"PUT|DELETE","sample":{"key":...,"value":...,
#      "encoding":...,"timestamp":...}}
#   A value that is not UTF-8 text or JSON comes base64-encoded. Queries and replies
#   are not logged.
# - When either part stops, the container exits and Docker restarts it.
set -eu
LOG_DIR=${ZENOH_LOG_DIR:-/log}
USERS=/tmp/zenoh-users.txt

umask 077
: >"$USERS"
env | sed -n 's/^ZENOH_PASSWORD_\([A-Z0-9_]*\)=\(..*\)$/\1 \2/p' | while read -r name password; do
  printf '%s:%s\n' "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" "$password" >>"$USERS"
done
if [ ! -s "$USERS" ]; then
  echo "as-zenoh: no ZENOH_PASSWORD_<NAME> in the environment (zenoh/zenoh.env)" >&2
  exit 1
fi
umask 022

/zenohd -c /etc/zenoh/zenoh.json5 &
zpid=$!
trap 'kill "$zpid" 2>/dev/null || true' EXIT INT TERM

i=0
until wget -q -O /dev/null 'http://127.0.0.1:8000/@/*/router' 2>/dev/null; do
  kill -0 "$zpid" 2>/dev/null || { echo "as-zenoh: zenohd exited" >&2; exit 1; }
  i=$((i + 1))
  [ "$i" -lt 60 ] || { echo "as-zenoh: the REST plugin did not come up" >&2; exit 1; }
  sleep 1
done
echo "as-zenoh: logging every put and delete to $LOG_DIR/messages-<UTC date>.jsonl"

event=
wget -q -O - --header 'Accept: text/event-stream' 'http://127.0.0.1:8000/**' |
  while IFS= read -r line; do
    case $line in
      'event: '*) event=${line#event: } ;;
      'data: '*)
        printf '{"received":"%s","event":"%s","sample":%s}\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "${line#data: }" \
          >>"$LOG_DIR/messages-$(date -u +%Y-%m-%d).jsonl" ;;
    esac
  done
echo "as-zenoh: the message stream ended; exiting so Docker restarts the router" >&2
exit 1
