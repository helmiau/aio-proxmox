#!/bin/bash
# svc-9router.sh — 9Router AI API Gateway lifecycle
# Source: https://github.com/decolua/9router | npm: 9router
# Install: npm install -g 9router (pm2 managed)
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/service-actions.sh"
source "$REPO_ROOT/lib/env-manager.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

SERVICE_NAME="9router"
ACTION="${1:-status}"

# Config from ENV
CTID="${ROUTER9_CTID:-101}"
HOSTNAME="${ROUTER9_HOSTNAME:-9router}"
IP="${ROUTER9_IP:-10.10.40.10}"
PORT="${ROUTER9_PORT:-20128}"
DATA_DIR="${ROUTER9_DATA_DIR:-/var/lib/9router}"
NPM_PACKAGE="${ROUTER9_NPM_PACKAGE:-9router}"
NODE_MAJOR="${NODE_MAJOR:-22}"
BASE_URL="${ROUTER9_BASE_URL:-https://ai.example.com}"
CLOUDFLARE_TUNNEL="${ROUTER9_CLOUDFLARE_TUNNEL:-no}"

# Paths
SERVICE_USER="root"
INSTALL_DIR="/usr/lib/node_modules/$NPM_PACKAGE"
PM2_NAME="9router"

ensure_curl

log_service() {
    log_info "[$SERVICE_NAME] $1"
}

ensure_node() {
    if ! command -v node >/dev/null 2>&1; then
        log_service "Installing Node.js $NODE_MAJOR"
        # Container minimal sering tanpa curl/ca-certificates — pastikan dulu
        if command -v apk >/dev/null 2>&1; then
            pkg_install nodejs npm curl ca-certificates
        else
            pkg_install curl ca-certificates gnupg 2>/dev/null || true
            curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
            pkg_install nodejs
        fi
    fi
    log_service "Node.js $(node --version) ready"
}

ensure_pm2() {
    if ! command -v pm2 >/dev/null 2>&1; then
        log_service "Installing pm2 globally"
        npm install -g pm2
    fi
}

create_config() {
    log_service "Creating config at $DATA_DIR/config.json"
    mkdir -p "$DATA_DIR"
    cat > "$DATA_DIR/config.json" <<EOF
{
  "port": $PORT,
  "host": "0.0.0.0",
  "baseUrl": "$BASE_URL",
  "dataDir": "$DATA_DIR",
  "logLevel": "info"
}
EOF
}

create_pm2_ecosystem() {
    log_service "Creating pm2 ecosystem"
    cat > "$DATA_DIR/ecosystem.config.js" <<EOF
module.exports = {
  apps: [{
    name: '$PM2_NAME',
    script: '$INSTALL_DIR/app/server.js',
    cwd: '$INSTALL_DIR/app',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '500M',
    env: {
      NODE_ENV: 'production',
      PORT: $PORT,
      DATA_DIR: '$DATA_DIR',
      BASE_URL: '$BASE_URL'
    },
    error_file: '/var/log/homelab/9router-error.log',
    out_file: '/var/log/homelab/9router-out.log',
    log_file: '/var/log/homelab/9router-combined.log',
    time: true
  }]
};
EOF
}

register_registry() {
    allocate_resource "$IP" "$PORT" "$SERVICE_NAME"
}

unregister_registry() {
    release_resource "$IP" "$SERVICE_NAME"
}

action_install() {
    log_service "Starting install (mode: ${ROUTER9_INSTALL_MODE:-ask})"
    
    # P8: Interactive prompt if ENV is DEFAULT
    prompt_service_env "9ROUTER"
    
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed, skipping"
        return 0
    fi

    ensure_node
    ensure_pm2

    log_service "Installing npm package: $NPM_PACKAGE"
    npm install -g "$NPM_PACKAGE"

    create_config
    create_pm2_ecosystem

    log_service "Starting via pm2"
    pm2 start "$DATA_DIR/ecosystem.config.js"
    pm2 save
    pm2 startup systemd -u "$SERVICE_USER" --hp "/root" || true

    register_registry
    mark_service_installed "$SERVICE_NAME"
    log_service "Install completed"
}

action_uninstall() {
    log_service "Uninstalling"
    
    pm2 delete "$PM2_NAME" 2>/dev/null || true
    pm2 save

    npm uninstall -g "$NPM_PACKAGE" 2>/dev/null || true

    unregister_registry
    
    # Remove from status
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

    ensure_node
    npm update -g "$NPM_PACKAGE"

    pm2 reload "$PM2_NAME"
    log_service "Update completed"
}

action_status() {
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Status: INSTALLED"
        pm2 list | grep -E "$PM2_NAME|name" || true
    else
        log_service "Status: NOT INSTALLED"
    fi
}

action_start() {
    pm2 start "$PM2_NAME" 2>/dev/null || pm2 start "$DATA_DIR/ecosystem.config.js"
}

action_stop() {
    pm2 stop "$PM2_NAME" 2>/dev/null || true
}

action_restart() {
    pm2 restart "$PM2_NAME" 2>/dev/null || action_start
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
