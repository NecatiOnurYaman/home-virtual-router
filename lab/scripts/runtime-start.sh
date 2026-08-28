#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runtime-common.sh
source "$script_dir/runtime-common.sh"
require_linux
require_root
load_topology_config
runtime_require_environment
if [ "$DEPLOYMENT_MODE" = "physical" ]; then physical_preflight; fi
runtime_lock
[ "$DEPLOYMENT_MODE" = "physical" ] || validate_topology_names
runtime_dependencies

profile="$TELEMETRY_MODE"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
owned=""
started_now=""
current_stage="initialization"
existing_state=0
if [ -e "$RUNTIME_STATE_FILE" ]; then
  existing_state=1
  existing_profile="$(runtime_state_field profile)" || die "malformed R12 state; inspect $RUNTIME_STATE_FILE"
  existing_deployment="$(runtime_state_field deployment)"
  [ "$existing_deployment" = "$DEPLOYMENT_MODE" ] || die "active runtime deployment is $existing_deployment, not configured $DEPLOYMENT_MODE"
  [ "$existing_profile" = "$profile" ] || die "runtime state profile $existing_profile conflicts with configured TELEMETRY_MODE=$profile; stop it before changing profiles"
  [ -r "$RUNTIME_CONFIG_SNAPSHOT" ] && cmp -s -- "$HVR_CONFIG" "$RUNTIME_CONFIG_SNAPSHOT" || die "configuration differs from the active runtime snapshot; restore it or stop before changing configuration"
  started_at="$(runtime_state_field started-at)"
  owned="$(runtime_state_field owned)"
fi
runtime_write_state "$profile" starting "$started_at" "$owned"
if [ "$existing_state" -eq 0 ]; then
  cp -- "$HVR_CONFIG" "$RUNTIME_CONFIG_SNAPSHOT"
  chmod 0640 "$RUNTIME_CONFIG_SNAPSHOT"
fi
rm -f -- "$RUNTIME_ERROR_FILE"

rollback() {
  local status="$?" stage code message
  message="runtime startup failed at $current_stage with exit status $status"
  trap - EXIT INT TERM
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$message" | tee -a "$RUNTIME_LOG_FILE" >&2
  printf '%s\n' "$message" > "$RUNTIME_ERROR_FILE"
  while IFS= read -r stage; do
    [ -n "$stage" ] || continue
    set +e; runtime_stage_state "$stage"; code=$?; set -e
    if [ "$code" -eq 0 ]; then runtime_disable_stage "$stage" >> "$RUNTIME_LOG_FILE" 2>&1 || true; fi
    owned="$(runtime_remove_owned "$owned" "$stage")"
  done < <(printf '%s\n' "$started_now" | tac)
  runtime_write_state "$profile" failed "$started_at" "$owned" || true
  exit "$status"
}
trap rollback EXIT INT TERM

while IFS= read -r stage; do
  current_stage="$stage"
  set +e; runtime_stage_state "$stage"; state=$?; set -e
  case "$state" in
    0) printf '%s %-16s already healthy\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$stage" | tee -a "$RUNTIME_LOG_FILE" ;;
    1)
      printf '%s %-16s starting\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$stage" | tee -a "$RUNTIME_LOG_FILE"
      runtime_enable_stage "$stage" 2>&1 | tee -a "$RUNTIME_LOG_FILE"
      runtime_stage_state "$stage" || die "$stage did not reach its exact healthy state"
      owned="$(runtime_append_owned "$owned" "$stage")"
      started_now="${started_now}${started_now:+$'\n'}$stage"
      runtime_write_state "$profile" starting "$started_at" "$owned"
      ;;
    *) die "$stage has conflicting or incomplete state; no broad cleanup was attempted" ;;
  esac
done < <(runtime_desired_stages)

runtime_write_state "$profile" running "$started_at" "$owned"
current_stage="complete"
trap - EXIT INT TERM
printf 'HVR runtime is running.\nDeployment mode: %s\nTelemetry mode: %s\nOwned stages: %s\n' \
  "$DEPLOYMENT_MODE" "$profile" "${owned:-none (pre-existing state preserved)}"
