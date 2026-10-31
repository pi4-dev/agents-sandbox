#!/bin/bash
# Renders docker-compose.yaml with the *.example env files and checks the
# security-relevant parts of the result (no daemon needed).
#
# Usage: tests/compose/validate.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# copy of the working tree (tracked + new, not ignored) with examples as real env files
(
  cd "$REPO"
  git ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' f; do
      if [ -e "$f" ]; then cp --parents "$f" "$W"; fi
    done
)
cp "$W/.env.example" "$W/.env"
while IFS= read -r -d '' f; do
  cp "$f" "${f%.example}"
done < <(find "$W" -name '*.env.example' -print0)
for f in "$W"/squid/conf/*.example "$W"/hermes/config.yaml.example; do cp "$f" "${f%.example}"; done

cd "$W"
docker compose config --format json >config.json
docker compose -f docker-compose.yaml -f compose.hermes-privileged.yaml config --format json >privileged.json

python3 - config.json privileged.json <<'EOF'
import json
import re
import sys

cfg = json.load(open(sys.argv[1]))
priv = json.load(open(sys.argv[2]))
svc = cfg["services"]
env = {}
failures = []


def check(cond, msg):
    print(("PASS  " if cond else "FAIL  ") + msg)
    if not cond:
        failures.append(msg)


for name, s in svc.items():
    env[name] = s.get("environment") or {}
    leftovers = [k for k, v in env[name].items() if v and "${" in str(v)]
    check(not leftovers, f"{name}: every env value is interpolated {leftovers or ''}")

proxy = "http://proxy.as.internal:3128"
llm_proxy = "http://llm-proxy.as.internal:3128"
dns_ip = svc["as-dns"]["networks"]["as-net-blind"]["ipv4_address"]
nets = cfg["networks"]


def members(net):
    return sorted(n for n, s in svc.items() if net in (s.get("networks") or {}))


def aliases(name, net):
    return (svc[name]["networks"][net] or {}).get("aliases") or []


# --- topology: as-net-blind has no route out; only the gateways touch the VLAN ---
for net in ["as-net-blind", "as-net-litellm-egress", "as-net-litellm-db"]:
    check(nets[net].get("internal") is True, f"network {net}: internal (no route out)")
check(members("as-net-vlan") == ["as-ingress", "as-squid"], f"as-net-vlan: only as-squid and as-ingress {members('as-net-vlan')}")
check(members("as-net-litellm-egress") == ["as-litellm", "as-squid"], f"as-net-litellm-egress: only LiteLLM and Squid {members('as-net-litellm-egress')}")
check(list(svc["as-dns"]["networks"]) == ["as-net-blind"], "as-dns: only on as-net-blind (Docker forwards none of its queries)")
for name in ["as-squid", "as-ingress"]:
    sc = svc[name].get("sysctls") or {}
    check(str(sc.get("net.ipv4.ip_forward")) == "0" and str(sc.get("net.ipv4.conf.all.forwarding")) == "0",
          f"{name}: dual-homed, does not route (ip_forward=0)")
for name, s in svc.items():
    if "network_mode" in s:
        check(s["network_mode"].startswith("service:") and s["network_mode"][8:].endswith("-net"),
              f"{name}: shares a sidecar namespace")
    elif name not in ("as-squid", "as-ingress"):
        outside = [n for n in (s.get("networks") or {}) if not nets[n].get("internal")]
        check(not outside, f"{name}: only internal networks {outside or ''}")
want_aliases = {
    "as-dns": "dns", "as-squid": "proxy", "as-litellm": "litellm", "as-open-webui": "open-webui",
    "as-hermes-net": "hermes", "as-netshoot-net": "netshoot", "as-ingress": "ingress",
    "as-claude-net": "claude dev-ws01", "as-claude-bridge-net": "claude-bridge",
}
for name, want in want_aliases.items():
    for a in want.split():
        check(f"{a}.as.internal" in aliases(name, "as-net-blind"), f"{name}: alias {a}.as.internal on as-net-blind")
check(aliases("as-squid", "as-net-litellm-egress") == ["llm-proxy.as.internal"], "as-squid: alias llm-proxy.as.internal on as-net-litellm-egress")
for name, s in svc.items():
    for net, att in (s.get("networks") or {}).items():
        if net != "as-net-vlan" and (att or {}).get("ipv4_address") and name != "as-dns":
            check(False, f"{name}: no fixed address on {net} (Docker assigns it)")
for name in [n for n in svc if n.endswith("-net")]:
    e = env[name]
    check(e.get("PROXY_HOST") == "proxy.as.internal" and "PROXY_PORT" not in e and "PORT_PORT" not in e,
          f"{name}: sidecar gets PROXY_HOST (a name), port fixed at fw.sh's 3128")
    check(e.get("DNS_IP") == dns_ip, f"{name}: sidecar points resolv.conf at as-dns")
    dep = svc[name].get("depends_on", {}).get("as-squid", {})
    check(dep.get("condition") == "service_healthy", f"{name}: waits for a healthy as-squid")
    check("as-dns" in svc[name].get("depends_on", {}), f"{name}: starts after as-dns")
    check("dns" not in svc[name], f"{name}: no Docker-managed DNS (fw.sh writes resolv.conf)")

for name in ["as-hermes", "as-claude-main", "as-claude-bridge", "as-netshoot"]:
    check(env[name].get("HTTPS_PROXY") == proxy, f"{name}: HTTPS_PROXY is {proxy}")
for k in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"]:
    check(env["as-litellm"].get(k) == llm_proxy, f"as-litellm: {k} is {llm_proxy} (its own leg)")

check(not svc["as-hermes"].get("privileged"), "as-hermes: not privileged by default")
check(priv["services"]["as-hermes"].get("privileged") is True,
      "compose.hermes-privileged.yaml: opt-in privileged mode works")

# --- Hermes settings the agent cannot change by editing /opt/data/.env ---
hermes_mounts = {v["target"]: v for v in svc["as-hermes"].get("volumes", [])}
check(hermes_mounts.get("/opt/data/config.yaml", {}).get("read_only") is True,
      "as-hermes: config.yaml mounted read-only")
managed = hermes_mounts.get("/etc/hermes/.env", {})
check(managed.get("type") == "bind" and managed.get("source", "").endswith("/hermes/managed.env")
      and managed.get("read_only") is True and (managed.get("bind") or {}).get("create_host_path") is False,
      "as-hermes: hermes/managed.env read-only at /etc/hermes/.env, never created by Docker")
soul = hermes_mounts.get("/opt/data/SOUL.md", {})
check(soul.get("type") == "bind" and soul.get("source", "").endswith("/hermes/SOUL.md")
      and soul.get("read_only") is True and (soul.get("bind") or {}).get("create_host_path") is False,
      "as-hermes: hermes/SOUL.md read-only at /opt/data/SOUL.md, never created by Docker")
soul_parts = [p for p in open("hermes/SOUL.md.example").read().split("\n\n") if p.strip()]
check(len(soul_parts) > 1,
      "hermes/SOUL.md.example: more than the image's default persona (an unedited default is rewritten, which fails read-only)")
he = env["as-hermes"]
check("HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH" in he and "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD" not in he
      and "HERMES_DASHBOARD_BASIC_AUTH_SECRET" not in he,
      "as-hermes: dashboard login as a password hash; no plaintext password or session secret in its env")
sources = [v.get("source", "") for s in svc.values() for v in s.get("volumes", [])]
check(not [x for x in sources if x.endswith("/hermes") or x.endswith("/hermes/dashboard-password")],
      "no container mounts hermes/dashboard-password (or all of hermes/)")
check(not [t for t in hermes_mounts if t == "/etc/hermes" or t.startswith("/etc/hermes/") and t != "/etc/hermes/.env"],
      "as-hermes: nothing else mounted in /etc/hermes (the image keeps files there)")
check("HERMES_MANAGED_DIR" not in env["as-hermes"], "as-hermes: HERMES_MANAGED_DIR unset (managed scope in /etc/hermes)")
pins = {}
for line in open("hermes/managed.env.example"):
    line = line.strip()
    if line and not line.startswith("#"):
        k, _, v = line.partition("=")
        pins[k.strip()] = v.strip()
rw = sorted(t for t, v in hermes_mounts.items() if v.get("type") == "bind" and not v.get("read_only"))
check(sorted(pins.get("HERMES_WRITE_SAFE_ROOT", "").split(":")) == rw,
      f"managed.env: HERMES_WRITE_SAFE_ROOT = the read-write mounts of as-hermes {rw}")
for k, want in [("HERMES_ALLOW_PRIVATE_URLS", "false"), ("HERMES_ENABLE_PROJECT_PLUGINS", "false"),
                ("HERMES_EPHEMERAL_SYSTEM_PROMPT", ""), ("HERMES_PREFILL_MESSAGES_FILE", ""),
                ("HERMES_IGNORE_RULES", "false")]:
    check(pins.get(k) == want, f"managed.env: {k}={want}")
home_dirs = {t.rsplit("/", 1)[0] for t in ("/opt/data/config.yaml", "/opt/data/SOUL.md") if t in hermes_mounts}
check(pins.get("HERMES_HOME") == "/opt/data" and "/opt/data" in hermes_mounts and home_dirs == {"/opt/data"},
      "managed.env: HERMES_HOME=/opt/data, where the data volume and the read-only config.yaml and SOUL.md are")
hermes_cfg = open("hermes/config.yaml.example").read()
check(re.search(r"(?m)^security:\n(?:[ \t]*(?:#.*)?\n)*[ \t]+redact_secrets:[ \t]*true[ \t]*$", hermes_cfg) is not None,
      "hermes/config.yaml: security.redact_secrets is true")
for name, s in svc.items():
    mounts = [v.get("source", "") for v in s.get("volumes", [])]
    check(not any("docker.sock" in m for m in mounts), f"{name}: no Docker socket mount")
    if name != "as-hermes":
        check(not s.get("privileged"), f"{name}: not privileged")

ns_mounts = {v["target"]: v for v in svc["as-netshoot"].get("volumes", [])}
check(ns_mounts.get("/usr/local/share/ca-certificates/proxy-ca.crt", {}).get("source", "").endswith("ssl/squid-ca.crt"),
      "as-netshoot: trusts the proxy CA")
check("server.mjs" not in " ".join(svc["as-claude-main"].get("command", [])),
      "as-claude-main: does not run the bridge")
bridge = svc["as-claude-bridge"]
check(bridge.get("network_mode") == "service:as-claude-bridge-net", "as-claude-bridge: behind its own sidecar")
check(svc["as-claude-main"].get("network_mode") == "service:as-claude-net", "as-claude-main: behind as-claude-net")
check(env["as-claude-bridge"].get("CLAUDE_OAI_KEY") and not env["as-claude-main"].get("CLAUDE_OAI_KEY"),
      "CLAUDE_OAI_KEY reaches the bridge, not the agent")
agent_src = {v["target"]: v.get("source", "") for v in svc["as-claude-main"]["volumes"]}
bridge_src = {v["target"]: v.get("source", "") for v in bridge["volumes"]}
check(bridge_src["/workspace"] != agent_src["/workspace"] and bridge_src["/home/node"] != agent_src["/home/node"]
      and not any("claude-main/data" in s for s in bridge_src.values()),
      "as-claude-bridge: own workspace and home, nothing from the agent's claude-main/data")
check(bridge.get("build", {}).get("context", "").endswith("/claude-bridge") and bridge.get("image") == "agents-sandbox/claude-bridge",
      "as-claude-bridge: its own image, built from claude-bridge/ (code baked in)")
check(not any("claude-main" in v.get("source", "") for v in bridge["volumes"]),
      "as-claude-bridge: no mount from claude-main (data, policy, CLAUDE.md)")
check(bridge.get("read_only") is True and bridge.get("cap_drop") == ["ALL"],
      "as-claude-bridge: read-only root filesystem, no capabilities")
check(env["as-claude-bridge"].get("PORT") == "9090", "as-claude-bridge: listens on 9090 (ALLOW_IN, api_base)")
check(not set(env["as-claude-main"]) & {"CLAUDE_OAI_KEY", "CLAUDE_OAI_SYSTEM_PROMPT_FILE"},
      "as-claude-main: no bridge settings (separate env files)")
check(env["as-claude-net"].get("ALLOW_IN") == "any::netshoot.as.internal",
      "as-claude-net: nothing inbound but as-netshoot (the bridge port is elsewhere)")
check(env["as-claude-bridge-net"].get("ALLOW_IN") == "tcp:9090:litellm.as.internal any::netshoot.as.internal",
      "as-claude-bridge-net: :9090 from LiteLLM (and anything from as-netshoot)")
blind_subnet = nets["as-net-blind"]["ipam"]["config"][0]["subnet"]
check(env["as-netshoot-net"].get("ALLOW_OUT") == f"any:{blind_subnet}" and not env["as-netshoot-net"].get("ALLOW_IN"),
      "as-netshoot-net: everything out to as-net-blind, nothing inbound")
check("healthcheck" in bridge, "as-claude-bridge: has a healthcheck")
check("healthcheck" in svc["as-squid"], "as-squid: has a healthcheck")
for name in ["as-squid", "as-claude-main", "as-claude-bridge"]:
    check(svc[name].get("pull_policy") == "build", f"{name}: image rebuilt on every up (files baked in)")

squid_mounts = {v["target"]: v for v in svc["as-squid"]["volumes"]}
check(squid_mounts.get("/etc/squid/conf", {}).get("read_only") is True,
      "as-squid: config directory mounted read-only")
check(all(not t.startswith("/etc/squid/conf/") for t in squid_mounts),
      "as-squid: no single-file mounts inside /etc/squid/conf")

for name in ["as-litellm", "as-open-webui", "as-ingress"]:
    check(svc[name].get("dns") == [dns_ip], f"{name}: unknown names go to as-dns")
check("dns" not in svc["as-squid"] and env["as-squid"].get("SQUID_DNS_UPSTREAM"),
      "as-squid: resolves internet names itself (SQUID_DNS_UPSTREAM)")
check(env["as-hermes-net"].get("ALLOW_IN") == "tcp:9119:ingress.as.internal any::netshoot.as.internal",
      "as-hermes-net: dashboard reachable only from as-ingress")
ing = svc["as-ingress"]
check(ing.get("read_only") is True and ing.get("cap_drop") == ["ALL"], "as-ingress: read-only, no capabilities but NET_BIND_SERVICE")
check(env["as-ingress"].get("HERMES_DASHBOARD_ALLOW_FROM"), "as-ingress: gets HERMES_DASHBOARD_ALLOW_FROM")
check(env["as-ingress"].get("INGRESS_DASHBOARD_ALLOW_FROM"), "as-ingress: gets INGRESS_DASHBOARD_ALLOW_FROM")
ing_mounts = {v["target"]: v for v in ing.get("volumes", [])}
check(ing_mounts.get("/etc/caddy", {}).get("read_only") is True
      and ing_mounts["/etc/caddy"]["source"].endswith("/ingress"),
      "as-ingress: ingress/ mounted read-only at /etc/caddy (Caddyfile and dashboard)")
check(env["as-open-webui"].get("OPENAI_API_BASE_URL") == "http://litellm.as.internal:4000/v1",
      "as-open-webui: reaches LiteLLM by name")
for name in ["as-claude-main", "as-claude-bridge"]:
    targets = [v["target"] for v in svc[name].get("volumes", [])]
    check("/etc/hosts" not in targets and "/etc/resolv.conf" not in targets,
          f"{name}: no hand-written /etc/hosts or /etc/resolv.conf")
litellm_mounts = {v["target"]: v for v in svc["as-litellm"]["volumes"]}
check(litellm_mounts.get("/app/models", {}).get("read_only") is True, "as-litellm: model sets mounted read-only")
llm_net = nets["as-net-litellm-egress"]["ipam"]["config"][0]["subnet"]
check(env["as-squid"].get("SQUID_LITELLM_NET") == llm_net, "as-squid: LLM provider APIs keyed on the as-net-litellm-egress network")
check(llm_net in env["as-squid"].get("SQUID_LOCALNET", "").split(), "as-squid: LiteLLM's leg is in localnet")
keys = svc["as-litellm-keys"]
check(list(keys.get("networks", {})) == ["as-net-litellm-db"], "as-litellm-keys: only on the internal DB network")
check(keys.get("depends_on", {}).get("as-litellm", {}).get("condition") == "service_healthy",
      "as-litellm-keys: runs after LiteLLM is healthy")
for name in ["as-hermes", "as-open-webui"]:
    check(svc[name].get("depends_on", {}).get("as-litellm-keys", {}).get("condition") == "service_completed_successfully",
          f"{name}: starts after its LiteLLM key is registered")
dns = svc["as-dns"]
check(dns.get("read_only") is True and dns.get("cap_drop") == ["ALL"], "as-dns: read-only, no capabilities but NET_BIND_SERVICE")

if failures:
    sys.exit(f"compose validate: {len(failures)} check(s) failed")
print("compose validate: all checks passed")
EOF
