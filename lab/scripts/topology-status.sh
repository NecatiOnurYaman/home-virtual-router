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

printf 'R2 topology status (lab namespaces only)\n'
for namespace in "$UPSTREAM_NAMESPACE" "$ROUTER_NAMESPACE" "$CLIENT_NAMESPACE"; do
  printf '\n[%s]\n' "$namespace"
  if ! namespace_exists "$namespace"; then
    printf '  namespace: absent\n'
    continue
  fi
  printf '  namespace: present\n'
  printf '  links:\n'
  ip -n "$namespace" -brief link show | sed 's/^/    /'
  printf '  IPv4 addresses:\n'
  ip -n "$namespace" -brief -4 address show | sed 's/^/    /'
  printf '  IPv4 routes:\n'
  ip -n "$namespace" -4 route show | sed 's/^/    /'
done

printf '\n[R3 routing state]\n'
if namespace_exists "$ROUTER_NAMESPACE" && namespace_exists "$CLIENT_NAMESPACE" && namespace_exists "$UPSTREAM_NAMESPACE"; then
  forwarding="$(ip netns exec "$ROUTER_NAMESPACE" sysctl -n net.ipv4.ip_forward)"
  printf '  router IPv4 forwarding: %s\n' "$forwarding"
  printf '  client default route:\n'
  ip -n "$CLIENT_NAMESPACE" route show default | sed 's/^/    /'
  printf '  upstream return route to %s:\n' "$LAN_SUBNET"
  ip -n "$UPSTREAM_NAMESPACE" route show "$LAN_SUBNET" | sed 's/^/    /'
  if [ "$forwarding" = "1" ] && client_default_route_exists; then
    printf '  R3 forwarding/client state: enabled\n'
    if upstream_return_route_exists; then
      printf '  R3 routed-without-NAT return path: enabled\n'
    else
      printf '  R3 routed-without-NAT return path: absent (expected under R4)\n'
    fi
  else
    printf '  R3 forwarding/client state: disabled or incomplete\n'
  fi
else
  printf '  R2 topology: incomplete or absent\n'
  printf '  R3 routing: unavailable\n'
fi

printf '\n[R4 NAT state]\n'
if namespace_exists "$ROUTER_NAMESPACE" && command -v nft >/dev/null 2>&1; then
  if nat_table_exists; then
    printf '  table ip %s: present\n' "$NAT_TABLE"
    printf '  masquerade rule and counters:\n'
    if nat_chain_output="$(router_nft list chain ip "$NAT_TABLE" "$NAT_CHAIN" 2>/dev/null)"; then
      printf '%s\n' "$nat_chain_output" | sed 's/^/    /'
    else
      printf '    expected chain %s is absent\n' "$NAT_CHAIN"
    fi
    if nat_rule_exists && ! ip -n "$UPSTREAM_NAMESPACE" route show "$LAN_SUBNET" | grep -q .; then
      printf '  R4 NAT: enabled\n'
    else
      printf '  R4 NAT: incomplete or conflicting\n'
    fi
  else
    printf '  table ip %s: absent\n' "$NAT_TABLE"
    printf '  R4 NAT: disabled\n'
  fi
else
  printf '  R4 NAT: unavailable (router namespace or nft missing)\n'
fi

printf '\n[R5 firewall state]\n'
if namespace_exists "$ROUTER_NAMESPACE" && command -v nft >/dev/null 2>&1; then
  if filter_table_exists; then
    printf '  table inet %s: present\n' "$FILTER_TABLE"
    printf '  forward policy, rules, and counters:\n'
    if filter_chain_output="$(router_nft list chain inet "$FILTER_TABLE" "$FILTER_CHAIN" 2>/dev/null)"; then
      printf '%s\n' "$filter_chain_output" | sed 's/^/    /'
    else
      printf '    expected chain %s is absent\n' "$FILTER_CHAIN"
    fi
    if filter_rules_exist; then
      printf '  R5 firewall: enabled\n'
    else
      printf '  R5 firewall: incomplete or conflicting\n'
    fi
  else
    printf '  table inet %s: absent\n' "$FILTER_TABLE"
    printf '  R5 firewall: disabled\n'
  fi
else
  printf '  R5 firewall: unavailable (router namespace or nft missing)\n'
fi

printf '\n[R6 DHCP state]\n'
printf '  configured range: %s - %s (%s)\n' "$DHCP_RANGE_START" "$DHCP_RANGE_END" "$DHCP_LEASE_TIME"
printf '  lease file: %s\n' "$DNSMASQ_LEASE_FILE"
if dnsmasq_dhcp_running; then
  printf '  dnsmasq DHCP process: running\n'
else
  printf '  dnsmasq DHCP process: stopped\n'
fi
printf '  client IPv4 addresses:\n'
if namespace_exists "$CLIENT_NAMESPACE"; then
  ip -n "$CLIENT_NAMESPACE" -brief -4 address show dev "$CLIENT_INTERFACE" | sed 's/^/    /'
  printf '  client default route:\n'
  ip -n "$CLIENT_NAMESPACE" route show default | sed 's/^/    /'
else
  printf '    client namespace absent\n'
fi
printf '  current lease entries:\n'
if [ -s "$DNSMASQ_LEASE_FILE" ]; then
  sed 's/^/    /' "$DNSMASQ_LEASE_FILE"
else
  printf '    none\n'
fi
if dnsmasq_dhcp_running && client_dhcp_address >/dev/null && client_default_route_exists; then
  printf '  R6 DHCP: enabled\n'
else
  printf '  R6 DHCP: disabled or incomplete\n'
fi

printf '\n[R7 DNS state]\n'
printf '  required LAN listener: %s:53 on %s (UDP/TCP)\n' "$ROUTER_LAN" "$ROUTER_LAN_INTERFACE"
printf '  permitted additional listeners: router loopback and %s IPv6 link-local\n' "$ROUTER_LAN_INTERFACE"
printf '  isolated upstream resolver: %s:53 in %s\n' "$DNS_UPSTREAM" "$UPSTREAM_NAMESPACE"
printf '  cache size: %s entries\n' "$DNS_CACHE_SIZE"
printf '  query log: %s\n' "$DNS_LOG_FILE"
if dns_r7_enabled; then
  printf '  combined router DHCP/DNS process: running\n'
  printf '  isolated upstream DNS process: running\n'
  if command -v ss >/dev/null 2>&1; then
    printf '  router DNS listeners:\n'
    ip netns exec "$ROUTER_NAMESPACE" ss -lntuH | awk '$5 ~ /:53$/ {print "    " $0}'
  fi
  printf '  recent DNS log entries:\n'
  if [ -s "$DNS_LOG_FILE" ]; then
    tail -n 5 "$DNS_LOG_FILE" | sed 's/^/    /'
  else
    printf '    none\n'
  fi
  printf '  R7 DNS: enabled\n'
else
  printf '  R7 DNS: disabled or incomplete\n'
fi

printf '\n[R8 IPFIX state]\n'
printf '  exporter: pmacctd/nfprobe\n'
printf '  capture: IPv4 on %s in %s (pre-NAT LAN vantage point)\n' \
  "$IPFIX_CAPTURE_INTERFACE" "$ROUTER_NAMESPACE"
printf '  collector: udp://%s:%s in %s\n' \
  "$IPFIX_COLLECTOR_HOST" "$IPFIX_COLLECTOR_PORT" "$UPSTREAM_NAMESPACE"
printf '  protocol: IPFIX v10, Observation Domain ID %s\n' "$IPFIX_OBSERVATION_DOMAIN_ID"
printf '  runtime directory: %s\n' "$IPFIX_RUNTIME_DIR"
printf '  configuration: %s\n' "$IPFIX_CONFIG_FILE"
printf '  exporter log: %s\n' "$IPFIX_LOG_FILE"
if [ -s "$IPFIX_COLLECTOR_RESULT" ]; then
  validated_datagrams="$(sed -n 's/^[[:space:]]*"datagrams": \([0-9][0-9]*\),*$/\1/p' "$IPFIX_COLLECTOR_RESULT" | head -n 1)"
  printf '  last test collector datagrams: %s\n' "${validated_datagrams:-unknown}"
else
  printf '  last test collector datagrams: not yet observed\n'
fi
if pmacctd_running; then
  printf '  project pmacctd process: running\n'
  printf '  R8 IPFIX: enabled\n'
else
  printf '  project pmacctd process: stopped\n'
  printf '  R8 IPFIX: disabled or incomplete\n'
fi
