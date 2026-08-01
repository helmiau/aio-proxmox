#!/bin/bash
# 00-check-env.sh — validate ENVIRONMENT before any install step
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/logging.sh
source "$REPO_ROOT/lib/logging.sh"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/env-manager.sh
source "$REPO_ROOT/lib/env-manager.sh"

# 1. Auto-init ENVIRONMENT if missing
init_env

# 2. Load and validate
load_env
validate_env
log_info "ENV OK: $ENV_FILE"
