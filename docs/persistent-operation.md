# R16 persistent router operation and supervision

R16 keeps the R15 `Type=oneshot`/`RemainAfterExit=yes` service and adds a systemd-native health service and timer. The main service still delegates all ownership and convergence to the canonical `runtime-start.sh`, `runtime-check.sh`, and `runtime-stop.sh` lifecycle. The watchdog never repairs or respawns an individual DHCP, DNS, IPFIX, or metrics process.

`home-virtual-router-health.timer` runs `home-virtual-router-health.service` about every 30 seconds. A healthy or intentionally inactive router causes no mutation and no routine journal message. Starting, stopping, and reloading states are skipped. A first failed runtime check is confirmed after five seconds; a transient failure that clears causes no recovery.

For a confirmed failure, the health action first requests the explicit recovery form of canonical runtime teardown. That transaction holds the normal runtime lock and requires an exactly running physical runtime, matching deployment/profile and configuration snapshot, recorded stage ownership, and existing stage-specific proof that any inconsistent residue is safely reconcilable. Only the verified HVR dnsmasq path currently needs special recovery cleanup; it verifies generated configuration and marker metadata plus process identity/namespace before acting. Ambiguous state fails before teardown, and the main service is not restarted. A successful recovery teardown is followed by exactly one `systemctl restart home-virtual-router.service` and a required full runtime check. This remains coherent whole-runtime reconstruction, never per-daemon respawning.

Ordinary `runtime-stop` and `systemd-stop` retain their conservative first-stop behavior: an inconsistent owned stage is refused rather than being treated automatically as an interrupted teardown. A failed recovery remains visible in systemd and journald, and a failed main service is not automatically resurrected. The main service retains its limit of three starts per five minutes, so persistent faults cannot create an unbounded restart storm. The timer has `Persistent=false`, so powered-off intervals do not create catch-up checks.

## Prerequisites and interface ownership

Persistent operation requires `DEPLOYMENT_MODE=physical`. Prepare the root-owned `/etc/home-virtual-router/router.env` and `/etc/home-virtual-router/allow-physical-deployment` exactly as for R13/R14, with dedicated `PHYSICAL_WAN_INTERFACE` and `PHYSICAL_LAN_INTERFACE` values. In DHCP WAN mode, HVR owns the WAN DHCP client.

Installation generates `/etc/NetworkManager/conf.d/90-home-virtual-router-unmanaged.conf` containing only the two configured interface names. It does not disable NetworkManager, alter unrelated profiles, or reload NetworkManager. Before the first service start, deliberately reload NetworkManager or reboot and verify both deployment interfaces are unmanaged. Existing systemd-networkd configuration must likewise leave them unmanaged.

Use a local console for initial deployment. If `PHYSICAL_MANAGEMENT_INTERFACE_ACK` acknowledges the WAN as the current management path, HVR taking ownership of that interface can terminate an SSH session.

## Inspect, install, and operate

From the repository checkout on Ubuntu, preview all generated units and the interface policy:

```sh
make systemd-show
make systemd-health-show
sudo python3 router/scripts/persistence.py render-nm "$PWD"
sudo make systemd-install
```

Installation atomically installs the main service, health service, timer, and narrow NetworkManager policy. It validates privileged inputs and paths, calls `systemctl daemon-reload`, and does not start or enable anything. Inspect the installed artifacts with:

```sh
sudo systemctl cat home-virtual-router.service
sudo systemctl cat home-virtual-router-health.service
sudo systemctl cat home-virtual-router-health.timer
sudo cat /etc/NetworkManager/conf.d/90-home-virtual-router-unmanaged.conf
```

After safely applying the NetworkManager policy and verifying both deployment interfaces are unmanaged, start the router and supervision together:

```sh
sudo make systemd-start
sudo make systemd-status
sudo make runtime-check
```

`systemd-start` starts the main router first and then the timer. If timer startup fails, it stops the main service rather than leaving an unsupervised deployment. `systemd-status` is read-only and reports installation-visible systemd states, enablement, configured interfaces, NetworkManager ownership, dynamic WAN lease details when available, canonical runtime status, and a non-fatal warning when `timedatectl` reports that the host clock is not NTP-synchronized. HVR never changes the clock or NTP configuration.

Enable both boot startup and health supervision separately:

```sh
sudo make systemd-enable
```

Normal stop prevents watchdog races by stopping the timer, then any in-flight health action, then the main router through canonical teardown:

```sh
sudo make systemd-stop
```

Disabling affects future boot activation but does not stop a currently running router:

```sh
sudo make systemd-disable
```

To remove persistence safely:

```sh
sudo make systemd-stop
sudo make systemd-disable
sudo make systemd-uninstall
```

Uninstall is idempotent but refuses while any installed HVR unit is active, while the main service or timer is enabled, or when an installed artifact is a symlink, non-regular file, or differs from its generated content. It does not restore NetworkManager profiles or immediately reclaim interfaces.

## Recovery, R14, and diagnostics

R14 acceptance and persistent operation remain mutually exclusive. R14 refuses while the main service, health timer, or health service is active or transitioning. The persistent service refuses startup while an R14 checkpoint exists, and the health action refuses recovery if one appears. Stop persistent operation before starting R14; never delete ownership or checkpoint state to bypass either controller.

Inspect a failure or recent recovery with:

```sh
sudo make systemd-status
sudo systemctl status --no-pager home-virtual-router.service home-virtual-router-health.timer home-virtual-router-health.service
sudo journalctl -u home-virtual-router.service -u home-virtual-router-health.service -b --no-pager
sudo make runtime-status
sudo make runtime-check
```

The health journal records a confirmed failure and its runtime-check reason, recovery-teardown request or refusal, the single main-service restart, post-restart validation, and recovery success or failure. Successful periodic checks are intentionally silent.

Temporary link loss can make the canonical runtime check fail. The five-second confirmation avoids reacting to a single brief failure. A longer outage may cause one full recovery attempt; if convergence cannot succeed, the main unit remains failed and its existing systemd start limit bounds retry behavior. The DHCP client continues to own normal lease renewal. R16 does not add a WAN failure state machine.

This supervision improves recovery from failures such as an owned dnsmasq, metrics exporter, or pmacctd process dying, because all are evaluated through the same runtime check and reconstructed through the full lifecycle. It does not install packages, migrate configuration, manage NTP, provide external monitoring, or implement high availability/failover. Production operators should still monitor the service and health unit from outside the router.
