#!/bin/bash
# svc-rustdesk.sh — RustDesk Server lifecycle
# Source: https://github.com/rustdesk/rustdesk-server
# Install: Docker (hbbs + hbbr)
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/service-actions.sh"
source "$REPO_ROOT/lib/env-manager.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

SERVICE_NAME="rustdesk"
ACTION="${1:-status}"

# Config from ENV
CTID="${RUSTDESK_CTID:-110}"
HOSTNAME="${RUSTDESK_HOSTNAME:-rustdesk}"
IP="${RUSTDESK_IP:-10.10.40.90}"
RELAY_PORT="${RUSTDESK_RELAY_PORT:-21117}"   # hbbr relay
SIGNAL_PORT="${RUSTDESK_SIGNAL_PORT:-21116}" # hbbs signal (udp+tcp)
DATA_DIR="${RUSTDESK_DATA_DIR:-/var/lib/rustdesk}"
RUSTDESK_VERSION="${RUSTDESK_VERSION:-latest}"

ensure_curl

log_service() {
    log_info "[$SERVICE_NAME] $1"
}

ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log_service "Menginstal Docker..."
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache docker docker-cli-compose 2>/dev/null || true
            rc-update add docker default 2>/dev/null || true
        else
            curl -fsSL https://get.docker.com | sh 2>/dev/null || pkg_install docker.io docker-compose-v2
        fi
    fi
}

action_install() {
    log_service "Starting install (mode: ${RUSTDESK_INSTALL_MODE:-ask})"
    prompt_service_env "RUSTDESK"
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed, skipping"
        return 0
    fi

    ensure_curl
    ensure_docker
    mkdir -p "$DATA_DIR"

    log_service "Menjalankan RustDesk server (hbbs + hbbr)"
    # hbbs: signal server (21116 tcp/udp + 21115)
    docker run -d --name rustdesk-hbbs \
        --restart unless-stopped \
        -p "21115:21115" -p "${SIGNAL_PORT}:21116" -p "${SIGNAL_PORT}:21116/udp" \
        -v "$DATA_DIR:/data" \
        "rustdesk/rustdesk-server-hbbs:$RUSTDESK_VERSION" \
        -r "relay.$IP:$RELAY_PORT" 2>/dev/null || true
    # hbbr: relay server
    docker run -d --name rustdesk-hbbr \
        --restart unless-stopped \
        -p "${RELAY_PORT}:21117" \
        -v "$DATA_DIR:/data" \
        "rustdesk/rustdesk-server-hbbr:$RUSTDESK_VERSION" 2>/dev/null || true

    log_info "Key server ada di $DATA_DIR/id_ed25519.pub"
    log_info "RustDesk client: ID server = $IP, relay = $IP:$RELAY_PORT"
    log_info "Ambil pub key: cat $DATA_DIR/id_ed25519.pub (untuk client 'Key')"

    register_registry
    mark_service_installed "$SERVICE_NAME"
    log_service "Install completed"
}

register_registry() {
    allocate_resource "$IP" "$SIGNAL_PORT" "$SERVICE_NAME-signal"
    allocate_resource "$IP" "$RELAY_PORT" "$SERVICE_NAME-relay"
}

unregister_registry() {
    release_resource "$IP" "$SERVICE_NAME-signal"
    release_resource "$IP" "$SERVICE_NAME-relay"
}

action_uninstall() {
    log_service "Uninstalling"
    docker rm -f rustdesk-hbbs rustdesk-hbbr 2>/dev/null || true
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
    docker pull "rustdesk/rustdesk-server-hbbs:$RUSTDESK_VERSION"
    docker pull "rustdesk/rustdesk-server-hbbr:$RUSTDESK_VERSION"
    docker restart rustdesk-hbbs rustdesk-hbbr 2>/dev/null || true
    log_service "Update completed"
}

action_status() {
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Status: INSTALLED"
        docker ps --filter name=rustdesk- 2>/dev/null || true
    else
        log_service "Status: NOT INSTALLED"
    fi
}

action_start() { docker start rustdesk-hbbs rustdesk-hbbr 2>/dev/null || true; }
action_stop() { docker stop rustdesk-hbbs rustdesk-hbbr 2>/dev/null || true; }
action_restart() { docker restart rustdesk-hbbs rustdesk-hbbr 2>/dev/null || true; }

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
