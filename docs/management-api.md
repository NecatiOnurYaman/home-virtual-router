# R17.2 read-only management API

R17.2 is a localhost-only JSON view of the accepted R17.1 operational-health model. It adds no GUI, authentication, remote exposure, configuration writes, or runtime controls. Start the development/native-validation listener with:

```sh
make management-api
```

The listener is fixed to IPv4 loopback at `127.0.0.1:8080`. Do not proxy, forward, or otherwise expose this unauthenticated stage to an untrusted interface.

## Endpoints

- `GET /api/v1/health` returns `{"api_version":"v1","status":"ok"}`. This is a cheap API-process check and never runs the R17.1 collector.
- `GET /api/v1/status` returns one fresh, complete R17.1 operational-health snapshot. A valid degraded snapshot is still HTTP 200.
- `GET /api/v1/clients` returns `{"api_version":"v1","clients":[...]}` using the snapshot's DHCP lease and raw Linux neighbor-state records. It does not invent an online/offline value.
- `GET /api/v1/config` returns `{"api_version":"v1","config":{...}}` containing only explicitly allowlisted, non-secret operational values.

The config allowlist contains deployment and WAN modes, WAN/LAN interface names, LAN subnet and router address, IPFIX and metrics-export enablement, and the two optional management diagnostic targets. It never dumps a configuration file or arbitrary environment keys. `/etc/home-virtual-router/router.env` remains the R1-R16 snapshotted runtime domain; `/etc/home-virtual-router/management.env` remains the separate optional R17 diagnostic domain. An absent management file still means both targets are `none`.

All mutating HTTP methods receive HTTP 405. Unknown paths receive HTTP 404. If authoritative collection cannot complete, `/status`, `/clients`, and `/config` return HTTP 503 with a fixed message; they do not report fabricated health or expose helper stderr, paths, environment contents, or tracebacks.

## Privilege boundary

The HTTP process is unprivileged. The authoritative R17.1 stage bridge correctly remains root-only, so data endpoints invoke exactly one fixed, bounded operation through `sudo -n`: `/usr/libexec/home-virtual-router-management-read`. That root helper accepts no arguments, reads only the fixed deployed router and management configuration paths, performs the existing observational collection, emits a structured JSON document, and offers no command, path, recovery, or mutation input.

R17.2 does not install a sudo policy, systemd service, or production packaging for this boundary. Native validation therefore requires an operator to install the helper at that fixed root-owned path and arrange a narrowly scoped local permission for only that executable. Do not grant broad passwordless sudo. Without that machine-local arrangement, `/health` remains available while the three data endpoints return HTTP 503. Installing and supervising a production API service is deferred.

Future LAN/WAN listening, authentication, TLS, configuration editing, and runtime-control operations remain later-stage work.
