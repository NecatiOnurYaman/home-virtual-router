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
command -v ping >/dev/null 2>&1 || die "ping is required"
command -v sysctl >/dev/null 2>&1 || die "sysctl is required"
command -v nft >/dev/null 2>&1 || die "nft is required to verify the R3 ruleset is empty"
require_r2_topology

default_route_before="$(capture_default_route)"
require_default_route_is_not_lab_interface "$default_route_before"
host_forwarding_before="$(capture_host_ipv4_forwarding)"

[ "$(ip netns exec "$ROUTER_NAMESPACE" sysctl -n net.ipv4.ip_forward)" = "1" ] ||
  die "R3 router-namespace forwarding is not enabled"
client_default_route_exists || die "exact client default route is absent"
upstream_return_route_exists || die "exact upstream LAN return route is absent"
if [ -n "$(ip netns exec "$ROUTER_NAMESPACE" nft list ruleset)" ]; then
  die "router namespace nftables ruleset is not empty; R3 expects no firewall or NAT rules"
fi

# The router needs only the connected routes created by its two interface addresses.
ip -n "$ROUTER_NAMESPACE" route show "$UPSTREAM_SUBNET" dev "$ROUTER_WAN_INTERFACE" | grep -q . ||
  die "router connected upstream route is absent"
ip -n "$ROUTER_NAMESPACE" route show "$LAN_SUBNET" dev "$ROUTER_LAN_INTERFACE" | grep -q . ||
  die "router connected LAN route is absent"
if ip -n "$ROUTER_NAMESPACE" route show default | grep -q .; then
  die "router namespace has an unexpected default route"
fi

# Route lookup proves both cross-subnet paths select hvr-router as next hop.
ip -n "$CLIENT_NAMESPACE" route get "$UPSTREAM_GATEWAY" |
  grep -E -q "via $ROUTER_LAN .*dev $CLIENT_INTERFACE" ||
  die "client route lookup does not select the router LAN address"
ip -n "$UPSTREAM_NAMESPACE" route get "$CLIENT_ADDRESS" |
  grep -E -q "via $ROUTER_WAN .*dev $UPSTREAM_INTERFACE" ||
  die "upstream route lookup does not select the router WAN address"

ping_path() {
  local namespace="$1" destination="$2"
  printf 'Ping from %s to %s... ' "$namespace" "$destination"
  ip netns exec "$namespace" ping -c 2 -W 1 "$destination" >/dev/null
  printf 'ok\n'
}

ping_path "$CLIENT_NAMESPACE" "$ROUTER_LAN"
ping_path "$CLIENT_NAMESPACE" "$ROUTER_WAN"
ping_path "$CLIENT_NAMESPACE" "$UPSTREAM_GATEWAY"
ping_path "$UPSTREAM_NAMESPACE" "$ROUTER_WAN"
ping_path "$UPSTREAM_NAMESPACE" "$ROUTER_LAN"
ping_path "$UPSTREAM_NAMESPACE" "$CLIENT_ADDRESS"

verify_default_route_unchanged "$default_route_before"
verify_host_ipv4_forwarding_unchanged "$host_forwarding_before"
printf 'R3 bidirectional routing tests passed. No NAT or firewall configuration was used.\n'
