"""Client half of tests/litellm/run-presidio-tests.sh, run inside the LiteLLM container.

Sends requests to LiteLLM (127.0.0.1:4000) and checks, in the bodies the fake model
recorded (upstream-bodies.py), what reached the model: secrets and card numbers masked
in every shape of request, ordinary text unchanged, no way for a client to turn the
guardrail off. Prints "ok   ..." / "FAIL ..." per check; exit status 1 on a failure.
Usage: python3 presidio-client.py <bodies file> masking|fail-closed
"""
import json
import sys
import time
import urllib.error
import urllib.request as u

BODIES, PHASE = sys.argv[1], sys.argv[2]
BASE = "http://127.0.0.1:4000"
fails = 0

# fake values of the real formats (none of them is a live credential)
CARD = "4111 1111 1111 1111"
IBAN = "PL61109010140000071219812874"
GH = "ghp_" + "A1b2C3d4E5" * 4
SK = "sk-ant-api03-" + "Xy9" * 12
PASSWORD = "Hunt3r-2024-x"
PEM_BODY = "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ"
KEY_LINE = "OPENSSH " + "PRIVATE KEY-----"   # split: tests/check-no-secrets.sh flags the whole line
PEM = f"-----BEGIN {KEY_LINE}\n{PEM_BODY}\n-----END {KEY_LINE}"
SECRETS = [CARD, IBAN, GH, SK, PASSWORD, PEM_BODY, "4111111111111111"]
# ordinary agent text: code, hashes, UUIDs, versions, addresses; must reach the model as sent
BENIGN = (
    "def count(tokens):\n    token_count = compute_tokens(tokens)\n"
    'password = os.environ["DB_PASSWORD"]  # see ${POSTGRES_PASSWORD}\n'
    "commit 1c3710d5051649b758da7, image sha256:286e3fa7f3a7426e775e8564fe1870f1ba8f999d3ab8bbb8cc46a44355d9d6e9\n"
    "uuid 550e8400-e29b-41d4-a716-446655440000, version 2.2.362, port 3000, phone 600123456\n"
    "api_key: CHANGE_ME_openrouter, https://github.com/pi4-dev/agents-sandbox, mail jan@example.com"
)


def check(name, cond, detail=""):
    global fails
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f": {detail}"), flush=True)
    fails += 0 if cond else 1


def post(path, body):
    r = u.Request(BASE + path, json.dumps(body).encode(), method="POST",
                  headers={"Authorization": "Bearer sk-test", "content-type": "application/json"})
    try:
        with u.urlopen(r, timeout=60) as resp:
            return resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except Exception as e:  # noqa: BLE001 - any transport error is a result here
        return 0, repr(e)


def recorded():
    try:
        return [json.loads(line) for line in open(BODIES)]
    except FileNotFoundError:
        return []


def sent(name, path, body):
    """POST, then return the request body the model got for it (or None)."""
    before = len(recorded())
    status, text = post(path, body)
    after = recorded()
    got = after[before]["body"] if len(after) > before else None
    check(f"{name}: answered 200", status == 200, f"{status} {text[:300]}")
    return got


def no_secret(name, got, *placeholders):
    s = json.dumps(got)
    leaked = [x for x in SECRETS if x in s or json.dumps(x)[1:-1] in s]
    check(f"{name}: reached the model", got is not None, "no upstream request recorded")
    check(f"{name}: no secret reached the model", got is not None and not leaked, f"leaked {leaked}: {s[:400]}")
    missing = [p for p in placeholders if p not in s]
    check(f"{name}: masked as {', '.join(placeholders)}", got is not None and not missing, f"missing {missing}: {s[:400]}")


for _ in range(180):
    try:
        u.urlopen(BASE + "/health/liveliness", timeout=2)
        break
    except Exception:  # noqa: BLE001
        time.sleep(1)

U = lambda c: {"role": "user", "content": c}  # noqa: E731

if PHASE == "masking":
    got = sent("chat", "/v1/chat/completions",
               {"model": "test", "messages": [U(f"card {CARD}, iban {IBAN}, token {GH}, key {SK}, DB_PASSWORD={PASSWORD}")]})
    no_secret("chat", got, "<CREDIT_CARD>", "<IBAN_CODE>", "<API_SECRET>", "<PASSWORD>")

    got = sent("chat, tool output", "/v1/chat/completions", {"model": "test", "messages": [
        U("read .env"),
        {"role": "assistant", "content": None, "tool_calls": [{"id": "t1", "type": "function", "function": {"name": "bash", "arguments": "{\"cmd\": \"cat .env\"}"}}]},
        {"role": "tool", "tool_call_id": "t1", "content": f"GITHUB_TOKEN={GH}\n{PEM}\nafter"}]})
    no_secret("chat, tool output", got, "<API_SECRET>", "<PRIVATE_KEY>")
    check("chat, tool output: the whole PEM block masked, the text after it kept",
          got is not None and "<PRIVATE_KEY>\nafter" in str(got["messages"][-1]["content"]),
          json.dumps(got)[:400] if got else "")

    got = sent("chat, stream", "/v1/chat/completions", {"model": "test", "stream": True, "messages": [U(f"card {CARD}")]})
    no_secret("chat, stream", got, "<CREDIT_CARD>")

    got = sent("messages (Claude Code)", "/v1/messages", {
        "model": "test", "max_tokens": 5,
        "system": [{"type": "text", "text": f"env holds {SK}"}],
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": f"card {CARD}"}]},
            {"role": "assistant", "content": [{"type": "tool_use", "id": "tu1", "name": "Bash", "input": {"command": "cat .env"}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "tu1", "content": f"token {GH}"}]},
            {"role": "assistant", "content": [{"type": "tool_use", "id": "tu2", "name": "Read", "input": {"file_path": "x"}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "tu2", "content": [{"type": "text", "text": f"iban {IBAN}"}]}]},
        ]})
    no_secret("messages (Claude Code)", got, "<CREDIT_CARD>", "<API_SECRET>", "<IBAN_CODE>")

    got = sent("messages, stream", "/v1/messages",
               {"model": "test", "max_tokens": 5, "stream": True, "system": f"key {SK}", "messages": [U(f"card {CARD}")]})
    no_secret("messages, stream", got, "<CREDIT_CARD>", "<API_SECRET>")

    got = sent("responses", "/v1/responses", {"model": "test", "input": f"card {CARD} token {GH}"})
    no_secret("responses", got, "<CREDIT_CARD>", "<API_SECRET>")

    got = sent("PESEL with its name", "/v1/chat/completions", {"model": "test", "messages": [U("PESEL: 44051401359")]})
    check("PESEL with its name: masked", got is not None and "44051401359" not in json.dumps(got) and "<PL_PESEL>" in json.dumps(got),
          json.dumps(got)[:300] if got else "")

    # a client cannot switch the guardrail off from the request
    for name, extra in [
        ("metadata.disable_global_guardrails", {"metadata": {"disable_global_guardrails": True}}),
        ("litellm_metadata.disable_global_guardrails", {"litellm_metadata": {"disable_global_guardrails": True}}),
        ("metadata.opted_out_global_guardrails", {"metadata": {"opted_out_global_guardrails": ["presidio-mask"]}}),
        ("metadata: forged key metadata", {"metadata": {"user_api_key_metadata": {"disable_global_guardrails": True}}}),
        ("guardrails: []", {"guardrails": []}),
        ("disable_global_guardrails at the top", {"disable_global_guardrails": True}),
    ]:
        got = sent(f"bypass {name}", "/v1/chat/completions", {"model": "test", "messages": [U(f"card {CARD} token {GH}")], **extra})
        no_secret(f"bypass {name}", got, "<CREDIT_CARD>", "<API_SECRET>")

    # permitted: ordinary text reaches the model unchanged (no false positives)
    got = sent("ordinary text", "/v1/chat/completions", {"model": "test", "messages": [U(BENIGN)]})
    check("ordinary text: reaches the model unchanged", got is not None and got["messages"][-1]["content"] == BENIGN,
          json.dumps(got["messages"][-1]["content"])[:500] if got else "")
    got = sent("ordinary text, messages", "/v1/messages", {"model": "test", "max_tokens": 5, "messages": [U(BENIGN)]})
    check("ordinary text, messages: reaches the model unchanged",
          got is not None and BENIGN in [m.get("content") for m in got["messages"]],
          json.dumps(got)[:500] if got else "")

elif PHASE == "fail-closed":
    before = len(recorded())
    status, text = post("/v1/chat/completions", {"model": "test", "messages": [U(f"card {CARD}")]})
    check("analyzer down: request refused", status >= 400, f"{status} {text[:200]}")
    check("analyzer down: nothing reached the model", len(recorded()) == before, "an upstream request was recorded")
    check("analyzer down: the error does not echo the request", CARD not in text, text[:300])

sys.exit(1 if fails else 0)
