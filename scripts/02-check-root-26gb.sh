#!/bin/bash
# 02-check-root-26gb.sh — root size check (NFR-1)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

MAX_GIB="${EXPECTED_ROOT_MAX_GIB:-28}"
TARGET_GIB="${EXPECTED_ROOT_TARGET_GIB:-26}"

ROOT_K=$(df -k / | awk 'NR==2{print $2}')
ROOT_GIB=$((ROOT_K / 1024 / 1024))

log_info "Root size ≈ ${ROOT_GIB} GiB (target ${TARGET_GIB}, max ${MAX_GIB})"
if (( ROOT_GIB > MAX_GIB )); then
  log_error "Root > ${MAX_GIB} GiB — cloning/backup risk"
  exit 1
fi
log_info "Root size OK"
