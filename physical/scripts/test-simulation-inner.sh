#!/usr/bin/env bash
set -euo pipefail
repo_dir="$1" simulation_config="$2" outer_net_namespace="$3" outer_mount_namespace="$4"
for command in ip nft sysctl dnsmasq dhclient dig ping tcpdump python3; do
  command -v "$command" >/dev/null || { echo "error: physical simulation requires $command" >&2; exit 1; }
done
mount --make-rprivate /
mount -t tmpfs tmpfs /run
mkdir -p /run/home-virtual-router
export HVR_INTERNAL_PHYSICAL_SIMULATION=1
export HVR_INTERNAL_SIMULATION_CONFIG="$simulation_config"
export HVR_INTERNAL_OUTER_NET_NAMESPACE="$outer_net_namespace"
export HVR_INTERNAL_OUTER_MOUNT_NAMESPACE="$outer_mount_namespace"
cleanup() {
  set +e
  "$repo_dir/lab/scripts/runtime-stop.sh" >/dev/null 2>&1
  [ ! -s /run/home-virtual-router/physical-simulation/dhclient.pid ] ||
    kill "$(cat /run/home-virtual-router/physical-simulation/dhclient.pid)" 2>/dev/null
  [ ! -s /run/home-virtual-router/physical-simulation/upstream-dnsmasq.pid ] ||
    kill "$(cat /run/home-virtual-router/physical-simulation/upstream-dnsmasq.pid)" 2>/dev/null
  ip netns del hvr-sim-client-ns 2>/dev/null
  ip netns del hvr-sim-upstream-ns 2>/dev/null
}
trap cleanup EXIT
ip netns add hvr-sim-client-ns
ip netns add hvr-sim-upstream-ns
ip link add hvr-sim-wan type veth peer name hvr-sim-up
ip link add hvr-sim-lan type veth peer name hvr-sim-client
ip link set hvr-sim-up netns hvr-sim-upstream-ns
ip link set hvr-sim-client netns hvr-sim-client-ns
ip -n hvr-sim-upstream-ns address add 203.0.113.1/24 dev hvr-sim-up
ip -n hvr-sim-upstream-ns link set hvr-sim-up up
ip -n hvr-sim-upstream-ns route add default via 203.0.113.2 dev hvr-sim-up
install -d -o 0 -g 0 -m 0700 /run/home-virtual-router/physical-simulation
cat > /run/home-virtual-router/physical-simulation/upstream-dnsmasq.conf <<'EOF'
port=53
interface=hvr-sim-up
listen-address=203.0.113.1
bind-interfaces
no-resolv
no-hosts
cache-size=0
address=/example.test/192.0.2.123
pid-file=/run/home-virtual-router/physical-simulation/upstream-dnsmasq.pid
EOF
ip netns exec hvr-sim-upstream-ns dnsmasq --conf-file=/run/home-virtual-router/physical-simulation/upstream-dnsmasq.conf
"$repo_dir/physical/scripts/preflight.sh"
"$repo_dir/lab/scripts/runtime-start.sh"
ip -o -4 address show dev hvr-sim-wan | awk '{print $4}' | grep -F -x '203.0.113.2/24' >/dev/null
ip -o -4 address show dev hvr-sim-lan | awk '{print $4}' | grep -F -x '10.0.0.1/24' >/dev/null
ip -o -4 route show default | grep -E '^default via 203\.0\.113\.1 dev hvr-sim-wan([[:space:]]|$)' >/dev/null
[ "$(sysctl -n net.ipv4.ip_forward)" = 1 ]
nft list table ip hvr-nat | grep -F 'oifname "hvr-sim-wan" ip saddr 10.0.0.0/24 masquerade' >/dev/null
nft list table inet hvr-filter | grep -F 'iifname "hvr-sim-lan" oifname "hvr-sim-wan"' >/dev/null
ip netns exec hvr-sim-client-ns env HVR_INTERNAL_PHYSICAL_SIMULATION=1 dhclient -4 -1 -v \
  -pf /run/home-virtual-router/physical-simulation/dhclient.pid \
  -lf /run/home-virtual-router/physical-simulation/dhclient.leases \
  -cf "$repo_dir/router/config/dhclient.conf" \
  -sf "$repo_dir/physical/scripts/simulation-dhclient-hook.sh" hvr-sim-client
client_address="$(ip -n hvr-sim-client-ns -o -4 address show dev hvr-sim-client scope global | awk '{print $4}')"
case "$client_address" in 10.0.0.1??/24) ;; *) echo "error: simulated client lease is invalid: $client_address" >&2; exit 1 ;; esac
ip -n hvr-sim-client-ns route show default | grep -E '^default via 10\.0\.0\.1 dev hvr-sim-client([[:space:]]|$)' >/dev/null
timeout 5 ip netns exec hvr-sim-upstream-ns tcpdump -U -n -i hvr-sim-up -c 1 \
  'icmp and src host 203.0.113.2' >/run/home-virtual-router/physical-simulation/nat-proof.txt 2>&1 &
capture_pid=$!
sleep 0.2
ip netns exec hvr-sim-client-ns ping -c 2 -W 2 203.0.113.1 >/dev/null
wait "$capture_pid"
ip netns exec hvr-sim-client-ns dig +time=2 +tries=1 @10.0.0.1 example.test A +short | grep -F -x 192.0.2.123 >/dev/null
grep -F -x 'interface=hvr-sim-lan' /run/home-virtual-router/ipfix/pmacctd.conf >/dev/null
metrics_json="$("$repo_dir/lab/scripts/show-metrics.sh")"
python3 -c 'import json,sys; d=json.load(sys.stdin); m=d["router"]["metrics"]; i={x["interface"]["role"]:x["interface"]["name"] for x in m if "interface" in x}; assert i=={"lan":"hvr-sim-lan","wan":"hvr-sim-wan"}' <<<"$metrics_json"
"$repo_dir/lab/scripts/runtime-start.sh"
"$repo_dir/lab/scripts/runtime-status.sh"
"$repo_dir/lab/scripts/runtime-check.sh"
"$repo_dir/lab/scripts/runtime-stop.sh"
"$repo_dir/lab/scripts/runtime-stop.sh"
ip -o -4 address show dev hvr-sim-wan | grep -F '203.0.113.2/' >/dev/null 2>&1 && exit 1 || true
[ ! -e /run/home-virtual-router/runtime/state.env ]
trap - EXIT
cleanup
