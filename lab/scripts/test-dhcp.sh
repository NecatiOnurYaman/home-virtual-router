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
for required_command in ip nft sysctl dnsmasq dhclient ping systemctl; do
  command -v "$required_command" >/dev/null 2>&1 || die "$required_command is required"
done
require_r2_topology
nat_rule_exists || die "R4 NAT state is required"
filter_rules_exist || die "R5 firewall state is required"
dnsmasq_dhcp_running || die "project dnsmasq DHCP process is not running"
dhclient_running || die "project DHCP client process is not running"
snapshot_r6_host_state

dynamic_address="$(client_dhcp_address)" || die "client lacks exactly one /24 address from the DHCP pool"
client_default_route_exists || die "client lacks the DHCP default route via $ROUTER_LAN"
if ip -n "$CLIENT_NAMESPACE" -o -4 address show dev "$CLIENT_INTERFACE" |
  awk '{print $4}' | grep -F -x -- "$CLIENT_ADDRESS/${LAN_SUBNET#*/}" >/dev/null; then
  die "legacy static client address is still present during R6"
fi
[ "$(cat "$DHCP_CLIENT_RESOLV_FILE" 2>/dev/null)" = "nameserver $DHCP_DNS_SERVER" ] ||
  die "project client resolver state does not match DHCP option 6"

client_mac="$(ip -n "$CLIENT_NAMESPACE" -o link show dev "$CLIENT_INTERFACE" | awk '{for (i = 1; i <= NF; i++) if ($i == "link/ether") print $(i + 1)}')"
lease_entry="$(awk -v mac="$client_mac" -v address="$dynamic_address" \
  '$2 == mac && $3 == address && $4 == "hvr-client" { print; found = 1 } END { if (!found) exit 1 }' \
  "$DNSMASQ_LEASE_FILE")" || die "matching dnsmasq lease entry is absent"
set -- $lease_entry
[ "$#" -ge 5 ] || die "dnsmasq lease entry has fewer than five fields"
printf 'Lease: expiry=%s mac=%s address=%s hostname=%s client-id=%s\n' "$1" "$2" "$3" "$4" "$5"

ping_path() {
  local destination="$1"
  printf 'DHCP client ping to %s... ' "$destination"
  ip netns exec "$CLIENT_NAMESPACE" ping -c 2 -W 1 "$destination" >/dev/null
  printf 'ok\n'
}
ping_path "$ROUTER_LAN"
ping_path "$ROUTER_WAN"
ping_path "$UPSTREAM_GATEWAY"

verify_r6_host_state
printf 'R6 DHCP tests passed for dynamically leased address %s/24. DNS service was not tested.\n' "$dynamic_address"
