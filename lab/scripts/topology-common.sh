#!/usr/bin/env bash

# Shared, data-only topology definitions and guards. Sourcing changes no network state.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HVR_REPO_DIR="$(cd "$script_dir/../.." && pwd)"
readonly HVR_CONFIG="$HVR_REPO_DIR/lab/config/defaults.env"
readonly HVR_VALIDATOR="$HVR_REPO_DIR/router/scripts/validate_config.py"
readonly DHCP_RUNTIME_DIR="/run/home-virtual-router/dhcp"
readonly DNSMASQ_CONFIG_TEMPLATE="$HVR_REPO_DIR/router/config/dnsmasq-dhcp.conf.template"
readonly DNSMASQ_CONFIG="$DHCP_RUNTIME_DIR/dnsmasq.conf"
readonly DHCLIENT_CONFIG="$HVR_REPO_DIR/router/config/dhclient.conf"
readonly DHCLIENT_HOOK_SOURCE="$HVR_REPO_DIR/router/scripts/dhclient-lab-hook.sh"
readonly DHCLIENT_RUNTIME_DIR="$DHCP_RUNTIME_DIR/client"
readonly DHCLIENT_RUNTIME_BINARY="$DHCLIENT_RUNTIME_DIR/dhclient"
readonly DHCLIENT_HOOK="$DHCLIENT_RUNTIME_DIR/dhclient-lab-hook.sh"
readonly DNSMASQ_PID_FILE="$DHCP_RUNTIME_DIR/dnsmasq.pid"
readonly DNSMASQ_LEASE_FILE="$DHCP_RUNTIME_DIR/dnsmasq.leases"
readonly DNSMASQ_LOG_FILE="$DHCP_RUNTIME_DIR/dnsmasq.log"
readonly DHCLIENT_PID_FILE="$DHCLIENT_RUNTIME_DIR/dhclient.pid"
readonly DHCLIENT_LEASE_FILE="$DHCLIENT_RUNTIME_DIR/dhclient.leases"
readonly DHCP_CLIENT_STATE_FILE="$DHCLIENT_RUNTIME_DIR/client-state.env"
readonly DHCP_CLIENT_RESOLV_FILE="$DHCLIENT_RUNTIME_DIR/client-resolv.conf"

# These variables are populated only from an allowlist after Python validation.
UPSTREAM_SUBNET=""
UPSTREAM_GATEWAY=""
ROUTER_WAN=""
LAN_SUBNET=""
ROUTER_LAN=""
CLIENT_ADDRESS=""
UPSTREAM_NAMESPACE=""
ROUTER_NAMESPACE=""
CLIENT_NAMESPACE=""
UPSTREAM_INTERFACE=""
ROUTER_WAN_INTERFACE=""
ROUTER_LAN_INTERFACE=""
CLIENT_INTERFACE=""
NAT_TABLE=""
NAT_CHAIN=""
FILTER_TABLE=""
FILTER_CHAIN=""
DHCP_RANGE_START=""
DHCP_RANGE_END=""
DHCP_LEASE_TIME=""
DHCP_DNS_SERVER=""
DNSMASQ_UID=""
DNSMASQ_GID=""

load_topology_config() {
  python3 "$HVR_VALIDATOR" "$HVR_CONFIG" >/dev/null
  while IFS='=' read -r key value; do
    case "$key" in
      UPSTREAM_SUBNET) UPSTREAM_SUBNET="$value" ;;
      UPSTREAM_GATEWAY) UPSTREAM_GATEWAY="$value" ;;
      ROUTER_WAN) ROUTER_WAN="$value" ;;
      LAN_SUBNET) LAN_SUBNET="$value" ;;
      ROUTER_LAN) ROUTER_LAN="$value" ;;
      CLIENT_ADDRESS) CLIENT_ADDRESS="$value" ;;
      UPSTREAM_NAMESPACE) UPSTREAM_NAMESPACE="$value" ;;
      ROUTER_NAMESPACE) ROUTER_NAMESPACE="$value" ;;
      CLIENT_NAMESPACE) CLIENT_NAMESPACE="$value" ;;
      UPSTREAM_INTERFACE) UPSTREAM_INTERFACE="$value" ;;
      ROUTER_WAN_INTERFACE) ROUTER_WAN_INTERFACE="$value" ;;
      ROUTER_LAN_INTERFACE) ROUTER_LAN_INTERFACE="$value" ;;
      CLIENT_INTERFACE) CLIENT_INTERFACE="$value" ;;
      NAT_TABLE) NAT_TABLE="$value" ;;
      NAT_CHAIN) NAT_CHAIN="$value" ;;
      FILTER_TABLE) FILTER_TABLE="$value" ;;
      FILTER_CHAIN) FILTER_CHAIN="$value" ;;
      DHCP_RANGE_START) DHCP_RANGE_START="$value" ;;
      DHCP_RANGE_END) DHCP_RANGE_END="$value" ;;
      DHCP_LEASE_TIME) DHCP_LEASE_TIME="$value" ;;
      DHCP_DNS_SERVER) DHCP_DNS_SERVER="$value" ;;
    esac
  done < "$HVR_CONFIG"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "root privileges are required; run this command with sudo"
}

namespace_exists() {
  ip netns list | awk '{print $1}' | grep -F -x -- "$1" >/dev/null 2>&1
}

host_interface_exists() {
  ip link show dev "$1" >/dev/null 2>&1
}

capture_default_route() {
  local route
  route="$(ip -o route show default)"
  [ -n "$route" ] || die "the Ubuntu VM has no default route; refusing lab operation"
  printf '%s' "$route"
}

require_default_route_is_not_lab_interface() {
  local route="$1"
  local interface
  for interface in "$UPSTREAM_INTERFACE" "$ROUTER_WAN_INTERFACE" "$ROUTER_LAN_INTERFACE" "$CLIENT_INTERFACE"; do
    if printf '%s\n' "$route" | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}' | grep -F -x -- "$interface" >/dev/null 2>&1; then
      die "default route uses reserved lab interface $interface; refusing lab operation"
    fi
  done
}

verify_default_route_unchanged() {
  local before="$1"
  local after
  after="$(capture_default_route)" || return 1
  [ "$before" = "$after" ] || die "the Ubuntu VM default route changed unexpectedly"
}

capture_host_ipv4_forwarding() {
  sysctl -n net.ipv4.ip_forward
}

verify_host_ipv4_forwarding_unchanged() {
  local before="$1"
  local after
  after="$(capture_host_ipv4_forwarding)" || return 1
  [ "$before" = "$after" ] || die "the Ubuntu VM host IPv4 forwarding value changed unexpectedly"
}

validate_topology_names() {
  local namespace interface
  for namespace in "$UPSTREAM_NAMESPACE" "$ROUTER_NAMESPACE" "$CLIENT_NAMESPACE"; do
    require_explicit_namespace "$namespace" || return 1
  done
  for interface in "$UPSTREAM_INTERFACE" "$ROUTER_WAN_INTERFACE" "$ROUTER_LAN_INTERFACE" "$CLIENT_INTERFACE"; do
    require_explicit_interface "$interface" || return 1
  done
  require_explicit_nft_table "$NAT_TABLE" || return 1
  require_explicit_nft_chain "$NAT_CHAIN" || return 1
  require_explicit_nft_table "$FILTER_TABLE" || return 1
  require_explicit_nft_chain "$FILTER_CHAIN" || return 1
}

is_known_namespace() {
  case "$1" in
    "$UPSTREAM_NAMESPACE"|"$ROUTER_NAMESPACE"|"$CLIENT_NAMESPACE") return 0 ;;
    *) return 1 ;;
  esac
}

is_known_interface() {
  case "$1" in
    "$UPSTREAM_INTERFACE"|"$ROUTER_WAN_INTERFACE"|"$ROUTER_LAN_INTERFACE"|"$CLIENT_INTERFACE") return 0 ;;
    *) return 1 ;;
  esac
}

client_default_route_exists() {
  ip -n "$CLIENT_NAMESPACE" -o route show default | awk \
    -v gateway="$ROUTER_LAN" -v interface="$CLIENT_INTERFACE" '
      $1 == "default" {
        via = ""; dev = ""
        for (i = 1; i <= NF; i++) {
          if ($i == "via") via = $(i + 1)
          if ($i == "dev") dev = $(i + 1)
        }
        if (via == gateway && dev == interface) found = 1
      }
      END { exit !found }
    '
}

upstream_return_route_exists() {
  ip -n "$UPSTREAM_NAMESPACE" -o route show "$LAN_SUBNET" | awk \
    -v subnet="$LAN_SUBNET" -v gateway="$ROUTER_WAN" -v interface="$UPSTREAM_INTERFACE" '
      $1 == subnet {
        via = ""; dev = ""
        for (i = 1; i <= NF; i++) {
          if ($i == "via") via = $(i + 1)
          if ($i == "dev") dev = $(i + 1)
        }
        if (via == gateway && dev == interface) found = 1
      }
      END { exit !found }
    '
}

require_r2_topology() {
  local namespace
  for namespace in "$UPSTREAM_NAMESPACE" "$ROUTER_NAMESPACE" "$CLIENT_NAMESPACE"; do
    namespace_exists "$namespace" || die "required R2 namespace is absent: $namespace"
  done
}

capture_host_nftables() {
  nft --stateless list ruleset
}

verify_host_nftables_unchanged() {
  local before="$1"
  local after
  after="$(capture_host_nftables)" || return 1
  [ "$before" = "$after" ] || die "the Ubuntu VM host nftables ruleset changed unexpectedly"
}

capture_host_dns_config() {
  printf 'target=%s\n' "$(readlink /etc/resolv.conf 2>/dev/null || true)"
  cat /etc/resolv.conf 2>/dev/null || true
}

capture_host_dnsmasq_service_state() {
  systemctl show dnsmasq.service --property=LoadState,ActiveState,UnitFileState 2>&1 || true
}

capture_host_interface_state() {
  printf '[links]\n'
  ip -o link show | normalize_host_link_state
  printf '[ipv4]\n'
  ip -o -4 address show | normalize_host_ipv4_state
}

normalize_host_link_state() {
  awk -F ': ' '
    {
      name = $2
      sub(/@.*/, "", name)
      mac = "-"
      count = split($3, fields, " ")
      for (i = 1; i <= count; i++) {
        if (fields[i] == "link/ether") mac = fields[i + 1]
      }
      print name, mac
    }
  ' | sort
}

normalize_host_ipv4_state() {
  awk '{print $2, $4}' | sort
}

verify_snapshot_unchanged() {
  local label="$1" before="$2" after="$3"
  [ "$before" = "$after" ] || die "$label changed unexpectedly"
}

router_nft() {
  ip netns exec "$ROUTER_NAMESPACE" nft "$@"
}

nat_table_exists() {
  router_nft list table ip "$NAT_TABLE" >/dev/null 2>&1
}

create_project_nat_table() {
  router_nft add table ip "$NAT_TABLE"
  router_nft add chain ip "$NAT_TABLE" "$NAT_CHAIN" \
    '{ type nat hook postrouting priority srcnat; }'
  router_nft add rule ip "$NAT_TABLE" "$NAT_CHAIN" \
    oifname "$ROUTER_WAN_INTERFACE" ip saddr "$LAN_SUBNET" \
    counter masquerade comment "hvr-r4-masquerade"
}

delete_project_nat_table() {
  router_nft delete table ip "$NAT_TABLE"
}

nat_rule_exists() {
  local rules
  rules="$(router_nft list chain ip "$NAT_TABLE" "$NAT_CHAIN" 2>/dev/null)" || return 1
  printf '%s\n' "$rules" | grep -F -- "type nat hook postrouting priority srcnat" >/dev/null || return 1
  printf '%s\n' "$rules" | grep -F -- "oifname \"$ROUTER_WAN_INTERFACE\"" >/dev/null || return 1
  printf '%s\n' "$rules" | grep -F -- "ip saddr $LAN_SUBNET" >/dev/null || return 1
  printf '%s\n' "$rules" | grep -F -- "masquerade" >/dev/null || return 1
  printf '%s\n' "$rules" | grep -F -- "comment \"hvr-r4-masquerade\"" >/dev/null
}

filter_table_exists() {
  router_nft list table inet "$FILTER_TABLE" >/dev/null 2>&1
}

create_project_filter_table() {
  router_nft add table inet "$FILTER_TABLE"
  router_nft add chain inet "$FILTER_TABLE" "$FILTER_CHAIN" \
    '{ type filter hook forward priority filter; policy drop; }'
  router_nft add rule inet "$FILTER_TABLE" "$FILTER_CHAIN" \
    ct state invalid counter drop comment "hvr-r5-invalid-drop"
  router_nft add rule inet "$FILTER_TABLE" "$FILTER_CHAIN" \
    ct state established,related counter accept comment "hvr-r5-established-accept"
  router_nft add rule inet "$FILTER_TABLE" "$FILTER_CHAIN" \
    ct state new iifname "$ROUTER_LAN_INTERFACE" oifname "$ROUTER_WAN_INTERFACE" \
    ip saddr "$LAN_SUBNET" counter accept comment "hvr-r5-lan-wan-accept"
  router_nft add rule inet "$FILTER_TABLE" "$FILTER_CHAIN" \
    ct state new iifname "$ROUTER_WAN_INTERFACE" oifname "$ROUTER_LAN_INTERFACE" \
    counter drop comment "hvr-r5-wan-lan-drop"
}

delete_project_filter_table() {
  router_nft delete table inet "$FILTER_TABLE"
}

filter_rules_exist() {
  local rules
  rules="$(router_nft list chain inet "$FILTER_TABLE" "$FILTER_CHAIN" 2>/dev/null)" || return 1
  printf '%s\n' "$rules" | grep -F -- "type filter hook forward priority filter; policy drop;" >/dev/null || return 1
  printf '%s\n' "$rules" | grep -F -- "ct state invalid" | grep -F -- "drop" | grep -F -- "hvr-r5-invalid-drop" >/dev/null || return 1
  printf '%s\n' "$rules" | grep -F -- "ct state established,related" | grep -F -- "accept" | grep -F -- "hvr-r5-established-accept" >/dev/null || return 1
  printf '%s\n' "$rules" | grep -F -- "ct state new" | grep -F -- "iifname \"$ROUTER_LAN_INTERFACE\"" | grep -F -- "oifname \"$ROUTER_WAN_INTERFACE\"" | grep -F -- "ip saddr $LAN_SUBNET" | grep -F -- "accept" | grep -F -- "hvr-r5-lan-wan-accept" >/dev/null || return 1
  printf '%s\n' "$rules" | grep -F -- "ct state new" | grep -F -- "iifname \"$ROUTER_WAN_INTERFACE\"" | grep -F -- "oifname \"$ROUTER_LAN_INTERFACE\"" | grep -F -- "drop" | grep -F -- "hvr-r5-wan-lan-drop" >/dev/null
}

filter_rule_packet_count() {
  local comment="$1"
  router_nft list chain inet "$FILTER_TABLE" "$FILTER_CHAIN" | awk -v marker="$comment" '
    index($0, "comment \"" marker "\"") {
      for (i = 1; i <= NF; i++) {
        if ($i == "packets") {
          print $(i + 1)
          found = 1
          exit
        }
      }
    }
    END { if (!found) exit 1 }
  '
}

require_r4_nat_state() {
  [ "$(ip netns exec "$ROUTER_NAMESPACE" sysctl -n net.ipv4.ip_forward)" = "1" ] ||
    die "router-namespace forwarding must be enabled"
  client_default_route_exists || die "client default route must be present"
  nat_rule_exists || die "exact R4 masquerade state is required"
  if ip -n "$UPSTREAM_NAMESPACE" route show "$LAN_SUBNET" | grep -q .; then
    die "R4 requires no upstream route to $LAN_SUBNET"
  fi
}

read_project_pid() {
  local file="$1" pid
  [ -r "$file" ] || return 1
  pid="$(cat "$file")"
  case "$pid" in *[!0-9]*|'') return 1 ;; esac
  printf '%s' "$pid"
}

project_process_matches() {
  local pid="$1" executable="$2" marker="$3" command_line
  [ -r "/proc/$pid/cmdline" ] || return 1
  command_line="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
  printf '%s\n' "$command_line" | grep -F -- "$executable" >/dev/null || return 1
  printf '%s\n' "$command_line" | grep -F -- "$marker" >/dev/null
}

stop_project_process() {
  local file="$1" executable="$2" marker="$3" pid attempt
  pid="$(read_project_pid "$file")" || return 0
  project_process_matches "$pid" "$executable" "$marker" ||
    die "PID file $file does not identify the expected project process"
  kill "$pid"
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  kill -0 "$pid" 2>/dev/null && die "project process $pid did not stop"
  rm -f "$file"
}

stop_project_process_if_present() {
  local file="$1" executable="$2" marker="$3" pid
  [ -e "$file" ] || return 0
  if ! pid="$(read_project_pid "$file")"; then
    rm -f "$file"
    return 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$file"
    return 0
  fi
  project_process_matches "$pid" "$executable" "$marker" ||
    die "PID file $file references a live process that is not the expected project process"
  stop_project_process "$file" "$executable" "$marker"
}

resolve_dnsmasq_identity() {
  local passwd_entry account_name
  passwd_entry="$(getent passwd dnsmasq 2>/dev/null)" ||
    { die "dnsmasq system user is missing; install/configure dnsmasq explicitly before enabling R6"; return 1; }
  IFS=: read -r account_name _ DNSMASQ_UID DNSMASQ_GID _ <<< "$passwd_entry"
  [ "$account_name" = "dnsmasq" ] || {
    die "system account lookup returned an unexpected dnsmasq entry"
    return 1
  }
  case "$DNSMASQ_UID:$DNSMASQ_GID" in
    *[!0-9:]*) die "dnsmasq system account has an invalid numeric UID or primary GID"; return 1 ;;
    :*|*:) die "dnsmasq system account lacks a numeric UID or primary GID"; return 1 ;;
  esac
}

remove_project_dhcp_files() {
  rm -f -- \
    "$DNSMASQ_CONFIG" "$DNSMASQ_PID_FILE" "$DNSMASQ_LEASE_FILE" "$DNSMASQ_LOG_FILE" \
    "$DHCLIENT_PID_FILE" "$DHCLIENT_LEASE_FILE" "$DHCP_CLIENT_STATE_FILE" \
    "$DHCP_CLIENT_RESOLV_FILE" "$DHCLIENT_HOOK" "$DHCLIENT_RUNTIME_BINARY"
  rmdir "$DHCLIENT_RUNTIME_DIR" 2>/dev/null || true
  rmdir "$DHCP_RUNTIME_DIR" 2>/dev/null || true
}

dnsmasq_dhcp_running() {
  local pid
  pid="$(read_project_pid "$DNSMASQ_PID_FILE")" || return 1
  project_process_matches "$pid" dnsmasq "$DNSMASQ_CONFIG"
}

dhclient_running() {
  local pid
  pid="$(read_project_pid "$DHCLIENT_PID_FILE")" || return 1
  project_process_matches "$pid" "$DHCLIENT_RUNTIME_BINARY" "$CLIENT_INTERFACE"
}

address_in_dhcp_pool() {
  local address="$1" host_number start_number end_number
  case "$address" in 10.0.0.*) ;; *) return 1 ;; esac
  host_number="${address##*.}"
  start_number="${DHCP_RANGE_START##*.}"
  end_number="${DHCP_RANGE_END##*.}"
  [ "$host_number" -ge "$start_number" ] && [ "$host_number" -le "$end_number" ]
}

client_dhcp_address() {
  local addresses address count=0 selected="" total=0
  addresses="$(ip -n "$CLIENT_NAMESPACE" -o -4 address show dev "$CLIENT_INTERFACE" scope global | awk '{print $4}')"
  for address in $addresses; do
    total=$((total + 1))
    [ "${address#*/}" = "24" ] || continue
    address="${address%/*}"
    if address_in_dhcp_pool "$address"; then
      count=$((count + 1))
      selected="$address"
    fi
  done
  [ "$total" -eq 1 ] && [ "$count" -eq 1 ] || return 1
  printf '%s' "$selected"
}

client_static_address_exists() {
  ip -n "$CLIENT_NAMESPACE" -o -4 address show dev "$CLIENT_INTERFACE" scope global |
    awk '{print $4}' | grep -F -x -- "$CLIENT_ADDRESS/${LAN_SUBNET#*/}" >/dev/null
}

remove_client_dhcp_addresses() {
  local addresses address
  addresses="$(ip -n "$CLIENT_NAMESPACE" -o -4 address show dev "$CLIENT_INTERFACE" scope global | awk '{print $4}')"
  for address in $addresses; do
    if [ "${address#*/}" = "24" ] && address_in_dhcp_pool "${address%/*}"; then
      ip -n "$CLIENT_NAMESPACE" address del "$address" dev "$CLIENT_INTERFACE"
    fi
  done
}

snapshot_r6_host_state() {
  R6_HOST_DEFAULT_ROUTE="$(capture_default_route)"
  require_default_route_is_not_lab_interface "$R6_HOST_DEFAULT_ROUTE"
  R6_HOST_FORWARDING="$(capture_host_ipv4_forwarding)"
  R6_HOST_NFTABLES="$(capture_host_nftables)"
  R6_HOST_DNS="$(capture_host_dns_config)"
  R6_HOST_DNSMASQ_SERVICE="$(capture_host_dnsmasq_service_state)"
  R6_HOST_INTERFACES="$(capture_host_interface_state)"
}

verify_r6_host_state() {
  verify_default_route_unchanged "$R6_HOST_DEFAULT_ROUTE" || return 1
  verify_host_ipv4_forwarding_unchanged "$R6_HOST_FORWARDING" || return 1
  verify_host_nftables_unchanged "$R6_HOST_NFTABLES" || return 1
  verify_snapshot_unchanged "Ubuntu VM host DNS configuration" "$R6_HOST_DNS" "$(capture_host_dns_config)" || return 1
  verify_snapshot_unchanged "Ubuntu VM host dnsmasq service state" "$R6_HOST_DNSMASQ_SERVICE" "$(capture_host_dnsmasq_service_state)" || return 1
  verify_snapshot_unchanged "Ubuntu VM host interface configuration" "$R6_HOST_INTERFACES" "$(capture_host_interface_state)"
}

render_dnsmasq_config() {
  {
    printf '# Generated from %s and %s\n' "$DNSMASQ_CONFIG_TEMPLATE" "$HVR_CONFIG"
    printf 'port=0\n'
    printf 'interface=%s\n' "$ROUTER_LAN_INTERFACE"
    printf 'bind-interfaces\n'
    printf 'dhcp-authoritative\n'
    printf 'dhcp-range=%s,%s,255.255.255.0,%s\n' "$DHCP_RANGE_START" "$DHCP_RANGE_END" "$DHCP_LEASE_TIME"
    printf 'dhcp-option=option:router,%s\n' "$ROUTER_LAN"
    printf 'dhcp-option=option:netmask,255.255.255.0\n'
    printf 'dhcp-option=option:dns-server,%s\n' "$DHCP_DNS_SERVER"
    printf 'dhcp-leasefile=%s\n' "$DNSMASQ_LEASE_FILE"
    printf 'pid-file=%s\n' "$DNSMASQ_PID_FILE"
    printf 'log-facility=%s\n' "$DNSMASQ_LOG_FILE"
    printf 'log-dhcp\n'
  } > "$DNSMASQ_CONFIG"
}
