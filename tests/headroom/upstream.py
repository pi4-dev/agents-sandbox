"""Fake OpenAI-compatible model server for tests/headroom/run-headroom-tests.sh.

Answers /v1/chat/completions (plain or SSE stream) with the text "hello" and prints one
line per request: `<path> chars=<total characters of all message contents>`, so the test
can see how much of a request reached the model after Headroom.
Usage: python3 upstream.py <port>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def text_len(content):
    if isinstance(content, str):
        return len(content)
    if isinstance(content, list):
        return sum(len(p.get("text", "")) for p in content if isinstance(p, dict))
    return 0


class Model(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        chars = sum(text_len(m.get("content")) for m in body.get("messages", []))
        print(f"{self.path} chars={chars}", flush=True)
        model = body.get("model", "m")
        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            for delta, finish in (({"role": "assistant", "content": "hel"}, None), ({"content": "lo"}, None), ({}, "stop")):
                chunk = {"id": "c", "object": "chat.completion.chunk", "created": 1, "model": model,
                         "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.close_connection = True
            return
        out = json.dumps({"id": "c", "object": "chat.completion", "created": 1, "model": model,
                          "choices": [{"index": 0, "message": {"role": "assistant", "content": "hello"}, "finish_reason": "stop"}],
                          "usage": {"prompt_tokens": 5, "completion_tokens": 1, "total_tokens": 6}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1])), Model).serve_forever()
