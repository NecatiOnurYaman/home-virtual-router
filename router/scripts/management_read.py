#!/usr/bin/env python3
"""Fixed privileged read operation used by the unprivileged R17.2 API."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys

REPOSITORY = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY))

from router.management.service import collect_management_document


def main() -> int:
    if len(sys.argv) != 1:
        print("error: this helper accepts no arguments", file=sys.stderr)
        return 2
    if os.geteuid() != 0:
        print("error: root privileges are required", file=sys.stderr)
        return 1
    try:
        document = collect_management_document()
    except Exception as error:
        print(f"error: management collection failed: {type(error).__name__}", file=sys.stderr)
        return 1
    print(json.dumps(document, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
