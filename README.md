# agents-env

Docker Compose homelab for AI coding agents with a shared LiteLLM API, an HTTPS-inspecting Squid proxy and network namespace firewall sidecars.

> **Status: imported baseline, not security-hardened.** Source files have been imported from the supplied `agents-env.tgz` archive without functional changes. The configuration has known P0/P1 security and deployment issues. See the review before running it.

## Components

| Component | Purpose |
| --- | --- |
| `ae-claude-main`, `ae-claude-net` | Claude Code and its network-namespace firewall |
| `ae-hermes`, `ae-hermes-net` | Hermes Agent and its network-namespace firewall |
| `ae-netshoot`, `ae-netshoot-net` | Troubleshooting container and firewall |
| `ae-squid` | Central HTTPS proxy and TLS inspection |
| `ae-litellm` | Shared API routing to LLM models |
| `ae-litellm-db` | PostgreSQL on a Docker `internal` network |
| `ae-open-webui` | Web UI for models |

## Repository layout

```text
docker-compose.yaml        Compose topology and network definitions
.env.example              Example addresses (currently invalid env-file syntax)
proxy.env                 Agent proxy variables (currently invalid env-file syntax)
start-main.sh             Startup helper
claude-main/              Claude image, policy and environment example
hermes/                   Hermes configuration and environment example
fw/                       Network namespace firewall rules
litellm/                  LiteLLM model/database configuration
open-webui/               Web UI environment example
squid/                    Proxy image, ACLs and error pages
ssl/                      CA creation script (no CA private key committed)
docs/                     Security review and remediation roadmap
AGENTS.md                 Contribution and agent-work instructions
```

## Architecture notes

- The current network uses Docker `macvlan` with parent `vlan100`. Update this to match the deployment host.
- Agent processes share the network namespace of their `ae-*-net` sidecars.
- Squid controls selected HTTP(S) egress, while LiteLLM, Open WebUI and Squid have direct macvlan attachment and need independent LAN access controls.
- The current `192.19.255.0/24` subnet is not RFC1918 space.
- Docker environment files should use `KEY=value`; imported examples currently use `KEY: value`. This is a known defect, not a recommended deployment convention.
- Hermes currently has `privileged: true`, which can undermine the sidecar isolation model. This must be addressed before treating the environment as sandboxed.

## Before deployment

1. Read [Security audit](docs/SECURITY_REVIEW.md) and [Roadmap](docs/ROADMAP.md).
2. Adapt network addressing, VLANs, endpoints and source restrictions.
3. Repair and validate env files: `docker compose config` with safe test values.
4. Generate CA material locally. Never commit private keys, model tokens or runtime env files.
5. Resolve agent privilege and secrets isolation concerns, then verify fail-closed IPv4/IPv6 egress.
6. Add automated tests and monitor actual proxy and model readiness before relying on this stack.

**No containers were launched as part of the import.** Functional changes will be addressed separately through tracked issues and focused pull requests.
