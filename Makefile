.PHONY: check test lab-info lab-create lab-destroy lab-status lab-test routing-enable routing-status routing-test routing-disable nat-enable nat-status nat-test nat-disable firewall-enable firewall-status firewall-test firewall-disable dhcp-enable dhcp-status dhcp-test dhcp-disable dns-enable dns-disable dns-test ipfix-enable ipfix-disable ipfix-test observability-enable observability-disable integration-test metrics-show metrics-test metrics-export-enable metrics-export-disable metrics-export-status metrics-export-test runtime-start runtime-stop runtime-restart runtime-status runtime-check runtime-test physical-check physical-sim-test physical-hardware-check physical-hardware-test-start physical-hardware-test-observe-nat physical-hardware-test-observe-firewall physical-hardware-test-verify physical-hardware-test-stop physical-hardware-test-post-reboot systemd-show

check:
	@bash -n router/scripts/*.sh lab/scripts/*.sh physical/scripts/*.sh tests/*.sh
	@python3 router/scripts/validate_config.py lab/config/defaults.env
	@python3 router/scripts/validate_config.py config/physical.example.env

test:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py' -v

lab-info:
	@lab/scripts/lab-info.sh

lab-create:
	@echo "Creating the isolated R2 topology requires root inside the Ubuntu UTM VM."
	sudo lab/scripts/create-topology.sh

lab-destroy:
	@echo "Destroying the exact allowlisted R2 topology requires root inside the Ubuntu UTM VM."
	sudo lab/scripts/destroy-topology.sh

lab-status:
	@echo "Inspecting namespace details requires root inside the Ubuntu UTM VM."
	sudo lab/scripts/topology-status.sh

lab-test:
	@echo "Testing namespace connectivity requires root inside the Ubuntu UTM VM."
	sudo lab/scripts/test-topology.sh

routing-enable:
	@echo "Enabling R3 routing inside the lab namespaces requires root."
	sudo lab/scripts/enable-routing.sh

routing-status:
	@echo "Inspecting R3 namespace routing state requires root."
	sudo lab/scripts/topology-status.sh

routing-test:
	@echo "Testing R3 routed connectivity inside the namespaces requires root."
	sudo lab/scripts/test-routing.sh

routing-disable:
	@echo "Removing only exact R3 namespace routing state requires root."
	sudo lab/scripts/disable-routing.sh

nat-enable:
	@echo "Enabling R4 masquerading inside hvr-router requires root."
	sudo lab/scripts/enable-nat.sh

nat-status:
	@echo "Inspecting R4 namespace NAT state requires root."
	sudo lab/scripts/topology-status.sh

nat-test:
	@echo "Testing R4 masquerading inside the isolated namespaces requires root."
	sudo lab/scripts/test-nat.sh

nat-disable:
	@echo "Removing only the project R4 NAT table and restoring R3 requires root."
	sudo lab/scripts/disable-nat.sh

firewall-enable:
	@echo "Enabling the R5 stateful forwarding firewall inside hvr-router requires root."
	sudo lab/scripts/enable-firewall.sh

firewall-status:
	@echo "Inspecting the R5 namespace firewall and counters requires root."
	sudo lab/scripts/topology-status.sh

firewall-test:
	@echo "Testing R5 stateful forwarding policy inside the isolated namespaces requires root."
	sudo lab/scripts/test-firewall.sh

firewall-disable:
	@echo "Deleting only the project R5 filter table requires root."
	sudo lab/scripts/disable-firewall.sh

dhcp-enable:
	@echo "Starting project DHCP inside hvr-router and leasing hvr-client requires root."
	sudo lab/scripts/enable-dhcp.sh

dhcp-status:
	@echo "Inspecting project DHCP process, address, and lease state requires root."
	sudo lab/scripts/topology-status.sh

dhcp-test:
	@echo "Testing the R6 dynamic client lease and connectivity requires root."
	sudo lab/scripts/test-dhcp.sh

dhcp-disable:
	@echo "Stopping only project DHCP state and restoring the R5 static client requires root."
	sudo lab/scripts/disable-dhcp.sh

dns-enable:
	@echo "Enabling isolated R7 DNS forwarding, caching, and query logging requires root."
	sudo lab/scripts/enable-dns.sh

dns-disable:
	@echo "Returning dnsmasq to R6 DHCP-only mode while preserving the current lease requires root."
	sudo lab/scripts/disable-dns.sh

dns-test:
	@echo "Testing R7 UDP/TCP DNS forwarding, cache behavior, and logs requires root."
	sudo lab/scripts/test-dns.sh

ipfix-enable:
	@echo "Starting the R8 IPFIX v10 exporter inside hvr-router requires root."
	sudo lab/scripts/enable-ipfix.sh

ipfix-test:
	@echo "Validating R8 IPFIX templates, records, and pre-NAT client identity requires root."
	sudo lab/scripts/test-ipfix.sh

ipfix-disable:
	@echo "Stopping only the project R8 exporter while preserving R7 requires root."
	sudo lab/scripts/disable-ipfix.sh

observability-enable:
	@echo "Creating the isolated R9 router-to-host telemetry link requires root."
	sudo lab/scripts/enable-observability.sh

observability-disable:
	@echo "Removing only the isolated R9 telemetry link requires root."
	sudo lab/scripts/disable-observability.sh

integration-test:
	@echo "Running the R9 real-telemetry acceptance test requires root and an already-running observability backend."
	sudo lab/scripts/test-observability-integration.sh

metrics-show:
	@echo "Collecting one read-only R10 snapshot inside hvr-router requires root. Output follows as JSON." >&2
	@sudo lab/scripts/show-metrics.sh

metrics-test:
	@echo "Validating R10 interface counters with isolated routed traffic requires root."
	sudo lab/scripts/test-metrics.sh

metrics-export-enable:
	@echo "Starting the R11 router metrics HTTP exporter requires root."
	sudo lab/scripts/enable-metrics-export.sh

metrics-export-disable:
	@echo "Stopping only the exact R11 exporter process requires root."
	sudo lab/scripts/disable-metrics-export.sh

metrics-export-status:
	@echo "Inspecting R11 exporter identity and target requires root."
	sudo lab/scripts/status-metrics-export.sh

metrics-export-test:
	@echo "Testing real R11 HTTP pushes across the isolated namespaces requires root."
	sudo lab/scripts/test-metrics-export.sh

runtime-start:
	@echo "Converging the complete R12 lab runtime requires root."
	sudo lab/scripts/runtime-start.sh

runtime-stop:
	@echo "Stopping only stages recorded as R12-owned requires root."
	sudo lab/scripts/runtime-stop.sh

runtime-restart:
	@echo "Restarting the R12-owned runtime requires root."
	sudo lab/scripts/runtime-restart.sh

runtime-status:
	@sudo lab/scripts/runtime-status.sh

runtime-check:
	@sudo lab/scripts/runtime-check.sh

runtime-test:
	@echo "Running the bounded R12 lifecycle acceptance requires root."
	sudo lab/scripts/test-runtime.sh

physical-check:
	@echo "Running the read-only R13 physical deployment preflight requires root."
	sudo physical/scripts/preflight.sh

physical-sim-test:
	@echo "Running R13 physical logic in isolated Linux namespaces requires root."
	sudo physical/scripts/test-simulation.sh

physical-hardware-check:
	@echo "R14 REAL HARDWARE READ-ONLY CHECK: configured WAN/LAN NICs will be inspected, not changed."
	sudo physical/scripts/hardware-check.sh

physical-hardware-test-start:
	@echo "R14 REAL HARDWARE VALIDATION: this modifies the two explicitly configured physical NICs."
	sudo physical/scripts/hardware-test.sh start

physical-hardware-test-observe-nat:
	@echo "R14 NAT observation: generate the documented client traffic during this bounded capture."
	sudo physical/scripts/hardware-test.sh observe-nat --client-ip "$(R14_CLIENT_IP)" --target "$(R14_UPSTREAM_TARGET)"

physical-hardware-test-observe-firewall:
	@echo "R14 firewall observation: send the documented controlled upstream probe during this bounded capture."
	sudo physical/scripts/hardware-test.sh observe-firewall --client-ip "$(R14_CLIENT_IP)" --upstream-peer "$(R14_UPSTREAM_PEER)"

physical-hardware-test-verify:
	@echo "R14 verification requires real-client identity and decoded IPFIX evidence."
	sudo physical/scripts/hardware-test.sh verify --client-mac "$(R14_CLIENT_MAC)" --client-ip "$(R14_CLIENT_IP)" --target "$(R14_UPSTREAM_TARGET)" --ipfix-result "$(R14_IPFIX_RESULT)"

physical-hardware-test-stop:
	@echo "R14 stopping only the recorded HVR runtime and verifying restoration."
	sudo physical/scripts/hardware-test.sh stop

physical-hardware-test-post-reboot:
	@echo "R14 post-reboot validation never initiates reboot or changes persistence."
	sudo physical/scripts/hardware-post-reboot.sh

systemd-show:
	@python3 router/scripts/render_systemd_unit.py "$(CURDIR)"
