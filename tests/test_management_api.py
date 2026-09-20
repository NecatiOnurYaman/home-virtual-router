from __future__ import annotations

import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

from router.management.api import CollectionError, FixedHelperProvider, ManagementAPI
from router.management.config import ManagementConfig
from router.management.service import sanitized_config


ROOT = Path(__file__).resolve().parents[1]


def snapshot(overall: str = "healthy") -> dict[str, object]:
    return {
        "schema_version": 1, "generated_at": "2026-09-20T00:00:00Z", "overall": overall,
        "runtime": {"recorded_status": "running"}, "wan": {}, "lan": {}, "services": {},
        "clients": [{
            "hostname": "client", "ipv4": "10.0.0.100", "mac": "02:00:00:00:00:01",
            "lease_expiry": 2000000000, "lease_expired": False, "neighbor_state": "STALE",
        }],
    }


class FakeProvider:
    def __init__(self, *, overall: str = "healthy", error: Exception | None = None) -> None:
        self.calls = 0
        self.error = error
        self.document = {"snapshot": snapshot(overall), "config": {"deployment_mode": "physical"}}

    def collect(self) -> dict[str, object]:
        self.calls += 1
        if self.error:
            raise self.error
        return self.document


class ManagementAPITests(unittest.TestCase):
    def test_health_is_cheap_and_does_not_collect(self) -> None:
        provider = FakeProvider(error=AssertionError("must not collect"))
        status, body = ManagementAPI(provider).dispatch("GET", "/api/v1/health")
        self.assertEqual(status, 200)
        self.assertEqual(body, {"status": "ok", "api_version": "v1"})
        self.assertEqual(provider.calls, 0)

    def test_status_returns_healthy_and_degraded_snapshots(self) -> None:
        for overall in ("healthy", "degraded"):
            with self.subTest(overall=overall):
                provider = FakeProvider(overall=overall)
                status, body = ManagementAPI(provider).dispatch("GET", "/api/v1/status")
                self.assertEqual(status, 200)
                self.assertEqual(body["overall"], overall)
                self.assertEqual(provider.calls, 1)

    def test_status_and_clients_fail_without_leaking_details(self) -> None:
        for path in ("/api/v1/status", "/api/v1/clients"):
            with self.subTest(path=path):
                secret = "token=do-not-leak"
                status, body = ManagementAPI(FakeProvider(error=RuntimeError(secret))).dispatch("GET", path)
                self.assertEqual(status, 503)
                self.assertEqual(body, {"detail": "management data unavailable"})
                self.assertNotIn(secret, json.dumps(body))
                self.assertNotIn("Traceback", json.dumps(body))

    def test_clients_preserve_neighbor_state_without_online_boolean(self) -> None:
        status, body = ManagementAPI(FakeProvider()).dispatch("GET", "/api/v1/clients")
        self.assertEqual(status, 200)
        self.assertEqual(body["api_version"], "v1")
        self.assertEqual(body["clients"][0]["neighbor_state"], "STALE")
        self.assertNotIn("online", body["clients"][0])

    def test_config_is_an_explicit_allowlist(self) -> None:
        router = {
            "DEPLOYMENT_MODE": "physical", "PHYSICAL_WAN_MODE": "dhcp",
            "PHYSICAL_WAN_INTERFACE": "wan0", "PHYSICAL_LAN_INTERFACE": "lan0",
            "LAN_SUBNET": "10.0.0.0/24", "ROUTER_LAN": "10.0.0.1",
            "IPFIX_ENABLED": "1", "METRICS_EXPORT_ENABLED": "0",
            "PASSWORD": "secret", "TOKEN": "secret", "ARBITRARY": "secret",
        }
        config = sanitized_config(router, ManagementConfig("10.0.0.2", "none"))
        self.assertEqual(set(config), {
            "deployment_mode", "wan_mode", "wan_interface", "lan_interface", "lan_subnet",
            "router_lan", "ipfix_enabled", "metrics_export_enabled", "lan_health_target",
            "internet_health_target",
        })
        self.assertNotIn("secret", json.dumps(config))
        provider = FakeProvider()
        provider.document["config"] = config
        status, body = ManagementAPI(provider).dispatch("GET", "/api/v1/config")
        self.assertEqual(status, 200)
        self.assertEqual(body["config"], config)

    def test_mutating_methods_and_unknown_routes_do_not_collect(self) -> None:
        provider = FakeProvider()
        api = ManagementAPI(provider)
        for method in ("POST", "PUT", "PATCH", "DELETE"):
            status, _body = api.dispatch(method, "/api/v1/status")
            self.assertEqual(status, 405)
        status, _body = api.dispatch("GET", "/api/v1/restart")
        self.assertEqual(status, 404)
        self.assertEqual(provider.calls, 0)


class PrivilegeBoundaryTests(unittest.TestCase):
    def test_provider_invokes_only_fixed_bounded_helper_without_shell(self) -> None:
        document = {"snapshot": snapshot(), "config": {"deployment_mode": "physical"}}
        result = subprocess.CompletedProcess([], 0, json.dumps(document), "")
        with patch("router.management.api.subprocess.run", return_value=result) as run:
            provider = FixedHelperProvider(Path("/fixed/helper"), timeout_seconds=7)
            self.assertEqual(provider.collect(), document)
        run.assert_called_once_with(
            ["sudo", "-n", "/fixed/helper"], capture_output=True, text=True, timeout=7, check=False,
        )

    def test_provider_failure_is_sanitized(self) -> None:
        result = subprocess.CompletedProcess([], 1, "", "sensitive helper diagnostic")
        with patch("router.management.api.subprocess.run", return_value=result):
            with self.assertRaisesRegex(CollectionError, "management collection unavailable") as raised:
                FixedHelperProvider().collect()
        self.assertNotIn("sensitive", str(raised.exception))

    def test_helper_and_launcher_preserve_privilege_and_loopback_boundaries(self) -> None:
        helper = (ROOT / "router/scripts/management-read-helper.sh").read_text(encoding="utf-8")
        reader = (ROOT / "router/scripts/management_read.py").read_text(encoding="utf-8")
        launcher = (ROOT / "router/scripts/management_api.py").read_text(encoding="utf-8")
        self.assertIn('[ "$#" -eq 0 ]', helper)
        self.assertIn('[ "$(id -u)" -eq 0 ]', helper)
        self.assertIn("len(sys.argv) != 1", reader)
        self.assertIn("os.geteuid() != 0", reader)
        self.assertIn('LOOPBACK_HOST = "127.0.0.1"', launcher)
        self.assertNotIn("0.0.0.0", launcher)
        self.assertNotIn("--helper", launcher)
        self.assertNotIn("sudo", launcher)
