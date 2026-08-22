.PHONY: check test lab-info lab-create lab-destroy lab-status lab-test routing-enable routing-status routing-test routing-disable

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
