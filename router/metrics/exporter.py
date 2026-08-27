"""Small HTTP push transport for R10 router metric snapshots."""

from __future__ import annotations

import http.client
import json
import re
import threading
import time
from collections.abc import Callable

from router.metrics.collector import InterfaceIdentity, MetricSnapshot, collect_snapshot


class MetricsExportError(RuntimeError):
    """A snapshot could not be accepted by the configured receiver."""


def build_envelope(router_id: str, snapshot: MetricSnapshot) -> dict[str, object]:
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,62}", router_id):
        raise ValueError("router_id must be a lowercase DNS-label-like identifier")
    return {"protocol_version": 1, "router_id": router_id, "snapshot": snapshot.as_dict()}


def serialize_envelope(router_id: str, snapshot: MetricSnapshot) -> bytes:
    return json.dumps(build_envelope(router_id, snapshot), sort_keys=True, separators=(",", ":")).encode("utf-8")


def post_envelope(host: str, port: int, path: str, payload: bytes, timeout: float) -> None:
    connection = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        connection.request("POST", path, body=payload, headers={"Content-Type": "application/json", "Content-Length": str(len(payload))})
        response = connection.getresponse()
        response.read(65536)
        if not 200 <= response.status < 300:
            raise MetricsExportError(f"receiver returned HTTP {response.status}")
    except (OSError, http.client.HTTPException) as error:
        raise MetricsExportError(str(error)) from error
    finally:
        connection.close()


def run_export_loop(
    *, router_id: str, interfaces: tuple[InterfaceIdentity, ...], host: str, port: int,
    path: str, interval: float, timeout: float, stop: threading.Event,
    log: Callable[[str], None], monotonic: Callable[[], float] = time.monotonic,
) -> None:
    deadline = monotonic()
    while not stop.is_set():
        try:
            snapshot = collect_snapshot(interfaces)
            post_envelope(host, port, path, serialize_envelope(router_id, snapshot), timeout)
        except Exception as error:  # one failed sample must not terminate the periodic exporter
            log(f"metrics export failed: {error}")
        deadline += interval
        now = monotonic()
        while deadline <= now:
            deadline += interval
        stop.wait(deadline - now)
