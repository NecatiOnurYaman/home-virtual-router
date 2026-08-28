# R13 physical router deployment

R13 implements conservative static-IPv4 physical deployment. It does not claim R14 hardware validation. Physical mode runs forwarding, project nftables tables, dnsmasq, pmacct, and metrics export in the Linux host network namespace; lab mode remains inside `hvr-router`.

## Configuration and authorization

`DEPLOYMENT_MODE` selects `lab` or `physical`. `TELEMETRY_MODE` still selects telemetry behavior. R13 physical mode supports `TELEMETRY_MODE=lab` with explicit collector/export destinations; the R9 namespace veth and dedicated physical telemetry deployment are deferred.

Install a complete local example without overwriting an existing file:

```sh
sudo install -d -o root -g root -m 0750 /etc/home-virtual-router
sudo test ! -e /etc/home-virtual-router/router.env
sudo install -o root -g root -m 0640 config/physical.example.env /etc/home-virtual-router/router.env
sudo editor /etc/home-virtual-router/router.env
```

Set exact WAN/LAN kernel names, static WAN address/prefix/gateway, LAN values, DNS upstream, IPFIX collector, and metrics receiver. No interface is guessed. WAN and LAN must differ; loopback, missing interfaces, collisions, unsupported modes, and conflicting addresses/routes fail closed. Replace all documentation addresses before hardware use.

Physical mutation also requires a fixed marker which the software never creates:

```sh
sudo install -o root -g root -m 0640 /dev/null /etc/home-virtual-router/allow-physical-deployment
sudo make physical-check
```

Both files must be root-owned and not group/world writable. Environment variables cannot redirect either path.

## Management and network-manager safety

Prefer a local appliance console for first deployment. A separate management NIC is recommended, but it must use specific management routes rather than a competing default route because the static WAN owns the router default path. Never first deploy over SSH through WAN or LAN unless disconnect is expected.

Preflight identifies the current default-route interface. If it equals WAN or LAN, `PHYSICAL_MANAGEMENT_INTERFACE_ACK` must equal that exact name; default `none` rejects takeover. NetworkManager and systemd-networkd are queried per configured NIC, and managed NICs are rejected. R13 never stops/disables a manager, rewrites Netplan, or generates manager configuration. Prepare dedicated NICs as unmanaged with normal host administration.

`sudo make physical-check` is read-only. It reports authorization, interface/address/link state, static addresses, gateway, telemetry setting, current default interface, and forwarding.

## Ownership and lifecycle

Physical topology accepts no global address or the exact desired address; anything else conflicts. It brings WAN/LAN up and adds only missing exact addresses/default route. Markers record whether HVR owns each address, link transition, and route, so pre-existing exact state is preserved.

Routing snapshots `net.ipv4.ip_forward`. Prior `1` remains `1`; an HVR-owned `0` to `1` transition restores `0`. NAT remains only `table ip hvr-nat`, with LAN-source masquerade on configured WAN. Firewall remains only `table inet hvr-filter`: default-drop forwarding, invalid drop, established/related accept, LAN-to-WAN new accept, and unsolicited WAN-to-LAN drop. INPUT/OUTPUT are untouched.

Physical DHCP runs only project dnsmasq bound to exact LAN; there is no physical dhclient. DNS reuses that process with cache/native logging and explicit upstream, then validates LAN UDP/TCP listeners and rejects WAN/wildcard listeners. `/etc/resolv.conf` is unchanged.

IPFIX runs pmacctd/nfprobe on the host and captures IPv4 on physical LAN before NAT, preserving v10 and destination configuration. R10 reads host `/proc` and `/sys/class/net` using unchanged semantic `lan`/`wan` schema. R11 runs on the host and preserves its HTTP POST protocol. R13 opens no telemetry firewall holes.

The R12 start/stop/restart/status/check order and lock remain. Versioned state records deployment mode; `config.snapshot` and `physical/interface-map.env` bind the active runtime to exact NICs. Config changes while active are inconsistent and never migrate interfaces. Physical stage failures perform exact local rollback, followed by normal R12 reverse rollback. Failed cleanup remains visible rather than being treated as success.

Teardown order is metrics, IPFIX, DNS, DHCP, firewall, NAT, forwarding restoration, then owned route/address/link changes. Unknown nftables/process/PID/ownership state blocks destructive cleanup.

## Simulation, first deployment, and recovery

The Linux-only simulation requires root and `unshare`. It generates an ephemeral config under a private temporary directory and uses private mount/network/PID namespaces with test-only veths. It neither reads nor creates `/etc/home-virtual-router` or the production authorization marker. The internal config selector fails unless both the mount and network namespace differ from the invoking host:

```sh
sudo make physical-sim-test
```

It proves cold start, repeated start, health, repeated stop, and restoration without real NICs. It is not R14.

For first hardware work, keep systemd disabled, use a local console, prepare dedicated unmanaged NICs, install/edit config, create the marker, then run:

```sh
sudo make physical-check
sudo make runtime-status
sudo make runtime-start
sudo make runtime-status
sudo make runtime-check
```

On failure inspect `/run/home-virtual-router/runtime/startup.log`, `last-error`, state/config snapshot, and `/run/home-virtual-router/physical/`. Restore the original configuration before `runtime-stop`; never delete ownership files or nftables tables blindly. The R12 unit can be rendered and verified but is never installed/enabled automatically.

R14 must validate real WAN/client DHCP/DNS/NAT/firewall/IPFIX/metrics, reboot, cables, NIC recovery, and optional HNOP integration. R13 excludes WAN DHCP, PPPoE, ISP VLANs, IPv6, Wi-Fi AP, bridging, VLAN switching, multi-WAN/failover, QoS, port forwarding, UPnP/NAT-PMP/PCP, VPN, TLS/auth, SNMP, manager reconfiguration, automatic NIC discovery, and appliance images.
