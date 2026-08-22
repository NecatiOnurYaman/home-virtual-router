from __future__ import annotations

import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "router/scripts/validate_config.py"
CHECKER = ROOT / "router/scripts/check-dependencies.sh"
SAFETY = ROOT / "router/scripts/safety.sh"
TOPOLOGY_COMMON = ROOT / "lab/scripts/topology-common.sh"
DESTROY = ROOT / "lab/scripts/destroy-topology.sh"

spec = importlib.util.spec_from_file_location("validate_config", VALIDATOR)
validate_config = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(validate_config)


class ConfigTests(unittest.TestCase):
    def test_defaults_are_valid(self) -> None:
        values = validate_config.parse(ROOT / "lab/config/defaults.env")
        validate_config.validate(values)
        self.assertEqual(values["UPSTREAM_NAMESPACE"], "hvr-upstream")
        self.assertEqual(values["ROUTER_NAMESPACE"], "hvr-router")
        self.assertEqual(values["CLIENT_NAMESPACE"], "hvr-client")
        self.assertEqual(values["UPSTREAM_INTERFACE"], "hvr-up")
        self.assertEqual(values["ROUTER_WAN_INTERFACE"], "hvr-wan")
        self.assertEqual(values["ROUTER_LAN_INTERFACE"], "hvr-lan")
        self.assertEqual(values["CLIENT_INTERFACE"], "hvr-client")
        self.assertEqual(values["CLIENT_ADDRESS"], "10.0.0.10")

    def test_rejects_executable_config(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.env"
            path.write_text("UPSTREAM_SUBNET=$(uname)\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                validate_config.parse(path)

    def test_rejects_non_documentation_upstream(self) -> None:
        values = validate_config.parse(ROOT / "lab/config/defaults.env")
        values["UPSTREAM_SUBNET"] = "192.168.1.0/24"
        values["UPSTREAM_GATEWAY"] = "192.168.1.1"
        values["ROUTER_WAN"] = "192.168.1.2"
        with self.assertRaises(ValueError):
            validate_config.validate(values)

    def test_rejects_unsafe_or_long_interface_name(self) -> None:
        values = validate_config.parse(ROOT / "lab/config/defaults.env")
        values["CLIENT_INTERFACE"] = "eth0"
        with self.assertRaises(ValueError):
            validate_config.validate(values)
        values["CLIENT_INTERFACE"] = "hvr-interface-name-too-long"
        with self.assertRaises(ValueError):
            validate_config.validate(values)


class DependencyCheckerTests(unittest.TestCase):
    def test_known_command_succeeds(self) -> None:
        environment = os.environ | {"HVR_CHECK_COMMANDS": "sh"}
        result = subprocess.run([CHECKER], env=environment, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ok      sh", result.stdout)

    def test_missing_command_reports_without_installing(self) -> None:
        environment = os.environ | {"HVR_CHECK_COMMANDS": "hvr-command-that-does-not-exist"}
        result = subprocess.run([CHECKER], env=environment, text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing hvr-command-that-does-not-exist", result.stdout)
        self.assertIn("Install them explicitly", result.stderr)


class SafetyTests(unittest.TestCase):
    def run_function(self, command: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "-c", f"source '{SAFETY}'; {command}"],
            text=True,
            capture_output=True,
        )

    def test_accepts_prefixed_names(self) -> None:
        self.assertEqual(self.run_function("require_explicit_interface hvr-wan0").returncode, 0)
        self.assertEqual(self.run_function("require_explicit_namespace hvr-router").returncode, 0)
        self.assertEqual(self.run_function("require_explicit_nft_table hvr-router").returncode, 0)

    def test_rejects_unspecified_and_host_like_interfaces(self) -> None:
        self.assertNotEqual(self.run_function("require_explicit_interface ''").returncode, 0)
        self.assertNotEqual(self.run_function("require_explicit_interface en0").returncode, 0)
        self.assertNotEqual(self.run_function("require_explicit_interface lo").returncode, 0)
        self.assertNotEqual(self.run_function("require_explicit_nft_table filter").returncode, 0)

    def test_lab_guard_rejects_current_macos_host(self) -> None:
        if os.uname().sysname == "Linux":
            self.skipTest("macOS-specific host guard assertion")
        self.assertNotEqual(self.run_function("require_lab_environment").returncode, 0)

    def test_lab_marker_path_cannot_be_overridden(self) -> None:
        result = subprocess.run(
            ["bash", "-c", f"HVR_LAB_MARKER=/etc/passwd; source '{SAFETY}'; printf '%s' \"$HVR_LAB_MARKER\""],
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "/etc/home-virtual-router-lab")


class TopologyAllowlistTests(unittest.TestCase):
    def run_common(self, command: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "-c", f"source '{TOPOLOGY_COMMON}'; load_topology_config; {command}"],
            text=True,
            capture_output=True,
        )

    def test_teardown_allowlist_accepts_only_configured_names(self) -> None:
        for name in ("hvr-upstream", "hvr-router", "hvr-client"):
            self.assertEqual(self.run_common(f"is_known_namespace {name}").returncode, 0)
        self.assertNotEqual(self.run_common("is_known_namespace unrelated").returncode, 0)
        for name in ("hvr-up", "hvr-wan", "hvr-lan", "hvr-client"):
            self.assertEqual(self.run_common(f"is_known_interface {name}").returncode, 0)
        self.assertNotEqual(self.run_common("is_known_interface eth0").returncode, 0)

    def test_destroy_has_no_broad_namespace_cleanup(self) -> None:
        script = DESTROY.read_text(encoding="utf-8")
        self.assertNotIn("ip netns list |", script)
        self.assertNotIn("nft flush", script)
        self.assertNotIn("ip route", script)


if __name__ == "__main__":
    unittest.main()
