#!/bin/bash

# LXC management helpers for Debian → Proxmox VE Homelab Installer
# Functions for creating, managing, and interacting with LXC containers

# Source common library
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Create a new LXC container
create_lxc_container() {
    local service_name="$1"
    local hostname="${2:-$service_name}"
    local ip="${3:-}"
    local cidr="${4:-24}"
    local gateway="${5:-$VM_BR_SERVICE_IP}"
    local ram_mb="${6:-$LXC_DEFAULT_RAM_MB}"
    local swap_mb="${7:-$LXC_DEFAULT_SWAP_MB}"
    local disk_gb="${8:-$LXC_DEFAULT_DISK_GB}"
    local cores="${9:-$LXC_DEFAULT_CORES}"
    local bridge="${10:-$LXC_DEFAULT_BRIDGE}"

    # Find next available CTID
    local ctid=$(find_next_ctid)

    # Create container
    log_info "Creating LXC container $hostname (CTID: $ctid)"
    pct create "$ctid" "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst" \
        --hostname "$hostname" \
        --memory "$ram_mb" \
        --swap "$swap_mb" \
        --cores "$cores" \
        --net0 "name=eth0,bridge=$bridge,ip=$ip/$cidr,gw=$gateway" \
        --nameserver "8.8.8.8" \
        --timezone "Europe/Berlin" \
        --password "${LXC_ROOT_PASSWORD:-changeme}" \
        --ssh-keys "${SSH_PUBLIC_KEY:-}" \
        --ostype debian \
        --unprivileged 1 \
        --features "nesting=1"

    if [[ $? -eq 0 ]]; then
        log_info "LXC container $hostname created successfully (CTID: $ctid)"
        return 0
    else
        log_error "Failed to create LXC container $hostname"
        return 1
    fi
}

# Start an LXC container
start_lxc_container() {
    local ctid="$1"
    pct start "$ctid"
}

# Stop an LXC container
stop_lxc_container() {
    local ctid="$1"
    pct stop "$ctid"
}

# Destroy an LXC container
destroy_lxc_container() {
    local ctid="$1"
    local force="${2:-false}"

    if [[ "$force" == "true" ]]; then
        pct destroy "$ctid" --purge
    else
        pct destroy "$ctid"
    fi
}

# Execute a command in an LXC container
exec_lxc_container() {
    local ctid="$1"
    shift
    pct exec "$ctid" -- "$@"
}

# Check if an LXC container exists
lxc_container_exists() {
    local ctid="$1"
    pct status "$ctid" >/dev/null 2>&1
}

# Find next available CTID
find_next_ctid() {
    local used_ctids=$(pct list | awk 'NR>1 {print $1}' | sort -n)
    local next_ctid=100

    for ctid in $used_ctids; do
        if [[ $next_ctid -lt $ctid ]]; then
            break
        fi
        next_ctid=$((ctid + 1))
    done

    echo "$next_ctid"
}

# Backup an LXC container
backup_lxc_container() {
    local ctid="$1"
    local backup_dir="${BACKUP_DIR:-/backup}"
    local backup_file="$backup_dir/vzdump-lxc-$ctid-$(date +%Y%m%d_%H%M%S).tar.gz"

    vzdump "$ctid" --compress gzip --output stdout > "$backup_file"
    if [[ $? -eq 0 ]]; then
        log_info "Backup created: $backup_file"
        return 0
    else
        log_error "Backup failed for LXC $ctid"
        return 1
    fi
}

# Restore an LXC container from backup
restore_lxc_container() {
    local backup_file="$1"
    local ctid="${2:-$(find_next_ctid)}"

    pct restore "$ctid" "$backup_file"
    if [[ $? -eq 0 ]]; then
        log_info "LXC container restored (CTID: $ctid)"
        return 0
    else
        log_error "Failed to restore LXC container"
        return 1
    fi
}

# Main entry point
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "LXC management helpers loaded. Use: source lib/lxc.sh"
fi