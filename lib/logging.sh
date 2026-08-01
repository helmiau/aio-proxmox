#!/bin/bash

# Centralized logging for Debian → Proxmox VE Homelab Installer
# Writes to systemd-journald (tag: homelab) and local file aggregate

# Source common library
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Log directory
LOG_DIR="${LOG_DIR:-/var/log/homelab}"
mkdir -p "$LOG_DIR"

# Log file for this service
SERVICE_LOG_FILE="${LOG_DIR}/${SERVICE_NAME:-installer}.log"

# Log levels
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3

# Current log level (default: INFO)
CURRENT_LOG_LEVEL="${LOG_LEVEL:-$LOG_LEVEL_INFO}"

# Write to systemd-journald
log_to_journald() {
    local level="$1"
    local message="$2"
    local tag="homelab"

    if command -v systemd-cat >/dev/null 2>&1; then
        echo "$message" | systemd-cat -t "$tag" -p "$level"
    fi
}

# Write to local log file
log_to_file() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$SERVICE_LOG_FILE"
}

# Generic log function
log() {
    local level="$1"
    local message="$2"
    local level_num

    case "$level" in
        DEBUG) level_num=$LOG_LEVEL_DEBUG ;;
        INFO)  level_num=$LOG_LEVEL_INFO ;;
        WARN)  level_num=$LOG_LEVEL_WARN ;;
        ERROR) level_num=$LOG_LEVEL_ERROR ;;
        *)     level_num=$LOG_LEVEL_INFO ;;
    esac

    if [[ $level_num -ge $CURRENT_LOG_LEVEL ]]; then
        log_to_journald "$level" "$message"
        log_to_file "$level" "$message"
    fi
}

# Convenience functions
log_debug() {
    log "DEBUG" "$1"
}

log_info() {
    log "INFO" "$1"
}

log_warn() {
    log "WARN" "$1"
}

log_error() {
    log "ERROR" "$1"
}

# Log with service context
log_service() {
    local action="$1"
    local service="$2"
    local status="$3"
    local message="${4:-}"

    log_info "Service $service $action: $status${message:+ - $message}"
}

# Main entry point
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "Logging library loaded. Use: source lib/logging.sh"
fi