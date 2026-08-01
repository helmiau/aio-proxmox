#!/bin/bash
# 00-check-env.sh — validate ENVIRONMENT before any install step
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/logging.sh
source "$REPO_ROOT/lib/logging.sh"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

ENV_FILE="${1:-$REPO_ROOT/ENVIRONMENT}"
[[ -f "$ENV_FILE" ]] || { log_error "Missing $ENV_FILE — cp ENVIRONMENT.v4.example ENVIRONMENT"; exit 1; }
load_env "$ENV_FILE"
validate_env
log_info "ENV OK: $ENV_FILE"
