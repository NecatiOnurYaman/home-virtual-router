from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from router.runtime.state import (
    RuntimeState, StateError, desired_stages, parse, read, rollback_order, write_atomic,
)


class RuntimeStateTests(unittest.TestCase):
    def test_round_trip_is_deterministic(self) -> None:
        state = RuntimeState("lab", "running", "2026-08-28T10:00:00Z", ("topology", "routing", "nat"))
        self.assertEqual(parse(state.render()), state)
        self.assertEqual(state.render().splitlines()[0], "VERSION=1")

    def test_atomic_write_and_read(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime" / "state.env"
            state = RuntimeState("observability", "starting", "2026-08-28T10:00:00Z", ("topology",))
            write_atomic(path, state)
            self.assertEqual(read(path), state)
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)

    def test_rejects_malformed_duplicate_and_unknown_data(self) -> None:
        valid = RuntimeState("lab", "running", "now", ()).render()
        cases = (
            valid + "STATUS=running\n",
            valid.replace("VERSION=1", "VERSION=2"),
            valid.replace("PROFILE=lab", "PROFILE=production"),
            valid.replace("OWNED_STAGES=", "OWNED_STAGES=routing,topology"),
            valid + "SURPRISE=value\n",
        )
        for text in cases:
            with self.subTest(text=text), self.assertRaises(StateError):
                parse(text)

    def test_rollback_order_is_reverse_ownership_order(self) -> None:
        state = RuntimeState("lab", "failed", "now", ("topology", "routing", "nat", "firewall"))
        self.assertEqual(rollback_order(state.owned_stages), ("firewall", "nat", "routing", "topology"))

    def test_desired_stages_follow_existing_profile_and_enable_flags(self) -> None:
        self.assertEqual(desired_stages("lab", True, True)[-2:], ("ipfix", "metrics-export"))
        self.assertNotIn("observability", desired_stages("lab", True, True))
        self.assertEqual(
            desired_stages("observability", False, False)[-1], "observability"
        )


class RuntimeShellLoadingTests(unittest.TestCase):
    repository = Path(__file__).resolve().parents[1]
    entrypoints = (
        "runtime-start.sh",
        "runtime-stop.sh",
        "runtime-restart.sh",
        "runtime-status.sh",
        "runtime-check.sh",
        "test-runtime.sh",
    )

    def test_runtime_common_loads_safety_before_topology_helpers(self) -> None:
        common = (self.repository / "lab/scripts/runtime-common.sh").read_text(encoding="utf-8")
        safety = 'source "$runtime_script_dir/../../router/scripts/safety.sh"'
        topology = 'source "$runtime_script_dir/topology-common.sh"'
        self.assertIn(safety, common)
        self.assertLess(common.index(safety), common.index(topology))

    def test_entrypoints_reach_lab_guard_without_command_not_found(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fake_bin = Path(directory)
            uname = fake_bin / "uname"
            uname.write_text("#!/usr/bin/env sh\necho Darwin\n", encoding="utf-8")
            uname.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
            for name in self.entrypoints:
                script = self.repository / "lab/scripts" / name
                with self.subTest(entrypoint=name):
                    result = subprocess.run(
                        [str(script)], cwd=directory, env=environment,
                        capture_output=True, text=True, timeout=5, check=False,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotEqual(result.returncode, 127)
                    self.assertIn("must run inside the Linux lab VM", result.stderr)
                    self.assertNotIn("command not found", result.stderr)


if __name__ == "__main__":
    unittest.main()
