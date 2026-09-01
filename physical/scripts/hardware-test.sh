#!/usr/bin/env bash
set -euo pipefail
r14_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
r14_repo_dir="$(cd "$r14_script_dir/../.." && pwd)"
# shellcheck source=hardware-common.sh
source "$r14_script_dir/hardware-common.sh"

usage() { echo "usage: $0 start | observe-nat --client-ip IP --target IP | observe-firewall --client-ip IP --upstream-peer IP | verify --client-mac MAC --client-ip IP --target IP --ipfix-result FILE | stop" >&2; exit 2; }
argument() {
  local wanted="$1"; shift
  while [ "$#" -gt 0 ]; do
    [ "$1" != "$wanted" ] || { [ "$#" -ge 2 ] || usage; printf '%s' "$2"; return; }
    shift
  done
  return 1
}
valid_ipv4() { python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$1" >/dev/null 2>&1; }
valid_mac() { [[ "$1" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]; }

convergence_signature() {
  local file
  ip -o -4 route show default
  ip -o -4 address show dev "$PHYSICAL_WAN_INTERFACE"
  ip -o -4 address show dev "$PHYSICAL_LAN_INTERFACE"
  nft -nn list table ip hvr-nat; nft -nn list table inet hvr-filter
  for file in "$DNSMASQ_PID_FILE" "$IPFIX_PID_FILE" "$IPFIX_PLUGIN_PID_FILE" "$IPFIX_CORE_STARTTIME_FILE" \
    "$IPFIX_PLUGIN_STARTTIME_FILE" "$METRICS_EXPORT_PID_FILE" "$METRICS_EXPORT_STARTTIME_FILE"; do
    printf '%s=' "$file"; cat "$file"
  done
}

lease_matches() {
  awk -v mac="${1,,}" -v ip="$2" 'tolower($2) == mac && $3 == ip {found=1} END {exit !found}' "$DNSMASQ_LEASE_FILE"
}
dns_evidence_matches() { grep -E "query\[[A-Z]+\] $DNS_TEST_NAME from $1([[:space:]]|$)" "$DNSMASQ_LOG_FILE" >/dev/null; }
ipfix_evidence_matches() {
  [ -r "$1" ] || return 1
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
assert result.get("required_fields_complete") is True
assert result.get("client_source_preserved") is True
record = result.get("expected_record")
assert result.get("expected_record_seen") is True and record
assert record.get("sourceIPv4Address") == sys.argv[2]
assert record.get("destinationIPv4Address") == sys.argv[3]
assert record.get("protocolIdentifier") == 1
PY
}
metrics_increased() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
def values(path):
    rows=json.load(open(path, encoding="utf-8"))["router"]["metrics"]
    return {(x["interface"]["name"],x["name"]):x["value"] for x in rows if "interface" in x}
before, after=values(sys.argv[1]), values(sys.argv[2])
for interface in sys.argv[3:]:
    names=("interface.rx_bytes","interface.tx_bytes","interface.rx_packets","interface.tx_packets")
    assert all(after[(interface,n)] >= before[(interface,n)] for n in names)
    assert (interface,"interface.operstate") in after
assert after[(sys.argv[3],"interface.rx_bytes")] > before[(sys.argv[3],"interface.rx_bytes")]
assert after[(sys.argv[4],"interface.tx_bytes")] > before[(sys.argv[4],"interface.tx_bytes")]
PY
}

start_test() {
  [ ! -e "$R14_CHECKPOINT" ] || die "R14 checkpoint already exists; finish or recover the prior run"
  "$r14_script_dir/hardware-check.sh"
  [ ! -e "$RUNTIME_STATE_FILE" ] && r14_runtime_residue_absent || die "R14 core start requires an absent, residue-free HVR runtime"
  r14_prepare_report; : > "$R14_SUMMARY"; r14_capture_inventory "$R14_DIR/hardware-before.txt"; r14_write_checkpoint
  r14_result "Preflight" PASS
  printf 'R14 DEPLOYED ROUTER VALIDATION\nWAN: %s\nLAN: %s\nThis test will modify networking on these exact pre-existing interfaces.\n' "$PHYSICAL_WAN_INTERFACE" "$PHYSICAL_LAN_INTERFACE"
  "$r14_repo_dir/lab/scripts/runtime-start.sh"
  r14_check "First start" "$r14_repo_dir/lab/scripts/runtime-check.sh"
  "$r14_repo_dir/lab/scripts/show-metrics.sh" > "$R14_METRICS_BEFORE"
  before="$(convergence_signature)"; "$r14_repo_dir/lab/scripts/runtime-start.sh"
  r14_check "Repeated start" test "$before" = "$(convergence_signature)"
  r14_check "Runtime status/check" "$r14_repo_dir/lab/scripts/runtime-check.sh"
  for label in "DHCP/DNS/routing client proof" "NAT observation" "Firewall upstream proof" "IPFIX decoded flow" "Metrics counter movement"; do r14_result "$label" "NOT RUN"; done
  echo "R14 start passed. Complete the documented client and controlled-upstream steps."
}

observe_nat() {
  local client target
  client="$(argument --client-ip "$@")" || usage; target="$(argument --target "$@")" || usage
  valid_ipv4 "$client" && valid_ipv4 "$target" || die "client and target must be explicit IPv4 addresses"
  [ -r "$R14_CHECKPOINT" ] && r14_checkpoint_identity_matches || die "R14 checkpoint/interface identity mismatch"
  rm -f -- "$R14_NAT_PROOF"
  echo "Waiting 20 seconds for translated ICMP $PHYSICAL_WAN_ADDRESS -> $target; generate it from $client now."
  timeout 20 tcpdump -U -n -i "$PHYSICAL_WAN_INTERFACE" -c 1 "icmp and src host $PHYSICAL_WAN_ADDRESS and dst host $target" > "$R14_NAT_PROOF" 2>&1
  grep -F "$PHYSICAL_WAN_ADDRESS > $target" "$R14_NAT_PROOF" >/dev/null
  r14_result "NAT observation" PASS
}

observe_firewall() {
  local client peer lan_capture="$R14_DIR/firewall-lan.txt" lan_pid
  client="$(argument --client-ip "$@")" || usage; peer="$(argument --upstream-peer "$@")" || usage
  valid_ipv4 "$client" && valid_ipv4 "$peer" || die "client and controlled upstream peer must be explicit IPv4 addresses"
  [ -r "$R14_CHECKPOINT" ] && r14_checkpoint_identity_matches || die "R14 checkpoint/interface identity mismatch"
  rm -f -- "$R14_FIREWALL_PROOF" "$R14_FIREWALL_OK" "$lan_capture"
  timeout 20 tcpdump -U -n -i "$PHYSICAL_LAN_INTERFACE" -c 1 "icmp and src host $peer and dst host $client" > "$lan_capture" 2>&1 &
  lan_pid=$!
  echo "Waiting 20 seconds for the controlled peer $peer to send ICMP toward $client."
  if ! timeout 20 tcpdump -U -n -i "$PHYSICAL_WAN_INTERFACE" -c 1 "icmp and src host $peer and dst host $client" > "$R14_FIREWALL_PROOF" 2>&1; then
    kill "$lan_pid" 2>/dev/null || true; wait "$lan_pid" 2>/dev/null || true
    die "controlled upstream probe was not observed on WAN"
  fi
  sleep 1; kill "$lan_pid" 2>/dev/null || true; wait "$lan_pid" 2>/dev/null || true
  ! grep -E ' IP .+ > .+:' "$lan_capture" >/dev/null || die "unsolicited probe reached the LAN capture"
  printf 'WAN_PROBE_OBSERVED_LAN_PROBE_ABSENT\n' > "$R14_FIREWALL_OK"
  chmod 0600 "$R14_FIREWALL_OK"
  r14_result "Firewall upstream proof" PASS
}

verify_test() {
  local mac client target result after="$R14_DIR/metrics-after.json"
  mac="$(argument --client-mac "$@")" || usage; client="$(argument --client-ip "$@")" || usage
  target="$(argument --target "$@")" || usage; result="$(argument --ipfix-result "$@")" || usage
  valid_mac "$mac" && valid_ipv4 "$client" && valid_ipv4 "$target" || die "explicit client MAC/client IPv4/target IPv4 are required"
  [ -r "$R14_CHECKPOINT" ] && r14_checkpoint_identity_matches || die "R14 checkpoint/interface identity mismatch"
  "$r14_repo_dir/lab/scripts/runtime-check.sh"; "$r14_repo_dir/lab/scripts/show-metrics.sh" > "$after"
  r14_check "DHCP lease" lease_matches "$mac" "$client"
  r14_check "DNS through HVR" dns_evidence_matches "$client"
  r14_check "NAT translated source" grep -F "$PHYSICAL_WAN_ADDRESS > $target" "$R14_NAT_PROOF"
  r14_check "Firewall upstream block" grep -F -x 'WAN_PROBE_OBSERVED_LAN_PROBE_ABSENT' "$R14_FIREWALL_OK"
  r14_check "IPFIX decoded flow" ipfix_evidence_matches "$result" "$client" "$target"
  r14_check "Metrics counter movement" metrics_increased "$R14_METRICS_BEFORE" "$after" "$PHYSICAL_LAN_INTERFACE" "$PHYSICAL_WAN_INTERFACE"
  r14_check "Runtime status/check" "$r14_repo_dir/lab/scripts/runtime-check.sh"
  for label in "Observability integration" "Hardware reboot validation" "Link-loss validation"; do r14_result "$label" "NOT RUN"; done
  echo "R14 core verification evidence passed; stop and restoration checks remain required."
}

stop_test() {
  local expected actual core_evidence=1 label
  [ -r "$R14_CHECKPOINT" ] && r14_checkpoint_identity_matches || die "R14 checkpoint/interface identity mismatch; refusing teardown"
  for label in "DHCP lease" "DNS through HVR" "NAT translated source" "Firewall upstream block" "IPFIX decoded flow" "Metrics counter movement" "Runtime status/check"; do
    r14_summary_latest_is_pass "$label" || core_evidence=0
  done
  "$r14_repo_dir/lab/scripts/runtime-stop.sh"
  r14_check "Runtime stop" r14_runtime_residue_absent
  r14_check "Forwarding restoration" test "$(sysctl -n net.ipv4.ip_forward)" = "$(r14_checkpoint_field FORWARDING)"
  r14_check "Default-route restoration" cmp -s "$R14_DEFAULT_ROUTES_BEFORE" <(ip -o -4 route show default)
  expected="$(r14_checkpoint_field WAN_ADDRESS_PRESENT)"; actual=0; physical_address_exists "$PHYSICAL_WAN_INTERFACE" "$PHYSICAL_WAN_ADDRESS/$PHYSICAL_WAN_PREFIX_LENGTH" && actual=1
  r14_check "WAN address restoration" test "$actual" = "$expected"
  expected="$(r14_checkpoint_field LAN_ADDRESS_PRESENT)"; actual=0; physical_address_exists "$PHYSICAL_LAN_INTERFACE" "$ROUTER_LAN/${LAN_SUBNET#*/}" && actual=1
  r14_check "LAN address restoration" test "$actual" = "$expected"
  expected="$(r14_checkpoint_field WAN_UP)"; actual=0; physical_interface_is_up "$PHYSICAL_WAN_INTERFACE" && actual=1
  r14_check "WAN link restoration" test "$actual" = "$expected"
  expected="$(r14_checkpoint_field LAN_UP)"; actual=0; physical_interface_is_up "$PHYSICAL_LAN_INTERFACE" && actual=1
  r14_check "LAN link restoration" test "$actual" = "$expected"
  r14_check "Residue" r14_runtime_residue_absent; r14_result "Host restoration" PASS
  rm -f -- "$R14_CHECKPOINT" "$R14_DEFAULT_ROUTES_BEFORE"
  rmdir "$R14_PERSIST_DIR" 2>/dev/null || true
  if [ "$core_evidence" -eq 1 ]; then
    r14_result "R14 deployment acceptance" PASS
    echo "R14 deployed virtual-router core acceptance passed."
  else
    r14_result "R14 deployment acceptance" "NOT RUN"
    echo "R14 teardown passed, but core acceptance was not completed."
  fi
  echo 'R14 Virtual-Router Deployment Acceptance'
  awk -F '\t' '{latest[$1]=$2; order[++count]=$1} END {for(i=1;i<=count;i++) if(!seen[order[i]]++) printf "%-34s %s\n", order[i], latest[order[i]]}' "$R14_SUMMARY"
}

trap 'status=$?; if [ "$status" -ne 0 ]; then r14_collect_failure_diagnostics; fi; exit "$status"' EXIT
r14_require_real_hardware
case "${1:-}" in
  start) shift; [ "$#" -eq 0 ] || usage; start_test ;;
  observe-nat) shift; observe_nat "$@" ;;
  observe-firewall) shift; observe_firewall "$@" ;;
  verify) shift; verify_test "$@" ;;
  stop) shift; [ "$#" -eq 0 ] || usage; stop_test ;;
  *) usage ;;
esac
trap - EXIT
