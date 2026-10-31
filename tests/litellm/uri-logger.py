#!/usr/bin/env python3
"""Reverse proxy that logs every request line (METHOD URI), like a typical access log.

  uri-logger.py LISTEN_PORT UPSTREAM_URL LOGFILE

Used by run-keys-tests.sh to prove that secrets never travel in URIs.
"""
import http.server
import sys
import urllib.error
import urllib.request

PORT, UPSTREAM, LOG = int(sys.argv[1]), sys.argv[2].rstrip("/"), sys.argv[3]


class Proxy(http.server.BaseHTTPRequestHandler):
    def _forward(self):
        with open(LOG, "a") as f:
            f.write(f"{self.command} {self.path}\n")
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)) or None
        headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length")}
        req = urllib.request.Request(UPSTREAM + self.path, data=body, method=self.command, headers=headers)
        try:
            resp = urllib.request.urlopen(req, timeout=30)
        except urllib.error.HTTPError as err:
            resp = err
        data = resp.read()
        self.send_response(resp.status if hasattr(resp, "status") else resp.code)
        self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _forward

    def log_message(self, fmt, *args):
        pass


http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Proxy).serve_forever()
