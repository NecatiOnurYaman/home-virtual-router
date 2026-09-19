from __future__ import annotations

from datetime import UTC, datetime
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from router.management.collector import Collector, aggregate, parse_leases, parse_neighbors
from router.management.models import HealthState

ROOT = Path(__file__).resolve().parents[1]

def completed(arguments: list[str], returncode: int = 0, stdout: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(arguments, returncode, stdout, "")


class ParsingTests(unittest.TestCase):
    def test_leases_are_deterministic_and_do_not_invent_online_state(self) -> None:
        leases = parse_leases(
            "200 02:00:00:00:00:02 10.0.0.102 beta *\n"
            "bad malformed\n"
            "50 02:00:00:00:00:01 10.0.0.101 * *\n",
            now=100,
        )
        self.assertEqual([item.ipv4 for item in leases], ["10.0.0.101", "10.0.0.102"])
        self.assertEqual(leases[0].hostname, "")
        self.assertTrue(leases[0].lease_expired)
        self.assertIsNone(leases[0].neighbor_state)
        self.assertFalse(hasattr(leases[0], "online"))

    def test_neighbor_parser_preserves_raw_nud_state(self) -> None:
        self.assertEqual(parse_neighbors('[{"dst":"10.0.0.2","state":"STALE"}]'), {"10.0.0.2": "STALE"})
        self.assertEqual(parse_neighbors("not-json"), {})

    def test_aggregation_distinguishes_degraded_and_failed(self) -> None:
        self.assertEqual(aggregate([HealthState.HEALTHY, HealthState.NOT_CONFIGURED]), HealthState.HEALTHY)
        self.assertEqual(aggregate([HealthState.HEALTHY, HealthState.DEGRADED]), HealthState.DEGRADED)
        self.assertEqual(aggregate([HealthState.DEGRADED, HealthState.FAILED]), HealthState.FAILED)


class CollectorTests(unittest.TestCase):
    def config(self) -> dict[str, str]:
        return {
            "DEPLOYMENT_MODE": "physical", "TELEMETRY_MODE": "lab",
            "PHYSICAL_WAN_INTERFACE": "wan0", "PHYSICAL_LAN_INTERFACE": "lan0",
            "PHYSICAL_WAN_MODE": "static", "PHYSICAL_WAN_ADDRESS": "203.0.113.2",
            "PHYSICAL_WAN_PREFIX_LENGTH": "24", "PHYSICAL_WAN_GATEWAY": "203.0.113.1",
            "LAN_SUBNET": "10.0.0.0/24", "ROUTER_LAN": "10.0.0.1",
            "LAN_HEALTH_TARGET": "10.0.0.2", "INTERNET_HEALTH_TARGET": "none",
            "IPFIX_ENABLED": "1", "METRICS_EXPORT_ENABLED": "1",
        }

    def test_healthy_runtime_can_have_degraded_lan_operation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "state.env"
            runtime.write_text(
                "VERSION=2\nDEPLOYMENT_MODE=physical\nPROFILE=lab\nSTATUS=running\n"
                "STARTED_AT=2026-09-19T10:00:00Z\nOWNED_STAGES=topology,routing,nat,firewall,dhcp,dns,ipfix,metrics-export\n",
                encoding="utf-8",
            )
            leases = root / "leases"
            leases.write_text("2000000000 aa:bb:cc:dd:ee:ff 10.0.0.100 client *\n", encoding="utf-8")

            def run(arguments: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
                if arguments[0].endswith("runtime-stage-status.sh"):
                    return completed(arguments, stdout="nat\t0\nfirewall\t0\ndhcp\t0\ndns\t0\nipfix\t0\nmetrics-export\t0\n")
                if arguments[:4] == ["ip", "-j", "link", "show"]:
                    return completed(arguments, stdout='[{"flags":["UP"],"operstate":"UP"}]')
                if arguments[:4] == ["ip", "-j", "neigh", "show"]:
                    return completed(arguments, stdout='[{"dst":"10.0.0.2","state":"INCOMPLETE"},{"dst":"10.0.0.100","state":"STALE"}]')
                if arguments[0] == "ping":
                    return completed(arguments, returncode=1)
                raise AssertionError(arguments)

            collector = Collector(
                self.config(), run=run, runtime_state=runtime, lease_file=leases,
                read_text=lambda path: "1\n" if str(path).endswith("/carrier") else path.read_text(encoding="utf-8"),
                now=lambda: datetime(2026, 9, 19, 12, 0, tzinfo=UTC),
            )
            document = collector.collect().as_dict()
            self.assertEqual(document["runtime"]["recorded_status"], "running")
            self.assertEqual(document["runtime"]["stage_integrity"]["firewall"], "healthy")
            self.assertEqual(document["lan"]["icmp"]["state"], "degraded")
            self.assertEqual(document["lan"]["target_neighbor_state"], "INCOMPLETE")
            self.assertEqual(document["overall"], "degraded")
            self.assertEqual(document["clients"][0]["neighbor_state"], "STALE")
            self.assertNotIn("online", document["clients"][0])
            json.dumps(document, sort_keys=True)

    def test_cli_emits_json_without_a_web_server(self) -> None:
        result = subprocess.run(
            ["python3", str(ROOT / "router/scripts/operational_health.py"), "--config", str(ROOT / "lab/config/defaults.env")],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        document = json.loads(result.stdout)
        self.assertEqual(document["schema_version"], 1)
        self.assertEqual(document["runtime"]["deployment_mode"], "lab")
