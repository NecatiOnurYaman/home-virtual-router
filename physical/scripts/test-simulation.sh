#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "error: physical simulation requires root" >&2; exit 1; }
command -v unshare >/dev/null || { echo "error: unshare is required (util-linux)" >&2; exit 1; }
temporary="$(mktemp -d /tmp/hvr-physical-sim.XXXXXX)"
cleanup() { rm -f -- "$temporary/router.env"; rmdir "$temporary" 2>/dev/null || true; }
trap cleanup EXIT
sed -e 's/^PHYSICAL_WAN_INTERFACE=.*/PHYSICAL_WAN_INTERFACE=hvr-sim-wan/' \
  -e 's/^PHYSICAL_LAN_INTERFACE=.*/PHYSICAL_LAN_INTERFACE=hvr-sim-lan/' \
  -e 's/^IPFIX_CAPTURE_INTERFACE=.*/IPFIX_CAPTURE_INTERFACE=hvr-sim-lan/' \
  "$repo_dir/config/physical.example.env" > "$temporary/router.env"
outer_net_namespace="$(readlink /proc/self/ns/net)"
outer_mount_namespace="$(readlink /proc/self/ns/mnt)"
unshare --mount --net --pid --fork --mount-proc \
  "$script_dir/test-simulation-inner.sh" "$repo_dir" "$temporary/router.env" \
  "$outer_net_namespace" "$outer_mount_namespace"
echo "R13 physical simulation passed in isolated mount/network/PID namespaces; this is not R14 hardware validation."
