from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
