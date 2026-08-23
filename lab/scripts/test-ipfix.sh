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
for required_command in ip pmacctd python3 ping dig nft sysctl systemctl; do
  command -v "$required_command" >/dev/null 2>&1 || die "$required_command is required"
done
require_r2_topology
pmacctd_running || die "R8 project pmacctd/nfprobe exporter is not running"
dns_r7_enabled || die "R7 DNS is not active"
client_address="$(client_dhcp_address)" || die "R6 dynamic client address is invalid"
snapshot_r6_host_state

collector_pid=""
cleanup_ipfix_test() {
  local status=$?
  trap - EXIT INT TERM
  if [ -n "$collector_pid" ] && kill -0 "$collector_pid" 2>/dev/null; then
    if project_process_matches "$collector_pid" python3 "$IPFIX_RECEIVER"; then
      kill "$collector_pid" 2>/dev/null || true
      wait "$collector_pid" 2>/dev/null || true
    else
      status=1
    fi
  fi
  verify_r6_host_state || status=1
  exit "$status"
}
trap cleanup_ipfix_test EXIT INT TERM

rm -f "$IPFIX_COLLECTOR_RESULT" "$IPFIX_COLLECTOR_READY" "$IPFIX_TRAFFIC_START"
ip netns exec "$UPSTREAM_NAMESPACE" python3 "$IPFIX_RECEIVER" \
  --bind "$IPFIX_COLLECTOR_HOST" --port "$IPFIX_COLLECTOR_PORT" \
  --client "$client_address" --traffic-start "$IPFIX_TRAFFIC_START" \
  --output "$IPFIX_COLLECTOR_RESULT" --ready "$IPFIX_COLLECTOR_READY" --timeout 12 &
collector_pid=$!
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -f "$IPFIX_COLLECTOR_READY" ] && break
  kill -0 "$collector_pid" 2>/dev/null || die "IPFIX test receiver exited before binding"
  sleep 0.05
done
[ -f "$IPFIX_COLLECTOR_READY" ] || die "IPFIX test receiver did not become ready"

# Deliberately tiny live workload: this is the regression test for softflowd buffering.
touch "$IPFIX_TRAFFIC_START"
ip netns exec "$CLIENT_NAMESPACE" ping -c 2 -W 1 "$UPSTREAM_GATEWAY" >/dev/null
ip netns exec "$CLIENT_NAMESPACE" dig +short +time=2 +tries=1 @"$ROUTER_LAN" "$DNS_TEST_NAME" A >/dev/null
ip netns exec "$CLIENT_NAMESPACE" dig +tcp +short +time=2 +tries=1 @"$ROUTER_LAN" "$DNS_TEST_NAME_ALT" A >/dev/null

if ! wait "$collector_pid"; then
  collector_pid=""
  [ ! -f "$IPFIX_COLLECTOR_RESULT" ] || sed 's/^/  /' "$IPFIX_COLLECTOR_RESULT" >&2
  die "pmacctd/nfprobe did not export a valid low-volume pre-NAT IPFIX flow within 12 seconds"
fi
collector_pid=""

grep -F -- '"version": 10' "$IPFIX_COLLECTOR_RESULT" >/dev/null || die "collector did not observe IPFIX v10"
grep -E '"datagrams": [1-9]' "$IPFIX_COLLECTOR_RESULT" >/dev/null || die "collector received no datagrams"
grep -E '"template_sets": [1-9]' "$IPFIX_COLLECTOR_RESULT" >/dev/null || die "collector received no templates"
grep -E '"data_sets": [1-9]' "$IPFIX_COLLECTOR_RESULT" >/dev/null || die "collector received no data sets"
grep -E '"records": [1-9]' "$IPFIX_COLLECTOR_RESULT" >/dev/null || die "collector decoded no records"
grep -F -- '"required_fields_complete": true' "$IPFIX_COLLECTOR_RESULT" >/dev/null || die "IPFIX template lacks required fields"
grep -F -- '"client_source_preserved": true' "$IPFIX_COLLECTOR_RESULT" >/dev/null || die "IPFIX lost the pre-NAT client source"
dns_r7_enabled || die "R8 test changed R7 DNS state"
client_dhcp_address >/dev/null || die "R8 test changed R6 DHCP state"
verify_r6_host_state
trap - EXIT INT TERM
printf 'R8 low-volume IPFIX test passed for pre-NAT client %s. Collector result:\n' "$client_address"
sed 's/^/  /' "$IPFIX_COLLECTOR_RESULT"
