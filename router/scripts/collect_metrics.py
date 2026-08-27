#!/usr/bin/env python3
"""Collect and print one R10 metric snapshot as deterministic JSON."""

from __future__ import annotations

import argparse
import json
import sys

from router.metrics.collector import InterfaceIdentity, MetricCollectionError, collect_snapshot


def interface_identity(value: str) -> InterfaceIdentity:
    role, separator, name = value.partition("=")
    if not separator or not role or not name:
        raise argparse.ArgumentTypeError("interface must use ROLE=KERNEL_NAME")
    return InterfaceIdentity(role=role, name=name)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interface", action="append", required=True, type=interface_identity)
    parser.add_argument("--cpu-sample-seconds", type=float, default=0.1)
    arguments = parser.parse_args()
    try:
        snapshot = collect_snapshot(tuple(arguments.interface), cpu_sample_seconds=arguments.cpu_sample_seconds)
        print(json.dumps(snapshot.as_dict(), sort_keys=True, separators=(",", ":")))
    except (MetricCollectionError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
