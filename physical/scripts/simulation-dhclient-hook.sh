#!/usr/bin/env bash
set -euo pipefail

readonly expected_interface="hvr-sim-client"
readonly state_dir="/run/home-virtual-router/physical-simulation"
readonly context_file="$state_dir/client-netns"
[ "$(id -u)" -eq 0 ] || exit 1
[ "$0" = "$state_dir/dhclient-hook" ] || exit 1
[ "$(stat -c %u:%g:%a "$context_file" 2>/dev/null)" = 0:0:600 ] || exit 1
[ "$(cat "$context_file")" = "$(readlink /proc/self/ns/net)" ] || exit 1
[ "${interface:-}" = "$expected_interface" ] || exit 1
install -d -o 0 -g 0 -m 0700 "$state_dir"
printf '%s interface=%s address=%s\n' "${reason:-unknown}" "${interface:-}" "${new_ip_address:-}" >> "$state_dir/dhclient-hook.log"
chmod 0600 "$state_dir/dhclient-hook.log"

case "${reason:-}" in
  BOUND|RENEW|REBIND|REBOOT)
    [ "${new_subnet_mask:-}" = 255.255.255.0 ] || exit 1
    case " ${new_routers:-} " in *" 10.0.0.1 "*) ;; *) exit 1 ;; esac
    ip -4 address replace "$new_ip_address/24" dev "$interface"
    ip -4 route replace default via 10.0.0.1 dev "$interface"
    printf 'CLIENT_ADDRESS=%s\nCLIENT_ROUTER=10.0.0.1\n' "$new_ip_address" > "$state_dir/client-state.env"
    ;;
  EXPIRE|FAIL|RELEASE|STOP)
    [ -z "${old_ip_address:-}" ] || ip -4 address del "$old_ip_address/24" dev "$interface" 2>/dev/null || true
    ip -4 route del default via 10.0.0.1 dev "$interface" 2>/dev/null || true
    rm -f -- "$state_dir/client-state.env"
    ;;
  PREINIT) ip link set "$interface" up ;;
esac
