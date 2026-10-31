#!/usr/bin/env python3
"""Register the LiteLLM virtual keys that clients already have in their env files.

The keys are generated before the first start (gen-secrets.sh) and written into
the clients' env files; this one-shot job (service as-litellm-keys) makes LiteLLM
accept exactly those values, so the stack starts in one `docker compose up`.

  LITELLM_URL          LiteLLM base URL (default http://as-litellm:4000)
  LITELLM_MASTER_KEY   admin key
  LITELLM_CLIENT_KEYS  "alias=ENV_VAR ...", e.g. "hermes=LITELLM_API_KEY"
  LITELLM_CLIENT_ROUTES  routes the client keys may call, space-separated (default: chat
                       and text completions, embeddings, the model list). Explicit
                       paths, because LiteLLM's "llm_api_routes" group (the UI's "AI
                       APIs") also contains /model/info and /model_group/info, which
                       show the upstream (api_base, settings).

Per alias:
  - key already registered      -> nothing to do (settings made in the UI stay), except
                                   a key with full access (no allowed_routes, e.g. after an
                                   edit in the UI) gets LITELLM_CLIENT_ROUTES
  - alias exists with another   -> rotation: a new key with the old key's settings
    key (value changed in env)     (models, budgets, limits, metadata) replaces it
  - alias unknown               -> create the key

Key values are never printed, and they never travel in a URI (access logs of
LiteLLM or of a proxy in front of it): the raw value is sent only in the body of
POST /key/generate. Existence is checked by comparing SHA-256 hashes, which is
how LiteLLM stores keys (the "token" field of /key/list).
"""
import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("LITELLM_URL", "http://as-litellm:4000").rstrip("/")
MASTER = os.environ.get("LITELLM_MASTER_KEY", "")
ROUTES = os.environ.get("LITELLM_CLIENT_ROUTES", " ".join((
    "/v1/chat/completions", "/chat/completions", "/v1/completions", "/completions",
    "/v1/embeddings", "/embeddings", "/v1/models", "/models"))).split()
# settings carried over to the new key on rotation (what the LiteLLM UI lets you set)
CARRY = ("models", "max_budget", "budget_duration", "tpm_limit", "rpm_limit",
         "max_parallel_requests", "metadata", "team_id", "user_id", "aliases",
         "permissions", "model_max_budget", "model_rpm_limit", "model_tpm_limit",
         "allowed_routes", "tags")


def api(method, path, body=None):
    req = urllib.request.Request(
        BASE + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {MASTER}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as err:
        return err.code, {}


def keys_with_alias(alias):
    status, data = api("GET", "/key/list?" + urllib.parse.urlencode(
        {"key_alias": alias, "return_full_object": "true"}))
    if status != 200:
        sys.exit(f"litellm-keys: listing keys for '{alias}' failed (HTTP {status})")
    return [k for k in data.get("keys", []) if k.get("key_alias") == alias]


def generate(key, alias, settings):
    body = {k: v for k, v in settings.items() if v not in (None, [], {})}
    body.setdefault("metadata", {})["managed_by"] = "agents-sandbox"
    # never full access; a rotated key keeps the routes it had
    body.setdefault("allowed_routes", ROUTES)
    body.update(key=key, key_alias=alias)
    status, _ = api("POST", "/key/generate", body)
    if status != 200:
        sys.exit(f"litellm-keys: creating key '{alias}' failed (HTTP {status})")


def ensure(alias, key):
    token = hashlib.sha256(key.encode()).hexdigest()
    old = keys_with_alias(alias)
    current = next((k for k in old if k.get("token") == token), None)
    if current is not None:
        if current.get("allowed_routes"):
            print(f"litellm-keys: {alias}: already registered")
            return
        # full access (no routes, e.g. cleared in the UI)
        status, _ = api("POST", "/key/update", {"key": token, "allowed_routes": ROUTES})
        if status != 200:
            sys.exit(f"litellm-keys: restricting '{alias}' to {ROUTES} failed (HTTP {status})")
        print(f"litellm-keys: {alias}: already registered, restricted to {' '.join(ROUTES)}")
        return
    if not old:
        generate(key, alias, {})
        print(f"litellm-keys: {alias}: created")
        return
    # rotation: new key under a temporary alias, delete the old one, take over the alias
    settings = {k: old[0].get(k) for k in CARRY}
    tmp = f"{alias}.rotating"
    api("POST", "/key/delete", {"key_aliases": [tmp]})   # leftover of an interrupted run
    generate(key, tmp, settings)
    status, _ = api("POST", "/key/delete", {"key_aliases": [alias]})
    if status != 200:
        sys.exit(f"litellm-keys: deleting the old '{alias}' key failed (HTTP {status})")
    status, _ = api("POST", "/key/update", {"key": token, "key_alias": alias})
    if status != 200:
        sys.exit(f"litellm-keys: renaming '{tmp}' to '{alias}' failed (HTTP {status})")
    print(f"litellm-keys: {alias}: rotated (old key deleted, settings kept)")


def main():
    if not MASTER:
        sys.exit("litellm-keys: LITELLM_MASTER_KEY is not set")
    for item in os.environ.get("LITELLM_CLIENT_KEYS", "").split():
        alias, _, var = item.partition("=")
        key = os.environ.get(var, "")
        if not key.startswith("sk-") or len(key) < 16 or "CHANGE_ME" in key:
            sys.exit(f"litellm-keys: {var} for '{alias}' must be a generated sk-... key "
                     f"of at least 16 characters (run ./gen-secrets.sh)")
        if key == MASTER:
            sys.exit(f"litellm-keys: {var} for '{alias}' is LITELLM_MASTER_KEY")
        ensure(alias, key)


if __name__ == "__main__":
    main()
