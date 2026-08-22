#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../router/scripts/safety.sh
source "$script_dir/../../router/scripts/safety.sh"
# shellcheck source=topology-common.sh
source "$script_dir/topology-common.sh"

require_lab_environment
require_root
load_topology_config
validate_topology_names
for required_command in ip nft sysctl dnsmasq dhclient systemctl; do
  command -v "$required_command" >/dev/null 2>&1 || die "$required_command is required"
done
require_r2_topology
require_r4_nat_state
filter_rules_exist || die "exact R5 firewall state is required before DHCP"

dnsmasq_dhcp_running && die "project DHCP server is already running"
dhclient_running && die "project DHCP client is already running"
for project_pid_file in "$DNSMASQ_PID_FILE" "$DHCLIENT_PID_FILE"; do
  if stale_pid="$(read_project_pid "$project_pid_file" 2>/dev/null)" && kill -0 "$stale_pid" 2>/dev/null; then
    die "project PID file $project_pid_file references an unexpected live process"
  fi
done
for process_id in $(ip netns pids "$ROUTER_NAMESPACE"); do
  if [ "$(cat "/proc/$process_id/comm" 2>/dev/null || true)" = "dnsmasq" ]; then
    die "an unknown dnsmasq process already exists in $ROUTER_NAMESPACE"
  fi
done
for process_id in $(ip netns pids "$CLIENT_NAMESPACE"); do
  if [ "$(cat "/proc/$process_id/comm" 2>/dev/null || true)" = "dhclient" ]; then
    die "an unknown dhclient process already exists in $CLIENT_NAMESPACE"
  fi
done

lan_prefix="${LAN_SUBNET#*/}"
ip -n "$CLIENT_NAMESPACE" -o -4 address show dev "$CLIENT_INTERFACE" |
  awk '{print $4}' | grep -F -x -- "$CLIENT_ADDRESS/$lan_prefix" >/dev/null ||
  die "R6 enable requires the R5 static client address $CLIENT_ADDRESS/$lan_prefix"
client_default_route_exists || die "R6 enable requires the R5 client default route"

snapshot_r6_host_state
mkdir -p "$DHCP_RUNTIME_DIR"
chown dnsmasq:dnsmasq "$DHCP_RUNTIME_DIR"
chmod 0755 "$DHCP_RUNTIME_DIR"
rm -f "$DNSMASQ_PID_FILE" "$DHCLIENT_PID_FILE" "$DHCP_CLIENT_STATE_FILE" "$DHCP_CLIENT_RESOLV_FILE"
touch "$DNSMASQ_LEASE_FILE" "$DNSMASQ_LOG_FILE"
chown dnsmasq:dnsmasq "$DNSMASQ_LEASE_FILE" "$DNSMASQ_LOG_FILE"
render_dnsmasq_config
ip netns exec "$ROUTER_NAMESPACE" dnsmasq --test --conf-file="$DNSMASQ_CONFIG" >/dev/null

dnsmasq_started=0
static_removed=0
rollback_dhcp_enable() {
  local status=$?
  trap - EXIT INT TERM
  if dhclient_running; then
    stop_project_process "$DHCLIENT_PID_FILE" dhclient "$CLIENT_INTERFACE" 2>/dev/null || true
  fi
  remove_client_dhcp_addresses 2>/dev/null || true
  ip -n "$CLIENT_NAMESPACE" route del default via "$ROUTER_LAN" dev "$CLIENT_INTERFACE" 2>/dev/null || true
  rm -f "$DHCP_CLIENT_STATE_FILE" "$DHCP_CLIENT_RESOLV_FILE"
  if [ "$static_removed" -eq 1 ]; then
    ip -n "$CLIENT_NAMESPACE" address replace "$CLIENT_ADDRESS/$lan_prefix" dev "$CLIENT_INTERFACE" 2>/dev/null || true
    ip -n "$CLIENT_NAMESPACE" route replace default via "$ROUTER_LAN" dev "$CLIENT_INTERFACE" 2>/dev/null || true
  fi
  if [ "$dnsmasq_started" -eq 1 ] && dnsmasq_dhcp_running; then
    stop_project_process "$DNSMASQ_PID_FILE" dnsmasq "$DNSMASQ_CONFIG" 2>/dev/null || true
  fi
  verify_r6_host_state || status=1
  exit "$status"
}
trap rollback_dhcp_enable EXIT INT TERM

ip netns exec "$ROUTER_NAMESPACE" dnsmasq --conf-file="$DNSMASQ_CONFIG"
dnsmasq_started=1
dnsmasq_dhcp_running || die "project dnsmasq DHCP process did not start"

static_removed=1
ip -n "$CLIENT_NAMESPACE" route del default via "$ROUTER_LAN" dev "$CLIENT_INTERFACE"
ip -n "$CLIENT_NAMESPACE" address del "$CLIENT_ADDRESS/$lan_prefix" dev "$CLIENT_INTERFACE"

ip netns exec "$CLIENT_NAMESPACE" dhclient -4 -1 -v \
  -pf "$DHCLIENT_PID_FILE" -lf "$DHCLIENT_LEASE_FILE" \
  -cf "$DHCLIENT_CONFIG" -sf "$DHCLIENT_HOOK" "$CLIENT_INTERFACE"

dynamic_address="$(client_dhcp_address)" || die "client did not obtain exactly one /24 address from the DHCP pool"
client_default_route_exists || die "client did not learn the default route via $ROUTER_LAN"
[ "$(cat "$DHCP_CLIENT_RESOLV_FILE" 2>/dev/null)" = "nameserver $DHCP_DNS_SERVER" ] ||
  die "client did not record the advertised DNS server"
client_mac="$(ip -n "$CLIENT_NAMESPACE" -o link show dev "$CLIENT_INTERFACE" | awk '{for (i = 1; i <= NF; i++) if ($i == "link/ether") print $(i + 1)}')"
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  awk -v mac="$client_mac" -v address="$dynamic_address" \
    '$2 == mac && $3 == address && $4 == "hvr-client" { found = 1 } END { exit !found }' \
    "$DNSMASQ_LEASE_FILE" 2>/dev/null && break
  sleep 0.05
done
awk -v mac="$client_mac" -v address="$dynamic_address" \
  '$2 == mac && $3 == address && $4 == "hvr-client" { found = 1 } END { exit !found }' \
  "$DNSMASQ_LEASE_FILE" || die "dnsmasq lease does not match client MAC, address, and hostname"
dhclient_running || die "project DHCP client process is not running after lease acquisition"
verify_r6_host_state

dnsmasq_started=0
static_removed=0
trap - EXIT INT TERM
printf 'R6 DHCP enabled; hvr-client leased %s/24 with gateway %s.\n' "$dynamic_address" "$ROUTER_LAN"
