# Home Virtual Router

Home Virtual Router is a future Linux-based software router intended to sit behind an existing ISP modem/router and provide a controlled downstream LAN. It is separate from the Home Network Observability Platform; future integration will use standards-based interfaces such as IPFIX, DHCP lease data, DNS telemetry, and router metrics.

## Current status

The repository is at **Stage R7: isolated DNS forwarding, caching, and native query logging**. The existing router dnsmasq process provides DHCP and DNS only on `hvr-lan`; it forwards to a deterministic test resolver in `hvr-upstream`. Internet DNS, blocking, management services, and IPFIX are not enabled.

Development happens inside a dedicated Ubuntu 26.04 LTS virtual machine running under UTM on macOS. The namespace lab stays inside that VM without changing macOS networking or the VM's normal UTM-facing interface and default route.

The topology is `hvr-upstream` (`192.0.2.1/24`) ↔ `hvr-router` (`192.0.2.2/24`, `10.0.0.1/24`) ↔ `hvr-client`. In R6 the client replaces its earlier static address with one lease from `10.0.0.100–10.0.0.199`.

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
make dhcp-enable
make dns-enable
make lab-status
make dns-test
make dns-disable
make dhcp-test
make dhcp-disable
make firewall-disable
make nat-disable
make routing-disable
make lab-destroy
```

The lab targets clearly invoke `sudo`. DHCP disable restores the earlier static client state for staged teardown. Missing dependencies, including `dhclient`, are reported but never installed automatically. See `docs/development-lab.md` for lifecycle and safety details.
