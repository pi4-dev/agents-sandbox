#!/bin/sh
# as-dns: CoreDNS with its log (the log plugin: every query with its source; errors) on
# stdout, for `docker compose logs as-dns`, and in $LOG_DIR/queries-<UTC date>.log
# (dns/logs/ on the host), one file a day; files older than $LOG_KEEP_DAYS days are
# deleted. When CoreDNS stops, the container exits and Docker restarts it.
set -eu
LOG_DIR=${LOG_DIR:-/var/log/coredns}
KEEP=${LOG_KEEP_DAYS:-7}

/coredns "$@" 2>&1 | awk -v dir="$LOG_DIR" -v keep="$KEEP" '
  {
    day = strftime("%Y-%m-%d")
    if (day != cur) {
      if (file != "") close(file)
      cur = day
      file = dir "/queries-" day ".log"
      system("find " dir " -name \"queries-*.log\" -mtime +" (keep - 1) " -delete")
    }
    print >> file; fflush(file)
    print; fflush()
  }'
echo "as-dns: CoreDNS stopped" >&2
exit 1
