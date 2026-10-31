# Claude bridge (`as-claude-bridge`)

LiteLLM's `claude-sub` model talks to an OpenAI-compatible bridge on
`http://claude-bridge.as.internal:9090/v1`. The bridge serves `/v1/chat/completions`
and `/v1/models` over the **Claude Agent SDK**, logged in with a Claude
subscription. Every request is a fresh, isolated SDK session.

The code is in [`claude-bridge/`](../claude-bridge):
`server.mjs`, `package.json` and `package-lock.json` (Agent SDK 0.3.301, installed
with `npm ci`).

## Independent of the agent

The agent (`as-claude-main`) runs with `--dangerously-skip-permissions`. Nothing of
it reaches the bridge, and it cannot reach or change the bridge:

| | agent (`as-claude-main`) | bridge (`as-claude-bridge`) |
|---|---|---|
| image | `agents-sandbox/claude` (`claude-main/Dockerfile`) | `agents-sandbox/claude-bridge` (`claude-bridge/Dockerfile`) |
| bridge code | none | baked into the image under `/app`, owned by root; read-only root filesystem |
| env file | `claude-main/claude.env` | `claude-bridge/claude-bridge.env` |
| `/workspace` | `./claude-main/data/workspace` | `./claude-bridge/workspace` (session cwd, optional system prompt) |
| `/home/node` (Claude login) | `./claude-main/data/claude-home` | `./claude-bridge/home` |
| policy, `CLAUDE.md` | `claude-main/policy`, `claude-main/CLAUDE.md` | none; `settingSources: []` loads no settings or `CLAUDE.md` |
| network | `as-claude-net`: proxy only, nothing inbound | `as-claude-bridge-net`: proxy, `:9090` from LiteLLM only |

CI checks this:
- `validate.sh` asserts that the bridge has its own image and mounts nothing from
  `claude-main`;
- `run-blind-tests.sh` runs the real bridge image and checks:
  - LiteLLM with the key gets 200, without it 401;
  - the agent and a container without a sidecar cannot connect;
  - `/app/server.mjs` cannot be changed.

The container is read-only with no capabilities and `no-new-privileges`. It
writes only to its home, its workspace and `/tmp`.

## Setting it up

1. **Key.** `./gen-secrets.sh` generates `CLAUDE_OAI_KEY` into
   `litellm/litellm.env` and `claude-bridge/claude-bridge.env`. `check-env.sh`
   fails when the two differ.
2. **Directories.** `start-main.sh` creates `claude-bridge/workspace` and
   `claude-bridge/home`. They must belong to UID 1000 (`node`); `check-env.sh`
   warns otherwise and prints the `chown` to run.
3. **Login.** The bridge needs its own Claude login, not the agent's. Do not
   copy `.credentials.json`: two copies of one OAuth login can invalidate each
   other on token refresh. Use one of these:
   - interactively: run the command below, then `/login` (the login lands in
     `claude-bridge/home/.claude/`):
     ```bash
     docker compose run --rm -it as-claude-bridge claude
     ```
   - a long-lived token: run `claude setup-token`, then put the token into
     `claude-bridge/claude-bridge.env` as `CLAUDE_CODE_OAUTH_TOKEN=…`.
4. **Start and check:**
   ```bash
   docker compose up -d as-claude-bridge
   docker compose ps as-claude-bridge
   docker compose logs -f as-claude-bridge
   ```
   The log line names the mode, e.g. `tools: NONE (chat)`.
5. **Test through LiteLLM:** ask for the model `claude-sub`, e.g. in Open WebUI or
   with a client key on `http://<INGRESS_IP>:4000/v1/chat/completions`. A
   missing login gives `Not logged in · Please run /login` in the response.

## Modes

- **Chat (default).** No built-in tool exists in the session (`tools: []`): the
  bridge behaves like a plain chat model.
- **Executor.** The session acts (Bash, file edits) in `/workspace`. Enable it in
  `claude-bridge/claude-bridge.env`:
  ```bash
  CLAUDE_OAI_ALLOWED_TOOLS=Bash,Read,Edit,Write,Grep,Glob
  CLAUDE_OAI_PERMISSION_MODE=bypassPermissions
  ```
  This is a second autonomous agent. Everyone who can use `claude-sub` through
  LiteLLM drives it: Hermes, Open WebUI users, any client key. It stays inside the
  bridge's namespace: proxy-only egress, its own workspace and home, its code
  read-only. Restrict a client to other models in the LiteLLM UI if it should
  not have that. Consider a narrower tool list or `CLAUDE_OAI_DISALLOWED_TOOLS`.

## Configuration (`claude-bridge/claude-bridge.env`)

| Variable | Meaning |
|---|---|
| `CLAUDE_OAI_KEY` | required Bearer token of LiteLLM (16+ characters), generated |
| `PORT`, `CLAUDE_OAI_HOST` | fixed in `docker-compose.yaml`: `9090`, `0.0.0.0` (the sidecar decides who connects) |
| `CLAUDE_MODEL` | force a model, e.g. `claude-opus-5-5`; default: Claude Code's default |
| `CLAUDE_OAI_CWD` | session working directory, `/workspace` |
| `CLAUDE_OAI_ALLOWED_TOOLS` | tools that exist and run without asking; empty = none |
| `CLAUDE_OAI_DISALLOWED_TOOLS` | tools to block (wins over the allowed list) |
| `CLAUDE_OAI_PERMISSION_MODE` | `default`, `acceptEdits`, `bypassPermissions`, `plan`, `dontAsk` |
| `CLAUDE_OAI_SYSTEM_PROMPT`, `CLAUDE_OAI_SYSTEM_PROMPT_FILE` | fixed system prompt for every request (the file wins), e.g. `/workspace/system-prompt.txt` |
| `CLAUDE_OAI_MEMORY_DIR` | auto-memory directory; its `MEMORY.md` index goes into the prompt, e.g. `/home/node/.claude/projects/-workspace/memory` |

The `model` field of a request passes only for real ids
(`claude-opus/sonnet/haiku-*`). Aliases such as `claude-sub` get the default model.

## Behavior details

- **Chat mode really has no tools.** `allowedTools` only lists tools that run
  without asking; the SDK option `tools` decides which tools exist. The bridge
  sets both, so in chat mode the model has no tools at all.
- **`bypassPermissions`** requires `allowDangerouslySkipPermissions`, which the
  bridge sets in that mode only.
- **The key stays with the server.** The Claude Code process gets the environment
  without the `CLAUDE_OAI_*` variables, so a Bash tool in executor mode cannot
  print `CLAUDE_OAI_KEY`.
- **Failed sessions are errors.** A non-streaming request whose session ends
  unsuccessfully with no text returns 502. A stream gets an `[error: …]` chunk.

## Subscription terms

Serving a personal Claude subscription as an API for other applications
(LiteLLM → Hermes, Open WebUI) may conflict with the subscription's terms of use.
Check them before relying on this setup; a violation can get the account blocked.
