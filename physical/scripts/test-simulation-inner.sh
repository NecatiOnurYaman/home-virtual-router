#!/usr/bin/env bash
set -euo pipefail
repo_dir="$1" simulation_config="$2" outer_net_namespace="$3" outer_mount_namespace="$4"
mount --make-rprivate /
mount -t tmpfs tmpfs /run
mkdir -p /run/home-virtual-router
export HVR_INTERNAL_PHYSICAL_SIMULATION=1
export HVR_INTERNAL_SIMULATION_CONFIG="$simulation_config"
export HVR_INTERNAL_OUTER_NET_NAMESPACE="$outer_net_namespace"
export HVR_INTERNAL_OUTER_MOUNT_NAMESPACE="$outer_mount_namespace"
ip link add hvr-sim-wan type veth peer name hvr-sim-up
ip link add hvr-sim-lan type veth peer name hvr-sim-client
ip link set hvr-sim-up up
ip link set hvr-sim-client up
"$repo_dir/physical/scripts/preflight.sh"
"$repo_dir/lab/scripts/runtime-start.sh"
"$repo_dir/lab/scripts/runtime-start.sh"
"$repo_dir/lab/scripts/runtime-check.sh"
"$repo_dir/lab/scripts/runtime-stop.sh"
"$repo_dir/lab/scripts/runtime-stop.sh"
ip -o -4 address show dev hvr-sim-wan | grep -F '203.0.113.2/' >/dev/null 2>&1 && exit 1 || true
[ ! -e /run/home-virtual-router/runtime/state.env ]
