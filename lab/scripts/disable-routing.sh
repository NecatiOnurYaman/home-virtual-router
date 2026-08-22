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
verify_host_state_on_exit() {
  local status=$?
  trap - EXIT
  verify_default_route_unchanged "$default_route_before" || status=1
  verify_host_ipv4_forwarding_unchanged "$host_forwarding_before" || status=1
  exit "$status"
}
trap verify_host_state_on_exit EXIT

ip netns exec "$ROUTER_NAMESPACE" sysctl -q -w net.ipv4.ip_forward=0
if client_default_route_exists; then
  ip -n "$CLIENT_NAMESPACE" route del default via "$ROUTER_LAN" dev "$CLIENT_INTERFACE"
  printf 'Removed exact client default route.\n'
fi
if upstream_return_route_exists; then
  ip -n "$UPSTREAM_NAMESPACE" route del "$LAN_SUBNET" via "$ROUTER_WAN" dev "$UPSTREAM_INTERFACE"
  printf 'Removed exact upstream return route.\n'
fi

[ "$(ip netns exec "$ROUTER_NAMESPACE" sysctl -n net.ipv4.ip_forward)" = "0" ] ||
  die "failed to disable IPv4 forwarding in $ROUTER_NAMESPACE"
if ip -n "$CLIENT_NAMESPACE" route show default | grep -q .; then
  die "$CLIENT_NAMESPACE has a non-R3 default route; it was left untouched"
fi
if ip -n "$UPSTREAM_NAMESPACE" route show "$LAN_SUBNET" | grep -q .; then
  die "$UPSTREAM_NAMESPACE has a non-R3 route to $LAN_SUBNET; it was left untouched"
fi

verify_default_route_unchanged "$default_route_before"
verify_host_ipv4_forwarding_unchanged "$host_forwarding_before"
trap - EXIT
printf 'R3 routing disabled; the topology is back in R2 routing state.\n'
