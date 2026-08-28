#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runtime-common.sh
source "$script_dir/runtime-common.sh"
require_linux
require_root
load_topology_config
runtime_require_environment
if [ -e "$RUNTIME_STATE_FILE" ]; then
  python3 "$RUNTIME_STATE_TOOL" show "$RUNTIME_STATE_FILE" >/dev/null || die "malformed R12 state"
  printf 'Recorded profile: %s\n' "$(runtime_state_field profile)" || die "malformed R12 state"
  printf 'Recorded deployment: %s\n' "$(runtime_state_field deployment)"
  printf 'Recorded status:  %s\n' "$(runtime_state_field status)"
  printf 'Started at:       %s\n' "$(runtime_state_field started-at)"
  printf 'Owned stages:     %s\n' "$(runtime_state_field owned)"
else
  echo "Recorded state:   absent"
fi
runtime_status_report
