#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hardware-common.sh
source "$script_dir/hardware-common.sh"
r14_require_real_hardware
runtime_dependencies
for command in tcpdump timeout; do command -v "$command" >/dev/null || die "R14 requires $command"; done
physical_preflight
if [ -e "$RUNTIME_STATE_FILE" ]; then
  [ "$(runtime_state_field deployment)" = physical ] || die "existing runtime state is not physical"
  [ "$(runtime_state_field status)" = running ] || die "existing runtime state is not exactly running"
  runtime_status_report >/dev/null || die "existing physical runtime is not healthy"
fi
printf 'R14 REAL HARDWARE READ-ONLY CHECK\n'
printf '  WAN: %s (%s, ifindex %s)\n' "$PHYSICAL_WAN_INTERFACE" "$(cat "/sys/class/net/$PHYSICAL_WAN_INTERFACE/address")" "$(cat "/sys/class/net/$PHYSICAL_WAN_INTERFACE/ifindex")"
printf '  LAN: %s (%s, ifindex %s)\n' "$PHYSICAL_LAN_INTERFACE" "$(cat "/sys/class/net/$PHYSICAL_LAN_INTERFACE/address")" "$(cat "/sys/class/net/$PHYSICAL_LAN_INTERFACE/ifindex")"
printf 'Read-only R13 preflight and R14 identity check passed; no network state was changed.\n'
