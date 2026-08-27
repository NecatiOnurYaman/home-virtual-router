"""Read minimally transformed system and interface metrics from Linux sources."""

from __future__ import annotations

import time
from dataclasses import dataclass
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path
from typing import Callable


class MetricCollectionError(ValueError):
    """Raised when an authoritative metric source is absent or invalid."""


class MetricType(StrEnum):
    COUNTER = "counter"
    GAUGE = "gauge"
    STATE = "state"


MetricValue = int | float | str


@dataclass(frozen=True, slots=True)
class InterfaceIdentity:
    role: str
    name: str

    def __post_init__(self) -> None:
        if self.role not in {"lan", "wan", "telemetry"}:
            raise MetricCollectionError(f"unsupported interface role: {self.role}")
        if not self.name or self.name == "lo" or "/" in self.name or any(character.isspace() for character in self.name):
            raise MetricCollectionError(f"invalid routed interface name: {self.name}")

    def as_dict(self) -> dict[str, str]:
        return {"role": self.role, "name": self.name}


@dataclass(frozen=True, slots=True)
class MetricSample:
    name: str
    value: MetricValue
    unit: str
    metric_type: MetricType
    interface: InterfaceIdentity | None = None

    def as_dict(self) -> dict[str, object]:
        result: dict[str, object] = {
            "name": self.name,
            "value": self.value,
            "unit": self.unit,
            "type": self.metric_type.value,
        }
        if self.interface is not None:
            result["interface"] = self.interface.as_dict()
        return result


@dataclass(frozen=True, slots=True)
class MetricSnapshot:
    timestamp: datetime
    metrics: tuple[MetricSample, ...]
    schema_version: int = 1

    def as_dict(self) -> dict[str, object]:
        if self.timestamp.tzinfo is None or self.timestamp.utcoffset() is None:
            raise MetricCollectionError("snapshot timestamp must be timezone-aware")
        timestamp = self.timestamp.astimezone(UTC).isoformat(timespec="microseconds").replace("+00:00", "Z")
        return {
            "schema_version": self.schema_version,
            "timestamp": timestamp,
            "router": {"metrics": [sample.as_dict() for sample in self.metrics]},
        }


@dataclass(frozen=True, slots=True)
class CPUTimes:
    total: int
    idle: int


INTERFACE_COUNTERS = (
    ("rx_bytes", "interface.rx_bytes", "bytes"),
    ("tx_bytes", "interface.tx_bytes", "bytes"),
    ("rx_packets", "interface.rx_packets", "packets"),
    ("tx_packets", "interface.tx_packets", "packets"),
    ("rx_errors", "interface.rx_errors", "errors"),
    ("tx_errors", "interface.tx_errors", "errors"),
    ("rx_dropped", "interface.rx_drops", "packets"),
    ("tx_dropped", "interface.tx_drops", "packets"),
)


def parse_uptime(text: str) -> float:
    try:
        value = float(text.split()[0])
    except (IndexError, ValueError) as error:
        raise MetricCollectionError("/proc/uptime does not contain a numeric uptime") from error
    if value < 0:
        raise MetricCollectionError("system uptime cannot be negative")
    return value


def parse_cpu_times(text: str) -> CPUTimes:
    first = text.splitlines()[0].split() if text.splitlines() else []
    if not first or first[0] != "cpu" or len(first) < 5:
        raise MetricCollectionError("/proc/stat lacks the aggregate cpu accounting row")
    try:
        values = [int(value) for value in first[1:9]]
    except ValueError as error:
        raise MetricCollectionError("aggregate CPU accounting contains a non-integer value") from error
    if any(value < 0 for value in values):
        raise MetricCollectionError("aggregate CPU accounting cannot be negative")
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return CPUTimes(total=sum(values), idle=idle)


def cpu_utilization_ratio(before: CPUTimes, after: CPUTimes) -> float:
    total_delta = after.total - before.total
    idle_delta = after.idle - before.idle
    if total_delta <= 0 or idle_delta < 0 or idle_delta > total_delta:
        raise MetricCollectionError("CPU accounting deltas are not valid")
    return (total_delta - idle_delta) / total_delta


def parse_meminfo(text: str) -> tuple[int, int, float]:
    values: dict[str, int] = {}
    for line in text.splitlines():
        key, separator, raw = line.partition(":")
        if not separator:
            continue
        fields = raw.split()
        if key not in {"MemTotal", "MemAvailable"}:
            continue
        if len(fields) != 2 or fields[1] != "kB":
            raise MetricCollectionError(f"{key} must be expressed as an integer number of kB")
        try:
            values[key] = int(fields[0]) * 1024
        except ValueError as error:
            raise MetricCollectionError(f"{key} contains a non-integer value") from error
    if "MemTotal" not in values or "MemAvailable" not in values:
        raise MetricCollectionError("/proc/meminfo requires MemTotal and MemAvailable")
    total, available = values["MemTotal"], values["MemAvailable"]
    if total <= 0 or available < 0 or available > total:
        raise MetricCollectionError("memory totals are outside their valid range")
    return total, available, 1.0 - (available / total)


def parse_counter(text: str, source: str) -> int:
    try:
        value = int(text.strip())
    except ValueError as error:
        raise MetricCollectionError(f"{source} is not an integer counter") from error
    if value < 0:
        raise MetricCollectionError(f"{source} cannot be negative")
    return value


def parse_operstate(text: str, source: str) -> str:
    value = text.strip()
    if not value or any(character.isspace() for character in value):
        raise MetricCollectionError(f"{source} is not a valid interface state")
    return value


def collect_snapshot(
    interfaces: tuple[InterfaceIdentity, ...],
    *,
    proc_root: Path = Path("/proc"),
    sys_class_net: Path = Path("/sys/class/net"),
    cpu_sample_seconds: float = 0.1,
    sleep: Callable[[float], None] = time.sleep,
    now: Callable[[], datetime] = lambda: datetime.now(UTC),
) -> MetricSnapshot:
    if not interfaces:
        raise MetricCollectionError("at least one routed interface identity is required")
    if cpu_sample_seconds <= 0:
        raise MetricCollectionError("CPU sample interval must be positive")
    if len({identity.role for identity in interfaces}) != len(interfaces):
        raise MetricCollectionError("interface roles must be unique")
    if len({identity.name for identity in interfaces}) != len(interfaces):
        raise MetricCollectionError("kernel interface names must be unique")
    timestamp = now()
    uptime = parse_uptime(_read(proc_root / "uptime"))
    cpu_before = parse_cpu_times(_read(proc_root / "stat"))
    sleep(cpu_sample_seconds)
    cpu_after = parse_cpu_times(_read(proc_root / "stat"))
    memory_total, memory_available, memory_ratio = parse_meminfo(_read(proc_root / "meminfo"))
    metrics: list[MetricSample] = [
        MetricSample("system.uptime_seconds", uptime, "seconds", MetricType.GAUGE),
        MetricSample("system.cpu.utilization_ratio", cpu_utilization_ratio(cpu_before, cpu_after), "ratio", MetricType.GAUGE),
        MetricSample("system.memory.total_bytes", memory_total, "bytes", MetricType.GAUGE),
        MetricSample("system.memory.available_bytes", memory_available, "bytes", MetricType.GAUGE),
        MetricSample("system.memory.utilization_ratio", memory_ratio, "ratio", MetricType.GAUGE),
    ]
    for identity in interfaces:
        interface_root = sys_class_net / identity.name
        if not interface_root.is_dir():
            raise MetricCollectionError(f"configured {identity.role} interface is absent: {identity.name}")
        for filename, metric_name, unit in INTERFACE_COUNTERS:
            source = interface_root / "statistics" / filename
            metrics.append(MetricSample(metric_name, parse_counter(_read(source), str(source)), unit, MetricType.COUNTER, identity))
        state_source = interface_root / "operstate"
        metrics.append(MetricSample("interface.operstate", parse_operstate(_read(state_source), str(state_source)), "state", MetricType.STATE, identity))
    return MetricSnapshot(timestamp=timestamp, metrics=tuple(metrics))


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="ascii")
    except OSError as error:
        raise MetricCollectionError(f"cannot read metric source {path}: {error}") from error
