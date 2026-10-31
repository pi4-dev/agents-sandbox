FROM ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends squid-openssl ca-certificates \
 && test -x /usr/lib/squid/security_file_certgen \
 && squid -v | grep -q -- '--with-openssl' \
 && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
