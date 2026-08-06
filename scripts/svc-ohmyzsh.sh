#!/bin/bash
# svc-ohmyzsh.sh — Oh My Zsh lifecycle
# Source: https://ohmyz.sh
# Install: curl + git (host only)
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/service-actions.sh"
source "$REPO_ROOT/lib/env-manager.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

SERVICE_NAME="ohmyzsh"
ACTION="${1:-status}"

log_service() {
    log_info "[$SERVICE_NAME] $1"
}

install_ohmyzsh() {
    log_service "Installing Oh My Zsh"
    if ! command -v zsh >/dev/null 2>&1; then
        pkg_update
        pkg_install zsh git
    fi

    # Install Oh My Zsh
    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    fi

    # Set default shell
    if [[ "$(getent passwd $USER | cut -d: -f7)" != "/bin/zsh" ]]; then
        chsh -s /bin/zsh
    fi
}

action_install() {
    log_service "Starting install (mode: ${OHMYZSH_INSTALL_MODE:-host})"    
    # P8: Interactive prompt if ENV is DEFAULT
    prompt_service_env "OHMYZSH"    
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed, skipping"
        return 0
    fi

    install_ohmyzsh
    mark_service_installed "$SERVICE_NAME"
    log_service "Install completed"
}

action_uninstall() {
    log_service "Uninstalling"
    
    rm -rf "$HOME/.oh-my-zsh"
    
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

    cd "$HOME/.oh-my-zsh" && git pull
    log_service "Update completed"
}

action_status() {
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Status: INSTALLED"
        [[ -d "$HOME/.oh-my-zsh" ]] && echo "  ✓ Oh My Zsh directory exists" || echo "  ✗ Oh My Zsh directory missing"
    else
        log_service "Status: NOT INSTALLED"
    fi
}

# Main dispatch
case "$ACTION" in
    install) action_install ;;
    uninstall) action_uninstall ;;
    update) action_update ;;
    status) action_status ;;
    *) log_error "Unknown action: $ACTION"; exit 1 ;;
esac
