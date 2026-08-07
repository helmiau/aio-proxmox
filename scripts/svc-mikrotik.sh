#!/bin/bash
# svc-mikrotik.sh — MikroTik CHR VM (not LXC)
# Source: https://mikrotik.com/download
# Install: qemu-img + virt-install (VM)
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
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

# --- Remote access (WinBox from outside) ---
# NAT: forward port publik (default 8291) ke IP MikroTik di bridge
WINBOX_PORT="${MIKROTIK_WINBOX_PORT:-8291}"
NAT_ENABLE="${MIKROTIK_NAT_ENABLE:-yes}"
NAT_PUBLIC_IF="${MIKROTIK_NAT_PUBLIC_IF:-vmbr0}"     # interface publik (WAN)
NAT_TARGET_IP="${MIKROTIK_WAN_IP:-$IP}"              # IP MikroTik tujuan NAT
# Cloudflare Tunnel TCP (jika cloudflared terpasang)
CF_TUNNEL_ENABLE="${MIKROTIK_CF_TUNNEL_ENABLE:-no}"
CF_TUNNEL_NAME="${MIKROTIK_CF_TUNNEL_NAME:-mikrotik}"
CF_TUNNEL_DOMAIN="${MIKROTIK_CF_TUNNEL_DOMAIN:-$DOMAIN_WINBOX}"

ensure_curl

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

# --- NAT port forward: publik:WINBOX_PORT -> MikroTik:WINBOX_PORT ---
setup_nat_winbox() {
    [[ "$NAT_ENABLE" != "yes" ]] && { log_service "NAT disabled (MIKROTIK_NAT_ENABLE=no)"; return 0; }
    log_service "Setting up NAT: $NAT_PUBLIC_IF:$WINBOX_PORT -> $NAT_TARGET_IP:$WINBOX_PORT (WinBox)"
    # Pastikan IP forwarding aktif
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    # PREROUTING DNAT
    iptables -t nat -C PREROUTING -i "$NAT_PUBLIC_IF" -p tcp --dport "$WINBOX_PORT" -j DNAT --to-destination "${NAT_TARGET_IP}:${WINBOX_PORT}" 2>/dev/null || \
    iptables -t nat -A PREROUTING -i "$NAT_PUBLIC_IF" -p tcp --dport "$WINBOX_PORT" -j DNAT --to-destination "${NAT_TARGET_IP}:${WINBOX_PORT}"
    # FORWARD allow
    iptables -C FORWARD -p tcp -d "$NAT_TARGET_IP" --dport "$WINBOX_PORT" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -p tcp -d "$NAT_TARGET_IP" --dport "$WINBOX_PORT" -j ACCEPT
    # MASQUERADE untuk lalu lintas keluar dari MikroTik via host
    iptables -t nat -C POSTROUTING -s "$NAT_TARGET_IP" -o "$NAT_PUBLIC_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$NAT_TARGET_IP" -o "$NAT_PUBLIC_IF" -j MASQUERADE
    log_success "NAT WinBox aktif: port $WINBOX_PORT -> $NAT_TARGET_IP:$WINBOX_PORT"
}

# --- Cloudflare Tunnel TCP untuk WinBox (via cloudflared) ---
setup_cf_tunnel_winbox() {
    [[ "$CF_TUNNEL_ENABLE" != "yes" ]] && { log_service "Cloudflare tunnel disabled (MIKROTIK_CF_TUNNEL_ENABLE=no)"; return 0; }
    if ! command -v cloudflared >/dev/null 2>&1; then
        log_warn "cloudflared tidak terpasang — skip Cloudflare tunnel (install service cloudflared dulu)"
        return 0
    fi
    local cf_cfg="/etc/cloudflared"
    local cf_yml="$cf_cfg/config.yml"
    log_service "Menambahkan ingress TCP MikroTik ke Cloudflare tunnel"
    # Tambah ingress ke config.yml jika belum ada
    if [[ -f "$cf_yml" ]] && ! grep -q "mikrotik" "$cf_yml"; then
        # Sisipkan ingress sebelum final catch-all (service: http_status:404)
        cp "$cf_yml" "$cf_yml.bak"
        sed -i "/hostname: .*$/!b" "$cf_yml"  # noop placeholder
        # Append ingress block sebelum penutup — pendekatan aman: tambah file terpisah
        log_service "Tunnel config manual: tambahkan ingress di $cf_yml"
    fi
    log_info "Cloudflare TCP tunnel: cloudflared access tcp --hostname ${CF_TUNNEL_DOMAIN:-mikrotik.domain} --url tcp://${NAT_TARGET_IP}:${WINBOX_PORT}"
    log_info "WinBox connect: host ${CF_TUNNEL_DOMAIN:-mikrotik.domain} port $WINBOX_PORT (login: admin, no password)"
}

# --- Bersihkan NAT saat uninstall ---
remove_nat_winbox() {
    [[ "$NAT_ENABLE" != "yes" ]] && return 0
    log_service "Menghapus NAT WinBox"
    iptables -t nat -D PREROUTING -i "$NAT_PUBLIC_IF" -p tcp --dport "$WINBOX_PORT" -j DNAT --to-destination "${NAT_TARGET_IP}:${WINBOX_PORT}" 2>/dev/null || true
    iptables -D FORWARD -p tcp -d "$NAT_TARGET_IP" --dport "$WINBOX_PORT" -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$NAT_TARGET_IP" -o "$NAT_PUBLIC_IF" -j MASQUERADE 2>/dev/null || true
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

    # Remote access: NAT + Cloudflare tunnel (WinBox external)
    setup_nat_winbox
    setup_cf_tunnel_winbox

    register_registry
    mark_service_installed "$SERVICE_NAME"
    log_service "Install completed"
    log_info "WinBox external: IP publik port $WINBOX_PORT -> $NAT_TARGET_IP:$WINBOX_PORT (NAT) atau via Cloudflare tunnel"
}

action_uninstall() {
    log_service "Uninstalling"
    
    virsh destroy "$HOSTNAME" 2>/dev/null || true
    virsh undefine "$HOSTNAME" --remove-all-storage 2>/dev/null || true

    remove_nat_winbox
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
