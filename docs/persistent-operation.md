# R15 persistent router operation

R15 installs a systemd orchestration layer around the existing runtime. It does not duplicate routing, DHCP, DNS, firewall, IPFIX, metrics, ownership, rollback, or locking logic. The unit is `Type=oneshot` with `RemainAfterExit=yes` because the canonical runtime intentionally starts several independently owned background processes and then exits. A successful unit start additionally requires `runtime-check` to pass.

The conservative `Restart=on-failure` policy retries failed initial control operations after 10 seconds and is rate-limited to three starts per five minutes. It does not monitor every child continuously or restart the router for an ordinary upstream DHCP outage; richer reconciliation/watchdog behavior remains deferred to R16.

## Prerequisites and interface ownership

R15 supports `DEPLOYMENT_MODE=physical`. Prepare the root-owned `/etc/home-virtual-router/router.env` and `/etc/home-virtual-router/allow-physical-deployment` exactly as for R13/R14. Configure dedicated `PHYSICAL_WAN_INTERFACE` and `PHYSICAL_LAN_INTERFACE` values. In DHCP WAN mode, HVR owns the WAN DHCP client.

Installation generates `/etc/NetworkManager/conf.d/90-home-virtual-router-unmanaged.conf` containing only the two configured interface names. This keeps them outside NetworkManager control after reboot without disabling NetworkManager, changing profiles, or affecting unrelated devices. Installation does not reload or restart NetworkManager because doing so could disrupt the current management connection. Before the first service start, deliberately reload NetworkManager or reboot and verify both interfaces are unmanaged. Existing systemd-networkd configuration must likewise leave them unmanaged.

Use a local console for initial deployment. If `PHYSICAL_MANAGEMENT_INTERFACE_ACK=enp0s1` acknowledges the WAN as the current management path, HVR taking ownership of that interface and replacing its address/default route can terminate an SSH session.

## Inspect, install, and operate

From the repository checkout on Ubuntu:

```sh
make systemd-show
sudo python3 router/scripts/persistence.py render-nm "$PWD"
sudo make systemd-install
```

`systemd-install` atomically installs the unit and narrow NetworkManager policy, validates paths, runs `systemctl daemon-reload`, and does **not** enable or start anything. Inspect them with:

```sh
sudo systemctl cat home-virtual-router.service
sudo cat /etc/NetworkManager/conf.d/90-home-virtual-router-unmanaged.conf
```

After applying the NetworkManager policy safely (for example, from the local console with `sudo systemctl reload NetworkManager`), confirm the exact WAN/LAN devices are unmanaged with `nmcli device status`, then start HVR:

```sh
sudo make systemd-start
sudo make systemd-status
sudo make runtime-check
```

Normal service stop uses the canonical runtime teardown and leaves the installed persistent interface policy in place:

```sh
sudo make systemd-stop
```

Enable boot startup separately:

```sh
sudo make systemd-enable
```

After an operator-initiated reboot, the dedicated interfaces should remain unmanaged and `home-virtual-router.service` should automatically converge WAN DHCP or static WAN, LAN addressing, forwarding, NAT, firewall, DHCP/DNS, and configured telemetry. The unit deliberately does not require `network-online.target`; HVR acquires its own WAN lease.

To remove persistence:

```sh
sudo make systemd-stop
sudo make systemd-disable
sudo make systemd-uninstall
```

Uninstall is idempotent but refuses to remove an active/enabled service, symlinks, non-regular targets, or locally modified generated artifacts. It does not restore NetworkManager profiles or immediately reclaim interfaces; apply the host's intended network configuration deliberately afterward.

## R14 interaction and troubleshooting

R14 is an operator-driven acceptance/restoration transaction; R15 is normal deployed operation. R14 refuses to run while the persistent service is active, and the service refuses to start while an R14 checkpoint exists. Finish the active controller instead of deleting ownership state.

Inspect failures with:

```sh
sudo systemctl status --no-pager home-virtual-router.service
sudo journalctl -u home-virtual-router.service -b --no-pager
sudo make runtime-status
sudo make runtime-check
```

Failed initial startup remains a failed unit and retains canonical runtime diagnostics under `/run/home-virtual-router/runtime/`. Explicit restart remains safe through the existing runtime lock and idempotent convergence. R15 does not add automated package installation, configuration migration, continuous child watchdogs, upgrades, HA, or remote management; those are outside this stage and broader production polish belongs to R16.
