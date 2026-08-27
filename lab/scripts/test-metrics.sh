#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../router/scripts/safety.sh
source "$script_dir/../../router/scripts/safety.sh"
# shellcheck source=topology-common.sh
source "$script_dir/topology-common.sh"

require_lab_environment
require_root
load_topology_config
validate_topology_names
require_r2_topology
for command in ip python3 ping; do command -v "$command" >/dev/null 2>&1 || die "$command is required"; done

before="$(mktemp)"
after="$(mktemp)"
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  rm -f -- "$before" "$after"
  exit "$status"
}
trap cleanup EXIT INT TERM

"$script_dir/show-metrics.sh" > "$before"
ip netns exec "$CLIENT_NAMESPACE" ping -c 3 -W 1 "$UPSTREAM_GATEWAY" >/dev/null ||
  die "client could not reach the R10 counter test endpoint $UPSTREAM_GATEWAY"
"$script_dir/show-metrics.sh" > "$after"

python3 - "$before" "$after" "$ROUTER_LAN_INTERFACE" "$ROUTER_WAN_INTERFACE" <<'PY'
import json
import sys

before_path, after_path, lan_name, wan_name = sys.argv[1:]
with open(before_path, encoding="utf-8") as stream:
    before = json.load(stream)
with open(after_path, encoding="utf-8") as stream:
    after = json.load(stream)

def counters(snapshot, interface_name):
    return {
        item["name"]: item["value"]
        for item in snapshot["router"]["metrics"]
        if item.get("interface", {}).get("name") == interface_name
        and item["name"] in {"interface.rx_bytes", "interface.tx_bytes", "interface.rx_packets", "interface.tx_packets"}
    }

for interface_name in (lan_name, wan_name):
    old = counters(before, interface_name)
    new = counters(after, interface_name)
    if old.keys() != new.keys() or len(old) != 4:
        raise SystemExit(f"error: required traffic counters are absent for {interface_name}")
    if sum(new.values()) <= sum(old.values()):
        raise SystemExit(f"error: cumulative traffic counters did not increase for {interface_name}")
print(json.dumps({"interfaces_verified": [lan_name, wan_name], "counter_increase": True}, sort_keys=True))
PY

trap - EXIT INT TERM
rm -f -- "$before" "$after"
printf 'R10 local metrics validation passed; LAN/WAN cumulative counters increased.\n'
