#!/bin/bash
# Fails when tracked files contain what AGENTS.md says must never be committed:
# env files, keys/certificates, runtime state, private keys or API tokens.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
while IFS= read -r -d '' f; do
  case $f in
    *.env.example|proxy.env) ;;
    hermes/dashboard-password)
      echo "tracked secret: $f"; fail=1 ;;
    *.env|*.env.*)
      echo "tracked env file: $f"; fail=1 ;;
    *.key|*.pem|*.p12|*.pfx|ssl/squid-ca.*)
      echo "tracked key/certificate material: $f"; fail=1 ;;
    claude-main/data/*|claude-bridge/home/*|claude-bridge/workspace/*|hermes/data/*|hermes/workspace/*|open-webui/data/*|litellm/db/*|squid/logs/*|zenoh/logs/*|dns/logs/*|ingress/logs/*|llm-gw/logs/*|litellm/logs/*)
      echo "tracked runtime state: $f"; fail=1 ;;
  esac
done < <(git ls-files -z)

# private keys and common token formats (Anthropic, GitHub, AWS, OpenAI-style)
if git grep -nIE -e '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' \
     -e 'sk-ant-[A-Za-z0-9_-]{20,}' -e '(ghp|gho|ghs|ghu)_[A-Za-z0-9]{30,}' -e 'github_pat_[A-Za-z0-9_]{30,}' \
     -e 'AKIA[0-9A-Z]{16}' -e 'sk-[A-Za-z0-9]{32,}' -- . ':!tests/check-no-secrets.sh'; then
  fail=1
fi

[ "$fail" = 0 ] && echo "check-no-secrets: clean"
exit "$fail"
