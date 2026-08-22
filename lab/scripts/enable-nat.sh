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
  die "R3 router-namespace forwarding must be enabled before NAT"
client_default_route_exists || die "exact R3 client default route is required before NAT"
if ip -n "$UPSTREAM_NAMESPACE" route show "$LAN_SUBNET" | grep -q . && ! upstream_return_route_exists; then
  die "$UPSTREAM_NAMESPACE has an unknown route to $LAN_SUBNET; refusing to replace it"
fi
if nat_table_exists; then
  die "nftables table ip $NAT_TABLE already exists in $ROUTER_NAMESPACE; refusing conflicting state"
fi

default_route_before="$(capture_default_route)"
require_default_route_is_not_lab_interface "$default_route_before"
host_forwarding_before="$(capture_host_ipv4_forwarding)"
host_nftables_before="$(capture_host_nftables)"

route_removed=0
table_created=0
rollback_nat_enable() {
  local status=$?
  trap - EXIT INT TERM
  if [ "$table_created" -eq 1 ]; then
    delete_project_nat_table 2>/dev/null || true
  fi
  if [ "$route_removed" -eq 1 ]; then
    ip -n "$UPSTREAM_NAMESPACE" route add "$LAN_SUBNET" via "$ROUTER_WAN" dev "$UPSTREAM_INTERFACE" 2>/dev/null || true
  fi
  verify_default_route_unchanged "$default_route_before" || status=1
  verify_host_ipv4_forwarding_unchanged "$host_forwarding_before" || status=1
  verify_host_nftables_unchanged "$host_nftables_before" || status=1
  exit "$status"
}
trap rollback_nat_enable EXIT INT TERM

if upstream_return_route_exists; then
  ip -n "$UPSTREAM_NAMESPACE" route del "$LAN_SUBNET" via "$ROUTER_WAN" dev "$UPSTREAM_INTERFACE"
  route_removed=1
fi
table_created=1
create_project_nat_table

nat_rule_exists || die "exact R4 masquerade rule was not created"
if ip -n "$UPSTREAM_NAMESPACE" route show "$LAN_SUBNET" | grep -q .; then
  die "upstream LAN return route still exists after enabling NAT"
fi
[ "$(ip netns exec "$ROUTER_NAMESPACE" sysctl -n net.ipv4.ip_forward)" = "1" ] ||
  die "router-namespace forwarding changed unexpectedly"
client_default_route_exists || die "client default route changed unexpectedly"
verify_default_route_unchanged "$default_route_before"
verify_host_ipv4_forwarding_unchanged "$host_forwarding_before"
verify_host_nftables_unchanged "$host_nftables_before"

route_removed=0
table_created=0
trap - EXIT INT TERM
printf 'R4 masquerading enabled inside hvr-router only; the upstream LAN return route is absent.\n'
