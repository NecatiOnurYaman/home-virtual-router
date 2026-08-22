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
