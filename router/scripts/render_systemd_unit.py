#!/usr/bin/env python3
"""Render the R15 systemd unit without installing or enabling it."""

from pathlib import Path
import sys


def systemd_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render(repository: Path) -> str:
    repository = repository.resolve(strict=True)
    template = repository / "deploy/systemd/home-virtual-router.service.in"
    return (template.read_text(encoding="utf-8")
            .replace("@HVR_DOCUMENTATION_QUOTED@", systemd_quote(f"file://{repository}/docs/runtime.md"))
            .replace("@HVR_SERVICE_START_QUOTED@", systemd_quote(str(repository / "router/scripts/service-start.sh")))
            .replace("@HVR_SERVICE_STOP_QUOTED@", systemd_quote(str(repository / "router/scripts/service-stop.sh")))
            .replace("@HVR_REPO_DIR_QUOTED@", systemd_quote(str(repository)))
            .replace("@HVR_REPO_DIR@", str(repository)))


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} REPOSITORY", file=sys.stderr)
        return 2
    repository = Path(sys.argv[1])
    try:
        print(render(repository), end="")
    except (OSError, RuntimeError) as error:
        print(f"cannot render systemd unit: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
