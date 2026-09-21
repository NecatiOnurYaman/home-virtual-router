# R17.2 API and R18.1 management UI

R18.1 adds an offline browser interface to the localhost-only R17.2 JSON API. The same unprivileged process serves both surfaces; it adds no authentication, remote exposure, configuration writes, or runtime controls. Start the development listener with:

```sh
make management-api
```

The listener is fixed to IPv4 loopback at `127.0.0.1:8080`. Do not proxy, forward, or otherwise expose this unauthenticated stage to an untrusted interface.

Open `http://127.0.0.1:8080/` in a browser on the router host. The interface contains five read-only views:

- **Overview** combines `/api/v1/status`, `/api/v1/clients`, and `/api/v1/config` into a concise operational summary.
- **Network** presents expected and observed WAN/LAN values and checks from `/api/v1/status` and `/api/v1/config`.
- **Clients** presents DHCP lease and raw Linux neighbor evidence from `/api/v1/clients`; it does not invent an online/offline state.
- **Services** presents the service checks from `/api/v1/status` without reinterpreting backend health.
- **System** presents the safely exposed runtime record, generation time, and cheap `/api/v1/health` result.

The browser performs a manual or non-overlapping 30-second refresh. Endpoint failures, HTTP 503, malformed JSON, absent optional fields, and unknown future status values are shown as unavailable/unknown management data without claiming the router itself failed. One endpoint failing does not discard successful data from the others.

The interface is plain UTF-8 HTML, CSS, and modern vanilla JavaScript. It has no compilation step, Node.js dependency, third-party library, external font, analytics, CDN, or other remote resource, so it operates entirely offline. Keyboard-visible focus, semantic landmarks and tables, text-and-symbol status badges, horizontal table overflow, and a narrow-screen navigation layout provide the R18.1 accessibility and responsive baseline.

## Endpoints

- `GET /api/v1/health` returns `{"api_version":"v1","status":"ok"}`. This is a cheap API-process check and never runs the R17.1 collector.
- `GET /api/v1/status` returns one fresh, complete R17.1 operational-health snapshot. A valid degraded snapshot is still HTTP 200.
- `GET /api/v1/clients` returns `{"api_version":"v1","clients":[...]}` using the snapshot's DHCP lease and raw Linux neighbor-state records. It does not invent an online/offline value.
- `GET /api/v1/config` returns `{"api_version":"v1","config":{...}}` containing only explicitly allowlisted, non-secret operational values.

The config allowlist contains deployment and WAN modes, WAN/LAN interface names, LAN subnet and router address, IPFIX and metrics-export enablement, and the two optional management diagnostic targets. It never dumps a configuration file or arbitrary environment keys. `/etc/home-virtual-router/router.env` remains the R1-R16 snapshotted runtime domain; `/etc/home-virtual-router/management.env` remains the separate optional R17 diagnostic domain. An absent management file still means both targets are `none`.

All mutating HTTP methods receive HTTP 405. Unknown paths receive HTTP 404. If authoritative collection cannot complete, `/status`, `/clients`, and `/config` return HTTP 503 with a fixed message; they do not report fabricated health or expose helper stderr, paths, environment contents, or tracebacks.

## Privilege boundary

The HTTP process is unprivileged. The authoritative R17.1 stage bridge correctly remains root-only, so data endpoints invoke exactly one fixed, bounded operation through `sudo -n`: `/usr/libexec/home-virtual-router-management-read`. That root helper accepts no arguments, reads only the fixed deployed router and management configuration paths, performs the existing observational collection, emits a structured JSON document, and offers no command, path, recovery, or mutation input.

Install the native read boundary explicitly on Ubuntu before running the API as its dedicated identity:

```sh
sudo make install-management-api-support
sudo make verify-management-api-support
sudo -u hvr-web /usr/bin/python3 -I -B \
  /usr/lib/home-virtual-router/router/scripts/management_api.py
```

Installation creates the non-login system account `hvr-web` with home `/nonexistent`; it is not added to `sudo` or another privileged group. It installs:

```text
/usr/libexec/home-virtual-router-management-read
/usr/lib/home-virtual-router/
    router/management/              R17.1 collection and R17.2 HTTP modules
    router/runtime/                 runtime-state reader
    router/scripts/                 installed API, fixed reader, and status bridge
    router/config/                  health-check configuration dependencies
    lab/scripts/                    sourced runtime/topology health primitives
    lab/config/                     validated fallback configuration
    physical/scripts/               sourced physical health primitives
    web/                             R18.1 HTML shell
        static/                      fixed CSS and JavaScript assets
/etc/sudoers.d/home-virtual-router-management
```

The installed tree, entry point, and UI assets are root-owned, not group/world writable, and independent of the invoking checkout. The API code and UI are read-only to `hvr-web`; the server is still executed unprivileged as that identity. Its installed script resolves `/usr/lib/home-virtual-router` from its own absolute location. The API launch uses Python isolation and bytecode suppression, so it neither imports from nor writes to the checkout.

Static serving uses an exact map for `/`, `/static/styles.css`, and `/static/app.js`. Request paths are never appended to a document root. Unknown and encoded traversal paths cannot select a file, directory listings are impossible, mapped symlinks are rejected, and each response is size-bounded with a fixed content type.

The privileged entry point changes to `/`, replaces the caller environment with a fixed minimal environment, uses a fixed secure `PATH`, and executes `/usr/bin/python3 -I -B` against the absolute installed reader. Python isolation and the installed reader's absolute module root prevent `PYTHONPATH`, `PYTHONHOME`, the caller's current directory, home directory, or checkout from redirecting privileged imports. `-B` also prevents normal management reads from creating `__pycache__` files in the installed tree.

The installed checker code and the active R16 runtime identity are deliberately separate. Canonical `runtime-start` records its canonical source root as root-owned mode `0640` data at `/run/home-virtual-router/runtime/repo-root`. The installed checker validates that fixed record and uses it only to construct path-sensitive process identity expectations, such as the exact `export_metrics.py` argument. It never sources, imports, or executes code from the recorded checkout. The metadata is removed by canonical runtime teardown, cannot be selected through HTTP, configuration, or caller environment, and malformed, missing, non-canonical, or non-root-owned metadata fails closed.

An R16 instance already running from before this metadata existed needs one explicit convergence command from the same authoritative checkout before installed management checks can succeed:

```sh
sudo make runtime-start
```

This idempotent start validates an existing metrics exporter against that checkout before recording the root; it does not restart already-healthy stages. The R17 installer never starts or restarts R16 and never writes runtime identity metadata.

The sudoers drop-in is root-owned mode `0440`, is checked with `visudo -cf`, and authorizes only this zero-argument command:

```sudoers
Defaults:hvr-web env_reset
Defaults:hvr-web secure_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
hvr-web ALL=(root) NOPASSWD: /usr/libexec/home-virtual-router-management-read ""
```

The empty argument string is the sudoers command-matching form that requires no command-line arguments. There is no wildcard, shell, Python authorization, `SETENV`, arbitrary path, or broad sudo grant. The helper independently rejects arguments as defense in depth.

For native validation, confirm the two `make` commands above succeed, then inspect `sudo -l -U hvr-web`, run `sudo -u hvr-web sudo -n /usr/libexec/home-virtual-router-management-read`, and start the API with the absolute installed command shown above. Verify `/health`, `/status`, `/clients`, and `/config` over `127.0.0.1`. Also verify an added helper argument is rejected and that the API process runs as `hvr-web`, not root. Checkout and `/home` permissions do not need to be relaxed: `hvr-web` executes no application code from `/home`. Privilege escalation remains limited to the existing exact read helper. Native Linux validation of this corrected installed API layout has not yet been performed.

`sudo make uninstall-management-api-support` removes only exact, unmodified installed support files. It deliberately retains `hvr-web` to avoid surprising account deletion and never removes `router.env` or `management.env`.

## R18.1 limitations

This stage remains loopback-only and read-only. It has no authentication, TLS, LAN exposure, configuration editing, runtime controls, topology visualization, evidence-chain interface, history, or traffic charts. R18.4 will address secure LAN management; until then, do not expose or proxy this listener beyond loopback.

R17.2 still does not install or start an API systemd service. The `make management-api` target remains a development launcher, and the listener remains fixed to localhost. Without the installed boundary, `/health` remains available while the three data endpoints return HTTP 503.

Future LAN/WAN listening, authentication, TLS, configuration editing, and runtime-control operations remain later-stage work.
