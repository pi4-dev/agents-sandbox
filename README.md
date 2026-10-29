# agents-env

Homelab environment for running AI agents with Docker Compose, shared LiteLLM API, an intercepting Squid proxy, and network-namespace firewall sidecars.

> **Status: baseline under review.** This repository currently contains the initial architectural audit and a work plan. Do not deploy the archived configuration as a secure multi-tenant agent sandbox without addressing the P0/P1 findings.

## Components

- **Claude Code**, **Hermes Agent**, and **Netshoot** with separate `ae-*-net` firewall sidecars.
- **Squid** as an HTTP/HTTPS proxy with TLS inspection and domain/URL rules.
- **LiteLLM** serving models to the agents and **Open WebUI**.
- **PostgreSQL** on an internal Docker network.
- **macvlan** network for direct LAN connectivity.

## Review and development

- [Security and operational audit](docs/SECURITY_REVIEW.md)
- [Prioritized remediation roadmap](docs/ROADMAP.md)

The source configuration was provided as `agents-env.tgz`. Before deploying, check local addressing and secrets, correct environment-file syntax, verify agent privileges and network enforcement, and run `docker compose config` with test fixtures.

Development policy: small, reviewable changes; no secrets or runtime data in version control; add positive and negative tests for all firewall or Squid ACL modifications.
