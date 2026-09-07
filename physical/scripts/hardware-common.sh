#!/usr/bin/env bash

hardware_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lab/scripts/runtime-common.sh
source "$hardware_script_dir/../../lab/scripts/runtime-common.sh"

readonly R14_DIR="/run/home-virtual-router/r14"
readonly R14_PERSIST_DIR="/var/lib/home-virtual-router/r14"
readonly R14_REPORT="$R14_DIR/report.txt"
readonly R14_SUMMARY="$R14_DIR/summary.tsv"
readonly R14_CHECKPOINT="$R14_PERSIST_DIR/checkpoint.env"
readonly R14_DEFAULT_ROUTES_BEFORE="$R14_PERSIST_DIR/default-routes.before"
readonly R14_METRICS_BEFORE="$R14_DIR/metrics-before.json"
readonly R14_NAT_PROOF="$R14_DIR/nat-proof.txt"
readonly R14_FIREWALL_PROOF="$R14_DIR/firewall-proof.txt"
readonly R14_FIREWALL_OK="$R14_DIR/firewall-proof.ok"
readonly R14_VERSION=3

r14_require_real_hardware() {
  require_linux
  require_root
  [ "${HVR_INTERNAL_PHYSICAL_SIMULATION:-0}" != 1 ] || die "R14 refuses the R13 simulation override"
  load_topology_config
  [ "$DEPLOYMENT_MODE" = physical ] || die "R14 requires DEPLOYMENT_MODE=physical"
  require_physical_authorization
}

r14_prepare_report() {
  install -d -o 0 -g 0 -m 0700 "$R14_DIR"
  touch "$R14_REPORT" "$R14_SUMMARY"
  chmod 0600 "$R14_REPORT" "$R14_SUMMARY"
}

r14_result() {
  local label="$1" result="$2"
  case "$result" in PASS|FAIL|'NOT RUN') ;; *) die "invalid R14 result: $result" ;; esac
  r14_prepare_report
  printf '%s\t%s\n' "$label" "$result" >> "$R14_SUMMARY"
  printf '%-34s %s\n' "$label" "$result"
}

r14_check() {
  local label="$1"
  shift
  if "$@"; then r14_result "$label" PASS; else r14_result "$label" FAIL; return 1; fi
}

r14_summary_latest_is_pass() {
  [ -r "$R14_SUMMARY" ] || return 1
  awk -F '\t' -v label="$1" '$1 == label {result=$2} END {exit result != "PASS"}' "$R14_SUMMARY"
}

r14_networkmanager_state() {
  local output
  command -v nmcli >/dev/null 2>&1 || { printf 'unavailable\n'; return; }
  output="$(nmcli -t -f GENERAL.STATE device show "$1" 2>/dev/null || true)"
  [ -n "$output" ] || { printf 'unavailable\n'; return; }
  if printf '%s\n' "$output" | grep -Eiq 'unmanaged|^[^:]*:10[[:space:]]'; then printf 'unmanaged\n'
  else printf 'managed\n'; fi
}

r14_capture_inventory() {
  local output="$1" interface driver
  : > "$output"
  chmod 0600 "$output"
  {
    printf 'timestamp=%s\nhostname=%s\nkernel=%s\nforwarding=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)" "$(uname -srvm)" "$(sysctl -n net.ipv4.ip_forward)"
    ip -o -4 route show default
    for interface in "$PHYSICAL_WAN_INTERFACE" "$PHYSICAL_LAN_INTERFACE"; do
      driver="$(basename "$(readlink -f "/sys/class/net/$interface/device/driver" 2>/dev/null)" 2>/dev/null || true)"
      printf 'interface=%s\nifindex=%s\nmac=%s\noperstate=%s\ncarrier=%s\nmtu=%s\ndriver=%s\n' \
        "$interface" "$(cat "/sys/class/net/$interface/ifindex")" "$(cat "/sys/class/net/$interface/address")" \
        "$(cat "/sys/class/net/$interface/operstate")" "$(cat "/sys/class/net/$interface/carrier" 2>/dev/null || echo unknown)" \
        "$(cat "/sys/class/net/$interface/mtu")" "${driver:-unknown}"
      ip -details link show dev "$interface"
      ip -o -4 address show dev "$interface"
      ip -o -4 route show dev "$interface"
      command -v nmcli >/dev/null 2>&1 && nmcli -t -f GENERAL.DEVICE,GENERAL.STATE,GENERAL.CONNECTION device show "$interface" || true
      networkctl status "$interface" --no-pager 2>/dev/null | head -n 30 || true
    done
  } >> "$output" 2>&1
}

r14_write_checkpoint() {
  local wan_up=0 lan_up=0 wan_address=0 lan_address=0 default_route=0 wan_nm lan_nm
  physical_interface_is_up "$PHYSICAL_WAN_INTERFACE" && wan_up=1
  physical_interface_is_up "$PHYSICAL_LAN_INTERFACE" && lan_up=1
  if [ "$(physical_wan_mode)" = static ]; then
    physical_address_exists "$PHYSICAL_WAN_INTERFACE" "$(physical_effective_wan_cidr)" && wan_address=1
  else
    ! ip -o -4 address show dev "$PHYSICAL_WAN_INTERFACE" scope global | grep -q . || wan_address=1
  fi
  physical_address_exists "$PHYSICAL_LAN_INTERFACE" "$ROUTER_LAN/${LAN_SUBNET#*/}" && lan_address=1
  physical_default_route_exact && default_route=1
  wan_nm="$(r14_networkmanager_state "$PHYSICAL_WAN_INTERFACE")"
  lan_nm="$(r14_networkmanager_state "$PHYSICAL_LAN_INTERFACE")"
  case "$wan_nm:$lan_nm" in unmanaged:unmanaged|unmanaged:unavailable|unavailable:unmanaged|unavailable:unavailable) ;;
    *) die "R14 checkpoint requires both deployment interfaces to remain unmanaged by NetworkManager" ;;
  esac
  install -d -o 0 -g 0 -m 0700 "$R14_PERSIST_DIR"
  {
    printf 'R14_VERSION=%s\nDEPLOYMENT_MODE=physical\nWAN_MODE=%s\n' "$R14_VERSION" "$(physical_wan_mode)"
    printf 'WAN_INTERFACE=%s\nWAN_IFINDEX=%s\nWAN_MAC=%s\n' "$PHYSICAL_WAN_INTERFACE" \
      "$(cat "/sys/class/net/$PHYSICAL_WAN_INTERFACE/ifindex")" "$(cat "/sys/class/net/$PHYSICAL_WAN_INTERFACE/address")"
    printf 'LAN_INTERFACE=%s\nLAN_IFINDEX=%s\nLAN_MAC=%s\n' "$PHYSICAL_LAN_INTERFACE" \
      "$(cat "/sys/class/net/$PHYSICAL_LAN_INTERFACE/ifindex")" "$(cat "/sys/class/net/$PHYSICAL_LAN_INTERFACE/address")"
    printf 'FORWARDING=%s\nWAN_UP=%s\nLAN_UP=%s\nWAN_ADDRESS_PRESENT=%s\nLAN_ADDRESS_PRESENT=%s\nDEFAULT_ROUTE_PRESENT=%s\n' \
      "$(sysctl -n net.ipv4.ip_forward)" "$wan_up" "$lan_up" "$wan_address" "$lan_address" "$default_route"
    printf 'WAN_NM_STATE=%s\nLAN_NM_STATE=%s\n' "$wan_nm" "$lan_nm"
  } > "$R14_CHECKPOINT"
  ip -o -4 route show default > "$R14_DEFAULT_ROUTES_BEFORE"
  chmod 0600 "$R14_CHECKPOINT" "$R14_DEFAULT_ROUTES_BEFORE"
}

r14_checkpoint_schema_valid() {
  python3 - "$R14_CHECKPOINT" <<'PY'
import pathlib, sys
base = {"R14_VERSION", "DEPLOYMENT_MODE", "WAN_MODE", "WAN_INTERFACE", "WAN_IFINDEX", "WAN_MAC",
        "LAN_INTERFACE", "LAN_IFINDEX", "LAN_MAC", "FORWARDING", "WAN_UP", "LAN_UP",
        "WAN_ADDRESS_PRESENT", "LAN_ADDRESS_PRESENT", "DEFAULT_ROUTE_PRESENT"}
values = {}
for line in pathlib.Path(sys.argv[1]).read_text(encoding="ascii").splitlines():
    key, separator, value = line.partition("=")
    assert separator and key not in values and value
    values[key] = value
version = values.get("R14_VERSION")
required = base if version == "2" else base | {"WAN_NM_STATE", "LAN_NM_STATE"}
assert version in {"2", "3"} and values.keys() == required
assert values["DEPLOYMENT_MODE"] == "physical" and values["WAN_MODE"] in {"static", "dhcp"}
for key in ("WAN_IFINDEX", "LAN_IFINDEX"):
    assert values[key].isdigit() and int(values[key]) > 0
for key in ("FORWARDING", "WAN_UP", "LAN_UP", "WAN_ADDRESS_PRESENT", "LAN_ADDRESS_PRESENT", "DEFAULT_ROUTE_PRESENT"):
    assert values[key] in {"0", "1"}
if version == "3":
    assert values["WAN_NM_STATE"] in {"unmanaged", "unavailable"}
    assert values["LAN_NM_STATE"] in {"unmanaged", "unavailable"}
PY
}

r14_checkpoint_field() {
  awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; found=1} END {exit !found}' "$R14_CHECKPOINT"
}

r14_checkpoint_identity_matches() {
  [ -f "$R14_CHECKPOINT" ] && [ ! -L "$R14_CHECKPOINT" ] &&
    [ -f "$R14_DEFAULT_ROUTES_BEFORE" ] && [ ! -L "$R14_DEFAULT_ROUTES_BEFORE" ] &&
    [ "$(stat -c %u:%a "$R14_CHECKPOINT")" = 0:600 ] &&
    [ "$(stat -c %u:%a "$R14_DEFAULT_ROUTES_BEFORE")" = 0:600 ] &&
    r14_checkpoint_schema_valid 2>/dev/null &&
    [ "$(r14_checkpoint_field DEPLOYMENT_MODE)" = physical ] &&
    [ "$(r14_checkpoint_field WAN_MODE)" = "$(physical_wan_mode)" ] &&
    [ "$(r14_checkpoint_field WAN_INTERFACE)" = "$PHYSICAL_WAN_INTERFACE" ] &&
    [ "$(r14_checkpoint_field LAN_INTERFACE)" = "$PHYSICAL_LAN_INTERFACE" ] &&
    [ "$(r14_checkpoint_field WAN_IFINDEX)" = "$(cat "/sys/class/net/$PHYSICAL_WAN_INTERFACE/ifindex")" ] &&
    [ "$(r14_checkpoint_field LAN_IFINDEX)" = "$(cat "/sys/class/net/$PHYSICAL_LAN_INTERFACE/ifindex")" ] &&
    [ "$(r14_checkpoint_field WAN_MAC)" = "$(cat "/sys/class/net/$PHYSICAL_WAN_INTERFACE/address")" ] &&
    [ "$(r14_checkpoint_field LAN_MAC)" = "$(cat "/sys/class/net/$PHYSICAL_LAN_INTERFACE/address")" ]
}

r14_checkpoint_networkmanager_state() {
  if [ "$(r14_checkpoint_field R14_VERSION)" = 2 ]; then printf 'unmanaged\n'
  elif [ "$1" = "$PHYSICAL_WAN_INTERFACE" ]; then r14_checkpoint_field WAN_NM_STATE
  else r14_checkpoint_field LAN_NM_STATE; fi
}

r14_restore_networkmanager_baseline() {
  local interface expected current attempt
  for interface in "$PHYSICAL_WAN_INTERFACE" "$PHYSICAL_LAN_INTERFACE"; do
    expected="$(r14_checkpoint_networkmanager_state "$interface")"
    current="$(r14_networkmanager_state "$interface")"
    if [ "$expected" = unmanaged ] && [ "$current" = managed ]; then
      nmcli device set "$interface" managed no
      for ((attempt=0; attempt<30; attempt++)); do
        [ "$(r14_networkmanager_state "$interface")" = unmanaged ] && break
        sleep 0.1
      done
      current="$(r14_networkmanager_state "$interface")"
    fi
    [ "$current" = "$expected" ] ||
      die "NetworkManager state for $interface is $current, expected checkpoint state $expected"
  done
}

r14_checkpoint_network_baseline_matches() {
  local expected actual
  cmp -s "$R14_DEFAULT_ROUTES_BEFORE" <(ip -o -4 route show default) || return 1
  expected="$(r14_checkpoint_field WAN_ADDRESS_PRESENT)"; actual=0
  if [ "$(physical_wan_mode)" = static ]; then physical_address_exists "$PHYSICAL_WAN_INTERFACE" "$(physical_effective_wan_cidr)" && actual=1
  else ! ip -o -4 address show dev "$PHYSICAL_WAN_INTERFACE" scope global | grep -q . || actual=1; fi
  [ "$actual" = "$expected" ] || return 1
  expected="$(r14_checkpoint_field LAN_ADDRESS_PRESENT)"; actual=0
  physical_address_exists "$PHYSICAL_LAN_INTERFACE" "$ROUTER_LAN/${LAN_SUBNET#*/}" && actual=1
  [ "$actual" = "$expected" ]
}

r14_wait_for_checkpoint_network_baseline() {
  local attempt
  for ((attempt=0; attempt<30; attempt++)); do
    r14_checkpoint_network_baseline_matches && return 0
    sleep 0.1
  done
  die "host addresses/default routes did not return to the R14 checkpoint baseline"
}

r14_runtime_residue_absent() {
  [ ! -e "$RUNTIME_STATE_FILE" ] && [ ! -e "$PHYSICAL_MAP_FILE" ] &&
    [ ! -e "$PHYSICAL_WAN_ADDRESS_OWNED" ] && [ ! -e "$PHYSICAL_LAN_ADDRESS_OWNED" ] &&
    [ ! -e "$PHYSICAL_WAN_LINK_OWNED" ] && [ ! -e "$PHYSICAL_LAN_LINK_OWNED" ] &&
    [ ! -e "$PHYSICAL_DEFAULT_ROUTE_OWNED" ] && [ ! -e "$PHYSICAL_FORWARDING_ORIGINAL" ] &&
    [ ! -e "$PHYSICAL_HOST_FORWARD_OWNED" ] &&
    [ ! -e "$PHYSICAL_WAN_DHCP_DIR" ] &&
    [ ! -e "$DNSMASQ_PID_FILE" ] && [ ! -e "$DNS_ENABLED_FILE" ] &&
    [ ! -e "$IPFIX_PID_FILE" ] && [ ! -e "$IPFIX_PLUGIN_PID_FILE" ] &&
    [ ! -e "$IPFIX_CORE_STARTTIME_FILE" ] && [ ! -e "$IPFIX_PLUGIN_STARTTIME_FILE" ] &&
    [ ! -e "$METRICS_EXPORT_PID_FILE" ] && [ ! -e "$METRICS_EXPORT_STARTTIME_FILE" ] &&
    ! nat_table_exists && ! filter_table_exists
}

r14_collect_failure_diagnostics() {
  r14_prepare_report
  {
    echo 'R14 bounded failure diagnostics'; date -u +%Y-%m-%dT%H:%M:%SZ
    "$HVR_REPO_DIR/lab/scripts/runtime-status.sh" 2>&1 || true
    "$HVR_REPO_DIR/lab/scripts/runtime-check.sh" 2>&1 || true
    ip -brief link; ip -o -4 address; ip -o -4 route; ip rule show
    nft list table ip hvr-nat 2>&1 || true; nft list table inet hvr-filter 2>&1 || true
    tail -n 80 "$(physical_active_dnsmasq_log_file)" 2>/dev/null || true
    tail -n 80 "$IPFIX_LOG_FILE" 2>/dev/null || true
    tail -n 80 "$METRICS_EXPORT_LOG_FILE" 2>/dev/null || true
    ss -H -lunp 2>/dev/null | head -n 80 || true
  } >> "$R14_REPORT" 2>&1
}
