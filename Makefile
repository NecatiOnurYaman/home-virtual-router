.PHONY: check test lab-info lab-create lab-destroy lab-status lab-test routing-enable routing-status routing-test routing-disable nat-enable nat-status nat-test nat-disable firewall-enable firewall-status firewall-test firewall-disable dhcp-enable dhcp-status dhcp-test dhcp-disable dns-enable dns-disable dns-test

check:
	@bash -n router/scripts/*.sh lab/scripts/*.sh tests/*.sh
	@python3 router/scripts/validate_config.py lab/config/defaults.env

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
