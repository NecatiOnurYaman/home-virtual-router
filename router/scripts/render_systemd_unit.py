#!/usr/bin/env python3
"""Render the R15 systemd unit without installing or enabling it."""

from pathlib import Path
import sys
from urllib.parse import quote


def validate_path(value: str) -> None:
    if not value.startswith("/"):
        raise ValueError("systemd paths must be absolute")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ValueError("systemd paths must not contain control characters")


def systemd_path_value(value: str) -> str:
    """Escape a scalar path directive without adding literal quote characters."""
    validate_path(value)
    safe = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/_.-$")
    rendered = ""
    for character in value:
        if character in safe:
            rendered += character
        elif character == "%":
            rendered += "%%"
        else:
            rendered += "".join(f"\\x{byte:02x}" for byte in character.encode("utf-8"))
    return rendered


def systemd_exec_argument(value: str) -> str:
    """Quote one systemd Exec*= command-line argument."""
    validate_path(value)
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%").replace("$", "$$")
    return f'"{escaped}"'


def systemd_documentation_uri(value: str) -> str:
    validate_path(value)
    # URI escaping and systemd specifier escaping are separate layers.
    return ("file://" + quote(value, safe="/-._~")).replace("%", "%%")


def render(repository: Path) -> str:
    repository = repository.resolve(strict=True)
    repository_text = str(repository)
    template = repository / "deploy/systemd/home-virtual-router.service.in"
    return (template.read_text(encoding="utf-8")
            .replace("@HVR_DOCUMENTATION_URI@", systemd_documentation_uri(str(repository / "docs/runtime.md")))
            .replace("@HVR_EXEC_START@", systemd_exec_argument(str(repository / "router/scripts/service-start.sh")))
            .replace("@HVR_EXEC_STOP@", systemd_exec_argument(str(repository / "router/scripts/service-stop.sh")))
            .replace("@HVR_WORKING_DIRECTORY@", systemd_path_value(repository_text)))


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} REPOSITORY", file=sys.stderr)
        return 2
    repository = Path(sys.argv[1])
    try:
        print(render(repository), end="")
    except (OSError, RuntimeError, ValueError) as error:
        print(f"cannot render systemd unit: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
