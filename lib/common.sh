#!/bin/bash

# Common utilities for Debian → Proxmox VE Homelab Installer
# Shared functions used across all scripts

# Fallback log functions (overridden by logging.sh if sourced later)
log_info() {
    echo "[INFO] $1"
}

log_warn() {
    echo "[WARN] $1"
}

log_error() {
    echo "[ERROR] $1"
}

# Ensure Proxmox tools are in PATH if PVE is installed
if command -v pveversion >/dev/null 2>&1; then
    export PATH="/usr/sbin:/sbin:/usr/bin:/bin:/usr/local/sbin:/usr/local/bin" || true
fi

# Ensure pmxcfs is mounted (call before pct commands)
ensure_pmxcfs() {
    if [[ -d "/etc/pve/nodes" ]]; then
        return 0
    fi
    log_warn "PVE Cluster filesystem (/etc/pve) not mounted. Attempting to start pve-cluster..."
    systemctl stop pve-cluster 2>/dev/null || true
    systemctl reset-failed pve-cluster 2>/dev/null || true
    systemctl start pve-cluster || { log_error "Failed to start pve-cluster"; return 1; }
    local retries=5
    local retry_delay=2
    local mounted=0
    for ((i=0; i<retries; i++)); do
        if [[ -d "/etc/pve/nodes" ]]; then
            mounted=1
            break
        fi
        sleep $retry_delay
    done
    if (( !mounted )); then
        log_error "pmxcfs did not mount after starting pve-cluster"
        return 1
    fi
    return 0
}

# Load environment variables from ENVIRONMENT file
load_env() {
    local env_file="${1:-ENVIRONMENT}"
    if [[ -f "$env_file" ]]; then
        source "$env_file"
    else
        log_error "ENVIRONMENT file not found: $env_file"
        return 1
    fi
}

# Validate environment variables
validate_env() {
    local required_vars=("INSTALL_MODE" "PROXMOX_HOSTNAME" "PROXMOX_IP" "PROXMOX_GATEWAY" "PROXMOX_NETMASK" "PROXMOX_DNS1" "PROXMOX_DNS2")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            log_error "Required environment variable not set: $var"
            return 1
        fi
    done
}

# Check if a service is installed
is_service_installed() {
    local service_name="$1"
    local var_name="INSTALL_${service_name^^}"
    local install_mode="${!var_name}"
    [[ "$install_mode" == "installed" ]]
}

# Mark a service as installed
mark_service_installed() {
    local service_name="$1"
    local var_name="INSTALL_${service_name^^}"
    export "$var_name=installed"
}

# Check if a port is available
is_port_available() {
    local port="$1"
    if ! ss -tuln | grep -q ":$port "; then
        return 0
    else
        return 1
    fi
}

# Exit on error, but allow specific commands to bypass
exit_on_error() {
    local cmd="$1"
    shift
    if ! "$@"; then
        log_error "Command failed: $cmd"
        return 1
    fi
}

# Load environment variables from ENVIRONMENT file
load_env() {
    local env_file="${1:-ENVIRONMENT}"
    if [[ -f "$env_file" ]]; then
        # shellcheck source=/dev/null
        source "$env_file"
        log_info "Loaded environment from $env_file"
    else
        log_error "Environment file $env_file not found"
        return 1
    fi
}

# Validate required environment variables
validate_env() {
    local required_vars=(
        "DOMAIN_ROOT"
        "PVE_HOSTNAME"
        "PVE_MGMT_IP"
        "PVE_MGMT_GATEWAY"
        "PVE_MGMT_CIDR"
    )

    local missing=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required environment variables: ${missing[*]}"
        return 1
    fi

    log_info "Environment validation passed"
}

# Check if a service is already installed
is_service_installed() {
    local service_name="$1"
    local status_file="/var/lib/homelab/service_status.json"

    if [[ -f "$status_file" ]]; then
        if jq -e ".services.\"$service_name\".installed" "$status_file" >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

# Mark a service as installed
mark_service_installed() {
    local service_name="$1"
    local status_file="/var/lib/homelab/service_status.json"

    mkdir -p "$(dirname "$status_file")"

    if [[ -f "$status_file" ]]; then
        jq --arg name "$service_name" '.services[$name].installed = true' "$status_file" >"$status_file.tmp" && mv "$status_file.tmp" "$status_file"
    else
        jq -n --arg name "$service_name" '{"services": {"'$name'": {"installed": true}}}' >"$status_file"
    fi

    log_info "Marked service $service_name as installed"
}

# Check if a port is available
is_port_available() {
    local port="$1"
    local host="${2:-0.0.0.0}"

    if command -v nc >/dev/null 2>&1; then
        if nc -z -w 1 "$host" "$port" 2>/dev/null; then
            return 1
        fi
    fi
    return 0
}

# Check if an IP is available
is_ip_available() {
    local ip="$1"
    local status_file="/var/lib/homelab/allocations.json"

    if [[ -f "$status_file" ]]; then
        if jq -e ".allocations.\"$ip\"" "$status_file" >/dev/null 2>&1; then
            return 1
        fi
    fi
    return 0
}

# Allocate an IP/port in the registry
allocate_resource() {
    local ip="$1"
    local port="$2"
    local service="$3"
    local status_file="/var/lib/homelab/allocations.json"

    mkdir -p "$(dirname "$status_file")"

    if [[ -f "$status_file" ]]; then
        jq --arg ip "$ip" --argjson port "$port" --arg service "$service" \
            '.allocations[$ip] = {"port": $port, "service": $service}' "$status_file" >"$status_file.tmp" && mv "$status_file.tmp" "$status_file"
    else
        jq -n --arg ip "$ip" --argjson port "$port" --arg service "$service" \
            '{"allocations": {"'$ip'": {"port": $port, "service": $service}}}' >"$status_file"
    fi

    log_info "Allocated IP $ip:PORT $port for service $service"
}

# Release an IP/port from the registry
release_resource() {
    local ip="$1"
    local status_file="/var/lib/homelab/allocations.json"

    if [[ -f "$status_file" ]]; then
        if jq --arg ip "$ip" 'del(.allocations[$ip])' "$status_file" >"$status_file.tmp" 2>/dev/null; then
            mv "$status_file.tmp" "$status_file"
            log_info "Released IP $ip from registry"
        fi
    fi
}

# Get next available IP in a subnet
get_next_ip() {
    local subnet="$1"  # e.g., 10.10.40.0/24
    local status_file="/var/lib/homelab/allocations.json"

    # Parse subnet
    local base_ip=$(echo "$subnet" | cut -d'/' -f1)
    local cidr=$(echo "$subnet" | cut -d'/' -f2)
    local mask=$((0xffffffff << (32 - cidr)))
    local network=$(( $(ip_to_int "$base_ip") & mask ))

    # Read existing allocations
    local allocated_ips=()
    if [[ -f "$status_file" ]]; then
        allocated_ips=($(jq -r '.allocations | keys[]' "$status_file" 2>/dev/null))
    fi

    # Find next available IP
    local next_ip=""
    for ((i=1; i<=254; i++)); do
        local test_ip=$(calc_ip "$network" "$i")
        local is_allocated=0

        for allocated in "${allocated_ips[@]}"; do
            if [[ "$allocated" == "$test_ip" ]]; then
                is_allocated=1
                break
            fi
        done

        if [[ $is_allocated -eq 0 ]]; then
            next_ip="$test_ip"
            break
        fi
    done

    if [[ -z "$next_ip" ]]; then
        log_error "No available IP in subnet $subnet"
        return 1
    fi

    echo "$next_ip"
}

# Convert IP to integer
ip_to_int() {
    local ip="$1"
    local IFS=.
    local a b c d
    read a b c d <<<"$ip"
    echo $(((a * 256 + b) * 256 + c) * 256 + d)
}

# Calculate IP from network and offset
calc_ip() {
    local network="$1"
    local offset="$2"

    local network_int=$(ip_to_int "$network")
    local result=$((network_int + offset))

    local a=$(( (result >> 24) & 0xff ))
    local b=$(( (result >> 16) & 0xff ))
    local c=$(( (result >> 8) & 0xff ))
    local d=$(( result & 0xff ))

    echo "$a.$b.$c.$d"
}

# Main entry point for testing
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "Common library loaded. Use: source lib/common.sh"
fi