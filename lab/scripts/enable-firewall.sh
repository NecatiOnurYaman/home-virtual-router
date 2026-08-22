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
if filter_table_exists; then
  die "nftables table inet $FILTER_TABLE already exists in $ROUTER_NAMESPACE; refusing conflicting state"
fi

default_route_before="$(capture_default_route)"
require_default_route_is_not_lab_interface "$default_route_before"
host_forwarding_before="$(capture_host_ipv4_forwarding)"
host_nftables_before="$(capture_host_nftables)"

table_created=0
rollback_firewall_enable() {
  local status=$?
  trap - EXIT INT TERM
  if [ "$table_created" -eq 1 ]; then
    delete_project_filter_table 2>/dev/null || true
  fi
  verify_default_route_unchanged "$default_route_before" || status=1
  verify_host_ipv4_forwarding_unchanged "$host_forwarding_before" || status=1
  verify_host_nftables_unchanged "$host_nftables_before" || status=1
  exit "$status"
}
trap rollback_firewall_enable EXIT INT TERM

table_created=1
create_project_filter_table
filter_rules_exist || die "exact R5 forwarding policy was not created"
nat_rule_exists || die "R4 NAT state changed unexpectedly"
require_r4_nat_state
verify_default_route_unchanged "$default_route_before"
verify_host_ipv4_forwarding_unchanged "$host_forwarding_before"
verify_host_nftables_unchanged "$host_nftables_before"

table_created=0
trap - EXIT INT TERM
printf 'R5 stateful forwarding firewall enabled inside hvr-router only.\n'
