#!/usr/bin/env python3
"""Bounded test-only HTTP receiver for real R11 namespace integration."""

from __future__ import annotations

import argparse
import json
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


def validate_envelope(value: object, router_id: str) -> str:
    if not isinstance(value, dict) or value.get("protocol_version") != 1 or value.get("router_id") != router_id:
        raise ValueError("invalid envelope identity")
    snapshot = value.get("snapshot")
    if not isinstance(snapshot, dict) or snapshot.get("schema_version") != 1:
        raise ValueError("invalid snapshot")
    timestamp = snapshot.get("timestamp")
    if not isinstance(timestamp, str) or not timestamp.endswith("Z"):
        raise ValueError("invalid UTC timestamp")
    datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    router = snapshot.get("router")
    metrics = router.get("metrics") if isinstance(router, dict) else None
    if not isinstance(metrics, list) or not metrics:
        raise ValueError("metrics are absent")
    required = {"system.uptime_seconds", "system.cpu.utilization_ratio", "system.memory.total_bytes"}
    names = {sample.get("name") for sample in metrics if isinstance(sample, dict)}
    if not required <= names or not {"counter", "gauge", "state"} <= {sample.get("type") for sample in metrics if isinstance(sample, dict)}:
        raise ValueError("required metric names or types are absent")
    if {sample.get("interface", {}).get("role") for sample in metrics if isinstance(sample, dict) and isinstance(sample.get("interface"), dict)} != {"lan", "wan", "telemetry"}:
        raise ValueError("interface roles are incomplete")
    return timestamp


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--path", required=True)
    parser.add_argument("--router-id", required=True)
    parser.add_argument("--expected-source", required=True)
    parser.add_argument("--count", type=int, default=2)
    parser.add_argument("--deadline-seconds", type=float, default=15)
    parser.add_argument("--result", required=True, type=Path)
    parser.add_argument("--ready", required=True, type=Path)
    args = parser.parse_args()
    accepted: list[dict[str, object]] = []
    rejected = 0

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            nonlocal rejected
            try:
                if self.path != args.path or self.client_address[0] != args.expected_source:
                    raise ValueError("unexpected path or source")
                if self.headers.get_content_type() != "application/json":
                    raise ValueError("unexpected content type")
                length = int(self.headers.get("Content-Length", "-1"))
                if not 0 < length <= 1_000_000:
                    raise ValueError("invalid content length")
                envelope = json.loads(self.rfile.read(length))
                timestamp = validate_envelope(envelope, args.router_id)
                if accepted and timestamp <= accepted[-1]["timestamp"]:
                    raise ValueError("snapshot timestamp did not advance")
                accepted.append({"timestamp": timestamp, "source": self.client_address[0], "envelope": envelope})
                self.send_response(204)
            except (ValueError, json.JSONDecodeError):
                rejected += 1
                self.send_response(400)
            self.end_headers()

        def log_message(self, *_: object) -> None:
            return

    server = HTTPServer((args.bind, args.port), Handler)
    server.timeout = 0.25
    args.ready.write_text("ready\n", encoding="ascii")
    deadline = time.monotonic() + args.deadline_seconds
    while len(accepted) < args.count and time.monotonic() < deadline:
        server.handle_request()
    server.server_close()
    result = {"accepted": len(accepted), "rejected": rejected, "requests": accepted}
    args.result.write_text(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if len(accepted) == args.count else 1


if __name__ == "__main__":
    raise SystemExit(main())
