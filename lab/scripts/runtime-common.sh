#!/usr/bin/env bash

# R12 orchestration helpers. Sourcing this file changes no runtime state.
runtime_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../router/scripts/safety.sh
source "$runtime_script_dir/../../router/scripts/safety.sh"
# shellcheck source=topology-common.sh
source "$runtime_script_dir/topology-common.sh"

readonly RUNTIME_DIR="/run/home-virtual-router/runtime"
readonly RUNTIME_STATE_FILE="$RUNTIME_DIR/state.env"
readonly RUNTIME_PROFILE_FILE="$RUNTIME_DIR/profile"
readonly RUNTIME_STARTED_FILE="$RUNTIME_DIR/started-at"
readonly RUNTIME_LOG_FILE="$RUNTIME_DIR/startup.log"
readonly RUNTIME_ERROR_FILE="$RUNTIME_DIR/last-error"
readonly RUNTIME_CONFIG_SNAPSHOT="$RUNTIME_DIR/config.snapshot"
readonly RUNTIME_STATE_TOOL="$HVR_REPO_DIR/router/runtime/state.py"
readonly RUNTIME_LOCK_FILE="$RUNTIME_DIR/lock"

runtime_dependencies() {
  HVR_CHECK_COMMANDS="ip nft dnsmasq dhclient sysctl ping curl tcpdump python3 ss systemctl getent dig pmacctd ps readlink flock timeout tac cmp" \
    "$HVR_REPO_DIR/router/scripts/check-dependencies.sh"
}

runtime_prepare_dir() {
  install -d -m 0750 -o 0 -g 0 "$RUNTIME_DIR"
  touch "$RUNTIME_LOG_FILE"
  chmod 0640 "$RUNTIME_LOG_FILE"
}

runtime_lock() {
  runtime_prepare_dir
  exec 9>"$RUNTIME_LOCK_FILE"
  flock -n 9 || die "another HVR runtime operation holds $RUNTIME_LOCK_FILE"
}

runtime_state_field() {
  python3 "$RUNTIME_STATE_TOOL" show "$RUNTIME_STATE_FILE" --field "$1"
}

runtime_write_state() {
  local profile="$1" status="$2" started_at="$3" owned="$4"
  python3 "$RUNTIME_STATE_TOOL" write "$RUNTIME_STATE_FILE" "$profile" "$status" "$started_at" "$owned"
  printf '%s\n' "$profile" > "$RUNTIME_PROFILE_FILE"
  printf '%s\n' "$started_at" > "$RUNTIME_STARTED_FILE"
  chmod 0640 "$RUNTIME_PROFILE_FILE" "$RUNTIME_STARTED_FILE"
}

runtime_append_owned() {
  local owned="$1" stage="$2"
  if [ -z "$owned" ]; then printf '%s' "$stage"; else printf '%s,%s' "$owned" "$stage"; fi
}

runtime_remove_owned() {
  local owned="$1" remove="$2" result="" stage
  IFS=, read -r -a stages <<< "$owned"
  for stage in "${stages[@]}"; do
    [ "$stage" = "$remove" ] && continue
    result="$(runtime_append_owned "$result" "$stage")"
  done
  printf '%s' "$result"
}

runtime_desired_stages() {
  python3 "$RUNTIME_STATE_TOOL" desired "$TELEMETRY_MODE" "$IPFIX_ENABLED" "$METRICS_EXPORT_ENABLED"
}

runtime_topology_healthy() {
  require_r2_topology >/dev/null 2>&1 || return 1
  ip -n "$UPSTREAM_NAMESPACE" -o -4 address show dev "$UPSTREAM_INTERFACE" | grep -F -q -- "$UPSTREAM_GATEWAY/${UPSTREAM_SUBNET#*/}" || return 1
  ip -n "$ROUTER_NAMESPACE" -o -4 address show dev "$ROUTER_WAN_INTERFACE" | grep -F -q -- "$ROUTER_WAN/${UPSTREAM_SUBNET#*/}" || return 1
  ip -n "$ROUTER_NAMESPACE" -o -4 address show dev "$ROUTER_LAN_INTERFACE" | grep -F -q -- "$ROUTER_LAN/${LAN_SUBNET#*/}" || return 1
  ip -n "$CLIENT_NAMESPACE" link show dev "$CLIENT_INTERFACE" >/dev/null 2>&1
}

runtime_observability_healthy() {
  [ "$TELEMETRY_MODE" = "observability" ] || return 1
  host_interface_exists "$TELEMETRY_HOST_INTERFACE" || return 1
  ip -n "$ROUTER_NAMESPACE" link show dev "$TELEMETRY_ROUTER_INTERFACE" >/dev/null 2>&1 || return 1
  ip -o -4 address show dev "$TELEMETRY_HOST_INTERFACE" | grep -F -q -- "$TELEMETRY_HOST_ADDRESS/${TELEMETRY_SUBNET#*/}" || return 1
  ip -n "$ROUTER_NAMESPACE" -o -4 address show dev "$TELEMETRY_ROUTER_INTERFACE" | grep -F -q -- "$TELEMETRY_ROUTER_ADDRESS/${TELEMETRY_SUBNET#*/}" || return 1
  [ "$(readlink "$TELEMETRY_EXPORT_DIR/dnsmasq.leases" 2>/dev/null)" = "$DNSMASQ_LEASE_FILE" ] || return 1
  [ "$(readlink "$TELEMETRY_EXPORT_DIR/dnsmasq.log" 2>/dev/null)" = "$DNS_LOG_FILE" ]
}

# Return 0=healthy, 1=absent, 2=present but conflicting/incomplete.
runtime_stage_state() {
  local stage="$1" count=0 namespace pid
  case "$stage" in
    topology)
      runtime_topology_healthy && return 0
      for namespace in "$UPSTREAM_NAMESPACE" "$ROUTER_NAMESPACE" "$CLIENT_NAMESPACE"; do namespace_exists "$namespace" && count=$((count + 1)); done
      [ "$count" -eq 0 ] && ! host_interface_exists "$UPSTREAM_INTERFACE" && ! host_interface_exists "$ROUTER_WAN_INTERFACE" && ! host_interface_exists "$ROUTER_LAN_INTERFACE" && ! host_interface_exists "$CLIENT_INTERFACE" && return 1
      return 2 ;;
    routing)
      if ! runtime_topology_healthy; then
        ! namespace_exists "$UPSTREAM_NAMESPACE" && ! namespace_exists "$ROUTER_NAMESPACE" && ! namespace_exists "$CLIENT_NAMESPACE" && return 1
        return 2
      fi
      if [ "$(ip netns exec "$ROUTER_NAMESPACE" sysctl -n net.ipv4.ip_forward)" = 1 ] && client_default_route_exists && { upstream_return_route_exists || nat_rule_exists; }; then return 0; fi
      [ "$(ip netns exec "$ROUTER_NAMESPACE" sysctl -n net.ipv4.ip_forward)" = 0 ] && ! ip -n "$CLIENT_NAMESPACE" route show default | grep -q . && ! ip -n "$UPSTREAM_NAMESPACE" route show "$LAN_SUBNET" | grep -q . && return 1
      return 2 ;;
    nat)
      if ! namespace_exists "$ROUTER_NAMESPACE"; then
        ! namespace_exists "$UPSTREAM_NAMESPACE" && return 1
        return 2
      fi
      nat_rule_exists && ! ip -n "$UPSTREAM_NAMESPACE" route show "$LAN_SUBNET" | grep -q . && return 0
      ! nat_table_exists && upstream_return_route_exists && return 1
      return 2 ;;
    firewall)
      namespace_exists "$ROUTER_NAMESPACE" || return 1
      filter_rules_exist && return 0
      ! filter_table_exists && return 1
      return 2 ;;
    dhcp)
      if ! namespace_exists "$ROUTER_NAMESPACE" || ! namespace_exists "$CLIENT_NAMESPACE"; then
        [ ! -e "$DNSMASQ_PID_FILE" ] && [ ! -e "$DHCLIENT_PID_FILE" ] && return 1
        return 2
      fi
      dnsmasq_dhcp_running && dhclient_running && client_dhcp_address >/dev/null && client_default_route_exists && return 0
      ! dnsmasq_dhcp_running && ! dhclient_running && client_static_address_exists && return 1
      return 2 ;;
    dns)
      if ! namespace_exists "$ROUTER_NAMESPACE" || ! namespace_exists "$UPSTREAM_NAMESPACE"; then
        [ ! -e "$DNS_ENABLED_FILE" ] && [ ! -e "$UPSTREAM_DNS_PID_FILE" ] && return 1
        return 2
      fi
      dns_r7_enabled && return 0
      [ ! -e "$DNS_ENABLED_FILE" ] && ! upstream_dns_running && dnsmasq_dhcp_running && return 1
      return 2 ;;
    observability)
      runtime_observability_healthy && return 0
      [ ! -e "/sys/class/net/$TELEMETRY_HOST_INTERFACE" ] && ! ip -n "$ROUTER_NAMESPACE" link show dev "$TELEMETRY_ROUTER_INTERFACE" >/dev/null 2>&1 && [ ! -e "$TELEMETRY_EXPORT_DIR/dnsmasq.leases" ] && [ ! -e "$TELEMETRY_EXPORT_DIR/dnsmasq.log" ] && return 1
      return 2 ;;
    ipfix)
      pmacctd_running && assert_single_project_pmacct_pair >/dev/null 2>&1 && return 0
      if pid="$(read_project_pid "$IPFIX_PID_FILE" 2>/dev/null)" && process_is_running "$pid"; then return 2; fi
      if pid="$(read_project_pid "$IPFIX_PLUGIN_PID_FILE" 2>/dev/null)" && process_is_running "$pid"; then return 2; fi
      return 1 ;;
    metrics-export)
      metrics_exporter_running && return 0
      if pid="$(read_project_pid "$METRICS_EXPORT_PID_FILE" 2>/dev/null)" && process_is_running "$pid"; then return 2; fi
      return 1 ;;
    *) die "unknown runtime stage: $stage" ;;
  esac
}

runtime_enable_stage() {
  case "$1" in
    topology) "$runtime_script_dir/create-topology.sh" ;;
    routing) "$runtime_script_dir/enable-routing.sh" ;;
    nat) "$runtime_script_dir/enable-nat.sh" ;;
    firewall) "$runtime_script_dir/enable-firewall.sh" ;;
    dhcp) "$runtime_script_dir/enable-dhcp.sh" ;;
    dns) "$runtime_script_dir/enable-dns.sh" ;;
    observability) "$runtime_script_dir/enable-observability.sh" ;;
    ipfix) "$runtime_script_dir/enable-ipfix.sh" ;;
    metrics-export) "$runtime_script_dir/enable-metrics-export.sh" ;;
  esac
}

runtime_disable_stage() {
  case "$1" in
    metrics-export) "$runtime_script_dir/disable-metrics-export.sh" ;;
    ipfix) "$runtime_script_dir/disable-ipfix.sh" ;;
    observability) "$runtime_script_dir/disable-observability.sh" ;;
    dns) "$runtime_script_dir/disable-dns.sh" ;;
    dhcp) "$runtime_script_dir/disable-dhcp.sh" ;;
    firewall) "$runtime_script_dir/disable-firewall.sh" ;;
    nat) "$runtime_script_dir/disable-nat.sh" ;;
    routing) "$runtime_script_dir/disable-routing.sh" ;;
    topology) "$runtime_script_dir/destroy-topology.sh" ;;
  esac
}

runtime_status_report() {
  local desired stage code healthy=0 absent=0 bad=0 core_bad=0 telemetry_bad=0
  desired="$(runtime_desired_stages)"
  printf 'HVR runtime profile: %s\n' "$TELEMETRY_MODE"
  while IFS= read -r stage; do
    set +e; runtime_stage_state "$stage"; code=$?; set -e
    case "$code" in
      0) label=healthy; healthy=$((healthy + 1)) ;;
      1) label=absent; absent=$((absent + 1)) ;;
      *) label=inconsistent; bad=$((bad + 1)) ;;
    esac
    case "$stage:$code" in
      topology:[12]|routing:[12]|nat:[12]|firewall:[12]|dhcp:[12]|dns:[12]) core_bad=1 ;;
      *:[12]) telemetry_bad=1 ;;
    esac
    printf '  %-16s %s\n' "$stage" "$label"
  done <<< "$desired"
  if [ "$absent" -gt 0 ] && [ "$healthy" -eq 0 ] && [ "$bad" -eq 0 ]; then RUNTIME_CLASS=stopped
  elif [ "$core_bad" -eq 1 ] || [ "$bad" -gt 0 ]; then RUNTIME_CLASS=inconsistent
  elif [ "$telemetry_bad" -eq 1 ] || [ "$absent" -gt 0 ]; then RUNTIME_CLASS=degraded
  else RUNTIME_CLASS=running
  fi
  if [ -e "$RUNTIME_STATE_FILE" ] && { [ ! -r "$RUNTIME_CONFIG_SNAPSHOT" ] || ! cmp -s -- "$HVR_CONFIG" "$RUNTIME_CONFIG_SNAPSHOT"; }; then
    printf '  configuration    differs from recorded startup snapshot\n'
    RUNTIME_CLASS=inconsistent
  fi
  printf 'Runtime state: %s\n' "$RUNTIME_CLASS"
}
