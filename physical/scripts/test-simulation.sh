#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "error: physical simulation requires root" >&2; exit 1; }
for command in unshare nsenter; do
  command -v "$command" >/dev/null || { echo "error: $command is required (util-linux)" >&2; exit 1; }
done
temporary="$(mktemp -d /tmp/hvr-physical-sim.XXXXXX)"
cleanup() { rm -f -- "$temporary/router.env"; rmdir "$temporary" 2>/dev/null || true; }
trap cleanup EXIT
sed -e 's/^PHYSICAL_WAN_INTERFACE=.*/PHYSICAL_WAN_INTERFACE=hvr-sim-wan/' \
  -e 's/^PHYSICAL_LAN_INTERFACE=.*/PHYSICAL_LAN_INTERFACE=hvr-sim-lan/' \
  -e 's/^IPFIX_CAPTURE_INTERFACE=.*/IPFIX_CAPTURE_INTERFACE=hvr-sim-lan/' \
  -e 's/^DNS_UPSTREAM=.*/DNS_UPSTREAM=203.0.113.1/' \
  -e 's/^IPFIX_COLLECTOR_HOST=.*/IPFIX_COLLECTOR_HOST=203.0.113.1/' \
  -e 's/^METRICS_EXPORT_HOST=.*/METRICS_EXPORT_HOST=203.0.113.1/' \
  "$repo_dir/config/physical.example.env" > "$temporary/router.env"
outer_net_namespace="$(readlink /proc/self/ns/net)"
outer_mount_namespace="$(readlink /proc/self/ns/mnt)"
unshare --mount --net --pid --fork --mount-proc \
  "$script_dir/test-simulation-inner.sh" "$repo_dir" "$temporary/router.env" \
  "$outer_net_namespace" "$outer_mount_namespace"
cleanup
trap - EXIT
for interface in hvr-sim-wan hvr-sim-up hvr-sim-lan hvr-sim-client; do
  ip link show dev "$interface" >/dev/null 2>&1 && { echo "error: simulation interface escaped isolation: $interface" >&2; exit 1; }
done
echo "CHECK: outer-host simulation interfaces absent ... PASS"
[ ! -e "$temporary" ] || { echo "error: simulation temporary directory was not removed: $temporary" >&2; exit 1; }
echo "CHECK: simulation temporary directory absent ... PASS"
echo "R13 physical simulation acceptance passed; isolated resources are absent. This is not R14 hardware validation."
