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
for required_command in ip nft sysctl dnsmasq systemctl; do
  command -v "$required_command" >/dev/null 2>&1 || die "$required_command is required"
done
require_r2_topology
pmacct_core_running && die "disable R8 IPFIX before disabling R7 DNS"
dns_r7_enabled || die "R7 DNS is not enabled"
client_address_before="$(client_dhcp_address)" || die "R6 dynamic client address is invalid"
client_default_route_exists || die "R6 client default route is absent"
snapshot_r6_host_state
router_changed=0
upstream_stopped=0
rollback_dns_disable() {
  local status=$?
  trap - EXIT INT TERM
  if [ "$status" -ne 0 ] && [ "$router_changed" -eq 1 ]; then
    stop_project_process_if_present "$DNSMASQ_PID_FILE" dnsmasq "$DNSMASQ_CONFIG" || status=1
    render_router_dns_config
    ip netns exec "$ROUTER_NAMESPACE" dnsmasq --conf-file="$DNSMASQ_CONFIG" || status=1
    touch "$DNS_ENABLED_FILE"
  fi
  if [ "$status" -ne 0 ] && [ "$upstream_stopped" -eq 1 ]; then
    render_upstream_dns_config
    ip netns exec "$UPSTREAM_NAMESPACE" dnsmasq --conf-file="$UPSTREAM_DNS_CONFIG" || status=1
  fi
  verify_r6_host_state || status=1
  exit "$status"
}
trap rollback_dns_disable EXIT INT TERM

stop_project_process "$DNSMASQ_PID_FILE" dnsmasq "$DNSMASQ_CONFIG"
router_changed=1
render_dnsmasq_config
ip netns exec "$ROUTER_NAMESPACE" dnsmasq --test --conf-file="$DNSMASQ_CONFIG" >/dev/null
ip netns exec "$ROUTER_NAMESPACE" dnsmasq --conf-file="$DNSMASQ_CONFIG"
dnsmasq_dhcp_running || die "R6 DHCP-only dnsmasq did not restart"

stop_project_process_if_present "$UPSTREAM_DNS_PID_FILE" dnsmasq "$UPSTREAM_DNS_CONFIG"
upstream_stopped=1
[ "$(client_dhcp_address)" = "$client_address_before" ] || die "DNS disable changed the DHCP client address"
client_default_route_exists || die "DNS disable changed the DHCP client default route"
grep -F -x -- "port=0" "$DNSMASQ_CONFIG" >/dev/null || die "dnsmasq did not return to R6 DHCP-only mode"
verify_r6_host_state
remove_project_dns_files
router_changed=0
upstream_stopped=0
trap - EXIT INT TERM
printf 'R7 DNS disabled; R6 DHCP lease, address, route, routing, NAT, and firewall remain active.\n'
