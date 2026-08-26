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

ip netns exec "$CLIENT_NAMESPACE" ping -c 2 -W 1 "$UPSTREAM_GATEWAY" >/dev/null ||
  die "client could not reach the R9 routed test endpoint $UPSTREAM_GATEWAY"
ip netns exec "$CLIENT_NAMESPACE" dig +tries=1 +time=2 "@$ROUTER_LAN" "$DNS_TEST_NAME" A >/dev/null ||
  die "client UDP DNS query for $DNS_TEST_NAME through $ROUTER_LAN failed"
ip netns exec "$CLIENT_NAMESPACE" dig +tcp +tries=1 +time=2 "@$ROUTER_LAN" "$DNS_TEST_NAME_ALT" A >/dev/null ||
  die "client TCP DNS query for $DNS_TEST_NAME_ALT through $ROUTER_LAN failed"

python3 - "$api_base" "$baseline" "$client_ip" "$client_mac" "$DNS_TEST_NAME" "$DNS_TEST_NAME_ALT" "$UPSTREAM_GATEWAY" "$ROUTER_LAN" "$collector_before" <<'PY'
import datetime as dt
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

base, baseline_raw, client_ip, client_mac, udp_domain, tcp_domain, upstream_ip, router_ip, before_raw = sys.argv[1:]
baseline = dt.datetime.fromisoformat(baseline_raw.replace("Z", "+00:00"))

def fail(assertion, details=None):
    message = f"R9 assertion failed: {assertion}"
    if details is not None:
        message += ": " + json.dumps(details, default=str, sort_keys=True)
    raise SystemExit(message)

try:
    before = json.loads(before_raw)
except (TypeError, ValueError) as error:
    fail("collector baseline was not valid JSON", str(error))

def get(path, parameters=None):
    query = "?" + urllib.parse.urlencode(parameters) if parameters else ""
    url = base + path + query
    try:
        with urllib.request.urlopen(url, timeout=3) as response:
            return json.load(response)
    except (OSError, ValueError, urllib.error.URLError) as error:
        fail(f"API request failed for {path}", {"url": url, "error": str(error)})

def parsed_time(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))

def complete_flow(item):
    return (
        parsed_time(item["created_at"]) >= baseline
        and item["packets"] is not None and item["packets"] > 0
        and item["bytes"] is not None and item["bytes"] > 0
        and item["start_time"] is not None
        and item["end_time"] is not None
        and item["exporter_ip"]
        and item["observation_domain_id"] is not None
        and item["template_id"] is not None
    )

deadline = time.monotonic() + 35
last = {}
while time.monotonic() < deadline:
    status = get("/api/collector/status")
    flows = get("/api/flows", {"start": baseline_raw, "src_ip": client_ip, "limit": 100})
    devices = get("/api/devices", {"mac": client_mac})
    udp_dns = get("/api/dns", {"start": baseline_raw, "client_ip": client_ip, "domain": udp_domain, "limit": 100})
    tcp_dns = get("/api/dns", {"start": baseline_raw, "client_ip": client_ip, "domain": tcp_domain, "limit": 100})
    end = dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z")
    analytics_protocols = get("/api/analytics/protocols", {"start": baseline_raw, "end": end})
    candidates = [item for item in flows["items"] if complete_flow(item)]
    routed = [item for item in candidates if item["src_ip"] == client_ip and item["dst_ip"] == upstream_ip]
    dns_flows = [item for item in candidates if item["src_ip"] == client_ip and item["dst_ip"] == router_ip and item["protocol"] in (6, 17) and item["dst_port"] == 53]
    last = {
        "collector_datagrams_increased": status["received_datagrams"] > before["received_datagrams"],
        "collector_persisted_flows_increased": status["persisted_flows"] > before["persisted_flows"],
        "fresh_complete_client_flows": len(candidates),
        "fresh_routed_upstream_flows": len(routed),
        "fresh_client_router_dns_flows": len(dns_flows),
        "matching_devices": len(devices["items"]),
        "fresh_udp_dns_events": len(udp_dns["items"]),
        "fresh_tcp_dns_events": len(tcp_dns["items"]),
        "interval_analytics_rows": len(analytics_protocols),
        "collector": status,
    }
    if (status["received_datagrams"] > before["received_datagrams"]
            and status["persisted_flows"] > before["persisted_flows"]
            and candidates and routed and dns_flows and devices["items"]
            and udp_dns["items"] and tcp_dns["items"] and analytics_protocols):
        break
    time.sleep(1)
else:
    fail("timed out waiting for fresh IPFIX, DHCP, DNS, and interval analytics telemetry", last)

device = devices["items"][0]
if device["hostname"] != "hvr-client" or not any(item["ip_address"] == client_ip and item["source"] == "DHCP" for item in device["addresses"]):
    fail("device record does not contain the real DHCP MAC/IP/hostname", device)
udp_event = udp_dns["items"][0]
tcp_event = tcp_dns["items"][0]
if udp_event["query_name"] != udp_domain or udp_event["client_ip"] != client_ip:
    fail("fresh UDP DNS event does not match the generated client query", udp_event)
if tcp_event["query_name"] != tcp_domain or tcp_event["client_ip"] != client_ip:
    fail("fresh TCP DNS event does not match the generated client query", tcp_event)
analytics_current = get("/api/analytics/current")
correlation = get(f"/api/flows/{dns_flows[0]['id']}/dns-correlation")
print(json.dumps({
    "baseline": baseline_raw,
    "client": {"ip": client_ip, "mac": client_mac},
    "device": device,
    "udp_dns_event": udp_event,
    "tcp_dns_event": tcp_event,
    "routed_flow": routed[0],
    "dns_flow": dns_flows[0],
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
require_r2_topology
[ "$(client_dhcp_address)" = "$client_ip" ] || die "R9 acceptance changed the R6 client DHCP address"
dns_r7_enabled || die "R9 acceptance changed the R7 DNS state"
nat_rule_exists || die "R9 acceptance changed the R4 NAT state"
filter_rules_exist || die "R9 acceptance changed the R5 firewall state"
printf 'R9 real-router observability integration passed for lease: %s\n' "$lease_line"
