#!/usr/bin/env bash

# Shared, data-only topology definitions and guards. Sourcing changes no network state.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HVR_REPO_DIR="$(cd "$script_dir/../.." && pwd)"
readonly HVR_LOCAL_CONFIG="/etc/home-virtual-router/router.env"
if [ "${HVR_INTERNAL_PHYSICAL_SIMULATION:-}" = 1 ]; then
  [ "$(id -u)" -eq 0 ] || { echo "error: internal physical simulation requires root" >&2; return 1 2>/dev/null || exit 1; }
  [ -n "${HVR_INTERNAL_SIMULATION_CONFIG:-}" ] && [ -f "$HVR_INTERNAL_SIMULATION_CONFIG" ] ||
    { echo "error: internal physical simulation config is missing" >&2; return 1 2>/dev/null || exit 1; }
  [ -n "${HVR_INTERNAL_OUTER_NET_NAMESPACE:-}" ] && [ -n "${HVR_INTERNAL_OUTER_MOUNT_NAMESPACE:-}" ] ||
    { echo "error: internal physical simulation namespace identity is missing" >&2; return 1 2>/dev/null || exit 1; }
  [ "$(readlink /proc/self/ns/net)" != "$HVR_INTERNAL_OUTER_NET_NAMESPACE" ] &&
    [ "$(readlink /proc/self/ns/mnt)" != "$HVR_INTERNAL_OUTER_MOUNT_NAMESPACE" ] ||
    { echo "error: refusing physical simulation outside isolated network and mount namespaces" >&2; return 1 2>/dev/null || exit 1; }
  readonly HVR_CONFIG="$HVR_INTERNAL_SIMULATION_CONFIG"
elif [ -f "$HVR_LOCAL_CONFIG" ]; then
  readonly HVR_CONFIG="$HVR_LOCAL_CONFIG"
else
  readonly HVR_CONFIG="$HVR_REPO_DIR/lab/config/defaults.env"
fi
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
readonly DNS_RUNTIME_DIR="/run/home-virtual-router/dns"
readonly ROUTER_DNS_CONFIG_TEMPLATE="$HVR_REPO_DIR/router/config/dnsmasq-router-dns.conf.template"
readonly UPSTREAM_DNS_CONFIG_TEMPLATE="$HVR_REPO_DIR/router/config/dnsmasq-upstream-test.conf.template"
readonly DNS_LOG_FILE="$DNS_RUNTIME_DIR/dnsmasq.log"
readonly DNS_ENABLED_FILE="$DNS_RUNTIME_DIR/enabled"
readonly UPSTREAM_DNS_CONFIG="$DNS_RUNTIME_DIR/upstream-dnsmasq.conf"
readonly UPSTREAM_DNS_PID_FILE="$DNS_RUNTIME_DIR/upstream-dnsmasq.pid"
readonly UPSTREAM_DNS_LOG_FILE="$DNS_RUNTIME_DIR/upstream-dnsmasq.log"
readonly IPFIX_RUNTIME_DIR="/run/home-virtual-router/ipfix"
readonly IPFIX_PID_FILE="$IPFIX_RUNTIME_DIR/pmacctd.pid"
readonly IPFIX_LOG_FILE="$IPFIX_RUNTIME_DIR/pmacctd.log"
readonly IPFIX_CONFIG_FILE="$IPFIX_RUNTIME_DIR/pmacctd.conf"
readonly IPFIX_CONFIG_TEMPLATE="$HVR_REPO_DIR/router/config/pmacctd-nfprobe.conf.template"
readonly IPFIX_COMMAND_FILE="$IPFIX_RUNTIME_DIR/command.txt"
readonly IPFIX_PROCESS_TREE_FILE="$IPFIX_RUNTIME_DIR/process-tree.txt"
readonly IPFIX_CORE_STARTTIME_FILE="$IPFIX_RUNTIME_DIR/pmacctd.starttime"
readonly IPFIX_LAUNCH_PID_FILE="$IPFIX_RUNTIME_DIR/launch.pid"
readonly IPFIX_LAUNCH_STARTTIME_FILE="$IPFIX_RUNTIME_DIR/launch.starttime"
readonly IPFIX_PLUGIN_PID_FILE="$IPFIX_RUNTIME_DIR/nfprobe.pid"
readonly IPFIX_PLUGIN_STARTTIME_FILE="$IPFIX_RUNTIME_DIR/nfprobe.starttime"
readonly IPFIX_COLLECTOR_RESULT="$IPFIX_RUNTIME_DIR/collector-result.json"
readonly IPFIX_COLLECTOR_READY="$IPFIX_RUNTIME_DIR/collector.ready"
readonly IPFIX_TRAFFIC_START="$IPFIX_RUNTIME_DIR/traffic-start"
readonly IPFIX_RECEIVER="$HVR_REPO_DIR/router/scripts/ipfix_test_receiver.py"
readonly TELEMETRY_EXPORT_DIR="/run/home-virtual-router/export"
readonly LEGACY_IPFIX_PID_FILE="$IPFIX_RUNTIME_DIR/softflowd.pid"
readonly LEGACY_IPFIX_CONTROL_SOCKET="$IPFIX_RUNTIME_DIR/softflowd.ctl"
readonly METRICS_EXPORT_RUNTIME_DIR="/run/home-virtual-router/metrics-export"
readonly METRICS_EXPORT_PID_FILE="$METRICS_EXPORT_RUNTIME_DIR/exporter.pid"
readonly METRICS_EXPORT_STARTTIME_FILE="$METRICS_EXPORT_RUNTIME_DIR/exporter.starttime"
readonly METRICS_EXPORT_LOG_FILE="$METRICS_EXPORT_RUNTIME_DIR/exporter.log"
readonly METRICS_EXPORT_COMMAND_FILE="$METRICS_EXPORT_RUNTIME_DIR/command.txt"
readonly METRICS_EXPORT_RESULT_FILE="$METRICS_EXPORT_RUNTIME_DIR/receiver-result.json"
readonly METRICS_EXPORT_READY_FILE="$METRICS_EXPORT_RUNTIME_DIR/test-receiver.ready"
readonly METRICS_EXPORTER="$HVR_REPO_DIR/router/scripts/export_metrics.py"
readonly METRICS_TEST_RECEIVER="$HVR_REPO_DIR/router/scripts/metrics_test_receiver.py"

# These variables are populated only from an allowlist after Python validation.
DEPLOYMENT_MODE=""
PHYSICAL_WAN_INTERFACE=""
PHYSICAL_LAN_INTERFACE=""
PHYSICAL_TELEMETRY_INTERFACE=""
PHYSICAL_WAN_ADDRESS=""
PHYSICAL_WAN_PREFIX_LENGTH=""
PHYSICAL_WAN_GATEWAY=""
PHYSICAL_MANAGEMENT_INTERFACE_ACK=""
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
DNS_UPSTREAM=""
DNS_CACHE_SIZE=""
DNS_TEST_NAME=""
DNS_TEST_ADDRESS=""
DNS_TEST_NAME_ALT=""
DNS_TEST_ADDRESS_ALT=""
IPFIX_ENABLED=""
IPFIX_COLLECTOR_HOST=""
IPFIX_COLLECTOR_PORT=""
IPFIX_CAPTURE_INTERFACE=""
TELEMETRY_MODE=""
TELEMETRY_SUBNET=""
TELEMETRY_HOST_ADDRESS=""
TELEMETRY_ROUTER_ADDRESS=""
TELEMETRY_HOST_INTERFACE=""
TELEMETRY_ROUTER_INTERFACE=""
ROUTER_ID=""
METRICS_EXPORT_ENABLED=""
METRICS_EXPORT_HOST=""
METRICS_EXPORT_PORT=""
METRICS_EXPORT_PATH=""
METRICS_EXPORT_INTERVAL_SECONDS=""
METRICS_EXPORT_TIMEOUT_SECONDS=""

load_topology_config() {
  python3 "$HVR_VALIDATOR" "$HVR_CONFIG" >/dev/null
  while IFS='=' read -r key value; do
    case "$key" in
      DEPLOYMENT_MODE) DEPLOYMENT_MODE="$value" ;;
      PHYSICAL_WAN_INTERFACE) PHYSICAL_WAN_INTERFACE="$value" ;;
      PHYSICAL_LAN_INTERFACE) PHYSICAL_LAN_INTERFACE="$value" ;;
      PHYSICAL_TELEMETRY_INTERFACE) PHYSICAL_TELEMETRY_INTERFACE="$value" ;;
      PHYSICAL_WAN_ADDRESS) PHYSICAL_WAN_ADDRESS="$value" ;;
      PHYSICAL_WAN_PREFIX_LENGTH) PHYSICAL_WAN_PREFIX_LENGTH="$value" ;;
      PHYSICAL_WAN_GATEWAY) PHYSICAL_WAN_GATEWAY="$value" ;;
      PHYSICAL_MANAGEMENT_INTERFACE_ACK) PHYSICAL_MANAGEMENT_INTERFACE_ACK="$value" ;;
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
      DNS_UPSTREAM) DNS_UPSTREAM="$value" ;;
      DNS_CACHE_SIZE) DNS_CACHE_SIZE="$value" ;;
      DNS_TEST_NAME) DNS_TEST_NAME="$value" ;;
      DNS_TEST_ADDRESS) DNS_TEST_ADDRESS="$value" ;;
      DNS_TEST_NAME_ALT) DNS_TEST_NAME_ALT="$value" ;;
      DNS_TEST_ADDRESS_ALT) DNS_TEST_ADDRESS_ALT="$value" ;;
      IPFIX_ENABLED) IPFIX_ENABLED="$value" ;;
      IPFIX_COLLECTOR_HOST) IPFIX_COLLECTOR_HOST="$value" ;;
      IPFIX_COLLECTOR_PORT) IPFIX_COLLECTOR_PORT="$value" ;;
      IPFIX_CAPTURE_INTERFACE) IPFIX_CAPTURE_INTERFACE="$value" ;;
      TELEMETRY_MODE) TELEMETRY_MODE="$value" ;;
      TELEMETRY_SUBNET) TELEMETRY_SUBNET="$value" ;;
      TELEMETRY_HOST_ADDRESS) TELEMETRY_HOST_ADDRESS="$value" ;;
      TELEMETRY_ROUTER_ADDRESS) TELEMETRY_ROUTER_ADDRESS="$value" ;;
      TELEMETRY_HOST_INTERFACE) TELEMETRY_HOST_INTERFACE="$value" ;;
      TELEMETRY_ROUTER_INTERFACE) TELEMETRY_ROUTER_INTERFACE="$value" ;;
      ROUTER_ID) ROUTER_ID="$value" ;;
      METRICS_EXPORT_ENABLED) METRICS_EXPORT_ENABLED="$value" ;;
      METRICS_EXPORT_HOST) METRICS_EXPORT_HOST="$value" ;;
      METRICS_EXPORT_PORT) METRICS_EXPORT_PORT="$value" ;;
      METRICS_EXPORT_PATH) METRICS_EXPORT_PATH="$value" ;;
      METRICS_EXPORT_INTERVAL_SECONDS) METRICS_EXPORT_INTERVAL_SECONDS="$value" ;;
      METRICS_EXPORT_TIMEOUT_SECONDS) METRICS_EXPORT_TIMEOUT_SECONDS="$value" ;;
    esac
  done < "$HVR_CONFIG"
  if [ "$DEPLOYMENT_MODE" = "physical" ]; then
    ROUTER_WAN_INTERFACE="$PHYSICAL_WAN_INTERFACE"
    ROUTER_LAN_INTERFACE="$PHYSICAL_LAN_INTERFACE"
  fi
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
  for interface in "$UPSTREAM_INTERFACE" "$ROUTER_WAN_INTERFACE" "$ROUTER_LAN_INTERFACE" "$CLIENT_INTERFACE" "$TELEMETRY_HOST_INTERFACE" "$TELEMETRY_ROUTER_INTERFACE"; do
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
    "$UPSTREAM_INTERFACE"|"$ROUTER_WAN_INTERFACE"|"$ROUTER_LAN_INTERFACE"|"$CLIENT_INTERFACE"|"$TELEMETRY_HOST_INTERFACE"|"$TELEMETRY_ROUTER_INTERFACE") return 0 ;;
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
  if [ "$DEPLOYMENT_MODE" = "physical" ]; then nft "$@"; else ip netns exec "$ROUTER_NAMESPACE" nft "$@"; fi
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

render_router_dns_config() {
  {
    printf '# Generated R7 combined DHCP/DNS configuration\n'
    printf 'port=53\n'
    printf 'interface=%s\n' "$ROUTER_LAN_INTERFACE"
    printf 'listen-address=%s\n' "$ROUTER_LAN"
    printf 'bind-interfaces\nno-resolv\nno-hosts\n'
    printf 'server=%s\n' "$DNS_UPSTREAM"
    printf 'cache-size=%s\n' "$DNS_CACHE_SIZE"
    printf 'log-queries=extra\nlog-facility=%s\n' "$DNS_LOG_FILE"
    printf 'dhcp-authoritative\n'
    printf 'dhcp-range=%s,%s,255.255.255.0,%s\n' "$DHCP_RANGE_START" "$DHCP_RANGE_END" "$DHCP_LEASE_TIME"
    printf 'dhcp-option=option:router,%s\n' "$ROUTER_LAN"
    printf 'dhcp-option=option:netmask,255.255.255.0\n'
    printf 'dhcp-option=option:dns-server,%s\n' "$DHCP_DNS_SERVER"
    printf 'dhcp-leasefile=%s\npid-file=%s\nlog-dhcp\n' "$DNSMASQ_LEASE_FILE" "$DNSMASQ_PID_FILE"
  } > "$DNSMASQ_CONFIG"
}

render_upstream_dns_config() {
  {
    printf '# Generated R7 isolated upstream resolver configuration\n'
    printf 'port=53\ninterface=%s\nlisten-address=%s\nbind-interfaces\n' "$UPSTREAM_INTERFACE" "$DNS_UPSTREAM"
    printf 'no-resolv\nno-hosts\ncache-size=0\nlocal-ttl=300\n'
    printf 'address=/%s/%s\n' "$DNS_TEST_NAME" "$DNS_TEST_ADDRESS"
    printf 'address=/%s/%s\n' "$DNS_TEST_NAME_ALT" "$DNS_TEST_ADDRESS_ALT"
    printf 'pid-file=%s\nlog-facility=%s\nlog-queries=extra\n' "$UPSTREAM_DNS_PID_FILE" "$UPSTREAM_DNS_LOG_FILE"
  } > "$UPSTREAM_DNS_CONFIG"
}

upstream_dns_running() {
  local pid
  pid="$(read_project_pid "$UPSTREAM_DNS_PID_FILE")" || return 1
  project_process_matches "$pid" dnsmasq "$UPSTREAM_DNS_CONFIG"
}

dns_r7_enabled() {
  [ -f "$DNS_ENABLED_FILE" ] || return 1
  dnsmasq_dhcp_running || return 1
  upstream_dns_running || return 1
  grep -F -x -- "port=53" "$DNSMASQ_CONFIG" >/dev/null 2>&1 || return 1
  grep -F -x -- "server=$DNS_UPSTREAM" "$DNSMASQ_CONFIG" >/dev/null 2>&1
}

remove_project_dns_files() {
  rm -f -- "$DNS_LOG_FILE" "$DNS_ENABLED_FILE" "$UPSTREAM_DNS_CONFIG" \
    "$UPSTREAM_DNS_PID_FILE" "$UPSTREAM_DNS_LOG_FILE"
  rmdir "$DNS_RUNTIME_DIR" 2>/dev/null || true
}

validate_router_dns_listeners() {
  local lan_address="$1" wan_address="$2" lan_interface="$3" lan_link_local_addresses="$4"
  awk -v lan="$lan_address" -v wan="$wan_address" -v lan_if="$lan_interface" \
    -v allowed_v6="$lan_link_local_addresses" '
    BEGIN {
      count = split(allowed_v6, addresses, " ")
      for (i = 1; i <= count; i++) if (addresses[i] != "") lan_v6[addresses[i]] = 1
    }
    ($1 == "udp" || $1 == "tcp") && $5 ~ /:53$/ {
      protocol = $1
      endpoint = $5
      sub(/:53$/, "", endpoint)
      gsub(/\[/, "", endpoint)
      gsub(/\]/, "", endpoint)

      scope = ""
      address = endpoint
      if (index(endpoint, "%")) {
        split(endpoint, scoped, "%")
        address = scoped[1]
        scope = scoped[2]
      }

      if (address == lan) {
        seen_lan[protocol] = 1
      } else if (address == "127.0.0.1" || address == "::1") {
        # Router-local loopback is allowed.
      } else if (address in lan_v6 && (scope == "" || scope == lan_if)) {
        # The exact link-local address assigned to hvr-lan is allowed.
      } else {
        bad = 1
      }

      if (address == wan || address == "0.0.0.0" || address == "::" || address == "*") bad = 1
    }
    END { exit !(seen_lan["udp"] && seen_lan["tcp"] && !bad) }
  '
}

process_starttime() {
  local pid="$1"
  [ -r "/proc/$pid/stat" ] || return 1
  awk '{print $22}' "/proc/$pid/stat"
}

process_is_running() {
  local pid="$1" state
  kill -0 "$pid" 2>/dev/null || return 1
  state="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)" || return 1
  [ "$state" != "Z" ]
}

process_is_pmacctd() {
  local pid="$1" executable
  [ -e "/proc/$pid/exe" ] || return 1
  executable="$(readlink "/proc/$pid/exe")" || return 1
  [ "${executable##*/}" = "pmacctd" ]
}

process_is_in_router_namespace() {
  local pid="$1" process_netns router_netns
  process_netns="$(readlink "/proc/$pid/ns/net" 2>/dev/null)" || return 1
  if [ "$DEPLOYMENT_MODE" = "physical" ]; then
    router_netns="$(readlink /proc/self/ns/net 2>/dev/null)" || return 1
  else
    router_netns="$(ip netns exec "$ROUTER_NAMESPACE" readlink /proc/self/ns/net 2>/dev/null)" || return 1
  fi
  [ "$process_netns" = "$router_netns" ]
}

metrics_exporter_identity_matches() {
  local pid="$1" expected_starttime current_starttime command_line executable
  process_is_running "$pid" || return 1
  [ -r "$METRICS_EXPORT_STARTTIME_FILE" ] || return 1
  expected_starttime="$(cat "$METRICS_EXPORT_STARTTIME_FILE")"
  current_starttime="$(process_starttime "$pid")" || return 1
  [ "$current_starttime" = "$expected_starttime" ] || return 1
  executable="$(readlink "/proc/$pid/exe" 2>/dev/null)" || return 1
  case "${executable##*/}" in python3|python3.[0-9]*) ;; *) return 1 ;; esac
  command_line="$(tr '\0' '\n' < "/proc/$pid/cmdline")"
  printf '%s\n' "$command_line" | grep -F -x -- "$METRICS_EXPORTER" >/dev/null || return 1
  printf '%s\n' "$command_line" | grep -F -x -- "$ROUTER_ID" >/dev/null || return 1
  printf '%s\n' "$command_line" | grep -F -x -- "$METRICS_EXPORT_HOST" >/dev/null || return 1
  process_is_in_router_namespace "$pid"
}

metrics_exporter_running() {
  local pid
  pid="$(read_project_pid "$METRICS_EXPORT_PID_FILE")" || return 1
  metrics_exporter_identity_matches "$pid"
}

stop_metrics_exporter_if_present() {
  local pid attempt
  [ -e "$METRICS_EXPORT_PID_FILE" ] || return 0
  if ! pid="$(read_project_pid "$METRICS_EXPORT_PID_FILE")"; then
    rm -f -- "$METRICS_EXPORT_PID_FILE" "$METRICS_EXPORT_STARTTIME_FILE"
    return 0
  fi
  if ! process_is_running "$pid"; then
    rm -f -- "$METRICS_EXPORT_PID_FILE" "$METRICS_EXPORT_STARTTIME_FILE"
    return 0
  fi
  metrics_exporter_identity_matches "$pid" || die "metrics exporter PID metadata does not identify the expected project process"
  kill "$pid"
  for attempt in {1..40}; do
    process_is_running "$pid" || break
    sleep 0.05
  done
  process_is_running "$pid" && die "metrics exporter process $pid did not stop"
  rm -f -- "$METRICS_EXPORT_PID_FILE" "$METRICS_EXPORT_STARTTIME_FILE"
}

pmacct_core_running() {
  local pid
  pid="$(read_project_pid "$IPFIX_PID_FILE")" || return 1
  process_is_running "$pid" || return 1
  process_is_pmacctd "$pid" || return 1
  process_is_in_router_namespace "$pid"
}

project_nfprobe_pids() {
  local core_pid="$1" child parent
  [ -r "/proc/$core_pid/task/$core_pid/children" ] || return 1
  for child in $(cat "/proc/$core_pid/task/$core_pid/children"); do
    parent="$(awk '/^PPid:/ {print $2}' "/proc/$child/status" 2>/dev/null)" || continue
    [ "$parent" = "$core_pid" ] || continue
    process_is_pmacctd "$child" || continue
    process_is_in_router_namespace "$child" || continue
    printf '%s\n' "$child"
  done
}

pmacct_nfprobe_running() {
  local core_pid plugin_pid
  core_pid="$(read_project_pid "$IPFIX_PID_FILE")" || return 1
  plugin_pid="$(project_nfprobe_pids "$core_pid" | head -n 1)"
  [ -n "$plugin_pid" ] || return 1
  printf '%s\n' "$plugin_pid" > "$IPFIX_PLUGIN_PID_FILE"
  process_starttime "$plugin_pid" > "$IPFIX_PLUGIN_STARTTIME_FILE"
}

pmacctd_running() {
  pmacct_core_running && pmacct_nfprobe_running
}

assert_single_project_pmacct_pair() {
  local core_pid plugin_pid pid found=""
  core_pid="$(read_project_pid "$IPFIX_PID_FILE")" || die "project pmacct core PID is unavailable"
  plugin_pid="$(project_nfprobe_pids "$core_pid")"
  [ "$(printf '%s\n' "$plugin_pid" | awk 'NF {count++} END {print count+0}')" -eq 1 ] ||
    die "expected exactly one nfprobe child for project pmacct core $core_pid"
  if [ "$DEPLOYMENT_MODE" = "physical" ]; then
    return 0
  fi
  for pid in $(ip netns pids "$ROUTER_NAMESPACE" 2>/dev/null || true); do
    process_is_pmacctd "$pid" || continue
    found="$found $pid"
  done
  [ "$(printf '%s\n' $found | awk 'NF {count++} END {print count+0}')" -eq 2 ] ||
    die "unexpected pmacct process set in $ROUTER_NAMESPACE:$found; inspect process identity and use cleanup-legacy-ipfix.sh only for a verified project core"
  printf '%s\n' $found | grep -F -x "$core_pid" >/dev/null || die "current project pmacct core is absent from namespace process set"
  printf '%s\n' $found | grep -F -x "$plugin_pid" >/dev/null || die "current project nfprobe child is absent from namespace process set"
}

capture_pmacct_process_tree() {
  local pid pids="" netns
  for pid_file in "$IPFIX_LAUNCH_PID_FILE" "$IPFIX_PID_FILE" "$IPFIX_PLUGIN_PID_FILE"; do
    if pid="$(read_project_pid "$pid_file" 2>/dev/null)"; then pids="$pids $pid"; fi
  done
  if pid="$(read_project_pid "$IPFIX_PID_FILE" 2>/dev/null)"; then
    pids="$pids $(project_nfprobe_pids "$pid" 2>/dev/null || true)"
  fi
  {
    printf '%s\n' '--- pmacct process snapshot ---'
    printf 'PID PPID PGID SID COMM ARGS NETNS\n'
    for pid in $(printf '%s\n' $pids | awk '!seen[$0]++'); do
      [ -r "/proc/$pid/status" ] || continue
      netns="$(readlink "/proc/$pid/ns/net" 2>/dev/null || printf unknown)"
      ps -o pid=,ppid=,pgid=,sid=,comm=,args= -p "$pid" 2>/dev/null |
        sed "s|$| $netns|"
    done
    printf '\nhvr-router namespace: %s\n' \
      "$(ip netns exec "$ROUTER_NAMESPACE" readlink /proc/self/ns/net 2>/dev/null || printf unavailable)"
    printf 'pmacct PIDs reported by ip netns pids:\n'
    for pid in $(ip netns pids "$ROUTER_NAMESPACE" 2>/dev/null || true); do
      process_is_pmacctd "$pid" || continue
      ps -o pid=,ppid=,pgid=,sid=,comm=,args= -p "$pid" 2>/dev/null || true
    done
  } >> "$IPFIX_PROCESS_TREE_FILE"
}

render_pmacctd_config() {
  sed -e "s|@PID_FILE@|$IPFIX_PID_FILE|g" \
    -e "s|@LOG_FILE@|$IPFIX_LOG_FILE|g" \
    -e "s|@CAPTURE_INTERFACE@|$IPFIX_CAPTURE_INTERFACE|g" \
    -e "s|@COLLECTOR_HOST@|$IPFIX_COLLECTOR_HOST|g" \
    -e "s|@COLLECTOR_PORT@|$IPFIX_COLLECTOR_PORT|g" \
    "$IPFIX_CONFIG_TEMPLATE" > "$IPFIX_CONFIG_FILE"
}

stop_recorded_pmacct_process() {
  local pid_file="$1" starttime_file="$2" label="$3" pid recorded_starttime current_starttime attempt
  pid="$(read_project_pid "$pid_file")" || return 0
  if ! process_is_running "$pid"; then rm -f -- "$pid_file" "$starttime_file"; return 0; fi
  [ -r "$starttime_file" ] || die "refusing to stop $label without its recorded process start time"
  recorded_starttime="$(cat "$starttime_file")"
  current_starttime="$(process_starttime "$pid")" || die "cannot verify $label process start time"
  [ "$recorded_starttime" = "$current_starttime" ] || die "refusing to stop reused PID $pid for $label"
  process_is_pmacctd "$pid" || die "refusing to stop $label PID that is not pmacctd"
  process_is_in_router_namespace "$pid" || die "refusing to stop $label outside hvr-router"
  kill "$pid"
  attempt=0
  while process_is_running "$pid" && [ "$attempt" -lt 50 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  process_is_running "$pid" && die "$label process $pid did not stop"
  rm -f -- "$pid_file" "$starttime_file"
}

stop_project_pmacctd_if_present() {
  local core_pid plugin_pid plugin_starttime attempt
  if core_pid="$(read_project_pid "$IPFIX_PID_FILE" 2>/dev/null)" && process_is_running "$core_pid"; then
    [ -r "$IPFIX_CORE_STARTTIME_FILE" ] || die "refusing to stop pmacct core without its recorded process start time"
    [ "$(cat "$IPFIX_CORE_STARTTIME_FILE")" = "$(process_starttime "$core_pid")" ] ||
      die "refusing to stop reused pmacct core PID $core_pid"
    process_is_pmacctd "$core_pid" || die "project pmacct pidfile does not identify pmacctd"
    process_is_in_router_namespace "$core_pid" || die "project pmacct core is outside hvr-router"
    plugin_pid="$(project_nfprobe_pids "$core_pid" | head -n 1)"
    if [ -n "$plugin_pid" ]; then
      plugin_starttime="$(process_starttime "$plugin_pid")"
      printf '%s\n' "$plugin_pid" > "$IPFIX_PLUGIN_PID_FILE"
      printf '%s\n' "$plugin_starttime" > "$IPFIX_PLUGIN_STARTTIME_FILE"
    fi
    kill "$core_pid"
    attempt=0
    while process_is_running "$core_pid" && [ "$attempt" -lt 50 ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
    process_is_running "$core_pid" && die "project pmacct core $core_pid did not stop"
  fi
  stop_recorded_pmacct_process "$IPFIX_PLUGIN_PID_FILE" "$IPFIX_PLUGIN_STARTTIME_FILE" "project nfprobe plugin"
  # During very early failure the launch PID may be the only identity available.
  stop_recorded_pmacct_process "$IPFIX_LAUNCH_PID_FILE" "$IPFIX_LAUNCH_STARTTIME_FILE" "project pmacct launch process"
  rm -f -- "$IPFIX_PID_FILE" "$IPFIX_CORE_STARTTIME_FILE" \
    "$IPFIX_PLUGIN_PID_FILE" "$IPFIX_PLUGIN_STARTTIME_FILE" \
    "$IPFIX_LAUNCH_PID_FILE" "$IPFIX_LAUNCH_STARTTIME_FILE"
}

remove_project_ipfix_pid_files() {
  rm -f -- "$IPFIX_PID_FILE" "$IPFIX_CORE_STARTTIME_FILE" \
    "$IPFIX_PLUGIN_PID_FILE" "$IPFIX_PLUGIN_STARTTIME_FILE" \
    "$IPFIX_LAUNCH_PID_FILE" "$IPFIX_LAUNCH_STARTTIME_FILE"
}

stop_legacy_project_softflowd_if_present() {
  local pid
  [ -e "$LEGACY_IPFIX_PID_FILE" ] || return 0
  pid="$(read_project_pid "$LEGACY_IPFIX_PID_FILE")" || { rm -f -- "$LEGACY_IPFIX_PID_FILE"; return 0; }
  if ! kill -0 "$pid" 2>/dev/null; then rm -f -- "$LEGACY_IPFIX_PID_FILE"; return 0; fi
  project_process_matches "$pid" softflowd "$IPFIX_CAPTURE_INTERFACE" ||
    die "refusing to stop a PID that is not the legacy project softflowd instance"
  project_process_matches "$pid" softflowd "$IPFIX_COLLECTOR_HOST:$IPFIX_COLLECTOR_PORT" ||
    die "legacy softflowd PID does not match the project collector"
  stop_project_process "$LEGACY_IPFIX_PID_FILE" softflowd "$IPFIX_CAPTURE_INTERFACE"
}

remove_project_ipfix_files() {
  rm -f -- "$IPFIX_PID_FILE" "$IPFIX_LOG_FILE" "$IPFIX_CONFIG_FILE" \
    "$IPFIX_COMMAND_FILE" "$IPFIX_PROCESS_TREE_FILE" \
    "$IPFIX_CORE_STARTTIME_FILE" "$IPFIX_LAUNCH_PID_FILE" "$IPFIX_LAUNCH_STARTTIME_FILE" \
    "$IPFIX_PLUGIN_PID_FILE" "$IPFIX_PLUGIN_STARTTIME_FILE" \
    "$LEGACY_IPFIX_PID_FILE" "$LEGACY_IPFIX_CONTROL_SOCKET" \
    "$IPFIX_RUNTIME_DIR/softflowd.log" "$IPFIX_RUNTIME_DIR/statistics.txt" \
    "$IPFIX_RUNTIME_DIR/dump-flows.txt" "$IPFIX_RUNTIME_DIR/expire-all.txt" \
    "$IPFIX_RUNTIME_DIR/test-traffic.pcap" "$IPFIX_RUNTIME_DIR/tcpdump.txt" \
    "$IPFIX_RUNTIME_DIR/offline-softflowd.txt" "$IPFIX_RUNTIME_DIR/live-diagnostic.txt" \
    "$IPFIX_RUNTIME_DIR/versions.txt" \
    "$IPFIX_RUNTIME_DIR/diagnostic-no-promisc.ctl" \
    "$IPFIX_RUNTIME_DIR/diagnostic-no-promisc.pid" \
    "$IPFIX_RUNTIME_DIR/diagnostic-no-promisc.log" \
    "$IPFIX_RUNTIME_DIR/diagnostic-no-promisc-statistics.txt" \
    "$IPFIX_RUNTIME_DIR/diagnostic-promisc.ctl" \
    "$IPFIX_RUNTIME_DIR/diagnostic-promisc.pid" \
    "$IPFIX_RUNTIME_DIR/diagnostic-promisc.log" \
    "$IPFIX_RUNTIME_DIR/diagnostic-promisc-statistics.txt" \
    "$IPFIX_COLLECTOR_RESULT" "$IPFIX_COLLECTOR_READY" "$IPFIX_TRAFFIC_START"
  rmdir "$IPFIX_RUNTIME_DIR" 2>/dev/null || true
}
