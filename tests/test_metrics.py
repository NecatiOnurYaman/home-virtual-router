from __future__ import annotations

import json
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path

from router.metrics.collector import (
    INTERFACE_COUNTERS,
    CPUTimes,
    InterfaceIdentity,
    MetricCollectionError,
    MetricType,
    collect_snapshot,
    cpu_utilization_ratio,
    parse_counter,
    parse_cpu_times,
    parse_meminfo,
    parse_operstate,
    parse_uptime,
)


class MetricsParsingTests(unittest.TestCase):
    def test_uptime_and_cpu_parsing(self) -> None:
        self.assertEqual(parse_uptime("123.45 99.00\n"), 123.45)
        self.assertEqual(parse_cpu_times("cpu  10 2 3 80 5 1 2 4 0 0\n"), CPUTimes(total=107, idle=85))
        ratio = cpu_utilization_ratio(CPUTimes(100, 80), CPUTimes(120, 90))
        self.assertEqual(ratio, 0.5)

    def test_cpu_rejects_malformed_or_impossible_samples(self) -> None:
        for value in ("", "cpu nope 1 2 3", "cpu 1 2 -1 4"):
            with self.subTest(value=value), self.assertRaises(MetricCollectionError):
                parse_cpu_times(value)
        with self.assertRaises(MetricCollectionError):
            cpu_utilization_ratio(CPUTimes(100, 80), CPUTimes(100, 80))
        with self.assertRaises(MetricCollectionError):
            cpu_utilization_ratio(CPUTimes(100, 80), CPUTimes(110, 95))

    def test_meminfo_uses_memavailable_and_bytes(self) -> None:
        total, available, ratio = parse_meminfo("MemTotal: 1000 kB\nMemFree: 1 kB\nMemAvailable: 250 kB\n")
        self.assertEqual((total, available), (1_024_000, 256_000))
        self.assertEqual(ratio, 0.75)

    def test_meminfo_rejects_missing_or_impossible_values(self) -> None:
        for value in (
            "MemTotal: 1000 kB\n",
            "MemTotal: 0 kB\nMemAvailable: 0 kB\n",
            "MemTotal: 10 kB\nMemAvailable: 11 kB\n",
            "MemTotal: nope kB\nMemAvailable: 1 kB\n",
        ):
            with self.subTest(value=value), self.assertRaises(MetricCollectionError):
                parse_meminfo(value)

    def test_counter_supports_zero_and_values_larger_than_32_bits(self) -> None:
        self.assertEqual(parse_counter("0\n", "fixture"), 0)
        self.assertEqual(parse_counter("1099511627776\n", "fixture"), 2**40)
        for value in ("-1", "not-a-number"):
            with self.subTest(value=value), self.assertRaises(MetricCollectionError):
                parse_counter(value, "fixture")

    def test_operstate_preserves_unusual_valid_state(self) -> None:
        self.assertEqual(parse_operstate("dormant\n", "fixture"), "dormant")
        with self.assertRaises(MetricCollectionError):
            parse_operstate("not valid\n", "fixture")


class MetricsSnapshotTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.proc = self.root / "proc"
        self.net = self.root / "sys" / "class" / "net"
        self.proc.mkdir(parents=True)
        self.net.mkdir(parents=True)
        (self.proc / "uptime").write_text("42.5 10.0\n", encoding="ascii")
        (self.proc / "stat").write_text("cpu 10 0 10 80 0 0 0 0\n", encoding="ascii")
        (self.proc / "meminfo").write_text("MemTotal: 1024 kB\nMemAvailable: 256 kB\n", encoding="ascii")
        self.identities = (
            InterfaceIdentity("lan", "fixture-lan"),
            InterfaceIdentity("wan", "fixture-wan"),
            InterfaceIdentity("telemetry", "fixture-observe"),
        )
        for index, identity in enumerate(self.identities):
            statistics = self.net / identity.name / "statistics"
            statistics.mkdir(parents=True)
            for counter_index, (filename, _metric, _unit) in enumerate(INTERFACE_COUNTERS):
                (statistics / filename).write_text(str((index + 1) * (counter_index + 1)), encoding="ascii")
            (self.net / identity.name / "operstate").write_text("up\n", encoding="ascii")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def collect(self):
        def advance_cpu(_seconds: float) -> None:
            (self.proc / "stat").write_text("cpu 15 0 15 90 0 0 0 0\n", encoding="ascii")

        return collect_snapshot(
            self.identities,
            proc_root=self.proc,
            sys_class_net=self.net,
            sleep=advance_cpu,
            now=lambda: datetime(2026, 8, 27, 12, 0, 0, 123456, tzinfo=UTC),
        )

    def test_snapshot_schema_types_units_and_interface_identity(self) -> None:
        payload = self.collect().as_dict()
        encoded = json.dumps(payload)
        decoded = json.loads(encoded)
        self.assertEqual(decoded["schema_version"], 1)
        self.assertEqual(decoded["timestamp"], "2026-08-27T12:00:00.123456Z")
        metrics = decoded["router"]["metrics"]
        expected_names = {
            "system.uptime_seconds", "system.cpu.utilization_ratio",
            "system.memory.total_bytes", "system.memory.available_bytes",
            "system.memory.utilization_ratio", "interface.rx_bytes",
            "interface.tx_bytes", "interface.rx_packets", "interface.tx_packets",
            "interface.rx_errors", "interface.tx_errors", "interface.rx_drops",
            "interface.tx_drops", "interface.operstate",
        }
        self.assertEqual({item["name"] for item in metrics}, expected_names)
        by_name = {item["name"]: item for item in metrics if "interface" not in item}
        self.assertEqual(by_name["system.uptime_seconds"]["type"], "gauge")
        self.assertEqual(by_name["system.uptime_seconds"]["unit"], "seconds")
        self.assertEqual(by_name["system.cpu.utilization_ratio"]["type"], "gauge")
        self.assertEqual(by_name["system.memory.total_bytes"]["unit"], "bytes")
        interface_metrics = [item for item in metrics if "interface" in item]
        self.assertEqual({item["interface"]["role"] for item in interface_metrics}, {"lan", "wan", "telemetry"})
        self.assertEqual({item["interface"]["name"] for item in interface_metrics}, {"fixture-lan", "fixture-wan", "fixture-observe"})
        self.assertNotIn("lo", {item["interface"]["name"] for item in interface_metrics})
        counters = [item for item in interface_metrics if item["type"] == "counter"]
        self.assertEqual(len(counters), 24)
        self.assertTrue(all(isinstance(item["value"], int) and item["value"] >= 0 for item in counters))
        states = [item for item in interface_metrics if item["name"] == "interface.operstate"]
        self.assertEqual(len(states), 3)
        self.assertTrue(all(item["type"] == "state" and isinstance(item["value"], str) for item in states))

    def test_system_values_are_plausible(self) -> None:
        metrics = {item.name: item for item in self.collect().metrics if item.interface is None}
        self.assertGreaterEqual(metrics["system.uptime_seconds"].value, 0)
        self.assertGreater(metrics["system.memory.total_bytes"].value, 0)
        self.assertGreaterEqual(metrics["system.memory.available_bytes"].value, 0)
        for name in ("system.cpu.utilization_ratio", "system.memory.utilization_ratio"):
            self.assertGreaterEqual(metrics[name].value, 0)
            self.assertLessEqual(metrics[name].value, 1)
        self.assertIs(metrics["system.cpu.utilization_ratio"].metric_type, MetricType.GAUGE)

    def test_missing_interface_and_loopback_fail_closed(self) -> None:
        with self.assertRaises(MetricCollectionError):
            collect_snapshot(
                (InterfaceIdentity("lan", "absent"),),
                proc_root=self.proc,
                sys_class_net=self.net,
                sleep=lambda _seconds: (self.proc / "stat").write_text("cpu 15 0 15 90 0 0 0 0\n", encoding="ascii"),
            )
        with self.assertRaises(MetricCollectionError):
            InterfaceIdentity("lan", "lo")
        with self.assertRaises(MetricCollectionError):
            InterfaceIdentity("unknown", "fixture-other")


class MetricsCommandTests(unittest.TestCase):
    def test_wrapper_collects_inside_router_namespace_with_configured_roles(self) -> None:
        root = Path(__file__).resolve().parents[1]
        wrapper = (root / "lab/scripts/show-metrics.sh").read_text(encoding="utf-8")
        common = (root / "lab/scripts/topology-common.sh").read_text(encoding="utf-8")
        self.assertIn("router_context_prefix", wrapper)
        self.assertIn('ROUTER_CONTEXT_PREFIX=(ip netns exec "$ROUTER_NAMESPACE")', common)
        self.assertIn("ROUTER_CONTEXT_PREFIX=(nsenter --net=/proc/1/ns/net --mount=/proc/1/ns/mnt --)", common)
        self.assertIn("ROUTER_CONTEXT_PREFIX=()", common)
        self.assertIn('--interface "lan=$ROUTER_LAN_INTERFACE"', wrapper)
        self.assertIn('--interface "wan=$ROUTER_WAN_INTERFACE"', wrapper)
        self.assertIn('--interface "telemetry=$TELEMETRY_ROUTER_INTERFACE"', wrapper)
        self.assertNotIn('--interface "loopback=', wrapper)
        for forbidden in ("nft ", "route add", "route del", "sysctl -w", "systemctl", "pkill", "killall"):
            self.assertNotIn(forbidden, wrapper)

    def test_metrics_exporter_uses_same_router_context_abstraction(self) -> None:
        root = Path(__file__).resolve().parents[1]
        exporter = (root / "lab/scripts/enable-metrics-export.sh").read_text(encoding="utf-8")
        self.assertIn("router_context_prefix", exporter)
        self.assertIn('prefix=("${ROUTER_CONTEXT_PREFIX[@]}" env "PYTHONPATH=$HVR_REPO_DIR")', exporter)
        self.assertNotIn("hvr-sim", exporter)

    def test_metrics_show_keeps_stdout_machine_readable(self) -> None:
        root = Path(__file__).resolve().parents[1]
        makefile = (root / "Makefile").read_text(encoding="utf-8")
        target = makefile[makefile.index("metrics-show:"):makefile.index("metrics-test:")]
        self.assertIn('>&2', target)
        self.assertIn('@sudo lab/scripts/show-metrics.sh', target)


if __name__ == "__main__":
    unittest.main()
