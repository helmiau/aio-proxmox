#!/bin/bash
# svc-cloudflared.sh — Cloudflare Tunnel lifecycle
# Source: https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/tunnel-guide/
# Install: curl + systemd
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/service-actions.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

SERVICE_NAME="cloudflared"
ACTION="${1:-status}"

# Config from ENV
CTID="${CLOUDFLARED_CTID:-105}"
HOSTNAME="${CLOUDFLARED_HOSTNAME:-cloudflared}"
IP="${CLOUDFLARED_IP:-10.10.40.50}"
TUNNEL_TOKEN="${CLOUDFLARED_TOKEN:-}"
TUNNEL_NAME="${CLOUDFLARED_TUNNEL_NAME:-homelab-tunnel}"
TUNNEL_ID="${CLOUDFLARED_TUNNEL_ID:-}"

# Paths
INSTALL_DIR="/opt/cloudflared"
CONFIG_DIR="/etc/cloudflared"
SERVICE_USER="cloudflared"

log_service() {
    log_info "[$SERVICE_NAME] $1"
}

ensure_user() {
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        log_service "Creating user $SERVICE_USER"
        useradd -m -s /bin/false "$SERVICE_USER"
    fi
}

install_cloudflared() {
    log_service "Installing cloudflared"
    mkdir -p "$INSTALL_DIR"
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" -o "$INSTALL_DIR/cloudflared"
    chmod +x "$INSTALL_DIR/cloudflared"
    ln -sf "$INSTALL_DIR/cloudflared" /usr/local/bin/cloudflared
}

create_config() {
    log_service "Creating config at $CONFIG_DIR/config.yml"
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/config.yml" <<EOF
# Cloudflare Tunnel config
tunnel: $TUNNEL_ID
credentials-file: $CONFIG_DIR/creds.json
metrics: 0.0.0.0:2000
no-autoupdate: true

ingress:
  - hostname: "*.nas.helminet.my.id"
    service: http://10.10.40.40:8081
  - hostname: "*.hermes.helminet.my.id"
    service: http://10.10.40.20:8000
  - service: http_status:404
EOF
}

create_creds() {
    log_service "Authenticating tunnel"
    if [[ -z "$TUNNEL_TOKEN" ]]; then
        log_error "CLOUDFLARED_TOKEN not set in ENVIRONMENT"
        exit 1
    fi
    cloudflared tunnel login --cred-file "$CONFIG_DIR/creds.json" --token "$TUNNEL_TOKEN"
}

create_systemd_service() {
    log_service "Creating systemd service"
    cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
ExecStart=/usr/local/bin/cloudflared tunnel --config $CONFIG_DIR/config.yml run
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
    allocate_resource "$IP" "2000" "cloudflared-metrics"
}

unregister_registry() {
    release_resource "$IP" "cloudflared-metrics"
}

action_install() {
    log_service "Starting install (mode: ${CLOUDFLARED_INSTALL_MODE:-host})"
    
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed, skipping"
        return 0
    fi

    ensure_user
    install_cloudflared
    create_config
    create_creds
    create_systemd_service

    log_service "Starting service"
    systemctl enable --now cloudflared

    register_registry
    mark_service_installed "$SERVICE_NAME"
    log_service "Install completed"
}

action_uninstall() {
    log_service "Uninstalling"
    
    systemctl disable --now cloudflared 2>/dev/null || true
    rm -f /etc/systemd/system/cloudflared.service
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

    install_cloudflared
    systemctl restart cloudflared
    log_service "Update completed"
}

action_status() {
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Status: INSTALLED"
        systemctl status cloudflared --no-pager || true
    else
        log_service "Status: NOT INSTALLED"
    fi
}

action_start() {
    systemctl start cloudflared
}

action_stop() {
    systemctl stop cloudflared
}

action_restart() {
    systemctl restart cloudflared
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
