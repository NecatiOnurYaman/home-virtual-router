#!/usr/bin/env bash
set -euo pipefail
service_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
service_repo_dir="$(cd "$service_script_dir/../.." && pwd)"
# shellcheck source=../../lab/scripts/runtime-common.sh
source "$service_repo_dir/lab/scripts/runtime-common.sh"
require_linux
require_root
load_topology_config
runtime_require_environment
[ "$DEPLOYMENT_MODE" = physical ] || die "the persistent HVR service supports only DEPLOYMENT_MODE=physical"
[ ! -e /var/lib/home-virtual-router/r14/checkpoint.env ] ||
  die "an R14 validation transaction is active; finish physical-hardware-test-stop before starting the service"
python3 "$service_script_dir/persistence.py" verify "$service_repo_dir"
"$service_repo_dir/lab/scripts/runtime-start.sh"
"$service_repo_dir/lab/scripts/runtime-check.sh"
echo "HVR persistent service startup is healthy."
