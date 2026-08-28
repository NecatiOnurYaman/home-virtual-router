#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=physical-common.sh
source "$script_dir/physical-common.sh"
require_root
load_topology_config
require_physical_authorization
[ "$#" -eq 2 ] || die "usage: physical-stage.sh STAGE enable|disable"
stage="$1" action="$2"
rollback=0
rollback_enable() {
  status=$?
  trap - EXIT INT TERM
  if [ "$status" -ne 0 ] && [ "$rollback" -eq 1 ]; then
    case "$stage" in
      metrics-export) stop_metrics_exporter_if_present || true ;;
      ipfix) stop_project_pmacctd_if_present || true ;;
      dns)
        stop_project_process_if_present "$DNSMASQ_PID_FILE" dnsmasq "$DNSMASQ_CONFIG" || true
        rm -f -- "$DNS_ENABLED_FILE"
        render_dnsmasq_config
        physical_start_dnsmasq || true
        ;;
      dhcp) stop_project_process_if_present "$DNSMASQ_PID_FILE" dnsmasq "$DNSMASQ_CONFIG" || true; remove_project_dhcp_files ;;
      firewall) filter_table_exists && delete_project_filter_table || true ;;
      nat) nat_table_exists && delete_project_nat_table || true ;;
      routing) [ ! -e "$PHYSICAL_FORWARDING_ORIGINAL" ] || physical_routing_disable || true ;;
      topology) [ ! -e "$PHYSICAL_MAP_FILE" ] || physical_topology_disable || true ;;
    esac
  fi
  exit "$status"
}
trap rollback_enable EXIT INT TERM
if [ "$action" = enable ]; then rollback=1; fi
case "$stage:$action" in
  topology:enable) physical_topology_enable ;;
  topology:disable) physical_topology_disable ;;
  routing:enable) physical_topology_healthy || die "physical topology is not healthy"; physical_routing_enable ;;
  routing:disable) physical_routing_disable ;;
  nat:enable) physical_routing_healthy || die "physical forwarding is not enabled"; nat_table_exists && die "project NAT table already exists"; create_project_nat_table; nat_rule_exists || die "physical NAT rule is incomplete" ;;
  nat:disable) nat_rule_exists || die "physical NAT ownership is inconsistent"; delete_project_nat_table ;;
  firewall:enable) nat_rule_exists || die "physical NAT must be healthy"; filter_table_exists && die "project firewall table already exists"; create_project_filter_table; filter_rules_exist || die "physical firewall is incomplete" ;;
  firewall:disable) filter_rules_exist || die "physical firewall ownership is inconsistent"; delete_project_filter_table ;;
  dhcp:enable) filter_rules_exist || die "physical firewall must be healthy"; physical_dhcp_enable ;;
  dhcp:disable) physical_dhcp_disable ;;
  dns:enable) physical_dns_enable ;;
  dns:disable) physical_dns_disable ;;
  ipfix:enable) physical_dns_healthy || die "physical DNS must be healthy"; physical_ipfix_enable ;;
  ipfix:disable) physical_ipfix_disable ;;
  metrics-export:enable) "$HVR_REPO_DIR/lab/scripts/enable-metrics-export.sh" ;;
  metrics-export:disable) "$HVR_REPO_DIR/lab/scripts/disable-metrics-export.sh" ;;
  *) die "unsupported physical stage action: $stage:$action" ;;
esac
rollback=0
trap - EXIT INT TERM
