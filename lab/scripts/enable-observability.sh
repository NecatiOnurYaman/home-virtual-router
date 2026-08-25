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
require_r2_topology
[ "$TELEMETRY_MODE" = "observability" ] ||
  die "TELEMETRY_MODE must be observability (and IPFIX_COLLECTOR_HOST must be $TELEMETRY_HOST_ADDRESS)"
[ ! -e "/sys/class/net/$TELEMETRY_HOST_INTERFACE" ] || die "telemetry link already exists"
ip -n "$ROUTER_NAMESPACE" link show dev "$TELEMETRY_ROUTER_INTERFACE" >/dev/null 2>&1 &&
  die "router telemetry interface already exists"

default_route_before="$(capture_default_route)"
require_default_route_is_not_lab_interface "$default_route_before"
host_forwarding_before="$(capture_host_ipv4_forwarding)"
host_nftables_before="$(capture_host_nftables)"
created=0
rollback() {
  local status=$?
  trap - EXIT INT TERM
  if [ "$created" -eq 1 ]; then
    ip link delete "$TELEMETRY_HOST_INTERFACE" 2>/dev/null || true
    rm -f -- "$TELEMETRY_EXPORT_DIR/dnsmasq.leases" "$TELEMETRY_EXPORT_DIR/dnsmasq.log"
    rmdir "$TELEMETRY_EXPORT_DIR" 2>/dev/null || true
  fi
  verify_default_route_unchanged "$default_route_before" || status=1
  verify_host_ipv4_forwarding_unchanged "$host_forwarding_before" || status=1
  verify_snapshot_unchanged "host nftables" "$host_nftables_before" "$(capture_host_nftables)" || status=1
  exit "$status"
}
trap rollback EXIT INT TERM
created=1

ip link add "$TELEMETRY_HOST_INTERFACE" type veth peer name "$TELEMETRY_ROUTER_INTERFACE"
ip link set "$TELEMETRY_ROUTER_INTERFACE" netns "$ROUTER_NAMESPACE"
telemetry_prefix="${TELEMETRY_SUBNET#*/}"
ip address add "$TELEMETRY_HOST_ADDRESS/$telemetry_prefix" dev "$TELEMETRY_HOST_INTERFACE"
ip -n "$ROUTER_NAMESPACE" address add "$TELEMETRY_ROUTER_ADDRESS/$telemetry_prefix" dev "$TELEMETRY_ROUTER_INTERFACE"
ip link set "$TELEMETRY_HOST_INTERFACE" up
ip -n "$ROUTER_NAMESPACE" link set "$TELEMETRY_ROUTER_INTERFACE" up

install -d -m 0755 "$TELEMETRY_EXPORT_DIR"
ln -s "$DNSMASQ_LEASE_FILE" "$TELEMETRY_EXPORT_DIR/dnsmasq.leases"
ln -s "$DNS_LOG_FILE" "$TELEMETRY_EXPORT_DIR/dnsmasq.log"

[ -z "$(ip -n "$ROUTER_NAMESPACE" route show default dev "$TELEMETRY_ROUTER_INTERFACE")" ] ||
  die "telemetry interface unexpectedly became a default route"
verify_default_route_unchanged "$default_route_before"
verify_host_ipv4_forwarding_unchanged "$host_forwarding_before"
verify_snapshot_unchanged "host nftables" "$host_nftables_before" "$(capture_host_nftables)"
created=0
trap - EXIT INT TERM
printf 'R9 observability boundary enabled: %s (%s) <-> %s (%s); telemetry files exported at %s.\n' \
  "$TELEMETRY_HOST_INTERFACE" "$TELEMETRY_HOST_ADDRESS" "$TELEMETRY_ROUTER_INTERFACE" "$TELEMETRY_ROUTER_ADDRESS" "$TELEMETRY_EXPORT_DIR"
