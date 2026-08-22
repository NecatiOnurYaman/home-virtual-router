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
command -v ip >/dev/null 2>&1 || die "iproute2 is required"
command -v nft >/dev/null 2>&1 || die "nftables is required"
command -v sysctl >/dev/null 2>&1 || die "sysctl is required"
require_r2_topology

[ "$(ip netns exec "$ROUTER_NAMESPACE" sysctl -n net.ipv4.ip_forward)" = "1" ] ||
  die "router-namespace forwarding must remain enabled to return to R3"
client_default_route_exists || die "client default route must remain present to return to R3"
if ip -n "$UPSTREAM_NAMESPACE" route show "$LAN_SUBNET" | grep -q . && ! upstream_return_route_exists; then
  die "$UPSTREAM_NAMESPACE has an unknown route to $LAN_SUBNET; refusing to modify it"
fi
table_was_present=0
if nat_table_exists; then
  nat_rule_exists || die "table ip $NAT_TABLE exists but does not match the exact R4 NAT state"
  table_was_present=1
fi

default_route_before="$(capture_default_route)"
require_default_route_is_not_lab_interface "$default_route_before"
host_forwarding_before="$(capture_host_ipv4_forwarding)"
host_nftables_before="$(capture_host_nftables)"

route_added=0
table_deleted=0
rollback_nat_disable() {
  local status=$?
  trap - EXIT INT TERM
  if [ "$table_deleted" -eq 1 ]; then
    create_project_nat_table 2>/dev/null || true
  fi
  if [ "$route_added" -eq 1 ]; then
    ip -n "$UPSTREAM_NAMESPACE" route del "$LAN_SUBNET" via "$ROUTER_WAN" dev "$UPSTREAM_INTERFACE" 2>/dev/null || true
  fi
  verify_default_route_unchanged "$default_route_before" || status=1
  verify_host_ipv4_forwarding_unchanged "$host_forwarding_before" || status=1
  verify_host_nftables_unchanged "$host_nftables_before" || status=1
  exit "$status"
}
trap rollback_nat_disable EXIT INT TERM

if ! upstream_return_route_exists; then
  ip -n "$UPSTREAM_NAMESPACE" route add "$LAN_SUBNET" via "$ROUTER_WAN" dev "$UPSTREAM_INTERFACE"
  route_added=1
fi
if [ "$table_was_present" -eq 1 ]; then
  delete_project_nat_table
  table_deleted=1
fi

if nat_table_exists; then
  die "project NAT table still exists after disable"
fi
upstream_return_route_exists || die "exact R3 upstream return route was not restored"
[ "$(ip netns exec "$ROUTER_NAMESPACE" sysctl -n net.ipv4.ip_forward)" = "1" ] ||
  die "router-namespace forwarding changed unexpectedly"
client_default_route_exists || die "client default route changed unexpectedly"
verify_default_route_unchanged "$default_route_before"
verify_host_ipv4_forwarding_unchanged "$host_forwarding_before"
verify_host_nftables_unchanged "$host_nftables_before"

route_added=0
table_deleted=0
trap - EXIT INT TERM
printf 'R4 NAT disabled; the exact R3 upstream return route has been restored.\n'
