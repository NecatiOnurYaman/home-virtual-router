# Home Virtual Router

Home Virtual Router is a future Linux-based software router intended to sit behind an existing ISP modem/router and provide a controlled downstream LAN. It remains separate from the Home Network Observability Platform and exports telemetry through IPFIX plus narrowly shared dnsmasq lease and query-log files.

## Current status

The repository is at **Stage R10: local router system and interface metrics**. R10 adds a read-only, on-demand metric snapshot sourced from Linux `/proc` and `/sys`, with stable semantic interface identities. R9 observability integration and R8 isolated validation remain unchanged. Metric network export, router management, anomaly detection, SNMP, physical deployment, production services, and IPv6 stages are not enabled.

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

## Local router metrics

`sudo make metrics-show` collects one R10 snapshot inside `hvr-router` and writes compact JSON to stdout. It starts no daemon, stores no history, and opens no network listener. The snapshot has one UTC timestamp and schema version, with samples under `router.metrics`. Each sample contains `name`, `value`, `unit`, and `type`; interface samples also contain `interface.role` (`lan`, `wan`, or `telemetry`) and the configured kernel `interface.name`.

System gauges are `system.uptime_seconds`, `system.cpu.utilization_ratio`, `system.memory.total_bytes`, `system.memory.available_bytes`, and `system.memory.utilization_ratio`. Uptime comes from `/proc/uptime`. CPU utilization is the non-idle fraction between two aggregate `/proc/stat` samples taken 0.1 seconds apart. Memory uses `MemTotal` and `MemAvailable` from `/proc/meminfo`; ratios are represented from `0.0` to `1.0`.

For each configured router interface, R10 exposes cumulative `interface.rx_bytes`, `interface.tx_bytes`, `interface.rx_packets`, `interface.tx_packets`, `interface.rx_errors`, `interface.tx_errors`, `interface.rx_drops`, and `interface.tx_drops` counters from `/sys/class/net/<name>/statistics`, plus the string-valued `interface.operstate` state. Counters can reset after reboot, interface recreation, or namespace topology recreation; R10 does not compensate for resets or calculate rates.

The command runs inside the router network namespace so interface visibility is namespace-specific and loopback is excluded. Network namespaces do not isolate the kernel's CPU, memory, or uptime, so those system gauges describe the Ubuntu host/kernel in the lab. On a future physical router, that Linux host would itself be the router. Network serialization/export is deliberately deferred to R11.
