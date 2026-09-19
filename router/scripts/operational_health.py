#!/usr/bin/env python3
"""Emit one deterministic, read-only R17.1 operational-health document."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

REPOSITORY = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY))

from router.management.collector import Collector
from router.scripts import validate_config


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("/etc/home-virtual-router/router.env"))
    args = parser.parse_args()
    try:
        values = validate_config.parse(args.config)
        validate_config.validate(values)
        snapshot = Collector(values).collect()
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(snapshot.as_dict(), sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
