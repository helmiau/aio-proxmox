#!/bin/bash

# Service lifecycle management for Debian â†’ Proxmox VE Homelab Installer
# Handles install, uninstall, update, reinstall, status, start, stop, restart

# Source common library
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Repo root (for svc-*.sh path resolution)
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"
SERVICE_SCRIPT_DIR="${SERVICE_SCRIPT_DIR:-$REPO_ROOT/scripts}"

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
                log_error "LXC creation failed for $service_name â€” aborting install"
                return 1
            fi
            bash "$(svc_script "$service_name")" install
            ;;
        lxc-existing)
            local var_name="TARGET_${service_name^^}_CTID"
            local target_ctid="${!var_name}"  # TARGET_<NAME>_CTID from environment
            if [[ -z "$target_ctid" ]]; then
                log_error "TARGET_${service_name^^}_CTID not set for lxc-existing mode"
                return 1
            fi
            log_info "Installing $service_name in existing LXC container $target_ctid"
            bash "$(svc_script "$service_name")" install
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
                        log_error "LXC creation failed for $service_name â€” aborting install"
                        return 1
                    fi
                    bash "$(svc_script "$service_name")" install
                    ;;
                e|E)
                    read -p "Enter target CTID: " target_ctid
                    if ! pct status "$target_ctid" >/dev/null 2>&1; then
                        log_error "LXC $target_ctid does not exist or is not running"
                        return 1
                    fi
                    log_info "Using existing LXC $target_ctid"
                    bash "$(svc_script "$service_name")" install
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
        local var="$1" label="$2" cur="${!var:-}"
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
    local bridge="${!var_bridge:-$VM_BR_SERVICE_IP}"
    if [[ -z "$bridge" ]]; then
        bridge="vmbr0"
    fi

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
        log_info "No ${prefix}_CTID set — using next available CTID $ctid"
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
                log_info "Saved ${key}='${val}' → ENVIRONMENT"
            done
            update_env_header "EDITED"
        fi
    fi

    log_info "Creating LXC container $hostname (CTID: $ctid, template: $tmpl_file)"

    local var_password="LXC_${prefix}_PASSWORD"
    local password="${!var_password:-${DEFAULT_LXC_ROOT_PASSWORD:-}}"
    local ostype="debian"
    [[ "$tmpl_file" == alpine-* ]] && ostype="alpine"

    pct create "$ctid" "$storage:vztmpl/$tmpl_file" \
        --hostname "$hostname" \
        --memory "$ram_mb" "$swap_mb" \
        --disk "$disk_gb" \
        --cores "$cores" \
        --net0 "name=eth0,bridge=$bridge,ip=$ip/$cidr,gw=$gateway" \
        --ostype "$ostype" \
        --nameserver "8.8.8.8" \
        --timezone "Europe/Berlin" \
        --password "$password" \
        --ssh-keys "${SSH_PUBLIC_KEY:-}"

    if [[ $? -eq 0 ]]; then
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
