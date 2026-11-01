"""Single leading system message for every chat completion LiteLLM sends.

Many chat templates (vLLM Qwen3: "System message must be at the beginning.")
accept exactly one system message, and only as the first message. Clients do
not always send that: the /v1/messages (Anthropic) adapter puts the top-level
`system` first and keeps any system entries from `messages`, and agents add
system notes mid-conversation. Just before the request goes to the deployment
this hook:
  * merges all leading system messages into one;
  * turns any later system message into a user message (same content).
Requests that already have at most one system message, first, are untouched.
"""

from litellm.integrations.custom_logger import CustomLogger

_CHAT_CALLS = {"completion", "acompletion"}


def _parts(content):
    if content is None:
        return []
    if isinstance(content, str):
        return [{"type": "text", "text": content}] if content else []
    return list(content)


def _merge(contents):
    if all(isinstance(c, str) or c is None for c in contents):
        return "\n\n".join(c for c in contents if c)
    merged = []
    for c in contents:
        merged.extend(_parts(c))
    return merged


def normalize(messages):
    """Return a new list, or None when `messages` needs no change."""
    if not isinstance(messages, list):
        return None
    roles = [m.get("role") if isinstance(m, dict) else None for m in messages]
    lead = 0
    while lead < len(roles) and roles[lead] == "system":
        lead += 1
    if lead <= 1 and "system" not in roles[lead:]:
        return None
    out = []
    if lead:
        first = dict(messages[0])
        first["content"] = _merge([m.get("content") for m in messages[:lead]])
        out.append(first)
    for m in messages[lead:]:
        if isinstance(m, dict) and m.get("role") == "system":
            m = {**m, "role": "user"}
            m.pop("name", None)
        out.append(m)
    return out


class SingleSystemMessage(CustomLogger):
    async def async_pre_call_deployment_hook(self, kwargs, call_type):
        ct = getattr(call_type, "value", call_type)
        if ct not in _CHAT_CALLS:
            return None
        fixed = normalize(kwargs.get("messages"))
        if fixed is None:
            return None
        return {**kwargs, "messages": fixed}


handler = SingleSystemMessage()
