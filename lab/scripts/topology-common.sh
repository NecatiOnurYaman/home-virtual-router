#!/usr/bin/env bash

# Shared, data-only topology definitions and guards. Sourcing changes no network state.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HVR_REPO_DIR="$(cd "$script_dir/../.." && pwd)"
readonly HVR_CONFIG="$HVR_REPO_DIR/lab/config/defaults.env"
readonly HVR_VALIDATOR="$HVR_REPO_DIR/router/scripts/validate_config.py"

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
