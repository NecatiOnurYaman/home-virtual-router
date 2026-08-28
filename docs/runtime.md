# R12 runtime orchestration

R12 adds one high-level lifecycle around the validated R2–R11 stage commands. It does not replace those commands, change `lab/config/defaults.env`, install a service, or add physical-router behavior.

## Lifecycle

Use `make runtime-start`, `runtime-status`, `runtime-check`, `runtime-restart`, and `runtime-stop` inside the marked Ubuntu lab VM. Start validates configuration and dependencies, then converges topology, routing, NAT, firewall, DHCP, DNS, the mode-specific observability link, IPFIX, and router-metrics export in dependency order. `TELEMETRY_MODE` remains the only profile selector:

- `lab` sends IPFIX and metrics to `hvr-upstream` and creates no host telemetry veth.
- `observability` creates the R9 `hvr-obs-host`/`hvr-observe` link before starting exporters.

`IPFIX_ENABLED` and `METRICS_EXPORT_ENABLED` continue to control their exporters. An unreachable receiver does not stop the core router: exporters remain locally healthy and log delivery failures. A missing or identity-invalid local exporter is degraded or inconsistent.

Every stage is inspected before it is changed. A healthy existing stage is preserved and not claimed by R12. An absent stage is started and recorded as R12-owned. Partial, unknown, or conflicting state stops convergence without broad cleanup. If startup fails, only stages started by that invocation are rolled back, in reverse order. Stop similarly removes only stages in the ownership record.

The bounded Ubuntu acceptance is:

```sh
sudo touch /etc/home-virtual-router-lab
make check
make test
make runtime-test
```

`runtime-test` requires an absent topology, performs a full start twice, checks health, stops twice, and verifies the absent baseline. It does not start a receiver or inject observability data.

If the manual R2–R8 lab is already running in the checked-in `lab` profile, return it to the absent baseline with the existing exact, reverse-order lifecycle before running the full acceptance:

```sh
sudo make runtime-stop
sudo make metrics-export-disable
sudo make ipfix-disable
sudo make dns-disable
sudo make dhcp-disable
sudo make firewall-disable
sudo make nat-disable
sudo make routing-disable
sudo make lab-destroy
sudo make runtime-test
```

The first command removes only R12-owned stages; the remaining commands dismantle the manually owned staged lab. Do not weaken the absent-topology precondition. A successful `runtime-test` ends with the topology and R12 state absent.

## Runtime diagnostics

R12 owns only `/run/home-virtual-router/runtime/`: `state.env`, `profile`, `started-at`, `config.snapshot`, `startup.log`, `last-error`, and the advisory `lock`. The strict state contains the profile, lifecycle status, UTC start time, and ordered ownership list. The lock is an operation mutex: a `flock --close` wrapper holds it for the complete lifecycle transaction without passing its descriptor to persistent router processes. These files and the namespaces are volatile and may disappear at reboot. Absence of both is cleanly stopped; malformed state, a profile mismatch, or a changed configuration snapshot is never sourced and blocks destructive teardown. Restore the recorded configuration before stopping an active runtime, then make the intended configuration change while stopped.

Status reports `running`, `stopped`, `degraded`, or `inconsistent` plus each desired subsystem. Check succeeds only for `running`. The core path is topology through DNS. IPFIX, the observability link, and metrics export are telemetry subsystems; absence degrades an otherwise healthy router, while conflicting identity or core damage is inconsistent.

## Optional systemd unit

The tracked `deploy/systemd/home-virtual-router.service.in` is a template, not an installed or enabled unit. Render and validate it with:

```sh
make systemd-show > /tmp/home-virtual-router.service
systemd-analyze verify /tmp/home-virtual-router.service
```

Installation under `/etc/systemd/system/`, enablement, and startup remain explicit operator actions. The unit retains the lab marker guard and calls the same ownership-aware lifecycle scripts.
