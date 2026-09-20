from __future__ import annotations

import json
import subprocess
import threading
import unittest
from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import patch

from router.metrics.collector import MetricSample, MetricSnapshot, MetricType
from router.metrics.exporter import MetricsExportError, build_envelope, post_envelope, serialize_envelope
from router.scripts.metrics_test_receiver import validate_envelope


def snapshot() -> MetricSnapshot:
    return MetricSnapshot(datetime(2026, 1, 2, 3, 4, 5, tzinfo=UTC), (
        MetricSample("system.uptime_seconds", 10.0, "seconds", MetricType.GAUGE),
    ))


class FakeResponse:
    def __init__(self, status: int) -> None: self.status = status
    def read(self, _: int) -> bytes: return b""


class FakeConnection:
    status = 204
    last: "FakeConnection | None" = None
    def __init__(self, host: str, port: int, timeout: float) -> None:
        self.host, self.port, self.timeout = host, port, timeout
        self.request_args = None
        FakeConnection.last = self
    def request(self, *args, **kwargs) -> None: self.request_args = (args, kwargs)
    def getresponse(self) -> FakeResponse: return FakeResponse(self.status)
    def close(self) -> None: pass


class MetricsEnvelopeTests(unittest.TestCase):
    def test_envelope_is_versioned_and_deterministic(self) -> None:
        envelope = build_envelope("hvr-router", snapshot())
        self.assertEqual(envelope["protocol_version"], 1)
        self.assertEqual(envelope["router_id"], "hvr-router")
        self.assertEqual(json.loads(serialize_envelope("hvr-router", snapshot())), envelope)

    def test_router_id_is_validated(self) -> None:
        with self.assertRaises(ValueError): build_envelope("Bad Router", snapshot())

    @patch("router.metrics.exporter.http.client.HTTPConnection", FakeConnection)
    def test_http_post_uses_json_and_timeout(self) -> None:
        post_envelope("192.0.2.1", 9101, "/v1/router-metrics", b"{}", 2)
        connection = FakeConnection.last
        self.assertEqual((connection.host, connection.port, connection.timeout), ("192.0.2.1", 9101, 2))
        self.assertEqual(connection.request_args[0][:2], ("POST", "/v1/router-metrics"))
        self.assertEqual(connection.request_args[1]["headers"]["Content-Type"], "application/json")

    @patch("router.metrics.exporter.http.client.HTTPConnection", FakeConnection)
    def test_non_success_response_is_failure(self) -> None:
        FakeConnection.status = 503
        try:
            with self.assertRaises(MetricsExportError): post_envelope("192.0.2.1", 9101, "/x", b"{}", 2)
        finally:
            FakeConnection.status = 204


class ReceiverValidationTests(unittest.TestCase):
    def test_malformed_envelope_is_rejected(self) -> None:
        with self.assertRaises(ValueError): validate_envelope({}, "hvr-router")


class LifecycleContractTests(unittest.TestCase):
    def shell_predicate(self, body: str, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "-c", f'source "$1"; {body}', "bash", "lab/scripts/topology-common.sh", *arguments],
            capture_output=True, text=True, check=False,
        )

    def test_runtime_root_controls_exact_exporter_argument_without_weakening_identity(self) -> None:
        active = "/srv/hvr-active"
        valid = f"python3\n{active}/router/scripts/export_metrics.py\n--router-id\nhvr-router\n--host\n192.0.2.1"
        body = 'ROUTER_ID="$2"; METRICS_EXPORT_HOST="$3"; metrics_exporter_command_matches "$4" "$5"'
        self.assertEqual(self.shell_predicate(body, "hvr-router", "192.0.2.1", valid, active).returncode, 0)
        for router_id, host, command, root in (
            ("hvr-router", "192.0.2.1", valid, "/usr/lib/home-virtual-router"),
            ("wrong-router", "192.0.2.1", valid, active),
            ("hvr-router", "198.51.100.1", valid, active),
        ):
            with self.subTest(router_id=router_id, host=host, root=root):
                self.assertNotEqual(self.shell_predicate(body, router_id, host, command, root).returncode, 0)
        self.assertEqual(self.shell_predicate('metrics_python_executable_matches "$2"', "/usr/bin/python3.14").returncode, 0)
        self.assertNotEqual(self.shell_predicate('metrics_python_executable_matches "$2"', "/tmp/not-python").returncode, 0)

    def test_cleanup_uses_pid_starttime_script_and_namespace_identity(self) -> None:
        common = Path("lab/scripts/topology-common.sh").read_text(encoding="utf-8")
        function = common[common.index("metrics_python_executable_matches()") : common.index("pmacct_core_running()")]
        for marker in ("process_starttime", "expected_exporter", "process_is_in_router_namespace", "METRICS_EXPORT_HOST"):
            self.assertIn(marker, function)
        for marker in ('metrics_python_executable_matches', 'metrics_exporter_command_matches',
                       '[ "$current_starttime" = "$expected_starttime" ]',
                       'grep -F -x -- "$METRICS_EXPORT_HOST"', 'runtime_identity_root'):
            self.assertIn(marker, function)
        self.assertNotIn('source "$identity_root', function)
        self.assertNotIn('python3 "$identity_root', function)
        self.assertNotIn("pkill", function)
        self.assertNotIn("killall", function)


if __name__ == "__main__":
    unittest.main()
