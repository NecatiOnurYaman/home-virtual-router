"""Strict, read-only parsing for the separate R17 management configuration."""

from __future__ import annotations

from dataclasses import dataclass
import ipaddress
from pathlib import Path
import re


KEYS = ("LAN_HEALTH_TARGET", "INTERNET_HEALTH_TARGET")
LINE = re.compile(r"([A-Z][A-Z0-9_]*)=([^\s#]+)")


@dataclass(frozen=True, slots=True)
class ManagementConfig:
    lan_health_target: str = "none"
    internet_health_target: str = "none"


def parse(text: str, source: str = "management configuration") -> ManagementConfig:
    values: dict[str, str] = {}
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = LINE.fullmatch(line)
        if not match:
            raise ValueError(f"{source}:{number}: expected KEY=VALUE")
        key, value = match.groups()
        if key not in KEYS:
            raise ValueError(f"{source}:{number}: unknown key {key}")
        if key in values:
            raise ValueError(f"{source}:{number}: duplicate key {key}")
        values[key] = value
    return ManagementConfig(values.get("LAN_HEALTH_TARGET", "none"), values.get("INTERNET_HEALTH_TARGET", "none"))


def validate(config: ManagementConfig, router_config: dict[str, str]) -> None:
    for key, target in (("LAN_HEALTH_TARGET", config.lan_health_target), ("INTERNET_HEALTH_TARGET", config.internet_health_target)):
        if target == "none":
            continue
        try:
            ipaddress.IPv4Address(target)
        except ipaddress.AddressValueError as error:
            raise ValueError(f"{key} must be none or an IPv4 address") from error
    if config.lan_health_target != "none":
        lan = ipaddress.ip_network(router_config["LAN_SUBNET"], strict=True)
        if ipaddress.ip_address(config.lan_health_target) not in lan:
            raise ValueError("LAN_HEALTH_TARGET must be within LAN_SUBNET")
        if config.lan_health_target == router_config["ROUTER_LAN"]:
            raise ValueError("LAN_HEALTH_TARGET must not equal ROUTER_LAN")


def load(path: Path, router_config: dict[str, str]) -> ManagementConfig:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        text = ""
    config = parse(text, str(path))
    validate(config, router_config)
    return config
