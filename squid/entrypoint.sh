#!/bin/sh
set -e

DB=/var/lib/squid/ssl_db
CERTGEN=/usr/lib/squid/security_file_certgen

# 1. Baza dynamicznie generowanych certyfikatów (tylko przy pierwszym starcie)
if [ ! -d "$DB" ]; then
  echo "entrypoint: tworzę $DB"
  "$CERTGEN" -c -s "$DB" -M 16MB
fi
chown -R proxy:proxy "$DB"

# 2. Katalog logów
mkdir -p /var/log/squid
chown -R proxy:proxy /var/log/squid

# 3. Walidacja konfiguracji: czytelny błąd zamiast cichego restartu
squid -k parse -f /etc/squid/squid.conf

# 4. Squid na pierwszym planie jako PID 1 (sam obsługuje SIGTERM)
exec squid -N -d 1 -f /etc/squid/squid.conf
