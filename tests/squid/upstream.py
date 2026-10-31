#!/usr/bin/env python3
"""Fake upstream for the Squid ACL test: answers every request on HTTP and HTTPS.

The body starts with UPSTREAM-OK, so the test can tell "Squid forwarded the
request" apart from any error that Squid generated itself.
"""
import argparse
import http.server
import ssl
import threading


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _answer(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        body = f"UPSTREAM-OK {self.command} {self.headers.get('Host')} {self.path}\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = _answer

    def log_message(self, fmt, *args):
        pass


def serve(addr, port, context=None):
    server = http.server.ThreadingHTTPServer((addr, port), Handler)
    if context:
        server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--addr", action="append", required=True, help="listen address (repeatable)")
    parser.add_argument("--http-port", type=int, default=80)
    parser.add_argument("--https-port", type=int, default=443)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    args = parser.parse_args()

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    for addr in args.addr:
        serve(addr, args.http_port)
        serve(addr, args.https_port, context)
    threading.Event().wait()


if __name__ == "__main__":
    main()
