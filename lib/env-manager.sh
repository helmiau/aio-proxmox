#!/bin/bash
# ============================================================
# ENV Manager (P8) — Auto-init + interactive edit
# - Jangan hapus ENVIRONMENT file, hanya edit konten
# - Backup ENV sebelum modify
# - Marker (DEFAULT)/(EDITED) per section
# ============================================================

set -euo pipefail

# --- Paths -----------------------------------------------------
# Get repo root relative to this library file
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"

# --- Constants -------------------------------------------------
ENV_FILE="${REPO_ROOT}/ENVIRONMENT"
ENV_EXAMPLE="${REPO_ROOT}/ENVIRONMENT.example"
ENV_BACKUP_DIR="${REPO_ROOT}/.env-backups"
MAX_BACKUPS=3

# --- Helper: Timestamp -----------------------------------------
timestamp() {
    date +"%Y%m%d-%H%M%S"
}

# --- Helper: Backup ENV ----------------------------------------
backup_env() {
    mkdir -p "${ENV_BACKUP_DIR}"
    local backup_file="${ENV_BACKUP_DIR}/ENVIRONMENT.bak.$(timestamp)"
    cp "${ENV_FILE}" "${backup_file}"
    log_info "ENV backup: ${backup_file}"
    
    # Rotate backups
    (cd "${ENV_BACKUP_DIR}" && ls -t ENVIRONMENT.bak.* | tail -n +$((MAX_BACKUPS + 1)) | xargs -I {} rm -f {})
}

# --- Helper: Add/Update header marker -------------------------
update_env_header() {
    local status="${1:-DEFAULT}"
    local header="# ENVIRONMENT auto-generated from ENVIRONMENT.example\n# Status: ${status}\n# Timestamp: $(date +'%Y-%m-%d %H:%M:%S')"
    
    if grep -q "^# ENVIRONMENT auto-generated" "${ENV_FILE}"; then
        sed -i "1,3c\\
${header}" "${ENV_FILE}"
    else
        echo -e "${header}\n$(cat "${ENV_FILE}")" > "${ENV_FILE}"
    fi
}

# --- Helper: Get section marker --------------------------------
get_section_marker() {
    local section="${1}"
    grep -A1 "^#.*${section}" "${ENV_FILE}" | tail -1 | awk '{print $2}' || echo "(DEFAULT)"
}

# --- Helper: Update section marker -----------------------------
update_section_marker() {
    local section="${1}"
    local marker="(EDITED $(date +'%Y-%m-%d'))"
    
    if grep -q "^#.*${section}" "${ENV_FILE}"; then
        sed -i "/^#.*${section}/!b;n;c\\# ${marker}" "${ENV_FILE}"
    else
        log_warn "Section ${section} not found in ENVIRONMENT"
    fi
}

# --- Core: Init ENV (first run) --------------------------------
init_env() {
    if [[ ! -f "${ENV_FILE}" ]]; then
        log_info "ENVIRONMENT not found. Copying from ENVIRONMENT.example..."
        cp "${ENV_EXAMPLE}" "${ENV_FILE}"
        update_env_header "DEFAULT"
        log_success "ENVIRONMENT created from template"
    else
        log_info "ENVIRONMENT already exists"
    fi
}

# --- Core: Interactive prompt for service ----------------------
prompt_service_env() {
    local service="${1}"
    local marker="$(get_section_marker "${service}")"
    
    if [[ "${marker}" != "(DEFAULT)" ]]; then
        log_info "${service} ENV already configured (${marker}). Skipping prompt."
        return 0
    fi
    
    log_info "Configuring ${service} (DEFAULT → EDITED)..."
    backup_env
    
    # --- Dynamic prompt based on service ------------------------
    case "${service}" in
        "9ROUTER")
            read -p "[9Router] IP (default ${9ROUTER_IP:-10.10.40.10}): " new_ip
            read -p "[9Router] Port (default ${9ROUTER_PORT:-20128}): " new_port
            read -p "[9Router] CTID (default ${9ROUTER_CTID:-101}): " new_ctid
            read -p "[9Router] Password (default ${DEFAULT_ROOT_PASSWORD:-changeme123}): " new_pass
            
            # Update ENV
            sed -i "s/^9ROUTER_IP=.*/9ROUTER_IP='${new_ip:-${9ROUTER_IP:-10.10.40.10}}'/" "${ENV_FILE}"
            sed -i "s/^9ROUTER_PORT=.*/9ROUTER_PORT='${new_port:-${9ROUTER_PORT:-20128}}'/" "${ENV_FILE}"
            sed -i "s/^9ROUTER_CTID=.*/9ROUTER_CTID='${new_ctid:-${9ROUTER_CTID:-101}}'/" "${ENV_FILE}"
            sed -i "s/^DEFAULT_ROOT_PASSWORD=.*/DEFAULT_ROOT_PASSWORD='${new_pass:-${DEFAULT_ROOT_PASSWORD:-changeme123}}'/" "${ENV_FILE}"
            ;;
        "HEADROOM")
            read -p "[Headroom] IP (default ${HEADROOM_IP:-10.10.40.10}): " new_ip
            read -p "[Headroom] Port (default ${HEADROOM_PORT:-8787}): " new_port
            read -p "[Headroom] CTID (default ${HEADROOM_CTID:-101}): " new_ctid
            
            sed -i "s/^HEADROOM_IP=.*/HEADROOM_IP='${new_ip:-${HEADROOM_IP:-10.10.40.10}}'/" "${ENV_FILE}"
            sed -i "s/^HEADROOM_PORT=.*/HEADROOM_PORT='${new_port:-${HEADROOM_PORT:-8787}}'/" "${ENV_FILE}"
            sed -i "s/^HEADROOM_CTID=.*/HEADROOM_CTID='${new_ctid:-${HEADROOM_CTID:-101}}'/" "${ENV_FILE}"
            ;;
        "HERMES")
            read -p "[Hermes] IP (default ${HERMES_IP:-10.10.40.10}): " new_ip
            read -p "[Hermes] Port (default ${HERMES_PORT:-8000}): " new_port
            read -p "[Hermes] CTID (default ${HERMES_CTID:-101}): " new_ctid
            
            sed -i "s/^HERMES_IP=.*/HERMES_IP='${new_ip:-${HERMES_IP:-10.10.40.10}}'/" "${ENV_FILE}"
            sed -i "s/^HERMES_PORT=.*/HERMES_PORT='${new_port:-${HERMES_PORT:-8000}}'/" "${ENV_FILE}"
            sed -i "s/^HERMES_CTID=.*/HERMES_CTID='${new_ctid:-${HERMES_CTID:-101}}'/" "${ENV_FILE}"
            ;;
        "HERMES_WEBUI")
            read -p "[Hermes WebUI] IP (default ${HERMES_WEBUI_IP:-10.10.40.30}): " new_ip
            read -p "[Hermes WebUI] Port (default ${HERMES_WEBUI_PORT:-3000}): " new_port
            read -p "[Hermes WebUI] CTID (default ${HERMES_WEBUI_CTID:-103}): " new_ctid
            
            sed -i "s/^HERMES_WEBUI_IP=.*/HERMES_WEBUI_IP='${new_ip:-${HERMES_WEBUI_IP:-10.10.40.30}}'/" "${ENV_FILE}"
            sed -i "s/^HERMES_WEBUI_PORT=.*/HERMES_WEBUI_PORT='${new_port:-${HERMES_WEBUI_PORT:-3000}}'/" "${ENV_FILE}"
            sed -i "s/^HERMES_WEBUI_CTID=.*/HERMES_WEBUI_CTID='${new_ctid:-${HERMES_WEBUI_CTID:-103}}'/" "${ENV_FILE}"
            ;;
        "CLOUDFLARED")
            read -p "[Cloudflared] Tunnel Name (default ${CLOUDFLARED_TUNNEL_NAME:-homelab}): " new_name
            read -p "[Cloudflared] Credentials File (default ${CLOUDFLARED_CREDENTIALS_FILE:-}): " new_creds
            
            sed -i "s/^CLOUDFLARED_TUNNEL_NAME=.*/CLOUDFLARED_TUNNEL_NAME='${new_name:-${CLOUDFLARED_TUNNEL_NAME:-homelab}}'/" "${ENV_FILE}"
            sed -i "s/^CLOUDFLARED_CREDENTIALS_FILE=.*/CLOUDFLARED_CREDENTIALS_FILE='${new_creds:-${CLOUDFLARED_CREDENTIALS_FILE:-}}'/" "${ENV_FILE}"
            ;;
        "TAILSCALE")
            read -p "[Tailscale] Auth Key (default ${TAILSCALE_AUTHKEY:-}): " new_key
            read -p "[Tailscale] Hostname (default ${TAILSCALE_HOSTNAME:-}): " new_host
            
            sed -i "s/^TAILSCALE_AUTHKEY=.*/TAILSCALE_AUTHKEY='${new_key:-${TAILSCALE_AUTHKEY:-}}'/" "${ENV_FILE}"
            sed -i "s/^TAILSCALE_HOSTNAME=.*/TAILSCALE_HOSTNAME='${new_host:-${TAILSCALE_HOSTNAME:-}}'/" "${ENV_FILE}"
            ;;
        "MIHOMO")
            read -p "[Mihomo] IP (default ${MIHOMO_IP:-10.10.40.50}): " new_ip
            read -p "[Mihomo] Port (default ${MIHOMO_PORT:-7890}): " new_port
            read -p "[Mihomo] CTID (default ${MIHOMO_CTID:-105}): " new_ctid
            
            sed -i "s/^MIHOMO_IP=.*/MIHOMO_IP='${new_ip:-${MIHOMO_IP:-10.10.40.50}}'/" "${ENV_FILE}"
            sed -i "s/^MIHOMO_PORT=.*/MIHOMO_PORT='${new_port:-${MIHOMO_PORT:-7890}}'/" "${ENV_FILE}"
            sed -i "s/^MIHOMO_CTID=.*/MIHOMO_CTID='${new_ctid:-${MIHOMO_CTID:-105}}'/" "${ENV_FILE}"
            ;;
        "MIKROTIK")
            read -p "[MikroTik] IP (default ${MIKROTIK_IP:-10.10.30.2}): " new_ip
            read -p "[MikroTik] Port (default ${MIKROTIK_PORT:-22}): " new_port
            read -p "[MikroTik] CTID (default ${MIKROTIK_CTID:-200}): " new_ctid
            
            sed -i "s/^MIKROTIK_IP=.*/MIKROTIK_IP='${new_ip:-${MIKROTIK_IP:-10.10.30.2}}'/" "${ENV_FILE}"
            sed -i "s/^MIKROTIK_PORT=.*/MIKROTIK_PORT='${new_port:-${MIKROTIK_PORT:-22}}'/" "${ENV_FILE}"
            sed -i "s/^MIKROTIK_CTID=.*/MIKROTIK_CTID='${new_ctid:-${MIKROTIK_CTID:-200}}'/" "${ENV_FILE}"
            ;;
        "STORAGE")
            read -p "[Storage] IP (default ${STORAGE_IP:-10.10.40.100}): " new_ip
            read -p "[Storage] CTID (default ${STORAGE_CTID:-110}): " new_ctid
            
            sed -i "s/^STORAGE_IP=.*/STORAGE_IP='${new_ip:-${STORAGE_IP:-10.10.40.100}}'/" "${ENV_FILE}"
            sed -i "s/^STORAGE_CTID=.*/STORAGE_CTID='${new_ctid:-${STORAGE_CTID:-110}}'/" "${ENV_FILE}"
            ;;
        "TTYD")
            read -p "[ttyd] Port (default ${TTYD_PORT:-7681}): " new_port
            
            sed -i "s/^TTYD_PORT=.*/TTYD_PORT='${new_port:-${TTYD_PORT:-7681}}'/" "${ENV_FILE}"
            ;;
        "XUI")
            read -p "[X-UI] IP (default ${XUI_IP:-10.10.40.60}): " new_ip
            read -p "[X-UI] Port (default ${XUI_PORT:-54321}): " new_port
            read -p "[X-UI] CTID (default ${XUI_CTID:-106}): " new_ctid
            
            sed -i "s/^XUI_IP=.*/XUI_IP='${new_ip:-${XUI_IP:-10.10.40.60}}'/" "${ENV_FILE}"
            sed -i "s/^XUI_PORT=.*/XUI_PORT='${new_port:-${XUI_PORT:-54321}}'/" "${ENV_FILE}"
            sed -i "s/^XUI_CTID=.*/XUI_CTID='${new_ctid:-${XUI_CTID:-106}}'/" "${ENV_FILE}"
            ;;
        "COPYPARTY")
            read -p "[Copyparty] IP (default ${COPYPARTY_IP:-10.10.40.70}): " new_ip
            read -p "[Copyparty] Port (default ${COPYPARTY_PORT:-3923}): " new_port
            read -p "[Copyparty] CTID (default ${COPYPARTY_CTID:-107}): " new_ctid
            
            sed -i "s/^COPYPARTY_IP=.*/COPYPARTY_IP='${new_ip:-${COPYPARTY_IP:-10.10.40.70}}'/" "${ENV_FILE}"
            sed -i "s/^COPYPARTY_PORT=.*/COPYPARTY_PORT='${new_port:-${COPYPARTY_PORT:-3923}}'/" "${ENV_FILE}"
            sed -i "s/^COPYPARTY_CTID=.*/COPYPARTY_CTID='${new_ctid:-${COPYPARTY_CTID:-107}}'/" "${ENV_FILE}"
            ;;
        "FASTFETCH")
            # Fastfetch has no configurable ENV vars
            ;;
        "OHMYZSH")
            # OhMyZsh has no configurable ENV vars
            ;;
        *)
            log_warn "No interactive prompt defined for ${service}"
            return 1
            ;;
        *)
            log_warn "No interactive prompt defined for ${service}"
            return 1
            ;;
    esac
    
    update_section_marker "${service}"
    log_success "${service} ENV updated (EDITED)"
}

# --- Core: Interactive ENV Editor -----------------------------
edit_env() {
    local editor="${EDITOR:-nano}"
    if ! command -v "$editor" >/dev/null 2>&1; then
        editor="nano"
    fi
    
    if [[ ! -f "${ENV_FILE}" ]]; then
        log_error "ENVIRONMENT file not found. Run init_env first."
        return 1
    fi
    
    backup_env
    update_env_header "EDITED"
    
    log_info "Opening ENVIRONMENT in $editor..."
    "$editor" "${ENV_FILE}"
    
    log_success "ENVIRONMENT saved. Remember to reload with: source ENVIRONMENT"
}
load_env() {
    if [[ -f "${ENV_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${ENV_FILE}"
        log_info "ENV loaded from ${ENV_FILE}"
    else
        log_error "ENVIRONMENT file not found!"
        exit 1
    fi
}