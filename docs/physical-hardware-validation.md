# R14 physical hardware validation

R14 validates the accepted R13 runtime on a Linux host with two explicitly configured Ethernet-class NICs: a static-IPv4 WAN connected to an upstream network and a LAN connected to a real wired client. It does not support WAN DHCP, PPPoE, VLAN tagging, Wi-Fi AP mode, bridging, IPv6 routing, multi-WAN, VPN, QoS, UPnP, or port forwarding. R14 never guesses an interface.

R14 has two levels. Core acceptance requires real NIC preflight, start, real-client DHCP/DNS/routing, observed NAT, controlled unsolicited-WAN blocking, decoded IPFIX, metrics movement, repeated start, runtime health, stop, restoration, and residue checks. Extended acceptance separately covers optional HNOP delivery, systemd/reboot, link loss, and safe configuration drift. `NOT RUN` is not `PASS`.

## Preparation and safety

Use a local console for the first run. SSH through either configured NIC can be lost. Prepare a complete root-owned `/etc/home-virtual-router/router.env` from `config/physical.example.env`; replace every documentation address and set exact `PHYSICAL_WAN_INTERFACE`, `PHYSICAL_LAN_INTERFACE`, static WAN/gateway, LAN/DHCP, DNS, IPFIX collector, and metrics receiver values. Keep the two NICs unmanaged using the distro's normal per-interface configuration. Do not disable NetworkManager or systemd-networkd globally.

Create the existing deliberate authorization marker and run the read-only checks:

```sh
sudo install -o root -g root -m 0640 /dev/null /etc/home-virtual-router/allow-physical-deployment
sudo make physical-check
sudo make physical-hardware-check
```

The R14 check refuses lab mode, the simulation override, invalid authorization, manager conflicts, unsafe management/default-route use, unsupported telemetry, stale/inconsistent runtime state, missing dependencies, or failed R13 preflight. It prints exact identities and does not mutate networking. The start phase records a bounded pre-start inventory under `/run/home-virtual-router/r14/` with timestamp, host/kernel, NIC name/ifindex/MAC/driver/link/carrier/MTU, addresses/routes, forwarding, and manager state.

## Core acceptance

Start from the local console:

```sh
sudo make physical-hardware-test-start
sudo make runtime-status
sudo make runtime-check
```

The start phase snapshots HVR-owned baseline state, starts through the R12/R13 lifecycle, records metrics, performs a second start, and requires an identical route/address/nftables/process signature.

Connect a real client to LAN and renew DHCP. On Linux use `sudo dhclient -r <client-iface>` then `sudo dhclient -v <client-iface>`; on macOS use `sudo ipconfig set <client-iface> DHCP`. Inspect the client and confirm its address is inside the configured pool, its prefix is the LAN prefix, and both default gateway and DNS server are HVR's LAN address. Do not record a client MAC in Git.

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

This accepts only a WAN packet whose source is the configured HVR WAN address and destination is the chosen target; client success alone is not NAT proof.

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

R14 never installs/enables systemd or reboots. If the operator explicitly installs the unit rendered by `make systemd-show`, validate it using normal `systemctl daemon-reload`, `enable`, `start`, `status`, and later `disable`/removal commands. The start phase places its non-secret NIC-identity checkpoint at `/var/lib/home-virtual-router/r14/checkpoint.env`; afterward run `sudo make physical-hardware-test-post-reboot`. With no enabled unit it requires no runtime residue; with an enabled unit it requires `runtime-check`. Revalidate the real client afterward. The normal stop phase removes the checkpoint.

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
test ! -e /run/home-virtual-router/ipfix/pmacctd.pid
test ! -e /run/home-virtual-router/metrics-export/exporter.pid
test ! -e /run/home-virtual-router/metrics-export/exporter.starttime
! sudo nft list table ip hvr-nat
! sudo nft list table inet hvr-filter
```

R13 simulation and CI can validate harness safety but cannot pass R14. Only a supported physical Linux host, two real NICs, a real client, and all required core proofs can establish R14 hardware acceptance.
