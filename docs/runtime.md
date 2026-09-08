# R12 runtime orchestration

R12 adds one high-level lifecycle around the validated R2–R11 stage commands. R13 extends its topology/stage dispatch for `DEPLOYMENT_MODE=physical`; `DEPLOYMENT_MODE=lab` remains the tracked default and retains the validated namespace commands.

## Lifecycle

Use `make runtime-start`, `runtime-status`, `runtime-check`, `runtime-restart`, and `runtime-stop` inside the marked Ubuntu lab VM. Start validates configuration and dependencies, then converges topology, routing, NAT, firewall, DHCP, DNS, the mode-specific observability link, IPFIX, and router-metrics export in dependency order. `TELEMETRY_MODE` remains the only profile selector:

- `lab` sends IPFIX and metrics to `hvr-upstream` and creates no host telemetry veth.
- `observability` creates the R9 `hvr-obs-host`/`hvr-observe` link before starting exporters.

`DEPLOYMENT_MODE` is independent: lab executes router commands in `hvr-router`; physical executes exact project operations in the host network namespace against explicit pre-existing interfaces. “Physical” is compatibility terminology and includes UTM/QEMU VirtIO and other VM-provided Ethernet interfaces; it does not imply bare-metal hardware. R13 physical mode accepts `TELEMETRY_MODE=lab` only; the namespace-specific R9 observability veth is never created in host-interface deployment.

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

R12 owns only `/run/home-virtual-router/runtime/`: `state.env`, `profile`, `started-at`, `config.snapshot`, `startup.log`, `last-error`, and the advisory `lock`. Version-2 state adds deployment mode; version-1 lab state remains readable. The lock remains a complete-transaction operation mutex. Physical identity is additionally recorded in `/run/home-virtual-router/physical/interface-map.env`, while the startup config snapshot binds teardown to the exact NIC mapping. Missing or changed snapshots block teardown rather than selecting newly configured NICs.

Status reports `running`, `stopped`, `degraded`, or `inconsistent` plus each desired subsystem. Check succeeds only for `running`. The core path is topology through DNS. IPFIX, the observability link, and metrics export are telemetry subsystems; absence degrades an otherwise healthy router, while conflicting identity or core damage is inconsistent.

## Persistent systemd operation and supervision

R15 introduced the explicitly installable orchestration layer; R16 adds a 30-second companion health timer that confirms failures and requests one controlled restart through the same canonical runtime lifecycle. Preview the generated units with:

```sh
make systemd-show > /tmp/home-virtual-router.service
make systemd-health-show
systemd-analyze verify /tmp/home-virtual-router.service
```

Installation, enablement, and startup remain separate operator actions. The main unit calls thin wrappers around the deployment-aware lifecycle and requires a healthy runtime before startup succeeds; the companion check does not reimplement component recovery. Persistent operation is physical-mode only; follow [`persistent-operation.md`](persistent-operation.md) for recovery bounds, diagnostics, NetworkManager policy, complete workflow, and R14 mutual exclusion.
