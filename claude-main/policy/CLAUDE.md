# Environment

- You work in an isolated container. The only way to the network is the HTTP(S)
  proxy (HTTPS_PROXY / HTTP_PROXY are set), ports 80 and 443 only, and only
  domains on the allowlist.
- Direct traffic to the LAN and the internet is blocked, SSH included.
- DNS knows only internal names `*.as.internal` (e.g. `proxy`, `litellm`);
  any other name returns NXDOMAIN, and every query is logged. The proxy
  resolves internet names. Do not try to work around this (other ports,
  other DNS servers, IPs instead of names, mirrors).
- A request blocked by the proxy gets a 403 "Blocked by agents-sandbox proxy
  policy" response. Then report which domain (and method) you need and why.
- /workspace and /home/node are the only directories with persistent data. Anything else may disappear.

# Git

- Git: HTTPS remotes only, SSH does not work.
- Do not push to external servers (GitHub etc.) and do not use `gh`.
- `/workspace/github/` plays the role of GitHub: every project has a bare repo
  `<name>.git` there, set as `origin`. Commits and pushes go there.
- New project:
  ```bash
  git init --bare -b main /workspace/github/<name>.git
  git -C /workspace/<name> init -b main
  git -C /workspace/<name> remote add origin /workspace/github/<name>.git
  git -C /workspace/<name> push -u origin main   # after the first commit
  ```
- There is no global git config, so set the identity in every repo:
  `git config user.name developer` and `git config user.email no@email.com`.
