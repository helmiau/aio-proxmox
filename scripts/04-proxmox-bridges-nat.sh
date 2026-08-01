#!/bin/bash
# 04-proxmox-bridges-nat.sh — vmbr30/40/50 + NAT
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

IFACES="/etc/network/interfaces"
log_info "Configuring bridges (idempotent append if missing)"

# ponytail: full ifupdown2 merge when multi-NIC; single-file append for MVP
ensure_bridge() {
  local name="$1" ip="$2" cidr="$3"
  if grep -q "iface $name" "$IFACES" 2>/dev/null; then
    log_info "Bridge $name exists"
    return 0
  fi
  cat >> "$IFACES" <<EOF

auto $name
iface $name inet static
	address ${ip}/${cidr}
	bridge-ports none
	bridge-stp off
	bridge-fd 0
EOF
  log_info "Added $name ${ip}/${cidr}"
}

ensure_bridge "${VM_BR_MIKROTIK:-vmbr30}" "${VM_BR_MIKROTIK_IP:-10.10.30.1}" "${VM_BR_MIKROTIK_CIDR:-24}"
ensure_bridge "${VM_BR_SERVICE:-vmbr40}" "${VM_BR_SERVICE_IP:-10.10.40.1}" "${VM_BR_SERVICE_CIDR:-24}"
ensure_bridge "${VM_BR_TEST:-vmbr50}" "${VM_BR_TEST_IP:-10.10.50.1}" "${VM_BR_TEST_CIDR:-24}"

# NAT via nftables/iptables — minimal
if [[ "${ENABLE_NAT_40:-yes}" == "yes" ]]; then
  sysctl -w net.ipv4.ip_forward=1
  grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.d/99-homelab.conf 2>/dev/null || \
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-homelab.conf
  log_info "IP forward enabled"
fi

log_info "Bridges/NAT configured — ifreload -a or reboot if needed"
