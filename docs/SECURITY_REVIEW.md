# Initial security and operations audit

**Date:** 2026-10-29  
**Source:** user-provided `agents-env.tgz`  
**Method:** static configuration review; no live containers or traffic tests performed.

## Executive summary

The architecture is promising for a controlled homelab: multiple sidecar network namespaces, IPv4 default-deny rules, a centrally managed HTTPS-inspecting Squid proxy, LiteLLM, and a separate database network. It is **not yet a trustworthy isolation boundary for an autonomous privileged agent**.

The most important fixes are removal/isolation of Hermes privileged execution, separating agent-accessible workspaces from secrets at the OS level, and validating actual network restrictions rather than assuming `HTTP_PROXY` enforces them.

## Findings

| ID | Priority | Location | Risk | Action |
| --- | --- | --- | --- | --- |
| SEC-01 | **P0** | `docker-compose.yaml`, `ae-hermes` | `privileged: true` with `network_mode: service:ae-hermes-net` can permit modification of rules in the shared network namespace. `approvals.mode: false` increases blast radius. | Remove privileged execution and audit required capabilities, or place this agent in an isolated VM with external firewall enforcement. |
| SEC-02 | **P0** | `claude-main/policy/managed-settings.json` | `Read(**/.env)` etc. are Claude Code tool permissions, not OS-enforced filesystem restrictions; indirect reads through code may remain possible. | Isolate secrets using UID, mounts and access controls; test indirect reads. |
| CFG-01 | **P1** | `.env.example`, `proxy.env`, `**/*.env.example` | Examples use YAML-like `KEY: value` syntax, not the `KEY=value` format expected for Compose environment files. | Convert env files, validate `docker compose config`. |
| CFG-02 | **P1** | `docker-compose.yaml` | `PORT_PORT: ${PROXY_PORT}` is a typo; the sidecar receives no `PROXY_PORT` and defaults to 3128. | Correct variable name, add config assertions. |
| SEC-03 | **P1** | `docker-compose.yaml` | Open WebUI, LiteLLM and Squid attach directly to macvlan and do not inherit agent sidecar policies. Without `ports:`, they can still be LAN-reachable. | Define ingress/egress trust zones and network ACLs. |
| SEC-04 | **P1** | `fw/fw.sh` | `ip6tables` errors are ignored; sidecar readiness does not guarantee IPv6 default deny. | Fail closed, or explicitly disable IPv6 and verify it. |
| OPS-01 | **P1** | `docker-compose.yaml`, `ae-claude-main` | The `server.mjs` restart loop is backgrounded while `sleep infinity` keeps the container alive; bridge failure can be hidden. | Separate bridge as a service and add meaningful healthchecks. |
| OPS-02 | **P1** | `ae-squid` / `depends_on` | `service_started` does not prove proxy readiness. | Add proxy healthcheck, test failure and restart behavior. |
| NET-01 | **P2** | `docker-compose.yaml` | `192.19.255.0/24` is not RFC1918 private addressing. | Migrate to dedicated RFC1918 addressing with policy updates. |
| OPS-03 | **P2** | `ssl/init_ca.sh` | CA key and cert paths depend on current directory. | Anchor outputs to script directory and document secure CA handling. |
| OPS-04 | **P2** | Dockerfiles / Compose | Floating image tags, unpinned npm dependency and no evident CI checks. | Pin releases/digests and add reproducible checks. |
| SEC-05 | **P2** | Squid ACLs | GitHub write restrictions based on URL and HTTP methods are not a complete data-exfiltration boundary. TLS bump also creates logging/privacy implications. | Threat model, egress regression tests, retention/access policy. |
| DOC-01 | **P2** | Hermes Compose comments | Comments mention a mounted Docker socket, but no such mount is present in the supplied file. | Correct comments and audit live mounts. |

## Strengths worth retaining

- Separate sidecar namespaces and default-drop IPv4 policies for agent containers.
- Centralized proxy, domain/URL controls and upstream certificate error rejection.
- Shared LiteLLM API and `internal: true` PostgreSQL network.
- Read-only mounts for selected policy files and bounded Docker logs.

## Security boundary principles

1. **Container policy is not prompt policy.** Deny rules for agent tools do not replace Linux filesystem permissions.
2. **Proxy settings are not enforcement.** A malicious process can ignore environment proxy variables; independent network controls must block bypass attempts.
3. **Privilege escalation invalidates in-namespace controls.** A privileged agent may be able to change the firewall in a shared namespace.
4. **macvlan exposes services to the physical network.** Control access to Web UI, LiteLLM and Squid separately from the agent egress policy.
5. **Secrets stay outside Git.** Never commit private CA keys, API keys, session files, workspace caches or local production `.env` files.

## Acceptance tests before trusted use

- [ ] Compose environment variables parse correctly and configuration validates.
- [ ] Autonomous agents cannot modify firewall controls or access the Docker daemon.
- [ ] Agents cannot read unrelated secrets through direct or indirect commands.
- [ ] IPv4/IPv6 direct egress, unauthorized LAN access, DNS and proxy bypass are blocked.
- [ ] Allowed HTTPS requests succeed; prohibited hosts, Git push and write APIs fail.
- [ ] Broken Claude bridge or Squid results in an unhealthy service state.
- [ ] Certificate errors fail closed; CA key handling and log retention are documented.
- [ ] CI catches malformed shell, Compose and security policy changes.

**Review limitation:** findings are hypotheses from source inspection until validated against the running Docker host.
