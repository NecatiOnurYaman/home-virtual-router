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
for required_command in ip nft sysctl softflowd softflowctl systemctl; do
  command -v "$required_command" >/dev/null 2>&1 || die "$required_command is required"
done
require_project_ipfix_control_socket
softflowd_help="$(softflowd -h 2>&1 || true)"
printf '%s\n' "$softflowd_help" | grep -Eiq 'export version[^[:cntrl:]]*10|IPFIX' || \
  die "installed softflowd does not advertise IPFIX v10 support"
softflowctl_help="$(softflowctl -h 2>&1 || true)"
printf '%s\n' "$softflowctl_help" | grep -F -- "expire-all" >/dev/null || \
  die "installed softflowctl does not advertise the expire-all command"
[ "$IPFIX_ENABLED" = "1" ] || die "IPFIX_ENABLED is not 1 in the validated lab configuration"
require_r2_topology
dns_r7_enabled || die "R7 DNS must be enabled before R8 IPFIX"
nat_rule_exists || die "R4 NAT state is required"
filter_rules_exist || die "R5 firewall state is required"
softflowd_running && die "R8 project softflowd process is already running"
if [ -e "$IPFIX_PID_FILE" ]; then
  stop_project_softflowd_if_present
fi
snapshot_r6_host_state

started=0
rollback_ipfix_enable() {
  local status=$?
  trap - EXIT INT TERM
  if [ "$started" -eq 1 ]; then
    stop_project_softflowd_if_present || status=1
  fi
  remove_project_ipfix_files
  verify_r6_host_state || status=1
  exit "$status"
}
trap rollback_ipfix_enable EXIT INT TERM

mkdir -p "$IPFIX_RUNTIME_DIR"
chown 0:0 "$IPFIX_RUNTIME_DIR"
chmod 0750 "$IPFIX_RUNTIME_DIR"
rm -f "$IPFIX_PID_FILE" "$IPFIX_LOG_FILE" "$IPFIX_CONTROL_SOCKET" \
  "$IPFIX_COLLECTOR_RESULT" "$IPFIX_COLLECTOR_READY"
touch "$IPFIX_LOG_FILE"
chmod 0640 "$IPFIX_LOG_FILE"

ip netns exec "$ROUTER_NAMESPACE" softflowd -d -N \
  -c "$IPFIX_CONTROL_SOCKET" \
  -i "$IPFIX_CAPTURE_INTERFACE" \
  -n "$IPFIX_COLLECTOR_HOST:$IPFIX_COLLECTOR_PORT" \
  -v 10 -P udp -A milli -T full \
  -t general=2 -t tcp=2 -t udp=2 -t maxlife=5 -t expint=1 \
  ip > "$IPFIX_LOG_FILE" 2>&1 &
exporter_pid=$!
printf '%s\n' "$exporter_pid" > "$IPFIX_PID_FILE"
started=1

for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  softflowd_running && break
  sleep 0.05
done
softflowd_running || die "project softflowd IPFIX exporter did not start"
[ -S "$IPFIX_CONTROL_SOCKET" ] || die "project softflowd control socket was not created"
verify_r6_host_state

started=0
trap - EXIT INT TERM
printf 'R8 IPFIX enabled: softflowd captures IPv4 on %s and exports v10 UDP to %s:%s.\n' \
  "$IPFIX_CAPTURE_INTERFACE" "$IPFIX_COLLECTOR_HOST" "$IPFIX_COLLECTOR_PORT"
