#!/bin/bash
# svc-copyparty.sh — CopyParty lifecycle
# Source: https://github.com/9001/copyparty
# Install: git clone + npm install + systemd
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/service-actions.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

SERVICE_NAME="copyparty"
ACTION="${1:-status}"

# Config from ENV
CTID="${COPYPARTY_CTID:-106}"
HOSTNAME="${COPYPARTY_HOSTNAME:-copyparty}"
IP="${COPYPARTY_IP:-10.10.40.60}"
PORT="${COPYPARTY_PORT:-8082}"
PASSWORD="${COPYPARTY_PASSWORD:-changeme123}"

# Paths
INSTALL_DIR="/opt/copyparty"
CONFIG_DIR="/etc/copyparty"
SERVICE_USER="copyparty"

log_service() {
    log_info "[$SERVICE_NAME] $1"
}

ensure_user() {
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        log_service "Creating user $SERVICE_USER"
        useradd -m -s /bin/false "$SERVICE_USER"
    fi
}

install_node() {
    if ! command -v node >/dev/null 2>&1; then
        log_service "Installing Node.js"
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    fi
}

clone_repo() {
    log_service "Cloning copyparty"
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        cd "$INSTALL_DIR" && git pull
    else
        git clone https://github.com/9001/copyparty.git "$INSTALL_DIR"
    fi
}

install_deps() {
    log_service "Installing npm dependencies"
    cd "$INSTALL_DIR"
    npm install
}

create_config() {
    log_service "Creating config at $CONFIG_DIR/config.json"
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/config.json" <<EOF
{
  "port": $PORT,
  "password": "$PASSWORD",
  "root": "/srv/storage",
  "log": "/var/log/copyparty.log",
  "logLevel": "info",
  "allowUpload": true,
  "allowDelete": true,
  "allowCreate": true,
  "allowRename": true
}
EOF
}

create_systemd_service() {
    log_service "Creating systemd service"
    cat > /etc/systemd/system/copyparty.service <<EOF
[Unit]
Description=CopyParty
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/node $INSTALL_DIR/copyparty.js --config $CONFIG_DIR/config.json
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
    log_service "Starting install (mode: ${COPYPARTY_INSTALL_MODE:-ask})"
    
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed, skipping"
        return 0
    fi

    ensure_user
    install_node
    clone_repo
    install_deps
    create_config
    create_systemd_service

    log_service "Starting service"
    systemctl enable --now copyparty

    register_registry
    mark_service_installed "$SERVICE_NAME"
    log_service "Install completed"
}

action_uninstall() {
    log_service "Uninstalling"
    
    systemctl disable --now copyparty 2>/dev/null || true
    rm -f /etc/systemd/system/copyparty.service
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

    cd "$INSTALL_DIR" && git pull
    install_deps
    systemctl restart copyparty
    log_service "Update completed"
}

action_status() {
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Status: INSTALLED"
        systemctl status copyparty --no-pager || true
    else
        log_service "Status: NOT INSTALLED"
    fi
}

action_start() {
    systemctl start copyparty
}

action_stop() {
    systemctl stop copyparty
}

action_restart() {
    systemctl restart copyparty
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
