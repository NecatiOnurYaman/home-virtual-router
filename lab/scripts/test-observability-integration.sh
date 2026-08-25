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
[ "$TELEMETRY_MODE" = "observability" ] || die "R9 integration test requires TELEMETRY_MODE=observability"
for command in ip curl python3 ping dig; do command -v "$command" >/dev/null 2>&1 || die "$command is required"; done
require_r2_topology
dns_r7_enabled || die "R7 DNS is not running"
pmacctd_running || die "R8 pmacctd/nfprobe exporter is not running"
assert_single_project_pmacct_pair
[ -e "/sys/class/net/$TELEMETRY_HOST_INTERFACE" ] || die "R9 telemetry link is absent; run make observability-enable"
[ -r "$TELEMETRY_EXPORT_DIR/dnsmasq.leases" ] || die "exported DHCP lease file is not readable"
[ -r "$TELEMETRY_EXPORT_DIR/dnsmasq.log" ] || die "exported DNS log file is not readable"

api_base="${OBSERVABILITY_API_URL:-http://127.0.0.1:8000}"
curl -fsS "$api_base/api/status" >/dev/null || die "observability backend is not reachable at $api_base"
collector_before="$(curl -fsS "$api_base/api/collector/status")"
baseline="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
client_ip="$(client_dhcp_address)" || die "hvr-client has no unique dynamic DHCP address"
client_mac="$(ip -n "$CLIENT_NAMESPACE" -o link show dev "$CLIENT_INTERFACE" | awk '{for (i = 1; i <= NF; i++) if ($i == "link/ether") print $(i + 1)}')"
lease_line="$(awk -v mac="$client_mac" -v ip="$client_ip" '$2 == mac && $3 == ip && $4 == "hvr-client" {print; found=1} END {exit !found}' "$DNSMASQ_LEASE_FILE")" ||
  die "real hvr-client lease is absent"

ip netns exec "$CLIENT_NAMESPACE" ping -c 2 -W 1 "$DNS_TEST_ADDRESS" >/dev/null
ip netns exec "$CLIENT_NAMESPACE" dig +tries=1 +time=2 "@$ROUTER_LAN" "$DNS_TEST_NAME" A >/dev/null
ip netns exec "$CLIENT_NAMESPACE" dig +tcp +tries=1 +time=2 "@$ROUTER_LAN" "$DNS_TEST_NAME" A >/dev/null
ip netns exec "$CLIENT_NAMESPACE" ping -c 2 -W 1 "$DNS_TEST_ADDRESS" >/dev/null

python3 - "$api_base" "$baseline" "$client_ip" "$client_mac" "$DNS_TEST_NAME" "$DNS_TEST_ADDRESS" "$collector_before" <<'PY'
import datetime as dt
import json
import sys
import time
import urllib.parse
import urllib.request

base, baseline_raw, client_ip, client_mac, domain, response_ip, before_raw = sys.argv[1:]
baseline = dt.datetime.fromisoformat(baseline_raw.replace("Z", "+00:00"))
before = json.loads(before_raw)

def get(path, parameters=None):
    query = "?" + urllib.parse.urlencode(parameters) if parameters else ""
    with urllib.request.urlopen(base + path + query, timeout=3) as response:
        return json.load(response)

deadline = time.monotonic() + 35
last = {}
while time.monotonic() < deadline:
    status = get("/api/collector/status")
    flows = get("/api/flows", {"start": baseline_raw, "src_ip": client_ip, "limit": 100})
    devices = get("/api/devices", {"mac": client_mac})
    dns = get("/api/dns", {"start": baseline_raw, "client_ip": client_ip, "domain": domain, "limit": 100})
    candidates = [item for item in flows["items"] if dt.datetime.fromisoformat(item["created_at"].replace("Z", "+00:00")) >= baseline and item["packets"] and item["bytes"] and item["start_time"] and item["observation_domain_id"] is not None]
    last = {"collector": status, "flows": flows, "devices": devices, "dns": dns}
    if status["persisted_flows"] > before["persisted_flows"] and candidates and devices["items"] and dns["items"]:
        break
    time.sleep(1)
else:
    raise SystemExit("timed out waiting for parsed, normalized, persisted IPFIX plus DHCP and DNS telemetry: " + json.dumps(last, default=str))

flow = next((item for item in candidates if item["dst_ip"] == response_ip), candidates[0])
device = devices["items"][0]
event = dns["items"][0]
if device["hostname"] != "hvr-client" or not any(item["ip_address"] == client_ip and item["source"] == "DHCP" for item in device["addresses"]):
    raise SystemExit("device record does not contain the real DHCP identity")
if event["query_name"] != domain or event["client_ip"] != client_ip:
    raise SystemExit("DNS event does not contain the real client query")
end = dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z")
analytics_current = get("/api/analytics/current", {"lookback_seconds": 120})
analytics_protocols = get("/api/analytics/protocols", {"start": baseline_raw, "end": end})
if analytics_current["flow_count"] < 1 or not analytics_protocols:
    raise SystemExit("real flow did not contribute to analytics")
correlation = get(f"/api/flows/{flow['id']}/dns-correlation")
if flow["dst_ip"] == response_ip and correlation["correlated_domain"] != domain:
    raise SystemExit("response-address flow was not correlated to the real DNS event")
print(json.dumps({
    "baseline": baseline_raw,
    "client": {"ip": client_ip, "mac": client_mac},
    "device": device,
    "dns_event": event,
    "flow": flow,
    "dns_correlation": correlation,
    "collector_before": before,
    "collector_after": status,
    "analytics_current": analytics_current,
    "analytics_protocols": analytics_protocols,
    "acceptance_latency_seconds": round((dt.datetime.now(dt.UTC) - baseline).total_seconds(), 3),
}, indent=2))
PY

pmacctd_running || die "pmacctd/nfprobe stopped during R9 acceptance"
assert_single_project_pmacct_pair
printf 'R9 real-router observability integration passed for lease: %s\n' "$lease_line"
