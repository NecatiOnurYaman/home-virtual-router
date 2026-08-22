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

validate_topology_names() {
  local namespace interface
  for namespace in "$UPSTREAM_NAMESPACE" "$ROUTER_NAMESPACE" "$CLIENT_NAMESPACE"; do
    require_explicit_namespace "$namespace" || return 1
  done
  for interface in "$UPSTREAM_INTERFACE" "$ROUTER_WAN_INTERFACE" "$ROUTER_LAN_INTERFACE" "$CLIENT_INTERFACE"; do
    require_explicit_interface "$interface" || return 1
  done
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
