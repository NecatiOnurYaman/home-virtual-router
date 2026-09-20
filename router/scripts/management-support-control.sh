#!/bin/bash
set -euo pipefail
management_control_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
management_repo_dir="$(cd "$management_control_dir/../.." && pwd)"
usage() { echo "usage: $0 install | uninstall | verify" >&2; exit 2; }
[ "$#" -eq 1 ] || usage
[ "$(/usr/bin/uname -s)" = Linux ] || { echo "error: management API support requires Linux" >&2; exit 1; }
[ "$(/usr/bin/id -u)" -eq 0 ] || { echo "error: management API support installation requires root" >&2; exit 1; }

validate_account() {
  local record uid home shell
  record="$(/usr/bin/getent passwd hvr-web)" || return 1
  IFS=: read -r _ _ uid _ _ home shell <<< "$record"
  [ "$uid" -lt 1000 ] && [ "$home" = /nonexistent ] && [ "$shell" = /usr/sbin/nologin ] || {
    echo "error: existing hvr-web account is not the expected system identity" >&2
    exit 1
  }
}

case "$1" in
  install)
    if ! validate_account; then
      /usr/sbin/useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin hvr-web
      validate_account
    fi
    sudoers_candidate="$(/usr/bin/mktemp)"
    trap '/usr/bin/rm -f "$sudoers_candidate"' EXIT
    /usr/bin/python3 "$management_control_dir/management_support.py" render-sudoers "$management_repo_dir" > "$sudoers_candidate"
    /usr/bin/chmod 0440 "$sudoers_candidate"
    /usr/sbin/visudo -cf "$sudoers_candidate"
    /usr/bin/python3 "$management_control_dir/management_support.py" install "$management_repo_dir"
    /usr/sbin/visudo -cf /etc/sudoers.d/home-virtual-router-management
    /usr/bin/python3 "$management_control_dir/management_support.py" verify "$management_repo_dir"
    echo "Installed root-owned R17.2 management API support without starting a service."
    ;;
  verify)
    validate_account || { echo "error: hvr-web account is absent" >&2; exit 1; }
    /usr/sbin/visudo -cf /etc/sudoers.d/home-virtual-router-management
    /usr/bin/python3 "$management_control_dir/management_support.py" verify "$management_repo_dir"
    ;;
  uninstall)
    /usr/bin/python3 "$management_control_dir/management_support.py" uninstall "$management_repo_dir"
    echo "Removed R17.2 installed support; the hvr-web system account was deliberately retained."
    ;;
  *) usage ;;
esac
