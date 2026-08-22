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
for required_command in ip nft sysctl pmacctd systemctl; do
  command -v "$required_command" >/dev/null 2>&1 ||
    die "$required_command is required (Ubuntu: sudo apt install pmacct)"
done
[ "$IPFIX_ENABLED" = "1" ] || die "IPFIX_ENABLED is not 1 in the validated lab configuration"
require_r2_topology
dns_r7_enabled || die "R7 DNS must be enabled before R8 IPFIX"
nat_rule_exists || die "R4 NAT state is required"
filter_rules_exist || die "R5 firewall state is required"
pmacctd_running && die "R8 project pmacctd process is already running"
snapshot_r6_host_state

started=0
rollback_ipfix_enable() {
  local status=$?
  trap - EXIT INT TERM
  if [ "$started" -eq 1 ]; then stop_project_pmacctd_if_present || status=1; fi
  remove_project_ipfix_files
  verify_r6_host_state || status=1
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

pmacctd_command=(pmacctd -f "$IPFIX_CONFIG_FILE")
printf '%q ' "${pmacctd_command[@]}" > "$IPFIX_COMMAND_FILE"
printf '\n' >> "$IPFIX_COMMAND_FILE"
ip netns exec "$ROUTER_NAMESPACE" "${pmacctd_command[@]}" >> "$IPFIX_LOG_FILE" 2>&1 &
exporter_pid=$!
printf '%s\n' "$exporter_pid" > "$IPFIX_PID_FILE"
started=1

for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  pmacctd_running && break
  sleep 0.1
done
if ! pmacctd_running; then
  sed 's/^/  /' "$IPFIX_LOG_FILE" >&2
  die "pmacctd could not start nfprobe; verify the installed pmacct build contains nfprobe/IPFIX support"
fi
if grep -Eiq 'unknown plugin|invalid plugin|nfprobe.*(not supported|unavailable)|ERROR.*nfprobe' "$IPFIX_LOG_FILE"; then
  sed 's/^/  /' "$IPFIX_LOG_FILE" >&2
  die "installed pmacctd lacks usable nfprobe support"
fi
verify_r6_host_state

started=0
trap - EXIT INT TERM
printf 'R8 IPFIX enabled: pmacctd/nfprobe captures IPv4 on %s and exports v10 UDP to %s:%s.\n' \
  "$IPFIX_CAPTURE_INTERFACE" "$IPFIX_COLLECTOR_HOST" "$IPFIX_COLLECTOR_PORT"
