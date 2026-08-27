#!/usr/bin/env python3
"""Periodically push fresh router metric snapshots to one HTTP receiver."""

from __future__ import annotations

import argparse
import signal
import sys
import threading
from datetime import UTC, datetime

from router.metrics.collector import InterfaceIdentity
from router.metrics.exporter import run_export_loop


def interface_identity(value: str) -> InterfaceIdentity:
    role, separator, name = value.partition("=")
    if not separator:
        raise argparse.ArgumentTypeError("interface must use ROLE=KERNEL_NAME")
    return InterfaceIdentity(role, name)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--router-id", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--path", required=True)
    parser.add_argument("--interval", required=True, type=float)
    parser.add_argument("--timeout", required=True, type=float)
    parser.add_argument("--interface", action="append", required=True, type=interface_identity)
    args = parser.parse_args()
    if args.interval <= 0 or args.timeout <= 0:
        parser.error("interval and timeout must be positive")
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    def log(message: str) -> None:
        timestamp = datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")
        print(f"{timestamp} {message}", file=sys.stderr, flush=True)
    log(f"metrics exporter started for http://{args.host}:{args.port}{args.path}")
    run_export_loop(router_id=args.router_id, interfaces=tuple(args.interface), host=args.host,
                    port=args.port, path=args.path, interval=args.interval, timeout=args.timeout,
                    stop=stop, log=log)
    log("metrics exporter stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
