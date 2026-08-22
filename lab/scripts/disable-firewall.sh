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
command -v ip >/dev/null 2>&1 || die "iproute2 is required"
command -v nft >/dev/null 2>&1 || die "nftables is required"
command -v sysctl >/dev/null 2>&1 || die "sysctl is required"
require_r2_topology
require_r4_nat_state

table_was_present=0
if filter_table_exists; then
  filter_rules_exist || die "table inet $FILTER_TABLE exists but does not match the exact R5 policy"
  table_was_present=1
fi

default_route_before="$(capture_default_route)"
require_default_route_is_not_lab_interface "$default_route_before"
host_forwarding_before="$(capture_host_ipv4_forwarding)"
host_nftables_before="$(capture_host_nftables)"

table_deleted=0
rollback_firewall_disable() {
  local status=$?
  trap - EXIT INT TERM
  if [ "$table_deleted" -eq 1 ]; then
    create_project_filter_table 2>/dev/null || true
  fi
  verify_default_route_unchanged "$default_route_before" || status=1
  verify_host_ipv4_forwarding_unchanged "$host_forwarding_before" || status=1
  verify_host_nftables_unchanged "$host_nftables_before" || status=1
  exit "$status"
}
trap rollback_firewall_disable EXIT INT TERM

if [ "$table_was_present" -eq 1 ]; then
  delete_project_filter_table
  table_deleted=1
fi
if filter_table_exists; then
  die "project filter table still exists after disable"
fi
require_r4_nat_state
verify_default_route_unchanged "$default_route_before"
verify_host_ipv4_forwarding_unchanged "$host_forwarding_before"
verify_host_nftables_unchanged "$host_nftables_before"

table_deleted=0
trap - EXIT INT TERM
printf 'R5 firewall disabled; R4 NAT and routing remain enabled.\n'
