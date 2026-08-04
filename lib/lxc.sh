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
    local template="${11:-$LXC_TEMPLATE}"

    # Find next available CTID
    local ctid=$(find_next_ctid)

    # Resolve template: Alpine (lightweight) vs Debian default
    # Alpine: ostype=alpine, uses *-standard*.tar.zst
    local ostype="debian"
    local template_glob="${DEBIAN13_LXC_TEMPLATE_GLOB:-debian-13-standard*.tar.zst}"
    if [[ "$template" == "alpine" || "$template" == "alpine-3"* ]]; then
        ostype="alpine"
        template_glob="${ALPINE_LXC_TEMPLATE_GLOB:-alpine-3*-standard*.tar.zst}"
    fi

    # Resolve actual template filename (download if missing)
    local tmpl_file
    tmpl_file=$(pveam list "$LXC_TEMPLATE_STORAGE" 2>/dev/null | grep -E "$template_glob" | awk '{print $1}' | head -n1)
    if [[ -z "$tmpl_file" ]]; then
        log_warn "Template matching '$template_glob' not found on $LXC_TEMPLATE_STORAGE — attempting download..."
        if [[ "$ostype" == "alpine" ]] && [[ "${ALPINE_LXC_AUTO_DOWNLOAD:-yes}" == "yes" ]]; then
            pveam update
            tmpl_file=$(pveam available --section system | grep -E "$template_glob" | awk '{print $2}' | head -n1)
            [[ -z "$tmpl_file" ]] && { log_error "Alpine template not available"; return 1; }
            pveam download "$LXC_TEMPLATE_STORAGE" "$tmpl_file"
        else
            log_error "Template not found and auto-download disabled. Run: pveam update && pveam download $LXC_TEMPLATE_STORAGE <template>"
            return 1
        fi
    fi

    # Create container
    log_info "Creating LXC container $hostname (CTID: $ctid, template: $tmpl_file)"
    pct create "$ctid" "local:vztmpl/$tmpl_file" \
        --hostname "$hostname" \
        --memory "$ram_mb" \
        --swap "$swap_mb" \
        --cores "$cores" \
        --net0 "name=eth0,bridge=$bridge,ip=$ip/$cidr,gw=$gateway" \
        --nameserver "8.8.8.8" \
        --timezone "Europe/Berlin" \
        --password "${LXC_ROOT_PASSWORD:-changeme}" \
        --ssh-keys "${SSH_PUBLIC_KEY:-}" \
        --ostype "$ostype" \
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