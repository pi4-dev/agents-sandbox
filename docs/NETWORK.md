# Network: the blind network and the edge router

How the stack is wired and how to protect its VLAN on the router/firewall that
terminates it: who on the LAN may reach the ingress and the proxy, and what the
stack may reach.

The examples use the addresses from `.env.example`; replace them with yours.
Values in angle brackets (`<LLM_LAN_IP>`, `<LLM_LAN_PORT>`) have no default and must be filled in.
They assume the router is also Squid's DNS server:
`SQUID_DNS_UPSTREAM` is the VLAN gateway, `192.19.255.1`, the default in `.env.example`.

## 1. Topology

Drawing: [topology.svg](topology.svg) (amber frames are the `fw.sh` sidecars).

```
                       internet
                          │
                   ┌──────┴──────┐  WAN
                   │ edge router │  DNS resolver for Squid
                   └──┬───────┬──┘
          users / admin│       │ vlan100 (192.19.255.0/24), gateway .1
                       │       │
                       │   ┌───┴──────────── Docker host ────────────────────────────────────────┐
                       │   │  as-net-vlan (macvlan):  .101 as-squid          .99 as-ingress      │
                       │   │                               │ no routing          │ no routing    │
                       │   │  as-net-blind (internal):  proxy.as.internal   ingress.as.internal  │
                       │   │     as-dns (DNS_IP)  as-litellm  as-llm-gw  as-open-webui  as-zenoh │
                       │   │     as-claude-net (+ claude-main)  as-claude-bridge-net (+ bridge)  │
                       │   │     as-hermes-net (+ hermes)  as-netshoot-net                       │
                       │   │  as-net-litellm-egress (internal): as-litellm <-> as-squid          │
                       │   │  as-net-litellm-db (internal): as-litellm, as-litellm-db            │
                       │   └─────────────────────────────────────────────────────────────────────┘
```

- **`as-net-blind` is a Docker `internal` network.** Its containers have no default
  route and no gateway. Docker's own rules on the host drop anything from that
  bridge to an address outside its subnet.
- **Two containers have a leg on the VLAN:**
  - `as-squid`, the way out;
  - `as-ingress` (Caddy), the way in to the GUIs.

  Both run with `ip_forward=0`. An agent that sets its own default route through
  them, with `NET_ADMIN`, gets nothing out (`tests/compose/run-blind-tests.sh`).
- **`as-dns` is only on `as-net-blind`.** Docker's embedded DNS forwards nothing to
  outside resolvers from there. Squid resolves internet names itself, through
  its VLAN leg.
- **LiteLLM talks to Squid over `as-net-litellm-egress`.** Only LiteLLM and Squid are on
  that network. It is how Squid tells LiteLLM apart for the provider APIs and
  LAN LLM servers.
- **Addresses inside are Docker's** (`BLIND_IP_RANGE`). Names are network
  aliases (`*.as.internal`). Fixed addresses: the two VLAN legs (`PROXY_IP`,
  `INGRESS_IP`) and `DNS_IP`.

## 2. What the edge router can and cannot see

- **The router sees** only the two VLAN legs: Squid's egress, the GUI traffic
  to `as-ingress`, and LAN clients of the proxy (`SQUID_LOCALNET_EXTRA`).
- **The router does not see** anything inside `as-net-blind` (agent → Squid, agent →
  `as-dns`, Hermes → `as-llm-gw` → LiteLLM, agents ↔ `as-zenoh`, LiteLLM → bridge). That traffic never leaves the Docker host. The
  `fw.sh` sidecars (agents) enforce it.

So the router has three jobs:

1. let Squid out only to the internet (and, if needed, one LAN LLM server);
2. let in only the intended networks to the ingress ports;
3. make sure nobody but the Docker host lives in the VLAN, and nobody forges VLAN
   addresses.

A container escaping `as-net-blind` would have to be put on the VLAN by whoever runs
Docker. The router's "anything else from the VLAN: drop and log" rule is the
alarm for that.

## 3. Prerequisites

- **Dedicated VLAN.** Only the Docker host sits in `vlan100`: no Wi-Fi clients,
  printers or other servers.
- **Switch port of the Docker host:** tagged `vlan100`, plus a separate
  management VLAN for the host itself if needed. Manage the host through its
  management VLAN, not through `vlan100`.
- **No IPv6 in the VLAN:** the router sends no router advertisements there and
  forwards no IPv6.
- **RFC1918 addressing.** `192.19.255.0/24` belongs to someone else on the
  internet: those hosts become unreachable, and a NAT or routing mistake can leak
  traffic. Move to e.g. `10.19.255.0/24` before deploying these rules; only `.env`
  changes.
- **Routing in the router CPU.** If inter-VLAN routing is hardware-offloaded
  (switch chip), the firewall does not see it.

## 4. Flow matrix

Default policy in both directions: **drop and log**.

### Out of the VLAN

| Source | Destination | Why |
|---|---|---|
| Squid `.101` | internet TCP 80/443, **not** private ranges | the stack's only egress; blocking RFC1918 stops an allowed domain that resolves to a LAN address from reaching your LAN |
| Squid `.101` | optional: an LLM server in the LAN (`squid/conf/lan.hosts`), its address and port | LiteLLM reaches it through Squid (its own leg, any port) |
| Squid `.101` | **the router itself**, UDP/TCP 53 (input chain) | `SQUID_DNS_UPSTREAM` |
| ingress `.99` | nothing (replies only) | |
| anything else in the VLAN | nothing, drop and log as an alarm | nothing else should exist there |
| whole VLAN | nothing to the router's management (Winbox, SSH, web, API) or to other VLANs | |

### Into the VLAN

| Source | Destination | Notes |
|---|---|---|
| users network | ingress `.99:8080` (Open WebUI) | plain HTTP |
| admin network | ingress `.99:80` (dashboard: links to the GUIs) | Caddy also checks `INGRESS_DASHBOARD_ALLOW_FROM` |
| admin network | ingress `.99:4000` (LiteLLM API and `/ui`) | the UI login is the master key |
| admin network | ingress `.99:9119` (Hermes dashboard) | Caddy also checks `HERMES_DASHBOARD_ALLOW_FROM` |
| `SQUID_LOCALNET_EXTRA` (e.g. `192.168.100.0/24`) | Squid `.101:3128` | only if that network really uses the proxy; otherwise remove it from `.env` |
| nobody | anything else | the services in `as-net-blind` are not on the VLAN at all |

### The router itself

| Source | Destination | Notes |
|---|---|---|
| Squid `.101` | router DNS, UDP/TCP 53 | the only DNS client the router serves in this VLAN |
| VLAN | ICMP to the gateway | optional, for diagnostics |
| VLAN | everything else on the router | drop and log |

NAT to the internet is needed only for Squid.

## 5. Anti-spoofing

- **On the router:** ingress filtering. From `vlan100` accept only sources in
  `VLAN_SUBNET`; from every other interface drop sources claiming `VLAN_SUBNET`.
- **Inside the Docker host:** containers in `as-net-blind` cannot put a packet on
  the VLAN, so they cannot forge VLAN addresses either. Inside `as-net-blind`, the
  sidecars drop packets with a source other than their own. Squid identifies
  LiteLLM by the network a request arrives on (`as-net-litellm-egress`), not by an address.

## 6. MikroTik (RouterOS v7), router as the DNS server

Assumptions:
- `vlan100` is the VLAN interface with `192.19.255.1/24`;
- WAN is in the interface list `WAN`, as in the default configuration;
- `vlan100` is **not** in the list `LAN`. Otherwise the default rules let the VLAN
  into the router, Winbox and SSH included.

```routeros
# ===== 0. VLAN (if it does not exist yet) =====
/interface vlan add name=vlan100 vlan-id=100 interface=bridge
/ip address add address=192.19.255.1/24 interface=vlan100
/interface list add name=AS
/interface list member add list=AS interface=vlan100

# ===== 1. DNS: the router resolves for Squid (= SQUID_DNS_UPSTREAM) =====
/ip dns set allow-remote-requests=yes servers=9.9.9.9,1.1.1.1 cache-size=4096KiB
# optional, DNS over HTTPS towards the router's upstream (import the CA bundle first):
# /ip dns set use-doh-server=https://dns.quad9.net/dns-query verify-doh-cert=yes

# ===== 2. Address lists (counterparts of .env) =====
/ip firewall address-list
add list=as-vlan    address=192.19.255.0/24
add list=as-squid   address=192.19.255.101 comment=PROXY_IP
add list=as-ingress address=192.19.255.99  comment=INGRESS_IP
add list=as-llm-lan address=<LLM_LAN_IP>   comment="optional: LLM server in the LAN"
add list=as-admin   address=10.0.0.0/24    comment="admin net / HERMES_ and INGRESS_DASHBOARD_ALLOW_FROM"
add list=as-users   address=192.168.1.0/24 comment="users of Open WebUI"
add list=private    address=10.0.0.0/8
add list=private    address=172.16.0.0/12
add list=private    address=192.168.0.0/16
add list=private    address=100.64.0.0/10
add list=private    address=169.254.0.0/16

# ===== 3. Anti-spoofing (raw: before connection tracking, cheap) =====
/ip firewall raw
add chain=prerouting in-interface=vlan100 src-address-list=!as-vlan action=drop \
    comment="AS: foreign source address from the VLAN"
add chain=prerouting in-interface=!vlan100 src-address-list=as-vlan action=drop \
    comment="AS: someone claims a VLAN address"

# ===== 4. Forward: new connections from/to the VLAN go to own chains =====
/ip firewall filter
add chain=forward connection-state=new in-interface=vlan100  action=jump jump-target=as-out \
    comment="AS: from the VLAN"
add chain=forward connection-state=new out-interface=vlan100 action=jump jump-target=as-in \
    comment="AS: to the VLAN"

# out of the VLAN: Squid only
add chain=as-out src-address-list=as-squid dst-address-list=as-llm-lan protocol=tcp dst-port=<LLM_LAN_PORT> action=accept
add chain=as-out src-address-list=as-squid dst-address-list=private action=drop log=yes log-prefix="AS-SQUID-LAN"
add chain=as-out src-address-list=as-squid protocol=tcp dst-port=80,443 action=accept
add chain=as-out action=drop log=yes log-prefix="AS-OUT-DENY" \
    comment="ingress never starts a connection; any other VLAN source should not exist"

# into the VLAN: the ingress ports (and the proxy for SQUID_LOCALNET_EXTRA, if used)
add chain=as-in src-address-list=as-users dst-address-list=as-ingress protocol=tcp dst-port=8080 action=accept
add chain=as-in src-address-list=as-admin dst-address-list=as-ingress protocol=tcp dst-port=80,4000,9119 action=accept
# add chain=as-in src-address=192.168.100.0/24 dst-address-list=as-squid protocol=tcp dst-port=3128 action=accept
add chain=as-in action=drop log=yes log-prefix="AS-IN-DENY"

# ===== 5. Input: the VLAN reaches only the router's DNS, and only from Squid =====
add chain=input in-interface=vlan100 connection-state=established,related action=accept
add chain=input in-interface=vlan100 src-address-list=as-squid protocol=udp dst-port=53 action=accept \
    comment="AS: Squid -> router DNS"
add chain=input in-interface=vlan100 src-address-list=as-squid protocol=tcp dst-port=53 action=accept
add chain=input in-interface=vlan100 protocol=udp dst-port=53 action=drop log=yes log-prefix="AS-DNS-BYPASS" \
    comment="any other DNS client in the VLAN should not exist"
add chain=input in-interface=vlan100 protocol=tcp dst-port=53 action=drop log=yes log-prefix="AS-DNS-BYPASS"
add chain=input in-interface=vlan100 protocol=icmp action=accept
add chain=input in-interface=vlan100 action=drop log=yes log-prefix="AS-TO-ROUTER"

# ===== 6. NAT: only Squid needs to reach the internet =====
/ip firewall nat
add chain=srcnat out-interface-list=WAN src-address-list=as-squid action=masquerade comment="AS: Squid"

# ===== 7. IPv6: nothing into or out of the VLAN =====
/ipv6 firewall filter
add chain=forward in-interface=vlan100  action=drop comment="AS: no IPv6"
add chain=forward out-interface=vlan100 action=drop
add chain=input   in-interface=vlan100  action=drop
# and no IPv6 address on vlan100, so the router sends no RA:
# /ipv6 address print where interface=vlan100   -> remove anything listed

# ===== 8. Management services invisible from the VLAN =====
/tool mac-server set allowed-interface-list=LAN
/tool mac-server mac-winbox set allowed-interface-list=LAN
/ip neighbor discovery-settings set discover-interface-list=LAN
```

### MikroTik caveats

- **Rule order.**
  - New rules go to the end of the list, and the default `forward` policy in
    RouterOS is accept. The two `jump` rules (section 4) and the `input` rules
    (section 5) must sit **before** any broad accept rule.
  - Best place: right after the default `accept established,related` and
    `drop invalid`. Check the numbers with `/ip firewall filter print` and use
    `move`, or add the rules with `place-before=<n>`.
  - Also keep the VLAN DNS rules above the default "accept DNS from LAN"-style
    rules if you have them.
  - In `as-out` the LAN LLM accept comes before the `private` drop on purpose.
    Without a LAN LLM server, delete that line.
- **Fasttrack** only speeds up established connections; every new connection
  still passes `as-in`/`as-out`.
- **L3 hardware offloading (CRS3xx/CRS5xx).** If the switch chip routes between
  VLANs, the firewall never sees that traffic. Route `vlan100` in the CPU
  (`l3-hw-offloading=no` for the port or the switch).
- **Default masquerade.** The default `out-interface-list=WAN` masquerade without
  a source would also cover the whole VLAN. That is harmless, because the filter
  decides what leaves; the rule in section 6 is for setups without it.
- **`/ip settings rp-filter=strict`** also stops spoofing, but globally, and can
  break asymmetric routing. The `raw` rules in section 3 affect this VLAN only.
- **Router DNS exposure.** `allow-remote-requests=yes` makes the router answer DNS
  on all interfaces. The default configuration drops input from WAN; the rules in
  section 5 limit this VLAN to Squid.
- **Switch side** (`/interface bridge vlan`): the Docker host port is tagged only
  in `vlan100` (`frame-types=admit-only-vlan-tagged` on that bridge port), and no
  other port carries `vlan100` untagged.
- **Logs.** Send them off the router:
  ```routeros
  /system logging action add name=remote target=remote remote=<syslog>
  /system logging add topics=firewall action=remote
  ```

## 7. Generic Linux router (nftables), router as the DNS server

The same policy for a Linux router (OPNsense/pfSense: same logic, as aliases and rules):

```nft
define VLAN    = 192.19.255.0/24
define SQUID   = 192.19.255.101
define INGRESS = 192.19.255.99
define LLMLAN  = <LLM_LAN_IP>            # optional: LLM server in the LAN
define PRIVATE = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 }
define ADMIN   = 10.0.0.0/24
define USERS   = 192.168.1.0/24

table inet as {
  chain prerouting {
    type filter hook prerouting priority raw; policy accept;
    iifname "vlan100" ip saddr != $VLAN counter drop
    iifname != "vlan100" ip saddr $VLAN counter drop
  }
  chain forward {
    type filter hook forward priority filter; policy accept;   # other traffic: your existing rules
    iifname "vlan100" meta nfproto ipv6 drop
    oifname "vlan100" meta nfproto ipv6 drop
    iifname "vlan100" ct state new jump as_out
    oifname "vlan100" ct state new jump as_in
  }
  chain as_out {
    ip saddr $SQUID ip daddr $LLMLAN tcp dport <LLM_LAN_PORT> accept
    ip saddr $SQUID ip daddr $PRIVATE log prefix "AS-SQUID-LAN " drop
    ip saddr $SQUID tcp dport { 80, 443 } accept
    log prefix "AS-OUT-DENY " drop
  }
  chain as_in {
    ip saddr $USERS ip daddr $INGRESS tcp dport 8080 accept
    ip saddr $ADMIN ip daddr $INGRESS tcp dport { 80, 4000, 9119 } accept
    log prefix "AS-IN-DENY " drop
  }
  chain input {
    type filter hook input priority filter; policy accept;
    iifname "vlan100" ct state established,related accept
    iifname "vlan100" ip saddr $SQUID meta l4proto { tcp, udp } th dport 53 accept
    iifname "vlan100" meta l4proto { tcp, udp } th dport 53 log prefix "AS-DNS-BYPASS " drop
    iifname "vlan100" icmp type echo-request accept
    iifname "vlan100" log prefix "AS-TO-ROUTER " drop
  }
  chain postrouting {
    type nat hook postrouting priority srcnat;
    oifname "wan0" ip saddr $SQUID masquerade
  }
}
```

The router's resolver (unbound, dnsmasq…) listens on `192.19.255.1` and is
reachable from `vlan100` only for Squid (input chain).

## 8. Verification

The Docker host side is covered by CI (`tests/compose/run-blind-tests.sh`).
Run these after every change on the router.

1. **Nothing else leaves the VLAN.** Put a throwaway container on the VLAN, which
   only an operator can do:
   ```bash
   docker run --rm --network agents-sandbox_as-net-vlan --ip 192.19.255.60 nicolaka/netshoot \
     sh -c 'curl -m 5 https://example.com; dig +time=2 @192.19.255.1 example.com'
   ```
   Expected: both fail, and the router logs `AS-OUT-DENY` and `AS-DNS-BYPASS`.
2. **No way out of `as-net-blind`**, even with a route set by hand:
   ```bash
   docker run --rm --cap-add NET_ADMIN --network agents-sandbox_as-net-blind nicolaka/netshoot \
     sh -c 'ip route add default via "$(getent hosts as-squid | cut -d" " -f1)"; curl -m 5 http://example.com'
   ```
   Expected: fails; the router sees nothing.
3. **Squid cannot reach the LAN:**
   ```bash
   docker exec as-squid bash -c 'exec 3<>/dev/tcp/192.168.1.1/80' || true
   ```
   Expected: `AS-SQUID-LAN` on the router. The image has no curl; any LAN address works.
4. **Squid resolves through the router:** from an agent container,
   `curl -sk https://api.anthropic.com/` is not a DNS error.
5. **Only intended ports are open from outside:**
   - `nmap -Pn 192.19.255.0/24` from the users network: only `.99:8080`;
   - from the admin network: also `.99:80`, `.99:4000` and `.99:9119`.
6. **Spoofed VLAN source from elsewhere** (e.g. `hping3 -a 192.19.255.101` from
   the users network): dropped by the raw rule, counter in
   `/ip firewall raw print stats` goes up.
7. **Counters and logs** on the router/firewall, e.g. with the MikroTik example from section 6:
   ```routeros
   /ip firewall filter print stats where comment~"AS" || log-prefix~"AS"
   /log print where message~"AS-"
   ```
