#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runtime-common.sh
source "$script_dir/runtime-common.sh"
require_linux
require_root
load_topology_config
runtime_require_environment
runtime_status_report
[ "$RUNTIME_CLASS" = running ] || die "runtime health is $RUNTIME_CLASS"
