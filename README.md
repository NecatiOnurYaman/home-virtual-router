# Home Virtual Router

Home Virtual Router is a future Linux-based software router intended to sit behind an existing ISP modem/router and provide a controlled downstream LAN. It is separate from the Home Network Observability Platform; future integration will use standards-based interfaces such as IPFIX, DHCP lease data, DNS telemetry, and router metrics.

## Current status

The repository is at **Stage R3: IPv4 routing in an isolated Linux network-namespace lab**. It builds three namespaces and two private veth links, then optionally enables bidirectional routing through the router namespace. NAT, firewalling, DHCP, DNS, Internet access, and IPFIX are not enabled.

Development happens inside a dedicated Ubuntu 26.04 LTS virtual machine running under UTM on macOS. The namespace lab stays inside that VM without changing macOS networking or the VM's normal UTM-facing interface and default route.

The topology is `hvr-upstream` (`192.0.2.1/24`) ↔ `hvr-router` (`192.0.2.2/24`, `10.0.0.1/24`) ↔ `hvr-client` (`10.0.0.10/24`). R3 adds a client default route and an upstream return route so the two endpoint namespaces can communicate without NAT.

## Getting started

Clone or copy the repository into the dedicated Ubuntu VM, then mark that VM explicitly as the approved lab environment:

```sh
sudo touch /etc/home-virtual-router-lab
make check
make test
make lab-info
make lab-create
make routing-enable
make lab-status
make routing-test
make routing-disable
make lab-destroy
```

The lab targets clearly invoke `sudo`. Missing dependencies are reported but never installed automatically. See `docs/development-lab.md` for the isolation model, routing details, and safety checks.
