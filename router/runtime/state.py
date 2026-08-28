"""Strict, deterministic parsing for the small R12 runtime state file."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import argparse
import os
import tempfile


VERSION = "1"
STAGES = (
    "topology", "routing", "nat", "firewall", "dhcp", "dns",
    "observability", "ipfix", "metrics-export",
)
STATUSES = {"starting", "running", "degraded", "stopping", "failed"}
KEYS = ("VERSION", "PROFILE", "STATUS", "STARTED_AT", "OWNED_STAGES")


class StateError(ValueError):
    pass


def desired_stages(profile: str, ipfix_enabled: bool, metrics_enabled: bool) -> tuple[str, ...]:
    if profile not in {"lab", "observability"}:
        raise StateError(f"invalid profile: {profile!r}")
    stages = ["topology", "routing", "nat", "firewall", "dhcp", "dns"]
    if profile == "observability":
        stages.append("observability")
    if ipfix_enabled:
        stages.append("ipfix")
    if metrics_enabled:
        stages.append("metrics-export")
    return tuple(stages)


def rollback_order(stages: tuple[str, ...]) -> tuple[str, ...]:
    unknown = set(stages) - set(STAGES)
    if unknown:
        raise StateError(f"unknown rollback stage: {sorted(unknown)[0]}")
    return tuple(reversed(stages))


@dataclass(frozen=True)
class RuntimeState:
    profile: str
    status: str
    started_at: str
    owned_stages: tuple[str, ...] = ()

    def validate(self) -> None:
        if self.profile not in {"lab", "observability"}:
            raise StateError(f"invalid profile: {self.profile!r}")
        if self.status not in STATUSES:
            raise StateError(f"invalid status: {self.status!r}")
        if not self.started_at or any(c in self.started_at for c in "\r\n="):
            raise StateError("invalid STARTED_AT")
        if len(set(self.owned_stages)) != len(self.owned_stages):
            raise StateError("duplicate owned stage")
        unknown = set(self.owned_stages) - set(STAGES)
        if unknown:
            raise StateError(f"unknown owned stage: {sorted(unknown)[0]}")
        order = [STAGES.index(stage) for stage in self.owned_stages]
        if order != sorted(order):
            raise StateError("owned stages are not in startup order")

    def render(self) -> str:
        self.validate()
        return (
            f"VERSION={VERSION}\nPROFILE={self.profile}\nSTATUS={self.status}\n"
            f"STARTED_AT={self.started_at}\nOWNED_STAGES={','.join(self.owned_stages)}\n"
        )


def parse(text: str) -> RuntimeState:
    values: dict[str, str] = {}
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line or "=" not in line:
            raise StateError(f"malformed line {line_number}")
        key, value = line.split("=", 1)
        if key not in KEYS:
            raise StateError(f"unknown key: {key!r}")
        if key in values:
            raise StateError(f"duplicate key: {key!r}")
        values[key] = value
    if set(values) != set(KEYS):
        raise StateError("state file has missing keys")
    if values["VERSION"] != VERSION:
        raise StateError(f"unsupported state version: {values['VERSION']!r}")
    owned = tuple(filter(None, values["OWNED_STAGES"].split(",")))
    state = RuntimeState(values["PROFILE"], values["STATUS"], values["STARTED_AT"], owned)
    state.validate()
    return state


def read(path: Path) -> RuntimeState:
    try:
        return parse(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise StateError(f"cannot read state: {exc}") from exc


def write_atomic(path: Path, state: RuntimeState) -> None:
    path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".state.", dir=path.parent, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(state.render())
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o640)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    show = subparsers.add_parser("show")
    show.add_argument("path", type=Path)
    show.add_argument("--field", choices=("profile", "status", "started-at", "owned", "rollback"))
    write = subparsers.add_parser("write")
    write.add_argument("path", type=Path)
    write.add_argument("profile")
    write.add_argument("status")
    write.add_argument("started_at")
    write.add_argument("owned", nargs="?", default="")
    desired = subparsers.add_parser("desired")
    desired.add_argument("profile")
    desired.add_argument("ipfix", choices=("0", "1"))
    desired.add_argument("metrics", choices=("0", "1"))
    args = parser.parse_args()
    if args.command == "desired":
        try:
            print("\n".join(desired_stages(args.profile, args.ipfix == "1", args.metrics == "1")))
        except StateError as exc:
            parser.exit(2, f"runtime state error: {exc}\n")
        return 0
    if args.command == "write":
        try:
            state = RuntimeState(
                args.profile, args.status, args.started_at,
                tuple(filter(None, args.owned.split(","))),
            )
            write_atomic(args.path, state)
        except StateError as exc:
            parser.exit(2, f"runtime state error: {exc}\n")
        return 0
    try:
        state = read(args.path)
    except StateError as exc:
        parser.exit(2, f"runtime state error: {exc}\n")
    values = {
        "profile": state.profile,
        "status": state.status,
        "started-at": state.started_at,
        "owned": ",".join(state.owned_stages),
        "rollback": "\n".join(rollback_order(state.owned_stages)),
    }
    print(values[args.field] if args.field else state.render(), end="" if not args.field else "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
