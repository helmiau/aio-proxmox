#!/bin/bash
# 01-debian-base.sh — base packages + tuning (clean or semi-configured Debian)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

export DEBIAN_FRONTEND=noninteractive
PKGS=(curl wget git jq ca-certificates gnupg lsb-release sudo openssh-server
      htop iotop net-tools dnsutils rsync unzip tar zstd)

log_info "Installing base packages (idempotent)"
apt-get update -y
apt-get install -y "${PKGS[@]}"

# Optional: upgrade path
if [[ "${DEBIAN_UPGRADE_ENABLED:-yes}" == "yes" ]]; then
  bash "$SCRIPT_DIR/upgrade-debian.sh" || log_warn "upgrade-debian non-fatal"
fi

log_info "Debian base done"
