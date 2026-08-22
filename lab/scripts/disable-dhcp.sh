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
nat_rule_exists || die "R4 NAT state is required"
filter_rules_exist || die "R5 firewall state is required"
snapshot_r6_host_state

verify_host_on_exit() {
  local status=$?
  trap - EXIT
  verify_r6_host_state || status=1
  exit "$status"
}
trap verify_host_on_exit EXIT

if dhclient_running; then
  ip netns exec "$CLIENT_NAMESPACE" dhclient -4 -r -v \
    -pf "$DHCLIENT_PID_FILE" -lf "$DHCLIENT_LEASE_FILE" \
    -cf "$DHCLIENT_CONFIG" -sf "$DHCLIENT_HOOK" "$CLIENT_INTERFACE" || true
fi
if dhclient_running; then
  stop_project_process "$DHCLIENT_PID_FILE" dhclient "$CLIENT_INTERFACE"
fi
remove_client_dhcp_addresses
ip -n "$CLIENT_NAMESPACE" route del default via "$ROUTER_LAN" dev "$CLIENT_INTERFACE" 2>/dev/null || true
rm -f "$DHCLIENT_PID_FILE" "$DHCP_CLIENT_STATE_FILE" "$DHCP_CLIENT_RESOLV_FILE"

if dnsmasq_dhcp_running; then
  stop_project_process "$DNSMASQ_PID_FILE" dnsmasq "$DNSMASQ_CONFIG"
elif [ -e "$DNSMASQ_PID_FILE" ]; then
  die "dnsmasq PID file does not identify the project DHCP process"
fi

lan_prefix="${LAN_SUBNET#*/}"
ip -n "$CLIENT_NAMESPACE" address replace "$CLIENT_ADDRESS/$lan_prefix" dev "$CLIENT_INTERFACE"
ip -n "$CLIENT_NAMESPACE" route replace default via "$ROUTER_LAN" dev "$CLIENT_INTERFACE"
client_default_route_exists || die "failed to restore the R5 client default route"
ip -n "$CLIENT_NAMESPACE" -o -4 address show dev "$CLIENT_INTERFACE" |
  awk '{print $4}' | grep -F -x -- "$CLIENT_ADDRESS/$lan_prefix" >/dev/null ||
  die "failed to restore the R5 static client address"

require_r4_nat_state
filter_rules_exist || die "R5 firewall state changed unexpectedly"
verify_r6_host_state
trap - EXIT
printf 'R6 DHCP disabled; the exact R5 static client address and route were restored.\n'
