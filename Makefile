.PHONY: check test lab-info

check:
	@bash -n router/scripts/*.sh lab/scripts/*.sh tests/*.sh
	@python3 router/scripts/validate_config.py lab/config/defaults.env

test:
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py' -v

lab-info:
	@lab/scripts/lab-info.sh
