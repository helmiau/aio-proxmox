# Makefile — aio-proxmox v4.0

.PHONY: all lint test clean

all: lint test

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
