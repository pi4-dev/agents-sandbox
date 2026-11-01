FROM node:22-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl ripgrep jq python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"
# client of the message bus (as-zenoh), the router's version: /opt/zenoh/bin/python
ARG ZENOH_VERSION=1.10.2
RUN python3 -m venv /opt/zenoh \
    && /opt/zenoh/bin/pip install --no-cache-dir "eclipse-zenoh==${ZENOH_VERSION}"
COPY --from=ssl squid-ca.crt /usr/local/share/ca-certificates/proxy-ca.crt
RUN update-ca-certificates
USER node
WORKDIR /workspace
CMD ["sleep", "infinity"]
