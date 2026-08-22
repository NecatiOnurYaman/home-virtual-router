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
command -v sysctl >/dev/null 2>&1 || die "sysctl is required"
require_r2_topology

default_route_before="$(capture_default_route)"
require_default_route_is_not_lab_interface "$default_route_before"
host_forwarding_before="$(capture_host_ipv4_forwarding)"

router_forwarding="$(ip netns exec "$ROUTER_NAMESPACE" sysctl -n net.ipv4.ip_forward)"
[ "$router_forwarding" = "0" ] || die "R3 routing is already enabled or $ROUTER_NAMESPACE is not in R2 state"
if ip -n "$CLIENT_NAMESPACE" route show default | grep -q .; then
  die "$CLIENT_NAMESPACE already has a default route; refusing to replace it"
fi
if ip -n "$UPSTREAM_NAMESPACE" route show "$LAN_SUBNET" | grep -q .; then
  die "$UPSTREAM_NAMESPACE already has a route to $LAN_SUBNET; refusing to replace it"
fi

changed=0
rollback_routing() {
  local status=$?
  trap - EXIT INT TERM
  if [ "$changed" -eq 1 ]; then
    printf 'R3 enable failed; removing only exact R3 routes and disabling router-namespace forwarding...\n' >&2
    ip -n "$CLIENT_NAMESPACE" route del default via "$ROUTER_LAN" dev "$CLIENT_INTERFACE" 2>/dev/null || true
    ip -n "$UPSTREAM_NAMESPACE" route del "$LAN_SUBNET" via "$ROUTER_WAN" dev "$UPSTREAM_INTERFACE" 2>/dev/null || true
    ip netns exec "$ROUTER_NAMESPACE" sysctl -q -w net.ipv4.ip_forward=0 2>/dev/null || true
  fi
  verify_default_route_unchanged "$default_route_before" || status=1
  verify_host_ipv4_forwarding_unchanged "$host_forwarding_before" || status=1
  exit "$status"
}
trap rollback_routing EXIT INT TERM
changed=1

ip -n "$CLIENT_NAMESPACE" route add default via "$ROUTER_LAN" dev "$CLIENT_INTERFACE"
ip -n "$UPSTREAM_NAMESPACE" route add "$LAN_SUBNET" via "$ROUTER_WAN" dev "$UPSTREAM_INTERFACE"
ip netns exec "$ROUTER_NAMESPACE" sysctl -q -w net.ipv4.ip_forward=1

[ "$(ip netns exec "$ROUTER_NAMESPACE" sysctl -n net.ipv4.ip_forward)" = "1" ] ||
  die "failed to enable IPv4 forwarding in $ROUTER_NAMESPACE"
client_default_route_exists || die "exact client default route was not installed"
upstream_return_route_exists || die "exact upstream return route was not installed"
verify_default_route_unchanged "$default_route_before"
verify_host_ipv4_forwarding_unchanged "$host_forwarding_before"

changed=0
trap - EXIT INT TERM
printf 'R3 routing enabled inside lab namespaces only. No NAT or firewall rules were added.\n'
