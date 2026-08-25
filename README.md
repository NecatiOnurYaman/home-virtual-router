# Home Virtual Router

Home Virtual Router is a future Linux-based software router intended to sit behind an existing ISP modem/router and provide a controlled downstream LAN. It remains separate from the Home Network Observability Platform and exports telemetry through IPFIX plus narrowly shared dnsmasq lease and query-log files.

## Current status

The repository is at **Stage R9: observability integration**. R8 isolated validation remains the default. In explicit observability mode, the same `pmacctd`/`nfprobe` exporter sends pre-NAT IPFIX v10 UDP to an external backend through a project-owned point-to-point link, while DHCP and DNS files are exposed through a narrow runtime export directory. The observability application is not bundled here. Later router-management, anomaly-detection, SNMP, physical-deployment, production-service, metrics, and IPv6 stages are not enabled.

Development happens inside a dedicated Ubuntu 26.04 LTS virtual machine running under UTM on macOS. The namespace lab stays inside that VM without changing macOS networking or the VM's normal UTM-facing interface and default route.

The topology is `hvr-upstream` (`192.0.2.1/24`) ↔ `hvr-router` (`192.0.2.2/24`, `10.0.0.1/24`) ↔ `hvr-client`. In R6 the client replaces its earlier static address with one lease from `10.0.0.100–10.0.0.199`.

## Getting started

Clone or copy the repository into the dedicated Ubuntu VM, then mark that VM explicitly as the approved lab environment:

```sh
sudo touch /etc/home-virtual-router-lab
sudo apt install pmacct
make check
make test
make lab-info
make lab-create
make routing-enable
make nat-enable
make firewall-enable
make dhcp-enable
make dns-enable
make ipfix-enable
make lab-status
make ipfix-test
make ipfix-disable
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

## Observability integration

The checked-in `lab` mode keeps `IPFIX_COLLECTOR_HOST=192.0.2.1` and `make ipfix-test` unchanged. For real integration, set `TELEMETRY_MODE=observability`, `IPFIX_COLLECTOR_HOST=198.18.0.1`, and `IPFIX_COLLECTOR_PORT=4739` in the data-only `lab/config/defaults.env`.

After R2–R7 are enabled, run `make observability-enable` before `make ipfix-enable`. The host endpoint is `hvr-obs-host` at `198.18.0.1/30`; `hvr-router` owns `hvr-observe` at `198.18.0.2/30`. This connected route is not a default route and provides no client forwarding path. The export view contains only `/run/home-virtual-router/export/dnsmasq.leases` and `dnsmasq.log`.

Start the separate observability backend with its UDP listener and those two export entries mounted read-only, then run `make integration-test`. Set `OBSERVABILITY_API_URL` only when its API is not at `http://127.0.0.1:8000`. Teardown order is `make ipfix-disable` then `make observability-disable`.
