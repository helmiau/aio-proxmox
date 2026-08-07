# Makefile — aio-proxmox v4.2.5 (Proxmox Services Manager)

.PHONY: all lint test clean

all: lint test

# P13: show version
version:
	@bash -c 'source lib/common.sh && echo "aio-proxmox $$(get_script_version)"'

lint:
	shellcheck -x scripts/*.sh lib/*.sh

# ponytail: bats tests when ready; lint-only for now
test:
	echo "TODO: bats tests"

clean:
	rm -rf /tmp/homelab-* /var/log/homelab/*.log

# Quick run
run:
	bash install

# Upgrade Debian standalone
upgrade:
	bash scripts/upgrade-debian.sh

# Repair Proxmox
repair:
	bash scripts/03-install-proxmox-ve9.sh repair
