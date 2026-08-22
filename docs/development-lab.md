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

The upstream return route is necessary because R3 has no NAT: replies to `10.0.0.10` must be explicitly sent back through the router WAN address. R4 will introduce NAT so the lab can model the future upstream-modem deployment without requiring that LAN return route. R3 adds no router static routes because its two connected routes are sufficient. It provides no Internet access and configures no nftables, DHCP, DNS, or IPFIX.

## Safety boundary

Project scripts do not launch or control UTM and must never alter macOS networking. Future networking commands belong inside the Ubuntu VM and must use the shared guards in `router/scripts/safety.sh`, explicit `hvr-` namespace and interface names, and targeted cleanup.

The Ubuntu VM's ordinary UTM-facing interface and default route are infrastructure, not lab interfaces. Future namespace experiments must leave both unchanged. They must also avoid VM-host-wide nftables changes, including an unqualified `nft flush ruleset`. A later physical-deployment stage may define different requirements, but only when explicitly requested.

Before any state-changing lab script is used, create the marker manually inside the dedicated VM:

```sh
sudo touch /etc/home-virtual-router-lab
```

The repository does not create this marker and cannot create it on macOS. Removing the marker disables the shared lab-environment guard.

`lab/config/defaults.env` is parsed as data and validated before topology creation. Interface names must start with `hvr-` and fit Linux IFNAMSIZ. Creation refuses any pre-existing exact namespace or host interface name rather than reusing it. Topology and routing operations snapshot the Ubuntu VM default route and host IPv4 forwarding value, reject a reserved lab interface as the default-route device, and verify both host values are unchanged afterward.

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
- `make lab-destroy` explicitly removes only the configured namespaces and exact-name partial veth endpoints.

The create, status, test, and destroy targets visibly use `sudo` because namespace administration requires root. Creation fails if the topology already exists. Teardown tolerates missing pieces and never performs wildcard or host-wide cleanup.

Expected R3 results:

- Client-to-upstream and upstream-to-client pings succeed through `hvr-router`.
- Namespace route lookups select `10.0.0.1` and `192.0.2.2` as the respective next hops.
- Disabling R3 makes client-to-upstream traffic fail again while preserving direct-link connectivity.
- No masquerade, SNAT, DNAT, or nftables rules are involved.

VM lifecycle and configuration remain explicit UTM administration tasks outside this repository. Disable routing before inspecting the R2 baseline, then use `make lab-destroy` and confirm `make lab-info` reports all three namespaces absent.
