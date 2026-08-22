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
for required_command in ip dnsmasq dig ss systemctl nft sysctl; do
  command -v "$required_command" >/dev/null 2>&1 || die "$required_command is required"
done
require_r2_topology
dns_r7_enabled || die "R7 DNS is not enabled"
snapshot_r6_host_state
verify_host_on_exit() {
  local status=$?
  trap - EXIT
  verify_r6_host_state || status=1
  exit "$status"
}
trap verify_host_on_exit EXIT

listeners="$(ip netns exec "$ROUTER_NAMESPACE" ss -lntuH)"
printf '%s\n' "$listeners" | awk -v endpoint="$ROUTER_LAN:53" '
  ($1 == "udp" || $1 == "tcp") && $5 == endpoint { seen[$1] = 1 }
  ($1 == "udp" || $1 == "tcp") && $5 ~ /:53$/ && $5 != endpoint { bad = 1 }
  END { exit !(seen["udp"] && seen["tcp"] && !bad) }
' || die "DNS must listen on UDP/TCP $ROUTER_LAN:53 and nowhere else in hvr-router"

router_dns_pid="$(read_project_pid "$DNSMASQ_PID_FILE")" || die "router DNS PID file is invalid"
project_process_matches "$router_dns_pid" dnsmasq "$DNSMASQ_CONFIG" || die "router DNS PID is not the project process"
log_start_lines="$(wc -l < "$DNS_LOG_FILE")"
kill -HUP "$router_dns_pid"
sleep 0.1
udp_answer="$(ip netns exec "$CLIENT_NAMESPACE" dig +short +time=2 +tries=1 @"$ROUTER_LAN" "$DNS_TEST_NAME" A)"
[ "$udp_answer" = "$DNS_TEST_ADDRESS" ] || die "UDP DNS returned an unexpected answer for $DNS_TEST_NAME"
ip netns exec "$CLIENT_NAMESPACE" dig +short +time=2 +tries=1 @"$ROUTER_LAN" "$DNS_TEST_NAME" A >/dev/null
tcp_answer="$(ip netns exec "$CLIENT_NAMESPACE" dig +tcp +short +time=2 +tries=1 @"$ROUTER_LAN" "$DNS_TEST_NAME_ALT" A)"
[ "$tcp_answer" = "$DNS_TEST_ADDRESS_ALT" ] || die "TCP DNS returned an unexpected answer for $DNS_TEST_NAME_ALT"

new_log=""
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  new_log="$(tail -n "+$((log_start_lines + 1))" "$DNS_LOG_FILE")"
  printf '%s\n' "$new_log" | grep -F -- "cached $DNS_TEST_NAME is $DNS_TEST_ADDRESS" >/dev/null && break
  sleep 0.05
done
printf '%s\n' "$new_log" | grep -F -- "query[A] $DNS_TEST_NAME from" >/dev/null || die "DNS query log lacks client/query metadata"
printf '%s\n' "$new_log" | grep -F -- "forwarded $DNS_TEST_NAME to $DNS_UPSTREAM" >/dev/null || die "DNS query was not forwarded to the isolated upstream"
printf '%s\n' "$new_log" | grep -F -- "reply $DNS_TEST_NAME is $DNS_TEST_ADDRESS" >/dev/null || die "DNS log lacks the deterministic reply"
printf '%s\n' "$new_log" | grep -F -- "cached $DNS_TEST_NAME is $DNS_TEST_ADDRESS" >/dev/null || die "repeated query was not served from dnsmasq cache"
printf '%s\n' "$new_log" | grep -F -- "$DNS_TEST_NAME_ALT" >/dev/null || die "TCP query was not logged"

client_dhcp_address >/dev/null || die "R7 test lost the R6 DHCP address"
client_default_route_exists || die "R7 test lost the R6 default route"
verify_r6_host_state
trap - EXIT
printf 'R7 DNS tests passed: isolated UDP/TCP forwarding, native query logs, and cache reuse verified.\n'
