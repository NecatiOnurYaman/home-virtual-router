#!/usr/bin/env bash
set -euo pipefail
repo_dir="$1" simulation_config="$2" outer_net_namespace="$3" outer_mount_namespace="$4"
for command in ip nft sysctl dnsmasq dhclient dig ping tcpdump python3; do
  command -v "$command" >/dev/null || { echo "error: physical simulation requires $command" >&2; exit 1; }
done
mount --make-rprivate /
mount -t tmpfs tmpfs /run
mkdir -p /run/home-virtual-router
export HVR_INTERNAL_PHYSICAL_SIMULATION=1
export HVR_INTERNAL_SIMULATION_CONFIG="$simulation_config"
export HVR_INTERNAL_OUTER_NET_NAMESPACE="$outer_net_namespace"
export HVR_INTERNAL_OUTER_MOUNT_NAMESPACE="$outer_mount_namespace"
check() {
  local label="$1"
  shift
  printf 'CHECK: %s ... ' "$label"
  if "$@"; then echo PASS; else echo FAIL >&2; echo "error: R13 physical simulation check failed: $label" >&2; return 1; fi
}
wan_address_ok() { ip -o -4 address show dev hvr-sim-wan | awk '{print $4}' | grep -F -x '203.0.113.2/24' >/dev/null; }
lan_address_ok() { ip -o -4 address show dev hvr-sim-lan | awk '{print $4}' | grep -F -x '10.0.0.1/24' >/dev/null; }
default_route_ok() { ip -o -4 route show default | grep -E '^default via 203\.0\.113\.1 dev hvr-sim-wan([[:space:]]|$)' >/dev/null; }
forwarding_ok() { [ "$(sysctl -n net.ipv4.ip_forward)" = 1 ]; }
runtime_state_physical() { [ "$(python3 "$repo_dir/router/runtime/state.py" show /run/home-virtual-router/runtime/state.env --field deployment)" = physical ]; }
dhcp_lease_ok() {
  client_address="$(ip -n hvr-sim-client-ns -o -4 address show dev hvr-sim-client scope global | awk '{print $4}')"
  case "$client_address" in 10.0.0.1??/24) ;; *) return 1 ;; esac
  [ "$client_address" != 10.0.0.10/24 ]
}
dhcp_route_ok() { ip -n hvr-sim-client-ns route show default | grep -E '^default via 10\.0\.0\.1 dev hvr-sim-client([[:space:]]|$)' >/dev/null; }
client_namespace_exists() { ip netns list | awk '{print $1}' | grep -F -x hvr-sim-client-ns >/dev/null; }
client_interface_exists() { ip -n hvr-sim-client-ns link show dev hvr-sim-client >/dev/null 2>&1; }
client_interface_up() { ip -n hvr-sim-client-ns -o link show dev hvr-sim-client | grep -q '<[^>]*UP[^>]*LOWER_UP[^>]*>'; }
client_runtime_safe() {
  [ "$(stat -c %u:%g:%a /run/home-virtual-router/physical-simulation)" = 0:0:700 ] &&
    [ "$(stat -c %u:%g:%a /run/home-virtual-router/physical-simulation/dhclient.leases)" = 0:0:600 ] &&
    [ "$(stat -c %u:%g:%a /run/home-virtual-router/physical-simulation/dhclient.pid)" = 0:0:600 ]
}
simulation_hook_executable() {
  [ "$(stat -c %u:%g:%a /run/home-virtual-router/physical-simulation/dhclient-hook)" = 0:0:700 ] &&
    [ -x /run/home-virtual-router/physical-simulation/dhclient-hook ]
}
simulation_dhclient_matches() {
  local pid="$1" executable command_line
  [ -e "/proc/$pid/exe" ] || return 1
  executable="$(readlink "/proc/$pid/exe")" || return 1
  [ "$executable" = /run/home-virtual-router/physical-simulation/dhclient ] || return 1
  command_line="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
  printf '%s\n' "$command_line" | grep -F -- 'hvr-sim-client' >/dev/null
}
stop_simulation_dhclient() {
  local pid="$1" attempt
  simulation_dhclient_matches "$pid" || return 1
  kill "$pid"
  for attempt in {1..50}; do
    if ! kill -0 "$pid" 2>/dev/null || [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)" = Z ]; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.1
  done
  return 1
}
dhcp_dora_ok() {
  local log=/run/home-virtual-router/physical-simulation/dhclient.log marker
  for marker in DHCPDISCOVER DHCPOFFER DHCPREQUEST DHCPACK; do grep -F "$marker" "$log" >/dev/null || return 1; done
}
dns_query_ok() { ip netns exec hvr-sim-client-ns dig +time=2 +tries=1 @10.0.0.1 example.test A +short | grep -F -x 192.0.2.123 >/dev/null; }
ipfix_capture_ok() {
  pmacctd_running && assert_single_project_pmacct_pair >/dev/null 2>&1 &&
    grep -F -x 'interface=hvr-sim-lan' "$IPFIX_CONFIG_FILE" >/dev/null &&
    grep -F -x 'nfprobe_version[hvr]: 10' "$IPFIX_CONFIG_FILE" >/dev/null
}
metrics_role_ok() {
  "$repo_dir/lab/scripts/show-metrics.sh" |
    python3 -c 'import json,sys; role,name=sys.argv[1:]; d=json.load(sys.stdin); m=d["router"]["metrics"]; pairs={(x["interface"]["role"],x["interface"]["name"]) for x in m if "interface" in x}; assert (role,name) in pairs' "$1" "$2"
}
runtime_status_physical() { "$repo_dir/lab/scripts/runtime-status.sh" | grep -F -x 'Recorded deployment: physical' >/dev/null; }
physical_runtime_absent() {
  ! physical_address_exists hvr-sim-wan 203.0.113.2/24 &&
    ! physical_address_exists hvr-sim-lan 10.0.0.1/24 &&
    ! nat_table_exists && ! filter_table_exists && [ ! -e "$RUNTIME_STATE_FILE" ]
}
cleanup() {
  set +e
  "$repo_dir/lab/scripts/runtime-stop.sh" >/dev/null 2>&1
  [ -z "${simulation_dhclient_pid:-}" ] || stop_simulation_dhclient "$simulation_dhclient_pid" 2>/dev/null
  [ ! -s /run/home-virtual-router/physical-simulation/upstream-dnsmasq.pid ] ||
    kill "$(cat /run/home-virtual-router/physical-simulation/upstream-dnsmasq.pid)" 2>/dev/null
  ip netns del hvr-sim-client-ns 2>/dev/null
  ip netns del hvr-sim-upstream-ns 2>/dev/null
}
trap cleanup EXIT
ip netns add hvr-sim-client-ns
ip netns add hvr-sim-upstream-ns
ip link add hvr-sim-wan type veth peer name hvr-sim-up
ip link add hvr-sim-lan type veth peer name hvr-sim-client
ip link set hvr-sim-up netns hvr-sim-upstream-ns
ip link set hvr-sim-client netns hvr-sim-client-ns
ip -n hvr-sim-client-ns link set lo up
ip -n hvr-sim-client-ns link set hvr-sim-client up
ip -n hvr-sim-upstream-ns address add 203.0.113.1/24 dev hvr-sim-up
ip -n hvr-sim-upstream-ns link set lo up
ip -n hvr-sim-upstream-ns link set hvr-sim-up up
ip -n hvr-sim-upstream-ns route add default via 203.0.113.2 dev hvr-sim-up
install -d -o 0 -g 0 -m 0700 /run/home-virtual-router/physical-simulation
dhclient_source="$(command -v dhclient)"
case "$dhclient_source" in /sbin/dhclient|/usr/sbin/dhclient) ;; *) echo "error: untrusted dhclient path: $dhclient_source" >&2; exit 1 ;; esac
install -o 0 -g 0 -m 0755 "$dhclient_source" /run/home-virtual-router/physical-simulation/dhclient
install -o 0 -g 0 -m 0700 "$repo_dir/physical/scripts/simulation-dhclient-hook.sh" \
  /run/home-virtual-router/physical-simulation/dhclient-hook
install -o 0 -g 0 -m 0600 /dev/null /run/home-virtual-router/physical-simulation/dhclient.leases
install -o 0 -g 0 -m 0600 /dev/null /run/home-virtual-router/physical-simulation/dhclient.pid
cat > /run/home-virtual-router/physical-simulation/upstream-dnsmasq.conf <<'EOF'
port=53
interface=hvr-sim-up
listen-address=203.0.113.1
bind-interfaces
no-resolv
no-hosts
cache-size=0
address=/example.test/192.0.2.123
pid-file=/run/home-virtual-router/physical-simulation/upstream-dnsmasq.pid
EOF
ip netns exec hvr-sim-upstream-ns dnsmasq --conf-file=/run/home-virtual-router/physical-simulation/upstream-dnsmasq.conf
source "$repo_dir/physical/scripts/physical-common.sh"
load_topology_config
initial_forwarding="$(sysctl -n net.ipv4.ip_forward)"
check "physical preflight" "$repo_dir/physical/scripts/preflight.sh"
check "first runtime-start" "$repo_dir/lab/scripts/runtime-start.sh"
check "runtime deployment state is physical" runtime_state_physical
check "physical WAN address 203.0.113.2/24" wan_address_ok
check "physical LAN address 10.0.0.1/24" lan_address_ok
check "physical default route" default_route_ok
check "IPv4 forwarding" forwarding_ok
check "exact HVR NAT masquerade rule" nat_rule_exists
check "complete R5 forwarding firewall rule set" filter_rules_exist
check "simulated client namespace exists" client_namespace_exists
check "simulated client interface exists" client_interface_exists
check "simulated client link is up" client_interface_up
check "simulated client runtime directory and files are private" client_runtime_safe
check "simulated dhclient hook is executable" simulation_hook_executable
ip netns exec hvr-sim-client-ns env HVR_INTERNAL_PHYSICAL_SIMULATION=1 \
  /run/home-virtual-router/physical-simulation/dhclient -4 -d -v \
  -pf /run/home-virtual-router/physical-simulation/dhclient.pid \
  -lf /run/home-virtual-router/physical-simulation/dhclient.leases \
  -cf "$repo_dir/router/config/dhclient.conf" \
  -sf /run/home-virtual-router/physical-simulation/dhclient-hook hvr-sim-client \
  >/run/home-virtual-router/physical-simulation/dhclient.log 2>&1 &
simulation_dhclient_pid=$!
check "simulation dhclient process identity" simulation_dhclient_matches "$simulation_dhclient_pid"
lease_ready=0
for _attempt in {1..150}; do
  dhcp_lease_ok && { lease_ready=1; break; }
  kill -0 "$simulation_dhclient_pid" 2>/dev/null || break
  sleep 0.1
done
[ "$lease_ready" -eq 1 ] || tail -n 40 /run/home-virtual-router/physical-simulation/dhclient.log >&2
check "dynamic DHCP lease in 10.0.0.100-199/24" test "$lease_ready" -eq 1
check "DHCP discover-offer-request-ack exchange" dhcp_dora_ok
check "DHCP default gateway 10.0.0.1" dhcp_route_ok
check "exact simulation dhclient termination" stop_simulation_dhclient "$simulation_dhclient_pid"
simulation_dhclient_pid=""
check "DNS query through physical LAN" dns_query_ok
client_ip="${client_address%/*}"
wan_to_lan_blocked() { ! ip netns exec hvr-sim-upstream-ns ping -c 1 -W 1 "$client_ip" >/dev/null 2>&1; }
check "unsolicited WAN-to-LAN traffic is blocked" wan_to_lan_blocked
timeout 5 ip netns exec hvr-sim-upstream-ns tcpdump -U -n -i hvr-sim-up -c 1 \
  'icmp and src host 203.0.113.2' >/run/home-virtual-router/physical-simulation/nat-proof.txt 2>&1 &
capture_pid=$!
capture_ready=0
for _attempt in {1..50}; do grep -F 'listening on hvr-sim-up' /run/home-virtual-router/physical-simulation/nat-proof.txt >/dev/null 2>&1 && { capture_ready=1; break; }; sleep 0.1; done
check "NAT observation capture readiness" test "$capture_ready" -eq 1
check "routed client ICMP" ip netns exec hvr-sim-client-ns ping -c 2 -W 2 203.0.113.1
check "upstream observed NAT source 203.0.113.2" wait "$capture_pid"
check "IPFIX process and LAN-side capture" ipfix_capture_ok
check "metrics LAN role hvr-sim-lan" metrics_role_ok lan hvr-sim-lan
check "metrics WAN role hvr-sim-wan" metrics_role_ok wan hvr-sim-wan
check "metrics exporter process identity" metrics_exporter_running
check "repeated runtime-start" "$repo_dir/lab/scripts/runtime-start.sh"
check "runtime-status reports physical deployment" runtime_status_physical
check "runtime-check" "$repo_dir/lab/scripts/runtime-check.sh"
check "first runtime-stop" "$repo_dir/lab/scripts/runtime-stop.sh"
check "second runtime-stop" "$repo_dir/lab/scripts/runtime-stop.sh"
check "runtime-owned physical teardown" physical_runtime_absent
check "IPv4 forwarding restoration" test "$(sysctl -n net.ipv4.ip_forward)" = "$initial_forwarding"
trap - EXIT
cleanup
check "simulation client namespace cleanup" test ! -e /run/netns/hvr-sim-client-ns
check "simulation upstream namespace cleanup" test ! -e /run/netns/hvr-sim-upstream-ns
echo "R13 physical simulation acceptance passed inside isolated namespaces."
