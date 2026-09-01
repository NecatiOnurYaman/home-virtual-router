# R13 host-interface deployment

R13 implements conservative static-IPv4 host-interface deployment. The existing `DEPLOYMENT_MODE=physical`, `PHYSICAL_*`, and `physical/*` names are compatibility terminology: “physical” means HVR operates in the Linux host context against explicitly configured pre-existing interfaces. Those interfaces may be UTM/QEMU VirtIO or other VM NICs, TAP-backed guest interfaces, PCI/USB Ethernet, or other normal Linux Ethernet interfaces; bare-metal hardware is not required. Lab mode remains inside `hvr-router`.

## Configuration and authorization

`DEPLOYMENT_MODE` selects `lab` or `physical`. `TELEMETRY_MODE` still selects telemetry behavior. R13 physical mode supports `TELEMETRY_MODE=lab` with explicit collector/export destinations; the R9 namespace veth and dedicated physical telemetry deployment are deferred.

Install a complete local example without overwriting an existing file:

```sh
sudo install -d -o root -g root -m 0750 /etc/home-virtual-router
sudo test ! -e /etc/home-virtual-router/router.env
sudo install -o root -g root -m 0640 config/physical.example.env /etc/home-virtual-router/router.env
sudo editor /etc/home-virtual-router/router.env
```

Set exact WAN/LAN kernel names, static WAN address/prefix/gateway, LAN values, DNS upstream, IPFIX collector, and metrics receiver. No interface is guessed. WAN and LAN must be distinct eligible Ethernet deployment interfaces; loopback, HVR lab interfaces, veths outside the R13 simulation, Linux bridges, missing interfaces, collisions, unsupported modes, and conflicting addresses/routes fail closed. Driver or PCI/USB backing is not allowlisted. Replace all documentation addresses before deployment use.

Physical mutation also requires a fixed marker which the software never creates:

```sh
sudo install -o root -g root -m 0640 /dev/null /etc/home-virtual-router/allow-physical-deployment
sudo make physical-check
```

Both files must be root-owned and not group/world writable. Environment variables cannot redirect either path.

## Management and network-manager safety

Prefer a local appliance console for first deployment. A separate management NIC is recommended, but it must use specific management routes rather than a competing default route because the static WAN owns the router default path. Never first deploy over SSH through WAN or LAN unless disconnect is expected.

Preflight identifies the current default-route interface. If it equals WAN or LAN, `PHYSICAL_MANAGEMENT_INTERFACE_ACK` must equal that exact name; default `none` rejects takeover. NetworkManager and systemd-networkd are queried per configured deployment interface, and managed interfaces are rejected. R13 never stops/disables a manager, rewrites Netplan, or generates manager configuration. Prepare the explicit deployment interfaces as unmanaged with normal host administration.

`sudo make physical-check` is read-only. It reports authorization, interface/address/link state, static addresses, gateway, telemetry setting, current default interface, and forwarding.

## Ownership and lifecycle

Physical topology accepts no global address or the exact desired address; anything else conflicts. It brings WAN/LAN up and adds only missing exact addresses/default route. Markers record whether HVR owns each address, link transition, and route, so pre-existing exact state is preserved.

Routing snapshots `net.ipv4.ip_forward`. Prior `1` remains `1`; an HVR-owned `0` to `1` transition restores `0`. NAT remains only `table ip hvr-nat`, with LAN-source masquerade on configured WAN. Firewall remains only `table inet hvr-filter`: default-drop forwarding, invalid drop, established/related accept, LAN-to-WAN new accept, and unsolicited WAN-to-LAN drop. INPUT/OUTPUT are untouched.

Physical DHCP runs only project dnsmasq bound to the exact LAN, with loopback explicitly excluded; there is no physical dhclient. DNS reuses that process with cache/native logging and an explicit upstream, and HVR does not need to own `127.0.0.1:53` or `[::1]:53`. Listener validation rejects WAN/wildcard listeners. `systemd-resolved` may remain active on its normal stub addresses, and `/etc/resolv.conf` is unchanged. The generic Ubuntu `dnsmasq.service` must not run concurrently because it can compete for HVR's dedicated physical DHCP/DNS sockets. Read-only physical preflight refuses an active `dnsmasq.service` and tells the administrator to stop and disable it deliberately; HVR never stops or disables host services automatically.

IPFIX runs pmacctd/nfprobe on the host and captures IPv4 on the deployment LAN before NAT, preserving v10 and destination configuration. R10 reads host `/proc` and `/sys/class/net` using unchanged semantic `lan`/`wan` schema. R11 runs on the host and preserves its HTTP POST protocol. R13 opens no telemetry firewall holes.

The R12 start/stop/restart/status/check order and lock remain. Versioned state records deployment mode; `config.snapshot` and `physical/interface-map.env` bind the active runtime to exact NICs. Config changes while active are inconsistent and never migrate interfaces. Physical stage failures perform exact local rollback, followed by normal R12 reverse rollback. Failed cleanup remains visible rather than being treated as success.

Teardown order is metrics, IPFIX, DNS, DHCP, firewall, NAT, forwarding restoration, then owned route/address/link changes. Unknown nftables/process/PID/ownership state blocks destructive cleanup.

## Simulation, first deployment, and recovery

The Linux-only simulation requires root and `unshare`. It generates an ephemeral config under a private temporary directory and uses private mount/network/PID namespaces with test-only veths and nested client/upstream namespaces. It neither reads nor creates `/etc/home-virtual-router` or the production authorization marker. The internal config selector fails unless both the mount and network namespace differ from the invoking host:

```sh
sudo make physical-sim-test
```

It proves cold start, exact host-interface addresses/routes/forwarding/nftables state, a dynamic simulated-client lease, routed/NAT-observed ICMP, LAN-only DNS with a bounded query, LAN-side IPFIX configuration/process health, semantic LAN/WAN metric identity, metrics-exporter health, repeated start/status/check, repeated stop, and restoration inside isolated simulated interfaces. The temporary upstream DNS helper, DHCP client, namespaces, and files are allowlisted and removed on success or failure. It is not R14 deployment acceptance.

Physical runtime paths are initialized by their owning stage rather than by lab R2 side effects. The runtime orchestrator owns `/run/home-virtual-router/runtime` at `0750`; physical topology/routing owns `physical` at `0750`; physical DHCP prepares `dhcp` as root-owned `0755` before rendering dnsmasq configuration; DNS owns `dns` at `0755`; IPFIX owns `ipfix` at `0750`; and R11 owns `metrics-export`. Stage teardown removes only its known files and removes an empty directory where its existing lifecycle supports that operation.

For first host-interface deployment, keep systemd disabled, use a local console, prepare two explicit unmanaged deployment interfaces, install/edit config, create the marker, then run:

```sh
sudo make physical-check
sudo make runtime-status
sudo make runtime-start
sudo make runtime-status
sudo make runtime-check
```

On failure inspect `/run/home-virtual-router/runtime/startup.log`, `last-error`, state/config snapshot, and `/run/home-virtual-router/physical/`. Restore the original configuration before `runtime-stop`; never delete ownership files or nftables tables blindly. The R12 unit can be rendered and verified but is never installed/enabled automatically.

R14 validates an external WAN/client path using pre-existing host interfaces, including a two-vNIC Ubuntu UTM deployment. R15 owns persistent background service operation, boot ordering, automatic startup, restart policy, and shutdown behavior. R13 excludes WAN DHCP, PPPoE, ISP VLANs, IPv6, Wi-Fi AP, bridging, VLAN switching, multi-WAN/failover, QoS, port forwarding, UPnP/NAT-PMP/PCP, VPN, TLS/auth, SNMP, manager reconfiguration, automatic NIC discovery, and appliance images.
