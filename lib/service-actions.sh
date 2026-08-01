#!/bin/bash

# Service lifecycle management for Debian → Proxmox VE Homelab Installer
# Handles install, uninstall, update, reinstall, status, start, stop, restart

# Source common library
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

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
    local install_mode="${!INSTALL_${service_name^^}}"  # INSTALL_<NAME> from environment

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
            local target_ctid="${!TARGET_${service_name^^}_CTID}"  # TARGET_<NAME>_CTID from environment
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
        local ip="${!SVC_${service_name^^}_IP}"
        local port="${!SVC_${service_name^^}_PORT}"
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
    local hostname="${!LXC_${service_name^^}_HOSTNAME}"
    local ip="${!LXC_${service_name^^}_IP}"
    local cidr="${!LXC_${service_name^^}_CIDR}"
    local gateway="${!LXC_${service_name^^}_GATEWAY}"
    local ram_mb="${!LXC_${service_name^^}_RAM_MB}"
    local swap_mb="${!LXC_${service_name^^}_SWAP_MB}"
    local disk_gb="${!LXC_${service_name^^}_DISK_GB}"
    local cores="${!LXC_${service_name^^}_CORES}"
    local bridge="${!LXC_${service_name^^}_BRIDGE}"

    if [[ -z "$hostname" || -z "$ip" || -z "$cidr" || -z "$gateway" ]]; then
        log_error "Missing LXC configuration for $service_name"
        return 1
    fi

    # Check if container already exists
    if pct list | grep -q "^$hostname"; then
        log_info "LXC container $hostname already exists"
        return 0
    fi

    log_info "Creating LXC container $hostname (CTID will be assigned)"

    # Create container
    pct create "$hostname" debian:trixie \
        --hostname "$hostname" \
        --memory "$ram_mb" "$swap_mb" \
        --disk "$disk_gb" \
        --cores "$cores" \
        --net0 "name=eth0,bridge=$bridge,ip=$ip/$cidr,gw=$gateway" \
        --nameserver "8.8.8.8" \
        --timezone "Europe/Berlin" \
        --password "${LXC_${service_name^^}_PASSWORD:-${DEFAULT_LXC_ROOT_PASSWORD}}" \
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