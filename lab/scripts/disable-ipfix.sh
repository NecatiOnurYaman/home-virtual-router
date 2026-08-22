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
require_project_ipfix_control_socket
for required_command in ip nft sysctl systemctl; do
  command -v "$required_command" >/dev/null 2>&1 || die "$required_command is required"
done
require_r2_topology
dns_r7_enabled || die "R7 DNS state must remain active during R8 disable"
snapshot_r6_host_state

verify_host_on_exit() {
  local status=$?
  trap - EXIT
  verify_r6_host_state || status=1
  exit "$status"
}
trap verify_host_on_exit EXIT

stop_project_softflowd_if_present
remove_project_ipfix_files
dns_r7_enabled || die "R8 disable changed R7 DNS state"
client_dhcp_address >/dev/null || die "R8 disable changed R6 DHCP state"
nat_rule_exists || die "R8 disable changed R4 NAT state"
filter_rules_exist || die "R8 disable changed R5 firewall state"
verify_r6_host_state
trap - EXIT
printf 'R8 IPFIX disabled; R7 DNS and the R2-R6 router stack remain active.\n'
