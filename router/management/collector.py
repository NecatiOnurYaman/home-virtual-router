"""Observational R17.1 health collection; this module performs no mutations."""

from __future__ import annotations

from datetime import UTC, datetime
import ipaddress
import json
from pathlib import Path
import subprocess
from typing import Callable, Mapping

from router.management.models import Check, Client, HealthState, Snapshot
from router.runtime.state import StateError, read as read_runtime_state


RUNTIME_STATE = Path("/run/home-virtual-router/runtime/state.env")
WAN_DHCP_STATE = Path("/run/home-virtual-router/physical/wan-dhcp/state.env")
LEASE_FILE = Path("/run/home-virtual-router/dhcp/dnsmasq.leases")


def parse_key_values(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


def parse_leases(text: str, now: int) -> tuple[Client, ...]:
    clients: list[Client] = []
    for line in text.splitlines():
        fields = line.split()
        if len(fields) != 5:
            continue
        expiry, mac, address, hostname, _client_id = fields
        try:
            expiry_value = int(expiry)
            ipaddress.IPv4Address(address)
        except ValueError:
            continue
        if not mac or hostname == "*":
            hostname = ""
        clients.append(Client(hostname, address, mac.lower(), expiry_value, expiry_value != 0 and expiry_value <= now, None))
    return tuple(sorted(clients, key=lambda item: (item.ipv4, item.mac)))


def parse_neighbors(text: str) -> dict[str, str]:
    try:
        rows = json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return {}
    neighbors: dict[str, str] = {}
    for row in rows if isinstance(rows, list) else ():
        if not isinstance(row, dict) or "dst" not in row:
            continue
        raw_state = row.get("state", "UNKNOWN")
        state = ",".join(str(item) for item in raw_state) if isinstance(raw_state, list) else str(raw_state)
        neighbors[str(row["dst"])] = state
    return neighbors


def parse_ipv4_addresses(text: str) -> tuple[str, ...]:
    try:
        rows = json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return ()
    addresses: list[str] = []
    for row in rows if isinstance(rows, list) else ():
        for address in row.get("addr_info", ()) if isinstance(row, dict) else ():
            if address.get("family") == "inet" and isinstance(address.get("local"), str) and isinstance(address.get("prefixlen"), int):
                addresses.append(f'{address["local"]}/{address["prefixlen"]}')
    return tuple(sorted(set(addresses)))


def neighbor_check(target: str, state: str | None) -> Check:
    if target == "none":
        return Check(HealthState.NOT_CONFIGURED)
    normalized = state.upper() if state else None
    states = set(normalized.split(",")) if normalized else set()
    if states & {"FAILED", "INCOMPLETE"}:
        return Check(HealthState.DEGRADED, f"nud={normalized}")
    if states and states <= {"REACHABLE", "STALE", "DELAY", "PROBE"}:
        return Check(HealthState.HEALTHY, f"nud={normalized}")
    if normalized is None:
        return Check(HealthState.DEGRADED, "neighbor entry missing after probe")
    return Check(HealthState.UNKNOWN, f"nud={normalized}")


def address_check(expected: str | None, observed: tuple[str, ...]) -> Check:
    if expected is None:
        return Check(HealthState.UNKNOWN, "expected address unavailable")
    if expected in observed:
        return Check(HealthState.HEALTHY, f"expected={expected}")
    return Check(HealthState.FAILED, f"expected address is not installed: {expected}")


def aggregate(core_checks: list[HealthState], ancillary_checks: list[HealthState] | None = None) -> HealthState:
    core = [state for state in core_checks if state not in {HealthState.DISABLED, HealthState.NOT_CONFIGURED}]
    ancillary = [state for state in (ancillary_checks or []) if state not in {HealthState.DISABLED, HealthState.NOT_CONFIGURED}]
    if any(state == HealthState.FAILED for state in core):
        return HealthState.FAILED
    if any(state in {HealthState.DEGRADED, HealthState.UNKNOWN} for state in core) or any(
        state in {HealthState.FAILED, HealthState.DEGRADED, HealthState.UNKNOWN} for state in ancillary
    ):
        return HealthState.DEGRADED
    return HealthState.HEALTHY if core or ancillary else HealthState.UNKNOWN


class Collector:
    def __init__(
        self,
        config: Mapping[str, str],
        *,
        run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
        read_text: Callable[[Path], str] | None = None,
        now: Callable[[], datetime] | None = None,
        stage_command: Path | None = None,
        runtime_state: Path = RUNTIME_STATE,
        wan_dhcp_state: Path = WAN_DHCP_STATE,
        lease_file: Path = LEASE_FILE,
    ) -> None:
        self.config = config
        self.run = run
        self.read_text = read_text or (lambda path: path.read_text(encoding="utf-8"))
        self.now = now or (lambda: datetime.now(UTC))
        self.stage_command = stage_command or Path(__file__).resolve().parents[1] / "scripts/runtime-stage-status.sh"
        self.runtime_state = runtime_state
        self.wan_dhcp_state = wan_dhcp_state
        self.lease_file = lease_file

    def command(self, arguments: list[str]) -> subprocess.CompletedProcess[str]:
        try:
            return self.run(arguments, capture_output=True, text=True, timeout=3, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            return subprocess.CompletedProcess(arguments, 127, "", str(error))

    def stages(self) -> dict[str, int]:
        result = self.command([str(self.stage_command)])
        if result.returncode != 0:
            return {}
        states: dict[str, int] = {}
        for line in result.stdout.splitlines():
            name, separator, raw = line.partition("\t")
            if separator and raw in {"0", "1", "2"}:
                states[name] = int(raw)
        return states

    def link(self, name: str) -> dict[str, object]:
        result = self.command(["ip", "-j", "link", "show", "dev", name])
        if result.returncode != 0:
            return {"interface": name, "exists": False, "administrative_state": "unknown", "link_state": "unknown", "carrier": None, "health": Check(HealthState.FAILED, "interface absent")}
        try:
            row = json.loads(result.stdout)[0]
        except (json.JSONDecodeError, IndexError, TypeError):
            return {"interface": name, "exists": True, "administrative_state": "unknown", "link_state": "unknown", "carrier": None, "health": Check(HealthState.UNKNOWN, "link data unavailable")}
        flags = row.get("flags", [])
        carrier: bool | None
        try:
            carrier = self.read_text(Path(f"/sys/class/net/{name}/carrier")).strip() == "1"
        except OSError:
            carrier = None
        health = HealthState.HEALTHY if "UP" in flags and carrier is not False else HealthState.DEGRADED
        return {
            "interface": name,
            "exists": True,
            "administrative_state": "up" if "UP" in flags else "down",
            "link_state": str(row.get("operstate", "unknown")).lower(),
            "carrier": carrier,
            "health": Check(health),
        }

    def probe(self, target: str, interface: str) -> Check:
        if target == "none":
            return Check(HealthState.NOT_CONFIGURED)
        result = self.command(["ping", "-n", "-c", "1", "-W", "1", "-I", interface, target])
        return Check(HealthState.HEALTHY if result.returncode == 0 else HealthState.DEGRADED, f"target={target}")

    def addresses(self, interface: str) -> tuple[str, ...]:
        result = self.command(["ip", "-j", "-4", "addr", "show", "dev", interface])
        return parse_ipv4_addresses(result.stdout) if result.returncode == 0 else ()

    def collect(self) -> Snapshot:
        timestamp = self.now()
        try:
            recorded = read_runtime_state(self.runtime_state)
            runtime: dict[str, object] = {
                "deployment_mode": recorded.deployment_mode,
                "profile": recorded.profile,
                "recorded_status": recorded.status,
                "started_at": recorded.started_at,
                "owned_stages": list(recorded.owned_stages),
            }
            owned = set(recorded.owned_stages)
        except StateError:
            runtime = {"deployment_mode": self.config["DEPLOYMENT_MODE"], "profile": self.config["TELEMETRY_MODE"], "recorded_status": "absent", "started_at": None, "owned_stages": []}
            owned = set()

        stage_states = self.stages()
        runtime["stage_integrity"] = {name: {0: "healthy", 1: "absent", 2: "inconsistent"}[code] for name, code in sorted(stage_states.items())}
        services: dict[str, Check] = {}
        configured = {"nat": True, "firewall": True, "dhcp": True, "dns": True, "ipfix": self.config["IPFIX_ENABLED"] == "1", "metrics-export": self.config["METRICS_EXPORT_ENABLED"] == "1"}
        for name, enabled in configured.items():
            if not enabled:
                services[name] = Check(HealthState.DISABLED)
            elif name not in stage_states:
                services[name] = Check(HealthState.UNKNOWN, "authoritative stage check unavailable")
            elif stage_states[name] == 0:
                services[name] = Check(HealthState.HEALTHY)
            elif stage_states[name] == 1 and name not in owned:
                services[name] = Check(HealthState.UNKNOWN, "stage is absent and not recorded as owned")
            else:
                services[name] = Check(HealthState.FAILED, "runtime integrity check failed")

        core_stage_states: list[HealthState] = []
        for name in ("topology", "routing", "nat", "firewall", "dhcp", "dns"):
            if name not in stage_states:
                core_stage_states.append(HealthState.UNKNOWN)
            elif stage_states[name] == 0:
                core_stage_states.append(HealthState.HEALTHY)
            elif stage_states[name] == 1 and name not in owned:
                core_stage_states.append(HealthState.UNKNOWN)
            else:
                core_stage_states.append(HealthState.FAILED)
        ancillary_service_states = [services[name].state for name in ("ipfix", "metrics-export")]

        if self.config["DEPLOYMENT_MODE"] != "physical":
            unavailable = {"state": HealthState.NOT_CONFIGURED, "detail": "physical deployment only"}
            return Snapshot(timestamp.isoformat().replace("+00:00", "Z"), aggregate(core_stage_states, ancillary_service_states), runtime, unavailable, unavailable, services, ())

        wan_mode = self.config.get("PHYSICAL_WAN_MODE", "static")
        if wan_mode == "dhcp":
            try:
                effective = parse_key_values(self.read_text(self.wan_dhcp_state))
            except OSError:
                effective = {}
            address = effective.get("WAN_ADDRESS")
            prefix = effective.get("WAN_PREFIX_LENGTH")
            gateway = effective.get("WAN_GATEWAY")
        else:
            address = self.config.get("PHYSICAL_WAN_ADDRESS")
            prefix = self.config.get("PHYSICAL_WAN_PREFIX_LENGTH")
            gateway = self.config.get("PHYSICAL_WAN_GATEWAY")
        wan = self.link(self.config["PHYSICAL_WAN_INTERFACE"])
        expected_wan = f"{address}/{prefix}" if address and prefix else None
        observed_wan = self.addresses(self.config["PHYSICAL_WAN_INTERFACE"])
        wan.update({"mode": wan_mode, "effective_ipv4": expected_wan, "observed_ipv4": observed_wan, "ipv4_health": address_check(expected_wan, observed_wan), "effective_gateway": gateway})
        wan["gateway_reachability"] = self.probe(gateway, self.config["PHYSICAL_WAN_INTERFACE"]) if gateway else Check(HealthState.UNKNOWN, "effective gateway unavailable")
        wan["internet_reachability"] = self.probe(self.config.get("INTERNET_HEALTH_TARGET", "none"), self.config["PHYSICAL_WAN_INTERFACE"])

        lan = self.link(self.config["PHYSICAL_LAN_INTERFACE"])
        expected_lan = f'{self.config["ROUTER_LAN"]}/{self.config["LAN_SUBNET"].split("/")[1]}'
        observed_lan = self.addresses(self.config["PHYSICAL_LAN_INTERFACE"])
        lan.update({"expected_ipv4": expected_lan, "observed_ipv4": observed_lan, "ipv4_health": address_check(expected_lan, observed_lan)})
        lan_target = self.config.get("LAN_HEALTH_TARGET", "none")
        lan["target"] = lan_target
        lan["icmp"] = self.probe(lan_target, self.config["PHYSICAL_LAN_INTERFACE"])
        neighbors_result = self.command(["ip", "-j", "neigh", "show", "dev", self.config["PHYSICAL_LAN_INTERFACE"]])
        neighbors = parse_neighbors(neighbors_result.stdout) if neighbors_result.returncode == 0 else {}
        lan["target_neighbor_state"] = neighbors.get(lan_target) if lan_target != "none" else None
        lan["neighbor_reachability"] = neighbor_check(lan_target, lan["target_neighbor_state"])

        try:
            clients = parse_leases(self.read_text(self.lease_file), int(timestamp.timestamp()))
        except OSError:
            clients = ()
        clients = tuple(Client(item.hostname, item.ipv4, item.mac, item.lease_expiry, item.lease_expired, neighbors.get(item.ipv4)) for item in clients)
        core_operational = core_stage_states + [wan["health"].state, wan["ipv4_health"].state, lan["health"].state, lan["ipv4_health"].state]
        ancillary_operational = ancillary_service_states + [wan["gateway_reachability"].state, wan["internet_reachability"].state, lan["icmp"].state, lan["neighbor_reachability"].state]
        return Snapshot(timestamp.isoformat().replace("+00:00", "Z"), aggregate(core_operational, ancillary_operational), runtime, wan, lan, services, clients)
