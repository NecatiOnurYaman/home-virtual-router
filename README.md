# Home Virtual Router

Home Virtual Router is a future Linux-based software router intended to sit behind an existing ISP modem/router and provide a controlled downstream LAN. It is separate from the Home Network Observability Platform; future integration will use standards-based interfaces such as IPFIX, DHCP lease data, DNS telemetry, and router metrics.

## Current status

The repository is at **Stage R5: stateful IPv4 forwarding policy in an isolated Linux network-namespace lab**. It adds a dedicated nftables filter table inside the router namespace while keeping NAT separate. DHCP, DNS, Internet access, management services, and IPFIX are not enabled.

Development happens inside a dedicated Ubuntu 26.04 LTS virtual machine running under UTM on macOS. The namespace lab stays inside that VM without changing macOS networking or the VM's normal UTM-facing interface and default route.

The topology is `hvr-upstream` (`192.0.2.1/24`) ↔ `hvr-router` (`192.0.2.2/24`, `10.0.0.1/24`) ↔ `hvr-client` (`10.0.0.10/24`). R5 allows new LAN-to-WAN flows and established replies while dropping invalid traffic and unsolicited WAN-to-LAN forwarding by default.

## Getting started

Clone or copy the repository into the dedicated Ubuntu VM, then mark that VM explicitly as the approved lab environment:

```sh
sudo touch /etc/home-virtual-router-lab
make check
make test
make lab-info
make lab-create
make routing-enable
make nat-enable
make firewall-enable
make lab-status
make firewall-test
make firewall-disable
make nat-disable
make routing-disable
make lab-destroy
```

The lab targets clearly invoke `sudo`. Firewall disable returns exactly to R4 with NAT intact. Missing dependencies are reported but never installed automatically. See `docs/development-lab.md` for policy and safety details.
