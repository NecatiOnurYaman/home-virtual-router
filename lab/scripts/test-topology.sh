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

for namespace in "$UPSTREAM_NAMESPACE" "$ROUTER_NAMESPACE" "$CLIENT_NAMESPACE"; do
  namespace_exists "$namespace" || die "required namespace is absent: $namespace"
done
if [ "$(ip netns exec "$ROUTER_NAMESPACE" sysctl -n net.ipv4.ip_forward)" != "0" ]; then
  die "IPv4 forwarding is enabled unexpectedly in $ROUTER_NAMESPACE"
fi

upstream_prefix="${UPSTREAM_SUBNET#*/}"
lan_prefix="${LAN_SUBNET#*/}"
assert_interface_address() {
  local namespace="$1" interface="$2" address="$3"
  ip -n "$namespace" -o link show dev "$interface" >/dev/null
  ip -n "$namespace" -o -4 address show dev "$interface" | awk '{print $4}' | grep -F -x -- "$address" >/dev/null ||
    die "$namespace/$interface does not have expected address $address"
  ip -n "$namespace" -o link show dev "$interface" | grep -q '<[^>]*UP[^>]*>' ||
    die "$namespace/$interface is not up"
}

assert_interface_address "$UPSTREAM_NAMESPACE" "$UPSTREAM_INTERFACE" "$UPSTREAM_GATEWAY/$upstream_prefix"
assert_interface_address "$ROUTER_NAMESPACE" "$ROUTER_WAN_INTERFACE" "$ROUTER_WAN/$upstream_prefix"
assert_interface_address "$ROUTER_NAMESPACE" "$ROUTER_LAN_INTERFACE" "$ROUTER_LAN/$lan_prefix"
assert_interface_address "$CLIENT_NAMESPACE" "$CLIENT_INTERFACE" "$CLIENT_ADDRESS/$lan_prefix"

for namespace in "$UPSTREAM_NAMESPACE" "$ROUTER_NAMESPACE" "$CLIENT_NAMESPACE"; do
  if ip -n "$namespace" route show default | grep -q .; then
    die "unexpected default route exists in $namespace"
  fi
done

ping_link() {
  local namespace="$1" destination="$2"
  printf 'Ping from %s to %s... ' "$namespace" "$destination"
  ip netns exec "$namespace" ping -c 2 -W 1 "$destination" >/dev/null
  printf 'ok\n'
}

ping_link "$UPSTREAM_NAMESPACE" "$ROUTER_WAN"
ping_link "$ROUTER_NAMESPACE" "$UPSTREAM_GATEWAY"
ping_link "$CLIENT_NAMESPACE" "$ROUTER_LAN"
ping_link "$ROUTER_NAMESPACE" "$CLIENT_ADDRESS"

printf 'Ping from %s to %s (must fail in R2)... ' "$CLIENT_NAMESPACE" "$UPSTREAM_GATEWAY"
if ip netns exec "$CLIENT_NAMESPACE" ping -c 1 -W 1 "$UPSTREAM_GATEWAY" >/dev/null 2>&1; then
  die "client reached upstream unexpectedly; routing/forwarding must remain disabled in R2"
fi
printf 'failed as expected\n'
printf 'R2 topology tests passed. No topology state was changed by this test.\n'
