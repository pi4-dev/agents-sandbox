"""Fake OpenAI-compatible upstream for tests/litellm/run-messages-tests.sh.

Prints one line per request: `<path> <role,role,...>` (roles of `messages`,
or `responses-api` when the body is a Responses API request), answers 400 so
LiteLLM does not retry.
Usage: python3 upstream-recorder.py <port>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Recorder(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if "messages" in body:
            roles = ",".join(m.get("role", "?") for m in body["messages"])
        else:
            roles = "responses-api"
        print(f"{self.path} {roles}", flush=True)
        self.send_response(400)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"error":{"message":"recorded","type":"invalid_request_error"}}')

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), Recorder).serve_forever()
