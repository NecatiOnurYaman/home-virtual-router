#!/usr/bin/env python3
"""Render the optional R12 systemd unit without installing or enabling it."""

from pathlib import Path
import re
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} REPOSITORY", file=sys.stderr)
        return 2
    repository = Path(sys.argv[1]).resolve()
    if not repository.is_absolute() or not re.fullmatch(r"/[A-Za-z0-9_./-]+", str(repository)):
        print("invalid repository path", file=sys.stderr)
        return 2
    template = repository / "deploy/systemd/home-virtual-router.service.in"
    print(template.read_text(encoding="utf-8").replace("@HVR_REPO_DIR@", str(repository)), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
