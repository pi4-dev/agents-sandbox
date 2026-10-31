# as-dns additions

`dns/Corefile` imports every `dns/local.d/*.conf`. The files are git-ignored,
so a `git pull` never touches them, and the tracked Corefile (the DNS policy)
stays as published.

Each file holds CoreDNS server blocks, e.g. a static name for the containers in
`as-net-blind`:

```
lab.as.internal {
    hosts {
        <address>  printer.lab.as.internal
        fallthrough
    }
    log
    errors
}
```

- A more specific zone wins over `as.internal` and the `.` NXDOMAIN block.
- **Do not `forward` to a resolver outside `as-net-blind`.** That reopens DNS
  as a channel out of the blind network (subdomain tunneling). `check-env.sh`
  warns about such a `forward`.
- Containers in `as-net-blind` have no route out. A name here only helps
  traffic that stays inside, or that goes through Squid (which resolves names
  itself and has its own LAN hosts in `squid/conf/lan.hosts`).
- Apply: `docker compose restart as-dns`, then check the log with
  `docker compose logs as-dns`.
