#!/bin/bash
# svc-hermes-webui.sh — Hermes WebUI lifecycle (replaces Open WebUI)
# Source: https://github.com/nesquena/hermes-webui | https://get-hermes.ai
# Install: git clone + npm install + build (systemd managed)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/service-actions.sh"
source "$REPO_ROOT/lib/env-manager.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

SERVICE_NAME="hermes-webui"
ACTION="${1:-status}"

# Config from ENV
CTID="${HERMES_WEBUI_CTID:-103}"
HOSTNAME="${HERMES_WEBUI_HOSTNAME:-hermes-webui}"
IP="${HERMES_WEBUI_IP:-10.10.40.30}"
PORT="${HERMES_WEBUI_PORT:-3000}"
HOST="${HERMES_WEBUI_HOST:-0.0.0.0}"
DATA_DIR="${HERMES_WEBUI_DATA_DIR:-/var/lib/hermes-webui}"
AGENT_MODE="${HERMES_WEBUI_AGENT_MODE:-auto}"
AUTO_INSTALL="${HERMES_WEBUI_AUTO_INSTALL:-1}"
AGENT_DIR="${HERMES_WEBUI_AGENT_DIR:-}"
HOME_DIR="${HERMES_HOME_DIR:-/var/lib/hermes-webui/.hermes}"
CONFIG_PATH="${HERMES_CONFIG_PATH:-/var/lib/hermes-webui/.hermes/config.yaml}"

# Paths
INSTALL_DIR="/opt/hermes-webui"
SERVICE_USER="root"
PM2_NAME="hermes-webui"

log_service() {
    log_info "[$SERVICE_NAME] $1"
}

ensure_node() {
    if ! command -v node >/dev/null 2>&1; then
        log_service "Installing Node.js 20"
        curl -fsSL "https://deb.nodesource.com/setup_20.x" | bash -
        pkg_install nodejs
    fi
    log_service "Node.js $(node --version) ready"
}

ensure_pm2() {
    if ! command -v pm2 >/dev/null 2>&1; then
        log_service "Installing pm2 globally"
        npm install -g pm2
    fi
}

clone_repo() {
    log_service "Cloning hermes-webui"
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        cd "$INSTALL_DIR" && git pull
    else
        git clone https://github.com/nesquena/hermes-webui.git "$INSTALL_DIR"
    fi
}

install_deps() {
    log_service "Installing npm dependencies"
    cd "$INSTALL_DIR"
    npm ci
}

build_app() {
    log_service "Building application"
    cd "$INSTALL_DIR"
    npm run build
}

create_config() {
    log_service "Creating config at $CONFIG_PATH"
    mkdir -p "$(dirname "$CONFIG_PATH")"
    cat > "$CONFIG_PATH" <<EOF
webui:
  host: $HOST
  port: $PORT
  data_dir: $DATA_DIR
  agent_mode: $AGENT_MODE
  auto_install: $AUTO_INSTALL
  agent_dir: $AGENT_DIR
  home_dir: $HOME_DIR
EOF
}

create_pm2_ecosystem() {
    log_service "Creating pm2 ecosystem"
    cat > "$DATA_DIR/ecosystem.config.js" <<EOF
module.exports = {
  apps: [{
    name: '$PM2_NAME',
    script: '$INSTALL_DIR/dist/index.js',
    cwd: '$INSTALL_DIR',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '500M',
    env: {
      NODE_ENV: 'production',
      PORT: $PORT,
      HOST: '$HOST',
      DATA_DIR: '$DATA_DIR',
      HERMES_CONFIG_PATH: '$CONFIG_PATH'
    },
    error_file: '/var/log/homelab/hermes-webui-error.log',
    out_file: '/var/log/homelab/hermes-webui-out.log',
    log_file: '/var/log/homelab/hermes-webui-combined.log',
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
    log_service "Starting install (mode: ${HERMES_WEBUI_INSTALL_MODE:-ask})"
    
    # P8: Interactive prompt if ENV is DEFAULT
    prompt_service_env "HERMES_WEBUI"
    
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed, skipping"
        return 0
    fi

    ensure_node
    ensure_pm2
    clone_repo
    install_deps
    build_app
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

    rm -rf "$INSTALL_DIR"

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
    build_app
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
