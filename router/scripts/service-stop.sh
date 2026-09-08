#!/usr/bin/env bash
set -euo pipefail
service_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
service_repo_dir="$(cd "$service_script_dir/../.." && pwd)"
"$service_repo_dir/lab/scripts/runtime-stop.sh"
