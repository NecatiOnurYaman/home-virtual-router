#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=physical-common.sh
source "$script_dir/physical-common.sh"
require_root
load_topology_config
physical_preflight
printf 'HVR host-interface deployment preflight (DEPLOYMENT_MODE=physical compatibility mode)\n'
printf '  deployment mode:       %s\n' "$DEPLOYMENT_MODE"
printf '  authorization marker:  %s\n' "$PHYSICAL_AUTHORIZATION_MARKER"
printf '  WAN interface:         %s\n' "$PHYSICAL_WAN_INTERFACE"
ip -brief -4 address show dev "$PHYSICAL_WAN_INTERFACE" | sed 's/^/    /'
printf '  WAN static address:    %s/%s\n' "$PHYSICAL_WAN_ADDRESS" "$PHYSICAL_WAN_PREFIX_LENGTH"
printf '  WAN gateway:           %s\n' "$PHYSICAL_WAN_GATEWAY"
printf '  LAN interface:         %s\n' "$PHYSICAL_LAN_INTERFACE"
ip -brief -4 address show dev "$PHYSICAL_LAN_INTERFACE" | sed 's/^/    /'
printf '  LAN address:           %s/%s\n' "$ROUTER_LAN" "${LAN_SUBNET#*/}"
printf '  telemetry interface:   %s\n' "$PHYSICAL_TELEMETRY_INTERFACE"
printf '  current default iface: %s\n' "$(physical_default_route_interface)"
printf '  forwarding:            %s\n' "$(sysctl -n net.ipv4.ip_forward)"
printf 'Preflight passed; no network state was changed.\n'
