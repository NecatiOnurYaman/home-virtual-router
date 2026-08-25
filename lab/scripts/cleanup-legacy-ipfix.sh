#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../router/scripts/safety.sh
source "$script_dir/../../router/scripts/safety.sh"
# shellcheck source=topology-common.sh
source "$script_dir/topology-common.sh"

require_lab_environment
require_root
load_topology_config
validate_topology_names
[ "$#" -eq 2 ] || die "usage: $0 VERIFIED_CORE_PID VERIFIED_PROC_STARTTIME"
core_pid="$1"
expected_starttime="$2"
printf '%s' "$core_pid" | grep -Eq '^[1-9][0-9]*$' || die "core PID must be numeric"
printf '%s' "$expected_starttime" | grep -Eq '^[1-9][0-9]*$' || die "start time must be numeric"
process_is_running "$core_pid" || die "PID $core_pid is not running"
process_is_pmacctd "$core_pid" || die "PID $core_pid is not pmacctd"
process_is_in_router_namespace "$core_pid" || die "PID $core_pid is not in $ROUTER_NAMESPACE"
[ "$(process_starttime "$core_pid")" = "$expected_starttime" ] || die "PID start time does not match"
tr '\0' ' ' < "/proc/$core_pid/cmdline" | grep -F -- "$IPFIX_CONFIG_FILE" >/dev/null ||
  die "PID command line does not reference the exact project IPFIX configuration"
children="$(project_nfprobe_pids "$core_pid")"
[ "$(printf '%s\n' "$children" | awk 'NF {count++} END {print count+0}')" -eq 1 ] ||
  die "verified legacy core does not have exactly one pmacctd nfprobe child"
plugin_pid="$children"
plugin_starttime="$(process_starttime "$plugin_pid")"
printf 'Stopping verified legacy project pair core=%s(start=%s) plugin=%s(start=%s).\n' \
  "$core_pid" "$expected_starttime" "$plugin_pid" "$plugin_starttime"
kill "$core_pid"
for _attempt in $(seq 1 50); do process_is_running "$core_pid" || break; sleep 0.1; done
process_is_running "$core_pid" && die "verified legacy core did not stop"
if process_is_running "$plugin_pid"; then
  [ "$(process_starttime "$plugin_pid")" = "$plugin_starttime" ] || die "plugin PID was reused; refusing signal"
  process_is_pmacctd "$plugin_pid" && process_is_in_router_namespace "$plugin_pid" || die "plugin identity changed; refusing signal"
  kill "$plugin_pid"
fi
printf 'Verified legacy project pmacct pair stopped.\n'
