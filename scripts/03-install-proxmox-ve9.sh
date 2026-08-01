#!/bin/bash
# 03-install-proxmox-ve9.sh — install OR repair Proxmox VE 9 on Debian 13
# P10: repair preserves LXC/VM when PROXMOX_REPAIR_PRESERVE_*=yes
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

export DEBIAN_FRONTEND=noninteractive
MODE="${1:-install}"  # install|repair|reinstall

pve_installed() {
  command -v pveversion >/dev/null 2>&1
}

install_pve_repos() {
  log_info "Adding Proxmox VE 9 repos"
  # ponytail: pin exact repo lines from official PVE9-on-Debian docs when published
  echo "deb [arch=amd64] http://download.proxmox.com/debian/pve trixie pve-no-subscription" \
    > /etc/apt/sources.list.d/pve-install.list
  wget -qO /etc/apt/trusted.gpg.d/proxmox-release.gpg \
    https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg || true
  apt-get update -y
}

install_pve_packages() {
  log_info "Installing proxmox-ve"
  apt-get install -y proxmox-ve postfix open-iscsi chrony || {
    log_error "proxmox-ve install failed — check repos/kernel"
    return 1
  }
}

case "$MODE" in
  install)
    if pve_installed; then
      log_info "PVE already installed: $(pveversion 2>/dev/null || true)"
      exit 0
    fi
    install_pve_repos
    install_pve_packages
    log_warn "REBOOT required after PVE install"
    ;;
  repair|reinstall)
    if [[ "${PROXMOX_REPAIR_ENABLED:-yes}" != "yes" ]]; then
      log_error "PROXMOX_REPAIR_ENABLED!=yes"
      exit 1
    fi
    log_warn "PVE $MODE — preserve LXC=${PROXMOX_REPAIR_PRESERVE_LXC:-yes} VM=${PROXMOX_REPAIR_PRESERVE_VM:-yes}"
    # Data under /var/lib/vz, /etc/pve (if cluster FS ok) kept; reinstall packages only
    install_pve_repos
    apt-get install -y --reinstall proxmox-ve pve-manager qemu-server lxc-pve || true
    systemctl restart pveproxy pvedaemon pvestatd pvescheduler 2>/dev/null || true
    # Verify services are running
    if ! systemctl is-active --quiet pveproxy pvedaemon pvestatd pvescheduler 2>/dev/null; then
        log_warn "Some Proxmox services may not be running properly"
        log_info "PVE $MODE done — verify: pveversion; pct list; qm list"
    else
        log_info "PVE $MODE done — verify: pveversion; pct list; qm list"
    fi
    ;;
  *)
    log_error "Usage: $0 [install|repair|reinstall]"
    exit 1
    ;;
esac
