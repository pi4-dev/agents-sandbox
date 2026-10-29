FROM node:22-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl ripgrep jq \
    && rm -rf /var/lib/apt/lists/*
RUN npm install -g @anthropic-ai/claude-code
COPY --from=ssl squid-ca.crt /usr/local/share/ca-certificates/proxy-ca.crt
RUN update-ca-certificates
USER node
WORKDIR /workspace
CMD ["sleep", "infinity"]
