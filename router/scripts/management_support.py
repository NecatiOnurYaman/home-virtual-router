#!/usr/bin/env python3
"""Install and verify the root-owned R17.2 management read boundary."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat
import tempfile


INSTALL_ROOT = Path("usr/lib/home-virtual-router")
HELPER_PATH = Path("usr/libexec/home-virtual-router-management-read")
SUDOERS_PATH = Path("etc/sudoers.d/home-virtual-router-management")
API_USER = "hvr-web"

SOURCE_FILES = (
    "router/management/__init__.py",
    "router/management/api.py",
    "router/management/collector.py",
    "router/management/config.py",
    "router/management/models.py",
    "router/management/runtime_identity.py",
    "router/management/service.py",
    "router/management/web.py",
    "router/runtime/__init__.py",
    "router/runtime/state.py",
    "router/scripts/management_api.py",
    "router/scripts/management_read.py",
    "router/scripts/runtime-stage-status.sh",
    "router/scripts/safety.sh",
    "router/scripts/validate_config.py",
    "lab/scripts/runtime-common.sh",
    "lab/scripts/topology-common.sh",
    "physical/scripts/physical-common.sh",
    "lab/config/defaults.env",
    "router/config/dhclient.conf",
    "router/config/dnsmasq-dhcp.conf.template",
    "router/config/dnsmasq-router-dns.conf.template",
    "router/config/dnsmasq-upstream-test.conf.template",
    "router/config/pmacctd-nfprobe.conf.template",
    "web/index.html",
    "web/static/styles.css",
    "web/static/app.js",
)

HELPER = """#!/bin/sh
set -eu
[ "$#" -eq 0 ] || { echo "error: management read helper accepts no arguments" >&2; exit 2; }
[ "$(/usr/bin/id -u)" -eq 0 ] || { echo "error: root privileges are required" >&2; exit 1; }
cd /
exec /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 \\
  /usr/bin/python3 -I -B /usr/lib/home-virtual-router/router/scripts/management_read.py
"""

SUDOERS = f"""Defaults:{API_USER} env_reset
Defaults:{API_USER} secure_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
{API_USER} ALL=(root) NOPASSWD: /usr/libexec/home-virtual-router-management-read ""
"""


def artifacts(repository: Path) -> dict[Path, tuple[bytes, int]]:
    result: dict[Path, tuple[bytes, int]] = {}
    for source_name in SOURCE_FILES:
        source = repository / source_name
        mode = 0o755 if source_name.endswith((".sh", "management_api.py", "management_read.py")) else 0o644
        result[INSTALL_ROOT / source_name] = (source.read_bytes(), mode)
    result[HELPER_PATH] = (HELPER.encode(), 0o755)
    result[SUDOERS_PATH] = (SUDOERS.encode(), 0o440)
    return result


def safe_parent(root: Path, relative: Path, *, create: bool) -> bool:
    current = root
    for component in relative.parent.parts:
        current /= component
        if current.exists() or current.is_symlink():
            mode = current.lstat().st_mode
            if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
                raise ValueError(f"refusing unsafe management-support parent: {current}")
            if stat.S_IMODE(mode) & 0o022:
                raise ValueError(f"management-support parent is group/world writable: {current}")
            if root == Path("/") and (current.stat().st_uid != 0 or current.stat().st_gid != 0):
                raise ValueError(f"management-support parent is not root-owned: {current}")
        elif create:
            current.mkdir(mode=0o755)
            os.chmod(current, 0o755)
            if os.geteuid() == 0:
                os.chown(current, 0, 0)
        else:
            return False
    return True


def safe_target(path: Path) -> None:
    if not path.exists() and not path.is_symlink():
        return
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise ValueError(f"refusing unsafe management-support target: {path}")


def write_atomic(root: Path, relative: Path, content: bytes, mode: int) -> None:
    safe_parent(root, relative, create=True)
    target = root / relative
    safe_target(target)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
    temporary_path = Path(temporary)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary_path, mode)
        if os.geteuid() == 0:
            os.chown(temporary_path, 0, 0)
        os.replace(temporary_path, target)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def install(root: Path, expected: dict[Path, tuple[bytes, int]]) -> None:
    for relative, (content, mode) in expected.items():
        write_atomic(root, relative, content, mode)


def verify(root: Path, expected: dict[Path, tuple[bytes, int]]) -> None:
    for relative, (content, mode) in expected.items():
        if not safe_parent(root, relative, create=False):
            raise ValueError(f"management-support parent is absent: {relative.parent}")
        target = root / relative
        safe_target(target)
        if not target.is_file() or target.read_bytes() != content:
            raise ValueError(f"installed management-support artifact differs: {target}")
        if stat.S_IMODE(target.stat().st_mode) != mode:
            raise ValueError(f"installed management-support artifact has unsafe mode: {target}")
        if root == Path("/") and (target.stat().st_uid != 0 or target.stat().st_gid != 0):
            raise ValueError(f"installed management-support artifact is not root-owned: {target}")
    installed = root / INSTALL_ROOT
    for directory in (installed, *(path for path in installed.rglob("*") if path.is_dir())):
        if directory.is_symlink() or stat.S_IMODE(directory.stat().st_mode) != 0o755:
            raise ValueError(f"installed management-support directory has unsafe mode: {directory}")
        if root == Path("/") and (directory.stat().st_uid != 0 or directory.stat().st_gid != 0):
            raise ValueError(f"installed management-support directory is not root-owned: {directory}")


def uninstall(root: Path, expected: dict[Path, tuple[bytes, int]]) -> None:
    for relative, (content, _mode) in reversed(tuple(expected.items())):
        if not safe_parent(root, relative, create=False):
            continue
        target = root / relative
        if not target.exists() and not target.is_symlink():
            continue
        safe_target(target)
        if target.read_bytes() != content:
            raise ValueError(f"refusing to remove modified management-support artifact: {target}")
        target.unlink()
    installed = root / INSTALL_ROOT
    if installed.is_dir():
        directories = (path for path in installed.rglob("*") if path.is_dir())
        for directory in sorted(directories, key=lambda path: len(path.parts), reverse=True):
            directory.rmdir()
        installed.rmdir()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("render-sudoers", "install", "verify", "uninstall"))
    parser.add_argument("repository", type=Path)
    parser.add_argument("--root", type=Path, default=Path("/"))
    args = parser.parse_args()
    try:
        expected = artifacts(args.repository.resolve(strict=True))
        if args.action == "render-sudoers":
            print(SUDOERS, end="")
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
