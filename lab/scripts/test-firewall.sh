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
command -v python3 >/dev/null 2>&1 || die "Python 3 is required for TCP firewall tests"
require_r2_topology
require_r4_nat_state
filter_rules_exist || die "exact R5 forwarding policy is absent"

default_route_before="$(capture_default_route)"
require_default_route_is_not_lab_interface "$default_route_before"
host_forwarding_before="$(capture_host_ipv4_forwarding)"
host_nftables_before="$(capture_host_nftables)"

positive_file="$(mktemp)"
blocked_file="$(mktemp)"
positive_pid=""
blocked_pid=""
test_route_added=0
cleanup_firewall_test() {
  local status=$?
  trap - EXIT INT TERM
  if [ "$test_route_added" -eq 1 ]; then
    ip -n "$UPSTREAM_NAMESPACE" route del "$LAN_SUBNET" via "$ROUTER_WAN" dev "$UPSTREAM_INTERFACE" 2>/dev/null || true
  fi
  for process_id in "$positive_pid" "$blocked_pid"; do
    if [ -n "$process_id" ]; then
      kill "$process_id" 2>/dev/null || true
      wait "$process_id" 2>/dev/null || true
    fi
  done
  verify_default_route_unchanged "$default_route_before" || status=1
  verify_host_ipv4_forwarding_unchanged "$host_forwarding_before" || status=1
  verify_host_nftables_unchanged "$host_nftables_before" || status=1
  rm -f "$positive_file" "$blocked_file"
  exit "$status"
}
trap cleanup_firewall_test EXIT INT TERM

printf 'Client-initiated ping to upstream... '
ip netns exec "$CLIENT_NAMESPACE" ping -c 2 -W 1 "$UPSTREAM_GATEWAY" >/dev/null
printf 'ok\n'

# Positive stateful TCP test: a client-created connection crosses LAN -> WAN,
# and the server reply must return through established connection state.
positive_port=45460
ip netns exec "$UPSTREAM_NAMESPACE" python3 -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], int(sys.argv[2])))
s.listen(1)
s.settimeout(4)
print("READY", flush=True)
c, peer = s.accept()
c.settimeout(2)
data = c.recv(1024)
if data != b"hvr-r5-request":
    raise SystemExit("unexpected request")
print(peer[0], flush=True)
c.sendall(b"hvr-r5-reply")
' "$UPSTREAM_GATEWAY" "$positive_port" >"$positive_file" 2>&1 &
positive_pid=$!

for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  grep -F -x READY "$positive_file" >/dev/null 2>&1 && break
  sleep 0.05
done
grep -F -x READY "$positive_file" >/dev/null || die "upstream TCP test server did not become ready"
ip netns exec "$CLIENT_NAMESPACE" python3 -c '
import socket, sys
s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=2)
s.sendall(b"hvr-r5-request")
if s.recv(1024) != b"hvr-r5-reply":
    raise SystemExit("stateful reply was not received")
' "$UPSTREAM_GATEWAY" "$positive_port"
wait "$positive_pid"
positive_pid=""
printf 'Client-initiated TCP exchange and established reply... ok\n'

# Add an exact, temporary lab-only route so the WAN test has a route to the
# client. A real listening socket prevents connection-refused false positives.
drop_packets_before="$(filter_rule_packet_count hvr-r5-wan-lan-drop)"
ip -n "$UPSTREAM_NAMESPACE" route add "$LAN_SUBNET" via "$ROUTER_WAN" dev "$UPSTREAM_INTERFACE"
test_route_added=1
blocked_port=45461
ip netns exec "$CLIENT_NAMESPACE" python3 -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], int(sys.argv[2])))
s.listen(1)
s.settimeout(3)
print("READY", flush=True)
s.accept()
print("ACCEPTED", flush=True)
' "$CLIENT_ADDRESS" "$blocked_port" >"$blocked_file" 2>&1 &
blocked_pid=$!

for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  grep -F -x READY "$blocked_file" >/dev/null 2>&1 && break
  sleep 0.05
done
grep -F -x READY "$blocked_file" >/dev/null || die "client TCP test server did not become ready"
printf 'Unsolicited WAN-to-LAN TCP connection... '
if ip netns exec "$UPSTREAM_NAMESPACE" python3 -c '
import socket, sys
s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=1)
' "$CLIENT_ADDRESS" "$blocked_port" >/dev/null 2>&1; then
  die "unsolicited WAN-to-LAN connection passed the default-drop firewall"
fi
printf 'blocked as expected\n'
drop_packets_after="$(filter_rule_packet_count hvr-r5-wan-lan-drop)"
if [ "$drop_packets_after" -le "$drop_packets_before" ]; then
  die "default-drop counter did not increase for the unsolicited WAN-to-LAN flow"
fi
printf 'Default-drop counter increased: %s -> %s\n' "$drop_packets_before" "$drop_packets_after"

ip -n "$UPSTREAM_NAMESPACE" route del "$LAN_SUBNET" via "$ROUTER_WAN" dev "$UPSTREAM_INTERFACE"
test_route_added=0
kill "$blocked_pid" 2>/dev/null || true
wait "$blocked_pid" 2>/dev/null || true
blocked_pid=""

require_r4_nat_state
filter_rules_exist || die "R5 policy changed during testing"
verify_default_route_unchanged "$default_route_before"
verify_host_ipv4_forwarding_unchanged "$host_forwarding_before"
verify_host_nftables_unchanged "$host_nftables_before"
trap - EXIT INT TERM
rm -f "$positive_file" "$blocked_file"
printf 'R5 firewall tests passed; temporary WAN test route was removed.\n'
