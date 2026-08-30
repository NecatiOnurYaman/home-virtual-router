#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hardware-common.sh
source "$script_dir/hardware-common.sh"
r14_require_real_hardware
[ -r "$R14_CHECKPOINT" ] || die "R14 checkpoint is absent; post-reboot validation was not prepared"
r14_checkpoint_identity_matches || die "configured NIC identity changed across reboot"
r14_prepare_report
printf 'R14 post-reboot validation (this command never reboots or changes persistence)\n'
if [ -e "$RUNTIME_STATE_FILE" ]; then
  r14_check "Post-reboot runtime" "$HVR_REPO_DIR/lab/scripts/runtime-check.sh"
  echo "Automatic runtime is healthy; validate real-client DHCP/DNS/routing again."
else
  r14_check "Post-reboot host residue" r14_runtime_residue_absent
  echo "No automatic runtime is present; manual runtime-start remains an explicit operator action."
fi
