#!/bin/bash
# upgrade-debian.sh — Debian 13.x → target (default 13.6.0)
# P9: run standalone OR called from install flow
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/logging.sh
source "$REPO_ROOT/lib/logging.sh"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"
TARGET="${DEBIAN_TARGET_VERSION:-13.6.0}"
REBOOT_MODE="${DEBIAN_UPGRADE_REBOOT:-ask}"

current_ver() {
  if [[ -f /etc/debian_version ]]; then
    cat /etc/debian_version
  else
    echo "unknown"
  fi
}

CUR="$(current_ver)"
log_info "Debian current=$CUR target=$TARGET"

if [[ "${DEBIAN_UPGRADE_ENABLED:-yes}" != "yes" ]]; then
  log_info "DEBIAN_UPGRADE_ENABLED!=yes — skip"
  exit 0
fi

# ponytail: full point-release pin when apt pinning needed; for now dist-upgrade
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get dist-upgrade -y
apt-get autoremove -y
apt-get autoclean -y

NEW="$(current_ver)"
log_info "Debian after upgrade=$NEW"

case "$REBOOT_MODE" in
  yes) log_warn "Reboot required — reboot now"; reboot ;;
  ask)
    read -r -p "Reboot now? [y/N] " a
    [[ "$a" =~ ^[yY]$ ]] && reboot || log_info "Reboot later"
    ;;
  no) log_info "Reboot skipped (DEBIAN_UPGRADE_REBOOT=no)" ;;
esac
