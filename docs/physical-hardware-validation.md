# R14 virtual-router deployment validation

R14 validates the accepted physical runtime on an Ubuntu router host with two explicitly configured, pre-existing Ethernet deployment interfaces: a static or ordinary IPv4-DHCP WAN connected to an upstream CPE/network and a LAN connected to an external downstream client. `DEPLOYMENT_MODE=physical` is the legacy compatibility name for this host-interface mode; it does not require bare-metal NICs. UTM/QEMU VirtIO, other VM Ethernet interfaces, and conventional PCI/USB Ethernet are valid when they satisfy the same Linux interface and ownership checks. R14 never guesses an interface.

R14 has two levels. Core acceptance requires deployment-interface preflight, start, external-client DHCP/DNS/routing, observed NAT, controlled unsolicited-WAN blocking, decoded IPFIX, metrics movement, repeated start, runtime health, stop, restoration, and residue checks. Extended acceptance separately covers optional HNOP delivery, post-reboot inspection, link loss, and safe configuration drift. Persistent background operation belongs to R15. `NOT RUN` is not `PASS`.

## Supported UTM topology

The intended deployment is an Ubuntu UTM guest acting as the router. One UTM-supplied Ethernet interface provides WAN/upstream connectivity and a second UTM-supplied Ethernet interface connects to an isolated, host-only, shared, or custom downstream segment appropriate to the operator's UTM version. HVR runs in the Ubuntu host network context: DHCP/DNS bind to LAN, NAT and the stateful firewall forward between LAN and WAN, IPFIX captures the LAN client pre-NAT, and metrics retain semantic `lan` and `wan` roles.

The interfaces may use `virtio_net`, emulated Ethernet, or another normal Linux Ethernet driver. R14 does not require a PCI or USB device and has no driver allowlist. It does require two distinct explicit interfaces with stable name/ifindex/MAC identity. It rejects loopback, HVR's R2 lab interface names, ordinary veth deployment targets, and Linux bridges such as Docker bridges. The R13 simulation retains its explicit private veth exception.

An external downstream client is any system outside HVR's internal R2 namespace topology that sends traffic through the configured deployment LAN interface. It may be another VM, another UTM guest, a host-connected virtual-network participant, or a physical machine; it does not need to be physically wired.

## Ubuntu R14 command sequence

Run these regression checks in the Ubuntu repository before preparing or touching deployment interfaces:

```sh
cd ~/home-virtual-router
git pull
make check
make test
sudo make physical-sim-test
sudo make runtime-test
```

These must pass before an R14 deployment run. They prove the accepted R13 simulation and R12 lifecycle remain green; they do not constitute two-vNIC virtual-router acceptance.

Next prepare the authoritative machine-local configuration and authorization files:

```sh
sudo install -d -o root -g root -m 0750 /etc/home-virtual-router
sudo test ! -e /etc/home-virtual-router/router.env
sudo install -o root -g root -m 0640 config/physical.example.env /etc/home-virtual-router/router.env
sudo editor /etc/home-virtual-router/router.env
sudo install -o root -g root -m 0640 /dev/null /etc/home-virtual-router/allow-physical-deployment
```

`/etc/home-virtual-router/router.env` must explicitly contain machine-appropriate placeholder replacements for at least:

- `DEPLOYMENT_MODE=physical`
- `PHYSICAL_WAN_INTERFACE` and `PHYSICAL_LAN_INTERFACE`
- `PHYSICAL_WAN_MODE=static|dhcp` (omission means `static`)
- in static mode only: `PHYSICAL_WAN_ADDRESS`, `PHYSICAL_WAN_PREFIX_LENGTH`, and `PHYSICAL_WAN_GATEWAY`; omit all three in DHCP mode
- `LAN_SUBNET` and `ROUTER_LAN`
- `DHCP_RANGE_START`, `DHCP_RANGE_END`, `DHCP_DNS_SERVER`, and `DHCP_LEASE_TIME`
- `DNS_UPSTREAM` and the existing deterministic DNS test values
- `IPFIX_CAPTURE_INTERFACE`, `IPFIX_COLLECTOR_HOST`, and `IPFIX_COLLECTOR_PORT`
- `METRICS_EXPORT_HOST`, `METRICS_EXPORT_PORT`, `METRICS_EXPORT_PATH`, and `ROUTER_ID`
- `PHYSICAL_MANAGEMENT_INTERFACE_ACK` when the configured WAN or LAN currently carries the management/default route

Do not copy real values into Git. The authorization marker is `/etc/home-virtual-router/allow-physical-deployment`; neither path is configurable.

Run the read-only deployment-interface check:

```sh
sudo make physical-hardware-check
```

This command must not mutate addresses, routes, links, forwarding, nftables, or processes. Stop if it reports an interface identity, network-manager, authorization, configuration, management-route, dependency, or runtime-state failure.

Start core acceptance from a local console and a residue-free runtime:

```sh
sudo make physical-hardware-test-start
```

Pause here. Connect the external downstream client, renew DHCP, and record its leased IPv4 address and MAC. Confirm its prefix, default gateway, and DNS server; query HVR directly for the deterministic and upstream DNS names; then generate ICMP toward a controlled upstream IPv4 target. Start the IPFIX decoder before generating the fresh marked ICMP flow and retain its JSON result on the HVR host.

Set local shell placeholders without committing them:

```sh
R14_CLIENT_MAC='REPLACE_WITH_CLIENT_MAC'
R14_CLIENT_IP='REPLACE_WITH_LEASED_CLIENT_IPV4'
R14_UPSTREAM_TARGET='REPLACE_WITH_CONTROLLED_TARGET_IPV4'
R14_UPSTREAM_PEER='REPLACE_WITH_CONTROLLED_PEER_IPV4'
R14_IPFIX_RESULT='/absolute/path/to/real-ipfix-result.json'
```

Run the bounded NAT observation, and while it waits generate the same ICMP flow from the LAN client:

```sh
sudo make physical-hardware-test-observe-nat \
  R14_CLIENT_IP="$R14_CLIENT_IP" \
  R14_UPSTREAM_TARGET="$R14_UPSTREAM_TARGET"
```

Do not continue until it observes the current effective HVR WAN source. With DHCP this is the HVR-owned lease shown by `sudo make runtime-status`, not the ISP/public address after the upstream CPE performs its second NAT. Next configure the controlled upstream peer's narrow route to the HVR LAN through the current HVR WAN address. Run the firewall observation and, while it waits, send the documented ICMP probe from that peer toward the client:

```sh
sudo make physical-hardware-test-observe-firewall \
  R14_CLIENT_IP="$R14_CLIENT_IP" \
  R14_UPSTREAM_PEER="$R14_UPSTREAM_PEER"
```

Do not continue unless the probe was observed on WAN and absent on LAN. With the real decoder JSON now present, verify all accumulated evidence:

```sh
sudo make physical-hardware-test-verify \
  R14_CLIENT_MAC="$R14_CLIENT_MAC" \
  R14_CLIENT_IP="$R14_CLIENT_IP" \
  R14_UPSTREAM_TARGET="$R14_UPSTREAM_TARGET" \
  R14_IPFIX_RESULT="$R14_IPFIX_RESULT"
```

Only after verification, stop the runtime and verify restoration:

```sh
sudo make physical-hardware-test-stop
```

Run the residue commands in the recovery section below. If optional reboot validation is desired, perform the manual reboot while the R14 checkpoint still exists—after `physical-hardware-test-start` and before `physical-hardware-test-stop`—then run:

```sh
sudo make physical-hardware-test-post-reboot
```

The project never invokes `reboot` or changes systemd persistence. After the post-reboot check, repeat the applicable real-client checks and finish with `physical-hardware-test-stop`.

## Preparation and safety

Use a local console for the first run. SSH through either configured interface can be lost. Prepare a complete root-owned `/etc/home-virtual-router/router.env` from `config/physical.example.env`; replace every documentation value and set exact `PHYSICAL_WAN_INTERFACE`, `PHYSICAL_LAN_INTERFACE`, WAN mode, LAN/DHCP, DNS, IPFIX collector, and metrics receiver values. Static mode requires its WAN address/prefix/gateway. DHCP mode omits those three keys and requires an ordinary upstream IPv4 DHCP server. Keep the two deployment interfaces unmanaged using the distro's normal per-interface configuration. Do not disable NetworkManager or systemd-networkd globally.

Create the existing deliberate authorization marker and run the read-only checks:

```sh
sudo install -o root -g root -m 0640 /dev/null /etc/home-virtual-router/allow-physical-deployment
sudo make physical-check
sudo make physical-hardware-check
```

The R14 check refuses lab mode, the simulation override, invalid authorization, manager conflicts, unsafe management/default-route use, unsupported telemetry, stale/inconsistent runtime state, missing dependencies, an active generic Ubuntu `dnsmasq.service`, or any other failed R13 preflight. HVR's dnsmasq explicitly excludes loopback and does not need to own `127.0.0.1:53` or `[::1]:53`; `systemd-resolved` may remain active on its normal stub addresses. A separate host `dnsmasq.service` can still compete for the dedicated physical LAN DHCP/DNS sockets, so preflight tells the administrator to stop and disable it deliberately instead of changing that service automatically. The check prints exact identities and does not mutate networking. The start phase records a bounded pre-start inventory under `/run/home-virtual-router/r14/` with timestamp, host/kernel, NIC name/ifindex/MAC/driver/link/carrier/MTU, addresses/routes, forwarding, and manager state.

## Core acceptance

Start from the local console:

```sh
sudo make physical-hardware-test-start
sudo make runtime-status
sudo make runtime-check
```

The start phase snapshots HVR-owned baseline state, starts through the R12/R13 lifecycle, records metrics, performs a second start, and requires an identical route/address/nftables/process signature.

Connect an external downstream client to the deployment LAN and renew DHCP. On Linux use `sudo dhclient -r <client-iface>` then `sudo dhclient -v <client-iface>`; on macOS use `sudo ipconfig set <client-iface> DHCP`. Inspect the client and confirm its address is inside the configured pool, its prefix is the LAN prefix, and both default gateway and DNS server are HVR's LAN address. Do not record a client MAC in Git.

Query HVR directly and generate a recognizable flow toward an operator-controlled upstream IPv4 target:

```sh
dig @<HVR_LAN_IP> example.test A
dig @<HVR_LAN_IP> example.com A
ping <CONTROLLED_UPSTREAM_TARGET>
```

macOS can use `dig` identically. Windows can use `ipconfig /renew`, `ipconfig /all`, `nslookup example.test <HVR_LAN_IP>`, and `ping <target>`.

Run the bounded WAN capture while generating the ping again from the client:

```sh
sudo make physical-hardware-test-observe-nat \
  R14_CLIENT_IP=<LEASED_CLIENT_IP> R14_UPSTREAM_TARGET=<CONTROLLED_TARGET_IP>
```

This accepts only a WAN packet whose source is HVR's current validated effective WAN address and destination is the chosen target; client success alone is not NAT proof. Double NAT at the upstream CPE is expected, and R14 neither observes nor requires the eventual ISP/public source.

For firewall proof, configure a route on a controlled upstream peer toward the HVR LAN subnet via HVR's WAN address. Start the bounded dual-interface observation, then send ICMP from that peer to the client:

```sh
sudo make physical-hardware-test-observe-firewall \
  R14_CLIENT_IP=<LEASED_CLIENT_IP> R14_UPSTREAM_PEER=<CONTROLLED_PEER_IP>
```

The probe must be observed on WAN and absent on LAN. Random Internet scans are not acceptable.

IPFIX must use the configured real collector. Start the existing R8 decoder there before generating the fresh client flow, with expected client source, destination, and protocol, and retain its JSON result locally on the HVR host. This is not a synthetic sender: pmacct/nfprobe must export the real LAN flow. Then verify all router-side evidence:

```sh
sudo make physical-hardware-test-verify \
  R14_CLIENT_MAC=<CLIENT_MAC> \
  R14_CLIENT_IP=<LEASED_CLIENT_IP> \
  R14_UPSTREAM_TARGET=<CONTROLLED_TARGET_IP> \
  R14_IPFIX_RESULT=<ABSOLUTE_DECODER_RESULT_JSON>
```

Verification correlates the exact dnsmasq lease, native DNS query log, NAT capture, firewall proof, decoded pre-NAT IPFIX record, LAN/WAN metric roles/operstate, positive counter movement, and runtime health. Reports under `/run/home-virtual-router/r14/` use only `PASS`, `FAIL`, and `NOT RUN`.

Stop and verify restoration:

```sh
sudo make physical-hardware-test-stop
```

This uses `runtime-stop`, then requires forwarding and default routes to match the checkpoint, configured address presence to match baseline, HVR nftables to be absent, and all runtime/physical/IPFIX/metrics ownership state to be absent. It does not delete `/etc/home-virtual-router` configuration.

## Extended acceptance

HNOP is optional. With the existing R9/R11 contract, verify a fresh `POST /v1/router-metrics` has the configured `router_id`, timestamp, and real LAN/WAN roles. Basic router acceptance does not require HNOP.

R14 never installs/enables systemd or reboots. Its optional command only inspects state after an operator-initiated reboot. The start phase places its non-secret interface-identity checkpoint at `/var/lib/home-virtual-router/r14/checkpoint.env`; afterward run `sudo make physical-hardware-test-post-reboot`. Revalidate the external client afterward. R15—not R14—will own systemd installation, boot ordering, automatic startup, restart policy, long-running background operation, and shutdown acceptance. The normal stop phase removes the checkpoint.

For link loss, unplug one non-management-critical cable manually, run `sudo make runtime-check`, record whether carrier degradation is reported and whether dnsmasq/IPFIX/exporter remain alive, reconnect, then run `runtime-check` again. R14 does not promise or add self-healing. Never programmatically lower a management-critical link.

For safe drift validation, back up `/etc/home-virtual-router/router.env` with ownership/mode preserved, change only a non-management configured interface name or gateway, confirm `runtime-start`/`runtime-check` fail closed, and restore the file byte-for-byte before `runtime-stop`. Hardware replacement or same-name MAC/ifindex drift is manual-only and must fail the checkpoint/ownership identity checks.

## Recovery and diagnostics

Normal recovery is project-scoped:

```sh
sudo make runtime-status
sudo make runtime-check
sudo make runtime-stop
sudo make physical-check
```

Do not flush nftables, flush NIC addresses, or stop a network manager globally. On failure inspect the bounded `/run/home-virtual-router/r14/report.txt`, runtime logs, and physical ownership markers. It captures HVR tables, addresses/routes/rules, bounded daemon log tails, interface identity, and relevant sockets—not credentials, arbitrary files, full system logs, or complete packet captures.

After stop, residue can be checked explicitly:

```sh
test ! -e /run/home-virtual-router/runtime/state.env
test ! -e /run/home-virtual-router/physical/interface-map.env
test ! -e /run/home-virtual-router/physical/wan-address-owned
test ! -e /run/home-virtual-router/physical/lan-address-owned
test ! -e /run/home-virtual-router/physical/wan-link-owned
test ! -e /run/home-virtual-router/physical/lan-link-owned
test ! -e /run/home-virtual-router/physical/default-route-owned
test ! -e /run/home-virtual-router/physical/forwarding-original
test ! -e /run/home-virtual-router/dhcp/dnsmasq.pid
test ! -e /run/home-virtual-router/dns/enabled
test ! -e /run/home-virtual-router/ipfix/pmacctd.pid
test ! -e /run/home-virtual-router/ipfix/pmacctd.starttime
test ! -e /run/home-virtual-router/ipfix/nfprobe.pid
test ! -e /run/home-virtual-router/ipfix/nfprobe.starttime
test ! -e /run/home-virtual-router/metrics-export/exporter.pid
test ! -e /run/home-virtual-router/metrics-export/exporter.starttime
test ! -e /var/lib/home-virtual-router/r14/checkpoint.env
test ! -e /var/lib/home-virtual-router/r14/default-routes.before
! sudo nft list table ip hvr-nat
! sudo nft list table inet hvr-filter
```

R13 simulation and CI can validate harness safety but cannot pass R14. Only an Ubuntu deployment with two pre-existing host-visible interfaces, an external downstream client outside R2, and all required core proofs can establish R14 deployment acceptance. A current one-vNIC UTM guest must stop here: add a second UTM network adapter, reboot the guest, inventory `ip -br link`, `ip -br addr`, `ip -4 route`, `nmcli device status 2>/dev/null || true`, and `networkctl list 2>/dev/null || true`, then configure the exact observed WAN/LAN names. Never guess the second name.
