#!/bin/bash
# svc-fastfetch.sh — FastFetch lifecycle
# Source: https://github.com/fastfetch-cli/fastfetch
# Install: apt (host only)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/service-actions.sh"
source "$REPO_ROOT/lib/env-manager.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

SERVICE_NAME="fastfetch"
ACTION="${1:-status}"

log_service() {
    log_info "[$SERVICE_NAME] $1"
}

install_fastfetch() {
    log_service "Installing fastfetch"
    apt-get update -y
    apt-get install -y fastfetch
}

action_install() {
    log_service "Starting install (mode: ${FASTFETCH_INSTALL_MODE:-host})"    
    # P8: Interactive prompt if ENV is DEFAULT
    prompt_service_env "FASTFETCH"    
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed, skipping"
        return 0
    fi

    install_fastfetch
    mark_service_installed "$SERVICE_NAME"
    log_service "Install completed"
}

action_uninstall() {
    log_service "Uninstalling"
    apt-get remove -y fastfetch
    
    local status_file="/var/lib/homelab/service_status.json"
    if [[ -f "$status_file" ]]; then
        jq --arg name "$SERVICE_NAME" 'del(.services[$name])' "$status_file" >"$status_file.tmp" && mv "$status_file.tmp" "$status_file"
    fi

    log_service "Uninstall completed"
}

action_update() {
    log_service "Updating"
    apt-get update -y && apt-get install -y --only-upgrade fastfetch
    log_service "Update completed"
}

action_status() {
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Status: INSTALLED"
        fastfetch --version || true
    else
        log_service "Status: NOT INSTALLED"
    fi
}

action_start() {
    log_service "FastFetch is a CLI tool, no service to start"
}

action_stop() {
    log_service "FastFetch is a CLI tool, no service to stop"
}

action_restart() {
    log_service "FastFetch is a CLI tool, no service to restart"
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
