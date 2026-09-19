#!/usr/bin/env bash
set -euo pipefail
stage_status_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stage_status_repo_dir="$(cd "$stage_status_script_dir/../.." && pwd)"
# shellcheck source=../../lab/scripts/runtime-common.sh
source "$stage_status_repo_dir/lab/scripts/runtime-common.sh"
require_linux
require_root
load_topology_config
runtime_require_environment
while IFS= read -r stage; do
  set +e
  runtime_stage_state "$stage" >/dev/null 2>&1
  code=$?
  set -e
  printf '%s\t%s\n' "$stage" "$code"
done < <(runtime_desired_stages)
