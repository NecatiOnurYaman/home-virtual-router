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
command -v ip >/dev/null 2>&1 || die "iproute2 is required"
command -v nft >/dev/null 2>&1 || die "nftables is required"
command -v ping >/dev/null 2>&1 || die "ping is required"
command -v python3 >/dev/null 2>&1 || die "Python 3 is required for deterministic source-address verification"
require_r2_topology

default_route_before="$(capture_default_route)"
require_default_route_is_not_lab_interface "$default_route_before"
host_forwarding_before="$(capture_host_ipv4_forwarding)"
host_nftables_before="$(capture_host_nftables)"

[ "$(ip netns exec "$ROUTER_NAMESPACE" sysctl -n net.ipv4.ip_forward)" = "1" ] ||
  die "router-namespace forwarding is not enabled"
client_default_route_exists || die "client default route is absent"
nat_rule_exists || die "exact R4 masquerade rule is absent"
if ip -n "$UPSTREAM_NAMESPACE" route show "$LAN_SUBNET" | grep -q .; then
  die "upstream still has a route to the LAN; R4 must work without it"
fi
if ip -n "$UPSTREAM_NAMESPACE" route get "$CLIENT_ADDRESS" >/dev/null 2>&1; then
  die "upstream unexpectedly has a route to the downstream client"
fi

ping_path() {
  local namespace="$1" destination="$2"
  printf 'Ping from %s to %s... ' "$namespace" "$destination"
  ip netns exec "$namespace" ping -c 2 -W 1 "$destination" >/dev/null
  printf 'ok\n'
}

ping_path "$CLIENT_NAMESPACE" "$ROUTER_LAN"
ping_path "$CLIENT_NAMESPACE" "$ROUTER_WAN"
ping_path "$CLIENT_NAMESPACE" "$UPSTREAM_GATEWAY"
ping_path "$UPSTREAM_NAMESPACE" "$ROUTER_WAN"

# A UDP listener reports the source address actually observed in hvr-upstream.
# This proves translation directly instead of inferring it from connectivity.
capture_file="$(mktemp)"
server_pid=""
cleanup_nat_test() {
  local status=$?
  trap - EXIT INT TERM
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -f "$capture_file"
  exit "$status"
}
trap cleanup_nat_test EXIT INT TERM

udp_port=45454
ip netns exec "$UPSTREAM_NAMESPACE" python3 -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((sys.argv[1], int(sys.argv[2])))
s.settimeout(3)
print("READY", flush=True)
_, peer = s.recvfrom(1024)
print(peer[0], flush=True)
' "$UPSTREAM_GATEWAY" "$udp_port" >"$capture_file" &
server_pid=$!

ready=0
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if grep -F -x READY "$capture_file" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.05
done
[ "$ready" -eq 1 ] || die "upstream UDP source-address observer did not become ready"

ip netns exec "$CLIENT_NAMESPACE" python3 -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(b"hvr-r4-source-check", (sys.argv[1], int(sys.argv[2])))
' "$UPSTREAM_GATEWAY" "$udp_port"
wait "$server_pid"
server_pid=""
observed_source="$(tail -n 1 "$capture_file")"
[ "$observed_source" = "$ROUTER_WAN" ] ||
  die "upstream observed source $observed_source; expected masqueraded source $ROUTER_WAN"
printf 'Upstream observed translated UDP source: %s\n' "$observed_source"

verify_default_route_unchanged "$default_route_before"
verify_host_ipv4_forwarding_unchanged "$host_forwarding_before"
verify_host_nftables_unchanged "$host_nftables_before"
trap - EXIT INT TERM
rm -f "$capture_file"
printf 'R4 NAT tests passed; kernel conntrack handled translation state and replies.\n'
