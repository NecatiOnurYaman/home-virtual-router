#!/usr/bin/env python3
"""Run the R17.2 read-only API on IPv4 loopback only."""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import sys

REPOSITORY = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY))

from router.management.api import FixedHelperProvider, ManagementAPI


LOOPBACK_HOST = "127.0.0.1"
DEFAULT_PORT = 8080


def handler_for(api: ManagementAPI) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def respond(self, method: str) -> None:
            status, payload = api.dispatch(method, self.path.split("?", 1)[0])
            body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

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
    HTTPServer((LOOPBACK_HOST, args.port), handler_for(api)).serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
