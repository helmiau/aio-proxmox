#!/bin/bash
# ============================================================
# ENV Manager (P8) ??? Auto-init + interactive edit
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

prompt_service_env() {
    local service="${1}"
    local marker="$(get_section_marker "${service}")"
    
    if [[ "${marker}" != "(DEFAULT)" ]]; then
        log_info "${service} ENV already configured (${marker}). Skipping prompt."
        return 0
    fi
    
    log_info "Configuring ${service} (DEFAULT ? EDITED)..."
    backup_env
    
    # Helper: prompt with default, echo resolved value; no nested ${}
    env_prompt() {
        local label="$1" defval="$2"
        local val=""
        read -p "[$label] (default ${defval}): " val
        echo "${val:-$defval}"
    }
    env_set() {
        local key="$1" val="$2"
        if grep -q "^${key}=" "${ENV_FILE}"; then
            sed -i "s|^${key}=.*|${key}='${val}'|" "${ENV_FILE}"
        else
            echo "${key}='${val}'" >> "${ENV_FILE}"
        fi
    }
    
    case "${service}" in
        "9ROUTER")
            env_set 9ROUTER_IP       "$(env_prompt "9Router IP" "${9ROUTER_IP:-10.10.40.10}")"
            env_set 9ROUTER_PORT     "$(env_prompt "9Router Port" "${9ROUTER_PORT:-20128}")"
            env_set 9ROUTER_CTID     "$(env_prompt "9Router CTID" "${9ROUTER_CTID:-101}")"
            env_set DEFAULT_ROOT_PASSWORD "$(env_prompt "9Router Password" "${DEFAULT_ROOT_PASSWORD:-changeme123}")"
            ;;
        "HEADROOM")
            env_set HEADROOM_IP      "$(env_prompt "Headroom IP" "${HEADROOM_IP:-10.10.40.10}")"
            env_set HEADROOM_PORT    "$(env_prompt "Headroom Port" "${HEADROOM_PORT:-8787}")"
            env_set HEADROOM_CTID    "$(env_prompt "Headroom CTID" "${HEADROOM_CTID:-101}")"
            ;;
        "HERMES")
            env_set HERMES_IP        "$(env_prompt "Hermes IP" "${HERMES_IP:-10.10.40.10}")"
            env_set HERMES_PORT      "$(env_prompt "Hermes Port" "${HERMES_PORT:-8000}")"
            env_set HERMES_CTID      "$(env_prompt "Hermes CTID" "${HERMES_CTID:-101}")"
            ;;
        "HERMES_WEBUI")
            env_set HERMES_WEBUI_IP  "$(env_prompt "Hermes WebUI IP" "${HERMES_WEBUI_IP:-10.10.40.30}")"
            env_set HERMES_WEBUI_PORT "$(env_prompt "Hermes WebUI Port" "${HERMES_WEBUI_PORT:-3000}")"
            env_set HERMES_WEBUI_CTID "$(env_prompt "Hermes WebUI CTID" "${HERMES_WEBUI_CTID:-103}")"
            ;;
        "CLOUDFLARED")
            env_set CLOUDFLARED_TUNNEL_NAME "$(env_prompt "Cloudflared Tunnel Name" "${CLOUDFLARED_TUNNEL_NAME:-homelab}")"
            env_set CLOUDFLARED_CREDENTIALS_FILE "$(env_prompt "Cloudflared Credentials File" "${CLOUDFLARED_CREDENTIALS_FILE:-}")"
            ;;
        "TAILSCALE")
            env_set TAILSCALE_AUTHKEY "$(env_prompt "Tailscale Auth Key" "${TAILSCALE_AUTHKEY:-}")"
            env_set TAILSCALE_HOSTNAME "$(env_prompt "Tailscale Hostname" "${TAILSCALE_HOSTNAME:-}")"
            ;;
        "MIHOMO")
            env_set MIHOMO_IP        "$(env_prompt "Mihomo IP" "${MIHOMO_IP:-10.10.40.50}")"
            env_set MIHOMO_PORT      "$(env_prompt "Mihomo Port" "${MIHOMO_PORT:-7890}")"
            env_set MIHOMO_CTID      "$(env_prompt "Mihomo CTID" "${MIHOMO_CTID:-105}")"
            ;;
        "MIKROTIK")
            env_set MIKROTIK_IP      "$(env_prompt "MikroTik IP" "${MIKROTIK_IP:-10.10.30.2}")"
            env_set MIKROTIK_PORT    "$(env_prompt "MikroTik Port" "${MIKROTIK_PORT:-22}")"
            env_set MIKROTIK_CTID    "$(env_prompt "MikroTik CTID" "${MIKROTIK_CTID:-200}")"
            ;;
        "STORAGE")
            env_set STORAGE_IP       "$(env_prompt "Storage IP" "${STORAGE_IP:-10.10.40.100}")"
            env_set STORAGE_CTID     "$(env_prompt "Storage CTID" "${STORAGE_CTID:-110}")"
            ;;
        "TTYD")
            env_set TTYD_PORT        "$(env_prompt "ttyd Port" "${TTYD_PORT:-7681}")"
            ;;
        "XUI")
            env_set XUI_IP           "$(env_prompt "X-UI IP" "${XUI_IP:-10.10.40.60}")"
            env_set XUI_PORT         "$(env_prompt "X-UI Port" "${XUI_PORT:-54321}")"
            env_set XUI_CTID         "$(env_prompt "X-UI CTID" "${XUI_CTID:-106}")"
            ;;
        "COPYPARTY")
            env_set COPYPARTY_IP     "$(env_prompt "Copyparty IP" "${COPYPARTY_IP:-10.10.40.70}")"
            env_set COPYPARTY_PORT   "$(env_prompt "Copyparty Port" "${COPYPARTY_PORT:-3923}")"
            env_set COPYPARTY_CTID   "$(env_prompt "Copyparty CTID" "${COPYPARTY_CTID:-107}")"
            ;;
        "FASTFETCH")
            # no configurable ENV vars
            ;;
        "OHMYZSH")
            # no configurable ENV vars
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
