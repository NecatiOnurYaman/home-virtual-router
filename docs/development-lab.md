# Isolated Linux development lab

The project uses the existing dedicated Ubuntu 26.04 LTS (`resolute`) virtual machine running under UTM on macOS. Ubuntu supplies the Linux kernel required by namespaces. UTM and the Ubuntu VM are not managed by this repository.

The Ubuntu VM hosts the isolated namespace lab; it is not itself part of the simulated router topology:

```text
hvr-upstream              hvr-router                    hvr-client
192.0.2.1/24              192.0.2.2/24                  10.0.0.10/24
    hvr-up <----------> hvr-wan  hvr-lan <----------> hvr-client
                                      10.0.0.1/24
```

The upstream uses RFC 5737 TEST-NET-1. R2 creates only the connected topology and explicitly leaves forwarding disabled inside `hvr-router`. R3 adds these namespace-local settings:

```text
hvr-client:   default via 10.0.0.1
hvr-router:   net.ipv4.ip_forward=1
hvr-upstream: 10.0.0.0/24 via 192.0.2.2
```

The upstream return route is necessary in R3 because replies to `10.0.0.10` must be explicitly sent back through the router WAN address. R4 removes that route and adds one project-owned nftables table inside `hvr-router`:

```text
table ip hvr-nat
└── hvr-postrouting: oifname "hvr-wan" ip saddr 10.0.0.0/24 masquerade
```

Before NAT, upstream sees source `10.0.0.10` and needs `10.0.0.0/24 via 192.0.2.2`. After NAT, upstream sees source `192.0.2.2`. Kernel connection tracking records the stateful translation and maps replies back to `10.0.0.10`; this project does not implement connection tracking itself.

This resembles the future double-NAT deployment: `10.0.0.x` → Virtual Router NAT → Superbox LAN address → Superbox NAT → Internet. R4 itself provides no Internet access. NAT is not a firewall, and R4 creates no filter chain, filtering policy, DNAT, port forwarding, DHCP, DNS, or IPFIX configuration.

R5 keeps address translation and traffic policy separate. NAT rewrites addresses; the firewall decides whether a packet may be forwarded. The project-owned `inet hvr-filter` forward chain has policy `drop` and these ordered rules:

```text
ct state invalid                         drop
ct state established,related             accept
ct state new hvr-lan -> hvr-wan
  source 10.0.0.0/24                     accept
ct state new hvr-wan -> hvr-lan          drop (counted)
everything else                          drop (chain policy)
```

Invalid packets are rejected because they cannot be associated safely with a valid connection. A LAN client may start a connection, and its reply is accepted through kernel connection tracking as established traffic. A new unsolicited WAN-originated forwarded flow hits an explicit counted drop rule, while any other unmatched traffic falls through to the default-drop policy. R5 adds no INPUT or OUTPUT chains, so router-local management hardening remains outside this stage.

R6 replaces the test client's static address with DHCP from a dedicated dnsmasq process inside `hvr-router`:

```text
hvr-client                    hvr-router / dnsmasq
    DHCPDISCOVER  ---------->
                  <---------- DHCPOFFER
    DHCPREQUEST   ---------->
                  <---------- DHCPACK

Result: 10.0.0.100–10.0.0.199/24, gateway 10.0.0.1, DNS option 10.0.0.1
```

In R6 mode dnsmasq binds only to `hvr-lan`; `port=0` disables its DNS service until R7 is enabled. DHCP traffic is to and from the router itself on UDP 67/68, so it does not traverse the R5 forward chain. The custom dhclient hook writes the advertised DNS value to `/run/home-virtual-router/dhcp/client/client-resolv.conf` instead of changing the Ubuntu VM's `/etc/resolv.conf`.

Leases are stored at `/run/home-virtual-router/dhcp/dnsmasq.leases` in dnsmasq's five-field format: `<expiry_epoch> <mac> <ip> <hostname> <client_id>`. The separate Home Network Observability Platform can consume this file later; R6 does not synchronize repositories. This dynamic workflow resembles a phone, television, or laptop joining the future home LAN.

R6 resolves the installed `dnsmasq` system user's numeric UID and primary GID from the system account database. It does not assume that the primary group is also named `dnsmasq`, and it will not create an account or group if the user is absent. Failed or interrupted enable operations stop only processes identified by project PID files and command markers, remove only the explicit project runtime files, and restore the R5 static client address and route. `make dhcp-disable` is also safe after a partial start where neither daemon successfully ran.

Ubuntu confines the packaged `/sbin/dhclient` path with AppArmor. R6 therefore installs ephemeral, root-owned mode `0755` copies of the installed client binary and project hook under the private mode `0700` directory `/run/home-virtual-router/dhcp/client/`. The client lease and PID files are separate mode `0600` files there. This avoids changing Ubuntu's AppArmor policy and avoids repository mount/traversal restrictions; the copy runs only in `hvr-client` and is removed by R6 cleanup. Dnsmasq retains its separate lease and PID files in `/run/home-virtual-router/dhcp/`. The hook writes resolver data only to the client runtime directory and never touches `/etc/resolv.conf`.

Host-interface safety snapshots compare stable interface names, Ethernet addresses, and IPv4 address/prefix pairs. Volatile `valid_lft` and `preferred_lft` countdowns are intentionally excluded, while default-route verification remains a separate exact comparison. With no R2 namespaces, `make dhcp-disable` stops only PID-validated project processes, removes the explicit R6 runtime files, and reports that namespace cleanup was unnecessary.

R7 makes the DHCP-advertised DNS server functional. The existing router dnsmasq is restarted in combined DHCP/DNS mode, still bound explicitly to `hvr-lan` and `10.0.0.1`; it does not listen on `hvr-wan`. It uses `no-resolv` and forwards only to `192.0.2.1`, where a separate test-only dnsmasq inside `hvr-upstream` returns `example.test → 192.0.2.123` and `router-test.example → 192.0.2.124`. No Ubuntu host or public resolver participates.

Dnsmasq may also open router-local `127.0.0.1:53` and `[::1]:53` sockets plus an IPv6 link-local socket for the address assigned specifically to `hvr-lan`. These are accepted as LAN/router-local binding behavior; they do not constitute general IPv6 routing or DNS support. R7 still rejects the router WAN address, `hvr-wan` link-local addresses, and IPv4/IPv6 wildcard listeners, and actively verifies from `hvr-upstream` that UDP and TCP DNS do not answer through `192.0.2.2`.

The router cache holds 150 entries. Native dnsmasq query, forwarding, reply, and cache messages are written to `/run/home-virtual-router/dns/dnsmasq.log`, which is the path intended for later consumption by the separate observability platform. R7 does not copy or synchronize that log. The R5 firewall has only a forward hook: client DNS addressed to the router uses router-local INPUT/OUTPUT, while forwarded upstream queries originate in `hvr-router`; R7 adds no firewall rules.

`make dns-disable` restarts the same router dnsmasq with the R6 `port=0` DHCP-only configuration and removes the isolated upstream resolver. The existing dnsmasq lease file, dhclient process, dynamic client address, default route, routing, NAT, and firewall remain intact.

R8 uses Ubuntu's `softflowd` package because it is a small, established packet-based flow exporter with native IPFIX v10, UDP export, interface selection, and the standard fields needed here; it avoids introducing a custom exporter or a heavier accounting suite. Enable also checks that the installed binary advertises version 10 support. The package supplies both `softflowd` and `softflowctl`. Softflowd runs only inside `hvr-router` and captures IPv4 on `hvr-lan`. This LAN-side vantage point sees a client's original dynamic `10.0.0.x` source before R4 masquerading rewrites it on `hvr-wan`:

```text
hvr-client -- original source --> [hvr-lan | softflowd] hvr-router [NAT | hvr-wan] --> hvr-upstream
                                      IPFIX v10 over UDP ---------------------------> 192.0.2.1:4739
```

The isolated test collector runs only in `hvr-upstream`. It starts before fresh client traffic is generated. The test confirms the project exporter has tracked the dynamic client, then runs `softflowctl -c /run/home-virtual-router/ipfix/softflowd.ctl expire-all` inside `hvr-router`. Forced expiry makes softflowd export immediately and deterministically; the test does not depend on a sleep long enough for natural expiry and leaves the exporter running. The lab exporter also uses short fallback expiry settings: `general=2`, `tcp=2`, `udp=2`, `maxlife=5`, and `expint=1` seconds.

The receiver structurally validates IPFIX version 10 headers, Template Sets, Data Sets, Observation Domain ID `0`, counters, protocol, TCP flags, transport ports, IPv4 source/destination addresses, and millisecond start/end timestamps. It also requires a decoded record containing the DHCP client's pre-NAT source address. Observation Domain ID `0` reflects softflowd's actual exporter implementation; the configuration validator rejects a misleading alternate value. R8 exports no IPv6 flows and is not a production collector or observability integration.

R8 creates no routes, nftables rules, DHCP/DNS settings, host services, or VM-wide forwarding changes. The export datagrams are router-originated OUTPUT traffic, whereas the R5 nftables chain governs forwarded traffic; no forwarding rule is weakened for telemetry. Runtime PID, log, control socket, and test-result files are restricted to `/run/home-virtual-router/ipfix/`. Disable stops only the PID-validated project exporter and leaves R7 running; R7 teardown refuses while R8 is active.

Installing the distro package may enable `softflowd.service` in the Ubuntu VM's host namespace. The lab reports that service's state but never starts, stops, enables, disables, or reconfigures it. Project commands always use the namespace process, project PID, and `/run/home-virtual-router/ipfix/softflowd.ctl`; they explicitly refuse the distro's default `/run/softflowd.ctl` and `/var/run/softflowd.ctl` paths. If the host service is unwanted, deciding whether to disable it remains an explicit VM-administration action outside these scripts.

## Safety boundary

Project scripts do not launch or control UTM and must never alter macOS networking. Future networking commands belong inside the Ubuntu VM and must use the shared guards in `router/scripts/safety.sh`, explicit `hvr-` namespace and interface names, and targeted cleanup.

The Ubuntu VM's ordinary UTM-facing interface and default route are infrastructure, not lab interfaces. Future namespace experiments must leave both unchanged. They must also avoid VM-host-wide nftables changes, including an unqualified `nft flush ruleset`. A later physical-deployment stage may define different requirements, but only when explicitly requested.

Before any state-changing lab script is used, create the marker manually inside the dedicated VM:

```sh
sudo touch /etc/home-virtual-router-lab
```

The repository does not create this marker and cannot create it on macOS. Removing the marker disables the shared lab-environment guard.

`lab/config/defaults.env` is parsed as data and validated before topology creation. Interface and nftables object names must use the `hvr-*` allowlist. Creation refuses pre-existing exact namespace or host interface names. R4 also refuses a conflicting `ip hvr-nat` table. R6 snapshots the host default route, forwarding, nftables, DNS configuration, dnsmasq system-service state, and interface configuration. It never invokes host `systemctl` mutations or writes the host resolver configuration.

## Commands

- `make lab-info` reports the distribution, kernel, marker, dependencies, configured subnets, and namespace presence without changing system state.
- `router/scripts/check-dependencies.sh` reports available and missing future tools without installing anything.
- `make lab-create` creates the exact three-namespace, two-veth topology.
- `make lab-status` shows lab links, addresses, routes, link state, and whether R3 is enabled.
- `make lab-test` checks the R2 base state before routing is enabled.
- `make routing-enable` enables forwarding only in `hvr-router` and adds the two exact namespace routes.
- `make routing-status` displays the same focused lab and R3 state as `make lab-status`.
- `make routing-test` verifies route selection and all six routed/direct ping paths.
- `make routing-disable` removes only exact R3 routes and restores router forwarding to `0`.
- `make nat-enable` removes the exact R3 upstream return route and enables scoped masquerading.
- `make nat-status` reports the project NAT table, rule, and counters.
- `make nat-test` proves upstream observes UDP source `192.0.2.2` and tests expected pings.
- `make nat-disable` deletes only `ip hvr-nat` and restores the exact R3 return route.
- `make firewall-enable` creates only `inet hvr-filter` inside `hvr-router`.
- `make firewall-status` displays forward policy, rules, and counters.
- `make firewall-test` verifies client-initiated ping/TCP and blocked unsolicited WAN TCP.
- `make firewall-disable` deletes only `inet hvr-filter`, leaving R4 NAT intact.
- `make dhcp-enable` starts project dnsmasq/dhclient instances and replaces the static client address with a lease.
- `make dhcp-status` reports process state, pool, client address/route, and lease entries.
- `make dhcp-test` validates the dynamic address, route, resolver option, lease, hostname, and connectivity.
- `make dhcp-disable` stops only project processes and restores the exact R5 static client state.
- `make dns-enable` restarts the router dnsmasq in combined DHCP/DNS mode and starts the isolated upstream test resolver.
- `make dns-test` verifies UDP and TCP port 53, deterministic forwarding, native logs, and a logged cache hit.
- `make dns-disable` returns the same router process to R6 DHCP-only mode without changing the client lease.
- `make ipfix-enable` starts namespace-scoped softflowd on `hvr-lan`, exporting IPFIX v10 over UDP to `192.0.2.1:4739`.
- `make ipfix-test` runs the isolated structural collector and proves the exported client source is pre-NAT.
- `make ipfix-disable` stops only the project exporter and preserves R7 and all earlier stages.
- `make lab-destroy` explicitly removes only the configured namespaces and exact-name partial veth endpoints.

The create, status, test, and destroy targets visibly use `sudo` because namespace administration requires root. Creation fails if the topology already exists. Teardown tolerates missing pieces and never performs wildcard or host-wide cleanup.

Expected R4 results:

- Client-to-upstream connectivity succeeds without an upstream LAN return route.
- A UDP observer in `hvr-upstream` reports the translated peer as `192.0.2.2`.
- Unsolicited upstream-to-client connectivity is not required and no upstream route exists for it.
- Disabling NAT restores routed-without-NAT R3 behavior and its explicit return route.

Expected R5 results:

- Client-initiated ping and TCP traffic succeeds, including established replies.
- A temporary isolated upstream route makes the client reachable for a controlled test, but a new WAN-to-LAN TCP connection is dropped by the firewall.
- The temporary route is always removed after the test.
- Disabling the firewall leaves R4 masquerading operational.

Expected R6 results:

- The client has exactly one global `/24` address from `10.0.0.100–10.0.0.199`.
- Its default route is learned via `10.0.0.1`, and the project resolver file records `10.0.0.1` without providing DNS service yet.
- The lease file matches the client MAC/address and contains hostname `hvr-client`.
- Router, WAN, and upstream pings continue through R3–R5.
- DHCP disable restores `10.0.0.10/24` and its static default route for staged teardown.

Expected R7 results:

- `example.test` resolves through `10.0.0.1` to `192.0.2.123`; the alternate test name resolves over TCP.
- Router DNS listens on UDP/TCP `10.0.0.1:53`; optional loopback and `hvr-lan` link-local sockets are allowed, while WAN and wildcard exposure are rejected.
- Repeated queries produce dnsmasq native cache log entries under `/run/home-virtual-router/dns/`.
- DNS disable leaves the verified R6 DHCP state working.

Expected R8 results:

- The collector receives IPFIX v10 templates and matching data records over UDP in `hvr-upstream`.
- Supported records expose flow counters, protocol, TCP flags, ports, IPv4 endpoints, and millisecond timestamps.
- At least one decoded flow has the dynamic `hvr-client` address as its source, proving LAN-side pre-NAT visibility.
- IPFIX disable leaves R7 DHCP/DNS, R5 firewall, R4 NAT, and R3 routing active.

VM lifecycle and configuration remain explicit UTM administration tasks outside this repository. Disable routing before inspecting the R2 baseline, then use `make lab-destroy` and confirm `make lab-info` reports all three namespaces absent.
