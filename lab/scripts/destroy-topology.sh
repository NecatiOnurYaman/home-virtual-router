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

default_route_before="$(capture_default_route)"
require_default_route_is_not_lab_interface "$default_route_before"
verify_route_on_exit() {
  local status=$?
  trap - EXIT
  verify_default_route_unchanged "$default_route_before" || status=1
  exit "$status"
}
trap verify_route_on_exit EXIT

printf 'Removing only the configured R2 namespaces and any exact-name partial veth endpoints...\n'
for namespace in "$CLIENT_NAMESPACE" "$ROUTER_NAMESPACE" "$UPSTREAM_NAMESPACE"; do
  is_known_namespace "$namespace" || die "internal safety error: teardown namespace is not allowlisted"
  if namespace_exists "$namespace"; then
    ip netns delete "$namespace"
    printf '  removed namespace %s\n' "$namespace"
  fi
done

# Normally namespace deletion removes each veth pair. These exact checks cover a
# partially failed creation while refusing all names outside the project allowlist.
for interface in "$CLIENT_INTERFACE" "$ROUTER_LAN_INTERFACE" "$ROUTER_WAN_INTERFACE" "$UPSTREAM_INTERFACE"; do
  is_known_interface "$interface" || die "internal safety error: teardown interface is not allowlisted"
  if host_interface_exists "$interface"; then
    ip link delete "$interface"
    printf '  removed partial host interface %s\n' "$interface"
  fi
done

verify_default_route_unchanged "$default_route_before"
trap - EXIT
printf 'R2 topology absent. The Ubuntu VM default route is unchanged.\n'
