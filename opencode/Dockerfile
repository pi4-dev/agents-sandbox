# as-opencode: the opencode agent (V2, npm @opencode/cli: a native binary chosen by its
# postinstall), git and ripgrep for its tools, the message bus client, the proxy CA.
FROM node:22-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl ripgrep jq python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*
# pinned: opencode's own update is off (opencode.jsonc), a new version comes with a rebuild
ARG OPENCODE_VERSION=2.3.2
RUN npm install -g "@opencode/cli@${OPENCODE_VERSION}" && npm cache clean --force \
    && opencode --version
# client of the message bus (as-zenoh), the router's version: /opt/zenoh/bin/python
ARG ZENOH_VERSION=1.10.2
RUN python3 -m venv /opt/zenoh \
    && /opt/zenoh/bin/pip install --no-cache-dir "eclipse-zenoh==${ZENOH_VERSION}"
COPY --from=ssl squid-ca.crt /usr/local/share/ca-certificates/proxy-ca.crt
RUN update-ca-certificates
USER node
WORKDIR /workspace
CMD ["sleep", "infinity"]
