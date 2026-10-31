# LiteLLM model sets

Each file here is one **API endpoint with its models**. `litellm/litellm-config.yaml`
pulls them in with `include:`, and LiteLLM merges their `model_list`s. The
`model_name` is what clients (Hermes, Open WebUI) ask for, so keep it unique
across files.

| File | Endpoint | Key in `litellm/litellm.env` | Squid |
|---|---|---|---|
| `claude-local.yaml` | `as-claude-bridge` (local Claude subscription) | `CLAUDE_OAI_KEY` (generated) | none (inside `as-net-blind`) |
| `openrouter.yaml` | `https://openrouter.ai/api/v1` | `OPENROUTER_API_KEY` | `openrouter.ai` in `llm_api_domains.txt` |

## Adding an endpoint

1. **Model file.** Create `litellm/models/<name>.yaml`. Use the LiteLLM provider
   prefix (`openai/`, `anthropic/`, `openrouter/`, `mistral/`, …); any
   OpenAI-compatible server works with `openai/` plus `api_base`:
   ```yaml
   model_list:
     - model_name: my-model            # what clients request
       litellm_params:
         model: openai/<model id at the endpoint>
         api_base: os.environ/MYAPI_API_BASE     # omit for providers LiteLLM knows
         api_key: os.environ/MYAPI_API_KEY
   ```
2. **Include it.** Add `- models/<name>.yaml` under `include:` in
   `litellm/litellm-config.yaml`.
3. **Secrets.** Add `MYAPI_API_KEY=CHANGE_ME_MYAPI_API_KEY` (and `MYAPI_API_BASE=…`
   if used) to `litellm/litellm.env.example`, and the real values to
   `litellm/litellm.env`. `check-env.sh` refuses to start while a placeholder is left.
4. **Network.** Pick one:
   - **internet endpoint:** add its API host to `squid/conf/llm_api_domains.txt`
     (reachable through Squid from LiteLLM only), then `squid/reload_squid.sh`;
   - **LAN endpoint:** add it to `squid/conf/lan.hosts` as `<name>.lan.internal`
     and use that name in `api_base`, then `squid/reload_squid.sh`. LiteLLM has no
     route out of `as-net-blind`: it reaches the server through Squid's LiteLLM leg (any
     port); allow Squid -> server on the edge router (docs/NETWORK.md).
5. **Apply.** Run `docker compose up -d as-litellm`.

## Removing an endpoint

Delete its line under `include:`, its keys from the env files, and its domain
from `llm_api_domains.txt` (or its line in `lan.hosts`).

## Defaults for clients

- `hermes/config.yaml`, `model.default`: `claude-sub`;
- Open WebUI lists every model the key may use.

Per-client restrictions (models, budgets) are set in the LiteLLM UI, see README.
