#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 0 ] || { echo "error: management read helper accepts no arguments" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "error: root privileges are required" >&2; exit 1; }
management_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$management_helper_dir/management_read.py"
