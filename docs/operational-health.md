# R17.1 read-only operational health

R17.1 adds a structured observation layer; it does not change the accepted R12–R16 lifecycle. Runtime integrity answers whether HVR's recorded, owned topology and services still match their authoritative definitions. Operational health answers whether the resulting links and selected network paths are usable. A runtime can therefore remain recorded as `running` with healthy ownership while LAN or WAN operational health is `degraded`.

On the deployed Linux router, emit one deterministic JSON document with:

```sh
sudo make operational-health
```

The command reads `/etc/home-virtual-router/router.env`, `/run/home-virtual-router` state, Linux interface/sysfs/neighbor information, and dnsmasq leases. It invokes the existing authoritative runtime stage checks through a machine-readable bridge and uses bounded ICMP probes. It does not parse human-facing status text. It never changes links, addresses, routes, nftables, DHCP, systemd, configuration, runtime state, or recovery state.

## Optional diagnostics

These configuration keys are optional for compatibility with existing installations; omission is identical to `none`:

```text
LAN_HEALTH_TARGET=none
INTERNET_HEALTH_TARGET=none
```

Each configured value must be an IPv4 literal. `LAN_HEALTH_TARGET` must be inside `LAN_SUBNET` and must differ from `ROUTER_LAN`. Its neighbor/ARP state and ICMP result are reported separately, allowing a broken downstream bridge path to appear as degraded operational LAN health even when the interface and HVR runtime ownership remain healthy. `INTERNET_HEALTH_TARGET` is an optional external probe and never becomes part of core R16 runtime integrity or recovery.

Client records combine read-only dnsmasq lease fields with the raw Linux neighbor state on the configured LAN interface. A lease is not proof that a client is online, and NUD states such as `STALE` are not converted into an online/offline boolean.

## Deferred management surface

A later stage is expected to add an authenticated API/UI and an explicit exposure policy conceptually shaped as:

```text
MANAGEMENT_ENABLED=1
MANAGEMENT_LISTEN=lan
MANAGEMENT_PORT=8080
```

Future listen scopes are reserved as `localhost`, `lan`, `wan`, and `both`, with LAN-only as the intended default deployment behavior. These are not R17.1 configuration keys: no listener, HTTP server, authentication, firewall exposure, configuration writes, restart controls, or privileged mutation helper is implemented here.
