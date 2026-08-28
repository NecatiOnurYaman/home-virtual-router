from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "router/scripts/validate_config.py"
PHYSICAL_COMMON = ROOT / "physical/scripts/physical-common.sh"
PHYSICAL_STAGE = ROOT / "physical/scripts/physical-stage.sh"
SIMULATION = ROOT / "physical/scripts/test-simulation.sh"
SIMULATION_INNER = ROOT / "physical/scripts/test-simulation-inner.sh"
TOPOLOGY_COMMON = ROOT / "lab/scripts/topology-common.sh"
RUNTIME_START = ROOT / "lab/scripts/runtime-start.sh"

spec = importlib.util.spec_from_file_location("validate_config_physical", VALIDATOR)
validate_config = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(validate_config)


class PhysicalConfigTests(unittest.TestCase):
    def values(self) -> dict[str, str]:
        return validate_config.parse(ROOT / "config/physical.example.env")

    def test_example_is_physical_and_valid(self) -> None:
        values = self.values()
        validate_config.validate(values)
        self.assertEqual(values["DEPLOYMENT_MODE"], "physical")

    def test_requires_distinct_explicit_interfaces(self) -> None:
        for key, value in (
            ("PHYSICAL_WAN_INTERFACE", "unset"),
            ("PHYSICAL_LAN_INTERFACE", "lo"),
            ("PHYSICAL_LAN_INTERFACE", "enp2s0"),
            ("PHYSICAL_TELEMETRY_INTERFACE", "enp2s0"),
        ):
            with self.subTest(key=key, value=value):
                values = self.values()
                values[key] = value
                with self.assertRaises(ValueError):
                    validate_config.validate(values)

    def test_rejects_bad_mode_wan_and_unsupported_observability(self) -> None:
        for key, value in (
            ("DEPLOYMENT_MODE", "automatic"),
            ("PHYSICAL_WAN_PREFIX_LENGTH", "99"),
            ("PHYSICAL_WAN_GATEWAY", "198.51.100.1"),
            ("TELEMETRY_MODE", "observability"),
        ):
            with self.subTest(key=key):
                values = self.values()
                values[key] = value
                with self.assertRaises(ValueError):
                    validate_config.validate(values)


class PhysicalSafetyTests(unittest.TestCase):
    def run_function(self, definitions: str, function: str) -> subprocess.CompletedProcess[str]:
        command = f'source "{PHYSICAL_COMMON}"; {definitions}; {function}'
        return subprocess.run(["bash", "-c", command], capture_output=True, text=True, check=False)

    def test_management_default_requires_exact_interface_ack(self) -> None:
        definitions = (
            'PHYSICAL_WAN_INTERFACE=enp2s0; PHYSICAL_LAN_INTERFACE=enp3s0; '
            'PHYSICAL_MANAGEMENT_INTERFACE_ACK=none; physical_default_route_interface(){ echo enp2s0; }'
        )
        rejected = self.run_function(definitions, "physical_require_management_ack")
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("acknowledge that exact interface", rejected.stderr)
        accepted = self.run_function(definitions.replace("ACK=none", "ACK=enp2s0"), "physical_require_management_ack")
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

    def test_network_manager_managed_interface_is_rejected(self) -> None:
        definitions = 'nmcli(){ echo "GENERAL.STATE:100 (connected)"; }; networkctl(){ :; }'
        result = self.run_function(definitions, "physical_interface_unmanaged enp2s0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("managed by NetworkManager", result.stderr)

    def test_authorization_path_is_fixed_and_no_global_network_flush_exists(self) -> None:
        common = PHYSICAL_COMMON.read_text(encoding="utf-8")
        stage = PHYSICAL_STAGE.read_text(encoding="utf-8")
        combined = common + stage
        self.assertIn('/etc/home-virtual-router/allow-physical-deployment', common)
        for forbidden in ("nft flush ruleset", "iptables -F", "rm /etc/netplan", "systemctl stop NetworkManager"):
            self.assertNotIn(forbidden, combined)

    def test_simulation_uses_ephemeral_config_without_production_paths(self) -> None:
        harness = SIMULATION.read_text(encoding="utf-8")
        inner = SIMULATION_INNER.read_text(encoding="utf-8")
        self.assertIn('temporary="$(mktemp -d /tmp/hvr-physical-sim.XXXXXX)"', harness)
        self.assertIn('"$temporary/router.env"', harness)
        self.assertNotIn("/etc/home-virtual-router", harness + inner)
        self.assertNotIn("allow-physical-deployment", harness + inner)
        self.assertNotIn("mount --bind", inner)

    def test_simulation_override_requires_root_and_two_isolated_namespaces(self) -> None:
        topology = TOPOLOGY_COMMON.read_text(encoding="utf-8")
        common = PHYSICAL_COMMON.read_text(encoding="utf-8")
        for text in (topology, common):
            self.assertIn("HVR_INTERNAL_PHYSICAL_SIMULATION", text)
            self.assertIn("id -u", text)
            self.assertIn("/proc/self/ns/net", text)
            self.assertIn("/proc/self/ns/mnt", text)
        self.assertIn('readonly HVR_LOCAL_CONFIG="/etc/home-virtual-router/router.env"', topology)
        self.assertIn('PHYSICAL_AUTHORIZATION_MARKER="/etc/home-virtual-router/allow-physical-deployment"', common)

    def test_simulation_cleanup_is_exact_and_interfaces_are_allowlisted(self) -> None:
        harness = SIMULATION.read_text(encoding="utf-8")
        inner = SIMULATION_INNER.read_text(encoding="utf-8")
        self.assertIn("trap cleanup EXIT", harness)
        self.assertIn('rm -f -- "$temporary/router.env"', harness)
        self.assertNotIn("rm -rf", harness + inner)
        self.assertNotIn("pkill", harness + inner)
        self.assertNotIn("killall", harness + inner)
        for interface in ("hvr-sim-wan", "hvr-sim-up", "hvr-sim-lan", "hvr-sim-client"):
            self.assertIn(interface, harness + inner)

    def test_physical_dhcp_runtime_is_prepared_before_rendering(self) -> None:
        common = PHYSICAL_COMMON.read_text(encoding="utf-8")
        self.assertIn('install -d -o 0 -g 0 -m 0755 "$DHCP_RUNTIME_DIR"', common)
        enable = "physical_dhcp_enable() { resolve_dnsmasq_identity; physical_prepare_dhcp_runtime; render_dnsmasq_config; physical_start_dnsmasq; }"
        self.assertIn(enable, common)
        self.assertLess(common.index("physical_prepare_dhcp_runtime; render_dnsmasq_config"), common.index("physical_start_dnsmasq; }"))

    def test_startup_failure_captures_status_before_message_and_rolls_back_reverse(self) -> None:
        start = RUNTIME_START.read_text(encoding="utf-8")
        self.assertIn('local status="$?" stage code message', start)
        self.assertIn('message="runtime startup failed at $current_stage with exit status $status"', start)
        self.assertNotIn("status: unbound variable", start)
        self.assertIn("runtime startup failed at $current_stage", start)
        self.assertIn("printf '%s\\n' \"$started_now\" | tac", start)
        self.assertIn('runtime_write_state "$profile" failed', start)
        self.assertIn('exit "$status"', start)

        function = start[start.index("rollback() {"):start.index("\ntrap rollback EXIT")]
        with tempfile.TemporaryDirectory() as directory:
            trace = Path(directory) / "trace"
            log = Path(directory) / "startup.log"
            error = Path(directory) / "last-error"
            harness = f'''set -euo pipefail
current_stage=dhcp
started_now=$'topology\nrouting\nnat\nfirewall'
owned=topology,routing,nat,firewall
profile=lab
started_at=now
RUNTIME_LOG_FILE={log}
RUNTIME_ERROR_FILE={error}
exec 3>>{trace}
runtime_stage_state() {{ return 0; }}
runtime_disable_stage() {{ printf '%s\n' "$1" >&3; }}
runtime_remove_owned() {{ printf '%s' "$1"; }}
runtime_write_state() {{ printf 'state:%s\n' "$2" >&3; }}
tac() {{ awk '{{ lines[NR]=$0 }} END {{ for (i=NR; i>=1; i--) print lines[i] }}'; }}
{function}
trap rollback EXIT
false
'''
            result = subprocess.run(["bash", "-c", harness], capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("unbound variable", result.stderr)
            self.assertIn("runtime startup failed at dhcp with exit status 1", result.stderr)
            self.assertEqual(trace.read_text(encoding="utf-8").splitlines(), ["firewall", "nat", "routing", "topology", "state:failed"])
            self.assertIn("failed at dhcp", error.read_text(encoding="utf-8"))

    def test_simulation_exercises_functional_physical_lifecycle(self) -> None:
        inner = SIMULATION_INNER.read_text(encoding="utf-8")
        for proof in (
            "dhclient -4 -1", "client_address=", "route show default",
            "tcpdump", "ping -c 2", "dig +time=2", "nat_rule_exists",
            "filter_rules_exist", "IPFIX_CONFIG_FILE", "show-metrics.sh",
            "runtime-status.sh", "runtime-check.sh",
        ):
            self.assertIn(proof, inner)
        for diagnostic in (
            "physical WAN address", "physical LAN address", "physical default route",
            "IPv4 forwarding", "exact HVR NAT masquerade rule",
            "complete R5 forwarding firewall rule set", "dynamic DHCP lease",
            "DHCP default gateway", "DNS query", "routed client ICMP",
            "upstream observed NAT source", "IPFIX process and LAN-side capture",
            "metrics LAN role", "metrics WAN role", "metrics exporter process identity",
            "repeated runtime-start", "runtime-status reports physical deployment",
            "runtime-check", "first runtime-stop", "second runtime-stop",
            "runtime-owned physical teardown",
        ):
            self.assertIn(diagnostic, inner)
        self.assertIn("R13 physical simulation acceptance passed", inner)

    def test_runtime_output_distinguishes_deployment_from_telemetry(self) -> None:
        start = RUNTIME_START.read_text(encoding="utf-8")
        self.assertIn("Deployment mode: %s", start)
        self.assertIn("Telemetry mode: %s", start)
        self.assertNotIn("runtime is running in %s mode", start)
        inner = SIMULATION_INNER.read_text(encoding="utf-8")
        self.assertIn("runtime deployment state is physical", inner)
        self.assertIn("--field deployment", inner)

    def test_host_execution_and_exact_owned_objects(self) -> None:
        topology = TOPOLOGY_COMMON.read_text(encoding="utf-8")
        self.assertIn('if [ "$DEPLOYMENT_MODE" = "physical" ]; then nft "$@"', topology)
        self.assertIn('oifname "$ROUTER_WAN_INTERFACE" ip saddr "$LAN_SUBNET"', topology)
        self.assertIn('iifname "$ROUTER_LAN_INTERFACE" oifname "$ROUTER_WAN_INTERFACE"', topology)

    def test_forwarding_address_route_and_link_changes_are_ownership_marked(self) -> None:
        common = PHYSICAL_COMMON.read_text(encoding="utf-8")
        for marker in (
            "PHYSICAL_FORWARDING_ORIGINAL", "PHYSICAL_WAN_ADDRESS_OWNED",
            "PHYSICAL_LAN_ADDRESS_OWNED", "PHYSICAL_DEFAULT_ROUTE_OWNED",
            "PHYSICAL_WAN_LINK_OWNED", "PHYSICAL_LAN_LINK_OWNED",
        ):
            self.assertIn(marker, common)
        self.assertIn('sysctl -q -w net.ipv4.ip_forward="$original"', common)
        self.assertIn('ip route del default via "$PHYSICAL_WAN_GATEWAY"', common)
        self.assertNotIn("ip route flush", common)

    def test_dhcp_dns_templates_remain_lan_bound(self) -> None:
        common = PHYSICAL_COMMON.read_text(encoding="utf-8")
        topology = TOPOLOGY_COMMON.read_text(encoding="utf-8")
        self.assertIn("render_dnsmasq_config", common)
        self.assertIn("render_router_dns_config", common)
        self.assertIn("printf 'interface=%s", topology)
        self.assertIn('"$ROUTER_LAN_INTERFACE"', topology)


if __name__ == "__main__":
    unittest.main()
