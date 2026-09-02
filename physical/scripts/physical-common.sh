#!/usr/bin/env bash

physical_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F require_lab_environment >/dev/null; then
  # shellcheck source=../../router/scripts/safety.sh
  source "$physical_script_dir/../../router/scripts/safety.sh"
fi
if ! declare -F load_topology_config >/dev/null; then
  # shellcheck source=../../lab/scripts/topology-common.sh
  source "$physical_script_dir/../../lab/scripts/topology-common.sh"
fi

readonly PHYSICAL_AUTHORIZATION_MARKER="/etc/home-virtual-router/allow-physical-deployment"
readonly PHYSICAL_RUNTIME_DIR="/run/home-virtual-router/physical"
readonly PHYSICAL_MAP_FILE="$PHYSICAL_RUNTIME_DIR/interface-map.env"
readonly PHYSICAL_WAN_ADDRESS_OWNED="$PHYSICAL_RUNTIME_DIR/wan-address-owned"
readonly PHYSICAL_LAN_ADDRESS_OWNED="$PHYSICAL_RUNTIME_DIR/lan-address-owned"
readonly PHYSICAL_WAN_LINK_OWNED="$PHYSICAL_RUNTIME_DIR/wan-link-owned"
readonly PHYSICAL_LAN_LINK_OWNED="$PHYSICAL_RUNTIME_DIR/lan-link-owned"
readonly PHYSICAL_DEFAULT_ROUTE_OWNED="$PHYSICAL_RUNTIME_DIR/default-route-owned"
readonly PHYSICAL_FORWARDING_ORIGINAL="$PHYSICAL_RUNTIME_DIR/forwarding-original"
readonly PHYSICAL_RUNTIME_STATE="/run/home-virtual-router/runtime/state.env"
readonly PHYSICAL_RUNTIME_CONFIG_SNAPSHOT="/run/home-virtual-router/runtime/config.snapshot"

require_physical_authorization() {
  require_linux || return 1
  [ "$DEPLOYMENT_MODE" = "physical" ] || die "DEPLOYMENT_MODE must be physical"
  if [ "${HVR_INTERNAL_PHYSICAL_SIMULATION:-}" = 1 ]; then
    [ "$HVR_CONFIG" = "${HVR_INTERNAL_SIMULATION_CONFIG:-}" ] || die "physical simulation config identity is inconsistent"
    [ "$(id -u)" -eq 0 ] || die "physical simulation requires root"
    [ "$(readlink /proc/self/ns/net)" != "${HVR_INTERNAL_OUTER_NET_NAMESPACE:-}" ] &&
      [ "$(readlink /proc/self/ns/mnt)" != "${HVR_INTERNAL_OUTER_MOUNT_NAMESPACE:-}" ] ||
      die "physical simulation requires isolated network and mount namespaces"
    return 0
  fi
  [ -f "$PHYSICAL_AUTHORIZATION_MARKER" ] || die "physical deployment is not authorized on this host; create $PHYSICAL_AUTHORIZATION_MARKER deliberately"
  [ "$HVR_CONFIG" = "$HVR_LOCAL_CONFIG" ] || die "physical deployment requires the fixed machine-local config $HVR_LOCAL_CONFIG"
  [ "$(stat -c %u "$HVR_CONFIG")" = 0 ] || die "physical configuration must be owned by root"
  [ "$(stat -c %u "$PHYSICAL_AUTHORIZATION_MARKER")" = 0 ] || die "physical authorization marker must be owned by root"
  [ -z "$(find "$HVR_CONFIG" "$PHYSICAL_AUTHORIZATION_MARKER" -maxdepth 0 -perm /022 -print -quit)" ] ||
    die "physical configuration and authorization marker must not be group/world writable"
}

physical_interface_exists() { ip link show dev "$1" >/dev/null 2>&1; }
physical_interface_is_up() { ip -o link show dev "$1" | grep -q '<[^>]*UP[^>]*>'; }
physical_address_exists() { ip -o -4 address show dev "$1" | awk '{print $4}' | grep -F -x -- "$2" >/dev/null; }
physical_interface_is_ethernet() { [ "$(cat "/sys/class/net/$1/type" 2>/dev/null)" = 1 ]; }
physical_interface_is_bridge() { [ -e "/sys/class/net/$1/bridge" ]; }
physical_interface_is_veth() {
  ip -details link show dev "$1" 2>/dev/null | grep -Eq '(^|[[:space:]])veth([[:space:]]|$)'
}
physical_private_simulation_interface_eligible() {
  local interface="$1" current_netns current_mountns
  [ "${HVR_INTERNAL_PHYSICAL_SIMULATION:-0}" = 1 ] && [ "$(id -u)" -eq 0 ] || return 1
  [ -n "${HVR_INTERNAL_SIMULATION_CONFIG:-}" ] && [ "$HVR_CONFIG" = "$HVR_INTERNAL_SIMULATION_CONFIG" ] || return 1
  [ -n "${HVR_INTERNAL_OUTER_NET_NAMESPACE:-}" ] && [ -n "${HVR_INTERNAL_OUTER_MOUNT_NAMESPACE:-}" ] || return 1
  current_netns="$(readlink /proc/self/ns/net 2>/dev/null)" || return 1
  current_mountns="$(readlink /proc/self/ns/mnt 2>/dev/null)" || return 1
  [ "$current_netns" != "$HVR_INTERNAL_OUTER_NET_NAMESPACE" ] &&
    [ "$current_mountns" != "$HVR_INTERNAL_OUTER_MOUNT_NAMESPACE" ] || return 1
  [ "$PHYSICAL_WAN_INTERFACE" = hvr-sim-wan ] && [ "$PHYSICAL_LAN_INTERFACE" = hvr-sim-lan ] || return 1
  case "$interface" in hvr-sim-wan|hvr-sim-lan) ;; *) return 1 ;; esac
  physical_interface_exists "$interface" && physical_interface_is_veth "$interface"
}
physical_interface_is_deployment_eligible() {
  local interface="$1" lab_interface
  physical_private_simulation_interface_eligible "$interface" && return 0
  [ "$interface" != lo ] && physical_interface_is_ethernet "$interface" || return 1
  for lab_interface in "$UPSTREAM_INTERFACE" "$LAB_ROUTER_WAN_INTERFACE" "$LAB_ROUTER_LAN_INTERFACE" \
    "$CLIENT_INTERFACE" "$TELEMETRY_HOST_INTERFACE" "$TELEMETRY_ROUTER_INTERFACE"; do
    [ "$interface" != "$lab_interface" ] || return 1
  done
  ! physical_interface_is_bridge "$interface" && ! physical_interface_is_veth "$interface"
}
physical_default_route_exact() {
  ip -o -4 route show default | awk -v gateway="$PHYSICAL_WAN_GATEWAY" -v interface="$PHYSICAL_WAN_INTERFACE" '
    $1 == "default" { via=""; dev=""; for (i=1;i<=NF;i++) { if ($i=="via") via=$(i+1); if ($i=="dev") dev=$(i+1) } if (via==gateway && dev==interface) found=1 }
    END { exit !found }
  '
}

physical_default_route_interface() {
  ip -o -4 route show default | awk 'NR == 1 { for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }'
}

physical_render_map() {
  printf 'MAP_VERSION=2\n'
  printf 'DEPLOYMENT_MODE=physical\n'
  printf 'ROUTER_NETNS=%s\n' "$(readlink /proc/self/ns/net)"
  printf 'WAN_INTERFACE=%s\n' "$PHYSICAL_WAN_INTERFACE"
  printf 'WAN_IFINDEX=%s\n' "$(cat "/sys/class/net/$PHYSICAL_WAN_INTERFACE/ifindex")"
  printf 'WAN_MAC=%s\n' "$(cat "/sys/class/net/$PHYSICAL_WAN_INTERFACE/address")"
  printf 'LAN_INTERFACE=%s\n' "$PHYSICAL_LAN_INTERFACE"
  printf 'LAN_IFINDEX=%s\n' "$(cat "/sys/class/net/$PHYSICAL_LAN_INTERFACE/ifindex")"
  printf 'LAN_MAC=%s\n' "$(cat "/sys/class/net/$PHYSICAL_LAN_INTERFACE/address")"
  printf 'WAN_ADDRESS=%s/%s\n' "$PHYSICAL_WAN_ADDRESS" "$PHYSICAL_WAN_PREFIX_LENGTH"
  printf 'WAN_GATEWAY=%s\n' "$PHYSICAL_WAN_GATEWAY"
  printf 'LAN_ADDRESS=%s/%s\n' "$ROUTER_LAN" "${LAN_SUBNET#*/}"
}

physical_map_matches_live_config() {
  [ -r "$PHYSICAL_MAP_FILE" ] && cmp -s "$PHYSICAL_MAP_FILE" <(physical_render_map)
}

physical_single_default_route_exact() {
  ip -o -4 route show default | awk -v gateway="$PHYSICAL_WAN_GATEWAY" -v interface="$PHYSICAL_WAN_INTERFACE" '
    $1 == "default" {
      count++; via=""; dev=""
      for (i=1;i<=NF;i++) { if ($i=="via") via=$(i+1); if ($i=="dev") dev=$(i+1) }
      if (via==gateway && dev==interface) exact++
    }
    END { exit !(count==1 && exact==1) }
  '
}

physical_runtime_owns_active_topology() {
  local deployment status owned
  [ -r "$PHYSICAL_RUNTIME_STATE" ] && [ -r "$PHYSICAL_RUNTIME_CONFIG_SNAPSHOT" ] || return 1
  cmp -s "$HVR_CONFIG" "$PHYSICAL_RUNTIME_CONFIG_SNAPSHOT" || return 1
  deployment="$(python3 "$HVR_REPO_DIR/router/runtime/state.py" show "$PHYSICAL_RUNTIME_STATE" --field deployment 2>/dev/null)" || return 1
  status="$(python3 "$HVR_REPO_DIR/router/runtime/state.py" show "$PHYSICAL_RUNTIME_STATE" --field status 2>/dev/null)" || return 1
  owned="$(python3 "$HVR_REPO_DIR/router/runtime/state.py" show "$PHYSICAL_RUNTIME_STATE" --field owned 2>/dev/null)" || return 1
  [ "$deployment" = physical ] && [ "$status" = running ] || return 1
  case ",$owned," in *,topology,*) ;; *) return 1 ;; esac
  case ",$owned," in *,routing,*) ;; *) return 1 ;; esac
}

physical_default_route_ownership_present() {
  [ -e "$PHYSICAL_DEFAULT_ROUTE_OWNED" ] || [ -L "$PHYSICAL_DEFAULT_ROUTE_OWNED" ]
}

physical_active_topology_ownership_present() {
  [ -e "$PHYSICAL_MAP_FILE" ] || [ -L "$PHYSICAL_MAP_FILE" ] ||
    [ -e "$PHYSICAL_RUNTIME_STATE" ] || [ -L "$PHYSICAL_RUNTIME_STATE" ] ||
    [ -e "$PHYSICAL_RUNTIME_CONFIG_SNAPSHOT" ] || [ -L "$PHYSICAL_RUNTIME_CONFIG_SNAPSHOT" ]
}

physical_active_topology_ownership_verified() {
  [ -f "$PHYSICAL_MAP_FILE" ] &&
    [ -f "$PHYSICAL_RUNTIME_STATE" ] && [ -f "$PHYSICAL_RUNTIME_CONFIG_SNAPSHOT" ] &&
    [ "$(stat -c %u:%a "$PHYSICAL_MAP_FILE")" = 0:640 ] &&
    [ "$(stat -c %u:%a "$PHYSICAL_RUNTIME_STATE")" = 0:640 ] &&
    [ "$(stat -c %u:%a "$PHYSICAL_RUNTIME_CONFIG_SNAPSHOT")" = 0:640 ] &&
    physical_map_matches_live_config && physical_runtime_owns_active_topology
}

physical_owned_management_route_verified() {
  [ -f "$PHYSICAL_DEFAULT_ROUTE_OWNED" ] && [ ! -L "$PHYSICAL_DEFAULT_ROUTE_OWNED" ] &&
    [ "$(stat -c %u "$PHYSICAL_DEFAULT_ROUTE_OWNED")" = 0 ] &&
    physical_active_topology_ownership_verified && physical_single_default_route_exact
}

physical_external_management_route_verified() {
  ! physical_default_route_ownership_present &&
    physical_active_topology_ownership_verified && physical_single_default_route_exact
}

physical_require_management_ack() {
  local default_interface
  default_interface="$(physical_default_route_interface)"
  if [ "$default_interface" = "$PHYSICAL_WAN_INTERFACE" ] || [ "$default_interface" = "$PHYSICAL_LAN_INTERFACE" ]; then
    if physical_default_route_ownership_present; then
      if ! physical_owned_management_route_verified; then
        die "physical runtime ownership mismatch for the configured default route; stop safely or restore the recorded configuration and interface identity"
        return 1
      fi
      return 0
    fi
    if physical_active_topology_ownership_present; then
      if ! physical_external_management_route_verified; then
        die "physical runtime topology or external default-route identity is inconsistent; stop safely or restore the recorded configuration and interface identity"
        return 1
      fi
      if [ "$PHYSICAL_MANAGEMENT_INTERFACE_ACK" != "$default_interface" ]; then
        die "$default_interface carries the pre-existing external default route; acknowledge that exact interface with PHYSICAL_MANAGEMENT_INTERFACE_ACK=$default_interface"
        return 1
      fi
      return 0
    fi
    if [ "$PHYSICAL_MANAGEMENT_INTERFACE_ACK" != "$default_interface" ]; then
      die "$default_interface carries the current default route; ownership is not established; acknowledge that exact interface with PHYSICAL_MANAGEMENT_INTERFACE_ACK=$default_interface"
      return 1
    fi
  fi
}

physical_interface_unmanaged() {
  local interface="$1" output
  if command -v nmcli >/dev/null 2>&1; then
    output="$(nmcli -t -f GENERAL.STATE device show "$interface" 2>/dev/null || true)"
    if [ -n "$output" ] && ! printf '%s\n' "$output" | grep -Eiq 'unmanaged|^[^:]*:10[[:space:]]'; then
      die "$interface is managed by NetworkManager; prepare this exact dedicated interface as unmanaged"
      return 1
    fi
  fi
  if command -v networkctl >/dev/null 2>&1; then
    output="$(networkctl status --no-pager "$interface" 2>/dev/null || true)"
    if printf '%s\n' "$output" | grep -E '^[[:space:]]*Network File:[[:space:]]+/' >/dev/null; then
      die "$interface is managed by systemd-networkd; prepare this exact dedicated interface as unmanaged"
      return 1
    fi
  fi
}

physical_host_dnsmasq_service_absent() {
  [ "${HVR_INTERNAL_PHYSICAL_SIMULATION:-0}" = 1 ] && return 0
  if systemctl is-active --quiet dnsmasq.service; then
    die "dnsmasq.service is active and conflicts with HVR's dedicated physical DHCP/DNS ownership; stop and disable that host service deliberately before physical deployment"
    return 1
  fi
}

physical_preflight() {
  local interface addresses desired
  require_physical_authorization
  physical_host_dnsmasq_service_absent
  [ "$PHYSICAL_WAN_INTERFACE" != "$PHYSICAL_LAN_INTERFACE" ] ||
    die "R14 requires two distinct configured deployment interfaces: WAN and LAN"
  for interface in "$PHYSICAL_WAN_INTERFACE" "$PHYSICAL_LAN_INTERFACE"; do
    physical_interface_exists "$interface" || die "configured deployment interface does not exist: $interface; R14 requires explicit WAN and LAN interfaces"
    physical_interface_is_deployment_eligible "$interface" ||
      die "$interface is not an eligible pre-existing Ethernet deployment interface"
    physical_interface_unmanaged "$interface"
  done
  physical_require_management_ack
  for interface in "$PHYSICAL_WAN_INTERFACE" "$PHYSICAL_LAN_INTERFACE"; do
    if [ "$interface" = "$PHYSICAL_WAN_INTERFACE" ]; then desired="$PHYSICAL_WAN_ADDRESS/$PHYSICAL_WAN_PREFIX_LENGTH"; else desired="$ROUTER_LAN/${LAN_SUBNET#*/}"; fi
    addresses="$(ip -o -4 address show dev "$interface" scope global | awk '{print $4}')"
    if [ -n "$addresses" ] && [ "$addresses" != "$desired" ]; then
      die "$interface has conflicting IPv4 state; expected only $desired or no global address"
    fi
  done
  if ip -o -4 route show default | grep -q . && ! physical_default_route_exact; then
    die "an existing default route conflicts with the configured physical WAN gateway/interface"
  fi
}

physical_write_map() {
  install -d -m 0750 -o 0 -g 0 "$PHYSICAL_RUNTIME_DIR"
  physical_render_map > "$PHYSICAL_MAP_FILE"
  chmod 0640 "$PHYSICAL_MAP_FILE"
}

physical_topology_healthy() {
  physical_map_matches_live_config &&
    physical_interface_exists "$PHYSICAL_WAN_INTERFACE" && physical_interface_exists "$PHYSICAL_LAN_INTERFACE" &&
    physical_interface_is_up "$PHYSICAL_WAN_INTERFACE" && physical_interface_is_up "$PHYSICAL_LAN_INTERFACE" &&
    physical_address_exists "$PHYSICAL_WAN_INTERFACE" "$PHYSICAL_WAN_ADDRESS/$PHYSICAL_WAN_PREFIX_LENGTH" &&
    physical_address_exists "$PHYSICAL_LAN_INTERFACE" "$ROUTER_LAN/${LAN_SUBNET#*/}" && physical_default_route_exact
}

physical_topology_absent() {
  [ ! -e "$PHYSICAL_MAP_FILE" ] && physical_preflight >/dev/null
}

physical_topology_enable() {
  physical_preflight
  physical_write_map
  if ! physical_interface_is_up "$PHYSICAL_WAN_INTERFACE"; then ip link set dev "$PHYSICAL_WAN_INTERFACE" up; touch "$PHYSICAL_WAN_LINK_OWNED"; fi
  if ! physical_interface_is_up "$PHYSICAL_LAN_INTERFACE"; then ip link set dev "$PHYSICAL_LAN_INTERFACE" up; touch "$PHYSICAL_LAN_LINK_OWNED"; fi
  if ! physical_address_exists "$PHYSICAL_WAN_INTERFACE" "$PHYSICAL_WAN_ADDRESS/$PHYSICAL_WAN_PREFIX_LENGTH"; then
    ip address add "$PHYSICAL_WAN_ADDRESS/$PHYSICAL_WAN_PREFIX_LENGTH" dev "$PHYSICAL_WAN_INTERFACE"; touch "$PHYSICAL_WAN_ADDRESS_OWNED"
  fi
  if ! physical_address_exists "$PHYSICAL_LAN_INTERFACE" "$ROUTER_LAN/${LAN_SUBNET#*/}"; then
    ip address add "$ROUTER_LAN/${LAN_SUBNET#*/}" dev "$PHYSICAL_LAN_INTERFACE"; touch "$PHYSICAL_LAN_ADDRESS_OWNED"
  fi
  if ! physical_default_route_exact; then
    ip route add default via "$PHYSICAL_WAN_GATEWAY" dev "$PHYSICAL_WAN_INTERFACE"; touch "$PHYSICAL_DEFAULT_ROUTE_OWNED"
  fi
  physical_topology_healthy || die "physical interfaces did not reach the exact configured state"
}

physical_topology_disable() {
  [ -r "$PHYSICAL_MAP_FILE" ] || die "physical ownership map is absent; refusing interface teardown"
  if [ -e "$PHYSICAL_DEFAULT_ROUTE_OWNED" ]; then ip route del default via "$PHYSICAL_WAN_GATEWAY" dev "$PHYSICAL_WAN_INTERFACE"; fi
  if [ -e "$PHYSICAL_LAN_ADDRESS_OWNED" ]; then ip address del "$ROUTER_LAN/${LAN_SUBNET#*/}" dev "$PHYSICAL_LAN_INTERFACE"; fi
  if [ -e "$PHYSICAL_WAN_ADDRESS_OWNED" ]; then ip address del "$PHYSICAL_WAN_ADDRESS/$PHYSICAL_WAN_PREFIX_LENGTH" dev "$PHYSICAL_WAN_INTERFACE"; fi
  if [ -e "$PHYSICAL_LAN_LINK_OWNED" ]; then ip link set dev "$PHYSICAL_LAN_INTERFACE" down; fi
  if [ -e "$PHYSICAL_WAN_LINK_OWNED" ]; then ip link set dev "$PHYSICAL_WAN_INTERFACE" down; fi
  rm -f -- "$PHYSICAL_DEFAULT_ROUTE_OWNED" "$PHYSICAL_LAN_ADDRESS_OWNED" "$PHYSICAL_WAN_ADDRESS_OWNED" "$PHYSICAL_LAN_LINK_OWNED" "$PHYSICAL_WAN_LINK_OWNED" "$PHYSICAL_MAP_FILE"
  rmdir "$PHYSICAL_RUNTIME_DIR" 2>/dev/null || true
}

physical_routing_healthy() { [ "$(sysctl -n net.ipv4.ip_forward)" = 1 ]; }
physical_routing_absent() { [ ! -e "$PHYSICAL_FORWARDING_ORIGINAL" ]; }
physical_routing_enable() {
  install -d -m 0750 -o 0 -g 0 "$PHYSICAL_RUNTIME_DIR"
  sysctl -n net.ipv4.ip_forward > "$PHYSICAL_FORWARDING_ORIGINAL"
  chmod 0640 "$PHYSICAL_FORWARDING_ORIGINAL"
  [ "$(cat "$PHYSICAL_FORWARDING_ORIGINAL")" = 1 ] || sysctl -q -w net.ipv4.ip_forward=1
  physical_routing_healthy || die "failed to enable physical host IPv4 forwarding"
}
physical_routing_disable() {
  [ -r "$PHYSICAL_FORWARDING_ORIGINAL" ] || die "physical forwarding ownership snapshot is absent"
  original="$(cat "$PHYSICAL_FORWARDING_ORIGINAL")"
  case "$original" in 0|1) ;; *) die "physical forwarding snapshot is malformed" ;; esac
  [ "$(sysctl -n net.ipv4.ip_forward)" = "$original" ] || sysctl -q -w net.ipv4.ip_forward="$original"
  rm -f -- "$PHYSICAL_FORWARDING_ORIGINAL"
}

physical_dnsmasq_process_healthy() {
  local pid
  pid="$(read_project_pid "$DNSMASQ_PID_FILE")" || return 1
  dnsmasq_dhcp_running && process_is_in_router_namespace "$pid" &&
    [ "$(readlink "/proc/$pid/ns/pid" 2>/dev/null)" = "$(readlink /proc/self/ns/pid 2>/dev/null)" ]
}

physical_dhcp_config_healthy() {
  grep -F -x "interface=$PHYSICAL_LAN_INTERFACE" "$DNSMASQ_CONFIG" >/dev/null 2>&1 &&
    grep -F -x 'except-interface=lo' "$DNSMASQ_CONFIG" >/dev/null 2>&1 &&
    grep -F -x 'bind-interfaces' "$DNSMASQ_CONFIG" >/dev/null 2>&1 &&
    grep -F -x 'dhcp-authoritative' "$DNSMASQ_CONFIG" >/dev/null 2>&1 &&
    grep -F -x "dhcp-range=$DHCP_RANGE_START,$DHCP_RANGE_END,255.255.255.0,$DHCP_LEASE_TIME" "$DNSMASQ_CONFIG" >/dev/null 2>&1 &&
    grep -F -x "dhcp-option=option:router,$ROUTER_LAN" "$DNSMASQ_CONFIG" >/dev/null 2>&1 &&
    grep -F -x "dhcp-option=option:dns-server,$DHCP_DNS_SERVER" "$DNSMASQ_CONFIG" >/dev/null 2>&1 &&
    grep -F -x "dhcp-leasefile=$DNSMASQ_LEASE_FILE" "$DNSMASQ_CONFIG" >/dev/null 2>&1 &&
    grep -F -x "pid-file=$DNSMASQ_PID_FILE" "$DNSMASQ_CONFIG" >/dev/null 2>&1 || return 1
  if [ -e "$DNS_ENABLED_FILE" ]; then
    grep -F -x 'port=53' "$DNSMASQ_CONFIG" >/dev/null 2>&1 &&
      grep -F -x "listen-address=$ROUTER_LAN" "$DNSMASQ_CONFIG" >/dev/null 2>&1 &&
      grep -F -x "server=$DNS_UPSTREAM" "$DNSMASQ_CONFIG" >/dev/null 2>&1
  else
    grep -F -x 'port=0' "$DNSMASQ_CONFIG" >/dev/null 2>&1
  fi
}

physical_ipv4_dhcp_socket_inodes() {
  local udp_table="${1:-/proc/net/udp}"
  awk '$2 ~ /:0043$/ {print $10}' "$udp_table" | sort -u
}

physical_process_socket_inodes() {
  local pid="$1" proc_root="${2:-/proc}" descriptor target
  for descriptor in "$proc_root/$pid/fd"/*; do
    target="$(readlink "$descriptor" 2>/dev/null || true)"
    case "$target" in socket:\[*\]) printf '%s\n' "$target" | sed -n 's/^socket:\[\([0-9][0-9]*\)\]$/\1/p' ;; esac
  done | sort -u
}

physical_socket_inodes_exactly_owned() {
  local listener_inodes="$1" process_inodes="$2" inode
  [ -n "$listener_inodes" ] || return 1
  while IFS= read -r inode; do
    [ -n "$inode" ] || continue
    printf '%s\n' "$process_inodes" | grep -F -x -- "$inode" >/dev/null || return 1
  done <<< "$listener_inodes"
}

physical_dhcp_listener_healthy() {
  local pid listener_inodes process_inodes
  pid="$(read_project_pid "$DNSMASQ_PID_FILE")" || return 1
  listener_inodes="$(physical_ipv4_dhcp_socket_inodes)" || return 1
  process_inodes="$(physical_process_socket_inodes "$pid")" || return 1
  physical_socket_inodes_exactly_owned "$listener_inodes" "$process_inodes"
}

physical_ipv4_proc_address() {
  awk -F. 'NF == 4 {printf "%02X%02X%02X%02X", $4, $3, $2, $1}' <<< "$1"
}

physical_dns_listener_table_healthy() {
  local table="$1" required_state="$2" process_inodes="$3" lan_hex address inode owned_lan=0
  lan_hex="$(physical_ipv4_proc_address "$ROUTER_LAN")" || return 1
  [ -n "$lan_hex" ] || return 1
  while read -r address inode; do
    [ -n "$address" ] || continue
    if printf '%s\n' "$process_inodes" | grep -F -x -- "$inode" >/dev/null; then
      [ "$address" = "$lan_hex" ] || return 1
      owned_lan=1
    fi
    if [ "$address" = "$lan_hex" ]; then
      printf '%s\n' "$process_inodes" | grep -F -x -- "$inode" >/dev/null || return 1
    fi
  done < <(awk -v state="$required_state" '$2 ~ /:0035$/ && $4 == state {split($2, local, ":"); print local[1], $10}' "$table")
  [ "$owned_lan" -eq 1 ]
}

physical_dns_listener_healthy() {
  local udp_table="${1:-/proc/net/udp}" tcp_table="${2:-/proc/net/tcp}" proc_root="${3:-/proc}"
  local pid process_inodes
  pid="$(read_project_pid "$DNSMASQ_PID_FILE")" || return 1
  process_inodes="$(physical_process_socket_inodes "$pid" "$proc_root")" || return 1
  physical_dns_listener_table_healthy "$udp_table" 07 "$process_inodes" &&
    physical_dns_listener_table_healthy "$tcp_table" 0A "$process_inodes"
}

physical_dhcp_lease_file_healthy() {
  [ -f "$DNSMASQ_LEASE_FILE" ] && [ "$(stat -c %u:%g:%a "$DNSMASQ_LEASE_FILE")" = "$DNSMASQ_UID:$DNSMASQ_GID:644" ]
}

physical_dhcp_healthy() {
  resolve_dnsmasq_identity && physical_topology_healthy && physical_dnsmasq_process_healthy &&
    physical_dhcp_config_healthy && physical_dhcp_listener_healthy && physical_dhcp_lease_file_healthy
}
physical_dns_healthy() {
  physical_dhcp_healthy && [ -e "$DNS_ENABLED_FILE" ] &&
    grep -F -x 'port=53' "$DNSMASQ_CONFIG" >/dev/null 2>&1 && physical_dns_listener_healthy
}

report_physical_dhcp_health() {
  local pid="<absent>" executable="<absent>" starttime="<absent>" process_netns="<absent>"
  local process_mntns="<absent>" process_pidns="<absent>" nspid="<absent>"
  local router_netns router_mntns router_pidns listener_inodes="<none>" process_inodes="<none>"
  local expected_mode=standalone runtime_status="<absent>" runtime_owned="<absent>"
  pid="$(cat "$DNSMASQ_PID_FILE" 2>/dev/null || echo '<absent>')"
  case "$pid" in
    *[!0-9]*|'') ;;
    *)
      executable="$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo '<exited>')"
      starttime="$(process_starttime "$pid" 2>/dev/null || echo '<exited>')"
      process_netns="$(readlink "/proc/$pid/ns/net" 2>/dev/null || echo '<exited>')"
      process_mntns="$(readlink "/proc/$pid/ns/mnt" 2>/dev/null || echo '<exited>')"
      process_pidns="$(readlink "/proc/$pid/ns/pid" 2>/dev/null || echo '<exited>')"
      nspid="$(awk '/^NSpid:/ {$1=""; sub(/^[[:space:]]+/, ""); print}' "/proc/$pid/status" 2>/dev/null || echo '<exited>')"
      process_inodes="$(physical_process_socket_inodes "$pid" 2>/dev/null || echo '<unreadable>')"
      ;;
  esac
  router_netns="$(router_context_namespace_identity net 2>/dev/null || echo '<unreadable>')"
  router_mntns="$(router_context_namespace_identity mnt 2>/dev/null || echo '<unreadable>')"
  router_pidns="$(readlink /proc/self/ns/pid 2>/dev/null || echo '<unreadable>')"
  listener_inodes="$(physical_ipv4_dhcp_socket_inodes 2>/dev/null || echo '<unreadable>')"
  if [ -r "$PHYSICAL_RUNTIME_STATE" ]; then
    runtime_status="$(python3 "$HVR_REPO_DIR/router/runtime/state.py" show "$PHYSICAL_RUNTIME_STATE" --field status 2>/dev/null || echo '<malformed>')"
    runtime_owned="$(python3 "$HVR_REPO_DIR/router/runtime/state.py" show "$PHYSICAL_RUNTIME_STATE" --field owned 2>/dev/null || echo '<malformed>')"
  fi
  [ ! -e "$DNS_ENABLED_FILE" ] || expected_mode='combined DHCP+DNS'
  printf 'Physical DHCP health diagnostic:\n  deployment mode: %s\n  expected steady state: %s\n  configured LAN: %s\n  configured LAN address: %s/%s\n  configured range: %s - %s\n  runtime status: %s\n  runtime owned stages: %s\n  PID file: %s\n  PID: %s\n  NSpid: %s\n  executable: %s\n  starttime: %s\n  process netns: %s\n  process mountns: %s\n  process pidns: %s\n  router netns: %s\n  router mountns: %s\n  router pidns: %s\n  config: %s\n  process identity/context: %s\n  configuration: %s\n  LAN topology: %s\n  DHCP listener ownership: %s\n  lease file metadata: %s\n  IPv4 UDP/67 socket inodes: %s\n  verified dnsmasq socket inodes: %s\n' \
    "$DEPLOYMENT_MODE" "$expected_mode" "$PHYSICAL_LAN_INTERFACE" "$ROUTER_LAN" "${LAN_SUBNET#*/}" \
    "$DHCP_RANGE_START" "$DHCP_RANGE_END" "$runtime_status" "$runtime_owned" \
    "$DNSMASQ_PID_FILE" "$pid" "$nspid" "$executable" "$starttime" \
    "$process_netns" "$process_mntns" "$process_pidns" "$router_netns" "$router_mntns" "$router_pidns" "$DNSMASQ_CONFIG" \
    "$(physical_dnsmasq_process_healthy && echo PASS || echo FAIL)" \
    "$(physical_dhcp_config_healthy && echo PASS || echo FAIL)" \
    "$(physical_topology_healthy && echo PASS || echo FAIL)" \
    "$(physical_dhcp_listener_healthy && echo PASS || echo FAIL)" \
    "$(physical_dhcp_lease_file_healthy && echo PASS || echo FAIL)" \
    "${listener_inodes:-<none>}" "${process_inodes:-<none>}" >&2
  echo 'ss -H -lun:' >&2
  ss -H -lun >&2 2>/dev/null || true
  echo 'ss -H -lunp:' >&2
  ss -H -lunp >&2 2>/dev/null || true
  echo 'ss -H -uan:' >&2
  ss -H -uan >&2 2>/dev/null || true
  echo '/proc/net/udp entries for IPv4 UDP/67 (:0043):' >&2
  awk 'NR == 1 || $2 ~ /:0043$/' /proc/net/udp >&2 2>/dev/null || true
  echo '/proc/net/udp6 entries for port 67 (:0043), diagnostic only:' >&2
  awk 'NR == 1 || $2 ~ /:0043$/' /proc/net/udp6 >&2 2>/dev/null || true
  echo '/proc mount:' >&2
  findmnt -T /proc >&2 2>/dev/null || true
  echo 'generated dnsmasq configuration:' >&2
  sed 's/^/  /' "$DNSMASQ_CONFIG" >&2 2>/dev/null || echo '  <absent>' >&2
  echo 'lease file (last 20 lines):' >&2
  tail -n 20 "$DNSMASQ_LEASE_FILE" >&2 2>/dev/null || echo '  <absent>' >&2
  echo 'LAN link/address:' >&2
  ip -details link show dev "$PHYSICAL_LAN_INTERFACE" >&2 2>/dev/null || true
  ip -o -4 address show dev "$PHYSICAL_LAN_INTERFACE" >&2 2>/dev/null || true
  echo 'dnsmasq log (last 40 lines):' >&2
  tail -n 40 "$DNSMASQ_LOG_FILE" >&2 2>/dev/null || echo '  <absent>' >&2
}

physical_prepare_dhcp_runtime() {
  install -d -o 0 -g 0 -m 0755 "$DHCP_RUNTIME_DIR"
  [ "$(stat -c %u:%g:%a "$DHCP_RUNTIME_DIR")" = "0:0:755" ] ||
    die "physical DHCP runtime directory has unexpected ownership or permissions"
}

physical_wait_for_dhcp_readiness() {
  local attempt pid
  for attempt in {1..50}; do
    physical_dhcp_healthy && return 0
    if pid="$(read_project_pid "$DNSMASQ_PID_FILE" 2>/dev/null)"; then
      if ! process_is_running "$pid" || ! project_process_matches "$pid" dnsmasq "$DNSMASQ_CONFIG" ||
          ! process_is_in_router_namespace "$pid"; then
        report_physical_dhcp_health
        die "physical dnsmasq exited or changed identity before DHCP readiness"
        return 1
      fi
    fi
    sleep 0.05
  done
  report_physical_dhcp_health
  die "physical dnsmasq did not reach strict DHCP readiness within 2.5 seconds"
  return 1
}

physical_start_dnsmasq() {
  resolve_dnsmasq_identity
  physical_prepare_dhcp_runtime
  touch "$DNSMASQ_LEASE_FILE" "$DNSMASQ_LOG_FILE"
  chown "$DNSMASQ_UID:$DNSMASQ_GID" "$DNSMASQ_LEASE_FILE" "$DNSMASQ_LOG_FILE"
  dnsmasq --test --conf-file="$DNSMASQ_CONFIG" >/dev/null
  dnsmasq --conf-file="$DNSMASQ_CONFIG"
  physical_wait_for_dhcp_readiness
}

physical_dhcp_enable() { resolve_dnsmasq_identity; physical_prepare_dhcp_runtime; render_dnsmasq_config; physical_start_dnsmasq; }
physical_dhcp_disable() {
  [ ! -e "$DNS_ENABLED_FILE" ] || die "disable physical DNS before DHCP"
  stop_project_process_if_present "$DNSMASQ_PID_FILE" dnsmasq "$DNSMASQ_CONFIG"
  remove_project_dhcp_files
}
physical_dns_enable() {
  physical_dhcp_healthy || die "physical DHCP must be healthy before DNS"
  stop_project_process "$DNSMASQ_PID_FILE" dnsmasq "$DNSMASQ_CONFIG"
  mkdir -p "$DNS_RUNTIME_DIR"
  touch "$DNS_LOG_FILE"
  resolve_dnsmasq_identity
  chown "$DNSMASQ_UID:$DNSMASQ_GID" "$DNS_LOG_FILE"
  render_router_dns_config
  touch "$DNS_ENABLED_FILE"
  physical_start_dnsmasq
  physical_dns_healthy || die "physical DNS did not reach LAN-only state"
  lan_link_local_addresses="$(ip -o -6 address show dev "$PHYSICAL_LAN_INTERFACE" scope link | awk '{sub(/\/.*/, "", $4); print $4}')"
  ss -lntuH | validate_router_dns_listeners "$ROUTER_LAN" "$PHYSICAL_WAN_ADDRESS" \
    "$PHYSICAL_LAN_INTERFACE" "$lan_link_local_addresses" ||
    die "physical DNS listener policy rejected WAN, wildcard, or missing LAN UDP/TCP listeners"
}
physical_dns_disable() {
  physical_dns_healthy || die "physical DNS is not healthy"
  stop_project_process "$DNSMASQ_PID_FILE" dnsmasq "$DNSMASQ_CONFIG"
  rm -f -- "$DNS_ENABLED_FILE"
  render_dnsmasq_config
  physical_start_dnsmasq
  remove_project_dns_files
}

physical_ipfix_enable() {
  [ "$IPFIX_ENABLED" = 1 ] || die "IPFIX is disabled by configuration"
  mkdir -p "$IPFIX_RUNTIME_DIR"
  remove_project_ipfix_files
  mkdir -p "$IPFIX_RUNTIME_DIR"
  touch "$IPFIX_LOG_FILE"
  chmod 0640 "$IPFIX_LOG_FILE"
  render_pmacctd_config
  command=(pmacctd -f "$IPFIX_CONFIG_FILE")
  printf '%q ' "${command[@]}" > "$IPFIX_COMMAND_FILE"; printf '\n' >> "$IPFIX_COMMAND_FILE"
  "${command[@]}" >> "$IPFIX_LOG_FILE" 2>&1 &
  launch_pid=$!
  printf '%s\n' "$launch_pid" > "$IPFIX_LAUNCH_PID_FILE"
  process_starttime "$launch_pid" > "$IPFIX_LAUNCH_STARTTIME_FILE"
  for _attempt in {1..30}; do
    if pmacct_core_running && [ ! -s "$IPFIX_CORE_STARTTIME_FILE" ]; then
      core_pid="$(read_project_pid "$IPFIX_PID_FILE")"
      process_starttime "$core_pid" > "$IPFIX_CORE_STARTTIME_FILE"
    fi
    if pmacct_core_running && pmacct_nfprobe_running; then break; fi
    sleep 0.1
  done
  pmacctd_running || die "physical pmacctd/nfprobe did not remain healthy"
  core_pid="$(read_project_pid "$IPFIX_PID_FILE")"
  process_starttime "$core_pid" > "$IPFIX_CORE_STARTTIME_FILE"
  assert_single_project_pmacct_pair
}

physical_ipfix_disable() {
  stop_project_pmacctd_if_present
  remove_project_ipfix_files
}
