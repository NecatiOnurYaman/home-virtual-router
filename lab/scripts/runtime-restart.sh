#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runtime-common.sh
source "$script_dir/runtime-common.sh"
require_lab_environment
require_root
runtime_lock
"$script_dir/runtime-stop.sh"
"$script_dir/runtime-start.sh"
