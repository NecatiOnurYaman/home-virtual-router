# Isolated Linux development lab

The project uses the existing dedicated Ubuntu 26.04 LTS (`resolute`) virtual machine running under UTM on macOS. Ubuntu supplies the Linux kernel required by namespaces. UTM and the Ubuntu VM are not managed by this repository.

The Ubuntu VM hosts the isolated R2 namespace lab; it is not itself part of the simulated router topology:

```text
hvr-upstream              hvr-router                    hvr-client
192.0.2.1/24              192.0.2.2/24                  10.0.0.10/24
    hvr-up <----------> hvr-wan  hvr-lan <----------> hvr-client
                                      10.0.0.1/24
```

The upstream uses RFC 5737 TEST-NET-1. Only kernel-generated routes for the two directly connected subnets exist. R2 explicitly forces IPv4 forwarding off inside `hvr-router`, regardless of the Ubuntu VM host's forwarding value, and verifies the host value is unchanged. Enabling router-namespace forwarding belongs to R3. R2 does not add namespace default routes, provide Internet access, or configure NAT, nftables, DHCP, DNS, or IPFIX.

## Safety boundary

Project scripts do not launch or control UTM and must never alter macOS networking. Future networking commands belong inside the Ubuntu VM and must use the shared guards in `router/scripts/safety.sh`, explicit `hvr-` namespace and interface names, and targeted cleanup.

The Ubuntu VM's ordinary UTM-facing interface and default route are infrastructure, not lab interfaces. Future namespace experiments must leave both unchanged. They must also avoid VM-host-wide nftables changes, including an unqualified `nft flush ruleset`. A later physical-deployment stage may define different requirements, but only when explicitly requested.

Before any state-changing lab script is used, create the marker manually inside the dedicated VM:

```sh
sudo touch /etc/home-virtual-router-lab
```

The repository does not create this marker and cannot create it on macOS. Removing the marker disables the shared lab-environment guard.

`lab/config/defaults.env` is parsed as data and validated before topology creation. Interface names must start with `hvr-` and fit Linux IFNAMSIZ. Creation refuses any pre-existing exact namespace or host interface name rather than reusing it. Both creation and teardown snapshot the Ubuntu VM default route, reject a reserved lab interface as its device, and verify the snapshot is unchanged afterward.

## Commands

- `make lab-info` reports the distribution, kernel, marker, dependencies, configured subnets, and namespace presence without changing system state.
- `router/scripts/check-dependencies.sh` reports available and missing future tools without installing anything.
- `make lab-create` creates the exact three-namespace, two-veth topology.
- `make lab-status` shows links, IPv4 addresses, routes, and link state only for the lab namespaces.
- `make lab-test` checks addresses and direct-link pings without changing topology.
- `make lab-destroy` explicitly removes only the configured namespaces and exact-name partial veth endpoints.

The create, status, test, and destroy targets visibly use `sudo` because namespace administration requires root. Creation fails if the topology already exists. Teardown tolerates missing pieces and never performs wildcard or host-wide cleanup.

Expected R2 test results:

- `hvr-upstream` ↔ router WAN succeeds.
- `hvr-client` ↔ router LAN succeeds.
- `hvr-client` → `192.0.2.1` fails, proving routing/forwarding has not been implemented.

VM lifecycle and configuration remain explicit UTM administration tasks outside this repository. After testing, use `make lab-destroy` and confirm `make lab-info` reports all three namespaces absent.
