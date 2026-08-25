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
default_route_before="$(capture_default_route)"
host_forwarding_before="$(capture_host_ipv4_forwarding)"
host_nftables_before="$(capture_host_nftables)"

if pmacct_core_running; then
  die "disable IPFIX before removing its observability path"
fi
if [ -e "/sys/class/net/$TELEMETRY_HOST_INTERFACE" ]; then
  ip link delete "$TELEMETRY_HOST_INTERFACE"
elif namespace_exists "$ROUTER_NAMESPACE" && ip -n "$ROUTER_NAMESPACE" link show dev "$TELEMETRY_ROUTER_INTERFACE" >/dev/null 2>&1; then
  ip -n "$ROUTER_NAMESPACE" link delete "$TELEMETRY_ROUTER_INTERFACE"
fi
rm -f -- "$TELEMETRY_EXPORT_DIR/dnsmasq.leases" "$TELEMETRY_EXPORT_DIR/dnsmasq.log"
rmdir "$TELEMETRY_EXPORT_DIR" 2>/dev/null || true

verify_default_route_unchanged "$default_route_before"
verify_host_ipv4_forwarding_unchanged "$host_forwarding_before"
verify_snapshot_unchanged "host nftables" "$host_nftables_before" "$(capture_host_nftables)"
printf 'R9 observability boundary disabled; only project telemetry link/export entries were removed.\n'
