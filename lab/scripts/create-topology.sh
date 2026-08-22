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

default_route_before="$(capture_default_route)"
require_default_route_is_not_lab_interface "$default_route_before"
host_forwarding_before="$(capture_host_ipv4_forwarding)"

for namespace in "$UPSTREAM_NAMESPACE" "$ROUTER_NAMESPACE" "$CLIENT_NAMESPACE"; do
  if namespace_exists "$namespace"; then
    die "namespace already exists: $namespace; destroy the known topology explicitly first"
  fi
done
for interface in "$UPSTREAM_INTERFACE" "$ROUTER_WAN_INTERFACE" "$ROUTER_LAN_INTERFACE" "$CLIENT_INTERFACE"; do
  if host_interface_exists "$interface"; then
    die "host interface already exists: $interface; refusing to reuse it"
  fi
done

created=0
rollback() {
  local status=$?
  trap - EXIT INT TERM
  if [ "$created" -eq 1 ]; then
    printf 'Topology creation failed; removing only known partial hvr-* resources...\n' >&2
    ip netns delete "$CLIENT_NAMESPACE" 2>/dev/null || true
    ip netns delete "$ROUTER_NAMESPACE" 2>/dev/null || true
    ip netns delete "$UPSTREAM_NAMESPACE" 2>/dev/null || true
    ip link delete "$UPSTREAM_INTERFACE" 2>/dev/null || true
    ip link delete "$ROUTER_WAN_INTERFACE" 2>/dev/null || true
    ip link delete "$ROUTER_LAN_INTERFACE" 2>/dev/null || true
    ip link delete "$CLIENT_INTERFACE" 2>/dev/null || true
  fi
  verify_default_route_unchanged "$default_route_before" || status=1
  verify_host_ipv4_forwarding_unchanged "$host_forwarding_before" || status=1
  exit "$status"
}
trap rollback EXIT INT TERM
created=1

ip netns add "$UPSTREAM_NAMESPACE"
ip netns add "$ROUTER_NAMESPACE"
ip netns exec "$ROUTER_NAMESPACE" sysctl -q -w net.ipv4.ip_forward=0
ip netns add "$CLIENT_NAMESPACE"

ip link add "$UPSTREAM_INTERFACE" type veth peer name "$ROUTER_WAN_INTERFACE"
ip link add "$ROUTER_LAN_INTERFACE" type veth peer name "$CLIENT_INTERFACE"

ip link set "$UPSTREAM_INTERFACE" netns "$UPSTREAM_NAMESPACE"
ip link set "$ROUTER_WAN_INTERFACE" netns "$ROUTER_NAMESPACE"
ip link set "$ROUTER_LAN_INTERFACE" netns "$ROUTER_NAMESPACE"
ip link set "$CLIENT_INTERFACE" netns "$CLIENT_NAMESPACE"

upstream_prefix="${UPSTREAM_SUBNET#*/}"
lan_prefix="${LAN_SUBNET#*/}"
ip -n "$UPSTREAM_NAMESPACE" address add "$UPSTREAM_GATEWAY/$upstream_prefix" dev "$UPSTREAM_INTERFACE"
ip -n "$ROUTER_NAMESPACE" address add "$ROUTER_WAN/$upstream_prefix" dev "$ROUTER_WAN_INTERFACE"
ip -n "$ROUTER_NAMESPACE" address add "$ROUTER_LAN/$lan_prefix" dev "$ROUTER_LAN_INTERFACE"
ip -n "$CLIENT_NAMESPACE" address add "$CLIENT_ADDRESS/$lan_prefix" dev "$CLIENT_INTERFACE"

for namespace in "$UPSTREAM_NAMESPACE" "$ROUTER_NAMESPACE" "$CLIENT_NAMESPACE"; do
  ip -n "$namespace" link set lo up
done
ip -n "$UPSTREAM_NAMESPACE" link set "$UPSTREAM_INTERFACE" up
ip -n "$ROUTER_NAMESPACE" link set "$ROUTER_WAN_INTERFACE" up
ip -n "$ROUTER_NAMESPACE" link set "$ROUTER_LAN_INTERFACE" up
ip -n "$CLIENT_NAMESPACE" link set "$CLIENT_INTERFACE" up

if [ "$(ip netns exec "$ROUTER_NAMESPACE" sysctl -n net.ipv4.ip_forward)" != "0" ]; then
  die "IPv4 forwarding is unexpectedly enabled in $ROUTER_NAMESPACE"
fi
verify_default_route_unchanged "$default_route_before"
verify_host_ipv4_forwarding_unchanged "$host_forwarding_before"
created=0
trap - EXIT INT TERM
printf 'R2 namespace topology created. IP forwarding, default routes, NAT, and firewall rules remain disabled.\n'
