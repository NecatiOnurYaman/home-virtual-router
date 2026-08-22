#!/usr/bin/env bash
set -euo pipefail

readonly expected_interface="hvr-client"
readonly expected_router="10.0.0.1"
readonly expected_dns="10.0.0.1"
readonly runtime_dir="/run/home-virtual-router/dhcp/client"
readonly state_file="$runtime_dir/client-state.env"
readonly resolv_file="$runtime_dir/client-resolv.conf"

[ "$(uname -s)" = "Linux" ] || exit 1
[ -f /etc/home-virtual-router-lab ] || exit 1
[ "${interface:-}" = "$expected_interface" ] || exit 1
[ -d "$runtime_dir" ] || exit 1

case "${reason:-}" in
  BOUND|RENEW|REBIND|REBOOT)
    [ "${new_subnet_mask:-}" = "255.255.255.0" ] || exit 1
    case "${new_ip_address:-}" in
      10.0.0.*) ;;
      *) exit 1 ;;
    esac
    host_number="${new_ip_address##*.}"
    [ "$host_number" -ge 100 ] && [ "$host_number" -le 199 ] || exit 1
    case " ${new_routers:-} " in *" $expected_router "*) ;; *) exit 1 ;; esac
    case " ${new_domain_name_servers:-} " in *" $expected_dns "*) ;; *) exit 1 ;; esac
    ip -4 address replace "$new_ip_address/24" dev "$interface"
    ip -4 route replace default via "$expected_router" dev "$interface"
    umask 077
    {
      printf 'CLIENT_ADDRESS=%s\n' "$new_ip_address"
      printf 'CLIENT_PREFIX=24\n'
      printf 'CLIENT_ROUTER=%s\n' "$expected_router"
      printf 'CLIENT_DNS=%s\n' "$expected_dns"
    } > "$state_file"
    printf 'nameserver %s\n' "$expected_dns" > "$resolv_file"
    ;;
  EXPIRE|FAIL|RELEASE|STOP)
    if [ -n "${old_ip_address:-}" ]; then
      ip -4 address del "$old_ip_address/24" dev "$interface" 2>/dev/null || true
    fi
    ip -4 route del default via "$expected_router" dev "$interface" 2>/dev/null || true
    rm -f "$state_file" "$resolv_file"
    ;;
  PREINIT)
    ip link set "$interface" up
    ;;
esac
