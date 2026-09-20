"""Composition helpers for the fixed, read-only management representation."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from router.management.collector import Collector
from router.management.config import ManagementConfig, load as load_management_config
from router.scripts import validate_config


ROUTER_CONFIG = Path("/etc/home-virtual-router/router.env")
MANAGEMENT_CONFIG = Path("/etc/home-virtual-router/management.env")


def sanitized_config(router: dict[str, str], management: ManagementConfig) -> dict[str, Any]:
    """Return only fields explicitly approved for the read-only API."""
    return {
        "deployment_mode": router["DEPLOYMENT_MODE"],
        "wan_mode": router.get("PHYSICAL_WAN_MODE", "static"),
        "wan_interface": router["PHYSICAL_WAN_INTERFACE"],
        "lan_interface": router["PHYSICAL_LAN_INTERFACE"],
        "lan_subnet": router["LAN_SUBNET"],
        "router_lan": router["ROUTER_LAN"],
        "ipfix_enabled": router["IPFIX_ENABLED"] == "1",
        "metrics_export_enabled": router["METRICS_EXPORT_ENABLED"] == "1",
        "lan_health_target": management.lan_health_target,
        "internet_health_target": management.internet_health_target,
    }


def collect_management_document(
    router_path: Path = ROUTER_CONFIG,
    management_path: Path = MANAGEMENT_CONFIG,
) -> dict[str, Any]:
    router = validate_config.parse(router_path)
    validate_config.validate(router)
    management = load_management_config(management_path, router)
    return {
        "snapshot": Collector(router, management).collect().as_dict(),
        "config": sanitized_config(router, management),
    }
