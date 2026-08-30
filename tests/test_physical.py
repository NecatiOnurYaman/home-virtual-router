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

    def test_exact_owned_management_route_allows_convergence_without_ack(self) -> None:
        definitions = (
            'PHYSICAL_WAN_INTERFACE=enp2s0; PHYSICAL_LAN_INTERFACE=enp3s0; '
            'PHYSICAL_MANAGEMENT_INTERFACE_ACK=none; physical_default_route_interface(){ echo enp2s0; }; '
            'physical_management_ownership_present(){ return 0; }; '
            'physical_owned_management_route_verified(){ return 0; }'
        )
        result = self.run_function(definitions, "physical_require_management_ack")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_partial_or_drifted_management_ownership_fails_closed(self) -> None:
        definitions = (
            'PHYSICAL_WAN_INTERFACE=enp2s0; PHYSICAL_LAN_INTERFACE=enp3s0; '
            'PHYSICAL_MANAGEMENT_INTERFACE_ACK=none; physical_default_route_interface(){ echo enp2s0; }; '
            'physical_management_ownership_present(){ return 0; }; '
            'physical_owned_management_route_verified(){ return 1; }'
        )
        result = self.run_function(definitions, "physical_require_management_ack")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ownership mismatch", result.stderr)

    def test_management_ownership_proof_is_exact_and_live(self) -> None:
        common = PHYSICAL_COMMON.read_text(encoding="utf-8")
        proof = common[
            common.index("physical_render_map()"):
            common.index("physical_require_management_ack()")
        ]
        for evidence in (
            "MAP_VERSION=2", "ROUTER_NETNS", "WAN_IFINDEX", "WAN_MAC", "LAN_IFINDEX", "LAN_MAC",
            "WAN_ADDRESS", "WAN_GATEWAY", "LAN_ADDRESS", "PHYSICAL_DEFAULT_ROUTE_OWNED",
            "physical_single_owned_default_route_exact", "PHYSICAL_RUNTIME_STATE",
            "PHYSICAL_RUNTIME_CONFIG_SNAPSHOT", "--field deployment", "--field status",
            "--field owned", "topology", "routing", "cmp -s",
        ):
            self.assertIn(evidence, proof)
        self.assertIn("count==1 && exact==1", proof)
        topology_health = common[
            common.index("physical_topology_healthy()"):
            common.index("physical_topology_absent()")
        ]
        self.assertIn("physical_map_matches_live_config", topology_health)

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

    def test_physical_dhcp_health_accepts_standalone_and_combined_dnsmasq(self) -> None:
        common = PHYSICAL_COMMON.read_text(encoding="utf-8")
        config_health = common[
            common.index("physical_dhcp_config_healthy()"):
            common.index("physical_dhcp_listener_healthy()")
        ]
        self.assertIn('if [ -e "$DNS_ENABLED_FILE" ]', config_health)
        self.assertIn("grep -F -x 'port=53'", config_health)
        self.assertIn("grep -F -x 'port=0'", config_health)
        for shared_setting in (
            "interface=$PHYSICAL_LAN_INTERFACE", "dhcp-authoritative", "dhcp-range=",
            "dhcp-option=option:router", "dhcp-option=option:dns-server",
            "dhcp-leasefile=$DNSMASQ_LEASE_FILE", "pid-file=$DNSMASQ_PID_FILE",
        ):
            self.assertIn(shared_setting, config_health)

    def test_physical_dhcp_health_is_server_owned_and_fails_closed(self) -> None:
        common = PHYSICAL_COMMON.read_text(encoding="utf-8")
        start = common.index("physical_dnsmasq_process_healthy()")
        end = common.index("physical_prepare_dhcp_runtime()")
        health = common[start:end]
        for required in (
            "dnsmasq_dhcp_running", "process_is_in_router_namespace", "physical_topology_healthy",
            "physical_dhcp_config_healthy", "physical_dhcp_listener_healthy",
            "physical_dhcp_lease_file_healthy", "physical_ipv4_dhcp_socket_inodes",
            "physical_process_socket_inodes", "physical_socket_inodes_exactly_owned",
        ):
            self.assertIn(required, health)
        self.assertNotIn("dhclient_running", health)
        self.assertNotIn("DHCLIENT_PID_FILE", health)
        self.assertNotIn("client_dhcp_address", health)
        lease_health = health[
            health.index("physical_dhcp_lease_file_healthy()"):
            health.index("physical_dhcp_healthy()")
        ]
        self.assertNotIn("grep", lease_health)
        self.assertNotIn("cmp", lease_health)

    def test_physical_dhcp_listener_uses_ipv4_kernel_socket_inode_ownership(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            proc_root = Path(directory) / "proc"
            udp = proc_root / "net" / "udp"
            descriptors = proc_root / "123" / "fd"
            udp.parent.mkdir(parents=True)
            descriptors.mkdir(parents=True)
            udp.write_text(
                "sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n"
                "1: 00000000:0043 00000000:0000 07 00000000:00000000 00:00000000 00000000 0 0 111 2\n",
                encoding="ascii",
            )
            (descriptors / "4").symlink_to("socket:[111]")
            command = (
                f'source "{PHYSICAL_COMMON}"; '
                f'listeners="$(physical_ipv4_dhcp_socket_inodes "{udp}")"; '
                f'owned="$(physical_process_socket_inodes 123 "{proc_root}")"; '
                'physical_socket_inodes_exactly_owned "$listeners" "$owned"'
            )
            accepted = subprocess.run(["bash", "-c", command], capture_output=True, text=True, check=False)
            self.assertEqual(accepted.returncode, 0, accepted.stderr)

            with udp.open("a", encoding="ascii") as stream:
                stream.write(
                    "2: 00000000:0043 00000000:0000 07 00000000:00000000 "
                    "00:00000000 00000000 0 0 222 2\n"
                )
            rejected = subprocess.run(["bash", "-c", command], capture_output=True, text=True, check=False)
            self.assertNotEqual(rejected.returncode, 0)

    def test_listener_health_does_not_depend_on_ss_process_formatting(self) -> None:
        common = PHYSICAL_COMMON.read_text(encoding="utf-8")
        listener = common[
            common.index("physical_dhcp_listener_healthy()"):
            common.index("physical_dhcp_lease_file_healthy()")
        ]
        self.assertIn("/proc/net/udp", common)
        self.assertNotIn("ss ", listener)
        self.assertNotIn("udp6", listener)
        self.assertIn(":0043", common)

    def test_physical_dhcp_conflict_reports_predicate_diagnostics(self) -> None:
        runtime = (ROOT / "lab/scripts/runtime-common.sh").read_text(encoding="utf-8")
        common = PHYSICAL_COMMON.read_text(encoding="utf-8")
        self.assertIn("report_physical_dhcp_health", runtime)
        for diagnostic in (
            "expected steady state", "configured LAN", "configured range", "PID file",
            "executable", "starttime", "process netns", "router netns", "process identity/context",
            "configuration", "LAN topology", "DHCP listener", "lease file metadata",
            "generated dnsmasq configuration", "lease file (last 20 lines)", "LAN link/address",
            "NSpid", "process mountns", "process pidns", "router mountns", "router pidns",
            "IPv4 UDP/67 socket inodes", "verified dnsmasq socket inodes", "ss -H -lun",
            "/proc/net/udp entries", "/proc mount", "dnsmasq log (last 40 lines)",
        ):
            self.assertIn(diagnostic, common)

    def test_physical_dnsmasq_start_waits_for_strict_bounded_readiness(self) -> None:
        common = PHYSICAL_COMMON.read_text(encoding="utf-8")
        wait = common[
            common.index("physical_wait_for_dhcp_readiness()"):
            common.index("physical_start_dnsmasq()")
        ]
        start = common[
            common.index("physical_start_dnsmasq()"):
            common.index("physical_dhcp_enable()")
        ]
        self.assertIn("for attempt in {1..50}", wait)
        self.assertIn("sleep 0.05", wait)
        self.assertIn("within 2.5 seconds", wait)
        self.assertIn("physical_dhcp_healthy && return 0", wait)
        self.assertIn("process_is_running", wait)
        self.assertIn("project_process_matches", wait)
        self.assertIn("process_is_in_router_namespace", wait)
        self.assertIn("report_physical_dhcp_health", wait)
        self.assertIn("physical_wait_for_dhcp_readiness", start)
        self.assertNotIn("dnsmasq_dhcp_running || die", start)

    def test_physical_dhcp_readiness_retries_without_diagnostic_spam(self) -> None:
        definitions = (
            'attempts=0; reports=0; '
            'physical_dhcp_healthy(){ attempts=$((attempts+1)); [ "$attempts" -ge 3 ]; }; '
            'read_project_pid(){ return 1; }; sleep(){ :; }; '
            'report_physical_dhcp_health(){ reports=$((reports+1)); }'
        )
        result = self.run_function(
            definitions,
            'physical_wait_for_dhcp_readiness; [ "$attempts" -eq 3 ] && [ "$reports" -eq 0 ]',
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_physical_dhcp_readiness_times_out_or_fails_identity_early(self) -> None:
        timeout_definitions = (
            'reports=0; physical_dhcp_healthy(){ return 1; }; read_project_pid(){ return 1; }; '
            'sleep(){ :; }; report_physical_dhcp_health(){ reports=$((reports+1)); }'
        )
        timeout = self.run_function(timeout_definitions, "physical_wait_for_dhcp_readiness")
        self.assertNotEqual(timeout.returncode, 0)
        self.assertIn("within 2.5 seconds", timeout.stderr)

        fatal_definitions = (
            'checks=0; physical_dhcp_healthy(){ return 1; }; read_project_pid(){ echo 123; }; '
            'process_is_running(){ checks=$((checks+1)); return 1; }; sleep(){ checks=99; }; '
            'report_physical_dhcp_health(){ :; }'
        )
        fatal = self.run_function(fatal_definitions, "physical_wait_for_dhcp_readiness")
        self.assertNotEqual(fatal.returncode, 0)
        self.assertIn("exited or changed identity", fatal.stderr)

    def test_physical_dns_transition_sets_mode_before_readiness(self) -> None:
        common = PHYSICAL_COMMON.read_text(encoding="utf-8")
        enable = common[common.index("physical_dns_enable()") : common.index("physical_dns_disable()")]
        disable = common[common.index("physical_dns_disable()") : common.index("physical_ipfix_enable()")]
        self.assertLess(enable.index('touch "$DNS_ENABLED_FILE"'), enable.index("physical_start_dnsmasq"))
        self.assertLess(disable.index('rm -f -- "$DNS_ENABLED_FILE"'), disable.index("physical_start_dnsmasq"))

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
            "dhclient -4 -d", "client_address=", "route show default",
            "tcpdump", "ping -c 2", "dig +time=2", "nat_rule_exists",
            "filter_rules_exist", "pcap_interface: hvr-sim-lan", "show-metrics.sh",
            "runtime-status.sh", "runtime-check.sh",
        ):
            self.assertIn(proof, inner)
        for diagnostic in (
            "physical WAN address", "physical LAN address", "physical default route",
            "IPv4 forwarding", "exact HVR NAT masquerade rule",
            "complete R5 forwarding firewall rule set", "dynamic DHCP lease",
            "DHCP default gateway", "DNS query", "routed client ICMP",
            "upstream observed NAT source", "IPFIX pmacctd and nfprobe processes exist",
            "metrics LAN role", "metrics WAN role", "metrics exporter process identity",
            "repeated runtime-start", "repeated runtime-start preserves exact owned state",
            "single exact physical default route after repeated start",
            "runtime-status reports physical deployment",
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

    def test_physical_ipfix_acceptance_uses_r8_decoder_and_fresh_traffic(self) -> None:
        inner = SIMULATION_INNER.read_text(encoding="utf-8")
        for check in (
            "IPFIX core process identity", "IPFIX nfprobe child process identity", "IPFIX physical-router network context",
            "IPFIX capture interface hvr-sim-lan", "IPFIX IPv4 capture filter",
            "IPFIX nfprobe plugin", "IPFIX version 10 configuration",
            "IPFIX collector destination 203.0.113.1:4739", "IPFIX receiver readiness",
            "fresh LAN-to-WAN traffic after IPFIX receiver readiness", "IPFIX UDP export decoded",
            "IPFIX template set decoded", "IPFIX data set decoded", "IPFIX data record decoded",
            "IPFIX pre-NAT client source preserved", "IPFIX exact fresh ICMP record observed",
        ):
            self.assertIn(check, inner)
        self.assertIn('pcap_interface: hvr-sim-lan', inner)
        self.assertIn('pcap_filter: ip', inner)
        self.assertIn('plugins: nfprobe[hvr]', inner)
        self.assertIn('nfprobe_version[hvr]: 10', inner)
        self.assertIn('nfprobe_receiver[hvr]: 203.0.113.1:4739', inner)
        self.assertIn('python3 "$IPFIX_RECEIVER"', inner)
        self.assertLess(inner.index("IPFIX receiver readiness"), inner.index("fresh LAN-to-WAN traffic after IPFIX receiver readiness"))
        self.assertIn("--timeout 12", inner)
        self.assertIn('--expect-source "$client_ip"', inner)
        self.assertIn("--expect-destination 203.0.113.1", inner)
        self.assertIn("--expect-protocol 1", inner)
        self.assertIn("ipfix_result_field expected_record_seen true", inner)
        self.assertNotIn("ipfix_pre_nat_record_ok", inner)
        self.assertIn("report_ipfix_failure", inner)
        self.assertIn("source/destination pairs", inner)
        self.assertIn("sample_records_truncated", inner)
        self.assertNotIn("assert any(r.get", inner)

    def test_physical_ipfix_identity_allows_rewritten_process_titles(self) -> None:
        inner = SIMULATION_INNER.read_text(encoding="utf-8")
        start = inner.index("ipfix_process_identity_ok()")
        end = inner.index("ipfix_plugin_identity_ok()")
        core_identity = inner[start:end]
        self.assertNotIn("project_process_matches", core_identity)
        self.assertNotIn("cmdline", core_identity)
        for stable_property in (
            "IPFIX_PID_FILE", "/proc/$pid/exe", "IPFIX_CORE_STARTTIME_FILE",
            "IPFIX_CONFIG_FILE", "IPFIX_COMMAND_FILE", "Reading configuration file",
        ):
            self.assertIn(stable_property, core_identity)
        plugin_end = inner.index("ipfix_process_context_ok()")
        plugin_identity = inner[end:plugin_end]
        for stable_property in ("project_nfprobe_pids", "PPid", "/proc/$plugin_pid/exe", "IPFIX_PLUGIN_STARTTIME_FILE", "/proc/$plugin_pid/ns/net"):
            self.assertIn(stable_property, plugin_identity)
        self.assertIn("receiver result: not started or result file not present", inner)

    def test_physical_metrics_use_router_context_with_clean_diagnostics(self) -> None:
        inner = SIMULATION_INNER.read_text(encoding="utf-8")
        show = (ROOT / "lab/scripts/show-metrics.sh").read_text(encoding="utf-8")
        exporter = (ROOT / "lab/scripts/enable-metrics-export.sh").read_text(encoding="utf-8")
        common = TOPOLOGY_COMMON.read_text(encoding="utf-8")
        for check in (
            "metrics collector physical-router network context",
            "metrics LAN role hvr-sim-lan", "metrics WAN role hvr-sim-wan",
            "metrics system metrics present", "metrics LAN/WAN interface metrics present",
            "metrics exporter process identity", "metrics exporter physical-router network context",
            "metrics exporter collection health",
        ):
            self.assertIn(check, inner)
        self.assertIn("router_context_prefix", show)
        self.assertIn("router_context_prefix", exporter)
        self.assertIn('ROUTER_CONTEXT_PREFIX=(ip netns exec "$ROUTER_NAMESPACE")', common)
        self.assertIn("ROUTER_CONTEXT_PREFIX=(nsenter --net=/proc/1/ns/net --mount=/proc/1/ns/mnt --)", common)
        self.assertIn("ROUTER_CONTEXT_PREFIX=()", common)
        self.assertNotIn("hvr-sim", show + exporter)
        self.assertIn('>"$simulation_metrics_result" 2>"$simulation_metrics_error"', inner)
        self.assertLess(inner.index("collect_metrics_snapshot"), inner.index("metrics_role_ok lan"))
        self.assertIn("interfaces visible through netlink", inner)
        self.assertNotIn("json.load(sys.stdin)", inner)

    def test_simulation_mounts_private_router_sysfs_after_isolation(self) -> None:
        harness = SIMULATION.read_text(encoding="utf-8")
        inner = SIMULATION_INNER.read_text(encoding="utf-8")
        self.assertIn("unshare --mount --net --pid", harness)
        self.assertLess(inner.index("mount --make-rprivate /"), inner.index("mount -t sysfs"))
        self.assertIn("findmnt -n -o PROPAGATION /", inner)
        self.assertIn("mount -t sysfs -o nosuid,nodev,noexec sysfs /sys", inner)
        self.assertIn("metrics router netlink sees LAN/WAN", inner)
        self.assertIn("metrics router sysfs sees LAN/WAN", inner)
        self.assertIn("metrics router proc net sees LAN/WAN", inner)
        self.assertIn("/sys/class/net", inner)
        self.assertIn("/proc/net/dev", inner)
        for generic in (
            ROOT / "lab/scripts/show-metrics.sh",
            ROOT / "lab/scripts/enable-metrics-export.sh",
            ROOT / "physical/scripts/physical-common.sh",
        ):
            text = generic.read_text(encoding="utf-8")
            self.assertNotIn("mount -t sysfs", text)
            self.assertNotIn("hvr-sim", text)

    def test_simulation_client_is_prepared_and_bounded_safely(self) -> None:
        inner = SIMULATION_INNER.read_text(encoding="utf-8")
        self.assertLess(inner.index("ip link set hvr-sim-client netns"), inner.index("ip -n hvr-sim-client-ns link set hvr-sim-client up"))
        self.assertIn("ip -n hvr-sim-client-ns link set lo up", inner)
        self.assertIn("UP[^>]*LOWER_UP", inner)
        self.assertIn('install -d -o 0 -g 0 -m 0700 /run/home-virtual-router/physical-simulation', inner)
        self.assertIn('install -o 0 -g 0 -m 0600 /dev/null', inner)
        self.assertIn('install -o 0 -g 0 -m 0700 "$repo_dir/physical/scripts/simulation-dhclient-hook.sh"', inner)
        self.assertIn('/run/home-virtual-router/physical-simulation/dhclient -4 -d -v', inner)
        self.assertIn("for _attempt in {1..150}", inner)
        self.assertIn("simulation_dhclient_matches", inner)
        self.assertIn("exact simulation dhclient termination", inner)
        self.assertIn("DHCPDISCOVER DHCPOFFER DHCPREQUEST DHCPACK", inner)
        self.assertNotIn("chmod 777", inner)
        self.assertNotIn("pkill", inner)
        self.assertNotIn("killall", inner)

    def test_simulation_dhclient_identity_converges_with_diagnostics(self) -> None:
        inner = SIMULATION_INNER.read_text(encoding="utf-8")
        self.assertIn('readlink -f "/proc/$pid/exe"', inner)
        self.assertIn("process_has_exact_argument", inner)
        for argument in ("-d", "-pf", "dhclient.pid", "-lf", "dhclient.leases", "-sf", "dhclient-hook", "hvr-sim-client"):
            self.assertIn(argument, inner)
        self.assertIn('readlink "/proc/$pid/ns/net"', inner)
        self.assertIn("simulation_client_netns", inner)
        self.assertIn("for _attempt in {1..50}", inner)
        self.assertIn("identity_ready", inner)
        self.assertIn("report_simulation_dhclient_identity", inner)
        for diagnostic in ("expected exe", "actual exe", "expected cmdline args", "actual cmdline", "expected netns", "actual netns", "expected pidfile", "actual pidfile", "actual starttime"):
            self.assertIn(diagnostic, inner)
        self.assertIn("simulation_dhclient_starttime", inner)
        self.assertIn("$22", inner)
        self.assertNotIn("pgrep", inner)

    def test_simulation_dhcp_starts_clean_and_reports_declines(self) -> None:
        inner = SIMULATION_INNER.read_text(encoding="utf-8")
        hook = (ROOT / "physical/scripts/simulation-dhclient-hook.sh").read_text(encoding="utf-8")
        self.assertIn("simulated client has no stale IPv4 address", inner)
        self.assertIn("simulated client has no stale default route", inner)
        self.assertIn("simulated client has no stale neighbor state", inner)
        self.assertIn("DHCP pool is unused before acquisition", inner)
        self.assertIn("timeout 20", inner)
        self.assertIn("arp or icmp", inner)
        self.assertIn("DHCP/ARP diagnostic capture readiness", inner)
        for diagnostic in ("DHCP failure diagnostic", "dhclient hook log", "dnsmasq leases", "dnsmasq log", "DHCP/ARP capture"):
            self.assertIn(diagnostic, inner)
        self.assertIn("! grep -F DHCPDECLINE", inner)
        self.assertIn("client-netns", hook)
        self.assertIn("readlink /proc/self/ns/net", hook)
        self.assertNotIn("HVR_INTERNAL_PHYSICAL_SIMULATION", hook)
        for forbidden in ("ping-check false", "do-forward-updates", "arping", "chmod 777"):
            self.assertNotIn(forbidden, inner + hook)

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
