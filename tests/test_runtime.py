from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

from router.runtime.state import (
    RuntimeState, StateError, desired_stages, parse, read, rollback_order, write_atomic,
)


class RuntimeStateTests(unittest.TestCase):
    def test_round_trip_is_deterministic(self) -> None:
        state = RuntimeState("lab", "lab", "running", "2026-08-28T10:00:00Z", ("topology", "routing", "nat"))
        self.assertEqual(parse(state.render()), state)
        self.assertEqual(state.render().splitlines()[0], "VERSION=2")

    def test_atomic_write_and_read(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime" / "state.env"
            state = RuntimeState("physical", "lab", "starting", "2026-08-28T10:00:00Z", ("topology",))
            write_atomic(path, state)
            self.assertEqual(read(path), state)
            self.assertEqual(read(path).deployment_mode, "physical")
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)

    def test_version_one_lab_state_remains_readable(self) -> None:
        legacy = "VERSION=1\nPROFILE=lab\nSTATUS=running\nSTARTED_AT=now\nOWNED_STAGES=topology\n"
        self.assertEqual(parse(legacy).deployment_mode, "lab")

    def test_rejects_malformed_duplicate_and_unknown_data(self) -> None:
        valid = RuntimeState("lab", "lab", "running", "now", ()).render()
        cases = (
            valid + "STATUS=running\n",
            valid.replace("VERSION=2", "VERSION=3"),
            valid.replace("PROFILE=lab", "PROFILE=production"),
            valid.replace("OWNED_STAGES=", "OWNED_STAGES=routing,topology"),
            valid + "SURPRISE=value\n",
        )
        for text in cases:
            with self.subTest(text=text), self.assertRaises(StateError):
                parse(text)

    def test_rollback_order_is_reverse_ownership_order(self) -> None:
        state = RuntimeState("lab", "lab", "failed", "now", ("topology", "routing", "nat", "firewall"))
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

    def test_runtime_lock_uses_close_on_command_wrapper(self) -> None:
        common = (self.repository / "lab/scripts/runtime-common.sh").read_text(encoding="utf-8")
        runner = (self.repository / "router/scripts/run_with_runtime_lock.sh").read_text(encoding="utf-8")
        self.assertIn("RUNTIME_LOCK_RUNNER", common)
        self.assertNotIn('exec 9>"$RUNTIME_LOCK_FILE"', common)
        self.assertIn("--close", runner)
        self.assertIn("--nonblock", runner)

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


@unittest.skipUnless(sys.platform.startswith("linux") and shutil.which("flock"), "requires Linux util-linux flock")
class RuntimeLockTests(unittest.TestCase):
    repository = Path(__file__).resolve().parents[1]
    runner = repository / "router/scripts/run_with_runtime_lock.sh"

    def test_concurrent_operation_is_rejected_then_sequential_operation_succeeds(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / "runtime.lock"
            ready = Path(directory) / "ready"
            holder = subprocess.Popen(
                [str(self.runner), str(lock), sys.executable, "-c",
                 "import pathlib,sys,time; pathlib.Path(sys.argv[1]).touch(); time.sleep(1)", str(ready)],
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
            )
            try:
                for _ in range(100):
                    if ready.exists():
                        break
                    time.sleep(0.01)
                self.assertTrue(ready.exists(), "lock holder did not become ready")
                concurrent = subprocess.run(
                    [str(self.runner), str(lock), "true"], capture_output=True,
                    text=True, timeout=2, check=False,
                )
                self.assertEqual(concurrent.returncode, 75)
                self.assertIn("another HVR runtime operation holds", concurrent.stderr)
            finally:
                holder.wait(timeout=3)
                if holder.stderr is not None:
                    holder.stderr.close()
            sequential = subprocess.run(
                [str(self.runner), str(lock), "true"], timeout=2, check=False,
            )
            self.assertEqual(sequential.returncode, 0)

    def test_long_lived_child_does_not_retain_operation_lock(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / "runtime.lock"
            child_pid = Path(directory) / "child.pid"
            launch = subprocess.run(
                [str(self.runner), str(lock), sys.executable, "-c",
                 "import pathlib,subprocess,sys; p=subprocess.Popen(['sleep','2'], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True); pathlib.Path(sys.argv[1]).write_text(str(p.pid))",
                 str(child_pid)],
                capture_output=True, text=True, timeout=2, check=False,
            )
            self.assertEqual(launch.returncode, 0, launch.stderr)
            pid = int(child_pid.read_text(encoding="utf-8"))
            try:
                self.assertTrue(Path(f"/proc/{pid}").exists())
                reacquire = subprocess.run(
                    [str(self.runner), str(lock), "true"], timeout=2, check=False,
                )
                self.assertEqual(reacquire.returncode, 0)
                lock_target = str(lock.resolve())
                targets = []
                for descriptor in Path(f"/proc/{pid}/fd").iterdir():
                    try:
                        targets.append(str(descriptor.resolve()))
                    except FileNotFoundError:
                        pass
                self.assertNotIn(lock_target, targets)
            finally:
                try:
                    os.kill(pid, 15)
                except ProcessLookupError:
                    pass


if __name__ == "__main__":
    unittest.main()
