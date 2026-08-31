#!/usr/bin/env python3
"""Validate the small, non-executable KEY=VALUE lab configuration format."""

from __future__ import annotations

import ipaddress
import re
import sys
from pathlib import Path

REQUIRED = {
    "DEPLOYMENT_MODE", "PHYSICAL_WAN_INTERFACE", "PHYSICAL_LAN_INTERFACE",
    "PHYSICAL_TELEMETRY_INTERFACE", "PHYSICAL_WAN_ADDRESS",
    "PHYSICAL_WAN_PREFIX_LENGTH", "PHYSICAL_WAN_GATEWAY",
    "PHYSICAL_MANAGEMENT_INTERFACE_ACK",
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
    "TELEMETRY_MODE", "TELEMETRY_SUBNET", "TELEMETRY_HOST_ADDRESS",
    "TELEMETRY_ROUTER_ADDRESS", "TELEMETRY_HOST_INTERFACE",
    "TELEMETRY_ROUTER_INTERFACE",
    "ROUTER_ID", "METRICS_EXPORT_ENABLED", "METRICS_EXPORT_HOST",
    "METRICS_EXPORT_PORT", "METRICS_EXPORT_PATH",
    "METRICS_EXPORT_INTERVAL_SECONDS", "METRICS_EXPORT_TIMEOUT_SECONDS",
}
LINE = re.compile(r"([A-Z][A-Z0-9_]*)=([^\s#]+)")
NAME = re.compile(r"hvr-[a-z0-9_.-]+")
INTERFACE = re.compile(r"[A-Za-z0-9_.-]{1,15}")


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
    deployment = values["DEPLOYMENT_MODE"]
    if deployment not in {"lab", "physical"}:
        raise ValueError("DEPLOYMENT_MODE must be lab or physical")
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
    if deployment == "lab" and ipaddress.ip_address(values["DNS_UPSTREAM"]) not in upstream:
        raise ValueError("DNS_UPSTREAM must be within UPSTREAM_SUBNET")
    if deployment == "lab" and values["DNS_UPSTREAM"] != values["UPSTREAM_GATEWAY"]:
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
    if values["TELEMETRY_MODE"] not in {"lab", "observability"}:
        raise ValueError("TELEMETRY_MODE must be lab or observability")
    telemetry = ipaddress.ip_network(values["TELEMETRY_SUBNET"], strict=True)
    benchmark = ipaddress.ip_network("198.18.0.0/15")
    if telemetry.prefixlen != 30 or not telemetry.subnet_of(benchmark):
        raise ValueError("TELEMETRY_SUBNET must be a /30 within 198.18.0.0/15")
    telemetry_host = ipaddress.ip_address(values["TELEMETRY_HOST_ADDRESS"])
    telemetry_router = ipaddress.ip_address(values["TELEMETRY_ROUTER_ADDRESS"])
    if telemetry_host not in telemetry.hosts() or telemetry_router not in telemetry.hosts():
        raise ValueError("telemetry addresses must be the two usable TELEMETRY_SUBNET addresses")
    if telemetry_host == telemetry_router:
        raise ValueError("telemetry host and router addresses must be unique")
    if telemetry.overlaps(upstream) or telemetry.overlaps(lan):
        raise ValueError("TELEMETRY_SUBNET must not overlap the WAN or LAN")
    expected_collector = values["UPSTREAM_GATEWAY"] if values["TELEMETRY_MODE"] == "lab" else values["TELEMETRY_HOST_ADDRESS"]
    if deployment == "lab" and values["IPFIX_COLLECTOR_HOST"] != expected_collector:
        raise ValueError(f"IPFIX_COLLECTOR_HOST must be {expected_collector} in {values['TELEMETRY_MODE']} mode")
    if not re.fullmatch(r"[1-9][0-9]{0,4}", values["IPFIX_COLLECTOR_PORT"]):
        raise ValueError("IPFIX_COLLECTOR_PORT must be between 1 and 65535")
    if int(values["IPFIX_COLLECTOR_PORT"]) > 65535:
        raise ValueError("IPFIX_COLLECTOR_PORT must be between 1 and 65535")
    expected_capture = values["ROUTER_LAN_INTERFACE"] if deployment == "lab" else values["PHYSICAL_LAN_INTERFACE"]
    if values["IPFIX_CAPTURE_INTERFACE"] != expected_capture:
        raise ValueError("R8 must capture on the router LAN interface before NAT")
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,62}", values["ROUTER_ID"]):
        raise ValueError("ROUTER_ID must be a lowercase DNS-label-like identifier")
    if values["METRICS_EXPORT_ENABLED"] not in {"0", "1"}:
        raise ValueError("METRICS_EXPORT_ENABLED must be 0 or 1")
    expected_metrics_host = values["UPSTREAM_GATEWAY"] if values["TELEMETRY_MODE"] == "lab" else values["TELEMETRY_HOST_ADDRESS"]
    if deployment == "lab" and values["METRICS_EXPORT_HOST"] != expected_metrics_host:
        raise ValueError(f"METRICS_EXPORT_HOST must be {expected_metrics_host} in {values['TELEMETRY_MODE']} mode")
    if not re.fullmatch(r"[1-9][0-9]{0,4}", values["METRICS_EXPORT_PORT"]) or int(values["METRICS_EXPORT_PORT"]) > 65535:
        raise ValueError("METRICS_EXPORT_PORT must be between 1 and 65535")
    if values["METRICS_EXPORT_PORT"] == "9100":
        raise ValueError("METRICS_EXPORT_PORT 9100 is reserved for the later pull endpoint")
    path = values["METRICS_EXPORT_PATH"]
    if not re.fullmatch(r"/[A-Za-z0-9._~/-]+", path) or "//" in path:
        raise ValueError("METRICS_EXPORT_PATH must be a simple absolute HTTP path")
    for key, minimum, maximum in (("METRICS_EXPORT_INTERVAL_SECONDS", 0.1, 3600), ("METRICS_EXPORT_TIMEOUT_SECONDS", 0.1, 60)):
        try:
            duration = float(values[key])
        except ValueError as error:
            raise ValueError(f"{key} must be numeric") from error
        if not minimum <= duration <= maximum:
            raise ValueError(f"{key} must be between {minimum} and {maximum}")
    if upstream.overlaps(lan):
        raise ValueError("UPSTREAM_SUBNET and LAN_SUBNET must not overlap")
    address_keys = ("UPSTREAM_GATEWAY", "ROUTER_WAN", "ROUTER_LAN", "CLIENT_ADDRESS")
    if len({values[key] for key in address_keys}) != len(address_keys):
        raise ValueError("lab interface addresses must be unique")
    namespace_keys = ("UPSTREAM_NAMESPACE", "ROUTER_NAMESPACE", "CLIENT_NAMESPACE")
    interface_keys = (
        "UPSTREAM_INTERFACE", "ROUTER_WAN_INTERFACE", "ROUTER_LAN_INTERFACE",
        "CLIENT_INTERFACE", "TELEMETRY_HOST_INTERFACE", "TELEMETRY_ROUTER_INTERFACE",
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
    if deployment == "physical":
        if values["TELEMETRY_MODE"] != "lab":
            raise ValueError("R13 physical deployment supports TELEMETRY_MODE=lab only")
        wan = values["PHYSICAL_WAN_INTERFACE"]
        lan_if = values["PHYSICAL_LAN_INTERFACE"]
        telemetry_if = values["PHYSICAL_TELEMETRY_INTERFACE"]
        for key, value in (("PHYSICAL_WAN_INTERFACE", wan), ("PHYSICAL_LAN_INTERFACE", lan_if)):
            if value in {"unset", "none", "lo"} or not INTERFACE.fullmatch(value):
                raise ValueError(f"{key} must name an explicit non-loopback deployment interface")
        if wan == lan_if:
            raise ValueError("R14 requires two distinct configured deployment interfaces: WAN and LAN")
        lab_interfaces = {
            values[key] for key in (
                "UPSTREAM_INTERFACE", "ROUTER_WAN_INTERFACE", "ROUTER_LAN_INTERFACE",
                "CLIENT_INTERFACE", "TELEMETRY_HOST_INTERFACE", "TELEMETRY_ROUTER_INTERFACE",
            )
        }
        if wan in lab_interfaces or lan_if in lab_interfaces:
            raise ValueError("deployment interfaces must not reuse an HVR lab-owned interface name")
        if telemetry_if != "none":
            raise ValueError("R13 physical telemetry interface deployment is deferred; use none")
        if values["PHYSICAL_MANAGEMENT_INTERFACE_ACK"] not in {"none", wan, lan_if}:
            raise ValueError("PHYSICAL_MANAGEMENT_INTERFACE_ACK must be none or the exact WAN/LAN interface")
        try:
            prefix = int(values["PHYSICAL_WAN_PREFIX_LENGTH"])
        except ValueError as error:
            raise ValueError("PHYSICAL_WAN_PREFIX_LENGTH must be an integer") from error
        if not 1 <= prefix <= 32:
            raise ValueError("PHYSICAL_WAN_PREFIX_LENGTH must be between 1 and 32")
        wan_network = ipaddress.ip_network(f"{values['PHYSICAL_WAN_ADDRESS']}/{prefix}", strict=False)
        gateway = ipaddress.ip_address(values["PHYSICAL_WAN_GATEWAY"])
        if gateway not in wan_network or gateway == ipaddress.ip_address(values["PHYSICAL_WAN_ADDRESS"]):
            raise ValueError("PHYSICAL_WAN_GATEWAY must be a different address in the static WAN subnet")
        if wan_network.overlaps(lan):
            raise ValueError("physical WAN network must not overlap LAN_SUBNET")


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
