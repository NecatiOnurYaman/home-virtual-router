#!/usr/bin/env bash
set -euo pipefail

[ "$#" -ge 2 ] || { echo "usage: run_with_runtime_lock.sh LOCK_FILE COMMAND [ARG ...]" >&2; exit 2; }
lock_file="$1"
shift
case "$lock_file" in
  /*) ;;
  *) echo "error: runtime lock path must be absolute" >&2; exit 2 ;;
esac

conflict_status=75
set +e
flock --exclusive --nonblock --close --conflict-exit-code "$conflict_status" \
  "$lock_file" "$@"
status=$?
set -e
if [ "$status" -eq "$conflict_status" ]; then
  echo "error: another HVR runtime operation holds $lock_file" >&2
fi
exit "$status"
