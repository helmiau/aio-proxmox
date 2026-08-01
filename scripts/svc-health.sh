#!/bin/bash
# svc-health.sh — health check (install verification only, MON-01)
set -euo pipefail
ACTION="${1:-status}"
SERVICE_NAME="healthcheck"
case "$ACTION" in
  install) log_info "Installing $SERVICE_NAME"; mark_service_installed "$SERVICE_NAME" ;;
  uninstall) log_info "Uninstalling $SERVICE_NAME" ;;
  update) log_info "Updating $SERVICE_NAME" ;;
  status)
    log_info "Health check: verifying installed services"
    for svc in 9router headroom hermes hermes-webui storage copyparty xui; do
      if is_service_installed "$svc"; then
        log_info "  ✓ $svc installed"
      else
        log_warn "  ✗ $svc not installed"
      fi
    done
    ;;
  *) log_error "Unknown action: $ACTION"; exit 1 ;;
esac
