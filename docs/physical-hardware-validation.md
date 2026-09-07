# R14 virtual-router deployment validation

R14 validates the accepted physical runtime on an Ubuntu router host with two explicitly configured, pre-existing Ethernet deployment interfaces: a static or ordinary IPv4-DHCP WAN connected to an upstream CPE/network and a LAN connected to an external downstream client. `DEPLOYMENT_MODE=physical` is the legacy compatibility name for this host-interface mode; it does not require bare-metal NICs. UTM/QEMU VirtIO, other VM Ethernet interfaces, and conventional PCI/USB Ethernet are valid when they satisfy the same Linux interface and ownership checks. R14 never guesses an interface.

R14 has two levels. Core acceptance requires deployment-interface preflight, start, external-client DHCP/DNS/routing, observed NAT, controlled unsolicited-WAN blocking, decoded IPFIX, metrics movement, repeated start, runtime health, stop, restoration, and residue checks. Extended acceptance separately covers optional HNOP delivery, post-reboot inspection, link loss, and safe configuration drift. Persistent background operation belongs to R15. `NOT RUN` is not `PASS`.

## R14 quick-start checklist

1. **Preflight:** confirm the working tree is clean and at the expected commit; prepare the root-owned `/etc/home-virtual-router/router.env` and authorization marker; set `DEPLOYMENT_MODE=physical`; verify the explicit WAN/LAN names; make both dedicated interfaces deliberately unmanaged; ensure neither has conflicting global IPv4/default-route state; and confirm there is no stale R14 checkpoint unless intentionally resuming a failed stop. Run `sudo make physical-hardware-check`.
2. **Start:** from a local console, run `sudo make physical-hardware-test-start`.
3. **Client proof:** pause for the external LAN client to obtain its HVR DHCP lease, default route and DNS server; prove DNS through HVR and external reachability.
4. **NAT/firewall proof:** run the documented `physical-hardware-test-observe-nat` and `physical-hardware-test-observe-firewall` targets with explicit endpoints. Add a narrow controlled-upstream route only when the firewall proof requires it, and remove that temporary host-owned route afterward.
5. **IPFIX proof:** start the external collector first, wait for receiver readiness, run `sudo make physical-hardware-test-refresh-ipfix`, signal `--traffic-start`, and generate fresh client traffic. Validate the resulting JSON and copy it to the router when collection ran externally.
6. **Verify:** run `sudo make physical-hardware-test-verify` with the documented client MAC, client IP, target IP, and router-local result path. Do not stop until verification passes.
7. **Stop:** run `sudo make physical-hardware-test-stop`. If it reports an interrupted `stopping` state, rerun the same target rather than deleting ownership evidence.
8. **Confirm restoration:** verify original forwarding and WAN/LAN link state, pre-test address/default-route state, and absence of HVR-owned processes, addresses, routes, nftables objects, WAN-DHCP state, and the restoration checkpoint.

R14 proves a manual, bounded real deployment and its safe restoration. R15—not R14—owns persistent background router operation, boot/service lifecycle, and automatic startup/restart. R14 does not install or enable systemd services.

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

Pause here. Connect the external downstream client, renew DHCP, and record its leased IPv4 address and MAC. Confirm its prefix, default gateway, and DNS server; query HVR directly for the deterministic and upstream DNS names; then generate ICMP toward a controlled upstream IPv4 target.

For IPFIX, start the decoder on the collector first and wait for its ready marker. A late collector does not have pmacct/nfprobe's earlier templates, and the supported pmacct configuration used by HVR has no reliable bounded template re-export interval. After the receiver is ready, run this on the router to restart only the physical IPFIX stage and force fresh templates:

```sh
sudo make physical-hardware-test-refresh-ipfix
```

This operation does not restart or alter DHCP, DNS, NAT, firewall, metrics, topology, routing, the WAN DHCP client, or the R14 checkpoint. After it succeeds, signal the receiver's `--traffic-start` marker and generate the fresh client traffic. Wait for the decoder to finish and validate its JSON before continuing.

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

Do not continue unless the probe was observed on WAN and absent on LAN. With the real decoder JSON now present as a regular readable file local to the Ubuntu router, verify all accumulated evidence:

```sh
sudo make physical-hardware-test-verify \
  R14_CLIENT_MAC="$R14_CLIENT_MAC" \
  R14_CLIENT_IP="$R14_CLIENT_IP" \
  R14_UPSTREAM_TARGET="$R14_UPSTREAM_TARGET" \
  R14_IPFIX_RESULT="$R14_IPFIX_RESULT"
```

An external collector path is not shared with the router. For example, `/tmp/hvr-r14-ipfix/result.json` on macOS is not visible at the same path inside the Ubuntu VM; copy the completed JSON to the router and set `R14_IPFIX_RESULT` to that router-local path. Missing, malformed, or structurally incomplete evidence is rejected before any verification checks or live probes begin.

Only after verification passes, stop the runtime and verify restoration:

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

IPFIX must use the configured real collector. Start the existing R8 decoder with expected client source, destination, and protocol. Wait for its ready marker, run `sudo make physical-hardware-test-refresh-ipfix` on the router so the late collector receives templates, signal `--traffic-start`, and only then generate the fresh client flow. Wait for the result and validate the JSON. This is not a synthetic sender: pmacct/nfprobe must export the real LAN flow.

On macOS with UTM, one tested arrangement could see UDP/4739 in `tcpdump` but did not deliver it to a normal userspace socket bound specifically to the bridge address `192.168.64.1`; binding the collector to `0.0.0.0:4739` worked. Treat wildcard binding as a portability recommendation for this setup, not a universal networking rule, and apply an appropriate host firewall policy. If the collector is external, copy the completed JSON to the Ubuntu router. The verifier requires a router-local path; a macOS `/tmp` path is not magically visible in the VM. Then verify all router-side evidence:

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

This uses `runtime-stop`, then requires forwarding, NetworkManager management state, default routes, configured address presence, and WAN/LAN links to match the checkpoint; HVR nftables and all runtime/physical/IPFIX/metrics ownership state must be absent. It does not delete `/etc/home-virtual-router` configuration. If teardown is interrupted, rerun `sudo make physical-hardware-test-stop`; either a recorded `stopping` runtime resumes from its remaining owned stages, or an absent runtime plus a valid R14 checkpoint continues the remaining host-restoration checks. The R14 checkpoint and default-route snapshot are retained until complete restoration and final result recording succeed.

Metrics-export runtime health currently proves exact process identity and configuration, not successful delivery of every HTTP sample. Transient and repeated delivery failures remain logged in `/run/home-virtual-router/metrics-export/exporter.log` without stopping routing. Adding bounded success/failure health state would change the R11/R12 telemetry contract and is intentionally deferred to a separate focused change.

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

### Runtime stuck in `stopping`

`Recorded status: stopping` means a teardown was interrupted or failed after some HVR-owned stages were already removed. A fully absent general runtime with a still-valid R14 checkpoint is also recoverable: it means stage teardown finished but host restoration/result recording did not. The restoration checkpoint is deliberately retained so current code can verify interface name, ifindex, MAC, NetworkManager baseline, addresses, routes, links, and forwarding before continuing safely. Do not delete `checkpoint.env`, remove HVR addresses/routes manually, or discard runtime ownership files before attempting supported recovery. Rerun:

```sh
sudo make physical-hardware-test-stop
```

The resumed stop proceeds only from verified HVR-owned state. If NetworkManager has reclaimed an interface that the checkpoint records as unmanaged, R14 sets only that exact interface back to `managed no`. Because becoming unmanaged does not guarantee that an existing IPv4 address or route disappears, R14 captures attributable objects first, waits boundedly, and removes only the unchanged exact objects required to match the checkpoint. It never flushes an interface, marks an interface managed, changes unrelated profiles, or disables NetworkManager globally. If recovery still refuses, capture the following diagnostics before changing host state:

```sh
sudo make runtime-status
ip -o -4 address
ip -o -4 route
sudo nft list tables
ps -ef | grep -E '[d]hclient|[d]nsmasq|[p]macctd|router-metrics'
sudo ls -la /var/lib/home-virtual-router/r14
sudo find /run/home-virtual-router/physical/wan-dhcp -maxdepth 1 -printf '%f %y %u %g %m\n'
```

Docker-owned nftables tables are legitimate host state. Only HVR-owned tables and rules must disappear during HVR restoration; never flush the host ruleset to make a residue check pass.

The WAN-DHCP teardown fixed in `397bd12` explains one prior partial-stop case: stopping dhclient invokes HVR's hook, which can append `dhclient-hook.log` and briefly create an atomic `state.env.*` file. Older cleanup attempted `rmdir` before accounting for those shutdown artifacts. Current cleanup is allowlisted, directory/file-ownership checked, race-aware, and resumable; unexpected entries are reported by exact path instead of being deleted broadly.

### Offline canonical commit transfer with `git bundle`

The Ubuntu router can have working IP connectivity while DNS resolution for `github.com` is unavailable. If the Mac repository's checked-out `HEAD` is the exact canonical commit to transfer, bundle that commit and all history reachable from it without rewriting either repository.

On macOS:

```sh
cd /path/to/home-virtual-router
git status --short
git rev-parse HEAD
git bundle create /tmp/home-virtual-router.bundle HEAD
git bundle verify /tmp/home-virtual-router.bundle
scp /tmp/home-virtual-router.bundle user@ROUTER_IP:/tmp/
```

On Ubuntu, first require a clean working tree, verify the bundle, fetch its advertised `HEAD`, and fast-forward only:

```sh
cd ~/home-virtual-router
git status --short
git bundle verify /tmp/home-virtual-router.bundle
git fetch /tmp/home-virtual-router.bundle HEAD
git merge --ff-only FETCH_HEAD
git rev-parse HEAD
```

`git bundle create ... HEAD` is intentional: it advertises the exact checked-out commit and records its complete reachable history. Check both `git rev-parse HEAD` outputs against the expected canonical commit. Do not use a destructive reset as the normal transfer workflow; `--ff-only` preserves local history and refuses divergence. Because this fetch reads a local bundle rather than GitHub, `origin/main` may remain stale even though the Ubuntu working tree is at the newer commit. The remote-tracking ref updates only after a successful fetch from `origin` (or an explicit, deliberate ref update).

### Troubleshooting matrix

| Symptom | Likely cause | Operator action |
|---|---|---|
| `Could not resolve host: github.com` | Router DNS/upstream resolution issue | Restore router DNS, or transfer the exact canonical history from the Mac using the bundle workflow above. |
| IPFIX `data_sets > 0` but `templates = 0` | Collector joined after nfprobe emitted its templates | Start the receiver first, wait for readiness, then run `sudo make physical-hardware-test-refresh-ipfix`. |
| IPFIX result is missing on the router | Collector ran externally or its copy/SCP did not complete | Finish copying the JSON to the router and validate that local file before `physical-hardware-test-verify`. |
| Runtime status is `stopping` | Teardown was interrupted after removing some stages | Rerun `sudo make physical-hardware-test-stop`; do not delete the restoration checkpoint. |
| Docker nftables tables remain after HVR stop | Normal Docker-owned host state | Require only HVR-owned nftables objects to disappear. Do not flush Docker or the host ruleset. |
| Metrics exporter logs timeouts while its process is healthy | Metrics delivery endpoint is unavailable or unreachable | Inspect `/run/home-virtual-router/metrics-export/exporter.log`; current health tracks process/config identity, not delivery success. |

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
