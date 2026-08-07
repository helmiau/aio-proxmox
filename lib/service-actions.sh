#!/bin/bash

# Service lifecycle management for Debian ???????? Proxmox VE Homelab Installer
# Handles install, uninstall, update, reinstall, status, start, stop, restart

# Source common library
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Repo root (for svc-*.sh path resolution)
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"
SERVICE_SCRIPT_DIR="${SERVICE_SCRIPT_DIR:-$REPO_ROOT/scripts}"

# CTID terakhir yang berhasil dibuat (untuk run_service_in_lxc)
LAST_CREATED_CTID=""

# Resolve a service script path
svc_script() {
    echo "${SERVICE_SCRIPT_DIR}/svc-$1.sh"
}

# Service action dispatcher
dispatch_action() {
    local action="$1"
    local service_name="$2"
    local service_script
    service_script="$(svc_script "$service_name")"

    if [[ ! -f "$service_script" ]]; then
        log_error "Service script $service_script not found"
        return 1
    fi

    case "$action" in
        install|uninstall|update|reinstall|status|start|stop|restart)
            log_info "Executing $action for service $service_name"
            bash "$service_script" "$action"
            local result=$?
            if [[ $result -eq 0 ]]; then
                log_info "Service $service_name $action completed successfully"
            else
                log_error "Service $service_name $action failed with exit code $result"
            fi
            return $result
            ;;
        *)
            log_error "Unknown action: $action"
            return 1
            ;;
    esac
}

# Install a service
# Jalankan svc script di dalam LXC container (fleksibel: host vs container)
# - Copy lib/ + ENVIRONMENT + script ke container
# - Eksekusi bash svc.sh <action> di dalam container
# ctid kosong = host mode (jalankan langsung)
run_service_in_lxc() {
    local ctid="$1" service_name="$2" action="$3"
    local script
    script="$(svc_script "$service_name")"

    if [[ -z "$ctid" ]]; then
        bash "$script" "$action"
        return $?
    fi

    # Pastikan container ADA dan RUNNING (pct push/exec butuh running)
    if ! pct status "$ctid" >/dev/null 2>&1; then
        log_error "LXC $ctid tidak ada"
        return 1
    fi
    local cstate
    cstate=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')

    # Auto-fix net0 jika bridge tidak valid (sebelum start)
    local net0 cur_bridge
    net0=$(pct config "$ctid" 2>/dev/null | grep -E '^net0:' | head -n1)
    if [[ -n "$net0" ]]; then
        cur_bridge=$(echo "$net0" | grep -oE 'bridge=[^,]+' | head -n1 | cut -d= -f2)
        if [[ -n "$cur_bridge" ]]; then
            local -a brs
            mapfile -t brs < <(list_bridges)
            local found=false
            for b in "${brs[@]}"; do
                [[ "$b" == "$cur_bridge" ]] && { found=true; break; }
            done
            if [[ "$found" != true ]]; then
                log_warn "Bridge '$cur_bridge' pada LXC $ctid tidak valid"
                local newbridge
                newbridge="$(pick_bridge)"
                if [[ -n "$newbridge" && "$newbridge" != "$cur_bridge" ]]; then
                    local newnet0
                    newnet0=$(echo "$net0" | sed "s/bridge=$cur_bridge/bridge=$newbridge/")
                    log_info "Memperbaiki net0: $newnet0"
                    pct set "$ctid" --net0 "$newnet0" || log_warn "Gagal set net0"
                fi
            fi
        fi
    fi

    if [[ "$cstate" != "running" ]]; then
        log_warn "LXC $ctid sedang $cstate — menyalakan otomatis..."
        if ! pct start "$ctid"; then
            log_error "Gagal menyalakan LXC $ctid"
            return 1
        fi
        # Tunggu sampai benar-benar running (maks 30 detik)
        local tries=15
        for ((i=0; i<tries; i++)); do
            if [[ "$(pct status "$ctid" 2>/dev/null | awk '{print $2}')" == "running" ]]; then
                break
            fi
            sleep 2
        done
        if [[ "$(pct status "$ctid" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
            log_error "LXC $ctid tidak kunjung running"
            return 1
        fi
        log_success "LXC $ctid sekarang running"
    fi

    local tmpdir="/tmp/aio-lxc"
    pct exec "$ctid" -- mkdir -p "$tmpdir/lib" 2>/dev/null || true
    for lib in common logging service-actions env-manager; do
        pct push "$ctid" "$REPO_ROOT/lib/$lib.sh" "$tmpdir/lib/$lib.sh" 2>/dev/null || true
    done
    [[ -f "$REPO_ROOT/ENVIRONMENT" ]] && pct push "$ctid" "$REPO_ROOT/ENVIRONMENT" "$tmpdir/ENVIRONMENT" 2>/dev/null || true
    pct push "$ctid" "$script" "$tmpdir/svc.sh" || { log_error "Gagal copy script ke LXC"; return 1; }

    log_info "Menjalankan $service_name $action di dalam LXC $ctid"
    # Export REPO_ROOT agar svc script menemukan lib di /tmp/aio-lxc
    pct exec "$ctid" -- env REPO_ROOT="$tmpdir" bash "$tmpdir/svc.sh" "$action"
}

# Install a service
install_service() {
    local service_name="$1"
    local var_name="INSTALL_${service_name^^}"
    local install_mode="${!var_name}"

    if [[ -z "$install_mode" ]]; then
        install_mode="ask"
    fi

    case "$install_mode" in
        host)
            log_info "Installing $service_name on host"
            bash "$(svc_script "$service_name")" install
            ;;
        lxc-new)
            log_info "Installing $service_name in new LXC container"
            if ! create_lxc_container "$service_name"; then
                log_error "LXC creation failed for $service_name — aborting install"
                return 1
            fi
            run_service_in_lxc "$LAST_CREATED_CTID" "$service_name" install
            ;;
        lxc-existing)
            local var_name="TARGET_${service_name^^}_CTID"
            local target_ctid="${!var_name}"  # TARGET_<NAME>_CTID from environment
            if [[ -z "$target_ctid" ]]; then
                log_error "TARGET_${service_name^^}_CTID not set for lxc-existing mode"
                return 1
            fi
            log_info "Installing $service_name in existing LXC container $target_ctid"
            run_service_in_lxc "$target_ctid" "$service_name" install
            ;;
        ask)
            log_info "Interactive installation for $service_name"
            read -p "Install $service_name on host (h), new LXC (n), or existing LXC (e)? [h/n/e]: " choice
            case "$choice" in
                h|H)
                    bash "$(svc_script "$service_name")" install
                    ;;
                n|N)
                    if ! create_lxc_container "$service_name"; then
                        log_error "LXC creation failed for $service_name — aborting install"
                        return 1
                    fi
                    run_service_in_lxc "$LAST_CREATED_CTID" "$service_name" install
                    ;;
                e|E)
                    read -p "Enter target CTID: " target_ctid
                    if ! pct status "$target_ctid" >/dev/null 2>&1; then
                        log_error "LXC $target_ctid does not exist"
                        return 1
                    fi
                    log_info "Using existing LXC $target_ctid (auto-start jika stopped)"
                    run_service_in_lxc "$target_ctid" "$service_name" install
                    ;;
                *)
                    log_error "Invalid choice"
                    return 1
                    ;;
            esac
            ;;
        yes)
            log_info "Non-interactive install of $service_name on host"
            bash "$(svc_script "$service_name")" install
            ;;
        no)
            log_info "Skipping $service_name installation"
            ;;
        *)
            log_error "Unknown install mode: $install_mode"
            return 1
            ;;
    esac
}

# Uninstall a service
uninstall_service() {
    local service_name="$1"

    if is_service_installed "$service_name"; then
        log_info "Uninstalling $service_name"
        bash "$(svc_script "$service_name")" uninstall
        # Release allocated resources
        local var_ip="SVC_${service_name^^}_IP"
        local var_port="SVC_${service_name^^}_PORT"
        local ip="${!var_ip}"
        local port="${!var_port}"
        if [[ -n "$ip" && -n "$port" ]]; then
            release_resource "$ip" "$port" "$service_name"
        fi
        # Remove from status file
        local status_file="/var/lib/homelab/service_status.json"
        if [[ -f "$status_file" ]]; then
            ensure_jq
            jq --arg name "$service_name" 'del(.services[$name])' "$status_file" >"$status_file.tmp" && mv "$status_file.tmp" "$status_file"
        fi
        log_info "Service $service_name uninstalled successfully"
    else
        log_info "Service $service_name not installed"
    fi
}

# Update a service
update_service() {
    local service_name="$1"

    if is_service_installed "$service_name"; then
        log_info "Updating $service_name"
        bash "$(svc_script "$service_name")" update
        log_info "Service $service_name updated successfully"
    else
        log_info "Service $service_name not installed, skipping update"
    fi
}

# Reinstall a service
reinstall_service() {
    local service_name="$1"

    if is_service_installed "$service_name"; then
        log_info "Reinstalling $service_name"
        bash "$(svc_script "$service_name")" uninstall
        bash "$(svc_script "$service_name")" install
        log_info "Service $service_name reinstalled successfully"
    else
        log_info "Service $service_name not installed, performing install instead"
        bash "$(svc_script "$service_name")" install
    fi
}

# Get service status
get_service_status() {
    local service_name="$1"

    if is_service_installed "$service_name"; then
        log_info "Service $service_name is installed"
        bash "$(svc_script "$service_name")" status
    else
        log_info "Service $service_name is not installed"
    fi
}

# Create LXC container
create_lxc_container() {
    local service_name="$1"
    local prefix="${service_name^^}"

    ensure_pmxcfs || return 1

    [[ "$prefix" == "9ROUTER" ]] && prefix="ROUTER9"
    [[ "$prefix" == "HERMES-WEBUI" ]] && prefix="HERMES_WEBUI"
    [[ "$prefix" == "MIKROTIK" ]] && prefix="MIKROTIK"
    [[ "$prefix" == "STORAGE" ]] && prefix="STORAGE_MANAGER"

    local overrides=()
    prompt_field() {
        local var="$1" label="$2" cur=""
        if declare -p "$var" >/dev/null 2>&1; then
            cur="${!var}"
        fi
        local val=""
        if [[ -n "$cur" ]]; then
            read -r -p "[$label] default ENV: $cur (Enter=default / override): " val
            val="${val:-$cur}"
        else
            read -r -p "[$label] (kosong = lewati): " val
        fi
        if [[ -n "$val" ]]; then
            if [[ "$val" != "$cur" ]]; then
                overrides+=("$var=$val")
            fi
            echo "$val"
        fi
    }

    local hostname ip cidr gateway ram_mb swap_mb disk_gb cores
    hostname="$(prompt_field "${prefix}_HOSTNAME" "Hostname")"
    ip="$(prompt_field "${prefix}_IP" "IP")"
    cidr="$(prompt_field "${prefix}_CIDR" "CIDR")"
    gateway="$(prompt_field "${prefix}_GATEWAY" "Gateway")"
    ram_mb="$(prompt_field "${prefix}_RAM_MB" "RAM (MB)")"
    swap_mb="$(prompt_field "${prefix}_SWAP_MB" "Swap (MB)")"
    disk_gb="$(prompt_field "${prefix}_DISK_GB" "Disk (GB)")"
    cores="$(prompt_field "${prefix}_CORES" "Cores")"

    if [[ -z "$hostname" || -z "$ip" || -z "$cidr" || -z "$gateway" ]]; then
        log_error "Missing LXC configuration for $service_name (hostname/ip/cidr/gateway wajib)"
        return 1
    fi

    local var_bridge="${prefix}_BRIDGE"
    local bridge="${!var_bridge:-$VM_BR_SERVICE}"
    if [[ -z "$bridge" ]]; then
        bridge="vmbr40"
    fi
    # Validasi/listing bridge sebelum create (hindari bridge salah)
    bridge="$(ensure_valid_bridge "$bridge")"
    [[ -z "$bridge" ]] && { log_error "Bridge tidak dipilih — aborting"; return 1; }

    local picked
    picked=$(pick_lxc_template)
    if [[ -z "$picked" ]]; then
        log_error "No template selected — aborting LXC creation"
        return 1
    fi
    local storage="${picked%%:vztmpl/*}"
    local tmpl_file="${picked##*:vztmpl/}"

    local var_ctid="${prefix}_CTID"
    local ctid="${!var_ctid:-}"
    if [[ -z "$ctid" ]]; then
        ctid=$(find_next_ctid)
        log_info "No ${prefix}_CTID set ??? using next available CTID $ctid"
    else
        local new_ctid
        new_ctid="$(prompt_field "${prefix}_CTID" "CTID")"
        [[ -n "$new_ctid" ]] && ctid="$new_ctid"
    fi

    if pct status "$ctid" >/dev/null 2>&1 || pct list | grep -qw "$hostname"; then
        log_info "LXC container $hostname (CTID: $ctid) already exists"
        return 0
    fi

    if (( ${#overrides[@]} > 0 )); then
        read -r -p "Simpan ${#overrides[@]} override ke ENVIRONMENT? (y/N): " save_ov
        if [[ "$save_ov" == "y" || "$save_ov" == "Y" ]]; then
            for ov in "${overrides[@]}"; do
                local key="${ov%%=*}" val="${ov#*=}"
                if grep -q "^${key}=" "$ENV_FILE"; then
                    sed -i "s|^${key}=.*|${key}='${val}'|" "$ENV_FILE"
                else
                    echo "${key}='${val}'" >> "$ENV_FILE"
                fi
                log_info "Saved ${key}='${val}' ??? ENVIRONMENT"
            done
            update_env_header "EDITED"
        fi
    fi

    log_info "Creating LXC container $hostname (CTID: $ctid, template: $tmpl_file)"

    local var_password="LXC_${prefix}_PASSWORD"
    local def_lxc_pass="${DEFAULT_LXC_ROOT_PASSWORD:-changeme}"
    local password="${!var_password:-$def_lxc_pass}"
    local ostype="debian"
    [[ "$tmpl_file" == alpine-* ]] && ostype="alpine"

    pct create "$ctid" "$storage:vztmpl/$tmpl_file" \
        --hostname "$hostname" \
        --memory "$ram_mb" \
        --swap "$swap_mb" \
        --cores "$cores" \
        --rootfs "$storage:${disk_gb}" \
        --net0 "name=eth0,bridge=$bridge,ip=$ip/$cidr,gw=$gateway" \
        --ostype "$ostype" \
        --nameserver "8.8.8.8" \
        --timezone "Europe/Berlin" \
        --password "$password" \
        --unprivileged 1 \
        --features "nesting=1"

    if [[ $? -eq 0 ]]; then
        LAST_CREATED_CTID="$ctid"
        log_success "LXC container $hostname created successfully (CTID: $ctid)"
    else
        log_error "Failed to create LXC container $hostname (CTID: $ctid)"
        return 1
    fi
}

# Find next available CTID (100+)
find_next_ctid() {
    local used
    used=$(pct list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n)
    local next=100
    for c in $used; do
        if [[ "$next" -lt "$c" ]]; then
            break
        fi
        next=$((c + 1))
    done
    echo "$next"
}

# Main entry point
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "Service actions library loaded. Use: source lib/service-actions.sh"
fi
