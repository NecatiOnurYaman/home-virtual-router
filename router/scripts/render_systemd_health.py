#!/usr/bin/env python3
"""Render the R16 health service and timer without installing them."""

from pathlib import Path
import sys

import render_systemd_unit


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} REPOSITORY", file=sys.stderr)
        return 2
    try:
        repository = Path(sys.argv[1])
        print(render_systemd_unit.render_template(repository, "home-virtual-router-health.service"), end="")
        print("\n# home-virtual-router-health.timer\n")
        print(render_systemd_unit.render_template(repository, "home-virtual-router-health.timer"), end="")
    except (OSError, RuntimeError, ValueError) as error:
        print(f"cannot render systemd health artifacts: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
