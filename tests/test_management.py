from __future__ import annotations

from datetime import UTC, datetime
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from router.management.collector import (
    Collector, address_check, aggregate, neighbor_check, parse_ipv4_addresses, parse_leases, parse_neighbors,
)
from router.management.config import ManagementConfig, load as load_management_config, parse as parse_management_config
from router.management.models import HealthState

ROOT = Path(__file__).resolve().parents[1]

def completed(arguments: list[str], returncode: int = 0, stdout: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(arguments, returncode, stdout, "")


class ParsingTests(unittest.TestCase):
    def test_management_config_defaults_for_missing_empty_and_omitted_keys(self) -> None:
        router = {"LAN_SUBNET": "10.0.0.0/24", "ROUTER_LAN": "10.0.0.1"}
        with tempfile.TemporaryDirectory() as directory:
            missing = load_management_config(Path(directory) / "missing.env", router)
            self.assertEqual(missing, ManagementConfig())
            empty_path = Path(directory) / "empty.env"
            empty_path.write_text("", encoding="utf-8")
            self.assertEqual(load_management_config(empty_path, router), ManagementConfig())
            partial_path = Path(directory) / "partial.env"
            partial_path.write_text("LAN_HEALTH_TARGET=10.0.0.2\n", encoding="utf-8")
            self.assertEqual(load_management_config(partial_path, router), ManagementConfig("10.0.0.2", "none"))
        self.assertEqual(load_management_config(ROOT / "config/management.example.env", router), ManagementConfig())

    def test_management_config_rejects_malformed_duplicate_and_unknown_lines(self) -> None:
        for text, message in (
            ("LAN_HEALTH_TARGET =none\n", "expected KEY=VALUE"),
            ("LAN_HEALTH_TARGET=none\nLAN_HEALTH_TARGET=none\n", "duplicate key"),
            ("MANAGEMENT_PORT=8080\n", "unknown key"),
        ):
            with self.subTest(text=text), self.assertRaisesRegex(ValueError, message):
                parse_management_config(text)

    def test_management_config_validates_targets_against_router_domain(self) -> None:
        router = {"LAN_SUBNET": "10.0.0.0/24", "ROUTER_LAN": "10.0.0.1"}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "management.env"
            for text, message in (
                ("LAN_HEALTH_TARGET=hostname\n", "must be none or an IPv4 address"),
                ("INTERNET_HEALTH_TARGET=hostname\n", "must be none or an IPv4 address"),
                ("LAN_HEALTH_TARGET=192.0.2.10\n", "within LAN_SUBNET"),
                ("LAN_HEALTH_TARGET=10.0.0.1\n", "must not equal ROUTER_LAN"),
            ):
                with self.subTest(text=text):
                    path.write_text(text, encoding="utf-8")
                    with self.assertRaisesRegex(ValueError, message):
                        load_management_config(path, router)
            path.write_text("LAN_HEALTH_TARGET=10.0.0.2\nINTERNET_HEALTH_TARGET=1.1.1.1\n", encoding="utf-8")
            self.assertEqual(load_management_config(path, router), ManagementConfig("10.0.0.2", "1.1.1.1"))

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
        self.assertEqual(parse_neighbors('[{"dst":"10.0.0.3","state":["PROBE"]}]'), {"10.0.0.3": "PROBE"})
        self.assertEqual(parse_neighbors("not-json"), {})

    def test_neighbor_health_is_conservative_and_structured(self) -> None:
        for state in ("REACHABLE", "STALE", "DELAY", "PROBE"):
            with self.subTest(state=state):
                self.assertEqual(neighbor_check("10.0.0.2", state).state, HealthState.HEALTHY)
        for state in ("FAILED", "INCOMPLETE"):
            with self.subTest(state=state):
                self.assertEqual(neighbor_check("10.0.0.2", state).state, HealthState.DEGRADED)
        self.assertEqual(neighbor_check("10.0.0.2", None).state, HealthState.DEGRADED)
        self.assertEqual(neighbor_check("none", None).state, HealthState.NOT_CONFIGURED)

    def test_observed_ipv4_addresses_match_expected_cidr(self) -> None:
        observed = parse_ipv4_addresses('[{"addr_info":[{"family":"inet","local":"10.0.0.1","prefixlen":24},{"family":"inet6","local":"::1","prefixlen":128}]}]')
        self.assertEqual(observed, ("10.0.0.1/24",))
        self.assertEqual(address_check("10.0.0.1/24", observed).state, HealthState.HEALTHY)
        self.assertEqual(address_check("10.0.0.2/24", observed).state, HealthState.FAILED)

    def test_aggregation_distinguishes_degraded_and_failed(self) -> None:
        self.assertEqual(aggregate([HealthState.HEALTHY, HealthState.NOT_CONFIGURED]), HealthState.HEALTHY)
        self.assertEqual(aggregate([HealthState.HEALTHY, HealthState.DEGRADED]), HealthState.DEGRADED)
        self.assertEqual(aggregate([HealthState.DEGRADED, HealthState.FAILED]), HealthState.FAILED)
        self.assertEqual(aggregate([HealthState.HEALTHY], [HealthState.FAILED]), HealthState.DEGRADED)


class CollectorTests(unittest.TestCase):
    def config(self) -> dict[str, str]:
        return {
            "DEPLOYMENT_MODE": "physical", "TELEMETRY_MODE": "lab",
            "PHYSICAL_WAN_INTERFACE": "wan0", "PHYSICAL_LAN_INTERFACE": "lan0",
            "PHYSICAL_WAN_MODE": "static", "PHYSICAL_WAN_ADDRESS": "203.0.113.2",
            "PHYSICAL_WAN_PREFIX_LENGTH": "24", "PHYSICAL_WAN_GATEWAY": "203.0.113.1",
            "LAN_SUBNET": "10.0.0.0/24", "ROUTER_LAN": "10.0.0.1",
            "IPFIX_ENABLED": "1", "METRICS_EXPORT_ENABLED": "1",
        }

    def collect_document(
        self, *, stage_codes: dict[str, int] | None = None, neighbor_state: str | None = "STALE",
        missing_addresses: tuple[str, ...] = (), failed_ping_targets: tuple[str, ...] = (),
        lan_target: str = "10.0.0.2", internet_target: str = "none",
    ) -> dict[str, object]:
        stages = {name: 0 for name in ("topology", "routing", "nat", "firewall", "dhcp", "dns", "ipfix", "metrics-export")}
        stages.update(stage_codes or {})
        config = self.config()
        management = ManagementConfig(lan_target, internet_target)
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
                    return completed(arguments, stdout="".join(f"{name}\t{code}\n" for name, code in stages.items()))
                if arguments[:4] == ["ip", "-j", "link", "show"]:
                    return completed(arguments, stdout='[{"flags":["UP"],"operstate":"UP"}]')
                if arguments[:5] == ["ip", "-j", "-4", "addr", "show"]:
                    interface = arguments[-1]
                    cidr = "203.0.113.2/24" if interface == "wan0" else "10.0.0.1/24"
                    if interface in missing_addresses:
                        return completed(arguments, stdout='[{"addr_info":[]}]')
                    address, prefix = cidr.split("/")
                    return completed(arguments, stdout=json.dumps([{"addr_info": [{"family": "inet", "local": address, "prefixlen": int(prefix)}]}]))
                if arguments[:4] == ["ip", "-j", "neigh", "show"]:
                    rows = [{"dst": "10.0.0.100", "state": "STALE"}]
                    if neighbor_state is not None and lan_target != "none":
                        rows.append({"dst": lan_target, "state": neighbor_state})
                    return completed(arguments, stdout=json.dumps(rows))
                if arguments[0] == "ping":
                    return completed(arguments, returncode=int(arguments[-1] in failed_ping_targets))
                raise AssertionError(arguments)

            return Collector(
                config, management, run=run, runtime_state=runtime, lease_file=leases,
                read_text=lambda path: "1\n" if str(path).endswith("/carrier") else path.read_text(encoding="utf-8"),
                now=lambda: datetime(2026, 9, 19, 12, 0, tzinfo=UTC),
            ).collect().as_dict()

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
            commands: list[list[str]] = []

            def run(arguments: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
                commands.append(arguments)
                if arguments[0].endswith("runtime-stage-status.sh"):
                    return completed(arguments, stdout="nat\t0\nfirewall\t0\ndhcp\t0\ndns\t0\nipfix\t0\nmetrics-export\t0\n")
                if arguments[:4] == ["ip", "-j", "link", "show"]:
                    return completed(arguments, stdout='[{"flags":["UP"],"operstate":"UP"}]')
                if arguments[:5] == ["ip", "-j", "-4", "addr", "show"]:
                    interface = arguments[-1]
                    address = "203.0.113.2" if interface == "wan0" else "10.0.0.1"
                    return completed(arguments, stdout=json.dumps([{"addr_info": [{"family": "inet", "local": address, "prefixlen": 24}]}]))
                if arguments[:4] == ["ip", "-j", "neigh", "show"]:
                    return completed(arguments, stdout='[{"dst":"10.0.0.2","state":"INCOMPLETE"},{"dst":"10.0.0.100","state":"STALE"}]')
                if arguments[0] == "ping":
                    return completed(arguments, returncode=1)
                raise AssertionError(arguments)

            collector = Collector(
                self.config(), ManagementConfig("10.0.0.2", "none"), run=run, runtime_state=runtime, lease_file=leases,
                read_text=lambda path: "1\n" if str(path).endswith("/carrier") else path.read_text(encoding="utf-8"),
                now=lambda: datetime(2026, 9, 19, 12, 0, tzinfo=UTC),
            )
            document = collector.collect().as_dict()
            self.assertEqual(document["runtime"]["recorded_status"], "running")
            self.assertEqual(document["runtime"]["stage_integrity"]["firewall"], "healthy")
            self.assertEqual(document["lan"]["icmp"]["state"], "degraded")
            self.assertEqual(document["lan"]["target_neighbor_state"], "INCOMPLETE")
            self.assertEqual(document["lan"]["neighbor_reachability"]["state"], "degraded")
            self.assertEqual(document["overall"], "degraded")
            self.assertEqual(document["clients"][0]["neighbor_state"], "STALE")
            self.assertNotIn("online", document["clients"][0])
            ping_index = next(index for index, command in enumerate(commands) if command[0] == "ping" and command[-1] == "10.0.0.2")
            neighbor_index = next(index for index, command in enumerate(commands) if command[:4] == ["ip", "-j", "neigh", "show"])
            self.assertLess(ping_index, neighbor_index)
            json.dumps(document, sort_keys=True)

    def test_neighbor_evidence_affects_optional_lan_health(self) -> None:
        stale = self.collect_document(neighbor_state="STALE")
        self.assertEqual(stale["lan"]["neighbor_reachability"]["state"], "healthy")
        for state in ("FAILED", "INCOMPLETE"):
            with self.subTest(state=state):
                document = self.collect_document(neighbor_state=state)
                self.assertEqual(document["lan"]["neighbor_reachability"]["state"], "degraded")
                self.assertEqual(document["overall"], "degraded")
        missing = self.collect_document(neighbor_state=None)
        self.assertEqual(missing["lan"]["neighbor_reachability"]["state"], "degraded")
        disabled = self.collect_document(lan_target="none")
        self.assertEqual(disabled["lan"]["neighbor_reachability"]["state"], "not_configured")

    def test_collector_keeps_management_targets_outside_router_config(self) -> None:
        router = self.config()
        self.assertNotIn("LAN_HEALTH_TARGET", router)
        self.assertNotIn("INTERNET_HEALTH_TARGET", router)
        document = self.collect_document(lan_target="10.0.0.2", internet_target="1.1.1.1")
        self.assertEqual(document["lan"]["target"], "10.0.0.2")
        self.assertEqual(document["wan"]["internet_reachability"]["detail"], "target=1.1.1.1")

    def test_expected_wan_and_lan_addresses_are_verified(self) -> None:
        present = self.collect_document()
        self.assertEqual(present["wan"]["observed_ipv4"], ("203.0.113.2/24",))
        self.assertEqual(present["wan"]["ipv4_health"]["state"], "healthy")
        self.assertEqual(present["lan"]["observed_ipv4"], ("10.0.0.1/24",))
        self.assertEqual(present["lan"]["ipv4_health"]["state"], "healthy")
        missing_wan = self.collect_document(missing_addresses=("wan0",))
        self.assertEqual(missing_wan["wan"]["ipv4_health"]["state"], "failed")
        missing_lan = self.collect_document(missing_addresses=("lan0",))
        self.assertEqual(missing_lan["lan"]["ipv4_health"]["state"], "failed")

    def test_overall_severity_distinguishes_core_and_ancillary_failures(self) -> None:
        for stage in ("ipfix", "metrics-export"):
            with self.subTest(stage=stage):
                document = self.collect_document(stage_codes={stage: 2})
                self.assertEqual(document["services"][stage]["state"], "failed")
                self.assertEqual(document["overall"], "degraded")
        core = self.collect_document(stage_codes={"firewall": 2})
        self.assertEqual(core["services"]["firewall"]["state"], "failed")
        self.assertEqual(core["overall"], "failed")

    def test_optional_internet_probe_failure_degrades(self) -> None:
        document = self.collect_document(internet_target="198.51.100.1", failed_ping_targets=("198.51.100.1",))
        self.assertEqual(document["wan"]["internet_reachability"]["state"], "degraded")
        self.assertEqual(document["overall"], "degraded")

    def test_cli_emits_json_without_a_web_server(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            missing_management = Path(directory) / "missing-management.env"
            result = subprocess.run(
                ["python3", str(ROOT / "router/scripts/operational_health.py"), "--config", str(ROOT / "lab/config/defaults.env"), "--management-config", str(missing_management)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            document = json.loads(result.stdout)
            self.assertEqual(document["schema_version"], 1)
            self.assertEqual(document["runtime"]["deployment_mode"], "lab")
