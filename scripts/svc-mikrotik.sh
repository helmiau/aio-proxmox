#!/bin/bash
# svc-mikrotik.sh — MikroTik CHR VM (not LXC)
# Source: https://mikrotik.com/download
# Install: qemu-img + virt-install (VM)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/service-actions.sh"
source "$REPO_ROOT/lib/env-manager.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

SERVICE_NAME="mikrotik-chr"
ACTION="${1:-status}"

# Config from ENV
VMID="${MIKROTIK_VMID:-108}"
HOSTNAME="${MIKROTIK_HOSTNAME:-mikrotik-chr}"
IP="${MIKROTIK_IP:-10.10.40.80}"
CIDR="${MIKROTIK_CIDR:-24}"
GATEWAY="${MIKROTIK_GATEWAY:-10.10.40.1}"
RAM_MB="${MIKROTIK_RAM_MB:-1024}"
SWAP_MB="${MIKROTIK_SWAP_MB:-1024}"
DISK_GB="${MIKROTIK_DISK_GB:-16}"
ISO_URL="${MIKROTIK_ISO_URL:-https://download.mikrotik.com/routeros/7.14.3/chr-7.14.3.img.zip}"

# Paths
VM_DIR="/var/lib/libvirt/images"
ISO_PATH="$VM_DIR/mikrotik-chr.img"

log_service() {
    log_info "[$SERVICE_NAME] $1"
}

ensure_kvm() {
    if ! command -v virt-install >/dev/null 2>&1; then
        log_service "Installing KVM tools"
        pkg_update
        pkg_install qemu-kvm libvirt-daemon-system virtinst virt-viewer
    fi
}

create_vm() {
    log_service "Creating VM"
    
    # Download ISO
    if [[ ! -f "$ISO_PATH" ]]; then
        curl -fsSL "$ISO_URL" -o "$ISO_PATH"
    fi

    # Create VM
    virt-install \
        --name="$HOSTNAME" \
        --memory="$RAM_MB" \
        --vcpus=1 \
        --disk path="$VM_DIR/$HOSTNAME.qcow2",size="$DISK_GB" \
        --import \
        --os-type=linux \
        --os-variant=generic \
        --network bridge=vmbr0,model=virtio \
        --graphics none \
        --noautoconsole \
        --import \
        --cdrom="$ISO_PATH"

    # Set network
    virsh net-update vmbr0 add ip-dhcp-host \
        "<host mac='52:54:00:$(printf '%02x:%02x' $((RANDOM%256)) $((RANDOM%256)))' name='$HOSTNAME' ip='$IP'/>

    # Start VM
    virsh start "$HOSTNAME"
}

register_registry() {
    allocate_resource "$IP" "22" "$SERVICE_NAME-ssh"
    allocate_resource "$IP" "80" "$SERVICE_NAME-web"
}

unregister_registry() {
    release_resource "$IP" "$SERVICE_NAME-ssh"
    release_resource "$IP" "$SERVICE_NAME-web"
}

action_install() {
    log_service "Starting install (mode: ${MIKROTIK_CHR_INSTALL_MODE:-vm})"    
    # P8: Interactive prompt if ENV is DEFAULT
    prompt_service_env "MIKROTIK"    
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed, skipping"
        return 0
    fi

    ensure_kvm
    create_vm

    register_registry
    mark_service_installed "$SERVICE_NAME"
    log_service "Install completed"
}

action_uninstall() {
    log_service "Uninstalling"
    
    virsh destroy "$HOSTNAME" 2>/dev/null || true
    virsh undefine "$HOSTNAME" --remove-all-storage 2>/dev/null || true

    unregister_registry
    
    local status_file="/var/lib/homelab/service_status.json"
    if [[ -f "$status_file" ]]; then
        jq --arg name "$SERVICE_NAME" 'del(.services[$name])' "$status_file" >"$status_file.tmp" && mv "$status_file.tmp" "$status_file"
    fi

    log_service "Uninstall completed"
}

action_update() {
    log_service "Updating"
    
    if ! is_service_installed "$SERVICE_NAME"; then
        log_service "Not installed, installing instead"
        action_install
        return
    fi

    log_service "Update requires manual intervention via RouterOS web interface"
}

action_status() {
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Status: INSTALLED"
        virsh list --all | grep "$HOSTNAME" || true
    else
        log_service "Status: NOT INSTALLED"
    fi
}

action_start() {
    virsh start "$HOSTNAME"
}

action_stop() {
    virsh shutdown "$HOSTNAME"
}

action_restart() {
    virsh reboot "$HOSTNAME"
}

action_reinstall() {
    action_uninstall
    action_install
}

# Main dispatch
case "$ACTION" in
    install) action_install ;;
    uninstall) action_uninstall ;;
    update) action_update ;;
    reinstall) action_reinstall ;;
    status) action_status ;;
    start) action_start ;;
    stop) action_stop ;;
    restart) action_restart ;;
    *) log_error "Unknown action: $ACTION"; exit 1 ;;
esac
