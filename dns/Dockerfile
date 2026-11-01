# as-dns: the CoreDNS binary of COREDNS_IMAGE on Alpine. The official image has no shell,
# and CoreDNS's log plugin writes to stdout only; run.sh copies that stream into daily
# files in dns/logs/ on the host.
ARG COREDNS_IMAGE=coredns/coredns:1.12.4
FROM ${COREDNS_IMAGE} AS coredns

FROM alpine:3.20
COPY --from=coredns /coredns /coredns
COPY run.sh /run.sh
ENTRYPOINT ["/bin/sh", "/run.sh"]
