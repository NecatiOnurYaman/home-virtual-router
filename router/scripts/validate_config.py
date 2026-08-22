#!/usr/bin/env python3
"""Validate the small, non-executable KEY=VALUE lab configuration format."""

from __future__ import annotations

import ipaddress
import re
import sys
from pathlib import Path

REQUIRED = {
    "UPSTREAM_SUBNET", "UPSTREAM_GATEWAY", "ROUTER_WAN", "LAN_SUBNET", "ROUTER_LAN",
    "CLIENT_ADDRESS", "UPSTREAM_NAMESPACE", "ROUTER_NAMESPACE", "CLIENT_NAMESPACE",
    "UPSTREAM_INTERFACE", "ROUTER_WAN_INTERFACE", "ROUTER_LAN_INTERFACE",
    "CLIENT_INTERFACE",
    "NAT_TABLE", "NAT_CHAIN", "FILTER_TABLE", "FILTER_CHAIN",
}
LINE = re.compile(r"([A-Z][A-Z0-9_]*)=([^\s#]+)")
NAME = re.compile(r"hvr-[a-z0-9_.-]+")


def parse(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = LINE.fullmatch(line)
        if not match:
            raise ValueError(f"{path}:{number}: expected KEY=VALUE")
        key, value = match.groups()
        if key in values:
            raise ValueError(f"{path}:{number}: duplicate key {key}")
        values[key] = value
    missing = sorted(REQUIRED - values.keys())
    if missing:
        raise ValueError(f"missing required keys: {', '.join(missing)}")
    return values


def validate(values: dict[str, str]) -> None:
    upstream = ipaddress.ip_network(values["UPSTREAM_SUBNET"], strict=True)
    lan = ipaddress.ip_network(values["LAN_SUBNET"], strict=True)
    if not upstream.subnet_of(ipaddress.ip_network("192.0.2.0/24")):
        raise ValueError("UPSTREAM_SUBNET must be within RFC 5737 TEST-NET-1 (192.0.2.0/24)")
    for key in ("UPSTREAM_GATEWAY", "ROUTER_WAN"):
        if ipaddress.ip_address(values[key]) not in upstream:
            raise ValueError(f"{key} must be within UPSTREAM_SUBNET")
    if ipaddress.ip_address(values["ROUTER_LAN"]) not in lan:
        raise ValueError("ROUTER_LAN must be within LAN_SUBNET")
    if ipaddress.ip_address(values["CLIENT_ADDRESS"]) not in lan:
        raise ValueError("CLIENT_ADDRESS must be within LAN_SUBNET")
    if upstream.overlaps(lan):
        raise ValueError("UPSTREAM_SUBNET and LAN_SUBNET must not overlap")
    address_keys = ("UPSTREAM_GATEWAY", "ROUTER_WAN", "ROUTER_LAN", "CLIENT_ADDRESS")
    if len({values[key] for key in address_keys}) != len(address_keys):
        raise ValueError("lab interface addresses must be unique")
    namespace_keys = ("UPSTREAM_NAMESPACE", "ROUTER_NAMESPACE", "CLIENT_NAMESPACE")
    interface_keys = (
        "UPSTREAM_INTERFACE", "ROUTER_WAN_INTERFACE", "ROUTER_LAN_INTERFACE",
        "CLIENT_INTERFACE",
    )
    nft_keys = ("NAT_TABLE", "NAT_CHAIN", "FILTER_TABLE", "FILTER_CHAIN")
    for key in namespace_keys + interface_keys + nft_keys:
        if not NAME.fullmatch(values[key]):
            raise ValueError(f"{key} must use the hvr-* naming convention")
    if len({values[key] for key in namespace_keys}) != len(namespace_keys):
        raise ValueError("namespace names must be unique")
    if len({values[key] for key in interface_keys}) != len(interface_keys):
        raise ValueError("interface names must be unique")
    for key in interface_keys:
        if len(values[key]) > 15:
            raise ValueError(f"{key} exceeds Linux IFNAMSIZ (15 visible characters)")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} CONFIG", file=sys.stderr)
        return 2
    try:
        validate(parse(Path(sys.argv[1])))
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"configuration valid: {sys.argv[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
