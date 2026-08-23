from __future__ import annotations

import importlib.util
import os
import subprocess
import tempfile
import unittest
import stat
import struct
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
DHCP_ENABLE = ROOT / "lab/scripts/enable-dhcp.sh"
DHCP_DISABLE = ROOT / "lab/scripts/disable-dhcp.sh"
DHCP_TEST = ROOT / "lab/scripts/test-dhcp.sh"
DNS_ENABLE = ROOT / "lab/scripts/enable-dns.sh"
DNS_DISABLE = ROOT / "lab/scripts/disable-dns.sh"
DNS_TEST = ROOT / "lab/scripts/test-dns.sh"
IPFIX_ENABLE = ROOT / "lab/scripts/enable-ipfix.sh"
IPFIX_DISABLE = ROOT / "lab/scripts/disable-ipfix.sh"
IPFIX_TEST = ROOT / "lab/scripts/test-ipfix.sh"
IPFIX_RECEIVER = ROOT / "router/scripts/ipfix_test_receiver.py"
PMACCT_CONFIG = ROOT / "router/config/pmacctd-nfprobe.conf.template"
DNSMASQ_CONFIG = ROOT / "router/config/dnsmasq-dhcp.conf.template"
ROUTER_DNS_CONFIG = ROOT / "router/config/dnsmasq-router-dns.conf.template"
UPSTREAM_DNS_CONFIG = ROOT / "router/config/dnsmasq-upstream-test.conf.template"
DHCLIENT_HOOK = ROOT / "router/scripts/dhclient-lab-hook.sh"

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
        self.assertEqual(values["DHCP_RANGE_START"], "10.0.0.100")
        self.assertEqual(values["DHCP_RANGE_END"], "10.0.0.199")
        self.assertEqual(values["DHCP_DNS_SERVER"], "10.0.0.1")
        self.assertEqual(values["DNS_UPSTREAM"], "192.0.2.1")
        self.assertEqual(values["DNS_CACHE_SIZE"], "150")
        self.assertEqual(values["DNS_TEST_NAME"], "example.test")
        self.assertEqual(values["DNS_TEST_ADDRESS"], "192.0.2.123")
        self.assertEqual(values["IPFIX_ENABLED"], "1")
        self.assertEqual(values["IPFIX_COLLECTOR_HOST"], "192.0.2.1")
        self.assertEqual(values["IPFIX_COLLECTOR_PORT"], "4739")
        self.assertEqual(values["IPFIX_CAPTURE_INTERFACE"], "hvr-lan")

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

    def test_rejects_invalid_dhcp_pool(self) -> None:
        values = validate_config.parse(ROOT / "lab/config/defaults.env")
        values["DHCP_RANGE_START"] = "10.0.0.1"
        with self.assertRaises(ValueError):
            validate_config.validate(values)
        values = validate_config.parse(ROOT / "lab/config/defaults.env")
        values["DHCP_RANGE_END"] = "10.0.1.10"
        with self.assertRaises(ValueError):
            validate_config.validate(values)

    def test_rejects_external_r7_dns_configuration(self) -> None:
        values = validate_config.parse(ROOT / "lab/config/defaults.env")
        values["DNS_UPSTREAM"] = "8.8.8.8"
        with self.assertRaises(ValueError):
            validate_config.validate(values)
        values = validate_config.parse(ROOT / "lab/config/defaults.env")
        values["DNS_TEST_ADDRESS"] = "1.1.1.1"
        with self.assertRaises(ValueError):
            validate_config.validate(values)

    def test_rejects_unsafe_ipfix_configuration(self) -> None:
        for key, value in (
            ("IPFIX_COLLECTOR_HOST", "203.0.113.1"),
            ("IPFIX_COLLECTOR_PORT", "0"),
            ("IPFIX_CAPTURE_INTERFACE", "hvr-wan"),
        ):
            with self.subTest(key=key):
                values = validate_config.parse(ROOT / "lab/config/defaults.env")
                values[key] = value
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


class DhcpStageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.enable = DHCP_ENABLE.read_text(encoding="utf-8")
        self.disable = DHCP_DISABLE.read_text(encoding="utf-8")
        self.integration_test = DHCP_TEST.read_text(encoding="utf-8")
        self.dnsmasq = DNSMASQ_CONFIG.read_text(encoding="utf-8")
        self.hook = DHCLIENT_HOOK.read_text(encoding="utf-8")

    def test_dnsmasq_is_dhcp_only_and_lan_bound(self) -> None:
        self.assertIn("port=0", self.dnsmasq)
        self.assertIn("interface=@ROUTER_LAN_INTERFACE@", self.dnsmasq)
        self.assertIn("bind-interfaces", self.dnsmasq)
        self.assertNotIn("interface=hvr-wan", self.dnsmasq)
        common = TOPOLOGY_COMMON.read_text(encoding="utf-8")
        self.assertIn("printf 'interface=%s\\n' \"$ROUTER_LAN_INTERFACE\"", common)

    def test_range_and_options_match_r6_defaults(self) -> None:
        self.assertIn(
            "dhcp-range=@DHCP_RANGE_START@,@DHCP_RANGE_END@,255.255.255.0,@DHCP_LEASE_TIME@",
            self.dnsmasq,
        )
        self.assertIn("dhcp-option=option:router,@ROUTER_LAN@", self.dnsmasq)
        self.assertIn("dhcp-option=option:netmask,255.255.255.0", self.dnsmasq)
        self.assertIn("dhcp-option=option:dns-server,@DHCP_DNS_SERVER@", self.dnsmasq)

    def test_lease_and_process_files_are_project_owned(self) -> None:
        self.assertIn(
            "dhcp-leasefile=@DNSMASQ_LEASE_FILE@",
            self.dnsmasq,
        )
        self.assertIn("pid-file=@DNSMASQ_PID_FILE@", self.dnsmasq)
        self.assertNotIn("/var/lib/misc", self.dnsmasq)

    def test_dnsmasq_and_dhclient_are_namespace_scoped(self) -> None:
        self.assertIn(
            'ip netns exec "$ROUTER_NAMESPACE" dnsmasq --conf-file="$DNSMASQ_CONFIG"',
            self.enable,
        )
        self.assertIn(
            'ip netns exec "$CLIENT_NAMESPACE" "$DHCLIENT_RUNTIME_BINARY" -4 -1 -v',
            self.enable,
        )
        self.assertNotIn("systemctl start", self.enable + self.disable)
        self.assertNotIn("systemctl stop", self.enable + self.disable)

    def test_disable_targets_project_pid_and_restores_static_state(self) -> None:
        self.assertIn(
            'stop_project_process_if_present "$DNSMASQ_PID_FILE" dnsmasq "$DNSMASQ_CONFIG"',
            self.disable,
        )
        self.assertNotIn("killall", self.disable)
        self.assertNotIn("pkill", self.disable)
        self.assertIn(
            'address replace "$CLIENT_ADDRESS/$lan_prefix" dev "$CLIENT_INTERFACE"',
            self.disable,
        )

    def test_hook_never_writes_host_resolv_conf(self) -> None:
        self.assertNotIn("/etc/resolv.conf", self.hook)
        self.assertIn("client-resolv.conf", self.hook)
        self.assertIn('send host-name "hvr-client";', (ROOT / "router/config/dhclient.conf").read_text())

    def test_integration_checks_dynamic_route_lease_and_hostname(self) -> None:
        self.assertIn('dynamic_address="$(client_dhcp_address)"', self.integration_test)
        self.assertIn("client_default_route_exists", self.integration_test)
        self.assertIn('$4 == "hvr-client"', self.integration_test)
        self.assertIn("$2 == mac && $3 == address", self.integration_test)

    def test_r6_snapshots_host_dns_service_and_interfaces(self) -> None:
        for script in (self.enable, self.disable, self.integration_test):
            self.assertIn("snapshot_r6_host_state", script)
            self.assertIn("verify_r6_host_state", script)

    def test_dnsmasq_identity_uses_numeric_primary_gid(self) -> None:
        command = f'''
source "{TOPOLOGY_COMMON}"
getent() {{ printf '%s\\n' 'dnsmasq:x:123:456:dnsmasq:/var/lib/misc:/usr/sbin/nologin'; }}
resolve_dnsmasq_identity
printf '%s:%s' "$DNSMASQ_UID" "$DNSMASQ_GID"
'''
        result = subprocess.run(["bash", "-c", command], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "123:456")
        self.assertIn('chown "$DNSMASQ_UID:$DNSMASQ_GID"', self.enable)
        self.assertNotIn("dnsmasq:dnsmasq", self.enable + self.disable + TOPOLOGY_COMMON.read_text())

    def test_missing_dnsmasq_user_fails_clearly(self) -> None:
        command = f'''
source "{SAFETY}"
source "{TOPOLOGY_COMMON}"
getent() {{ return 2; }}
resolve_dnsmasq_identity
'''
        result = subprocess.run(["bash", "-c", command], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dnsmasq system user is missing", result.stderr)

    def test_partial_pid_state_can_be_cleaned_without_a_daemon(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "dnsmasq.pid"
            pid_file.write_text("99999999\n", encoding="utf-8")
            command = f'''
source "{TOPOLOGY_COMMON}"
stop_project_process_if_present "{pid_file}" dnsmasq "$DNSMASQ_CONFIG"
test ! -e "{pid_file}"
'''
            result = subprocess.run(["bash", "-c", command], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_disable_allows_missing_r6_binaries_and_limits_cleanup(self) -> None:
        dependency_loop = self.disable.split("for required_command in nft", 1)[1].split("done", 1)[0]
        self.assertNotIn(" dnsmasq", dependency_loop)
        self.assertNotIn(" dhclient", dependency_loop)
        self.assertIn("stop_project_process_if_present", self.disable)
        common = TOPOLOGY_COMMON.read_text(encoding="utf-8")
        self.assertIn("remove_project_dhcp_files()", common)
        self.assertIn('"$DNSMASQ_CONFIG" "$DNSMASQ_PID_FILE"', common)
        self.assertNotIn('rm -rf', self.disable + common)
        self.assertIn('address replace "$CLIENT_ADDRESS/$lan_prefix"', self.disable)

    def test_dhclient_runtime_is_private_and_writable_by_root(self) -> None:
        self.assertIn('install -d -o 0 -g 0 -m 0700 "$DHCLIENT_RUNTIME_DIR"', self.enable)
        self.assertIn('touch "$DHCLIENT_PID_FILE" "$DHCLIENT_LEASE_FILE"', self.enable)
        self.assertIn('chown 0:0 "$DHCLIENT_PID_FILE" "$DHCLIENT_LEASE_FILE"', self.enable)
        self.assertIn('chmod 0600 "$DHCLIENT_PID_FILE" "$DHCLIENT_LEASE_FILE"', self.enable)
        self.assertNotIn("0777", self.enable + TOPOLOGY_COMMON.read_text())

    def test_runtime_hook_and_client_binary_are_executable_copies(self) -> None:
        mode = DHCLIENT_HOOK.stat().st_mode
        self.assertTrue(mode & stat.S_IXUSR)
        self.assertTrue(os.access(DHCLIENT_HOOK, os.X_OK))
        self.assertIn(
            'install -o 0 -g 0 -m 0755 "$DHCLIENT_HOOK_SOURCE" "$DHCLIENT_HOOK"',
            self.enable,
        )
        self.assertIn(
            'install -o 0 -g 0 -m 0755 "$dhclient_source" "$DHCLIENT_RUNTIME_BINARY"',
            self.enable,
        )
        self.assertIn('/sbin/dhclient|/usr/sbin/dhclient)', self.enable)
        common = TOPOLOGY_COMMON.read_text(encoding="utf-8")
        self.assertIn('readonly DHCLIENT_RUNTIME_DIR="$DHCP_RUNTIME_DIR/client"', common)

    def test_success_requires_actual_dynamic_state_without_static_address(self) -> None:
        dynamic_check = self.enable.index('dynamic_address="$(client_dhcp_address)"')
        static_check = self.enable.index("client_static_address_exists && die")
        route_check = self.enable.index("client_default_route_exists || die", dynamic_check)
        resolver_check = self.enable.index('cat "$DHCP_CLIENT_RESOLV_FILE"', dynamic_check)
        lease_check = self.enable.index('"$DNSMASQ_LEASE_FILE" || die', dynamic_check)
        self.assertLess(dynamic_check, static_check)
        self.assertLess(static_check, route_check)
        self.assertLess(route_check, resolver_check)
        self.assertLess(resolver_check, lease_check)

    def test_host_interface_snapshot_ignores_lifetimes(self) -> None:
        common = TOPOLOGY_COMMON
        before = "2: eth0    inet 192.0.2.20/24 brd 192.0.2.255 scope global dynamic eth0 valid_lft 300sec preferred_lft 300sec"
        after = "2: eth0    inet 192.0.2.20/24 brd 192.0.2.255 scope global dynamic eth0 valid_lft 250sec preferred_lft 250sec"
        command = f'''source "{common}"; normalize_host_ipv4_state'''
        first = subprocess.run(["bash", "-c", command], input=before, text=True, capture_output=True, check=True)
        second = subprocess.run(["bash", "-c", command], input=after, text=True, capture_output=True, check=True)
        self.assertEqual(first.stdout, second.stdout)

    def test_host_ip_and_interface_changes_remain_visible(self) -> None:
        common = TOPOLOGY_COMMON
        normalize_ip = f'''source "{common}"; normalize_host_ipv4_state'''
        old_ip = subprocess.run(
            ["bash", "-c", normalize_ip], input="2: eth0 inet 192.0.2.20/24 scope global eth0\n",
            text=True, capture_output=True, check=True,
        ).stdout
        new_ip = subprocess.run(
            ["bash", "-c", normalize_ip], input="2: eth0 inet 192.0.2.21/24 scope global eth0\n",
            text=True, capture_output=True, check=True,
        ).stdout
        self.assertNotEqual(old_ip, new_ip)

        normalize_link = f'''source "{common}"; normalize_host_link_state'''
        links = subprocess.run(
            ["bash", "-c", normalize_link],
            input="2: eth0: <UP> mtu 1500 link/ether 02:00:00:00:00:01\n",
            text=True, capture_output=True, check=True,
        ).stdout
        renamed = subprocess.run(
            ["bash", "-c", normalize_link],
            input="2: enp0s1: <UP> mtu 1500 link/ether 02:00:00:00:00:01\n",
            text=True, capture_output=True, check=True,
        ).stdout
        self.assertNotEqual(links, renamed)
        self.assertNotEqual(links, "")

    def test_default_route_check_remains_separate_and_exact(self) -> None:
        common = TOPOLOGY_COMMON.read_text(encoding="utf-8")
        self.assertIn('verify_default_route_unchanged "$R6_HOST_DEFAULT_ROUTE"', common)
        self.assertIn('[ "$before" = "$after" ] || die "the Ubuntu VM default route changed unexpectedly"', common)

    def test_disable_handles_completely_absent_topology_before_r2_requirement(self) -> None:
        absent_branch = self.disable.index('if ! namespace_exists "$UPSTREAM_NAMESPACE"')
        topology_requirement = self.disable.index("require_r2_topology")
        self.assertLess(absent_branch, topology_requirement)
        self.assertIn("namespace cleanup was unnecessary", self.disable)
        self.assertIn("remove_project_dhcp_files", self.disable[absent_branch:topology_requirement])


class DnsStageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.enable = DNS_ENABLE.read_text(encoding="utf-8")
        self.disable = DNS_DISABLE.read_text(encoding="utf-8")
        self.integration_test = DNS_TEST.read_text(encoding="utf-8")
        self.router_config = ROUTER_DNS_CONFIG.read_text(encoding="utf-8")
        self.upstream_config = UPSTREAM_DNS_CONFIG.read_text(encoding="utf-8")
        self.common = TOPOLOGY_COMMON.read_text(encoding="utf-8")

    def test_router_dns_binds_only_to_lan(self) -> None:
        self.assertIn("port=53", self.router_config)
        self.assertIn("interface=@ROUTER_LAN_INTERFACE@", self.router_config)
        self.assertIn("listen-address=@ROUTER_LAN@", self.router_config)
        self.assertIn("bind-interfaces", self.router_config)
        self.assertNotIn("ROUTER_WAN_INTERFACE", self.router_config)
        self.assertNotIn("ROUTER_WAN", self.router_config)
        self.assertIn("validate_router_dns_listeners", self.integration_test)
        self.assertIn('seen_lan["udp"] && seen_lan["tcp"] && !bad', self.common)

    def run_listener_policy(self, listeners: str, lan_v6: str = "fe80::10") -> subprocess.CompletedProcess[str]:
        command = (
            f'source "{TOPOLOGY_COMMON}"; '
            f'validate_router_dns_listeners 10.0.0.1 192.0.2.2 hvr-lan "{lan_v6}"'
        )
        return subprocess.run(
            ["bash", "-c", command], input=listeners, text=True, capture_output=True
        )

    def test_listener_policy_requires_ipv4_lan_udp_and_tcp(self) -> None:
        both = (
            "udp UNCONN 0 0 10.0.0.1:53 0.0.0.0:*\n"
            "tcp LISTEN 0 32 10.0.0.1:53 0.0.0.0:*\n"
        )
        self.assertEqual(self.run_listener_policy(both).returncode, 0)
        self.assertNotEqual(self.run_listener_policy(both.splitlines()[0] + "\n").returncode, 0)
        self.assertNotEqual(self.run_listener_policy(both.splitlines()[1] + "\n").returncode, 0)

    def test_listener_policy_allows_loopback_and_lan_link_local(self) -> None:
        listeners = (
            "udp UNCONN 0 0 10.0.0.1:53 0.0.0.0:*\n"
            "tcp LISTEN 0 32 10.0.0.1:53 0.0.0.0:*\n"
            "udp UNCONN 0 0 127.0.0.1:53 0.0.0.0:*\n"
            "tcp LISTEN 0 32 [::1]:53 [::]:*\n"
            "udp UNCONN 0 0 [fe80::10%hvr-lan]:53 [::]:*\n"
            "tcp LISTEN 0 32 [fe80::10%hvr-lan]:53 [::]:*\n"
        )
        self.assertEqual(self.run_listener_policy(listeners).returncode, 0)

    def test_listener_policy_rejects_wan_and_wildcards(self) -> None:
        base = (
            "udp UNCONN 0 0 10.0.0.1:53 0.0.0.0:*\n"
            "tcp LISTEN 0 32 10.0.0.1:53 0.0.0.0:*\n"
        )
        forbidden = (
            "udp UNCONN 0 0 192.0.2.2:53 0.0.0.0:*\n",
            "tcp LISTEN 0 32 0.0.0.0:53 0.0.0.0:*\n",
            "udp UNCONN 0 0 [::]:53 [::]:*\n",
            "udp UNCONN 0 0 [fe80::20%hvr-wan]:53 [::]:*\n",
        )
        for listener in forbidden:
            with self.subTest(listener=listener):
                self.assertNotEqual(self.run_listener_policy(base + listener).returncode, 0)

    def test_active_wan_dns_probes_must_fail(self) -> None:
        self.assertIn(
            'ip netns exec "$UPSTREAM_NAMESPACE" dig +short +time=1 +tries=1 @"$ROUTER_WAN"',
            self.integration_test,
        )
        self.assertIn(
            'ip netns exec "$UPSTREAM_NAMESPACE" dig +tcp +short +time=1 +tries=1 @"$ROUTER_WAN"',
            self.integration_test,
        )
        self.assertIn("UDP DNS unexpectedly answered through router WAN", self.integration_test)
        self.assertIn("TCP DNS unexpectedly answered through router WAN", self.integration_test)

    def test_upstream_is_explicit_and_isolated(self) -> None:
        self.assertIn("no-resolv", self.router_config)
        self.assertIn("server=@DNS_UPSTREAM@", self.router_config)
        self.assertIn("interface=@UPSTREAM_INTERFACE@", self.upstream_config)
        self.assertIn("listen-address=@DNS_UPSTREAM@", self.upstream_config)
        combined = self.enable + self.disable + self.integration_test + self.router_config + self.upstream_config
        for public_resolver in ("8.8.8.8", "1.1.1.1", "9.9.9.9"):
            self.assertNotIn(public_resolver, combined)
        self.assertNotIn("/etc/resolv.conf", combined)

    def test_deterministic_records_and_native_logging(self) -> None:
        self.assertIn("address=/@DNS_TEST_NAME@/@DNS_TEST_ADDRESS@", self.upstream_config)
        self.assertIn("address=/@DNS_TEST_NAME_ALT@/@DNS_TEST_ADDRESS_ALT@", self.upstream_config)
        self.assertIn("local-ttl=300", self.upstream_config)
        self.assertIn("log-queries=extra", self.router_config)
        self.assertIn("log-facility=@DNS_LOG_FILE@", self.router_config)
        self.assertIn('readonly DNS_LOG_FILE="$DNS_RUNTIME_DIR/dnsmasq.log"', self.common)
        self.assertIn('query[A] $DNS_TEST_NAME from', self.integration_test)
        self.assertIn('reply $DNS_TEST_NAME is $DNS_TEST_ADDRESS', self.integration_test)

    def test_cache_is_dnsmasq_native_and_log_verified(self) -> None:
        self.assertIn("cache-size=@DNS_CACHE_SIZE@", self.router_config)
        self.assertIn('cached $DNS_TEST_NAME is $DNS_TEST_ADDRESS', self.integration_test)
        self.assertIn('kill -HUP "$router_dns_pid"', self.integration_test)
        self.assertIn('log_start_lines="$(wc -l < "$DNS_LOG_FILE")"', self.integration_test)
        self.assertNotIn("time ", self.integration_test)

    def test_udp_tcp_queries_use_router_address(self) -> None:
        self.assertIn('@"$ROUTER_LAN" "$DNS_TEST_NAME" A', self.integration_test)
        self.assertIn('+tcp +short', self.integration_test)
        self.assertIn('"$DNS_TEST_ADDRESS"', self.integration_test)
        self.assertIn('"$DNS_TEST_ADDRESS_ALT"', self.integration_test)

    def test_r7_reuses_router_dnsmasq_and_preserves_dhcp(self) -> None:
        self.assertIn('stop_project_process "$DNSMASQ_PID_FILE" dnsmasq "$DNSMASQ_CONFIG"', self.enable)
        self.assertIn("render_router_dns_config", self.enable)
        self.assertIn("dhcp-range=", self.router_config)
        self.assertIn("dhcp-leasefile=@DNSMASQ_LEASE_FILE@", self.router_config)
        self.assertIn('[ "$(client_dhcp_address)" = "$client_address_before" ]', self.enable)

    def test_disable_returns_to_r6_without_releasing_client(self) -> None:
        self.assertIn("render_dnsmasq_config", self.disable)
        self.assertIn('grep -F -x -- "port=0"', self.disable)
        self.assertIn('[ "$(client_dhcp_address)" = "$client_address_before" ]', self.disable)
        self.assertNotIn("dhclient -4 -r", self.disable)
        self.assertNotIn("remove_client_dhcp_addresses", self.disable)
        self.assertNotIn("address del", self.disable)

    def test_process_and_file_cleanup_is_project_scoped(self) -> None:
        self.assertIn('stop_project_process_if_present "$UPSTREAM_DNS_PID_FILE"', self.disable)
        self.assertIn("remove_project_dns_files", self.disable)
        self.assertNotIn("pkill", self.enable + self.disable)
        self.assertNotIn("killall", self.enable + self.disable)
        self.assertNotIn("rm -rf", self.enable + self.disable + self.common)

    def test_host_dns_and_network_state_are_unchanged(self) -> None:
        for script in (self.enable, self.disable, self.integration_test):
            self.assertIn("snapshot_r6_host_state", script)
            self.assertIn("verify_r6_host_state", script)
            self.assertNotIn("systemctl start", script)
            self.assertNotIn("systemctl stop", script)
            self.assertNotIn("nft add", script)
            self.assertNotIn("nft delete", script)


class R8IpfixTests(unittest.TestCase):
    def setUp(self) -> None:
        self.enable = IPFIX_ENABLE.read_text(encoding="utf-8")
        self.disable = IPFIX_DISABLE.read_text(encoding="utf-8")
        self.integration_test = IPFIX_TEST.read_text(encoding="utf-8")
        self.common = TOPOLOGY_COMMON.read_text(encoding="utf-8")
        self.config = PMACCT_CONFIG.read_text(encoding="utf-8")

    def test_exporter_is_namespace_scoped_ipfix_v10_on_lan(self) -> None:
        self.assertIn('pmacctd_command=(ip netns exec "$ROUTER_NAMESPACE" pmacctd -f "$IPFIX_CONFIG_FILE")', self.enable)
        self.assertIn('"${pmacctd_command[@]}" >> "$IPFIX_LOG_FILE" 2>&1 &', self.enable)
        self.assertIn('IPFIX_CAPTURE_INTERFACE=hvr-lan', (ROOT / "lab/config/defaults.env").read_text())
        self.assertIn("pcap_interface: @CAPTURE_INTERFACE@", self.config)
        self.assertIn("pcap_filter: ip", self.config)
        self.assertIn("plugins: nfprobe[hvr]", self.config)
        self.assertIn("nfprobe_version[hvr]: 10", self.config)
        self.assertIn("pidfile: @PID_FILE@", self.config)
        self.assertIn("nfprobe_receiver[hvr]: @COLLECTOR_HOST@:@COLLECTOR_PORT@", self.config)
        self.assertNotIn("nfprobe_engine", self.config)
        self.assertNotIn("log_stderr_tstamp", self.config)
        self.assertIn('> "$IPFIX_COMMAND_FILE"', self.enable)

    def test_required_nfprobe_fields_and_bounded_timeouts(self) -> None:
        self.assertIn("src_host, dst_host, src_port, dst_port, proto, tos, tcpflags", self.config)
        self.assertIn("udp=3:icmp=3:general=3:maxlife=10:expint=1", self.config)
        self.assertNotIn("timestamps_secs", self.config)

    def test_receiver_precedes_small_bounded_traffic(self) -> None:
        receiver = self.integration_test.index('python3 "$IPFIX_RECEIVER"')
        ready = self.integration_test.index('IPFIX test receiver did not become ready')
        traffic = self.integration_test.index('ping -c 2', ready)
        wait = self.integration_test.index('wait "$collector_pid"', traffic)
        self.assertLess(receiver, ready)
        self.assertLess(ready, traffic)
        self.assertLess(traffic, wait)
        self.assertIn("--timeout 12", self.integration_test)
        self.assertIn('touch "$IPFIX_TRAFFIC_START"', self.integration_test)
        self.assertNotIn("--observation-domain", self.integration_test)
        self.assertNotIn("2048", self.integration_test)
        self.assertNotIn("ping -f", self.integration_test)

    def test_failure_cleanup_targets_only_temporary_receiver(self) -> None:
        self.assertIn("trap cleanup_ipfix_test EXIT INT TERM", self.integration_test)
        self.assertIn('project_process_matches "$collector_pid" python3 "$IPFIX_RECEIVER"', self.integration_test)
        self.assertIn('kill "$collector_pid"', self.integration_test)
        self.assertNotIn("pkill", self.integration_test)
        self.assertNotIn("killall", self.integration_test)

    def test_actual_binary_capability_is_checked_by_startup(self) -> None:
        self.assertIn("pmacctd -V", CHECKER.read_text(encoding="utf-8"))
        self.assertIn("no more plugins active", self.enable)
        self.assertIn("engine_type:engine_id is only supported on NetFlow v5", self.enable)
        self.assertIn("hvr/nfprobe", self.enable)
        self.assertIn("pmacct_core_running", self.enable)
        self.assertIn("pmacct_nfprobe_running", self.enable)
        self.assertIn('Exporting flows to [$IPFIX_COLLECTOR_HOST]:$IPFIX_COLLECTOR_PORT', self.enable)

    def test_process_model_uses_pidfile_parentage_and_namespace(self) -> None:
        self.assertIn('readonly IPFIX_PROCESS_TREE_FILE="$IPFIX_RUNTIME_DIR/process-tree.txt"', self.common)
        self.assertIn('readlink "/proc/$pid/ns/net"', self.common)
        self.assertIn('readlink /proc/self/ns/net', self.common)
        self.assertIn('/proc/$core_pid/task/$core_pid/children', self.common)
        self.assertIn('[ "$parent" = "$core_pid" ]', self.common)
        self.assertIn("process_is_pmacctd", self.common)
        self.assertIn("process_starttime", self.common)

    def test_failed_start_preserves_diagnostics(self) -> None:
        rollback = self.enable[self.enable.index("rollback_ipfix_enable()"):
                               self.enable.index("trap rollback_ipfix_enable")]
        self.assertIn("capture_pmacct_process_tree", rollback)
        self.assertIn("remove_project_ipfix_pid_files", rollback)
        self.assertNotIn("remove_project_ipfix_files", rollback)
        for artifact in ("IPFIX_CONFIG_FILE", "IPFIX_LOG_FILE", "IPFIX_COMMAND_FILE", "IPFIX_PROCESS_TREE_FILE"):
            self.assertIn(artifact, rollback)

    def test_safe_shutdown_signals_verified_core_then_plugin(self) -> None:
        self.assertIn('kill "$core_pid"', self.common)
        self.assertIn('stop_recorded_pmacct_process "$IPFIX_PLUGIN_PID_FILE"', self.common)
        self.assertIn("refusing to stop reused pmacct core PID", self.common)
        self.assertIn("project pmacct core is outside hvr-router", self.common)
        self.assertIn("run ipfix-disable before enabling", self.enable)

    def test_host_network_and_services_are_not_modified(self) -> None:
        combined = self.enable + self.disable + self.integration_test
        for forbidden in (
            "systemctl start", "systemctl stop", "systemctl restart",
            "systemctl enable", "systemctl disable", "nft add", "nft delete",
            "route add", "route del",
        ):
            self.assertNotIn(forbidden, combined)
        for script in (self.enable, self.disable, self.integration_test):
            self.assertIn("snapshot_r6_host_state", script)
            self.assertIn("verify_r6_host_state", script)

    def test_cleanup_is_project_scoped_and_preserves_r7(self) -> None:
        self.assertIn("stop_project_pmacctd_if_present", self.disable)
        self.assertIn("pmacct_core_running()", self.common)
        self.assertIn("pmacct_nfprobe_running()", self.common)
        self.assertIn("project pmacct pidfile does not identify pmacctd", self.common)
        self.assertIn("remove_project_ipfix_files", self.disable)
        self.assertIn("dns_r7_enabled", self.disable)
        self.assertNotIn("pkill", self.enable + self.disable)
        self.assertNotIn("killall", self.enable + self.disable)
        self.assertNotIn("rm -rf", self.enable + self.disable)

    def test_dependency_checker_uses_pmacct_not_softflowd(self) -> None:
        checker = CHECKER.read_text(encoding="utf-8")
        self.assertIn("pmacctd", checker)
        self.assertNotIn("softflowd", checker)
        self.assertNotIn("softflowctl", checker)

    def test_no_host_service_manipulation_or_normal_softflowd_path(self) -> None:
        combined = self.enable + self.disable + self.integration_test
        self.assertNotIn("softflowctl", combined)
        self.assertNotIn("systemctl start", combined)
        self.assertNotIn("systemctl stop", combined)
        self.assertNotIn("systemctl enable", combined)
        self.assertNotIn("systemctl disable", combined)

    def test_receiver_decodes_template_and_pre_nat_record(self) -> None:
        receiver_spec = importlib.util.spec_from_file_location("ipfix_receiver", IPFIX_RECEIVER)
        receiver_module = importlib.util.module_from_spec(receiver_spec)
        assert receiver_spec.loader
        receiver_spec.loader.exec_module(receiver_module)
        fields = ((1, 8), (2, 8), (4, 1), (6, 2), (7, 2), (8, 4),
                  (11, 2), (12, 4), (152, 8), (153, 8))
        template_record = struct.pack("!HH", 1024, len(fields)) + b"".join(
            struct.pack("!HH", element, length) for element, length in fields
        )
        template_set = struct.pack("!HH", 2, len(template_record) + 4) + template_record
        values = (1234, 12, 6, 0x12, 53000, 0x0A000064, 53, 0xC0000201, 1000, 2000)
        record = b"".join(value.to_bytes(length, "big") for value, (_element, length) in zip(values, fields))
        data_set = struct.pack("!HH", 1024, len(record) + 5) + record + b"\0"
        length = 16 + len(template_set) + len(data_set)
        packet = struct.pack("!HHIII", 10, length, 0, 0, 0) + template_set + data_set
        validator = receiver_module.IPFIXValidator()
        validator.consume(packet)
        result = validator.result("10.0.0.100")
        self.assertTrue(result["required_fields_complete"])
        self.assertTrue(result["client_source_preserved"])
        self.assertEqual(result["records"], 1)
        self.assertEqual(result["observation_domains"], [0])

    def test_receiver_discovers_domain_and_rejects_inconsistency(self) -> None:
        receiver_spec = importlib.util.spec_from_file_location("ipfix_receiver_domain", IPFIX_RECEIVER)
        receiver_module = importlib.util.module_from_spec(receiver_spec)
        assert receiver_spec.loader
        receiver_spec.loader.exec_module(receiver_module)
        validator = receiver_module.IPFIXValidator()
        validator.consume(struct.pack("!HHIII", 10, 16, 0, 0, 42))
        self.assertEqual(validator.result("10.0.0.100")["observation_domains"], [42])
        with self.assertRaises(receiver_module.IPFIXValidationError):
            validator.consume(struct.pack("!HHIII", 10, 16, 0, 0, 43))

    def test_receiver_rejects_non_ipfix_version(self) -> None:
        receiver_spec = importlib.util.spec_from_file_location("ipfix_receiver_bad", IPFIX_RECEIVER)
        receiver_module = importlib.util.module_from_spec(receiver_spec)
        assert receiver_spec.loader
        receiver_spec.loader.exec_module(receiver_module)
        packet = struct.pack("!HHIII", 9, 16, 0, 0, 0)
        with self.assertRaises(receiver_module.IPFIXValidationError):
            receiver_module.IPFIXValidator().consume(packet)


if __name__ == "__main__":
    unittest.main()
