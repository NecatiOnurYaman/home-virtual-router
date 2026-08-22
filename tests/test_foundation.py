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
CREATE = ROOT / "lab/scripts/create-topology.sh"
ROUTING_ENABLE = ROOT / "lab/scripts/enable-routing.sh"
ROUTING_DISABLE = ROOT / "lab/scripts/disable-routing.sh"
NAT_ENABLE = ROOT / "lab/scripts/enable-nat.sh"
NAT_DISABLE = ROOT / "lab/scripts/disable-nat.sh"
NAT_TEST = ROOT / "lab/scripts/test-nat.sh"
FIREWALL_ENABLE = ROOT / "lab/scripts/enable-firewall.sh"
FIREWALL_DISABLE = ROOT / "lab/scripts/disable-firewall.sh"
FIREWALL_TEST = ROOT / "lab/scripts/test-firewall.sh"

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
        self.assertEqual(values["NAT_TABLE"], "hvr-nat")
        self.assertEqual(values["NAT_CHAIN"], "hvr-postrouting")
        self.assertEqual(values["FILTER_TABLE"], "hvr-filter")
        self.assertEqual(values["FILTER_CHAIN"], "hvr-forward")

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

    def test_r2_forces_only_router_namespace_forwarding_off(self) -> None:
        script = CREATE.read_text(encoding="utf-8")
        namespace_write = (
            'ip netns exec "$ROUTER_NAMESPACE" sysctl -q -w '
            'net.ipv4.ip_forward=0'
        )
        namespace_verify = (
            'ip netns exec "$ROUTER_NAMESPACE" sysctl -n '
            'net.ipv4.ip_forward'
        )
        self.assertIn(namespace_write, script)
        self.assertIn(namespace_verify, script)
        self.assertNotIn("sysctl -q -w net.ipv4.ip_forward=1", script)
        for line in script.splitlines():
            if "sysctl -q -w net.ipv4.ip_forward=" in line:
                self.assertTrue(line.startswith('ip netns exec "$ROUTER_NAMESPACE" '))

    def test_r2_verifies_host_forwarding_is_unchanged(self) -> None:
        script = CREATE.read_text(encoding="utf-8")
        self.assertIn('host_forwarding_before="$(capture_host_ipv4_forwarding)"', script)
        self.assertGreaterEqual(
            script.count('verify_host_ipv4_forwarding_unchanged "$host_forwarding_before"'),
            2,
        )


class RoutingStageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.enable = ROUTING_ENABLE.read_text(encoding="utf-8")
        self.disable = ROUTING_DISABLE.read_text(encoding="utf-8")

    def test_forwarding_writes_are_router_namespace_scoped(self) -> None:
        self.assertIn(
            'ip netns exec "$ROUTER_NAMESPACE" sysctl -q -w net.ipv4.ip_forward=1',
            self.enable,
        )
        for script in (self.enable, self.disable):
            for line in script.splitlines():
                if "sysctl -q -w net.ipv4.ip_forward=" in line:
                    self.assertTrue(line.lstrip().startswith('ip netns exec "$ROUTER_NAMESPACE" '))

    def test_routes_are_exact_and_namespace_scoped(self) -> None:
        self.assertIn(
            'ip -n "$CLIENT_NAMESPACE" route add default via "$ROUTER_LAN" dev "$CLIENT_INTERFACE"',
            self.enable,
        )
        self.assertIn(
            'ip -n "$UPSTREAM_NAMESPACE" route add "$LAN_SUBNET" via "$ROUTER_WAN" dev "$UPSTREAM_INTERFACE"',
            self.enable,
        )
        for script in (self.enable, self.disable):
            for line in script.splitlines():
                stripped = line.lstrip()
                if " route add " in stripped or " route del " in stripped:
                    self.assertTrue(stripped.startswith('ip -n "$'))

    def test_disable_removes_only_exact_r3_state(self) -> None:
        self.assertIn(
            'ip -n "$CLIENT_NAMESPACE" route del default via "$ROUTER_LAN" dev "$CLIENT_INTERFACE"',
            self.disable,
        )
        self.assertIn(
            'ip -n "$UPSTREAM_NAMESPACE" route del "$LAN_SUBNET" via "$ROUTER_WAN" dev "$UPSTREAM_INTERFACE"',
            self.disable,
        )
        self.assertNotIn("route flush", self.disable)
        self.assertNotIn("ip netns delete", self.disable)

    def test_r3_has_no_nat_or_nftables_commands(self) -> None:
        for script in (self.enable, self.disable):
            lowered = script.lower()
            self.assertNotIn("nft ", lowered)
            self.assertNotIn("masquerade", lowered)
            self.assertNotIn("snat", lowered)
            self.assertNotIn("dnat", lowered)

    def test_r3_verifies_host_route_and_forwarding_unchanged(self) -> None:
        for script in (self.enable, self.disable):
            self.assertIn('default_route_before="$(capture_default_route)"', script)
            self.assertIn('host_forwarding_before="$(capture_host_ipv4_forwarding)"', script)
            self.assertIn('verify_default_route_unchanged "$default_route_before"', script)
            self.assertIn(
                'verify_host_ipv4_forwarding_unchanged "$host_forwarding_before"',
                script,
            )


class NatStageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.enable = NAT_ENABLE.read_text(encoding="utf-8")
        self.disable = NAT_DISABLE.read_text(encoding="utf-8")
        self.common = TOPOLOGY_COMMON.read_text(encoding="utf-8")
        self.integration_test = NAT_TEST.read_text(encoding="utf-8")

    def test_nat_table_and_chain_are_allowlisted(self) -> None:
        result = subprocess.run(
            [
                "bash", "-c",
                f"source '{SAFETY}'; "
                "require_explicit_nft_table hvr-nat; "
                "require_explicit_nft_chain hvr-postrouting",
            ],
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('require_explicit_nft_table "$NAT_TABLE"', self.common)
        self.assertIn('require_explicit_nft_chain "$NAT_CHAIN"', self.common)

    def test_masquerade_rule_is_exact(self) -> None:
        self.assertIn('oifname "$ROUTER_WAN_INTERFACE" ip saddr "$LAN_SUBNET"', self.common)
        self.assertIn('counter masquerade comment "hvr-r4-masquerade"', self.common)
        self.assertIn("type nat hook postrouting priority srcnat", self.common)

    def test_all_nat_mutations_are_router_namespace_scoped(self) -> None:
        self.assertIn('ip netns exec "$ROUTER_NAMESPACE" nft "$@"', self.common)
        self.assertIn('router_nft add table ip "$NAT_TABLE"', self.common)
        self.assertIn('router_nft delete table ip "$NAT_TABLE"', self.common)
        for script in (self.enable, self.disable):
            self.assertNotIn("\nnft add", script)
            self.assertNotIn("\nnft delete", script)
            self.assertNotIn("nft flush", script)

    def test_enable_removes_and_disable_restores_exact_return_route(self) -> None:
        exact_delete = (
            'ip -n "$UPSTREAM_NAMESPACE" route del "$LAN_SUBNET" '
            'via "$ROUTER_WAN" dev "$UPSTREAM_INTERFACE"'
        )
        exact_add = (
            'ip -n "$UPSTREAM_NAMESPACE" route add "$LAN_SUBNET" '
            'via "$ROUTER_WAN" dev "$UPSTREAM_INTERFACE"'
        )
        self.assertIn(exact_delete, self.enable)
        self.assertIn(exact_add, self.disable)
        self.assertNotIn("route flush", self.enable + self.disable)

    def test_no_dnat_port_forwarding_or_filter_policy(self) -> None:
        nat_helpers = self.common[
            self.common.index("create_project_nat_table()"):
            self.common.index("filter_table_exists()")
        ]
        scripts = (self.enable + self.disable + nat_helpers).lower()
        self.assertNotIn(" dnat", scripts)
        self.assertNotIn(" redirect", scripts)
        self.assertNotIn(" hook input", scripts)
        self.assertNotIn(" hook forward", scripts)
        self.assertNotIn("policy drop", scripts)

    def test_host_state_is_snapshotted_and_verified(self) -> None:
        for script in (self.enable, self.disable):
            self.assertIn('default_route_before="$(capture_default_route)"', script)
            self.assertIn('host_forwarding_before="$(capture_host_ipv4_forwarding)"', script)
            self.assertIn('host_nftables_before="$(capture_host_nftables)"', script)
            self.assertIn('verify_host_nftables_unchanged "$host_nftables_before"', script)
        self.assertNotIn("sysctl -q -w net.ipv4.ip_forward", self.enable + self.disable)

    def test_source_translation_is_observed_not_inferred(self) -> None:
        self.assertIn('observed_source="$(tail -n 1 "$capture_file")"', self.integration_test)
        self.assertIn('[ "$observed_source" = "$ROUTER_WAN" ]', self.integration_test)


class FirewallStageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.enable = FIREWALL_ENABLE.read_text(encoding="utf-8")
        self.disable = FIREWALL_DISABLE.read_text(encoding="utf-8")
        self.common = TOPOLOGY_COMMON.read_text(encoding="utf-8")
        self.integration_test = FIREWALL_TEST.read_text(encoding="utf-8")

    def test_filter_objects_are_allowlisted_and_separate_from_nat(self) -> None:
        self.assertIn('require_explicit_nft_table "$FILTER_TABLE"', self.common)
        self.assertIn('require_explicit_nft_chain "$FILTER_CHAIN"', self.common)
        self.assertIn('router_nft add table inet "$FILTER_TABLE"', self.common)
        self.assertIn('router_nft add table ip "$NAT_TABLE"', self.common)

    def test_forward_chain_has_default_drop_policy(self) -> None:
        self.assertIn("type filter hook forward priority filter; policy drop;", self.common)

    def test_rules_are_ordered_and_stateful(self) -> None:
        invalid = self.common.index('ct state invalid counter drop')
        established = self.common.index('ct state established,related counter accept')
        outbound = self.common.index('ct state new iifname "$ROUTER_LAN_INTERFACE"')
        wan_drop = self.common.index('ct state new iifname "$ROUTER_WAN_INTERFACE"')
        self.assertLess(invalid, established)
        self.assertLess(established, outbound)
        self.assertLess(outbound, wan_drop)
        self.assertIn('oifname "$ROUTER_WAN_INTERFACE"', self.common[outbound:])
        self.assertIn('ip saddr "$LAN_SUBNET" counter accept', self.common[outbound:])

    def test_no_wan_to_lan_accept_or_port_forwarding(self) -> None:
        for line in self.common.splitlines():
            if 'iifname "$ROUTER_WAN_INTERFACE"' in line:
                self.assertNotIn("accept", line)
        lowered = self.enable.lower() + self.disable.lower() + self.common.lower()
        self.assertNotIn(" dnat", lowered)
        self.assertNotIn(" redirect", lowered)

    def test_firewall_mutations_are_namespace_scoped_and_exact(self) -> None:
        self.assertIn('ip netns exec "$ROUTER_NAMESPACE" nft "$@"', self.common)
        self.assertIn('router_nft delete table inet "$FILTER_TABLE"', self.common)
        self.assertNotIn("nft flush", self.enable + self.disable + self.common)
        self.assertNotIn('delete table ip "$NAT_TABLE"', self.disable)

    def test_enable_and_disable_verify_host_nftables(self) -> None:
        for script in (self.enable, self.disable):
            self.assertIn('host_nftables_before="$(capture_host_nftables)"', script)
            self.assertIn('verify_host_nftables_unchanged "$host_nftables_before"', script)
            self.assertNotIn("\nnft add", script)
            self.assertNotIn("\nnft delete", script)

    def test_unsolicited_test_route_is_exact_and_removed(self) -> None:
        exact_add = (
            'ip -n "$UPSTREAM_NAMESPACE" route add "$LAN_SUBNET" '
            'via "$ROUTER_WAN" dev "$UPSTREAM_INTERFACE"'
        )
        exact_delete = (
            'ip -n "$UPSTREAM_NAMESPACE" route del "$LAN_SUBNET" '
            'via "$ROUTER_WAN" dev "$UPSTREAM_INTERFACE"'
        )
        self.assertEqual(self.integration_test.count(exact_add), 1)
        self.assertGreaterEqual(self.integration_test.count(exact_delete), 2)
        self.assertIn(
            "drop_packets_before=\"$(filter_rule_packet_count hvr-r5-wan-lan-drop)\"",
            self.integration_test,
        )
        self.assertIn(
            "drop_packets_after=\"$(filter_rule_packet_count hvr-r5-wan-lan-drop)\"",
            self.integration_test,
        )


if __name__ == "__main__":
    unittest.main()
