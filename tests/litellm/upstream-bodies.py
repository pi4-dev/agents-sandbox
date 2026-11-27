"""Fake OpenAI-compatible model for tests/litellm/run-presidio-tests.sh.

Appends every request body it gets to <file> (one JSON object per line: path and body),
so the test can see exactly what LiteLLM sent to the model, and answers
/v1/chat/completions (plain or SSE stream) and /v1/responses with "ok".
Usage: python3 upstream-bodies.py <port> <file>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, OUT = int(sys.argv[1]), sys.argv[2]


class Model(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(OUT, "a") as f:
            f.write(json.dumps({"path": self.path, "body": body}) + "\n")
        model = body.get("model", "m")
        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            for delta, finish in (({"role": "assistant", "content": "ok"}, None), ({}, "stop")):
                chunk = {"id": "c", "object": "chat.completion.chunk", "created": 1, "model": model,
                         "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.close_connection = True
            return
        if self.path.endswith("/responses"):
            out = json.dumps({"id": "r", "object": "response", "created_at": 1, "status": "completed", "model": model,
                              "output": [{"type": "message", "id": "m", "status": "completed", "role": "assistant",
                                          "content": [{"type": "output_text", "text": "ok", "annotations": []}]}],
                              "usage": {"input_tokens": 5, "output_tokens": 1, "total_tokens": 6}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            return
        out = json.dumps({"id": "c", "object": "chat.completion", "created": 1, "model": model,
                          "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}],
                          "usage": {"prompt_tokens": 5, "completion_tokens": 1, "total_tokens": 6}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", PORT), Model).serve_forever()
