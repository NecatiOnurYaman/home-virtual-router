#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../router/scripts/safety.sh
source "$script_dir/../../router/scripts/safety.sh"
# shellcheck source=topology-common.sh
source "$script_dir/topology-common.sh"

readonly DIAGNOSTIC_PACKET_COUNT=2048
readonly DIAGNOSTIC_PACKET_SIZE=1200
readonly DIAGNOSTIC_INTERVAL=0.001

require_lab_environment
require_root
load_topology_config
validate_topology_names
require_project_ipfix_control_socket
for required_command in ip softflowd softflowctl ping dpkg-query tcpdump nft sysctl systemctl; do
  command -v "$required_command" >/dev/null 2>&1 || die "$required_command is required"
done
require_r2_topology
softflowd_running || die "start the normal R8 project exporter before live diagnostics"
dns_r7_enabled || die "R7 DNS is not active"
client_address="$(client_dhcp_address)" || die "R6 dynamic client address is invalid"
snapshot_r6_host_state

readonly DIAG_NO_PROMISC_CTL="$IPFIX_RUNTIME_DIR/diagnostic-no-promisc.ctl"
readonly DIAG_NO_PROMISC_PID="$IPFIX_RUNTIME_DIR/diagnostic-no-promisc.pid"
readonly DIAG_NO_PROMISC_LOG="$IPFIX_RUNTIME_DIR/diagnostic-no-promisc.log"
readonly DIAG_NO_PROMISC_STATS="$IPFIX_RUNTIME_DIR/diagnostic-no-promisc-statistics.txt"
readonly DIAG_PROMISC_CTL="$IPFIX_RUNTIME_DIR/diagnostic-promisc.ctl"
readonly DIAG_PROMISC_PID="$IPFIX_RUNTIME_DIR/diagnostic-promisc.pid"
readonly DIAG_PROMISC_LOG="$IPFIX_RUNTIME_DIR/diagnostic-promisc.log"
readonly DIAG_PROMISC_STATS="$IPFIX_RUNTIME_DIR/diagnostic-promisc-statistics.txt"

active_pid_file=""
active_control_socket=""
cleanup_live_diagnostic() {
  local status=$?
  trap - EXIT INT TERM
  if [ -n "$active_pid_file" ]; then
    stop_project_process_if_present "$active_pid_file" softflowd "$active_control_socket" || status=1
  fi
  rm -f -- "$DIAG_NO_PROMISC_CTL" "$DIAG_NO_PROMISC_PID" \
    "$DIAG_PROMISC_CTL" "$DIAG_PROMISC_PID"
  verify_r6_host_state || status=1
  exit "$status"
}
trap cleanup_live_diagnostic EXIT INT TERM

rm -f -- "$DIAG_NO_PROMISC_CTL" "$DIAG_NO_PROMISC_PID" "$DIAG_NO_PROMISC_LOG" \
  "$DIAG_NO_PROMISC_STATS" "$DIAG_PROMISC_CTL" "$DIAG_PROMISC_PID" \
  "$DIAG_PROMISC_LOG" "$DIAG_PROMISC_STATS" "$IPFIX_LIVE_DIAGNOSTIC_FILE" \
  "$IPFIX_VERSION_FILE"

{
  printf 'softflowd help/version:\n'
  softflowd -h 2>&1 | head -n 3 || true
  printf '\nUbuntu packages:\n'
  dpkg-query -W -f='${Package} ${Version}\n' softflowd libpcap0.8 2>&1 || true
  printf '\ntcpdump/libpcap:\n'
  tcpdump --version 2>&1 || true
} > "$IPFIX_VERSION_FILE"

promiscuity_before="$(ip -n "$ROUTER_NAMESPACE" -details link show dev "$IPFIX_CAPTURE_INTERFACE" |
  awk '/promiscuity/ {for (i=1; i<=NF; i++) if ($i == "promiscuity") {print $(i+1); exit}}')"

run_live_variant() {
  local label="$1" control_socket="$2" pid_file="$3" log_file="$4" stats_file="$5"
  shift 5
  local -a mode_args=("$@") command
  local pid

  command=(softflowd -d "${mode_args[@]}" -c "$control_socket" \
    -i "$IPFIX_CAPTURE_INTERFACE" -T full -- ip)
  ip netns exec "$ROUTER_NAMESPACE" "${command[@]}" > "$log_file" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$pid_file"
  active_pid_file="$pid_file"
  active_control_socket="$control_socket"
  for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -S "$control_socket" ] && break
    kill -0 "$pid" 2>/dev/null || die "$label diagnostic softflowd exited during startup"
    sleep 0.05
  done
  [ -S "$control_socket" ] || die "$label diagnostic control socket did not appear"
  project_process_matches "$pid" softflowd "$control_socket" || \
    die "$label diagnostic PID does not identify its project softflowd"

  ip netns exec "$CLIENT_NAMESPACE" ping -q -c "$DIAGNOSTIC_PACKET_COUNT" \
    -s "$DIAGNOSTIC_PACKET_SIZE" -i "$DIAGNOSTIC_INTERVAL" -W 1 \
    "$UPSTREAM_GATEWAY" >/dev/null
  ip netns exec "$ROUTER_NAMESPACE" softflowctl -c "$control_socket" statistics \
    > "$stats_file" 2>&1 || die "$label diagnostic statistics query failed"
  stop_project_process "$pid_file" softflowd "$control_socket"
  active_pid_file=""
  active_control_socket=""
  rm -f -- "$control_socket"
}

run_live_variant "-N" "$DIAG_NO_PROMISC_CTL" "$DIAG_NO_PROMISC_PID" \
  "$DIAG_NO_PROMISC_LOG" "$DIAG_NO_PROMISC_STATS" -N
run_live_variant "promiscuous" "$DIAG_PROMISC_CTL" "$DIAG_PROMISC_PID" \
  "$DIAG_PROMISC_LOG" "$DIAG_PROMISC_STATS"

promiscuity_after="$(ip -n "$ROUTER_NAMESPACE" -details link show dev "$IPFIX_CAPTURE_INTERFACE" |
  awk '/promiscuity/ {for (i=1; i<=NF; i++) if ($i == "promiscuity") {print $(i+1); exit}}')"
[ "$promiscuity_before" = "$promiscuity_after" ] || \
  die "diagnostic did not restore hvr-lan promiscuity state"

processed_no_promisc="$(awk -F ': ' '/Packets processed:/ {print $2; exit}' "$DIAG_NO_PROMISC_STATS")"
processed_promisc="$(awk -F ': ' '/Packets processed:/ {print $2; exit}' "$DIAG_PROMISC_STATS")"
case "$processed_no_promisc" in ''|*[!0-9]*) die "could not parse -N processed-packet count" ;; esac
case "$processed_promisc" in ''|*[!0-9]*) die "could not parse promiscuous processed-packet count" ;; esac

{
  printf 'bounded_packets_per_variant=%s\n' "$DIAGNOSTIC_PACKET_COUNT"
  printf 'packet_payload_bytes=%s\n' "$DIAGNOSTIC_PACKET_SIZE"
  printf 'packet_interval_seconds=%s\n' "$DIAGNOSTIC_INTERVAL"
  printf 'no_promisc_packets_processed=%s\n' "$processed_no_promisc"
  printf 'promisc_packets_processed=%s\n' "$processed_promisc"
  if [ "$processed_no_promisc" -gt 0 ]; then
    printf 'classification=A: bounded high-volume traffic makes -N live processing begin; buffering/read-timeout behavior is strongly indicated.\n'
  elif [ "$processed_promisc" -gt 0 ]; then
    printf 'classification=B: only the promiscuous variant processes packets.\n'
  else
    printf 'classification=D-candidate: neither live variant processed the bounded burst; offline success still requires a separate exporter decision.\n'
  fi
} > "$IPFIX_LIVE_DIAGNOSTIC_FILE"

verify_r6_host_state
trap - EXIT INT TERM
printf 'R8 bounded live-capture diagnostic complete.\n'
cat "$IPFIX_LIVE_DIAGNOSTIC_FILE"
