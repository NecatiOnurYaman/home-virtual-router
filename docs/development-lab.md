# Isolated Linux development lab

Stage R1 uses the existing dedicated Ubuntu 26.04 LTS (`resolute`) virtual machine running under UTM on macOS. Ubuntu supplies the Linux kernel required by namespaces, nftables, and forwarding controls. UTM and the Ubuntu VM are not managed by this repository.

The Ubuntu VM is the host for a future lab made from Linux network namespaces; it is not itself treated as the router topology. Stage R1 does not create namespaces, enable forwarding, or configure router services.

## Safety boundary

Project scripts do not launch or control UTM and must never alter macOS networking. Future networking commands belong inside the Ubuntu VM and must use the shared guards in `router/scripts/safety.sh`, explicit `hvr-` namespace and interface names, and targeted cleanup.

The Ubuntu VM's ordinary UTM-facing interface and default route are infrastructure, not lab interfaces. Future namespace experiments must leave both unchanged. They must also avoid VM-host-wide nftables changes, including an unqualified `nft flush ruleset`. A later physical-deployment stage may define different requirements, but only when explicitly requested.

Before any future state-changing lab script is used, create the marker manually inside the dedicated VM:

```sh
sudo touch /etc/home-virtual-router-lab
```

The repository does not create this marker and cannot create it on macOS. Removing the marker disables the shared lab-environment guard.

`lab/config/defaults.env` is a data-only configuration file. Its simulated upstream is TEST-NET-1 (`192.0.2.0/24`), which is reserved for documentation, and its LAN is private address space. Stage R1 validates these values but does not apply them.

## Commands

- `make lab-info` reports the distribution, kernel, marker, dependencies, configured subnets, and future namespace presence without changing system state.
- `router/scripts/check-dependencies.sh` reports available and missing future tools without installing anything.

VM lifecycle and configuration remain explicit UTM administration tasks outside this repository. No project script performs automatic setup, teardown, or destructive networking cleanup at this stage.
