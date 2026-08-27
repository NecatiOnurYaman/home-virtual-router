#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lab/scripts/topology-common.sh
source "$script_dir/topology-common.sh"
require_root
load_topology_config
stop_metrics_exporter_if_present
echo "R11 metrics exporter is stopped; R1-R10 state is unchanged."
