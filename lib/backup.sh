#!/bin/bash
# lib/backup.sh — P17: backup/restore data service
# Target: direktori PVE (BACKUP_DIR) dan/atau Telegram Bot API
# Scope: config + data dir per service (bukan vzdump penuh)

# --- Source of truth: data dir per service ---
service_data_dirs() {
    local svc="$1"
    case "$svc" in
        9router)        echo "${ROUTER9_DATA_DIR:-/var/lib/9router}" ;;
        headroom)       echo "${HEADROOM_DIR:-/opt/headroom}" ;;
        hermes)         echo "${HERMES_HOME_DIR:-/var/lib/hermes-webui/.hermes}" ;;
        hermes-webui)   echo "${HERMES_WEBUI_DATA_DIR:-/var/lib/hermes-webui}" ;;
        mihomo)         echo "${MIHOMO_DIR:-/etc/mihomo}" ;;
        storage)        echo "/var/lib/storage-manager" ;;
        copyparty)      echo "${COPYPARTY_ROOT:-/srv/copyparty}" ;;
        xui)            echo "${XUI_DATA_DIR:-/var/lib/x-ui}" ;;
        cloudflared)    echo "/etc/cloudflared" ;;
        tailscale)      echo "/var/lib/tailscale" ;;
        ttyd)           echo "/etc/ttyd" ;;
        mikrotik)       echo "/var/lib/libvirt/images" ;;
        *)              echo "" ;;
    esac
}

# --- Lokasi backup ---
backup_dir_for() {
    local svc="$1"
    echo "${BACKUP_DIR:-/var/lib/homelab/backups}/$svc"
}

# --- List backup file service ---
list_backups() {
    local svc="$1"
    local dir
    dir="$(backup_dir_for "$svc")"
    if [[ -d "$dir" ]]; then
        ls -1t "$dir"/svc-*.tar.gz 2>/dev/null
    fi
}

# --- Backup service ke direktori +/atau telegram ---
backup_service() {
    local svc="$1"
    local target="${2:-dir}"   # dir | telegram | both
    local dirs
    dirs="$(service_data_dirs "$svc")"
    [[ -z "$dirs" ]] && { log_warn "Tidak ada data dir dikenal untuk $svc — skip backup"; return 1; }

    local bdir
    bdir="$(backup_dir_for "$svc")"
    mkdir -p "$bdir"

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local file="$bdir/svc-${svc}-${ts}.tar.gz"

    log_info "Backup $svc: $dirs → $file"
    # Tar hanya dir yang ada
    local -a existing=()
    local d
    for d in $dirs; do
        [[ -d "$d" ]] && existing+=("$d")
    done
    if (( ${#existing[@]} == 0 )); then
        log_warn "Tidak ada data dir yang ada untuk $svc"
        return 1
    fi
    tar -czf "$file" -C / "${existing[@]#/}" 2>/dev/null || { log_error "Gagal membuat backup $svc"; return 1; }

    log_success "Backup dibuat: $file ($(du -h "$file" | cut -f1))"

    # Kirim ke Telegram jika diminta
    if [[ "$target" == "telegram" || "$target" == "both" ]] && [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
        send_telegram "$file" "Backup $svc"
    elif [[ "$target" == "dir" ]] && [[ "${BACKUP_TARGET:-dir}" == *"telegram"* ]]; then
        # Otomatis kirim juga ke telegram jika BACKUP_TARGET termasuk telegram
        [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && send_telegram "$file" "Backup $svc" || true
    fi

    # Rotasi: simpan max BACKUP_MAX_KEEP
    local max_keep="${BACKUP_MAX_KEEP:-5}"
    ls -1t "$bdir"/svc-*.tar.gz 2>/dev/null | tail -n +$((max_keep + 1)) | xargs -r rm -f
    log_info "Rotasi backup $svc: simpan maksimal $max_keep file"
    return 0
}

# --- Kirim file ke Telegram (document) ---
send_telegram() {
    local file="$1"
    local caption="${2:-Backup}"
    [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || { log_warn "TELEGRAM_BOT_TOKEN kosong — skip Telegram"; return 1; }
    ensure_curl
    log_info "Mengirim $file ke Telegram..."
    curl -sS -F "chat_id=${TELEGRAM_ALLOWED_USER_IDS%% *}" \
        -F "caption=$caption" \
        -F "document=@$file" \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" >/dev/null 2>&1 \
        && log_success "Terkirim ke Telegram" \
        || { log_error "Gagal kirim ke Telegram"; return 1; }
}

# --- Restore service dari backup ---
restore_service() {
    local svc="$1"
    local file="${2:-}"
    if [[ -z "$file" ]]; then
        # Pilih dari list
        file="$(list_backups "$svc" | head -n1)"
        if [[ -z "$file" ]]; then
            log_error "Tidak ada backup untuk $svc"
            return 1
        fi
        log_info "Menggunakan backup terbaru: $file"
    fi
    [[ -f "$file" ]] || { log_error "File backup tidak ada: $file"; return 1; }

    log_warn "Restore $svc dari $file akan MENIMPA data saat ini"
    read -r -p "Lanjutkan restore? (y/N): " confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { log_info "Dibatalkan"; return 1; }

    # Deteksi path dari tar (relatif ke /)
    log_info "Mengekstrak $file ke lokasi asal..."
    tar -xzf "$file" -C / 2>/dev/null || { log_error "Gagal restore $svc"; return 1; }
    log_success "Restore $svc selesai"
    return 0
}
