#!/bin/bash
# svc-xui.sh — 3x-ui (Xray panel) lifecycle
# Source: https://github.com/MHSanaei/3x-ui
# Install: official install script (unattended)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/service-actions.sh"
source "$REPO_ROOT/lib/env-manager.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

SERVICE_NAME="xui"
ACTION="${1:-status}"

# Config from ENV
CTID="${XUI_CTID:-110}"
HOSTNAME="${XUI_HOSTNAME:-xui}"
IP="${XUI_IP:-10.10.40.100}"
PORT="${XUI_PORT:-2053}"
ADMIN_PASSWORD="${XUI_ADMIN_PASSWORD:-changeme123}"

# Paths
INSTALL_DIR="/usr/local/x-ui"
SERVICE_USER="root"

log_service() {
    log_info "[$SERVICE_NAME] $1"
}

install_xui() {
    log_service "Installing 3x-ui (unattended)"
    # Official install script with unattended flags
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<EOF
y
$ADMIN_PASSWORD
$PORT
EOF
}

register_registry() {
    allocate_resource "$IP" "$PORT" "$SERVICE_NAME"
}

unregister_registry() {
    release_resource "$IP" "$SERVICE_NAME"
}

action_install() {
    log_service "Starting install (mode: ${XUI_INSTALL_MODE:-ask})"
    
    # P8: Interactive prompt if ENV is DEFAULT
    prompt_service_env "XUI"
    
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed, skipping"
        return 0
    fi

    install_xui

    register_registry
    mark_service_installed "$SERVICE_NAME"
    log_service "Install completed"
}

action_uninstall() {
    log_service "Uninstalling"
    
    systemctl disable --now x-ui 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    rm -f /etc/systemd/system/x-ui.service
    systemctl daemon-reload

    unregister_registry
    
    local status_file="/var/lib/homelab/service_status.json"
    if [[ -f "$status_file" ]]; then
        jq --arg name "$SERVICE_NAME" 'del(.services[$name])' "$status_file" >"$status_file.tmp" && mv "$status_file.tmp" "$status_file"
    fi

    log_service "Uninstall completed"
}

action_update() {
    log_service "Updating"
    
    if ! is_service_installed "$SERVICE_NAME"; then
        log_service "Not installed, installing instead"
        action_install
        return
    fi

    # Re-run install script for update
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<EOF
y
$ADMIN_PASSWORD
$PORT
EOF
    log_service "Update completed"
}

action_status() {
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Status: INSTALLED"
        systemctl status x-ui --no-pager || true
    else
        log_service "Status: NOT INSTALLED"
    fi
}

action_start() {
    systemctl start x-ui
}

action_stop() {
    systemctl stop x-ui
}

action_restart() {
    systemctl restart x-ui
}

action_reinstall() {
    action_uninstall
    action_install
}

# Main dispatch
case "$ACTION" in
    install) action_install ;;
    uninstall) action_uninstall ;;
    update) action_update ;;
    reinstall) action_reinstall ;;
    status) action_status ;;
    start) action_start ;;
    stop) action_stop ;;
    restart) action_restart ;;
    *) log_error "Unknown action: $ACTION"; exit 1 ;;
esac
