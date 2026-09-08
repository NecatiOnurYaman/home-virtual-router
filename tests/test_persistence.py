from __future__ import annotations

import importlib.util
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PERSISTENCE_PATH = ROOT / "router/scripts/persistence.py"
sys.path.insert(0, str(PERSISTENCE_PATH.parent))
spec = importlib.util.spec_from_file_location("hvr_persistence", PERSISTENCE_PATH)
persistence = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(persistence)


class PersistenceRenderingTests(unittest.TestCase):
    def test_unit_wraps_canonical_runtime_without_network_online(self) -> None:
        unit = persistence.render_systemd_unit.render(ROOT)
        self.assertIn("Type=oneshot", unit)
        self.assertIn("RemainAfterExit=yes", unit)
        self.assertIn("Restart=on-failure", unit)
        self.assertIn("StartLimitBurst=3", unit)
        self.assertIn("KillMode=mixed", unit)
        self.assertIn("Before=network.target", unit)
        self.assertNotIn("network-online.target", unit)
        self.assertIn(str(ROOT / "router/scripts/service-start.sh"), unit)
        self.assertIn(str(ROOT / "router/scripts/service-stop.sh"), unit)
        self.assertIn(f"WorkingDirectory={ROOT}", unit)
        self.assertNotIn(f'WorkingDirectory="{ROOT}"', unit)
        start = (ROOT / "router/scripts/service-start.sh").read_text(encoding="utf-8")
        stop = (ROOT / "router/scripts/service-stop.sh").read_text(encoding="utf-8")
        self.assertIn('lab/scripts/runtime-start.sh"', start)
        self.assertIn('lab/scripts/runtime-check.sh"', start)
        self.assertIn('lab/scripts/runtime-stop.sh"', stop)

    def test_unit_quotes_unusual_valid_repository_path(self) -> None:
        with tempfile.TemporaryDirectory(prefix="hvr path-") as directory:
            repository = Path(directory)
            template = repository / "deploy/systemd"
            template.mkdir(parents=True)
            (template / "home-virtual-router.service.in").write_text(
                (ROOT / "deploy/systemd/home-virtual-router.service.in").read_text(encoding="utf-8"), encoding="utf-8"
            )
            rendered = persistence.render_systemd_unit.render(repository)
            resolved = repository.resolve()
            self.assertIn(f'WorkingDirectory={str(resolved).replace(" ", r"\x20")}', rendered)
            self.assertIn(f'ExecStart="{resolved}/router/scripts/service-start.sh"', rendered)

    def test_directive_specific_escaping_handles_quotes_and_backslashes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory) / 'quoted" path\\part'
            template = repository / "deploy/systemd"
            template.mkdir(parents=True)
            (template / "home-virtual-router.service.in").write_text(
                (ROOT / "deploy/systemd/home-virtual-router.service.in").read_text(encoding="utf-8"), encoding="utf-8"
            )
            rendered = persistence.render_systemd_unit.render(repository)
            resolved = repository.resolve()
            self.assertIn("WorkingDirectory=" + persistence.render_systemd_unit.systemd_path_value(str(resolved)), rendered)
            self.assertIn("ExecStart=" + persistence.render_systemd_unit.systemd_exec_argument(str(resolved / "router/scripts/service-start.sh")), rendered)
            self.assertIn("Documentation=file://", rendered)
            self.assertIn("%%22", rendered)
            self.assertIn("%%5C", rendered)

    def test_control_characters_are_rejected(self) -> None:
        for character in ("\n", "\r", "\t", chr(127)):
            with self.subTest(character=repr(character)), self.assertRaisesRegex(ValueError, "control characters"):
                persistence.render_systemd_unit.systemd_path_value(f"/tmp/hvr{character}path")

    def test_networkmanager_policy_is_exact_for_static_and_dhcp(self) -> None:
        for mode in ("static", "dhcp"):
            values = persistence.configuration(ROOT / "config/physical.example.env")
            values["PHYSICAL_WAN_MODE"] = mode
            rendered = persistence.render_nm(values)
            self.assertEqual(
                rendered,
                f"[keyfile]\nunmanaged-devices=interface-name:{values['PHYSICAL_WAN_INTERFACE']};"
                f"interface-name:{values['PHYSICAL_LAN_INTERFACE']}\n",
            )
            self.assertNotIn("*", rendered)
            self.assertNotIn("managed=false", rendered)


class PersistenceInstallTests(unittest.TestCase):
    config = ROOT / "config/physical.example.env"

    def test_install_verify_reinstall_and_uninstall_are_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected = persistence.artifacts(ROOT, self.config)
            persistence.install(root, expected)
            persistence.verify(root, expected)
            persistence.install(root, expected)
            persistence.verify(root, expected)
            for relative, (_content, mode) in expected.items():
                self.assertEqual(stat.S_IMODE((root / relative).stat().st_mode), mode)
            persistence.uninstall(root, expected)
            persistence.uninstall(root, expected)
            self.assertTrue(all(not (root / relative).exists() for relative in expected))

    def test_install_and_uninstall_reject_symlinks_and_modified_files(self) -> None:
        expected = persistence.artifacts(ROOT, self.config)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / persistence.UNIT_PATH
            target.parent.mkdir(parents=True)
            target.symlink_to(root / "elsewhere")
            with self.assertRaisesRegex(ValueError, "unsafe persistence target"):
                persistence.install(root, expected)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            persistence.install(root, expected)
            (root / persistence.NM_PATH).write_text("modified\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "modified persistence artifact"):
                persistence.uninstall(root, expected)

    def test_install_rejects_symlinked_parent(self) -> None:
        expected = persistence.artifacts(ROOT, self.config)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "etc").symlink_to(root / "elsewhere")
            with self.assertRaisesRegex(ValueError, "unsafe persistence parent"):
                persistence.install(root, expected)

    def test_invalid_or_lab_configuration_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "DEPLOYMENT_MODE=physical"):
            persistence.configuration(ROOT / "lab/config/defaults.env")
        with tempfile.TemporaryDirectory() as directory:
            invalid = Path(directory) / "router.env"
            invalid.write_text("DEPLOYMENT_MODE=physical\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                persistence.configuration(invalid)


class PersistenceControlTests(unittest.TestCase):
    def test_control_is_explicit_and_install_does_not_enable(self) -> None:
        control = (ROOT / "router/scripts/systemd-control.sh").read_text(encoding="utf-8")
        install = control[control.index("  install)"):control.index("  uninstall)")]
        self.assertIn("systemctl daemon-reload", install)
        self.assertNotIn("systemctl enable", install)
        self.assertNotIn("systemctl start", install)
        self.assertEqual(control.count('systemctl "$1" home-virtual-router.service'), 2)
        self.assertIn('physical_interface_is_deployment_eligible "$interface"', control)
        recovery = control[control.index("  disable|stop)"):control.index("  status)")]
        self.assertNotIn("persistence.py", recovery)
        self.assertNotIn("validate_deployment", recovery)
        self.assertNotIn("NetworkManager restart", control)
        self.assertNotIn("nmcli device", control)

    def test_r14_and_service_are_mutually_exclusive(self) -> None:
        service = (ROOT / "router/scripts/service-start.sh").read_text(encoding="utf-8")
        r14 = (ROOT / "physical/scripts/hardware-common.sh").read_text(encoding="utf-8")
        self.assertIn("/var/lib/home-virtual-router/r14/checkpoint.env", service)
        self.assertIn("home-virtual-router.service is active", r14)

    def test_make_help_preserves_r14_and_lists_r15(self) -> None:
        result = subprocess.run(["make", "help"], cwd=ROOT, capture_output=True, text=True, check=True)
        for target in ("systemd-install", "systemd-enable", "systemd-start", "systemd-stop", "systemd-uninstall"):
            self.assertIn(target, result.stdout)
        self.assertIn("physical-hardware-test-start", result.stdout)


if __name__ == "__main__":
    unittest.main()
