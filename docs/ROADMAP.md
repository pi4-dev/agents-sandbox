# Hardening roadmap

The goal is to preserve current experimental functionality while separating a **full-trust lab mode** from a **restricted agent mode**. Avoid mixing unrelated security changes in one pull request.

## Phase 0 — Reproducible configuration

1. Correct `.env.example`, `proxy.env` and service env file syntax (`KEY=value`); fix `PORT_PORT` vs `PROXY_PORT`.
2. Add sanitized fixture values and a `docker compose config` CI check.
3. Add shell lint, secret scanning and configuration checks.
4. Fix `ssl/init_ca.sh` current-directory assumptions and document CA rotation.

**Acceptance:** clean static validation and no committed credentials.

## Phase 1 — Trust boundaries (highest priority)

1. Eliminate `privileged: true` for Hermes or isolate the privileged mode in a dedicated VM.
2. Inventory Linux capabilities and mounted host paths; ensure the agent cannot change its network enforcement.
3. Enforce secret protection with filesystem and mount isolation; test indirect reads.
4. Implement verified fail-closed IPv6 rules.

**Acceptance:** compromise of an agent process cannot change firewall controls or read unrelated secrets.

## Phase 2 — Reliable lifecycle

1. Move the Claude bridge into its own service with a real healthcheck.
2. Add a Squid healthcheck and use meaningful `depends_on` conditions.
3. Separate LiteLLM process liveness from model readiness.
4. Correct obsolete comments describing nonexistent Docker socket mounts.

**Acceptance:** actual model/proxy failure is visible as unhealthy, not merely `running`.

## Phase 3 — Network and operations

1. Document VLAN zones, macvlan LAN exposure, ACLs and authenticated management access.
2. Replace non-RFC1918 addressing if feasible.
3. Automate positive/negative tests of Squid ACL, HTTP methods, Git read-only controls and direct egress.
4. Pin images/npm dependencies and document upgrades, backups, log retention and rollback.

## PR rules

- Every P0/P1 fix includes an acceptance test.
- Network ACL changes include a permitted and a rejected traffic case.
- No committed secrets, CA private keys, runtime volumes or workspace contents.
- Preserve a known-good baseline and rollback path.
