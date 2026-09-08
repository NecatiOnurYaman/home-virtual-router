#!/usr/bin/env bash
set -u
status_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status_repo_dir="$(cd "$status_script_dir/../.." && pwd)"
# shellcheck source=../../lab/scripts/runtime-common.sh
source "$status_repo_dir/lab/scripts/runtime-common.sh"
load_topology_config || exit 1
unit_active_state() {
  local state
  state="$(systemctl show -p ActiveState --value "$1" 2>/dev/null || true)"
  printf '%s\n' "${state:-not-installed}"
}
unit_enabled_state() {
  local state
  state="$(systemctl is-enabled "$1" 2>/dev/null || true)"
  printf '%s\n' "${state:-not-installed}"
}
printf 'R16 persistent deployment status\n'
for unit in home-virtual-router.service home-virtual-router-health.timer home-virtual-router-health.service; do
  printf '  %-39s %s\n' "$unit" "$(unit_active_state "$unit")"
done
printf '  %-39s %s\n' 'main enabled' "$(unit_enabled_state home-virtual-router.service)"
printf '  %-39s %s\n' 'health timer enabled' "$(unit_enabled_state home-virtual-router-health.timer)"
printf '  configured WAN/LAN                      %s / %s\n' "$PHYSICAL_WAN_INTERFACE" "$PHYSICAL_LAN_INTERFACE"
for interface in "$PHYSICAL_WAN_INTERFACE" "$PHYSICAL_LAN_INTERFACE"; do
  if command -v nmcli >/dev/null 2>&1; then
    managed="$(nmcli -g GENERAL.NM-MANAGED device show "$interface" 2>/dev/null || echo unavailable)"
  else
    managed=unavailable
  fi
  printf '  NetworkManager %-24s %s\n' "$interface" "$managed"
done
if [ "$(physical_wan_mode)" = dhcp ] && physical_wan_dhcp_state_valid; then
  printf '  WAN lease/address/gateway               %s/%s via %s\n' \
    "$(physical_effective_wan_address)" "$(physical_effective_wan_prefix)" "$(physical_effective_wan_gateway)"
else
  printf '  WAN lease/address/gateway               unavailable or static\n'
fi
if command -v timedatectl >/dev/null 2>&1; then
  synchronized="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  case "$synchronized" in yes) ;; no) echo '  warning: host clock is not reported NTP-synchronized' ;; esac
fi
"$status_repo_dir/lab/scripts/runtime-status.sh" || true
