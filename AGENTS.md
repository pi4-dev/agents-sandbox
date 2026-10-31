# Repository contribution instructions

- This repo represents an experimental AI-agent homelab, **not** a production security boundary.
- Before changing firewall, proxy, capabilities or agent behavior, read the "Security model" section of `README.md` and `docs/NETWORK.md`.
- Prefer small, reviewable changes with explicit acceptance tests and rollback notes.
- Never commit `.env`, private CA keys, API tokens, browser sessions, runtime volumes or agent workspaces.
- Preserve the intended least-privilege model; privileged mode / Docker socket access requires an explicit architecture decision.
- Test both permitted and blocked traffic after every firewall/Squid ACL change.
- Treat `HTTP_PROXY`/`HTTPS_PROXY` as application configuration, not as security controls.
- Preserve current functionality unless a change explicitly documents a security-motivated behavior change.
