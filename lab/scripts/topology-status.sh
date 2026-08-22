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

printf 'R2 topology status (lab namespaces only)\n'
for namespace in "$UPSTREAM_NAMESPACE" "$ROUTER_NAMESPACE" "$CLIENT_NAMESPACE"; do
  printf '\n[%s]\n' "$namespace"
  if ! namespace_exists "$namespace"; then
    printf '  namespace: absent\n'
    continue
  fi
  printf '  namespace: present\n'
  printf '  links:\n'
  ip -n "$namespace" -brief link show | sed 's/^/    /'
  printf '  IPv4 addresses:\n'
  ip -n "$namespace" -brief -4 address show | sed 's/^/    /'
  printf '  IPv4 routes:\n'
  ip -n "$namespace" -4 route show | sed 's/^/    /'
done

printf '\n[R3 routing state]\n'
if namespace_exists "$ROUTER_NAMESPACE" && namespace_exists "$CLIENT_NAMESPACE" && namespace_exists "$UPSTREAM_NAMESPACE"; then
  forwarding="$(ip netns exec "$ROUTER_NAMESPACE" sysctl -n net.ipv4.ip_forward)"
  printf '  router IPv4 forwarding: %s\n' "$forwarding"
  printf '  client default route:\n'
  ip -n "$CLIENT_NAMESPACE" route show default | sed 's/^/    /'
  printf '  upstream return route to %s:\n' "$LAN_SUBNET"
  ip -n "$UPSTREAM_NAMESPACE" route show "$LAN_SUBNET" | sed 's/^/    /'
  if [ "$forwarding" = "1" ] && client_default_route_exists && upstream_return_route_exists; then
    printf '  R3 routing: enabled\n'
  else
    printf '  R3 routing: disabled or incomplete\n'
  fi
else
  printf '  R2 topology: incomplete or absent\n'
  printf '  R3 routing: unavailable\n'
fi
