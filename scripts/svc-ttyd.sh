#!/bin/bash
# svc-ttyd.sh — ttyd lifecycle
# Source: https://github.com/tsl0922/ttyd
# Install: apt or build from source + systemd
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/service-actions.sh"
source "$REPO_ROOT/lib/env-manager.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

SERVICE_NAME="ttyd"
ACTION="${1:-status}"

# Config from ENV
CTID="${TTYD_CTID:-109}"
HOSTNAME="${TTYD_HOSTNAME:-ttyd}"
IP="${TTYD_IP:-10.10.40.90}"
PORT="${TTYD_PORT:-7681}"
SHELL="${TTYD_SHELL:-/bin/bash}"

# Paths
INSTALL_DIR="/opt/ttyd"
SERVICE_USER="ttyd"

log_service() {
    log_info "[$SERVICE_NAME] $1"
}

ensure_user() {
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        log_service "Creating user $SERVICE_USER"
        useradd -m -s /bin/false "$SERVICE_USER"
    fi
}

install_ttyd() {
    log_service "Installing ttyd"
    pkg_update
    pkg_install ttyd
}

create_systemd_service() {
    log_service "Creating systemd service"
    cat > /etc/systemd/system/ttyd.service <<EOF
[Unit]
Description=ttyd - Web Terminal
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
ExecStart=/usr/bin/ttyd -W -p $PORT $SHELL
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

register_registry() {
    allocate_resource "$IP" "$PORT" "$SERVICE_NAME"
}

unregister_registry() {
    release_resource "$IP" "$SERVICE_NAME"
}

action_install() {
    log_service "Starting install (mode: ${TTYD_INSTALL_MODE:-host})"    
    # P8: Interactive prompt if ENV is DEFAULT
    prompt_service_env "TTYD"    
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed, skipping"
        return 0
    fi

    ensure_user
    install_ttyd
    create_systemd_service

    log_service "Starting service"
    svc_enable ttyd
    svc_start ttyd

    register_registry
    mark_service_installed "$SERVICE_NAME"
    log_service "Install completed"
}

action_uninstall() {
    log_service "Uninstalling"
    
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now ttyd 2>/dev/null || true
        rm -f /etc/systemd/system/ttyd.service
        systemctl daemon-reload
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service ttyd stop 2>/dev/null || true
        rc-update del ttyd default 2>/dev/null || true
        rm -f /etc/init.d/ttyd
    fi

    pkg_remove ttyd 2>/dev/null || true

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

    pkg_upgrade ttyd
    svc_start ttyd
    log_service "Update completed"
}

action_status() {
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Status: INSTALLED"
        systemctl status ttyd --no-pager || true
    else
        log_service "Status: NOT INSTALLED"
    fi
}

action_start() {
    systemctl start ttyd
}

action_stop() {
    systemctl stop ttyd
}

action_restart() {
    systemctl restart ttyd
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
