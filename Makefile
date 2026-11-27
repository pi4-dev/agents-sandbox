# agents-sandbox: shortcuts. `make` lists them.
# The profiles that start come from COMPOSE_PROFILES in .env (README, "Profiles").
SHELL := /bin/bash
COMPOSE := docker compose

# directories bind-mounted into the containers, created by you rather than by Docker as
# root: the Claude containers (agent, bridge, Qwen), opencode, Hermes, as-zenoh, the access
# logs of as-dns, as-ingress, as-llm-gw and as-litellm, as-headroom's state; .claude and
# .config/opencode too, because CLAUDE.md and AGENTS.md are mounted into them
DIRS := claude-main/data/workspace claude-main/data/claude-home/.claude \
        claude-bridge/workspace claude-bridge/home/.claude \
        claude-qwen/data/workspace claude-qwen/data/claude-home/.claude \
        opencode/data/workspace opencode/data/home/.config/opencode \
        hermes/data hermes/workspace zenoh/logs dns/logs ingress/logs llm-gw/logs litellm/logs \
        headroom/data

# running <service> <profile>: stop with a hint when the service is not up
define running
	@[ -n "$$($(COMPOSE) ps -q --status running $(1))" ] || \
	  { echo "make: $(1) is not running; it needs the $(2) profile (COMPOSE_PROFILES in .env), then make up" >&2; exit 1; }
endef

.DEFAULT_GOAL := help

help: ## List the targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}'

# --- environment ---

setup: ## Create missing env files and local config, fill generated secrets, create directories
	./gen-secrets.sh >/dev/null
	mkdir -p $(DIRS)

check: ## Check env files, CA, directory owners (check-env.sh)
	./check-env.sh

up: setup check ## Prepare and start every container of the active profiles (keeps all state)
	$(COMPOSE) up -d
	$(MAKE) --no-print-directory squid-reload

down: ## Stop and remove the containers (data, logins and logs stay on disk)
	$(COMPOSE) down --remove-orphans

restart: ## Restart one service: make restart S=as-litellm
	@[ -n "$(S)" ] || { echo "make: name the service, e.g. make restart S=as-litellm" >&2; exit 1; }
	$(COMPOSE) restart $(S)

ps: ## Container status
	$(COMPOSE) ps -a

logs: ## Logs (follow), all or one service: make logs S=as-litellm
	$(COMPOSE) logs -f --tail=100 $(S)

squid-reload: ## Reload the Squid configuration (squid/conf) without a restart
	$(COMPOSE) exec as-squid squid -k reconfigure -f /etc/squid/conf/squid.conf

# --- agent sessions; ARGS="..." replaces the default arguments ---

claude: ARGS ?= --dangerously-skip-permissions --remote-control main
claude: ## Claude Code in the Claude agent (as-claude-main), Remote Control
	$(call running,as-claude-main,claude)
	$(COMPOSE) exec as-claude-main claude $(ARGS)

qwen: ## Claude Code on the LiteLLM model CLAUDE_QWEN_MODEL (as-claude-qwen); e.g. ARGS=--resume
	$(call running,as-claude-qwen,qwen)
	$(COMPOSE) exec as-claude-qwen claude $(ARGS)

opencode: ARGS ?= --standalone
opencode: ## opencode with a private server (as-opencode); e.g. ARGS='run "Explain this repo"'
	$(call running,as-opencode,opencode)
	$(COMPOSE) exec as-opencode opencode $(ARGS)

shell: ## Shell in a container: make shell S=as-claude-main
	@[ -n "$(S)" ] || { echo "make: name the service, e.g. make shell S=as-claude-main" >&2; exit 1; }
	$(COMPOSE) exec $(S) sh -c 'command -v bash >/dev/null && exec bash || exec sh'

# --- tests ---

test: ## Static checks of CI: shellcheck (if installed), secrets, env examples, compose, JSON
	@if command -v shellcheck >/dev/null; then \
	  shellcheck fw/fw.sh ssl/init_ca.sh check-env.sh gen-secrets.sh squid/*.sh tests/*.sh tests/*/*.sh \
	    litellm/run.sh zenoh/conf/run.sh hermes/ca-trust.sh dns/run.sh && echo "shellcheck: OK"; \
	else echo "make: shellcheck is not installed, skipped" >&2; fi
	tests/check-no-secrets.sh
	./check-env.sh --examples
	tests/compose/validate.sh
	python3 -m json.tool claude-main/policy/managed-settings.json >/dev/null

.PHONY: help setup check up down restart ps logs squid-reload claude qwen opencode shell test
