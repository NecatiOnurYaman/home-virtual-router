#!/usr/bin/env bash
set -euo pipefail
control_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
control_repo_dir="$(cd "$control_script_dir/../.." && pwd)"
# shellcheck source=../../lab/scripts/runtime-common.sh
source "$control_repo_dir/lab/scripts/runtime-common.sh"
usage() { echo "usage: $0 install | uninstall | enable | disable | start | stop | status" >&2; exit 2; }
[ "$#" -eq 1 ] || usage
require_linux
[ "$(id -u)" -eq 0 ] || die "systemd persistence control requires root"
load_topology_config
validate_deployment() {
  local interface
  runtime_require_environment
  [ "$DEPLOYMENT_MODE" = physical ] || die "persistent operation requires DEPLOYMENT_MODE=physical"
  for interface in "$PHYSICAL_WAN_INTERFACE" "$PHYSICAL_LAN_INTERFACE"; do
    physical_interface_exists "$interface" || die "configured deployment interface does not exist: $interface"
    physical_interface_is_deployment_eligible "$interface" || die "configured deployment interface is not eligible: $interface"
  done
}
stop_if_loaded() {
  local load_state
  load_state="$(systemctl show -p LoadState --value "$1" 2>/dev/null || true)"
  case "$load_state" in
    ''|not-found) return 0 ;;
    *) systemctl stop "$1" ;;
  esac
}
case "$1" in
  install)
    validate_deployment
    python3 "$control_script_dir/persistence.py" install "$control_repo_dir"
    systemctl daemon-reload
    echo "Installed R16 persistence artifacts without enabling or starting them. Reload NetworkManager or reboot, then verify both exact deployment interfaces are unmanaged before starting HVR."
    ;;
  uninstall)
    for unit in home-virtual-router-health.timer home-virtual-router-health.service home-virtual-router.service; do
      systemctl is-active --quiet "$unit" && die "stop $unit before uninstalling"
    done
    for unit in home-virtual-router-health.timer home-virtual-router.service; do
      systemctl is-enabled --quiet "$unit" && die "disable $unit before uninstalling"
    done
    python3 "$control_script_dir/persistence.py" uninstall "$control_repo_dir"
    systemctl daemon-reload
    echo "Removed the exact unmodified R16 units and NetworkManager policy."
    ;;
  enable)
    validate_deployment
    python3 "$control_script_dir/persistence.py" verify "$control_repo_dir"
    systemctl enable home-virtual-router.service home-virtual-router-health.timer
    ;;
  start)
    validate_deployment
    python3 "$control_script_dir/persistence.py" verify "$control_repo_dir"
    systemctl start home-virtual-router.service
    if ! systemctl start home-virtual-router-health.timer; then
      systemctl stop home-virtual-router.service
      die "health timer failed to start; the router service was stopped"
    fi
    ;;
  disable)
    systemctl disable home-virtual-router-health.timer home-virtual-router.service
    ;;
  stop)
    stop_if_loaded home-virtual-router-health.timer
    stop_if_loaded home-virtual-router-health.service
    stop_if_loaded home-virtual-router.service
    ;;
  status)
    "$control_script_dir/persistent-status.sh"
    ;;
  *) usage ;;
esac
