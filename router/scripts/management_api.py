#!/usr/bin/env python3
"""Run the R17.2 read-only API on IPv4 loopback only."""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import sys

REPOSITORY = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY))

from router.management.api import FixedHelperProvider, ManagementAPI
from router.management.web import ManagementApplication, StaticResources


LOOPBACK_HOST = "127.0.0.1"
DEFAULT_PORT = 8080


def handler_for(application: ManagementApplication) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def respond(self, method: str) -> None:
            response = application.dispatch(method, self.path)
            self.send_response(response.status)
            self.send_header("Content-Type", response.content_type)
            self.send_header("Content-Length", str(len(response.body)))
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'self'; connect-src 'self'; img-src 'self'; style-src 'self'; script-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(response.body)

        def do_GET(self) -> None: self.respond("GET")
        def do_POST(self) -> None: self.respond("POST")
        def do_PUT(self) -> None: self.respond("PUT")
        def do_PATCH(self) -> None: self.respond("PATCH")
        def do_DELETE(self) -> None: self.respond("DELETE")
        def log_message(self, format: str, *args: object) -> None:
            super().log_message(format, *args)

    return Handler


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("port must be between 1 and 65535")
    api = ManagementAPI(FixedHelperProvider())
    application = ManagementApplication(api, StaticResources(REPOSITORY / "web"))
    HTTPServer((LOOPBACK_HOST, args.port), handler_for(application)).serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
