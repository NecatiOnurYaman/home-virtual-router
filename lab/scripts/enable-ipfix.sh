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
for required_command in ip nft sysctl pmacctd ps readlink systemctl; do
  command -v "$required_command" >/dev/null 2>&1 ||
    die "$required_command is required (Ubuntu: sudo apt install pmacct)"
done
[ "$IPFIX_ENABLED" = "1" ] || die "IPFIX_ENABLED is not 1 in the validated lab configuration"
require_r2_topology
dns_r7_enabled || die "R7 DNS must be enabled before R8 IPFIX"
nat_rule_exists || die "R4 NAT state is required"
filter_rules_exist || die "R5 firewall state is required"
if existing_pid="$(read_project_pid "$IPFIX_PID_FILE" 2>/dev/null)" && process_is_running "$existing_pid"; then
  die "an R8 pmacct core PID is already live; run ipfix-disable before enabling"
fi
if existing_pid="$(read_project_pid "$IPFIX_PLUGIN_PID_FILE" 2>/dev/null)" && process_is_running "$existing_pid"; then
  die "an R8 nfprobe plugin PID is already live; run ipfix-disable before enabling"
fi
snapshot_r6_host_state

started=0
rollback_ipfix_enable() {
  local status=$?
  trap - EXIT INT TERM
  capture_pmacct_process_tree || status=1
  if [ "$started" -eq 1 ]; then stop_project_pmacctd_if_present || status=1; fi
  remove_project_ipfix_pid_files
  verify_r6_host_state || status=1
  printf 'R8 startup failed; preserved %s, %s, %s, and %s for diagnosis.\n' \
    "$IPFIX_CONFIG_FILE" "$IPFIX_LOG_FILE" "$IPFIX_COMMAND_FILE" "$IPFIX_PROCESS_TREE_FILE" >&2
  exit "$status"
}
trap rollback_ipfix_enable EXIT INT TERM

# Safely migrate an earlier project-owned R8 instance; no host service is touched.
stop_legacy_project_softflowd_if_present
mkdir -p "$IPFIX_RUNTIME_DIR"
chown 0:0 "$IPFIX_RUNTIME_DIR"
chmod 0750 "$IPFIX_RUNTIME_DIR"
remove_project_ipfix_files
mkdir -p "$IPFIX_RUNTIME_DIR"
touch "$IPFIX_LOG_FILE"
chmod 0640 "$IPFIX_LOG_FILE"
render_pmacctd_config
chown 0:0 "$IPFIX_CONFIG_FILE"
chmod 0640 "$IPFIX_CONFIG_FILE"

pmacctd_command=(ip netns exec "$ROUTER_NAMESPACE" pmacctd -f "$IPFIX_CONFIG_FILE")
printf '%q ' "${pmacctd_command[@]}" > "$IPFIX_COMMAND_FILE"
printf '>> %q 2>&1 &\n' "$IPFIX_LOG_FILE" >> "$IPFIX_COMMAND_FILE"
"${pmacctd_command[@]}" >> "$IPFIX_LOG_FILE" 2>&1 &
launch_pid=$!
printf '%s\n' "$launch_pid" > "$IPFIX_LAUNCH_PID_FILE"
process_starttime "$launch_pid" > "$IPFIX_LAUNCH_STARTTIME_FILE"
started=1

healthy=0
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  capture_pmacct_process_tree || true
  if pmacct_core_running && [ ! -s "$IPFIX_CORE_STARTTIME_FILE" ]; then
    core_pid="$(read_project_pid "$IPFIX_PID_FILE")"
    process_starttime "$core_pid" > "$IPFIX_CORE_STARTTIME_FILE"
  fi
  if grep -Eiq 'no more plugins active|engine_type:engine_id is only supported on NetFlow v5|unknown plugin|invalid plugin|nfprobe.*(not supported|unavailable)|(^|[[:space:]])ERROR([[:space:]]|$)' "$IPFIX_LOG_FILE"; then
    sed 's/^/  /' "$IPFIX_LOG_FILE" >&2
    die "pmacctd nfprobe plugin startup failed; inspect the project log"
  fi
  if pmacct_core_running && pmacct_nfprobe_running &&
     grep -F 'hvr/nfprobe' "$IPFIX_LOG_FILE" >/dev/null 2>&1 &&
     grep -F "Exporting flows to [$IPFIX_COLLECTOR_HOST]:$IPFIX_COLLECTOR_PORT" "$IPFIX_LOG_FILE" >/dev/null 2>&1; then
    healthy=1
  fi
  sleep 0.1
done
if [ "$healthy" -ne 1 ] || ! pmacctd_running; then
  capture_pmacct_process_tree || true
  sed 's/^/  /' "$IPFIX_LOG_FILE" >&2
  die "pmacct core and hvr/nfprobe plugin did not remain healthy in hvr-router"
fi
assert_single_project_pmacct_pair
core_pid="$(read_project_pid "$IPFIX_PID_FILE")"
process_starttime "$core_pid" > "$IPFIX_CORE_STARTTIME_FILE"
capture_pmacct_process_tree
verify_r6_host_state

started=0
trap - EXIT INT TERM
printf 'R8 IPFIX enabled: pmacctd/nfprobe captures IPv4 on %s and exports v10 UDP to %s:%s.\n' \
  "$IPFIX_CAPTURE_INTERFACE" "$IPFIX_COLLECTOR_HOST" "$IPFIX_COLLECTOR_PORT"
