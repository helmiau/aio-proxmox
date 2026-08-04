#!/bin/bash

# Service lifecycle management for Debian → Proxmox VE Homelab Installer
# Handles install, uninstall, update, reinstall, status, start, stop, restart

# Source common library
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Ensure Proxmox tools are in PATH
# (handled globally in lib/common.sh — unconditional export)

# Service action dispatcher
dispatch_action() {
    local action="$1"
    local service_name="$2"
    local service_script="svc-${service_name}.sh"

    if [[ ! -f "$service_script" ]]; then
        log_error "Service script $service_script not found"
        return 1
    fi

    case "$action" in
        install|uninstall|update|reinstall|status|start|stop|restart)
            log_info "Executing $action for service $service_name"
            "$service_script" "$action"
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
            "svc-${service_name}.sh" install
            ;;
        lxc-new)
            log_info "Installing $service_name in new LXC container"
            create_lxc_container "$service_name"
            "svc-${service_name}.sh" install
            ;;
        lxc-existing)
            local var_name="TARGET_${service_name^^}_CTID"
            local target_ctid="${!var_name}"  # TARGET_<NAME>_CTID from environment
            if [[ -z "$target_ctid" ]]; then
                log_error "TARGET_${service_name^^}_CTID not set for lxc-existing mode"
                return 1
            fi
            log_info "Installing $service_name in existing LXC container $target_ctid"
            "svc-${service_name}.sh" install
            ;;
        ask)
            log_info "Interactive installation for $service_name"
            read -p "Install $service_name on host (h), new LXC (n), or existing LXC (e)? [h/n/e]: " choice
            case "$choice" in
                h|H)
                    "svc-${service_name}.sh" install
                    ;;
                n|N)
                    create_lxc_container "$service_name"
                    "svc-${service_name}.sh" install
                    ;;
                e|E)
                    read -p "Enter target CTID: " target_ctid
                    "svc-${service_name}.sh" install
                    ;;
                *)
                    log_error "Invalid choice"
                    return 1
                    ;;
            esac
            ;;
        yes)
            log_info "Non-interactive install of $service_name on host"
            "svc-${service_name}.sh" install
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
        "svc-${service_name}.sh" uninstall
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
        "svc-${service_name}.sh" update
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
        "svc-${service_name}.sh" uninstall
        "svc-${service_name}.sh" install
        log_info "Service $service_name reinstalled successfully"
    else
        log_info "Service $service_name not installed, performing install instead"
        "svc-${service_name}.sh" install
    fi
}

# Get service status
get_service_status() {
    local service_name="$1"

    if is_service_installed "$service_name"; then
        log_info "Service $service_name is installed"
        "svc-${service_name}.sh" status
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

    # Check if container already exists
    if pct list | grep -q "^$hostname"; then
        log_info "LXC container $hostname already exists"
        return 0
    fi

    log_info "Creating LXC container $hostname (CTID will be assigned)"

    # Create container
    local var_password="LXC_${prefix}_PASSWORD"
    local password="${!var_password:-${DEFAULT_LXC_ROOT_PASSWORD:-}}"
    
    pct create "$hostname" debian:trixie \
        --hostname "$hostname" \
        --memory "$ram_mb" "$swap_mb" \
        --disk "$disk_gb" \
        --cores "$cores" \
        --net0 "name=eth0,bridge=$bridge,ip=$ip/$cidr,gw=$gateway" \
        --nameserver "8.8.8.8" \
        --timezone "Europe/Berlin" \
        --password "$password" \
        --ssh-keys "${SSH_PUBLIC_KEY:-}"

    if [[ $? -eq 0 ]]; then
        log_info "LXC container $hostname created successfully"
    else
        log_error "Failed to create LXC container $hostname"
        return 1
    fi
}

# Main entry point
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "Service actions library loaded. Use: source lib/service-actions.sh"
fi