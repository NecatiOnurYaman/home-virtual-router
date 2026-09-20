from __future__ import annotations

import json
import importlib.util
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from router.management.api import CollectionError, FixedHelperProvider, ManagementAPI
from router.management.config import ManagementConfig
from router.management.service import sanitized_config


ROOT = Path(__file__).resolve().parents[1]
SUPPORT_PATH = ROOT / "router/scripts/management_support.py"
support_spec = importlib.util.spec_from_file_location("hvr_management_support", SUPPORT_PATH)
support = importlib.util.module_from_spec(support_spec)
assert support_spec.loader
support_spec.loader.exec_module(support)


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
        helper = support.HELPER
        reader = (ROOT / "router/scripts/management_read.py").read_text(encoding="utf-8")
        launcher = (ROOT / "router/scripts/management_api.py").read_text(encoding="utf-8")
        self.assertIn('[ "$#" -eq 0 ]', helper)
        self.assertIn('[ "$(/usr/bin/id -u)" -eq 0 ]', helper)
        self.assertIn("len(sys.argv) != 1", reader)
        self.assertIn("os.geteuid() != 0", reader)
        self.assertIn('LOOPBACK_HOST = "127.0.0.1"', launcher)
        self.assertNotIn("0.0.0.0", launcher)
        self.assertNotIn("--helper", launcher)
        self.assertNotIn("sudo", launcher)


class ManagementSupportInstallTests(unittest.TestCase):
    def test_installed_layout_is_fixed_complete_and_checkout_independent(self) -> None:
        expected = support.artifacts(ROOT)
        required = {
            support.HELPER_PATH,
            support.SUDOERS_PATH,
            support.INSTALL_ROOT / "router/scripts/management_read.py",
            support.INSTALL_ROOT / "router/scripts/runtime-stage-status.sh",
            support.INSTALL_ROOT / "router/management/collector.py",
            support.INSTALL_ROOT / "router/runtime/state.py",
            support.INSTALL_ROOT / "lab/scripts/runtime-common.sh",
            support.INSTALL_ROOT / "lab/scripts/topology-common.sh",
            support.INSTALL_ROOT / "physical/scripts/physical-common.sh",
        }
        self.assertTrue(required <= set(expected))
        helper = expected[support.HELPER_PATH][0].decode()
        self.assertIn("cd /", helper)
        self.assertIn("/usr/bin/env -i", helper)
        self.assertIn("/usr/bin/python3 -I", helper)
        self.assertIn("/usr/lib/home-virtual-router/router/scripts/management_read.py", helper)
        self.assertNotIn(str(ROOT), helper)
        self.assertNotIn("$HOME", helper)
        self.assertNotIn("PYTHONPATH", helper)
        self.assertNotIn("PYTHONHOME", helper)

    def test_sudoers_is_exact_zero_argument_policy(self) -> None:
        policy = support.SUDOERS
        self.assertIn(
            'hvr-web ALL=(root) NOPASSWD: /usr/libexec/home-virtual-router-management-read ""',
            policy,
        )
        self.assertIn("Defaults:hvr-web env_reset", policy)
        self.assertIn("Defaults:hvr-web secure_path=", policy)
        self.assertNotIn("SETENV", policy)
        self.assertNotIn("*", policy)
        self.assertNotIn("/usr/bin/python", policy)

    def test_temp_root_install_verify_reinstall_and_uninstall(self) -> None:
        expected = support.artifacts(ROOT)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            support.install(root, expected)
            support.verify(root, expected)
            support.install(root, expected)
            support.verify(root, expected)
            self.assertEqual(stat.S_IMODE((root / support.HELPER_PATH).stat().st_mode), 0o755)
            self.assertEqual(stat.S_IMODE((root / support.SUDOERS_PATH).stat().st_mode), 0o440)
            self.assertEqual(
                stat.S_IMODE((root / support.INSTALL_ROOT / "router/management/collector.py").stat().st_mode),
                0o644,
            )
            self.assertEqual(stat.S_IMODE((root / support.INSTALL_ROOT).stat().st_mode), 0o755)
            support.uninstall(root, expected)
            support.uninstall(root, expected)
            self.assertFalse((root / support.INSTALL_ROOT).exists())
            self.assertFalse((root / support.HELPER_PATH).exists())
            self.assertFalse((root / support.SUDOERS_PATH).exists())

    def test_control_creates_only_dedicated_non_login_identity(self) -> None:
        control = (ROOT / "router/scripts/management-support-control.sh").read_text(encoding="utf-8")
        self.assertIn(
            "/usr/sbin/useradd --system --no-create-home --home-dir /nonexistent "
            "--shell /usr/sbin/nologin hvr-web",
            control,
        )
        self.assertIn("/usr/sbin/visudo -cf", control)
        self.assertNotIn("usermod", control)
        self.assertNotIn("systemctl", control)
        self.assertNotIn("userdel", control)
