#!/bin/bash
# svc-omniroute.sh — OmniRoute AI Gateway lifecycle
# Source: https://github.com/diegosouzapw/OmniRoute
# Install: npm install -g omniroute (Node >= 22.22.2)
# Dokumen: https://omniroute.online/ — "Works second you install it"
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/service-actions.sh"
source "$REPO_ROOT/lib/env-manager.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

SERVICE_NAME="omniroute"
ACTION="${1:-status}"

# Config from ENV
CTID="${OMNIROUTE_CTID:-109}"
HOSTNAME="${OMNIROUTE_HOSTNAME:-omniroute}"
IP="${OMNIROUTE_IP:-10.10.40.85}"
PORT="${OMNIROUTE_PORT:-20128}"   # default resmi OmniRoute
NODE_MAJOR="${NODE_MAJOR:-22}"
DATA_DIR="${OMNIROUTE_DIR:-/var/lib/omniroute}"
SERVICE_USER="root"

ensure_curl

log_service() {
    log_info "[$SERVICE_NAME] $1"
}

ensure_node() {
    if ! command -v node >/dev/null 2>&1; then
        log_service "Installing Node.js $NODE_MAJOR"
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache nodejs npm 2>/dev/null || true
        else
            pkg_install curl ca-certificates gnupg 2>/dev/null || true
            curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - 2>/dev/null || true
            pkg_install nodejs
        fi
    fi
    log_service "Node.js $(node --version) ready"
}

action_install() {
    log_service "Starting install (mode: ${OMNIROUTE_INSTALL_MODE:-ask})"
    prompt_service_env "OMNIROUTE"
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed, skipping"
        return 0
    fi

    ensure_curl
    ensure_node
    mkdir -p "$DATA_DIR"

    log_service "Menginstal omniroute (npm global)..."
    OMNIROUTE_SKIP_POSTINSTALL=1 npm install -g omniroute 2>/dev/null || npm install -g omniroute || {
        log_error "Gagal npm install omniroute"; return 1; }

    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/omniroute.service <<EOF
[Unit]
Description=OmniRoute AI Gateway
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
Environment=PORT=$PORT
Environment=OMNIROUTE_DATA_DIR=$DATA_DIR
ExecStart=$(command -v omniroute) serve
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        svc_enable omniroute
        svc_start omniroute
    else
        log_warn "No systemd — jalankan manual: omniroute serve (port $PORT)"
    fi

    log_info "Dashboard: http://$IP:$PORT"
    log_info "API:       http://$IP:$PORT/v1"
    log_info "Coding tool: base URL http://$IP:$PORT/v1, model auto (zero-config, free tier)"
    log_info "Dokumen: https://omniroute.online/ dan https://github.com/diegosouzapw/OmniRoute"

    register_registry
    mark_service_installed "$SERVICE_NAME"
    log_service "Install completed"
}

register_registry() {
    allocate_resource "$IP" "$PORT" "$SERVICE_NAME"
}

unregister_registry() {
    release_resource "$IP" "$SERVICE_NAME"
}

action_uninstall() {
    log_service "Uninstalling"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop omniroute 2>/dev/null || true
        systemctl disable omniroute 2>/dev/null || true
        rm -f /etc/systemd/system/omniroute.service
        systemctl daemon-reload
    fi
    npm uninstall -g omniroute 2>/dev/null || true
    unregister_registry
    local status_file="/var/lib/homelab/service_status.json"
    if [[ -f "$status_file" ]]; then
        ensure_jq
        jq --arg name "$SERVICE_NAME" 'del(.services[$name])' "$status_file" >"$status_file.tmp" && mv "$status_file.tmp" "$status_file"
    fi
    log_service "Uninstall completed"
}

action_update() {
    log_service "Updating"
    if ! is_service_installed "$SERVICE_NAME"; then action_install; return; fi
    npm update -g omniroute 2>/dev/null || npm install -g omniroute
    svc_start omniroute 2>/dev/null || true
    log_service "Update completed"
}

action_status() {
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Status: INSTALLED"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl status omniroute --no-pager 2>/dev/null | head -n 5 || true
        fi
        curl -s "http://127.0.0.1:$PORT/v1/models" 2>/dev/null | head -c 200 || true
        echo ""
    else
        log_service "Status: NOT INSTALLED"
    fi
}

action_start() { svc_start omniroute 2>/dev/null || true; }
action_stop() { command -v systemctl >/dev/null 2>&1 && systemctl stop omniroute 2>/dev/null || true; }
action_restart() { command -v systemctl >/dev/null 2>&1 && systemctl restart omniroute 2>/dev/null || true; }

action_reinstall() { action_uninstall; action_install; }

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