#!/bin/bash
# svc-omniroute.sh — OmniRoute lifecycle
# Source: https://github.com/diegosouzapw/OmniRoute
# Install: git clone + install script (PHP-based router UI)
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
PORT="${OMNIROUTE_PORT:-8080}"
INSTALL_DIR="${OMNIROUTE_DIR:-/opt/omniroute}"
REPO_URL="${OMNIROUTE_REPO_URL:-https://github.com/diegosouzapw/OmniRoute.git}"

ensure_curl

log_service() {
    log_info "[$SERVICE_NAME] $1"
}

ensure_deps() {
    # PHP + composer (atau bun/php sesuai requirements OmniRoute)
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache git curl php php-json php-mbstring php-pdo php-openssl composer 2>/dev/null || \
        apk add --no-cache git curl php composer 2>/dev/null || true
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y git curl php-cli php-json php-mbstring composer 2>/dev/null || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y git curl php-cli composer 2>/dev/null || true
    fi
}

action_install() {
    log_service "Starting install (mode: ${OMNIROUTE_INSTALL_MODE:-ask})"
    prompt_service_env "OMNIROUTE"
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed, skipping"
        return 0
    fi

    ensure_curl
    ensure_deps
    mkdir -p "$INSTALL_DIR"

    log_service "Cloning OmniRoute"
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        cd "$INSTALL_DIR" && git pull
    else
        git clone "$REPO_URL" "$INSTALL_DIR"
    fi

    cd "$INSTALL_DIR"
    if [[ -f composer.json ]]; then
        composer install --no-interaction 2>/dev/null || true
    fi

    # Jalankan via php built-in server (fallback) — sesuaikan dokumentasi OmniRoute
    log_service "Menjalankan OmniRoute di port $PORT"
    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/omniroute.service <<EOF
[Unit]
Description=OmniRoute
After=network.target

[Service]
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/php -S 0.0.0.0:$PORT -t public
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        svc_enable omniroute
        svc_start omniroute
    else
        log_warn "No systemd — jalankan manual: cd $INSTALL_DIR && php -S 0.0.0.0:$PORT -t public"
    fi

    register_registry
    mark_service_installed "$SERVICE_NAME"
    log_service "Install completed"
    log_info "OmniRoute: http://$IP:$PORT (lihat dokumentasi repo untuk setup)"
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
    rm -rf "$INSTALL_DIR" 2>/dev/null || true
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
    cd "$INSTALL_DIR" && git pull
    [[ -f composer.json ]] && composer install --no-interaction 2>/dev/null || true
    svc_start omniroute 2>/dev/null || true
    log_service "Update completed"
}

action_status() {
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Status: INSTALLED"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl status omniroute --no-pager 2>/dev/null | head -n 5 || true
        fi
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
