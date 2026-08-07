#!/bin/bash
# svc-headroom.sh — Headroom AI Context Compression lifecycle
# Source: https://github.com/headroomlabs-ai/headroom
# Install: pip install "headroom-ai[proxy,code,ml,mcp]" --break-system-packages
# Default: co-located with 9Router (same CTID/IP)
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/service-actions.sh"
source "$REPO_ROOT/lib/env-manager.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

SERVICE_NAME="headroom"
ACTION="${1:-status}"

# Config from ENV (co-located with 9Router by default)
def_r9_ctid="${ROUTER9_CTID:-101}"
CTID="${HEADROOM_CTID:-$def_r9_ctid}"
HOSTNAME="${HEADROOM_HOSTNAME:-headroom}"
# 2-step: fallback ROUTER9_IP via pre-resolved var (no nested ${})
def_r9_ip="${ROUTER9_IP:-10.10.40.10}"
IP="${HEADROOM_IP:-$def_r9_ip}"
PORT="${HEADROOM_PORT:-8787}"
EXTRAS="${HEADROOM_EXTRAS:-proxy,code,ml,mcp}"
AUTH="${HEADROOM_AUTH:-}"
UPDATER_SRC="${HEADROOM_UPDATER_SRC:-tools/headroom-updater}"
UPDATER_DST="${HEADROOM_UPDATER_DST:-/usr/local/bin/headroom-updater}"

# Paths
INSTALL_DIR="/opt/headroom"
VENV_DIR="$INSTALL_DIR/venv"
SERVICE_USER="root"
PM2_NAME="headroom"

log_service() {
    log_info "[$SERVICE_NAME] $1"
}

ensure_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        log_service "Installing python3"
        pkg_update && pkg_install python3 python3-pip python3-venv
    fi
    # python3-venv (ensurepip) sering terpisah — pastikan venv bisa dibuat
    if ! python3 -m venv --help >/dev/null 2>&1; then
        log_service "python3-venv belum lengkap — menginstal"
        pkg_update && pkg_install python3-venv python3-pip 2>/dev/null || true
    fi
    log_service "Python $(python3 --version) ready"
}

create_venv() {
    log_service "Creating virtual environment at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip setuptools wheel
}

install_headroom() {
    log_service "Installing headroom-ai[$EXTRAS]"
    "$VENV_DIR/bin/pip" install "headroom-ai[$EXTRAS]" --break-system-packages
}

create_systemd_service() {
    log_service "Creating systemd service"
    cat > /etc/systemd/system/headroom.service <<EOF
[Unit]
Description=Headroom AI Context Compression
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
Environment=HEADROOM_HOST=0.0.0.0
Environment=HEADROOM_PORT=$PORT
Environment=HEADROOM_AUTH=$AUTH
Environment=HEADROOM_EXTRAS=$EXTRAS
ExecStart=$VENV_DIR/bin/headroom serve --host 0.0.0.0 --port $PORT
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
    log_service "Starting install (mode: ${HEADROOM_INSTALL_MODE:-ask})"
    
    # P8: Interactive prompt if ENV is DEFAULT
    prompt_service_env "HEADROOM"
    
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed, skipping"
        return 0
    fi

    ensure_python
    create_venv
    install_headroom
    create_systemd_service

    log_service "Starting service"
    systemctl enable --now headroom

    register_registry
    mark_service_installed "$SERVICE_NAME"
    log_service "Install completed"
}

action_uninstall() {
    log_service "Uninstalling"
    
    systemctl disable --now headroom 2>/dev/null || true
    rm -f /etc/systemd/system/headroom.service
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

    "$VENV_DIR/bin/pip" install --upgrade "headroom-ai[$EXTRAS]" --break-system-packages
    systemctl restart headroom
    log_service "Update completed"
}

action_status() {
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Status: INSTALLED"
        systemctl status headroom --no-pager || true
    else
        log_service "Status: NOT INSTALLED"
    fi
}

action_start() {
    systemctl start headroom
}

action_stop() {
    systemctl stop headroom
}

action_restart() {
    systemctl restart headroom
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
