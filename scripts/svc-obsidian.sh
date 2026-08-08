#!/bin/bash
# svc-obsidian.sh — Obsidian LiveSync (CouchDB) lifecycle
# Source: https://community.obsidian.md/plugins/obsidian-livesync
# Install: Docker CouchDB (Livesync plugin connects via HTTP/WebSocket)
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/service-actions.sh"
source "$REPO_ROOT/lib/env-manager.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

SERVICE_NAME="obsidian"
ACTION="${1:-status}"

# Config from ENV
CTID="${OBSIDIAN_CTID:-108}"
HOSTNAME="${OBSIDIAN_HOSTNAME:-obsidian}"
IP="${OBSIDIAN_IP:-10.10.40.80}"
PORT="${OBSIDIAN_PORT:-5984}"
COUCHDB_USER="${OBSIDIAN_COUCHDB_USER:-admin}"
COUCHDB_PASSWORD="${OBSIDIAN_COUCHDB_PASSWORD:-changeme123}"
DATA_DIR="${OBSIDIAN_DATA_DIR:-/var/lib/obsidian}"
COUCHDB_VERSION="${OBSIDIAN_COUCHDB_VERSION:-3.3.3}"

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
    log_service "Starting install (mode: ${OBSIDIAN_INSTALL_MODE:-ask})"
    prompt_service_env "OBSIDIAN"
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed, skipping"
        return 0
    fi

    ensure_curl
    ensure_docker
    mkdir -p "$DATA_DIR"

    log_service "Menjalankan CouchDB container (port $PORT)"
    docker run -d --name "obsidian-livesync" \
        --restart unless-stopped \
        -p "$PORT:5984" \
        -e "COUCHDB_USER=$COUCHDB_USER" \
        -e "COUCHDB_PASSWORD=$COUCHDB_PASSWORD" \
        -v "$DATA_DIR:/opt/couchdb/data" \
        "couchdb:$COUCHDB_VERSION" || { log_error "Gagal start CouchDB"; return 1; }

    log_info "Buat database + admin user:"
    log_info "  http://$IP:$PORT/_utils/ (Fauxton UI)"
    log_info "  Plugin Obsidian Livesync: server $IP:$PORT, user $COUCHDB_USER"
    log_info "  Detail: https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/setup_own_server.md"

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
    docker rm -f obsidian-livesync 2>/dev/null || true
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
    docker pull "couchdb:$COUCHDB_VERSION" && docker restart obsidian-livesync
    log_service "Update completed"
}

action_status() {
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Status: INSTALLED"
        docker ps --filter name=obsidian-livesync 2>/dev/null || true
    else
        log_service "Status: NOT INSTALLED"
    fi
}

action_start() { docker start obsidian-livesync 2>/dev/null || true; }
action_stop() { docker stop obsidian-livesync 2>/dev/null || true; }
action_restart() { docker restart obsidian-livesync 2>/dev/null || true; }

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
