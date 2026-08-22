# Home Virtual Router

Home Virtual Router is a future Linux-based software router intended to sit behind an existing ISP modem/router and provide a controlled downstream LAN. It is separate from the Home Network Observability Platform; future integration will use standards-based interfaces such as IPFIX, DHCP lease data, DNS telemetry, and router metrics.

## Current status

The repository is at **Stage R1: repository foundation and safe lab tooling**. It does not yet configure routing, NAT, firewalling, DHCP, DNS, IP forwarding, IPFIX, or a network-namespace topology.

Development happens inside a dedicated Ubuntu 26.04 LTS virtual machine running under UTM on macOS. macOS does not provide Linux network namespaces or Linux networking tools such as `ip` and `nft`. Future namespace labs will run inside the Ubuntu VM without changing macOS networking or the VM's normal UTM-facing interface and default route.

The future Linux lab will use mature components: Linux kernel routing and network namespaces, iproute2, nftables, dnsmasq, standard diagnostics, and a standards-compliant IPFIX exporter. None of those router functions are enabled in R1.

## Getting started

Clone or copy the repository into the dedicated Ubuntu VM, then mark that VM explicitly as the approved lab environment:

```sh
sudo touch /etc/home-virtual-router-lab
make check
make test
make lab-info
router/scripts/check-dependencies.sh
```

Missing dependencies are reported with Ubuntu/Debian package suggestions for explicit installation by the user. The defaults in `lab/config/defaults.env` use RFC 5737 TEST-NET-1 for the simulated upstream. They are configuration only; no topology is created from them yet.

See `docs/development-lab.md` for the isolation model and operating boundaries.
