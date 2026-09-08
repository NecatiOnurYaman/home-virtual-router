#!/usr/bin/env bash
set -euo pipefail
health_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
health_repo_dir="$(cd "$health_script_dir/../.." && pwd)"
main_state="$(systemctl show -p ActiveState --value home-virtual-router.service 2>/dev/null || true)"
case "$main_state" in
  inactive|'') exit 0 ;;
  activating|deactivating|reloading) exit 0 ;;
  failed) echo "HVR health: main service is failed; operator action or systemd reset-failed is required." >&2; exit 1 ;;
  active) ;;
  *) echo "HVR health: unsupported main service state: $main_state" >&2; exit 1 ;;
esac
if [ -e /var/lib/home-virtual-router/r14/checkpoint.env ]; then
  echo "HVR health: R14 checkpoint is active; refusing automatic recovery." >&2
  exit 1
fi
if output="$("$health_repo_dir/lab/scripts/runtime-check.sh" 2>&1)"; then
  exit 0
fi
sleep 5
if output="$("$health_repo_dir/lab/scripts/runtime-check.sh" 2>&1)"; then
  exit 0
fi
echo "HVR health failure detected:" >&2
printf '%s\n' "$output" >&2
echo "HVR health requesting safe recovery teardown." >&2
if ! output="$("$health_repo_dir/lab/scripts/runtime-stop.sh" --recover 2>&1)"; then
  echo "HVR health recovery teardown failed; main service was not restarted:" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi
echo "HVR health requesting one controlled service restart." >&2
if ! systemctl restart home-virtual-router.service; then
  echo "HVR health recovery failed; main service state remains visible in systemd." >&2
  exit 1
fi
if ! output="$("$health_repo_dir/lab/scripts/runtime-check.sh" 2>&1)"; then
  echo "HVR health recovery failed post-restart runtime validation:" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi
echo "HVR health recovery succeeded." >&2
