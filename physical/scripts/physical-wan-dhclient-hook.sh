#!/usr/bin/env bash
set -euo pipefail

state_dir=/run/home-virtual-router/physical/wan-dhcp
state_file="$state_dir/state.env"
log_file="$state_dir/dhclient-hook.log"

[ "$0" = "$state_dir/dhclient-hook" ] || exit 1
[ "${interface:-}" = "$(cat "$state_dir/interface" 2>/dev/null)" ] || exit 1

prefix_from_netmask() {
  python3 - "$1" <<'PY'
import ipaddress, sys
print(ipaddress.IPv4Network(f"0.0.0.0/{sys.argv[1]}").prefixlen)
PY
}

write_state() {
  local prefix temporary
  prefix="$(prefix_from_netmask "$new_subnet_mask")"
  temporary="$(mktemp "$state_dir/state.env.XXXXXX")"
  {
    printf 'WAN_INTERFACE=%s\n' "$interface"
    printf 'WAN_ADDRESS=%s\n' "$new_ip_address"
    printf 'WAN_PREFIX_LENGTH=%s\n' "$prefix"
    printf 'WAN_GATEWAY=%s\n' "${new_routers%% *}"
    printf 'DHCP_REASON=%s\n' "$reason"
    printf 'DHCP_LEASE_TIME=%s\n' "${new_dhcp_lease_time:-unknown}"
    printf 'DHCP_RENEWAL_TIME=%s\n' "${new_dhcp_renewal_time:-unknown}"
    printf 'DHCP_REBINDING_TIME=%s\n' "${new_dhcp_rebinding_time:-unknown}"
  } > "$temporary"
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$state_file"
}

remove_old_state() {
  local old_address="${old_ip_address:-}" old_prefix=""
  if [ -n "${old_subnet_mask:-}" ]; then old_prefix="$(prefix_from_netmask "$old_subnet_mask")"; fi
  if [ -n "${old_routers:-}" ]; then
    ip route del default via "${old_routers%% *}" dev "$interface" 2>/dev/null || true
  fi
  if [ -n "$old_address" ] && [ -n "$old_prefix" ]; then
    ip address del "$old_address/$old_prefix" dev "$interface" 2>/dev/null || true
  fi
}

printf '%s reason=%s interface=%s address=%s gateway=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${reason:-unknown}" "$interface" \
  "${new_ip_address:-${old_ip_address:-none}}" "${new_routers:-${old_routers:-none}}" >> "$log_file"
chmod 0600 "$log_file"

case "${reason:-}" in
  BOUND|RENEW|REBIND|REBOOT|TIMEOUT)
    [ -n "${new_ip_address:-}" ] && [ -n "${new_subnet_mask:-}" ] && [ -n "${new_routers:-}" ] || exit 1
    prefix="$(prefix_from_netmask "$new_subnet_mask")"
    if [ -n "${old_ip_address:-}" ] && [ "$old_ip_address" != "$new_ip_address" ]; then remove_old_state; fi
    ip address replace "$new_ip_address/$prefix" dev "$interface"
    ip route replace default via "${new_routers%% *}" dev "$interface"
    write_state
    ;;
  EXPIRE|FAIL|RELEASE|STOP)
    remove_old_state
    rm -f -- "$state_file"
    ;;
  PREINIT|MEDIUM) ;;
esac

# This hook deliberately never updates /etc/resolv.conf or host resolver state.
exit 0
