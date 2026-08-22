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
for required_command in ip nft sysctl dnsmasq dhclient systemctl getent ss; do
  command -v "$required_command" >/dev/null 2>&1 || die "$required_command is required"
done
require_r2_topology
nat_rule_exists || die "R4 NAT state is required"
filter_rules_exist || die "R5 firewall state is required"
dnsmasq_dhcp_running || die "R6 project dnsmasq DHCP process is not running"
dhclient_running || die "R6 project DHCP client process is not running"
client_address_before="$(client_dhcp_address)" || die "R6 dynamic client address is invalid"
client_default_route_exists || die "R6 client default route is absent"
dns_r7_enabled && die "R7 DNS is already enabled"
upstream_dns_running && die "an R7 upstream DNS process already exists"
resolve_dnsmasq_identity
snapshot_r6_host_state

router_reconfigured=0
rollback_dns_enable() {
  local status=$?
  trap - EXIT INT TERM
  if [ "$router_reconfigured" -eq 1 ]; then
    stop_project_process_if_present "$DNSMASQ_PID_FILE" dnsmasq "$DNSMASQ_CONFIG" || status=1
    render_dnsmasq_config
    if ip netns exec "$ROUTER_NAMESPACE" dnsmasq --test --conf-file="$DNSMASQ_CONFIG" >/dev/null 2>&1; then
      ip netns exec "$ROUTER_NAMESPACE" dnsmasq --conf-file="$DNSMASQ_CONFIG" || status=1
    else
      status=1
    fi
  fi
  stop_project_process_if_present "$UPSTREAM_DNS_PID_FILE" dnsmasq "$UPSTREAM_DNS_CONFIG" || status=1
  remove_project_dns_files
  verify_r6_host_state || status=1
  exit "$status"
}
trap rollback_dns_enable EXIT INT TERM

mkdir -p "$DNS_RUNTIME_DIR"
chown 0:0 "$DNS_RUNTIME_DIR"
chmod 0755 "$DNS_RUNTIME_DIR"
rm -f "$DNS_ENABLED_FILE" "$UPSTREAM_DNS_PID_FILE"
touch "$DNS_LOG_FILE" "$UPSTREAM_DNS_LOG_FILE"
chown "$DNSMASQ_UID:$DNSMASQ_GID" "$DNS_LOG_FILE" "$UPSTREAM_DNS_LOG_FILE"
chmod 0640 "$DNS_LOG_FILE" "$UPSTREAM_DNS_LOG_FILE"
render_upstream_dns_config
ip netns exec "$UPSTREAM_NAMESPACE" dnsmasq --test --conf-file="$UPSTREAM_DNS_CONFIG" >/dev/null
ip netns exec "$UPSTREAM_NAMESPACE" dnsmasq --conf-file="$UPSTREAM_DNS_CONFIG"
upstream_dns_running || die "isolated upstream DNS process did not start"

stop_project_process "$DNSMASQ_PID_FILE" dnsmasq "$DNSMASQ_CONFIG"
router_reconfigured=1
render_router_dns_config
ip netns exec "$ROUTER_NAMESPACE" dnsmasq --test --conf-file="$DNSMASQ_CONFIG" >/dev/null
ip netns exec "$ROUTER_NAMESPACE" dnsmasq --conf-file="$DNSMASQ_CONFIG"
dnsmasq_dhcp_running || die "combined R7 DHCP/DNS process did not start"
touch "$DNS_ENABLED_FILE"

[ "$(client_dhcp_address)" = "$client_address_before" ] || die "R7 changed the DHCP client address"
client_default_route_exists || die "R7 changed the DHCP client default route"
dns_r7_enabled || die "R7 DNS state is incomplete"
verify_r6_host_state

router_reconfigured=0
trap - EXIT INT TERM
printf 'R7 DNS enabled on %s:53 with isolated upstream %s and cache size %s.\n' \
  "$ROUTER_LAN" "$DNS_UPSTREAM" "$DNS_CACHE_SIZE"
