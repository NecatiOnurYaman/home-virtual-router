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
  [ "$DEPLOYMENT_MODE" = physical ] || die "R15 persistence requires DEPLOYMENT_MODE=physical"
  for interface in "$PHYSICAL_WAN_INTERFACE" "$PHYSICAL_LAN_INTERFACE"; do
    physical_interface_exists "$interface" || die "configured deployment interface does not exist: $interface"
    physical_interface_is_deployment_eligible "$interface" || die "configured deployment interface is not eligible: $interface"
  done
}
case "$1" in
  install)
    validate_deployment
    python3 "$control_script_dir/persistence.py" install "$control_repo_dir"
    systemctl daemon-reload
    echo "Installed R15 artifacts without enabling or starting the service. Reload NetworkManager or reboot, then verify both exact deployment interfaces are unmanaged before starting HVR."
    ;;
  uninstall)
    systemctl is-active --quiet home-virtual-router.service && die "stop home-virtual-router.service before uninstalling"
    systemctl is-enabled --quiet home-virtual-router.service && die "disable home-virtual-router.service before uninstalling"
    python3 "$control_script_dir/persistence.py" uninstall "$control_repo_dir"
    systemctl daemon-reload
    echo "Removed the exact unmodified R15 unit and NetworkManager policy."
    ;;
  enable|start)
    validate_deployment
    python3 "$control_script_dir/persistence.py" verify "$control_repo_dir"
    systemctl "$1" home-virtual-router.service
    ;;
  disable|stop)
    systemctl "$1" home-virtual-router.service
    ;;
  status)
    systemctl status --no-pager home-virtual-router.service
    ;;
  *) usage ;;
esac
