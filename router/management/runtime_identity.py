#!/usr/bin/env python3
"""Validate the root-owned data identifying the active R16 source tree."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat
import tempfile


RUNTIME_ROOT_FILE = Path("/run/home-virtual-router/runtime/repo-root")
REQUIRED_FILES = (
    Path("router/scripts/export_metrics.py"),
    Path("lab/scripts/runtime-start.sh"),
    Path("lab/scripts/runtime-common.sh"),
)


class RuntimeIdentityError(ValueError):
    pass


def validate_root(raw: str) -> Path:
    if not raw or "\n" in raw or "\r" in raw:
        raise RuntimeIdentityError("runtime repository root is malformed")
    root = Path(raw)
    if not root.is_absolute():
        raise RuntimeIdentityError("runtime repository root is not absolute")
    try:
        canonical = root.resolve(strict=True)
    except OSError as error:
        raise RuntimeIdentityError("runtime repository root is unavailable") from error
    if root != canonical:
        raise RuntimeIdentityError("runtime repository root is not canonical")
    if any(not (root / relative).is_file() for relative in REQUIRED_FILES):
        raise RuntimeIdentityError("runtime repository root is incomplete")
    return root


def read(path: Path = RUNTIME_ROOT_FILE, *, require_root_owner: bool = True) -> Path:
    try:
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            raise RuntimeIdentityError("runtime repository metadata is not a regular file")
        if stat.S_IMODE(metadata.st_mode) != 0o640:
            raise RuntimeIdentityError("runtime repository metadata has unsafe mode")
        if require_root_owner and (metadata.st_uid != 0 or metadata.st_gid != 0):
            raise RuntimeIdentityError("runtime repository metadata is not root-owned")
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise RuntimeIdentityError("runtime repository metadata is unavailable") from error
    if not text.endswith("\n") or text.count("\n") != 1:
        raise RuntimeIdentityError("runtime repository metadata is malformed")
    return validate_root(text[:-1])


def write(path: Path, root: Path, *, require_root: bool = True) -> None:
    if require_root and os.geteuid() != 0:
        raise RuntimeIdentityError("runtime repository metadata requires root")
    canonical = validate_root(str(root))
    path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
    parent = path.parent.lstat()
    if stat.S_ISLNK(parent.st_mode) or not stat.S_ISDIR(parent.st_mode) or stat.S_IMODE(parent.st_mode) & 0o022:
        raise RuntimeIdentityError("runtime repository metadata parent is unsafe")
    if require_root and (parent.st_uid != 0 or parent.st_gid != 0):
        raise RuntimeIdentityError("runtime repository metadata parent is not root-owned")
    if path.exists() or path.is_symlink():
        existing = path.lstat()
        if stat.S_ISLNK(existing.st_mode) or not stat.S_ISREG(existing.st_mode):
            raise RuntimeIdentityError("runtime repository metadata target is unsafe")
    descriptor, temporary = tempfile.mkstemp(prefix=".repo-root.", dir=path.parent, text=True)
    temporary_path = Path(temporary)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(f"{canonical}\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary_path, 0o640)
        if os.geteuid() == 0:
            os.chown(temporary_path, 0, 0)
        os.replace(temporary_path, path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    read_parser = subparsers.add_parser("read")
    read_parser.add_argument("path", type=Path)
    write_parser = subparsers.add_parser("write")
    write_parser.add_argument("path", type=Path)
    write_parser.add_argument("root", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "read":
            print(read(args.path))
        else:
            write(args.path, args.root)
    except RuntimeIdentityError as error:
        parser.exit(2, f"runtime identity error: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
