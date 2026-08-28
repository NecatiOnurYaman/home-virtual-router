#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runtime-common.sh
source "$script_dir/runtime-common.sh"
require_lab_environment
require_root
load_topology_config

if [ -e "$RUNTIME_STATE_FILE" ]; then
  die "runtime-test requires a stopped R12 runtime; run make runtime-stop first"
fi
set +e; runtime_stage_state topology; topology_state=$?; set -e
[ "$topology_state" -eq 1 ] || die "runtime-test requires an absent lab topology so ownership and full teardown can be proven"

cleanup() { "$script_dir/runtime-stop.sh" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
start_seconds="${HVR_RUNTIME_TEST_TIMEOUT_SECONDS:-90}"
case "$start_seconds" in *[!0-9]*|'') die "HVR_RUNTIME_TEST_TIMEOUT_SECONDS must be an integer" ;; esac
[ "$start_seconds" -ge 10 ] && [ "$start_seconds" -le 300 ] || die "HVR_RUNTIME_TEST_TIMEOUT_SECONDS must be between 10 and 300"

timeout "$start_seconds" "$script_dir/runtime-start.sh"
timeout "$start_seconds" "$script_dir/runtime-start.sh"
"$script_dir/runtime-check.sh"
"$script_dir/runtime-stop.sh"
"$script_dir/runtime-stop.sh"
set +e; runtime_stage_state topology; topology_state=$?; set -e
[ "$topology_state" -eq 1 ] || die "runtime-stop did not return to the absent baseline"
trap - EXIT INT TERM
echo "R12 acceptance passed: full start, idempotent start, health, owned teardown, and idempotent stop succeeded."
