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
for required_command in ip softflowd softflowctl tcpdump python3 ping dig nft sysctl systemctl; do
  command -v "$required_command" >/dev/null 2>&1 || die "$required_command is required"
done
require_project_ipfix_control_socket
require_r2_topology
softflowd_running || die "R8 project softflowd exporter is not running"
[ -S "$IPFIX_CONTROL_SOCKET" ] || die "project softflowd control socket is absent"
dns_r7_enabled || die "R7 DNS is not active"
client_address="$(client_dhcp_address)" || die "R6 dynamic client address is invalid"
snapshot_r6_host_state

collector_pid=""
tcpdump_pid=""
cleanup_ipfix_test() {
  local status=$?
  trap - EXIT INT TERM
  if [ -n "$tcpdump_pid" ] && kill -0 "$tcpdump_pid" 2>/dev/null; then
    if project_process_matches "$tcpdump_pid" tcpdump "$IPFIX_TEST_PCAP"; then
      kill -INT "$tcpdump_pid" 2>/dev/null || true
      wait "$tcpdump_pid" 2>/dev/null || true
    else
      status=1
    fi
  fi
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

rm -f "$IPFIX_COLLECTOR_RESULT" "$IPFIX_COLLECTOR_READY"
ip netns exec "$UPSTREAM_NAMESPACE" python3 "$IPFIX_RECEIVER" \
  --bind "$IPFIX_COLLECTOR_HOST" --port "$IPFIX_COLLECTOR_PORT" \
  --client "$client_address" --observation-domain "$IPFIX_OBSERVATION_DOMAIN_ID" \
  --output "$IPFIX_COLLECTOR_RESULT" --ready "$IPFIX_COLLECTOR_READY" &
collector_pid=$!
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -f "$IPFIX_COLLECTOR_READY" ] && break
  kill -0 "$collector_pid" 2>/dev/null || die "IPFIX test receiver exited before binding"
  sleep 0.05
done
[ -f "$IPFIX_COLLECTOR_READY" ] || die "IPFIX test receiver did not become ready"

rm -f "$IPFIX_TEST_PCAP" "$IPFIX_TCPDUMP_FILE" "$IPFIX_OFFLINE_FILE"
ip netns exec "$ROUTER_NAMESPACE" tcpdump -U -nn -i "$IPFIX_CAPTURE_INTERFACE" \
  -w "$IPFIX_TEST_PCAP" "ip and host $client_address" >/dev/null 2>&1 &
tcpdump_pid=$!
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$IPFIX_TEST_PCAP" ] && break
  kill -0 "$tcpdump_pid" 2>/dev/null || die "namespace tcpdump exited before capture became ready"
  sleep 0.05
done
[ -s "$IPFIX_TEST_PCAP" ] || die "namespace tcpdump did not become ready"

ip netns exec "$CLIENT_NAMESPACE" ping -c 2 -W 1 "$UPSTREAM_GATEWAY" >/dev/null
ip netns exec "$CLIENT_NAMESPACE" dig +short +time=2 +tries=1 @"$DNS_UPSTREAM" "$DNS_TEST_NAME" A >/dev/null
ip netns exec "$CLIENT_NAMESPACE" dig +tcp +short +time=2 +tries=1 @"$DNS_UPSTREAM" "$DNS_TEST_NAME_ALT" A >/dev/null

kill -INT "$tcpdump_pid"
wait "$tcpdump_pid"
tcpdump_pid=""
ip netns exec "$ROUTER_NAMESPACE" tcpdump -nn -r "$IPFIX_TEST_PCAP" \
  > "$IPFIX_TCPDUMP_FILE" 2>&1
grep -F -- "$client_address" "$IPFIX_TCPDUMP_FILE" >/dev/null || \
  die "hvr-lan pcap does not contain the dynamic client address"
grep -F -- "$UPSTREAM_GATEWAY" "$IPFIX_TCPDUMP_FILE" >/dev/null || \
  die "hvr-lan pcap does not contain client-to-upstream traffic"
grep -E 'link-type EN10MB|link-type Ethernet' "$IPFIX_TCPDUMP_FILE" >/dev/null || \
  die "hvr-lan pcap does not report an Ethernet datalink type"

if ! ip netns exec "$ROUTER_NAMESPACE" softflowd -d -r "$IPFIX_TEST_PCAP" -T full -- ip \
  > "$IPFIX_OFFLINE_FILE" 2>&1; then
  sed 's/^/  /' "$IPFIX_OFFLINE_FILE" >&2
  die "offline softflowd could not parse the hvr-lan pcap"
fi
grep -E 'Packets processed: [1-9][0-9]*' "$IPFIX_OFFLINE_FILE" >/dev/null || {
  sed 's/^/  /' "$IPFIX_OFFLINE_FILE" >&2
  die "hvr-lan sees traffic but offline softflowd processed zero packets"
}

ip netns exec "$ROUTER_NAMESPACE" softflowctl -c "$IPFIX_CONTROL_SOCKET" statistics \
  > "$IPFIX_STATISTICS_FILE" 2>&1 || {
  sed 's/^/  /' "$IPFIX_STATISTICS_FILE" >&2
  die "live project softflowd statistics query failed"
}
grep -E 'Packets processed: [1-9][0-9]*' "$IPFIX_STATISTICS_FILE" >/dev/null || {
  sed 's/^/  /' "$IPFIX_STATISTICS_FILE" >&2
  die "offline softflowd parses hvr-lan traffic but live softflowd processed zero packets"
}

tracked_flows=""
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if ip netns exec "$ROUTER_NAMESPACE" softflowctl \
    -c "$IPFIX_CONTROL_SOCKET" dump-flows > "$IPFIX_DUMP_FLOWS_FILE" 2>&1; then
    tracked_flows="$(cat "$IPFIX_DUMP_FLOWS_FILE")"
  else
    tracked_flows=""
  fi
  printf '%s\n' "$tracked_flows" | grep -F -- "$client_address" >/dev/null && break
  sleep 0.05
done
if ! printf '%s\n' "$tracked_flows" | grep -F -- "$client_address" >/dev/null; then
  sed 's/^/  /' "$IPFIX_DUMP_FLOWS_FILE" >&2
  die "softflowd did not track fresh traffic from the dynamic client"
fi
if ! ip netns exec "$ROUTER_NAMESPACE" softflowctl \
  -c "$IPFIX_CONTROL_SOCKET" expire-all > "$IPFIX_EXPIRE_ALL_FILE" 2>&1; then
  sed 's/^/  /' "$IPFIX_EXPIRE_ALL_FILE" >&2
  die "project softflowctl expire-all failed"
fi

if ! wait "$collector_pid"; then
  collector_pid=""
  [ ! -f "$IPFIX_COLLECTOR_RESULT" ] || sed 's/^/  /' "$IPFIX_COLLECTOR_RESULT" >&2
  die "IPFIX receiver did not validate templates, data, required fields, and pre-NAT client source"
fi
collector_pid=""

grep -F -- '"version": 10' "$IPFIX_COLLECTOR_RESULT" >/dev/null || die "collector did not observe IPFIX v10"
grep -F -- '"template_sets":' "$IPFIX_COLLECTOR_RESULT" >/dev/null || die "collector result lacks templates"
grep -F -- '"data_sets":' "$IPFIX_COLLECTOR_RESULT" >/dev/null || die "collector result lacks data sets"
grep -F -- '"required_fields_complete": true' "$IPFIX_COLLECTOR_RESULT" >/dev/null || die "IPFIX template lacks required supported fields"
grep -F -- '"client_source_preserved": true' "$IPFIX_COLLECTOR_RESULT" >/dev/null || die "IPFIX lost the pre-NAT client source"
dns_r7_enabled || die "R8 test changed R7 DNS state"
client_dhcp_address >/dev/null || die "R8 test changed R6 DHCP state"
verify_r6_host_state
trap - EXIT INT TERM
printf 'R8 IPFIX tests passed for pre-NAT client %s. Collector result:\n' "$client_address"
sed 's/^/  /' "$IPFIX_COLLECTOR_RESULT"
