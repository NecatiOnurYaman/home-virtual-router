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
    "DHCP_RANGE_START", "DHCP_RANGE_END", "DHCP_LEASE_TIME", "DHCP_DNS_SERVER",
    "DNS_UPSTREAM", "DNS_CACHE_SIZE", "DNS_TEST_NAME", "DNS_TEST_ADDRESS",
    "DNS_TEST_NAME_ALT", "DNS_TEST_ADDRESS_ALT",
    "IPFIX_ENABLED", "IPFIX_COLLECTOR_HOST", "IPFIX_COLLECTOR_PORT",
    "IPFIX_CAPTURE_INTERFACE",
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
    if lan.prefixlen != 24:
        raise ValueError("R6 DHCP currently requires LAN_SUBNET to be /24")
    if not upstream.subnet_of(ipaddress.ip_network("192.0.2.0/24")):
        raise ValueError("UPSTREAM_SUBNET must be within RFC 5737 TEST-NET-1 (192.0.2.0/24)")
    for key in ("UPSTREAM_GATEWAY", "ROUTER_WAN"):
        if ipaddress.ip_address(values[key]) not in upstream:
            raise ValueError(f"{key} must be within UPSTREAM_SUBNET")
    if ipaddress.ip_address(values["ROUTER_LAN"]) not in lan:
        raise ValueError("ROUTER_LAN must be within LAN_SUBNET")
    if ipaddress.ip_address(values["CLIENT_ADDRESS"]) not in lan:
        raise ValueError("CLIENT_ADDRESS must be within LAN_SUBNET")
    dhcp_start = ipaddress.ip_address(values["DHCP_RANGE_START"])
    dhcp_end = ipaddress.ip_address(values["DHCP_RANGE_END"])
    if dhcp_start not in lan or dhcp_end not in lan:
        raise ValueError("DHCP range must be within LAN_SUBNET")
    if int(dhcp_start) > int(dhcp_end):
        raise ValueError("DHCP_RANGE_START must not exceed DHCP_RANGE_END")
    if ipaddress.ip_address(values["ROUTER_LAN"]) in (dhcp_start, dhcp_end) or (
        int(dhcp_start) <= int(ipaddress.ip_address(values["ROUTER_LAN"])) <= int(dhcp_end)
    ):
        raise ValueError("DHCP range must exclude ROUTER_LAN")
    if ipaddress.ip_address(values["DHCP_DNS_SERVER"]) not in lan:
        raise ValueError("DHCP_DNS_SERVER must be within LAN_SUBNET")
    if not re.fullmatch(r"[1-9][0-9]*[mhd]", values["DHCP_LEASE_TIME"]):
        raise ValueError("DHCP_LEASE_TIME must be a positive duration ending in m, h, or d")
    if ipaddress.ip_address(values["DNS_UPSTREAM"]) not in upstream:
        raise ValueError("DNS_UPSTREAM must be within UPSTREAM_SUBNET")
    if values["DNS_UPSTREAM"] != values["UPSTREAM_GATEWAY"]:
        raise ValueError("R7 DNS_UPSTREAM must be the isolated upstream namespace address")
    if not re.fullmatch(r"[1-9][0-9]{0,3}", values["DNS_CACHE_SIZE"]):
        raise ValueError("DNS_CACHE_SIZE must be between 1 and 9999")
    for key in ("DNS_TEST_NAME", "DNS_TEST_NAME_ALT"):
        if not re.fullmatch(r"[a-z0-9-]+(?:\.[a-z0-9-]+)+", values[key]):
            raise ValueError(f"{key} must be a lowercase test domain")
    if values["DNS_TEST_NAME"] == values["DNS_TEST_NAME_ALT"]:
        raise ValueError("R7 deterministic DNS names must be unique")
    for key in ("DNS_TEST_ADDRESS", "DNS_TEST_ADDRESS_ALT"):
        if ipaddress.ip_address(values[key]) not in upstream:
            raise ValueError(f"{key} must be within RFC 5737 upstream test subnet")
    if values["IPFIX_ENABLED"] not in {"0", "1"}:
        raise ValueError("IPFIX_ENABLED must be 0 or 1")
    if values["IPFIX_COLLECTOR_HOST"] != values["UPSTREAM_GATEWAY"]:
        raise ValueError("R8 collector must be the isolated upstream namespace address")
    if not re.fullmatch(r"[1-9][0-9]{0,4}", values["IPFIX_COLLECTOR_PORT"]):
        raise ValueError("IPFIX_COLLECTOR_PORT must be between 1 and 65535")
    if int(values["IPFIX_COLLECTOR_PORT"]) > 65535:
        raise ValueError("IPFIX_COLLECTOR_PORT must be between 1 and 65535")
    if values["IPFIX_CAPTURE_INTERFACE"] != values["ROUTER_LAN_INTERFACE"]:
        raise ValueError("R8 must capture on the router LAN interface before NAT")
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
