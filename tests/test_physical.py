from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "router/scripts/validate_config.py"
PHYSICAL_COMMON = ROOT / "physical/scripts/physical-common.sh"
PHYSICAL_STAGE = ROOT / "physical/scripts/physical-stage.sh"
TOPOLOGY_COMMON = ROOT / "lab/scripts/topology-common.sh"

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
