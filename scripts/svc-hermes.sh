#!/bin/bash
# svc-hermes.sh — Hermes Agent (+ MCP) lifecycle
# Source: https://github.com/nousresearch/hermes-agent
# Install: git clone + pip install (systemd managed)
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/service-actions.sh"
source "$REPO_ROOT/lib/env-manager.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

SERVICE_NAME="hermes"
ACTION="${1:-status}"

# Config from ENV
CTID="${HERMES_CTID:-102}"
HOSTNAME="${HERMES_HOSTNAME:-hermes-agent}"
IP="${HERMES_IP:-10.10.40.20}"
PORT="${HERMES_PORT:-8000}"
MCP_PORT="${HERMES_MCP_PORT:-8001}"
USER="${HERMES_USER:-hermes}"
OPENAI_BASE_URL="${HERMES_OPENAI_BASE_URL:-http://10.10.40.10:8787}"
MODEL_ID="${HERMES_MODEL_ID:-}"
SKIP_BROWSER="${HERMES_SKIP_BROWSER:-yes}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_ALLOWED_USER_IDS="${TELEGRAM_ALLOWED_USER_IDS:-}"

# Paths
INSTALL_DIR="/opt/hermes-agent"
VENV_DIR="$INSTALL_DIR/venv"
CONFIG_DIR="/var/lib/hermes-agent"
SERVICE_USER="$USER"

log_service() {
    log_info "[$SERVICE_NAME] $1"
}

ensure_user() {
    if ! id "$USER" >/dev/null 2>&1; then
        log_service "Creating user $USER"
        useradd -m -s /bin/bash "$USER"
    fi
}

ensure_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        log_service "Installing python3"
        pkg_update && pkg_install python3 python3-pip python3-venv
    fi
    # ensurepip (python3-venv) sering terpisah — install version-specific biar pasti
    if ! python3 -m ensurepip --version >/dev/null 2>&1; then
        log_service "ensurepip belum tersedia — menginstal python3-venv..."
        local pyver
        pyver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)"
        if [[ -n "$pyver" ]] && command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y "python${pyver}-venv" "python${pyver}-pip" 2>/dev/null || true
        fi
        pkg_update && pkg_install python3-venv python3-pip 2>/dev/null || true
        python3 -m ensurepip --version >/dev/null 2>&1 || \
            log_error "ensurepip masih tidak tersedia — coba manual: apt install python3.11-venv"
    fi
}

clone_repo() {
    log_service "Cloning hermes-agent"
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        cd "$INSTALL_DIR" && git pull
    else
        git clone https://github.com/nousresearch/hermes-agent.git "$INSTALL_DIR"
    fi
}

create_venv() {
    log_service "Creating virtual environment"
    if ! python3 -m venv "$VENV_DIR" 2>/dev/null; then
        log_warn "venv gagal — pastikan ensurepip; coba bootstrap pip manual"
        python3 -m ensurepip --upgrade 2>/dev/null || true
        python3 -m venv "$VENV_DIR" || { log_error "Gagal membuat venv di $VENV_DIR"; return 1; }
    fi
    "$VENV_DIR/bin/pip" install --upgrade pip setuptools wheel
}

install_deps() {
    log_service "Installing dependencies"
    cd "$INSTALL_DIR"
    "$VENV_DIR/bin/pip" install -e . --break-system-packages 2>/dev/null || \
    "$VENV_DIR/bin/pip" install -r requirements.txt --break-system-packages 2>/dev/null || \
    "$VENV_DIR/bin/pip" install hermes-agent --break-system-packages
}

create_config() {
    log_service "Creating config at $HERMES_CONFIG_DIR"
    mkdir -p "$HERMES_CONFIG_DIR"
    cat > "$HERMES_CONFIG_DIR/config.yaml" <<EOF
agent:
  host: 0.0.0.0
  port: $PORT
  mcp_port: $MCP_PORT
  skip_browser: $SKIP_BROWSER
  model_id: $MODEL_ID
  openai_base_url: $OPENAI_BASE_URL
telegram:
  bot_token: $TELEGRAM_BOT_TOKEN
  allowed_user_ids: $TELEGRAM_ALLOWED_USER_IDS
EOF
}

create_systemd_service() {
    log_service "Creating systemd service"
    cat > /etc/systemd/system/hermes-agent.service <<EOF
[Unit]
Description=Hermes Agent + MCP
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR
Environment=HERMES_CONFIG_DIR=$HERMES_CONFIG_DIR
Environment=HERMES_HOST=0.0.0.0
Environment=HERMES_PORT=$PORT
Environment=HERMES_MCP_PORT=$MCP_PORT
ExecStart=$VENV_DIR/bin/hermes-agent serve --config $HERMES_CONFIG_DIR/config.yaml
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
    allocate_resource "$IP" "$MCP_PORT" "${SERVICE_NAME}-mcp"
}

unregister_registry() {
    release_resource "$IP" "$SERVICE_NAME"
    release_resource "$IP" "${SERVICE_NAME}-mcp"
}

action_install() {
    log_service "Starting install (mode: ${HERMES_INSTALL_MODE:-ask})"
    
    # P8: Interactive prompt if ENV is DEFAULT
    prompt_service_env "HERMES"
    
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed, skipping"
        return 0
    fi

    ensure_user
    ensure_python
    clone_repo
    create_venv
    install_deps
    create_config
    create_systemd_service

    log_service "Starting service"
    systemctl enable --now hermes-agent

    register_registry
    mark_service_installed "$SERVICE_NAME"
    log_service "Install completed"
}

action_uninstall() {
    log_service "Uninstalling"
    
    systemctl disable --now hermes-agent 2>/dev/null || true
    rm -f /etc/systemd/system/hermes-agent.service
    systemctl daemon-reload

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
    systemctl restart hermes-agent
    log_service "Update completed"
}

action_status() {
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Status: INSTALLED"
        systemctl status hermes-agent --no-pager || true
    else
        log_service "Status: NOT INSTALLED"
    fi
}

action_start() {
    systemctl start hermes-agent
}

action_stop() {
    systemctl stop hermes-agent
}

action_restart() {
    systemctl restart hermes-agent
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
