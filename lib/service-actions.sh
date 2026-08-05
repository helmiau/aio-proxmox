#!/bin/bash

# Service lifecycle management for Debian → Proxmox VE Homelab Installer
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
                log_error "LXC creation failed for $service_name — aborting install"
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
                        log_error "LXC creation failed for $service_name — aborting install"
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

    # Ensure pmxcfs is mounted before pct commands
    ensure_pmxcfs || return 1
    
    # Special case mapping for ENV prefixes
    [[ "$prefix" == "9ROUTER" ]] && prefix="ROUTER9"
    [[ "$prefix" == "HERMES-WEBUI" ]] && prefix="HERMES_WEBUI"
    [[ "$prefix" == "MIKROTIK" ]] && prefix="MIKROTIK"
    [[ "$prefix" == "STORAGE" ]] && prefix="STORAGE_MANAGER"

    local var_hostname="${prefix}_HOSTNAME"
    local var_ip="${prefix}_IP"
    local var_cidr="${prefix}_CIDR"
    local var_gateway="${prefix}_GATEWAY"
    local var_ram_mb="${prefix}_RAM_MB"
    local var_swap_mb="${prefix}_SWAP_MB"
    local var_disk_gb="${prefix}_DISK_GB"
    local var_cores="${prefix}_CORES"
    local var_bridge="${prefix}_BRIDGE"
    
    local hostname="${!var_hostname:-}"
    local ip="${!var_ip:-}"
    local cidr="${!var_cidr:-}"
    local gateway="${!var_gateway:-}"
    local ram_mb="${!var_ram_mb:-}"
    local swap_mb="${!var_swap_mb:-}"
    local disk_gb="${!var_disk_gb:-}"
    local cores="${!var_cores:-}"
    local bridge="${!var_bridge:-}"

    if [[ -z "$hostname" || -z "$ip" || -z "$cidr" || -z "$gateway" ]]; then
        log_error "Missing LXC configuration for $service_name"
        return 1
    fi

    # Check if running on Proxmox host (pct command available)
    if ! command -v pct >/dev/null 2>&1; then
        log_error "pct command not found — must run on Proxmox host"
        return 1
    fi

    # Resolve CTID: <PREFIX>_CTID from ENV, else next available
    local var_ctid="${prefix}_CTID"
    local ctid="${!var_ctid:-}"
    if [[ -z "$ctid" ]]; then
        ctid=$(find_next_ctid)
        log_info "No ${prefix}_CTID set — using next available CTID $ctid"
    fi

    # Check if container already exists (by CTID or hostname)
    if pct status "$ctid" >/dev/null 2>&1 || pct list | grep -qw "$hostname"; then
        log_info "LXC container $hostname (CTID: $ctid) already exists"
        return 0
    fi

    # Resolve base OS: alpine (lightweight) or debian (default)
    # Per-service override: <PREFIX>_LXC_TEMPLATE=alpine|debian, else global LXC_TEMPLATE
    local var_template="${prefix}_LXC_TEMPLATE"
    local base_os="${!var_template:-${LXC_TEMPLATE:-debian}}"
    local ostype="debian"
    local template_glob="${DEBIAN13_LXC_TEMPLATE_GLOB:-debian-13-standard*.tar.zst}"
    if [[ "$base_os" == "alpine" ]]; then
        ostype="alpine"
        template_glob="${ALPINE_LXC_TEMPLATE_GLOB:-alpine-3*-standard*.tar.zst}"
    fi

    # Resolve actual template filename; download if missing
    local tmpl_file storage="${LXC_TEMPLATE_STORAGE:-local}"
    tmpl_file=$(pveam list "$storage" 2>/dev/null | grep -E "$template_glob" | awk '{print $1}' | head -n1)
    if [[ -z "$tmpl_file" ]]; then
        log_warn "Template matching '$template_glob' not found on $storage — downloading..."
        if [[ "$ostype" == "alpine" ]] && [[ "${ALPINE_LXC_AUTO_DOWNLOAD:-yes}" == "yes" ]]; then
            pveam update
            tmpl_file=$(pveam available --section system | grep -E "$template_glob" | awk '{print $2}' | head -n1)
            [[ -z "$tmpl_file" ]] && { log_error "Alpine template not available"; return 1; }
            pveam download "$storage" "$tmpl_file"
        else
            log_error "Template not found and auto-download disabled. Run: pveam update && pveam download $storage <template>"
            return 1
        fi
    fi

    # Resolve CTID: <PREFIX>_CTID from ENV, else next available
    local var_ctid="${prefix}_CTID"
    local ctid="${!var_ctid:-}"
    if [[ -z "$ctid" ]]; then
        ctid=$(find_next_ctid)
        log_info "No ${prefix}_CTID set — using next available CTID $ctid"
    fi

    log_info "Creating LXC container $hostname (CTID: $ctid, template: $tmpl_file)"

    # Create container
    local var_password="LXC_${prefix}_PASSWORD"
    local password="${!var_password:-${DEFAULT_LXC_ROOT_PASSWORD:-}}"
    
    pct create "$ctid" "local:vztmpl/$tmpl_file" \
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