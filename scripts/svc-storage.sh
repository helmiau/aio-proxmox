#!/bin/bash
# svc-storage.sh — Storage Manager stack (P6)
# FBQ + SFTP + FTP + Samba
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$REPO_ROOT/lib/logging.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/service-actions.sh"
source "$REPO_ROOT/lib/env-manager.sh"

[[ -f "$REPO_ROOT/ENVIRONMENT" ]] && load_env "$REPO_ROOT/ENVIRONMENT"

SERVICE_NAME="storage-manager"
ACTION="${1:-status}"

# Config from ENV
IP="${STORAGE_MANAGER_IP:-10.10.40.40}"
ROOT_DIR="${STORAGE_MANAGER_ROOT:-/srv/storage}"
USERS_YAML="${STORAGE_MANAGER_USERS_CONFIG:-/var/lib/storage-manager/users.yaml}"
FB_PORT="${FILEBROWSER_PORT:-8081}"
DEFAULT_PASS="${STORAGE_MANAGER_DEFAULT_PASSWORD:-changeme123}"

ensure_curl

log_service() {
    log_info "[$SERVICE_NAME] $1"
}

ensure_deps() {
    log_service "Installing dependencies (vsftpd, samba, openssh-server, curl, jq, yq)"
    pkg_update
    pkg_install vsftpd samba openssh-server curl jq yq
}

setup_fbq() {
    log_service "Installing File Browser Quantum"
    curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
    
    mkdir -p "/var/lib/filebrowser"
    if [[ ! -f "/var/lib/filebrowser/filebrowser.db" ]]; then
        filebrowser config init --database="/var/lib/filebrowser/filebrowser.db"
        filebrowser config set --address="0.0.0.0" --port="$FB_PORT" --root="$ROOT_DIR" --database="/var/lib/filebrowser/filebrowser.db"
        filebrowser users add admin "$DEFAULT_PASS" --perm.admin --database="/var/lib/filebrowser/filebrowser.db"
    fi

    cat > /etc/systemd/system/filebrowser.service <<EOF
[Unit]
Description=File Browser Quantum
After=network.target

[Service]
User=root
Group=root
ExecStart=/usr/local/bin/filebrowser --database=/var/lib/filebrowser/filebrowser.db
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now filebrowser
}

setup_sftp() {
    log_service "Configuring SFTP (OpenSSH)"
    # Backup original
    [[ ! -f /etc/ssh/sshd_config.bak ]] && cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    
    # Ensure Subsystem sftp internal-sftp
    sed -i 's|^Subsystem\s\+sftp\s\+.*|Subsystem sftp internal-sftp|' /etc/ssh/sshd_config
    
    # Add Match Group storage-users if not exists
    if ! grep -q "Match Group storage-users" /etc/ssh/sshd_config; then
        cat >> /etc/ssh/sshd_config <<EOF

Match Group storage-users
    ChrootDirectory %h
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
EOF
    fi
    
    groupadd -f storage-users
    systemctl restart ssh
}

setup_ftp() {
    log_service "Configuring FTP (vsftpd)"
    cat > /etc/vsftpd.conf <<EOF
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
chroot_local_user=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
user_sub_token=\$USER
local_root=$ROOT_DIR/\$USER
allow_writeable_chroot=YES
EOF
    systemctl restart vsftpd
}

setup_samba() {
    log_service "Configuring Samba"
    # Global config
    cat > /etc/samba/smb.conf <<EOF
[global]
   workgroup = WORKGROUP
   server string = %h server (Samba, Proxmox)
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file
   panic action = /usr/share/samba/panic-action %d
   server role = standalone server
   obey pam restrictions = yes
   unix password sync = yes
   passwd program = /usr/bin/passwd %u
   passwd chat = *Enter\snew\s*\spassword:* %n\n *Retype\snew\s*\spassword:* %n\n *password\supdated\ssuccessfully* .
   pam password change = yes
   map to guest = bad user
   usershare allow guests = yes

EOF
    systemctl restart smbd nmbd
}

action_install() {
    log_service "Starting install"
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Already installed"
        return 0
    fi

    mkdir -p "$ROOT_DIR"
    mkdir -p "$(dirname "$USERS_YAML")"
    [[ ! -f "$USERS_YAML" ]] && echo "users: []" > "$USERS_YAML"

    ensure_deps
    setup_fbq
    setup_sftp
    setup_ftp
    setup_samba

    allocate_resource "$IP" "$FB_PORT" "filebrowser"
    allocate_resource "$IP" "22" "sftp"
    allocate_resource "$IP" "21" "ftp"
    allocate_resource "$IP" "445" "samba"

    mark_service_installed "$SERVICE_NAME"
    log_service "Install completed"
}

action_adduser() {
    local user="$2"
    local path="$3"
    log_service "Adding user: $user -> $path"

    # 1. Linux User
    if ! id "$user" >/dev/null 2>&1; then
        useradd -m -g storage-users -s /usr/sbin/nologin "$user"
        echo "$user:$DEFAULT_PASS" | chpasswd
    fi

    # 2. Path setup
    local full_path="$ROOT_DIR/$user"
    mkdir -p "$full_path"
    chown root:root "$ROOT_DIR"
    chown "$user:storage-users" "$full_path"
    chmod 755 "$full_path"

    # 3. Samba share
    if ! grep -q "\[$user\]" /etc/samba/smb.conf; then
        cat >> /etc/samba/smb.conf <<EOF

[$user]
   path = $full_path
   browseable = yes
   read only = no
   guest ok = no
   valid users = $user
EOF
        (echo "$DEFAULT_PASS"; echo "$DEFAULT_PASS") | smbpasswd -a -s "$user"
        systemctl restart smbd
    fi

    # 4. FBQ User
    filebrowser users add "$user" "$DEFAULT_PASS" --scope "$full_path" --database="/var/lib/filebrowser/filebrowser.db" 2>/dev/null || true

    # 5. Update YAML
    yq -i ".users += [{\"name\": \"$user\", \"path\": \"$path\"}]" "$USERS_YAML"
}

action_status() {
    if is_service_installed "$SERVICE_NAME"; then
        log_service "Status: INSTALLED"
        systemctl is-active filebrowser vsftpd smbd ssh
    else
        log_service "Status: NOT INSTALLED"
    fi
}

# Main dispatch
case "$ACTION" in
    install) action_install ;;
    adduser) action_adduser "$@" ;;
    status) action_status ;;
    uninstall|update|reinstall|start|stop|restart) 
        log_service "Action $ACTION not fully implemented for stack yet"
        ;;
    *) log_error "Unknown action: $ACTION"; exit 1 ;;
esac
