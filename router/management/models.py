"""Stable models for the R17.1 operational-health document."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from enum import StrEnum
from typing import Any


class HealthState(StrEnum):
    HEALTHY = "healthy"
    DEGRADED = "degraded"
    FAILED = "failed"
    UNKNOWN = "unknown"
    DISABLED = "disabled"
    NOT_CONFIGURED = "not_configured"


@dataclass(frozen=True, slots=True)
class Check:
    state: HealthState
    detail: str | None = None


@dataclass(frozen=True, slots=True)
class Client:
    hostname: str
    ipv4: str
    mac: str
    lease_expiry: int
    lease_expired: bool
    neighbor_state: str | None


@dataclass(frozen=True, slots=True)
class Snapshot:
    generated_at: str
    overall: HealthState
    runtime: dict[str, Any]
    wan: dict[str, Any]
    lan: dict[str, Any]
    services: dict[str, Check]
    clients: tuple[Client, ...]
    schema_version: int = 1

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)
