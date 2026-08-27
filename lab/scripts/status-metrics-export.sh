#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lab/scripts/topology-common.sh
source "$script_dir/topology-common.sh"
require_root
load_topology_config
echo "configured: http://$METRICS_EXPORT_HOST:$METRICS_EXPORT_PORT$METRICS_EXPORT_PATH every ${METRICS_EXPORT_INTERVAL_SECONDS}s"
if metrics_exporter_running; then
  echo "running: PID $(read_project_pid "$METRICS_EXPORT_PID_FILE") in $ROUTER_NAMESPACE"
else
  echo "stopped"
fi
echo "log: $METRICS_EXPORT_LOG_FILE"
