#!/usr/bin/env python3
"""Render, install, verify, and remove the narrow persistence artifacts."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat
import tempfile

import render_systemd_unit
import validate_config

UNIT_PATH = Path("etc/systemd/system/home-virtual-router.service")
HEALTH_UNIT_PATH = Path("etc/systemd/system/home-virtual-router-health.service")
HEALTH_TIMER_PATH = Path("etc/systemd/system/home-virtual-router-health.timer")
NM_PATH = Path("etc/NetworkManager/conf.d/90-home-virtual-router-unmanaged.conf")
AUTHORIZATION = Path("/etc/home-virtual-router/allow-physical-deployment")


def configuration(path: Path) -> dict[str, str]:
    values = validate_config.parse(path)
    validate_config.validate(values)
    if values["DEPLOYMENT_MODE"] != "physical":
        raise ValueError("persistence requires DEPLOYMENT_MODE=physical")
    return values


def validate_privileged_inputs(config: Path) -> None:
    for path in (config, AUTHORIZATION):
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
            raise ValueError(f"privileged persistence input is not a regular file: {path}")
        if path.stat().st_uid != 0 or stat.S_IMODE(mode) & 0o022:
            raise ValueError(f"privileged persistence input must be root-owned and not group/world writable: {path}")


def render_nm(values: dict[str, str]) -> str:
    wan, lan = values["PHYSICAL_WAN_INTERFACE"], values["PHYSICAL_LAN_INTERFACE"]
    return f"[keyfile]\nunmanaged-devices=interface-name:{wan};interface-name:{lan}\n"


def artifacts(repository: Path, config: Path) -> dict[Path, tuple[str, int]]:
    values = configuration(config)
    return {
        UNIT_PATH: (render_systemd_unit.render(repository), 0o644),
        HEALTH_UNIT_PATH: (render_systemd_unit.render_template(repository, "home-virtual-router-health.service"), 0o644),
        HEALTH_TIMER_PATH: (render_systemd_unit.render_template(repository, "home-virtual-router-health.timer"), 0o644),
        NM_PATH: (render_nm(values), 0o644),
    }


def destination(root: Path, relative: Path) -> Path:
    return root / relative


def ensure_safe_target(path: Path) -> None:
    if not path.exists() and not path.is_symlink():
        return
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise ValueError(f"refusing unsafe persistence target: {path}")


def ensure_safe_parent(root: Path, relative: Path, *, create: bool) -> bool:
    current = root
    for component in relative.parent.parts:
        current = current / component
        if current.exists() or current.is_symlink():
            mode = current.lstat().st_mode
            if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
                raise ValueError(f"refusing unsafe persistence parent: {current}")
        else:
            if not create:
                return False
            current.mkdir(mode=0o755)
    return True


def write_atomic(root: Path, relative: Path, content: str, mode: int) -> None:
    ensure_safe_parent(root, relative, create=True)
    path = destination(root, relative)
    ensure_safe_target(path)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary_path, mode)
        if os.geteuid() == 0:
            os.chown(temporary_path, 0, 0)
        os.replace(temporary_path, path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def install(root: Path, expected: dict[Path, tuple[str, int]]) -> None:
    for relative, (content, mode) in expected.items():
        write_atomic(root, relative, content, mode)


def verify(root: Path, expected: dict[Path, tuple[str, int]]) -> None:
    for relative, (content, mode) in expected.items():
        ensure_safe_parent(root, relative, create=False)
        path = destination(root, relative)
        ensure_safe_target(path)
        if not path.is_file() or path.read_text(encoding="utf-8") != content:
            raise ValueError(f"installed persistence artifact differs from expected content: {path}")
        actual_mode = stat.S_IMODE(path.stat().st_mode)
        if actual_mode != mode:
            raise ValueError(f"installed persistence artifact has mode {actual_mode:o}, expected {mode:o}: {path}")
        if root == Path("/") and path.stat().st_uid != 0:
            raise ValueError(f"installed persistence artifact is not root-owned: {path}")


def uninstall(root: Path, expected: dict[Path, tuple[str, int]]) -> None:
    for relative, (content, _mode) in expected.items():
        if not ensure_safe_parent(root, relative, create=False):
            continue
        path = destination(root, relative)
        if not path.exists() and not path.is_symlink():
            continue
        ensure_safe_target(path)
        if path.read_text(encoding="utf-8") != content:
            raise ValueError(f"refusing to remove modified persistence artifact: {path}")
        path.unlink()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("render-nm", "install", "verify", "uninstall"))
    parser.add_argument("repository", type=Path)
    parser.add_argument("--config", type=Path, default=Path("/etc/home-virtual-router/router.env"))
    parser.add_argument("--root", type=Path, default=Path("/"))
    args = parser.parse_args()
    try:
        if args.root == Path("/") and args.action != "render-nm":
            validate_privileged_inputs(args.config)
        expected = artifacts(args.repository.resolve(strict=True), args.config)
        if args.action == "render-nm":
            print(expected[NM_PATH][0], end="")
        elif args.action == "install":
            install(args.root, expected)
        elif args.action == "verify":
            verify(args.root, expected)
        else:
            uninstall(args.root, expected)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
