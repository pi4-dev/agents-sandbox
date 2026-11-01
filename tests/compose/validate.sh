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
    "as-claude-net": "claude dev-ws01", "as-claude-bridge-net": "claude-bridge", "as-claude-qwen-net": "claude-qwen", "as-llm-gw": "llm", "as-zenoh": "zenoh",
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

for name in ["as-hermes", "as-claude-main", "as-claude-bridge", "as-claude-qwen", "as-netshoot"]:
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
compose_src = open("docker-compose.yaml").read()


def file_mount(source, target):
    """A read-only bind of one host file that Docker never creates. Checked in the file
    itself: the rendered config shows the short syntax (Docker creates a missing source as a
    directory) and a long one with create_host_path: false alike in some Compose versions."""
    m = hermes_mounts.get(target, {})
    rendered = (m.get("type") == "bind" and m.get("source", "").endswith(source[1:]) and m.get("read_only") is True
                and (m.get("bind") or {}).get("create_host_path") is not True)
    written = re.search(r"- type: bind\n\s+source: " + re.escape(source) + r"\n\s+target: " + re.escape(target)
                        + r"\n\s+read_only: true\n\s+bind:\n\s+create_host_path: false\n", compose_src)
    return rendered and written is not None


check(file_mount("./hermes/managed.env", "/etc/hermes/.env"),
      "as-hermes: hermes/managed.env read-only at /etc/hermes/.env, never created by Docker")
check(file_mount("./hermes/SOUL.md", "/opt/data/SOUL.md"),
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

for name in ["as-litellm", "as-open-webui", "as-ingress", "as-llm-gw", "as-zenoh"]:
    check(svc[name].get("dns") == [dns_ip], f"{name}: unknown names go to as-dns")
check("dns" not in svc["as-squid"] and env["as-squid"].get("SQUID_DNS_UPSTREAM"),
      "as-squid: resolves internet names itself (SQUID_DNS_UPSTREAM)")
# --- as-llm-gw: the agents' way to LiteLLM ---
check(env["as-hermes-net"].get("ALLOW_OUT") == "tcp:llm.as.internal:4000 tcp:zenoh.as.internal:7447",
      "as-hermes-net: out only to as-llm-gw (not LiteLLM directly) and the message bus")

# --- as-zenoh: the message bus, a login and an ACL per system, every message logged ---
check(env["as-claude-net"].get("ALLOW_OUT") == "tcp:zenoh.as.internal:7447", "as-claude-net: out to the message bus only")

# --- as-claude-qwen: Claude Code on a LiteLLM model, like Hermes ---
check(env["as-claude-qwen-net"].get("ALLOW_OUT") == "tcp:llm.as.internal:4000 tcp:zenoh.as.internal:7447"
      and env["as-claude-qwen-net"].get("ALLOW_IN") == "any::netshoot.as.internal",
      "as-claude-qwen-net: out only to as-llm-gw and the bus, in only from netshoot")
cq = env["as-claude-qwen"]
check(svc["as-claude-qwen"].get("network_mode") == "service:as-claude-qwen-net", "as-claude-qwen: behind as-claude-qwen-net")
check(cq.get("ANTHROPIC_BASE_URL") == "http://llm.as.internal:4000" and cq.get("ANTHROPIC_AUTH_TOKEN")
      and "ANTHROPIC_API_KEY" not in cq, "as-claude-qwen: Anthropic API of LiteLLM through as-llm-gw, its own key")
models_cq = {cq.get(k) for k in ("ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                                 "ANTHROPIC_DEFAULT_HAIKU_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL")}
check(len(models_cq) == 1 and None not in models_cq, f"as-claude-qwen: every Claude Code model slot is CLAUDE_QWEN_MODEL {models_cq}")
keys_env = env["as-litellm-keys"].get("LITELLM_CLIENT_KEYS", "")
check("claude-qwen=ANTHROPIC_AUTH_TOKEN" in keys_env.split() and env["as-litellm-keys"].get("ANTHROPIC_AUTH_TOKEN") == cq.get("ANTHROPIC_AUTH_TOKEN"),
      "as-litellm-keys: registers the claude-qwen key")
check(not [v for v in svc["as-claude-qwen"]["volumes"] if "claude-main/data" in v.get("source", "")],
      "as-claude-qwen: own workspace and home, nothing from claude-main/data")
check("zenoh" not in str(env["as-claude-bridge-net"].get("ALLOW_OUT", "")), "as-claude-bridge-net: not on the message bus")
zen = svc["as-zenoh"]
check(list(zen.get("networks", {})) == ["as-net-blind"], "as-zenoh: only on as-net-blind")
check(zen.get("read_only") is True and zen.get("cap_drop") == ["ALL"] and not zen.get("cap_add")
      and "no-new-privileges:true" in (zen.get("security_opt") or []),
      "as-zenoh: read-only, no capabilities, no-new-privileges")
check(str(zen.get("user", "0")).split(":")[0] not in ("", "0", "root"), f"as-zenoh: not root ({zen.get('user')})")
zen_mounts = {v["target"]: v for v in zen.get("volumes", [])}
check(zen_mounts.get("/etc/zenoh", {}).get("read_only") is True and zen_mounts["/etc/zenoh"]["source"].endswith("/zenoh/conf"),
      "as-zenoh: zenoh/conf mounted read-only")
check(zen_mounts.get("/log", {}).get("source", "").endswith("/zenoh/logs") and not zen_mounts["/log"].get("read_only"),
      "as-zenoh: writes the message log to zenoh/logs on the host")
check("healthcheck" in zen, "as-zenoh: has a healthcheck")
zver = zen.get("image", "").rpartition(":")[2]
check(re.fullmatch(r"\d+\.\d+\.\d+", zver) is not None, f"as-zenoh: image pinned to a release ({zen.get('image')})")
check(svc["as-claude-main"].get("build", {}).get("args", {}).get("ZENOH_VERSION") == zver
      and env["as-hermes"].get("ZENOH_VERSION") == zver, "agents get the router's client version")
zen_users = sorted(k[len("ZENOH_PASSWORD_"):].lower().replace("_", "-") for k in env["as-zenoh"] if k.startswith("ZENOH_PASSWORD_"))
zen_cfg = open("zenoh/conf/zenoh.json5").read()
zen_code = "\n".join(l for l in zen_cfg.splitlines() if not l.lstrip().startswith("//"))
acl_users = sorted(re.findall(r'usernames:\s*\["([^"]+)"\]', zen_code))
check(zen_users and zen_users == acl_users, f"as-zenoh: a login for each ACL subject {zen_users}")
for agent, user in [("as-hermes", "hermes"), ("as-claude-main", "claude"), ("as-claude-qwen", "claude-qwen")]:
    e = env[agent]
    check(e.get("ZENOH_USER") == user and e.get("ZENOH_CONNECT") == "tcp/zenoh.as.internal:7447"
          and "ZENOH_PASSWORD_" + user.upper().replace("-", "_") in e, f"{agent}: logs in to the bus as {user}")
for user in acl_users:
    own = re.search(r'id:\s*"own-' + user + r'"(.*?)\}', zen_code, re.S)
    check(own and re.search(r'key_exprs:\s*\["as/' + user + r'/\*\*"\]', own.group(1))
          and re.search(r'flows:\s*\["ingress"\]', own.group(1)),
          f"as-zenoh: {user} publishes only under as/{user}/**")
check(re.search(r'listen:\s*\{\s*endpoints:\s*\["tcp/0\.0\.0\.0:7447"\]', zen_code)
      and re.search(r'multicast:\s*\{\s*enabled:\s*false', zen_code),
      "as-zenoh: listens on tcp/7447 (IPv4), no multicast scouting")
check(re.search(r'rest:\s*\{\s*http_port:\s*"127\.0\.0\.1:8000"', zen_code),
      "as-zenoh: REST (the log's subscriber, no login, no ACL) on 127.0.0.1 only")
check(re.search(r'access_control:\s*\{\s*enabled:\s*true,\s*default_permission:\s*"deny"', zen_code)
      and re.search(r'usrpwd:\s*\{\s*dictionary_file:', zen_code),
      "as-zenoh: logins required, ACL default deny")
hermes_mounts_ca = {v["target"]: v for v in svc["as-hermes"].get("volumes", [])}
ca_hook = hermes_mounts_ca.get("/etc/cont-init.d/00-proxy-ca", {})
check(hermes_mounts_ca.get("/usr/local/share/ca-certificates/proxy-ca.crt", {}).get("source", "").endswith("ssl/squid-ca.crt")
      and ca_hook.get("source", "").endswith("/hermes/ca-trust.sh") and ca_hook.get("read_only") is True,
      "as-hermes: the proxy CA joins the system store at start (s6 cont-init hook)")
check(env["as-hermes"].get("SSL_CERT_FILE") == env["as-hermes"].get("REQUESTS_CA_BUNDLE") == "/etc/ssl/certs/ca-certificates.crt"
      and env["as-hermes"].get("NODE_EXTRA_CA_CERTS") == "/usr/local/share/ca-certificates/proxy-ca.crt",
      "as-hermes: certifi, OpenSSL and Node point at a bundle with the proxy CA")
check(svc["as-hermes"].get("depends_on", {}).get("as-llm-gw") is not None, "as-hermes: starts after as-llm-gw")
check(re.search(r'(?m)^\s*api:\s*"?http://llm\.as\.internal:4000/v1"?\s*$', open("hermes/config.yaml.example").read()),
      "hermes/config.yaml: LiteLLM through as-llm-gw")
gw = svc["as-llm-gw"]
check(gw.get("read_only") is True and gw.get("cap_drop") == ["ALL"] and gw.get("cap_add") == ["NET_BIND_SERVICE"],
      "as-llm-gw: read-only, no capabilities but NET_BIND_SERVICE")
check(list(gw.get("networks", {})) == ["as-net-blind"], "as-llm-gw: only on as-net-blind")
gw_mounts = {v["target"]: v for v in gw.get("volumes", [])}
check(gw_mounts.get("/etc/caddy", {}).get("read_only") is True and gw_mounts["/etc/caddy"]["source"].endswith("/llm-gw"),
      "as-llm-gw: llm-gw/ mounted read-only at /etc/caddy")
gw_cfg = open("llm-gw/Caddyfile").read()
gw_paths = re.search(r"(?m)^\s*@client_routes path (.+)$", gw_cfg)
keys_src = open("litellm/litellm-keys.py").read()
keys_default = re.search(r'ROUTES = os\.environ\.get\("LITELLM_CLIENT_ROUTES", " "\.join\(\((.*?)\)\)\)\.split\(\)', keys_src, re.S)
key_routes = sorted(re.findall(r'"(/[^"]*)"', keys_default.group(1))) if keys_default else []
check(key_routes and gw_paths and sorted(gw_paths.group(1).split()) == key_routes,
      f"as-llm-gw: forwards exactly the default client-key routes {key_routes}")
check(not [r for r in key_routes if "embeddings" in r], "client keys: no embeddings route by default")
check("/v1/messages" in key_routes, "client keys and as-llm-gw: the Anthropic API (/v1/messages) for Claude Code")
check(re.search(r"(?m)^\s*reverse_proxy litellm\.as\.internal:4000 \{", gw_cfg) and re.search(r"(?m)^\s*respond 404\s*$", gw_cfg),
      "as-llm-gw: those routes to LiteLLM, everything else a 404")
check(re.search(r"(?m)^\s*header_down -llm_provider-\*\s*$", gw_cfg) and re.search(r"(?m)^\s*header_down -x-litellm-model-\*\s*$", gw_cfg),
      "as-llm-gw: drops the llm_provider-* and x-litellm-model-* response headers")
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

# --- access logs: files in <service>/logs on the host, like squid/logs ---
log_dirs = {"as-dns": ("/var/log/coredns", "/dns/logs"), "as-ingress": ("/var/log/caddy", "/ingress/logs"),
            "as-llm-gw": ("/var/log/caddy", "/llm-gw/logs"), "as-litellm": ("/var/log/litellm", "/litellm/logs")}
for name, (target, src) in log_dirs.items():
    m = {v["target"]: v for v in svc[name].get("volumes", [])}.get(target, {})
    check(m.get("source", "").endswith(src) and not m.get("read_only"), f"{name}: access log in {src[1:]} on the host")
for name in ["as-dns", "as-ingress", "as-llm-gw"]:
    sv = svc[name]
    check(str(sv.get("user", "0")).split(":")[0] not in ("", "0", "root") and sv.get("read_only") is True
          and sv.get("cap_drop") == ["ALL"], f"{name}: runs as LOGS_UID ({sv.get('user')}), read-only, no capabilities")
check(str((svc["as-dns"].get("sysctls") or {}).get("net.ipv4.ip_unprivileged_port_start")) == "53",
      "as-dns: binds :53 without root (in its own namespace)")
check(str((svc["as-ingress"].get("sysctls") or {}).get("net.ipv4.ip_unprivileged_port_start")) == "80",
      "as-ingress: binds :80 without root (in its own namespace)")
check(svc["as-dns"].get("build", {}).get("context", "").endswith("/dns") and svc["as-dns"].get("pull_policy") == "build",
      "as-dns: built from dns/ (CoreDNS and the log writer)")
for f in ["ingress/Caddyfile", "llm-gw/Caddyfile"]:
    code = "\n".join(l for l in open(f).read().splitlines() if not l.lstrip().startswith("#"))
    check(re.search(r"log \{\s*output file /var/log/caddy/access\.log \{[^}]*roll_keep_for 7d", code),
          f"{f}: access log to /var/log/caddy/access.log, 7 days kept")
lc = json.load(open("litellm/logging.json"))
fh = lc.get("handlers", {}).get("access_file", {})
check(fh.get("class") == "logging.handlers.TimedRotatingFileHandler" and fh.get("filename") == "/var/log/litellm/access.log"
      and fh.get("when") == "midnight" and fh.get("backupCount") == 7
      and "access_file" in lc.get("loggers", {}).get("uvicorn.access", {}).get("handlers", []),
      "litellm/logging.json: uvicorn access log to /var/log/litellm/access.log, daily, 7 kept")
hc = " ".join(svc["as-litellm"].get("healthcheck", {}).get("test", []))
check(env["as-litellm"].get("LITELLM_DISABLE_ACCESS_LOG_PATHS") == "/health/liveliness" and "/health/liveliness" in hc,
      "as-litellm: the healthcheck's /health/liveliness stays out of the access log")
cmd = svc["as-litellm"].get("command", [])
check("--log_config" in cmd and cmd[cmd.index("--log_config") + 1] == "/app/logging.json"
      and {v["target"]: v for v in svc["as-litellm"]["volumes"]}.get("/app/logging.json", {}).get("read_only") is True,
      "as-litellm: started with --log_config /app/logging.json (read-only)")

if failures:
    sys.exit(f"compose validate: {len(failures)} check(s) failed")
print("compose validate: all checks passed")
EOF
