# agents-sandbox

Docker Compose homelab for AI coding agents with a shared LiteLLM API, an HTTPS-inspecting Squid proxy and network namespace firewall sidecars.

> **Status: experimental homelab, not a security boundary.** What the controls do and do not cover: [Security model](#security-model).

## Components

| Component | Purpose |
| --- | --- |
| `as-claude-main`, `as-claude-net` | Claude Code agent and its network-namespace firewall |
| `as-claude-bridge`, `as-claude-bridge-net` | OpenAI-compatible bridge (Claude Agent SDK, subscription login) for LiteLLM's `claude-sub` model, independent of the agent: own image with the code read-only, env, directories and firewall (`:9090` from LiteLLM only) ([details](docs/CLAUDE_BRIDGE.md)) |
| `as-hermes`, `as-hermes-net` | Hermes Agent and its network-namespace firewall |
| `as-netshoot`, `as-netshoot-net` | Network diagnostics: reaches everything in `as-net-blind` on any port and by ping, the sidecar-protected containers included (they admit it with `ALLOW_IN any::netshoot.as.internal`); nothing can connect to it |
| `as-squid` | Central HTTPS proxy and TLS inspection; the only way out of `as-net-blind` |
| `as-ingress` | Reverse proxy (Caddy) for the GUIs, with a dashboard of links to them (`:80`); the only way into `as-net-blind` |
| `as-dns` | Internal DNS (CoreDNS): only `*.as.internal`, no recursion, every query logged |
| `as-litellm` | Shared API routing to LLM models |
| `as-litellm-keys` | One-shot job: registers the pre-generated client keys in LiteLLM |
| `as-llm-gw` | The agents' way to LiteLLM (Caddy, `llm.as.internal:4000`): only the client-key routes, without the response headers that describe the upstream |
| `as-litellm-db` | PostgreSQL on a Docker `internal` network |
| `as-open-webui` | Web UI for models |

## Repository layout

```text
docker-compose.yaml            Compose topology and network definitions
compose.hermes-privileged.yaml Opt-in full-trust (privileged) mode for Hermes
.env.example                   All addressing and optional overrides (copy to .env)
proxy.env                      Agent proxy variables (by name)
start-main.sh                  Generate missing secrets, check env files, start, attach to the agent
gen-secrets.sh                 Create env files from the examples, fill generated CHANGE_ME_* values
check-env.sh                   Placeholders, values that must match, no IPs outside .env
dns/                           CoreDNS config (Corefile) and your additions (local.d/*.conf, git-ignored)
ingress/                       as-ingress config (Caddyfile) and its dashboard template
claude-main/                   Claude agent image, policy and environment example
claude-bridge/                 Claude bridge: server.mjs, its image and environment example (home/, workspace/: runtime)
hermes/                        Hermes configuration (config.yaml.example), managed settings (managed.env.example), persona (SOUL.md.example), environment example
fw/                            Network namespace firewall rules (fw.sh)
litellm/                       LiteLLM model/database configuration
llm-gw/                        as-llm-gw config (Caddyfile): the agents' routes to LiteLLM
open-webui/                    Web UI environment example
squid/                         Proxy image, entrypoint, error pages
squid/conf/                    squid.conf, the allow/deny lists and LAN hosts: tracked as *.example, your copies beside them
ssl/                           CA creation script (no CA private key committed)
tests/                         Compose, DNS, Squid ACL, firewall and secret checks
docs/                          Bridge and network (edge router) guides, topology
AGENTS.md                      Contribution and agent-work instructions
```

## Architecture notes

![agents-sandbox topology: as-net-blind behind as-ingress and as-squid, firewall sidecars, LiteLLM's own leg to Squid](docs/topology.svg)

In short:

```text
 LAN ──► as-ingress :80 :8080 :4000 :9119 ───────┐          ┌── as-squid ──► internet (allowlist)
         (VLAN leg, INGRESS_IP)                  │          │   (VLAN leg, PROXY_IP)
                                                 ▼          │
   as-net-blind (internal, no route out):  open-webui  litellm  llm-gw  hermes  claude  claude-bridge  netshoot  as-dns
                                                    │       (hermes ──► llm-gw ──► litellm)
                                   as-net-litellm-egress (internal): LiteLLM <-> Squid only
```

- **`as-net-blind` is a Docker `internal` network: nothing on it has a route out.** Agents, LiteLLM, Open WebUI and `as-dns` live there. The way out is Squid, the way in `as-ingress`; both have a second leg on the VLAN (`macvlan`, parent `VLAN_PARENT`) and do not route between their legs (`ip_forward=0`, CI-tested with an agent that sets its own route). Changing an address or a route inside `as-net-blind` leads nowhere, even with `NET_ADMIN` (privileged Hermes).
- Agent processes share the network namespace of their `as-*-net` sidecars. The sidecar applies default-drop IPv4/IPv6 rules (`fw/fw.sh`) between the containers of `as-net-blind`. Only the sidecar has `NET_ADMIN`.
- The egress for agents is Squid at `proxy.as.internal:3128` (fixed port). Squid bumps all TLS and decides on the decrypted request (host, URL, method). Denied requests get `403 Blocked by agents-sandbox proxy policy`.
- **Hermes reaches LiteLLM only through `as-llm-gw`** (`llm.as.internal:4000`, `llm-gw/Caddyfile`); its firewall drops `litellm.as.internal`.
  - The gateway forwards only the routes of the client keys (the default `LITELLM_CLIENT_ROUTES`; CI keeps both lists equal). Everything else is a 404 that never reaches LiteLLM: `/openapi.json`, `/redoc`, `/health/*`, `/metrics`, `/.well-known/*`, key and admin routes.
  - It drops the response headers that describe the upstream: `llm_provider-*`, under which LiteLLM forwards every header of the provider (no LiteLLM setting turns that off), and `x-litellm-model-*` (`api_base`, the deployment's real model name and id).
  - Error bodies pass unchanged. Admins (`as-ingress :4000`) and Open WebUI use LiteLLM directly.
- **LiteLLM reaches Squid over its own network** (`as-net-litellm-egress`, `llm-proxy.as.internal`). Squid serves the LLM provider APIs (`llm_api_domains.txt`) and LAN hosts (`lan.hosts`) only on that leg, so the identity is network membership, not an address an agent could forge.
- **Dashboard** at `http://<INGRESS_IP>/` (`:80`, only from `INGRESS_DASHBOARD_ALLOW_FROM`): links to every published GUI, with a dot showing whether your browser reaches its port. Caddy builds the list on each request from the `# @dashboard <name> | <description> | <path>` lines in `ingress/Caddyfile`, so a new site with such a line shows up after `docker compose restart as-ingress`. Every path serves the dashboard; the Caddyfile itself is not served.
- **GUIs through `as-ingress`** on `INGRESS_IP`, one port per GUI: Open WebUI `:8080`, LiteLLM `:4000` (API and `/ui`), Hermes dashboard `:9119` (only from `HERMES_DASHBOARD_ALLOW_FROM`). Caddy listens on its VLAN leg only.
- **Names, not addresses.** Every service is reached by a `*.as.internal` name (`proxy`, `litellm`, `llm`, `claude-bridge`, `hermes`, `open-webui`, `netshoot`, `dns`, `ingress`, `dev-ws01`). They are Docker network aliases in `docker-compose.yaml`, and Docker assigns the addresses (`BLIND_IP_RANGE`). Fixed addresses are only the VLAN legs (`PROXY_IP`, `INGRESS_IP`) and `DNS_IP`, all in `.env`; LAN hosts are in `squid/conf/lan.hosts`. `check-env.sh` rejects literal IPs anywhere else.
- **`as-dns`** (CoreDNS) asks Docker's embedded DNS for `*.as.internal` and keeps one log of every DNS query in `as-net-blind` (`docker compose logs as-dns`).
  - Any other name gets NXDOMAIN on the spot. Nothing is forwarded out: `as-dns` sits only on the internal network, where Docker forwards no query to an outside resolver (CI-tested), so DNS cannot carry data out (subdomain tunneling).
  - Internet names are resolved by Squid itself, over its VLAN leg (`SQUID_DNS_UPSTREAM`), and only for requests that passed its ACLs.
  - Agents: `fw.sh` writes the sidecar's `/etc/resolv.conf` (`nameserver DNS_IP`, `search as.internal`), which the agent container shares. It allows DNS only to `as-dns` and blocks Docker's embedded DNS (`127.0.0.11`), so every lookup is logged.
  - LiteLLM, Open WebUI, `as-ingress` and `as-llm-gw` (no sidecar) use `dns: DNS_IP`: Docker's embedded DNS answers the aliases of their networks itself and sends the rest to `as-dns`.
  - Firewall rules take names (`ALLOW_OUT=tcp:llm.as.internal:4000`). `fw.sh` re-resolves them every 30 s (`FW_REFRESH`) and rebuilds the rules when a peer starts, stops or comes back on another address; a name that does not resolve gets no rule.
- Restrict the VLAN legs on the edge router/firewall: [docs/NETWORK.md](docs/NETWORK.md) has the flow matrix, anti-spoofing, example configurations and verification steps.
- The default `192.19.255.0/24` subnet is not RFC1918 space (see "Changing addressing").
- Hermes runs **without** `privileged`. Full-trust mode is opt-in:
  `docker compose -f docker-compose.yaml -f compose.hermes-privileged.yaml up -d`.
- Env files use `KEY=value` and Compose interpolation (`${BLIND_SUBNET}`). Use them through Docker Compose, not `docker run --env-file`.

## Setup

1. Read the [security model](#security-model) and its known limitations.
2. Create the env files and generate the secrets, then set the few values only you know:
   ```bash
   ./gen-secrets.sh   # copies the examples, fills every generated CHANGE_ME_* (same name = same value)
   ```
   It lists what is left: the provider keys in `litellm/litellm.env`, e.g.
   `OPENROUTER_API_KEY` (without an OpenRouter account, drop `models/openrouter.yaml`
   from `include:` and the key's line). Then run `./check-env.sh`.
   `CLAUDE_OAI_KEY`, the key between LiteLLM and the Claude bridge, is generated into
   `litellm/litellm.env` and `claude-bridge/claude-bridge.env` (the bridge's environment).
   The Hermes dashboard password goes to `hermes/dashboard-password` and only its hash
   into `hermes/hermes.env`; hashing needs `python3` on the host.
   The LiteLLM keys for Hermes and Open WebUI are generated here too, before LiteLLM
   exists; on start the one-shot `as-litellm-keys` registers exactly those values as
   LiteLLM virtual keys, and Hermes and Open WebUI wait for it. So the stack comes up
   in one `docker compose up`, without creating keys in the UI first.

   `check-env.sh` fails on leftover placeholders (any `CHANGE_ME` spelling and
   `<...>`), a key from `.env.example` missing in `.env`, a `DATABASE_URL`
   that does not match `litellm-db.env`, the LiteLLM master key reused as a client
   key, client keys LiteLLM would reject (`sk-` prefix, 16+ characters) or shared between
   clients, and literal IP addresses outside `.env`/`squid/conf/lan.hosts`. `start-main.sh`
   runs it; run it yourself before a plain `docker compose up`.
3. Adapt addressing and the macvlan parent in `.env`; add LAN hosts LiteLLM talks to
   (e.g. a local LLM server) to `squid/conf/lan.hosts` as `<name>.lan.internal`.
4. The Claude containers run as `node` (UID 1000) and must own their directories
   (`claude-main/data/`, `claude-bridge/`), or the Claude login cannot be saved.
   `start-main.sh` creates them; `check-env.sh` warns about a missing directory or a
   file not owned by UID 1000 and prints the `sudo chown -R 1000:1000 …` to run.
   Hermes runs as `PUID`/`PGID` from `hermes/hermes.env` (default 1000) and must own
   `hermes/data` and `hermes/workspace` the same way, or it cannot write `/workspace`;
   `start-main.sh` creates them and `check-env.sh` checks them against `PUID`. It must
   also read `hermes/managed.env`, or Hermes does not start; `check-env.sh` warns.
5. Create the proxy CA: `ssl/init_ca.sh` (needs `sudo` to hand the key to UID 13).
6. Validate: `tests/compose/validate.sh`, then `docker compose config -q` with your real files.
7. Start: `./start-main.sh`, or `./check-env.sh && docker compose up -d`.
8. If you use the Claude bridge, set it up in its own directories and give it its own login ([CLAUDE_BRIDGE.md](docs/CLAUDE_BRIDGE.md), "Setting up the bridge").

### Changing addressing

Edit `.env` only (`VLAN_*`, `PROXY_IP`, `INGRESS_IP`, `BLIND_*`, `DNS_IP`, `LLM_EGRESS_SUBNET`, `DB_SUBNET`, `SQUID_LOCALNET_EXTRA`), then `docker compose up -d`. Names, Squid's `localnet`, firewall rules and all clients follow, because everything else uses names. Hosts outside the stack live in `squid/conf/lan.hosts` (after an edit: `squid/reload_squid.sh`).

### Models (LiteLLM)

- **One file per API endpoint** in `litellm/models/`, pulled in by `include:` in
  `litellm/litellm-config.yaml`:
  - `claude-local.yaml`: `claude-sub`, the local Claude bridge;
  - `openrouter.yaml`: OpenRouter examples `openrouter-gpt-oss-20b` and `openrouter-nvidia-nemotron-3.5-lightning:free`.
- **Adding an endpoint and its models:**
  1. a new file plus one `include:` line;
  2. its key in `litellm/litellm.env` (placeholder in the example);
  3. for internet APIs, its host in `squid/conf/llm_api_domains.txt`; for a LAN
     server, a `<name>.lan.internal` line in `squid/conf/lan.hosts`.

  Steps and a template: [litellm/models/README.md](litellm/models/README.md).
- **Provider APIs and LAN hosts are reachable through Squid from LiteLLM's network only**
  (`as-net-litellm-egress`). An agent with someone else's API key cannot send data to
  that provider's account.

### LiteLLM keys

- Each client has its own virtual key, alias `hermes` and `open-webui`. They are
  not restricted to models or budgets.
- **The keys reach the LLM API only.** Their Allowed Routes are chat and text
  completions and the model list (`/v1/models`); no embeddings, which no model in
  `litellm/models` serves.
  - `/model/info`, `/model_group/info`, which show the upstream (`api_base`,
    settings), and all key and admin routes are refused (401/403).
  - `as-litellm-keys` sets the routes on new keys and on registered keys that have
    none (full access, e.g. after an edit in the UI) or still have an earlier default
    list (with embeddings); a rotated key keeps them. A list you set in the UI stays.
  - Other routes: `LITELLM_CLIENT_ROUTES` (space-separated) in the environment of
    `as-litellm-keys`. Hermes gets only what the `@client_routes` line of
    `llm-gw/Caddyfile` lists; `validate.sh` checks that line against the default list
    in `litellm/litellm-keys.py`, so change both together.
  - The UI may still show the key type "Default". The list under Allowed Routes
    is what applies. LiteLLM's "AI APIs" type would also allow `/model/info`.
- **To restrict a client,** open the LiteLLM UI from the LAN at `http://<INGRESS_IP>:4000/ui`
  and log in with `LITELLM_MASTER_KEY`.
  Under Virtual Keys, edit the key with that alias (Models, budgets, rate limits).
  `as-litellm-keys` never overwrites those settings.
- **Rotating a key:**
  1. Set its line back to the placeholder (e.g. `LITELLM_API_KEY=CHANGE_ME_LITELLM_KEY_HERMES`).
  2. Run `./gen-secrets.sh`, then `docker compose up -d`.

  `as-litellm-keys` creates the new key with the old key's settings, deletes the old
  one and moves the alias. You can also paste your own `sk-…` value (16+ characters)
  instead of the placeholder.
- A new client means a new `alias=ENV_VAR` entry in `LITELLM_CLIENT_KEYS` of
  `as-litellm-keys` and its env file in that service's `env_file`.

### Day-to-day

- **Local configuration is yours.** Git tracks only `squid/conf/*.example`, `hermes/config.yaml.example`, `hermes/managed.env.example` and `hermes/SOUL.md.example`; `./gen-secrets.sh` creates `squid/conf/squid.conf`, the lists, `lan.hosts`, `hermes/config.yaml`, `hermes/managed.env` and `hermes/SOUL.md` from them, and `git pull` never touches your copies. as-dns additions go into `dns/local.d/*.conf`, which the tracked `dns/Corefile` imports ([dns/local.d/README.md](dns/local.d/README.md); no `forward` out of `as-net-blind`).
  - Edit your copies, then run `squid/reload_squid.sh` (validates and reloads without restarting the container).
  - When a pull changes an `.example`, `check-env.sh` and `gen-secrets.sh` warn and print the `diff -u` to review. Take over what you want, then `touch` your copy to mark it reviewed.
  - `squid.conf` carries the policy (SSL bump, GitHub and npm write rules): review its changes in particular.
- Squid logs: `squid/logs/`, rotated daily, 7 files kept. They contain full decrypted URLs.
- Bridge logs: `docker compose logs as-claude-bridge`.
- **Hermes model:** change it in `hermes/config.yaml` (`model.default`, a `model_name` from `litellm/models/*.yaml`), then `docker compose up -d --force-recreate as-hermes`.
  - The dashboard cannot save model changes ("Failed to save model assignment"): Compose mounts `config.yaml` as a single read-only file. Hermes saves by writing a temporary file and renaming it over the original, which a single-file mount does not allow even read-write.
  - The read-only mount is deliberate: the agent (YOLO mode) cannot rewrite its own provider settings.
- **Hermes settings the agent cannot change by editing its `.env`:** Hermes loads `/opt/data/.env` (`hermes/data/.env`, writable by the agent) over the container environment, so `hermes/hermes.env` cannot pin a value. Two files win over it:
  - `hermes/config.yaml` (read-only) for what the gateway takes from it, e.g. `security.redact_secrets: true`;
  - `hermes/managed.env`, mounted read-only as Hermes' managed scope (`/etc/hermes/.env`) and loaded last on every reload of its env: `HERMES_WRITE_SAFE_ROOT=/opt/data:/workspace` (`write_file`/`patch` only in the read-write mounts; the image default is `/opt/data` alone), `HERMES_ALLOW_PRIVATE_URLS=false`, `HERMES_ENABLE_PROJECT_PLUGINS=false`, an empty `HERMES_EPHEMERAL_SYSTEM_PROMPT` and `HERMES_PREFILL_MESSAGES_FILE` (no prompt text from `.env`), `HERMES_HOME=/opt/data` (where the read-only `config.yaml` and `SOUL.md` are; Hermes profiles do not work with it) and `HERMES_IGNORE_RULES=false` (`SOUL.md`, memory and skills stay in the prompt). No secrets in it: Hermes, and therefore the agent, reads it.
  - After an edit: `docker compose up -d --force-recreate as-hermes`. `docker exec as-hermes hermes doctor` then reports `Managed scope active: … env key(s) pinned by /etc/hermes`; a line `managed dir set via HERMES_MANAGED_DIR` means the scope was redirected (see [Security model](#security-model)).
- **Hermes dashboard login:** user `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` from `hermes/hermes.env`, password in `hermes/dashboard-password` (host only; no container mounts it). The container gets only the password's scrypt hash and no static session secret, so you log in again after each restart of `as-hermes`.
  - New password: set `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=CHANGE_ME_HERMES_DASHBOARD_PASSWORD_HASH` in `hermes/hermes.env`, run `./gen-secrets.sh`, then `docker compose up -d --force-recreate as-hermes`.
  - The hash stays in single quotes: Compose expands the `$` in it otherwise. `check-env.sh` checks the quoting and the format.
  - An older `hermes.env` with `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` and `HERMES_DASHBOARD_BASIC_AUTH_SECRET`: replace both lines with the placeholder line above and run `./gen-secrets.sh`. `check-env.sh` warns until then, and fails while the plaintext password and the hash are both set (the plaintext wins).
- **Hermes persona:** `hermes/SOUL.md`, mounted read-only at `/opt/data/SOUL.md`, so neither the agent nor the dashboard can rewrite it. Edit it on the host, then `docker compose up -d --force-recreate as-hermes`: an editor that replaces the file leaves the container on the old copy.
  - Keep text of your own in it beyond the image's default persona (the example's "This environment" section). Hermes rewrites an unedited default or an old template in place; on a read-only file that stops it from starting.
  - The persona used before stays in `hermes/data/SOUL.md`, hidden by the mount; `gen-secrets.sh` points at it when it creates `hermes/SOUL.md`.
- DNS queries (agents, LiteLLM, Open WebUI): `docker compose logs as-dns` (10 × 10 MB kept). A query for an external name from an agent is worth a look.
- Pin versions with `CLAUDE_CODE_VERSION` and the `*_IMAGE` variables in `.env`.

### Firewall drop logs (`FW_LOG`)

The sidecars with `FW_LOG: 1` log dropped packets with the iptables `LOG` target
(prefixes `fw-drop-in:` and `fw-drop-out:`, at most 10 per minute each). The kernel
**ignores `LOG` inside a container's network namespace** unless it is allowed on the host:

```bash
sudo sysctl -w net.netfilter.nf_log_all_netns=1
echo 'net.netfilter.nf_log_all_netns = 1' | sudo tee /etc/sysctl.d/90-agents-sandbox.conf
```

The second line keeps it after a reboot.

**Where to set it:** on the machine whose kernel runs the containers. The setting
exists only in the kernel's initial network namespace, so a container cannot set it.

| Docker runs on | Set it on | Logs appear in |
| --- | --- | --- |
| bare metal | the Docker host | the Docker host: `journalctl -k` / `dmesg` |
| a Proxmox **VM** (KVM) | the Docker host, i.e. inside the VM (it has its own kernel); nothing on Proxmox | the VM |
| a Proxmox **LXC** container | the **Proxmox host** (LXC shares its kernel and is itself a non-initial namespace) | the Proxmox host, not the LXC |

Read them with `journalctl -k | grep fw-drop` (or `dmesg | grep fw-drop`) there.

- **Trade-off:** the setting lets every network namespace on that kernel write
  to the kernel log, including containers that are not part of this stack. A
  container with `NET_ADMIN` (e.g. privileged Hermes) could add its own `LOG`
  rules and flood the log. The sidecars rate-limit their own rules.
- **Without it,** the firewall drops the same packets; only the log lines are missing.

## Security model

Principles:

1. **Container policy is not prompt policy.** Deny rules for agent tools
   (`managed-settings.json`) do not replace Linux filesystem permissions.
2. **Proxy settings are not enforcement.** A process can ignore `HTTP(S)_PROXY`;
   the sidecars and `as-net-blind` block every other way out.
3. **Privilege escalation defeats in-namespace controls.** A privileged agent
   (`compose.hermes-privileged.yaml`) can change the firewall of its namespace;
   it still has no route out of `as-net-blind`.
4. **macvlan exposes services to the physical network.** Only Squid and
   `as-ingress` are on it; restrict them on the router ([NETWORK.md](docs/NETWORK.md)).
5. **Secrets stay outside Git.** No private CA keys, API keys, session files,
   workspaces or local `.env` files.

Known limitations:

- **Agents can read their own secrets.** The deny rules for `.env` and similar are
  Claude Code tool permissions; with `--dangerously-skip-permissions`, `cat` through
  Bash still works. Only separate UIDs or mounts would stop that. The bridge keeps
  `CLAUDE_OAI_KEY` out of its Claude Code process.
- **Allowed hosts are channels.** `api.anthropic.com` and `claude.ai` allow every
  path and method, so a prompt-injected agent with someone else's API key can
  upload data to that account. The GitHub rules restrict URLs and methods but are
  not a complete exfiltration boundary. GET query strings to allowed hosts are a
  smaller channel.
- **Allowed hosts can tell an agent the stack's public IP.** Cloudflare's `/cdn-cgi/`
  on every host behind it (`/cdn-cgi/trace` answers `ip=` with the proxy's address)
  is denied in `squid/conf/denied_urls.txt`, in every spelling Cloudflare decodes
  (`%XX`, `\`, `//`, dot segments; `tests/squid/run-acl-tests.sh`). Squid does not see
  response bodies, so a Cloudflare error page that shows the visitor's IP, or any
  allowed service that echoes it, still can.
- **Squid logs decrypted URLs.** Anyone with access to `squid/logs/` on the host
  can read them; 7 daily files are kept.
- **Default addressing is public space.** `192.19.255.0/24` is not RFC1918; move
  it (see "Changing addressing").
- **Image tags and `CLAUDE_CODE_VERSION` float** unless you pin them in `.env`.
- **GUIs are plain HTTP.** `as-ingress` serves them without TLS; the Hermes
  dashboard sends basic auth in the clear, and the first Open WebUI signup becomes
  admin. Keep `HERMES_DASHBOARD_ALLOW_FROM` and the router rules narrow.
- **Hermes can change its own settings.** `/opt/data/.env` overrides the container
  environment, and the agent can write it. `hermes/managed.env` and the read-only
  `config.yaml` pin a few keys, but that is configuration, checked inside the gateway
  process the agent runs in:
  - The gateway's `reload.env` RPC loads `/opt/data/.env` into the running gateway
    without the managed layer, so a value the agent wrote there (e.g. a wider
    `HERMES_WRITE_SAFE_ROOT`) applies at once. The pins return when the gateway
    reloads its env, with the managed layer, for the next turn. Any process with Hermes' UID can call it: the gateway's control
    socket and loopback WebSocket check only the peer UID. The agent has used this.
  - A `HERMES_MANAGED_DIR` line in `/opt/data/.env` points Hermes at a managed
    directory the agent controls.
  - `HERMES_WRITE_SAFE_ROOT` limits the file tools, not the terminal.
  - `HERMES_HOME` and `HERMES_IGNORE_RULES` are pinned, so `/opt/data/.env` cannot
    point Hermes at another home (with its own `SOUL.md` and `config.yaml`) or drop
    `SOUL.md` from the prompt, except through `reload.env` for the rest of a turn.
    Its memory and skills in `hermes/data` stay writable.

  The boundary is Hermes' UID and its mounts. On the host it writes only `hermes/data`
  and `hermes/workspace`; in the container, scratch space such as `/tmp` (the image's
  code is not writable for it). Whatever Hermes must not write belongs to root or is
  mounted `:ro`, never to its UID.
- **The agent can use its own dashboard.** The dashboard runs with Hermes' UID, so the
  agent reads what it holds: its environment (`/proc/PID/environ`) and, where the host's
  `kernel.yama.ptrace_scope` is 0, its memory. Hence the password hash and the per-start
  session key instead of a plaintext password and a fixed secret in `hermes.env`. The
  agent reaches the dashboard on `localhost:9119` anyway and can replace its login with
  a line in `/opt/data/.env`: it is the agent's own control plane, with no more rights
  than the agent.
- **`as-netshoot` reaches everything** in `as-net-blind`, and the sidecars admit it.
  Whoever can `docker exec` already controls every container; the bridge still
  requires `CLAUDE_OAI_KEY`. Nothing can connect to netshoot.
- **`as-dns` has no healthcheck** (distroless image). It fails closed: without it,
  sidecars do not report ready and names do not resolve.
- **Not covered by CI:** Open WebUI, a Claude Code login, Hermes talking to a model,
  a real VLAN, IPv6 on containers.

## Tests

CI (`.github/workflows/checks.yml`) runs these on every push. To run them locally:

```bash
tests/check-no-secrets.sh          # no env files, keys, runtime state or tokens in Git
./check-env.sh --examples          # examples use only CHANGE_ME_* placeholders
tests/compose/validate.sh          # Compose renders; security invariants hold
sudo tests/compose/run-blind-tests.sh  # as-net-blind on real containers: proxy paths, ingress, no escape (needs docker)
tests/dns/run-dns-tests.sh         # as-dns: aliases, no recursion, no leak, logging (needs docker)
tests/litellm/run-keys-tests.sh    # as-litellm-keys against real LiteLLM + PostgreSQL (needs docker)
sudo tests/squid/run-acl-tests.sh  # permitted/blocked requests through squid/conf/*.example (needs squid-openssl);
                                   # pass squid/conf to test your own copies
sudo tests/fw/run-fw-tests.sh      # permitted/blocked traffic through fw.sh in network namespaces
```

AGENTS.md requires both permitted and blocked cases for every firewall or Squid ACL change. Add them to these scripts.
