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
simulation_ipfix_result=/run/home-virtual-router/physical-simulation/ipfix-result.json
simulation_ipfix_ready=/run/home-virtual-router/physical-simulation/ipfix-ready
simulation_ipfix_traffic=/run/home-virtual-router/physical-simulation/ipfix-traffic-start
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
client_ipv4_clean() { [ -z "$(ip -n hvr-sim-client-ns -o -4 address show dev hvr-sim-client scope global)" ]; }
client_route_clean() { ! ip -n hvr-sim-client-ns -o -4 route show default | grep -q .; }
client_neighbor_clean() { [ -z "$(ip -n hvr-sim-client-ns neigh show dev hvr-sim-client)" ]; }
simulation_pool_unused() {
  local address
  for address in $(ip -o -4 address show | awk '{sub(/\/.*/, "", $4); print $4}') \
    $(ip -n hvr-sim-client-ns -o -4 address show | awk '{sub(/\/.*/, "", $4); print $4}') \
    $(ip -n hvr-sim-upstream-ns -o -4 address show | awk '{sub(/\/.*/, "", $4); print $4}'); do
    case "$address" in 10.0.0.1??) return 1 ;; esac
  done
}
client_namespace_exists() { ip netns list | awk '{print $1}' | grep -F -x hvr-sim-client-ns >/dev/null; }
client_interface_exists() { ip -n hvr-sim-client-ns link show dev hvr-sim-client >/dev/null 2>&1; }
client_interface_up() { ip -n hvr-sim-client-ns -o link show dev hvr-sim-client | grep -q '<[^>]*UP[^>]*LOWER_UP[^>]*>'; }
client_runtime_safe() {
  [ "$(stat -c %u:%g:%a /run/home-virtual-router/physical-simulation)" = 0:0:700 ] &&
    [ "$(stat -c %u:%g:%a /run/home-virtual-router/physical-simulation/client-netns)" = 0:0:600 ] &&
    [ "$(stat -c %u:%g:%a /run/home-virtual-router/physical-simulation/dhclient.leases)" = 0:0:600 ] &&
    [ "$(stat -c %u:%g:%a /run/home-virtual-router/physical-simulation/dhclient.pid)" = 0:0:600 ]
}
simulation_hook_executable() {
  [ "$(stat -c %u:%g:%a /run/home-virtual-router/physical-simulation/dhclient-hook)" = 0:0:700 ] &&
    [ -x /run/home-virtual-router/physical-simulation/dhclient-hook ]
}
process_has_exact_argument() {
  local pid="$1" expected="$2" argument
  while IFS= read -r -d '' argument; do [ "$argument" = "$expected" ] && return 0; done < "/proc/$pid/cmdline"
  return 1
}
simulation_dhclient_candidate_matches() {
  local pid="$1" executable actual_netns
  [ -e "/proc/$pid/exe" ] || return 1
  executable="$(readlink -f "/proc/$pid/exe")" || return 1
  [ "$executable" = /run/home-virtual-router/physical-simulation/dhclient ] || return 1
  for expected in -d -pf /run/home-virtual-router/physical-simulation/dhclient.pid \
    -lf /run/home-virtual-router/physical-simulation/dhclient.leases \
    -sf /run/home-virtual-router/physical-simulation/dhclient-hook hvr-sim-client; do
    process_has_exact_argument "$pid" "$expected" || return 1
  done
  actual_netns="$(readlink "/proc/$pid/ns/net")" || return 1
  [ "$actual_netns" = "$simulation_client_netns" ] || return 1
  [ "$(cat /run/home-virtual-router/physical-simulation/dhclient.pid 2>/dev/null)" = "$pid" ]
}
simulation_dhclient_matches() {
  local pid="$1" expected_starttime="$2"
  simulation_dhclient_candidate_matches "$pid" || return 1
  [ "$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$expected_starttime" ]
}
report_simulation_dhclient_identity() {
  local pid="$1" actual_exe="<exited>" actual_cmdline="<exited>" actual_netns="<exited>" actual_starttime="<exited>" pidfile="<absent>"
  [ ! -e "/proc/$pid/exe" ] || actual_exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo '<unreadable>')"
  [ ! -r "/proc/$pid/cmdline" ] || actual_cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
  [ ! -e "/proc/$pid/ns/net" ] || actual_netns="$(readlink "/proc/$pid/ns/net" 2>/dev/null || echo '<unreadable>')"
  [ ! -r "/proc/$pid/stat" ] || actual_starttime="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || echo '<unreadable>')"
  [ ! -r /run/home-virtual-router/physical-simulation/dhclient.pid ] || pidfile="$(cat /run/home-virtual-router/physical-simulation/dhclient.pid)"
  printf 'dhclient identity diagnostic:\n  PID: %s\n  expected exe: %s\n  actual exe: %s\n  expected cmdline args: %s\n  actual cmdline: %s\n  expected netns: %s\n  actual netns: %s\n  expected pidfile: %s\n  actual pidfile: %s\n  actual starttime: %s\n' \
    "$pid" /run/home-virtual-router/physical-simulation/dhclient \
    "$actual_exe" '-d -pf .../dhclient.pid -lf .../dhclient.leases -sf .../dhclient-hook hvr-sim-client' \
    "$actual_cmdline" "$simulation_client_netns" "$actual_netns" "$pid" "$pidfile" "$actual_starttime" >&2
}
stop_simulation_dhclient() {
  local pid="$1" expected_starttime="$2" attempt
  simulation_dhclient_matches "$pid" "$expected_starttime" || { report_simulation_dhclient_identity "$pid"; return 1; }
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
  ! grep -F DHCPDECLINE "$log" >/dev/null
}
report_dhcp_failure() {
  echo 'DHCP failure diagnostic:' >&2
  ip -n hvr-sim-client-ns -details link show dev hvr-sim-client >&2 || true
  ip -n hvr-sim-client-ns -4 address show dev hvr-sim-client >&2 || true
  ip -n hvr-sim-client-ns -4 route show >&2 || true
  ip -n hvr-sim-client-ns neigh show >&2 || true
  for setting in proxy_arp arp_ignore arp_announce arp_filter; do
    printf 'net.ipv4.conf.all.%s=%s\n' "$setting" "$(sysctl -n "net.ipv4.conf.all.$setting" 2>/dev/null || echo unreadable)" >&2
    printf 'net.ipv4.conf.hvr-sim-lan.%s=%s\n' "$setting" "$(sysctl -n "net.ipv4.conf.hvr-sim-lan.$setting" 2>/dev/null || echo unreadable)" >&2
  done
  echo 'dhclient log:' >&2; tail -n 40 /run/home-virtual-router/physical-simulation/dhclient.log >&2 || true
  echo 'dhclient hook log:' >&2; cat /run/home-virtual-router/physical-simulation/dhclient-hook.log >&2 || true
  echo 'dnsmasq leases:' >&2; cat "$DNSMASQ_LEASE_FILE" >&2 || true
  echo 'dnsmasq log:' >&2; tail -n 40 "$DNSMASQ_LOG_FILE" >&2 || true
  echo 'DHCP/ARP capture:' >&2; tail -n 80 /run/home-virtual-router/physical-simulation/dhcp-packets.log >&2 || true
}
dns_query_ok() { ip netns exec hvr-sim-client-ns dig +time=2 +tries=1 @10.0.0.1 example.test A +short | grep -F -x 192.0.2.123 >/dev/null; }
ipfix_process_identity_ok() {
  local pid expected_executable actual_executable recorded_starttime
  pid="$(read_project_pid "$IPFIX_PID_FILE")" || return 1
  process_is_running "$pid" && process_is_pmacctd "$pid" || return 1
  expected_executable="$(readlink -f "$(command -v pmacctd)")" || return 1
  actual_executable="$(readlink -f "/proc/$pid/exe")" || return 1
  [ "$actual_executable" = "$expected_executable" ] || return 1
  recorded_starttime="$(cat "$IPFIX_CORE_STARTTIME_FILE")" || return 1
  [ "$(process_starttime "$pid")" = "$recorded_starttime" ] || return 1
  [ -r "$IPFIX_CONFIG_FILE" ] && [ -r "$IPFIX_COMMAND_FILE" ] || return 1
  grep -F -- "pmacctd -f $IPFIX_CONFIG_FILE" "$IPFIX_COMMAND_FILE" >/dev/null || return 1
  grep -F -- "Reading configuration file '$IPFIX_CONFIG_FILE'." "$IPFIX_LOG_FILE" >/dev/null
}
ipfix_plugin_identity_ok() {
  local core_pid plugin_pid expected_executable actual_executable recorded_starttime
  core_pid="$(read_project_pid "$IPFIX_PID_FILE")" || return 1
  plugin_pid="$(project_nfprobe_pids "$core_pid")" || return 1
  [ "$(printf '%s\n' "$plugin_pid" | awk 'NF {count++} END {print count+0}')" -eq 1 ] || return 1
  [ "$(awk '/^PPid:/ {print $2}' "/proc/$plugin_pid/status")" = "$core_pid" ] || return 1
  expected_executable="$(readlink -f "$(command -v pmacctd)")" || return 1
  actual_executable="$(readlink -f "/proc/$plugin_pid/exe")" || return 1
  [ "$actual_executable" = "$expected_executable" ] || return 1
  recorded_starttime="$(cat "$IPFIX_PLUGIN_STARTTIME_FILE")" || return 1
  [ "$(process_starttime "$plugin_pid")" = "$recorded_starttime" ] || return 1
  [ "$(readlink "/proc/$plugin_pid/ns/net")" = "$(readlink /proc/self/ns/net)" ]
}
ipfix_process_context_ok() {
  local pid
  pid="$(read_project_pid "$IPFIX_PID_FILE")" || return 1
  [ "$(readlink "/proc/$pid/ns/net")" = "$(readlink /proc/self/ns/net)" ]
}
ipfix_capture_interface_ok() { grep -F -x 'pcap_interface: hvr-sim-lan' "$IPFIX_CONFIG_FILE" >/dev/null; }
ipfix_ipv4_capture_ok() { grep -F -x 'pcap_filter: ip' "$IPFIX_CONFIG_FILE" >/dev/null; }
ipfix_plugin_ok() { grep -F -x 'plugins: nfprobe[hvr]' "$IPFIX_CONFIG_FILE" >/dev/null; }
ipfix_version_ok() { grep -F -x 'nfprobe_version[hvr]: 10' "$IPFIX_CONFIG_FILE" >/dev/null; }
ipfix_destination_ok() { grep -F -x 'nfprobe_receiver[hvr]: 203.0.113.1:4739' "$IPFIX_CONFIG_FILE" >/dev/null; }
ipfix_result_field() {
  python3 -c 'import json,sys; value=json.load(open(sys.argv[1]))[sys.argv[2]]; expected=sys.argv[3]; assert (isinstance(value,int) and value >= int(expected)) if expected.isdigit() else value is (expected == "true")' "$simulation_ipfix_result" "$1" "$2"
}
ipfix_pre_nat_record_ok() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); source,destination=sys.argv[2:]; assert any(r.get("sourceIPv4Address")==source and r.get("destinationIPv4Address")==destination for r in d["sample_records"])' \
    "$simulation_ipfix_result" "$client_ip" 203.0.113.1
}
report_ipfix_failure() {
  local pid="<absent>" actual_exe="<absent>" actual_cmdline="<absent>" actual_netns="<absent>" actual_starttime="<absent>"
  local plugin_pid="<absent>" plugin_exe="<absent>" plugin_cmdline="<absent>" plugin_parent="<absent>" plugin_netns="<absent>"
  pid="$(cat "$IPFIX_PID_FILE" 2>/dev/null || echo '<absent>')"
  if case "$pid" in *[!0-9]*|'') false ;; *) true ;; esac && [ -e "/proc/$pid/exe" ]; then
    actual_exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo '<unreadable>')"
    actual_cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
    actual_netns="$(readlink "/proc/$pid/ns/net" 2>/dev/null || echo '<unreadable>')"
    actual_starttime="$(process_starttime "$pid" 2>/dev/null || echo '<unreadable>')"
    plugin_pid="$(project_nfprobe_pids "$pid" 2>/dev/null | head -n 1)"
    if case "$plugin_pid" in *[!0-9]*|'') false ;; *) true ;; esac && [ -e "/proc/$plugin_pid/exe" ]; then
      plugin_exe="$(readlink -f "/proc/$plugin_pid/exe" 2>/dev/null || echo '<unreadable>')"
      plugin_cmdline="$(tr '\0' ' ' < "/proc/$plugin_pid/cmdline")"
      plugin_parent="$(awk '/^PPid:/ {print $2}' "/proc/$plugin_pid/status" 2>/dev/null || echo '<unreadable>')"
      plugin_netns="$(readlink "/proc/$plugin_pid/ns/net" 2>/dev/null || echo '<unreadable>')"
    fi
  fi
  printf 'IPFIX failure diagnostic:\n  core PID: %s\n  core executable: %s\n  core title: %s\n  core netns: %s\n  physical-router netns: %s\n  core starttime: %s\n  nfprobe PID: %s\n  nfprobe executable: %s\n  nfprobe title: %s\n  nfprobe parent: %s\n  nfprobe netns: %s\n  expected capture: hvr-sim-lan\n  expected collector: 203.0.113.1:4739\n  expected version: 10\n' \
    "$pid" "$actual_exe" "$actual_cmdline" "$actual_netns" "$(readlink /proc/self/ns/net)" "$actual_starttime" \
    "$plugin_pid" "$plugin_exe" "$plugin_cmdline" "$plugin_parent" "$plugin_netns" >&2
  echo 'generated pmacct configuration:' >&2; sed 's/^/  /' "$IPFIX_CONFIG_FILE" >&2 || true
  echo 'pmacct log tail:' >&2; tail -n 60 "$IPFIX_LOG_FILE" >&2 || true
  if [ -r "$simulation_ipfix_result" ]; then
    echo 'receiver result:' >&2; cat "$simulation_ipfix_result" >&2
  else
    echo 'receiver result: not started or result file not present' >&2
  fi
}
check_ipfix() {
  local label="$1"
  shift
  check "$label" "$@" || { report_ipfix_failure; return 1; }
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
  [ -z "${dhcp_capture_pid:-}" ] || { kill "$dhcp_capture_pid" 2>/dev/null; wait "$dhcp_capture_pid" 2>/dev/null; }
  if [ -n "${simulation_ipfix_receiver_pid:-}" ] && kill -0 "$simulation_ipfix_receiver_pid" 2>/dev/null; then
    project_process_matches "$simulation_ipfix_receiver_pid" python3 "$IPFIX_RECEIVER" && kill "$simulation_ipfix_receiver_pid" 2>/dev/null
    wait "$simulation_ipfix_receiver_pid" 2>/dev/null
  fi
  [ -z "${simulation_dhclient_pid:-}" ] || stop_simulation_dhclient "$simulation_dhclient_pid" "${simulation_dhclient_starttime:-}" 2>/dev/null
  [ ! -s /run/home-virtual-router/physical-simulation/upstream-dnsmasq.pid ] ||
    kill "$(cat /run/home-virtual-router/physical-simulation/upstream-dnsmasq.pid)" 2>/dev/null
  ip netns del hvr-sim-client-ns 2>/dev/null
  ip netns del hvr-sim-upstream-ns 2>/dev/null
}
trap cleanup EXIT
ip netns add hvr-sim-client-ns
ip netns add hvr-sim-upstream-ns
simulation_client_netns="$(ip netns exec hvr-sim-client-ns readlink /proc/self/ns/net)"
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
printf '%s\n' "$simulation_client_netns" > /run/home-virtual-router/physical-simulation/client-netns
chmod 0600 /run/home-virtual-router/physical-simulation/client-netns
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
check "simulated client has no stale IPv4 address" client_ipv4_clean
check "simulated client has no stale default route" client_route_clean
check "simulated client has no stale neighbor state" client_neighbor_clean
check "DHCP pool is unused before acquisition" simulation_pool_unused
timeout 20 ip netns exec hvr-sim-client-ns tcpdump -U -n -e -i hvr-sim-client -c 100 \
  'arp or icmp or (udp port 67 or udp port 68)' \
  >/run/home-virtual-router/physical-simulation/dhcp-packets.log 2>&1 &
dhcp_capture_pid=$!
dhcp_capture_ready=0
for _attempt in {1..50}; do
  grep -F 'listening on hvr-sim-client' /run/home-virtual-router/physical-simulation/dhcp-packets.log >/dev/null 2>&1 && { dhcp_capture_ready=1; break; }
  kill -0 "$dhcp_capture_pid" 2>/dev/null || break
  sleep 0.1
done
check "DHCP/ARP diagnostic capture readiness" test "$dhcp_capture_ready" -eq 1
ip netns exec hvr-sim-client-ns env HVR_INTERNAL_PHYSICAL_SIMULATION=1 \
  /run/home-virtual-router/physical-simulation/dhclient -4 -d -v \
  -pf /run/home-virtual-router/physical-simulation/dhclient.pid \
  -lf /run/home-virtual-router/physical-simulation/dhclient.leases \
  -cf "$repo_dir/router/config/dhclient.conf" \
  -sf /run/home-virtual-router/physical-simulation/dhclient-hook hvr-sim-client \
  >/run/home-virtual-router/physical-simulation/dhclient.log 2>&1 &
simulation_dhclient_pid=$!
identity_ready=0
for _attempt in {1..50}; do
  if simulation_dhclient_candidate_matches "$simulation_dhclient_pid"; then identity_ready=1; break; fi
  kill -0 "$simulation_dhclient_pid" 2>/dev/null || break
  sleep 0.1
done
if [ "$identity_ready" -eq 0 ]; then
  report_simulation_dhclient_identity "$simulation_dhclient_pid"
  tail -n 40 /run/home-virtual-router/physical-simulation/dhclient.log >&2
fi
check "simulation dhclient process identity" test "$identity_ready" -eq 1
simulation_dhclient_starttime="$(awk '{print $22}' "/proc/$simulation_dhclient_pid/stat")"
check "simulation dhclient PID start time" simulation_dhclient_matches "$simulation_dhclient_pid" "$simulation_dhclient_starttime"
lease_ready=0
for _attempt in {1..150}; do
  dhcp_lease_ok && { lease_ready=1; break; }
  kill -0 "$simulation_dhclient_pid" 2>/dev/null || break
  sleep 0.1
done
[ "$lease_ready" -eq 1 ] || report_dhcp_failure
check "dynamic DHCP lease in 10.0.0.100-199/24" test "$lease_ready" -eq 1
check "DHCP discover-offer-request-ack exchange" dhcp_dora_ok
check "DHCP default gateway 10.0.0.1" dhcp_route_ok
check "exact simulation dhclient termination" stop_simulation_dhclient "$simulation_dhclient_pid" "$simulation_dhclient_starttime"
simulation_dhclient_pid=""
simulation_dhclient_starttime=""
kill "$dhcp_capture_pid" 2>/dev/null || true
wait "$dhcp_capture_pid" 2>/dev/null || true
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
check_ipfix "IPFIX pmacctd and nfprobe processes exist" pmacctd_running
check_ipfix "IPFIX core process identity" ipfix_process_identity_ok
check_ipfix "IPFIX nfprobe child process identity" ipfix_plugin_identity_ok
check_ipfix "IPFIX physical-router network context" ipfix_process_context_ok
check_ipfix "IPFIX capture interface hvr-sim-lan" ipfix_capture_interface_ok
check_ipfix "IPFIX IPv4 capture filter" ipfix_ipv4_capture_ok
check_ipfix "IPFIX nfprobe plugin" ipfix_plugin_ok
check_ipfix "IPFIX version 10 configuration" ipfix_version_ok
check_ipfix "IPFIX collector destination 203.0.113.1:4739" ipfix_destination_ok
rm -f -- "$simulation_ipfix_result" "$simulation_ipfix_ready" "$simulation_ipfix_traffic"
ip netns exec hvr-sim-upstream-ns python3 "$IPFIX_RECEIVER" \
  --bind 203.0.113.1 --port 4739 --client "$client_ip" \
  --traffic-start "$simulation_ipfix_traffic" --output "$simulation_ipfix_result" \
  --ready "$simulation_ipfix_ready" --timeout 12 &
simulation_ipfix_receiver_pid=$!
receiver_ready=0
for _attempt in {1..50}; do
  [ -e "$simulation_ipfix_ready" ] && { receiver_ready=1; break; }
  kill -0 "$simulation_ipfix_receiver_pid" 2>/dev/null || break
  sleep 0.1
done
check_ipfix "IPFIX receiver readiness" test "$receiver_ready" -eq 1
touch "$simulation_ipfix_traffic"
check "fresh LAN-to-WAN traffic after IPFIX receiver readiness" \
  ip netns exec hvr-sim-client-ns ping -c 2 -W 2 203.0.113.1
receiver_status=0
wait "$simulation_ipfix_receiver_pid" || receiver_status=$?
simulation_ipfix_receiver_pid=""
[ "$receiver_status" -eq 0 ] || report_ipfix_failure
check "IPFIX UDP export decoded" test "$receiver_status" -eq 0
check "IPFIX datagram observed" ipfix_result_field datagrams 1
check "IPFIX template set decoded" ipfix_result_field template_sets 1
check "IPFIX data set decoded" ipfix_result_field data_sets 1
check "IPFIX data record decoded" ipfix_result_field records 1
check "IPFIX required template fields" ipfix_result_field required_fields_complete true
check "IPFIX pre-NAT client source preserved" ipfix_result_field client_source_preserved true
check "IPFIX LAN client to upstream record" ipfix_pre_nat_record_ok
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
