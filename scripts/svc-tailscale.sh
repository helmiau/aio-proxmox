#!/bin/bash
# svc-tailscale.sh — Tailscale VPN lifecycle
# Source: https://tailscale.com/download/linux
# Install: curl + systemd
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/service-actions.sh"
source "$REPO_ROOT/lib/env-manager.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

SERVICE_NAME="tailscale"
ACTION="${1:-status}"

# Config from ENV
AUTH_KEY="${TAILSCALE_AUTHKEY:-}"
HOSTNAME="${TAILSCALE_HOSTNAME:-}"
ACCEPT_DNS="${TAILSCALE_ACCEPT_DNS:-true}"
ACCEPT_ROUTES="${TAILSCALE_ACCEPT_ROUTES:-true}"
SSH_ENABLED="${TAILSCALE_SSH:-true}"
EXTRA_ARGS="${TAILSCALE_EXTRA_ARGS:-}"

log_service() {
    log_info "[$SERVICE_NAME] $1"
}

install_tailscale() {
    log_service "Installing Tailscale"
    curl -fsSL https://tailscale.com/install.sh | sh
}

action_install() {
    log_service "Starting install (mode: ${TAILSCALE_INSTALL_MODE:-host})"
    
    # P8: Interactive prompt if ENV is DEFAULT
    prompt_service_env "TAILSCALE"
    
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed, skipping"
        return 0
    fi

    install_tailscale

    # Build tailscale up args
    local up_args="--accept-routes"
    [[ -n "$AUTH_KEY" ]] && up_args="$up_args --authkey=$AUTH_KEY"
    [[ -n "$HOSTNAME" ]] && up_args="$up_args --hostname=$HOSTNAME"
    [[ "$ACCEPT_DNS" == "true" ]] && up_args="$up_args --accept-dns"
    [[ "$SSH_ENABLED" == "true" ]] && up_args="$up_args --ssh"
    [[ -n "$EXTRA_ARGS" ]] && up_args="$up_args $EXTRA_ARGS"

    log_service "Running: tailscale up $up_args"
    tailscale up $up_args

    systemctl enable --now tailscaled

    mark_service_installed "$SERVICE_NAME"
    log_service "Install completed"
}

action_uninstall() {
    log_service "Uninstalling"
    
    tailscale down 2>/dev/null || true
    systemctl disable --now tailscaled 2>/dev/null || true
    
    # Uninstall script
    curl -fsSL https://tailscale.com/install.sh | sh -- --uninstall 2>/dev/null || true
    
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

    install_tailscale
    systemctl restart tailscaled
    log_service "Update completed"
}

action_status() {
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Status: INSTALLED"
        tailscale status || true
    else
        log_service "Status: NOT INSTALLED"
    fi
}

action_start() {
    systemctl start tailscaled
}

action_stop() {
    tailscale down
}

action_restart() {
    tailscale down 2>/dev/null || true
    tailscale up --accept-routes
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
