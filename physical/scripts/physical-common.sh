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
physical_default_route_exact() {
  ip -o -4 route show default | awk -v gateway="$PHYSICAL_WAN_GATEWAY" -v interface="$PHYSICAL_WAN_INTERFACE" '
    $1 == "default" { via=""; dev=""; for (i=1;i<=NF;i++) { if ($i=="via") via=$(i+1); if ($i=="dev") dev=$(i+1) } if (via==gateway && dev==interface) found=1 }
    END { exit !found }
  '
}

physical_default_route_interface() {
  ip -o -4 route show default | awk 'NR == 1 { for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }'
}

physical_require_management_ack() {
  local default_interface
  default_interface="$(physical_default_route_interface)"
  if [ "$default_interface" = "$PHYSICAL_WAN_INTERFACE" ] || [ "$default_interface" = "$PHYSICAL_LAN_INTERFACE" ]; then
    [ "$PHYSICAL_MANAGEMENT_INTERFACE_ACK" = "$default_interface" ] ||
      die "$default_interface carries the current default route; acknowledge that exact interface with PHYSICAL_MANAGEMENT_INTERFACE_ACK=$default_interface"
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

physical_preflight() {
  local interface addresses desired
  require_physical_authorization
  for interface in "$PHYSICAL_WAN_INTERFACE" "$PHYSICAL_LAN_INTERFACE"; do
    physical_interface_exists "$interface" || die "configured physical interface does not exist: $interface"
    [ "$interface" != lo ] || die "loopback cannot be a physical router interface"
    physical_interface_unmanaged "$interface"
  done
  [ "$PHYSICAL_WAN_INTERFACE" != "$PHYSICAL_LAN_INTERFACE" ] || die "physical WAN and LAN interfaces collide"
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
  {
    printf 'DEPLOYMENT_MODE=physical\n'
    printf 'WAN_INTERFACE=%s\n' "$PHYSICAL_WAN_INTERFACE"
    printf 'LAN_INTERFACE=%s\n' "$PHYSICAL_LAN_INTERFACE"
    printf 'WAN_ADDRESS=%s/%s\n' "$PHYSICAL_WAN_ADDRESS" "$PHYSICAL_WAN_PREFIX_LENGTH"
    printf 'WAN_GATEWAY=%s\n' "$PHYSICAL_WAN_GATEWAY"
    printf 'LAN_ADDRESS=%s/%s\n' "$ROUTER_LAN" "${LAN_SUBNET#*/}"
  } > "$PHYSICAL_MAP_FILE"
  chmod 0640 "$PHYSICAL_MAP_FILE"
}

physical_topology_healthy() {
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

physical_dhcp_healthy() { dnsmasq_dhcp_running && grep -F -x 'port=0' "$DNSMASQ_CONFIG" >/dev/null 2>&1; }
physical_dns_healthy() { dnsmasq_dhcp_running && [ -e "$DNS_ENABLED_FILE" ] && grep -F -x 'port=53' "$DNSMASQ_CONFIG" >/dev/null 2>&1 && grep -F -x "interface=$PHYSICAL_LAN_INTERFACE" "$DNSMASQ_CONFIG" >/dev/null 2>&1; }

physical_start_dnsmasq() {
  resolve_dnsmasq_identity
  mkdir -p "$DHCP_RUNTIME_DIR"
  touch "$DNSMASQ_LEASE_FILE" "$DNSMASQ_LOG_FILE"
  chown "$DNSMASQ_UID:$DNSMASQ_GID" "$DNSMASQ_LEASE_FILE" "$DNSMASQ_LOG_FILE"
  dnsmasq --test --conf-file="$DNSMASQ_CONFIG" >/dev/null
  dnsmasq --conf-file="$DNSMASQ_CONFIG"
  dnsmasq_dhcp_running || die "physical dnsmasq did not remain running"
}

physical_dhcp_enable() { resolve_dnsmasq_identity; render_dnsmasq_config; physical_start_dnsmasq; }
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
  physical_start_dnsmasq
  touch "$DNS_ENABLED_FILE"
  physical_dns_healthy || die "physical DNS did not reach LAN-only state"
  lan_link_local_addresses="$(ip -o -6 address show dev "$PHYSICAL_LAN_INTERFACE" scope link | awk '{sub(/\/.*/, "", $4); print $4}')"
  ss -lntuH | validate_router_dns_listeners "$ROUTER_LAN" "$PHYSICAL_WAN_ADDRESS" \
    "$PHYSICAL_LAN_INTERFACE" "$lan_link_local_addresses" ||
    die "physical DNS listener policy rejected WAN, wildcard, or missing LAN UDP/TCP listeners"
}
physical_dns_disable() {
  physical_dns_healthy || die "physical DNS is not healthy"
  stop_project_process "$DNSMASQ_PID_FILE" dnsmasq "$DNSMASQ_CONFIG"
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
