#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lab/scripts/topology-common.sh
source "$script_dir/topology-common.sh"
require_root
load_topology_config
[ "$METRICS_EXPORT_ENABLED" = "1" ] || die "metrics export is disabled by configuration"
if [ "$DEPLOYMENT_MODE" = "physical" ]; then
  # shellcheck source=../../physical/scripts/physical-common.sh
  source "$script_dir/../../physical/scripts/physical-common.sh"
  require_physical_authorization
  ip link show dev "$ROUTER_LAN_INTERFACE" >/dev/null || die "physical LAN interface is absent"
  ip link show dev "$ROUTER_WAN_INTERFACE" >/dev/null || die "physical WAN interface is absent"
else
  namespace_exists "$ROUTER_NAMESPACE" || die "R2 router namespace is absent"
  ip -n "$ROUTER_NAMESPACE" link show dev "$ROUTER_LAN_INTERFACE" >/dev/null || die "R10 LAN interface is absent"
  ip -n "$ROUTER_NAMESPACE" link show dev "$ROUTER_WAN_INTERFACE" >/dev/null || die "R10 WAN interface is absent"
fi
interfaces=(--interface "lan=$ROUTER_LAN_INTERFACE" --interface "wan=$ROUTER_WAN_INTERFACE")
if [ "$DEPLOYMENT_MODE" = "physical" ] && [ "$PHYSICAL_TELEMETRY_INTERFACE" != none ]; then
  ip link show dev "$PHYSICAL_TELEMETRY_INTERFACE" >/dev/null || die "physical telemetry interface is absent"
  interfaces+=(--interface "telemetry=$PHYSICAL_TELEMETRY_INTERFACE")
elif [ "$TELEMETRY_MODE" = "observability" ]; then
  ip -n "$ROUTER_NAMESPACE" link show dev "$TELEMETRY_ROUTER_INTERFACE" >/dev/null || die "R9 telemetry interface is absent in observability mode"
  interfaces+=(--interface "telemetry=$TELEMETRY_ROUTER_INTERFACE")
fi
mkdir -p -- "$METRICS_EXPORT_RUNTIME_DIR"
if metrics_exporter_running; then
  echo "R11 metrics exporter is already running."
  exit 0
fi
stop_metrics_exporter_if_present
interval="${HVR_METRICS_EXPORT_INTERVAL_SECONDS:-$METRICS_EXPORT_INTERVAL_SECONDS}"
python3 - "$interval" <<'PY'
import sys
value = float(sys.argv[1])
assert 0.1 <= value <= 3600
PY
command=(python3 "$METRICS_EXPORTER" --router-id "$ROUTER_ID" --host "$METRICS_EXPORT_HOST" --port "$METRICS_EXPORT_PORT" --path "$METRICS_EXPORT_PATH" --interval "$interval" --timeout "$METRICS_EXPORT_TIMEOUT_SECONDS" "${interfaces[@]}")
if [ "$DEPLOYMENT_MODE" = "physical" ]; then prefix=(env "PYTHONPATH=$HVR_REPO_DIR"); else prefix=(ip netns exec "$ROUTER_NAMESPACE" env "PYTHONPATH=$HVR_REPO_DIR"); fi
printf '%q ' "${prefix[@]}" "${command[@]}" > "$METRICS_EXPORT_COMMAND_FILE"
printf '\n' >> "$METRICS_EXPORT_COMMAND_FILE"
"${prefix[@]}" "${command[@]}" >> "$METRICS_EXPORT_LOG_FILE" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$METRICS_EXPORT_PID_FILE"
process_starttime "$pid" > "$METRICS_EXPORT_STARTTIME_FILE"
sleep 0.2
metrics_exporter_identity_matches "$pid" || { wait "$pid" || true; rm -f -- "$METRICS_EXPORT_PID_FILE" "$METRICS_EXPORT_STARTTIME_FILE"; die "metrics exporter did not remain running; inspect $METRICS_EXPORT_LOG_FILE"; }
echo "R11 metrics exporter started (PID $pid) -> http://$METRICS_EXPORT_HOST:$METRICS_EXPORT_PORT$METRICS_EXPORT_PATH"
