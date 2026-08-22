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

spec = importlib.util.spec_from_file_location("validate_config", VALIDATOR)
validate_config = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(validate_config)


class ConfigTests(unittest.TestCase):
    def test_defaults_are_valid(self) -> None:
        values = validate_config.parse(ROOT / "lab/config/defaults.env")
        validate_config.validate(values)

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


if __name__ == "__main__":
    unittest.main()
