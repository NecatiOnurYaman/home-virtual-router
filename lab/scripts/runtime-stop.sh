#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runtime-common.sh
source "$script_dir/runtime-common.sh"
[ "$#" -le 1 ] || die "usage: runtime-stop.sh [--recover]"
recovery=0
if [ "$#" -eq 1 ]; then
  [ "$1" = --recover ] || die "usage: runtime-stop.sh [--recover]"
  recovery=1
fi
require_linux
require_root
load_topology_config
runtime_require_environment
runtime_lock "$@"
if [ ! -e "$RUNTIME_STATE_FILE" ]; then
  echo "HVR runtime has no owned state; manual stage state was not changed."
  exit 0
fi
profile="$(runtime_state_field profile)" || die "malformed R12 state; refusing teardown"
deployment="$(runtime_state_field deployment)"
status="$(runtime_state_field status)"
started_at="$(runtime_state_field started-at)"
owned="$(runtime_state_field owned)"
[ "$profile" = "$TELEMETRY_MODE" ] || die "runtime state profile $profile conflicts with configured TELEMETRY_MODE=$TELEMETRY_MODE"
[ "$deployment" = "$DEPLOYMENT_MODE" ] || die "runtime state deployment $deployment conflicts with configured DEPLOYMENT_MODE=$DEPLOYMENT_MODE"
[ "$recovery" -eq 0 ] || [ "$deployment" = physical ] || die "automatic recovery teardown requires physical deployment state"
[ "$recovery" -eq 0 ] || [ "$status" = running ] || die "automatic recovery requires runtime state to be exactly running"
[ "$status" != stopping ] || echo "Resuming the previously interrupted HVR runtime teardown."
[ -r "$RUNTIME_CONFIG_SNAPSHOT" ] && cmp -s -- "$HVR_CONFIG" "$RUNTIME_CONFIG_SNAPSHOT" || die "configuration differs from the active runtime snapshot; restore it before safe teardown"
if [ "$recovery" -eq 1 ]; then
  while IFS= read -r stage; do
    [ -n "$stage" ] || continue
    set +e; runtime_stage_state "$stage"; state=$?; set -e
    case "$state" in
      0|1) ;;
      2) physical_stage_teardown_resumable "$stage" || die "owned stage $stage is not safely recoverable; refusing automatic teardown" ;;
      *) die "owned stage $stage returned an invalid state" ;;
    esac
  done < <(python3 "$RUNTIME_STATE_TOOL" show "$RUNTIME_STATE_FILE" --field rollback)
fi
runtime_write_state "$profile" stopping "$started_at" "$owned"
while IFS= read -r stage; do
  [ -n "$stage" ] || continue
  set +e; runtime_stage_state "$stage"; state=$?; set -e
  case "$state" in
    0) runtime_disable_stage "$stage" 2>&1 | tee -a "$RUNTIME_LOG_FILE" ;;
    1) printf 'Owned stage %s was already absent.\n' "$stage" | tee -a "$RUNTIME_LOG_FILE" ;;
    2)
      if [ "$deployment" = physical ] && { [ "$status" = stopping ] || [ "$recovery" -eq 1 ]; } && physical_stage_teardown_resumable "$stage"; then
        runtime_recover_disable_stage "$stage" 2>&1 | tee -a "$RUNTIME_LOG_FILE"
      else
        die "owned stage $stage is inconsistent; refusing unsafe teardown"
      fi
      ;;
    *) die "owned stage $stage returned an invalid state" ;;
  esac
  owned="$(runtime_remove_owned "$owned" "$stage")"
  runtime_write_state "$profile" stopping "$started_at" "$owned"
done < <(python3 "$RUNTIME_STATE_TOOL" show "$RUNTIME_STATE_FILE" --field rollback)
rm -f -- "$RUNTIME_STATE_FILE" "$RUNTIME_PROFILE_FILE" "$RUNTIME_STARTED_FILE" "$RUNTIME_CONFIG_SNAPSHOT" "$RUNTIME_ERROR_FILE"
echo "HVR runtime is stopped; only R12-owned stages were removed."
