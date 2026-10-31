# as-claude-bridge: the OpenAI-compatible shim (server.mjs) and its dependencies,
# baked into the image and owned by root. The bridge runs as node and cannot change
# its own code; the agent has no access to this image or its directories at all.
FROM node:22-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git ripgrep \
    && rm -rf /var/lib/apt/lists/*
# the Claude Code CLI, for the bridge's own login (claude, then /login) or `claude setup-token`
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" && npm cache clean --force
COPY --from=ssl squid-ca.crt /usr/local/share/ca-certificates/proxy-ca.crt
RUN update-ca-certificates
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY server.mjs ./
USER node
WORKDIR /workspace
CMD ["node", "/app/server.mjs"]
