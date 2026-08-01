#!/bin/bash
# svc-mihomo.sh — Mihomo (Clash.Meta) lifecycle
# Source: https://github.com/MetaCubeX/mihomo
# Install: binary download + systemd
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/service-actions.sh"
source "$REPO_ROOT/lib/env-manager.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

SERVICE_NAME="mihomo"
ACTION="${1:-status}"

# Config from ENV
CTID="${MIHOMO_CTID:-107}"
HOSTNAME="${MIHOMO_HOSTNAME:-mihomo}"
IP="${MIHOMO_IP:-10.10.40.70}"
PORT="${MIHOMO_PORT:-7890}"
UI_PORT="${MIHOMO_UI_PORT:-9090}"
CONFIG_URL="${MIHOMO_CONFIG_URL:-}"

# Paths
INSTALL_DIR="/opt/mihomo"
CONFIG_DIR="/etc/mihomo"
SERVICE_USER="mihomo"

log_service() {
    log_info "[$SERVICE_NAME] $1"
}

ensure_user() {
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        log_service "Creating user $SERVICE_USER"
        useradd -m -s /bin/false "$SERVICE_USER"
    fi
}

install_mihomo() {
    log_service "Installing Mihomo"
    mkdir -p "$INSTALL_DIR"
    local arch="amd64"
    [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
    curl -fsSL "https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-${arch}-v1.18.0.gz" | gunzip -c > "$INSTALL_DIR/mihomo"
    chmod +x "$INSTALL_DIR/mihomo"
    ln -sf "$INSTALL_DIR/mihomo" /usr/local/bin/mihomo
}

create_config() {
    log_service "Creating config at $CONFIG_DIR/config.yaml"
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/config.yaml" <<EOF
port: $PORT
socks-port: $PORT
mixed-port: $PORT
allow-lan: true
mode: rule
log-level: info
external-controller: 0.0.0.0:$UI_PORT
secret: ""
dns:
  enable: true
  listen: 0.0.0.0:53
  enhanced-mode: fake-ip
  nameserver:
    - 1.1.1.1
    - 8.8.8.8
proxies: []
proxy-groups: []
rules: []
EOF
}

create_systemd_service() {
    log_service "Creating systemd service"
    cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=Mihomo (Clash.Meta)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
ExecStart=/usr/local/bin/mihomo -d $CONFIG_DIR
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
    allocate_resource "$IP" "$UI_PORT" "${SERVICE_NAME}-ui"
}

unregister_registry() {
    release_resource "$IP" "$SERVICE_NAME"
    release_resource "$IP" "${SERVICE_NAME}-ui"
}

action_install() {
    log_service "Starting install (mode: ${MIHOMO_INSTALL_MODE:-host})"    
    # P8: Interactive prompt if ENV is DEFAULT
    prompt_service_env "MIHOMO"    
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed, skipping"
        return 0
    fi

    ensure_user
    install_mihomo
    create_config
    create_systemd_service

    log_service "Starting service"
    systemctl enable --now mihomo

    register_registry
    mark_service_installed "$SERVICE_NAME"
    log_service "Install completed"
}

action_uninstall() {
    log_service "Uninstalling"
    
    systemctl disable --now mihomo 2>/dev/null || true
    rm -f /etc/systemd/system/mihomo.service
    systemctl daemon-reload

    rm -rf "$INSTALL_DIR"
    rm -rf "$CONFIG_DIR"

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

    install_mihomo
    systemctl restart mihomo
    log_service "Update completed"
}

action_status() {
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Status: INSTALLED"
        systemctl status mihomo --no-pager || true
    else
        log_service "Status: NOT INSTALLED"
    fi
}

action_start() {
    systemctl start mihomo
}

action_stop() {
    systemctl stop mihomo
}

action_restart() {
    systemctl restart mihomo
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
