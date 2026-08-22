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

Dnsmasq binds only to `hvr-lan`; `port=0` disables its DNS service until R7. DHCP traffic is to and from the router itself on UDP 67/68, so it does not traverse the R5 forward chain. The custom dhclient hook writes the advertised DNS value to `/run/home-virtual-router/dhcp/client-resolv.conf` instead of changing the Ubuntu VM's `/etc/resolv.conf`.

Leases are stored at `/run/home-virtual-router/dhcp/dnsmasq.leases` in dnsmasq's five-field format: `<expiry_epoch> <mac> <ip> <hostname> <client_id>`. The separate Home Network Observability Platform can consume this file later; R6 does not synchronize repositories. This dynamic workflow resembles a phone, television, or laptop joining the future home LAN.

R6 resolves the installed `dnsmasq` system user's numeric UID and primary GID from the system account database. It does not assume that the primary group is also named `dnsmasq`, and it will not create an account or group if the user is absent. Failed or interrupted enable operations stop only processes identified by project PID files and command markers, remove only the explicit project runtime files, and restore the R5 static client address and route. `make dhcp-disable` is also safe after a partial start where neither daemon successfully ran.

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

VM lifecycle and configuration remain explicit UTM administration tasks outside this repository. Disable routing before inspecting the R2 baseline, then use `make lab-destroy` and confirm `make lab-info` reports all three namespaces absent.
