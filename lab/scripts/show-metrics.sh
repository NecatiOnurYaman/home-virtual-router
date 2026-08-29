#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../router/scripts/safety.sh
source "$script_dir/../../router/scripts/safety.sh"
# shellcheck source=topology-common.sh
source "$script_dir/topology-common.sh"

require_linux
require_root
load_topology_config
[ "$DEPLOYMENT_MODE" = "physical" ] || validate_topology_names
command -v ip >/dev/null 2>&1 || die "iproute2 is required"
command -v python3 >/dev/null 2>&1 || die "Python 3 is required"
if [ "$DEPLOYMENT_MODE" = "physical" ]; then
  # shellcheck source=../../physical/scripts/physical-common.sh
  source "$script_dir/../../physical/scripts/physical-common.sh"
  require_physical_authorization
  router_context_prefix
  "${ROUTER_CONTEXT_PREFIX[@]}" ip link show dev "$ROUTER_WAN_INTERFACE" >/dev/null 2>&1 || die "configured WAN interface is absent: $ROUTER_WAN_INTERFACE"
  "${ROUTER_CONTEXT_PREFIX[@]}" ip link show dev "$ROUTER_LAN_INTERFACE" >/dev/null 2>&1 || die "configured LAN interface is absent: $ROUTER_LAN_INTERFACE"
  command=(env PYTHONPATH="$HVR_REPO_DIR" python3 "$HVR_REPO_DIR/router/scripts/collect_metrics.py" --interface "lan=$ROUTER_LAN_INTERFACE" --interface "wan=$ROUTER_WAN_INTERFACE")
  [ "$PHYSICAL_TELEMETRY_INTERFACE" = none ] || command+=(--interface "telemetry=$PHYSICAL_TELEMETRY_INTERFACE")
  "${ROUTER_CONTEXT_PREFIX[@]}" "${command[@]}"
  exit 0
fi
require_lab_environment
require_r2_topology
ip -n "$ROUTER_NAMESPACE" link show dev "$ROUTER_WAN_INTERFACE" >/dev/null 2>&1 ||
  die "configured WAN interface is absent: $ROUTER_WAN_INTERFACE"
ip -n "$ROUTER_NAMESPACE" link show dev "$ROUTER_LAN_INTERFACE" >/dev/null 2>&1 ||
  die "configured LAN interface is absent: $ROUTER_LAN_INTERFACE"
ip -n "$ROUTER_NAMESPACE" link show dev "$TELEMETRY_ROUTER_INTERFACE" >/dev/null 2>&1 ||
  die "configured telemetry interface is absent: $TELEMETRY_ROUTER_INTERFACE; enable the R9 observability link"

router_context_prefix
"${ROUTER_CONTEXT_PREFIX[@]}" env PYTHONPATH="$HVR_REPO_DIR" \
  python3 "$HVR_REPO_DIR/router/scripts/collect_metrics.py" \
  --interface "lan=$ROUTER_LAN_INTERFACE" \
  --interface "wan=$ROUTER_WAN_INTERFACE" \
  --interface "telemetry=$TELEMETRY_ROUTER_INTERFACE"
