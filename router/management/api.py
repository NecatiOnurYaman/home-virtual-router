"""Small read-only HTTP representation over the accepted R17.1 collector."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import subprocess
from typing import Any, Protocol


API_VERSION = "v1"
DEFAULT_HELPER = Path("/usr/libexec/home-virtual-router-management-read")


class DocumentProvider(Protocol):
    def collect(self) -> dict[str, Any]: ...


class CollectionError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class FixedHelperProvider:
    helper: Path = DEFAULT_HELPER
    timeout_seconds: float = 10.0

    def collect(self) -> dict[str, Any]:
        try:
            result = subprocess.run(
                ["sudo", "-n", str(self.helper)], capture_output=True, text=True,
                timeout=self.timeout_seconds, check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise CollectionError("management collection unavailable") from error
        if result.returncode != 0:
            raise CollectionError("management collection unavailable")
        try:
            document = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise CollectionError("management collection unavailable") from error
        if not isinstance(document, dict) or not isinstance(document.get("snapshot"), dict) or not isinstance(document.get("config"), dict):
            raise CollectionError("management collection unavailable")
        return document


class ManagementAPI:
    def __init__(self, provider: DocumentProvider) -> None:
        self.provider = provider

    def dispatch(self, method: str, path: str) -> tuple[int, dict[str, Any]]:
        if method != "GET":
            return 405, {"detail": "method not allowed"}
        if path == "/api/v1/health":
            return 200, {"status": "ok", "api_version": API_VERSION}
        if path not in {"/api/v1/status", "/api/v1/clients", "/api/v1/config"}:
            return 404, {"detail": "not found"}
        try:
            document = self.provider.collect()
        except Exception:
            return 503, {"detail": "management data unavailable"}
        snapshot = document.get("snapshot")
        config = document.get("config")
        if not isinstance(snapshot, dict) or not isinstance(config, dict):
            return 503, {"detail": "management data unavailable"}
        if path == "/api/v1/status":
            return 200, snapshot
        if path == "/api/v1/clients":
            clients = snapshot.get("clients")
            if not isinstance(clients, list):
                return 503, {"detail": "management data unavailable"}
            return 200, {"api_version": API_VERSION, "clients": clients}
        return 200, {"api_version": API_VERSION, "config": config}
