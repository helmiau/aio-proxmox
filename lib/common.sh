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

# Ensure Proxmox tools are in PATH (unconditional — SSH login PATH may lack /usr/sbin)
# Prepend (jangan timpa) agar binary Proxmox tersedia di semua shell
# pct, qm, pveversion live in /usr/sbin:/sbin
for _p in /usr/sbin /sbin /usr/local/sbin /usr/local/bin; do
    case ":$PATH:" in
        *":$_p:"*) ;;
        *) PATH="$_p:$PATH" ;;
    esac
done
export PATH

# Pastikan binary Proxmox umum tersedia — jika belum, coba buat symlink ke /usr/local/bin
# (berguna untuk shell non-login / client SSH tanpa profile)
ensure_pve_binaries() {
    local bin
    for bin in pct qm pveam pvesm pvesh pveversion vzdump; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            local src=""
            for d in /usr/sbin /sbin /usr/bin /usr/local/sbin; do
                if [[ -x "$d/$bin" ]]; then src="$d/$bin"; break; fi
            done
            if [[ -n "$src" && -d /usr/local/bin ]]; then
                ln -sf "$src" "/usr/local/bin/$bin" 2>/dev/null || true
            fi
        fi
    done
}
ensure_pve_binaries

# Setup PATH persist untuk shell login interaktif (SSH client manapun)
# Tulis /etc/profile.d/pve-path.sh — berlaku untuk semua user & shell login
setup_pve_path() {
    local prof="/etc/profile.d/pve-path.sh"
    if [[ -w /etc/profile.d ]] && [[ ! -f "$prof" ]]; then
        cat > "$prof" <<'EOF'
# aio-proxmox: ensure Proxmox CLI tools on PATH for all login shells
case ":$PATH:" in
    *":/usr/sbin:"*) ;;
    *) export PATH="/usr/sbin:/sbin:/usr/local/sbin:$PATH" ;;
esac
EOF
        log_info "PATH setup tersimpan di $prof"
    fi
    # Juga untuk root .bashrc (interactive non-login)
    if [[ -w /root ]]; then
        if [[ -f /root/.bashrc ]] && ! grep -q "pve-path" /root/.bashrc; then
            echo 'export PATH="/usr/sbin:/sbin:$PATH"  # aio-proxmox pve-path' >> /root/.bashrc
        fi
    fi
}

# List bridge network yang tersedia (vmbr0, vmbr30, vmbr40, ...)
list_bridges() {
    local -a brs
    if command -v brctl >/dev/null 2>&1; then
        mapfile -t brs < <(brctl show 2>/dev/null | awk 'NR>1 && $1 ~ /^vmbr/ {print $1}')
    fi
    if (( ${#brs[@]} == 0 )); then
        # fallback: ip link
        mapfile -t brs < <(ip -o link show 2>/dev/null | grep -oE 'vmbr[0-9]+' | sort -u)
    fi
    printf '%s\n' "${brs[@]}"
}

# Pilih bridge via interaktif (default: VM_BR_SERVICE / vmbr40)
# Output: nama bridge ke stdout, atau kosong jika cancel
pick_bridge() {
    local -a brs
    mapfile -t brs < <(list_bridges)
    local def="${VM_BR_SERVICE:-vmbr40}"
    local choicen=0
    if (( ${#brs[@]} > 0 )); then
        echo "" >&2
        echo "--- Available Bridges ---" >&2
        local i=1
        for b in "${brs[@]}"; do
            local mark=""
            [[ "$b" == "$def" ]] && mark=" (default)"
            echo "  $i) $b$mark" >&2
            i=$((i+1))
        done
        read -r -p "Pilih bridge (nomor, Enter=$def, q=cancel): " choicen
        [[ "$choicen" == "q" ]] && { echo ""; return 1; }
        if [[ -z "$choicen" ]]; then
            echo "$def"
            return 0
        fi
        if [[ "$choicen" =~ ^[0-9]+$ ]] && (( choicen >= 1 && choicen <= ${#brs[@]} )); then
            echo "${brs[$((choicen-1))]}"
            return 0
        fi
        echo "Invalid — pakai default $def" >&2
        echo "$def"
        return 0
    fi
    echo "$def"
}

# Validasi bridge ada; jika tidak, listing & auto-fix pilihan user
ensure_valid_bridge() {
    local current="$1"
    local -a brs
    mapfile -t brs < <(list_bridges)
    if (( ${#brs[@]} > 0 )); then
        for b in "${brs[@]}"; do
            [[ "$b" == "$current" ]] && { echo "$current"; return 0; }
        done
    fi
    # bridge tidak valid — minta user pilih
    log_warn "Bridge '$current' tidak ada. Pilih bridge yang tersedia:"
    pick_bridge
}

# --- Script versioning (P13) ---
SCRIPT_VERSION_FILE="${SCRIPT_VERSION_FILE:-$(dirname "${BASH_SOURCE[0]}")/../VERSION}"

get_script_version() {
    local ver="unknown"
    if [[ -f "$SCRIPT_VERSION_FILE" ]]; then
        ver="$(head -n1 "$SCRIPT_VERSION_FILE" | tr -d '[:space:]')"
    fi
    echo "${ver:-unknown}"
}

is_script_version_at_least() {
    # Compare dotted versions, e.g. is_script_version_at_least 4.2.0
    local want="$1"
    local have
    have="$(get_script_version)"
    [[ "$have" == "unknown" ]] && return 1
    # shellcheck disable=SC2046
    IFS='.' read -ra h <<< "$have"
    # shellcheck disable=SC2046
    IFS='.' read -ra w <<< "$want"
    for i in 0 1 2; do
        local hv="${h[$i]:-0}"
        local wv="${w[$i]:-0}"
        if (( hv > wv )); then return 0; fi
        if (( hv < wv )); then return 1; fi
    done
    return 0
}

# Interactive LXC template picker (shared: install menu + service LXC creation)
# Lists downloaded templates first, --- separator, then available. Select by
# number / keyword / full name. Auto-downloads if picked template not present.
# Output: <storage>:vztmpl/<name> or empty on cancel.
pick_lxc_template() {
    # IMPORTANT: hanya path hasil ke stdout; semua UI/echo ke stderr (> >&2)
    # agar caller (tmpl=$(pick_lxc_template)) hanya menerima <storage>:vztmpl/<name>
    local -a storages
    mapfile -t storages < <(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 {print $1}')
    local storage=""
    echo "" >&2
    echo "--- Available Storages (vztmpl) ---" >&2
    local si=1
    for s in "${storages[@]}"; do
        echo "  $si) $s" >&2
        si=$((si+1))
    done
    echo "  99) Create new storage (wizard)" >&2
    local s_choice=""
    read -r -p "Select storage (number/name, 99=new, q=cancel): " s_choice
    [[ "$s_choice" == "q" || -z "$s_choice" ]] && { echo ""; return 1; }
    if [[ "$s_choice" == "99" ]]; then
        create_new_storage
        mapfile -t storages < <(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 {print $1}')
        si=1
        echo "--- Available Storages (vztmpl) ---" >&2
        for s in "${storages[@]}"; do
            echo "  $si) $s" >&2
            si=$((si+1))
        done
        read -r -p "Select storage (number/name, q=cancel): " s_choice
        [[ "$s_choice" == "q" || -z "$s_choice" ]] && { echo ""; return 1; }
    fi
    if [[ "$s_choice" =~ ^[0-9]+$ ]] && (( s_choice >= 1 && s_choice <= ${#storages[@]} )); then
        storage="${storages[$((s_choice-1))]}"
    else
        storage="$s_choice"
    fi

    # --- template listing (downloaded) ---
    local -a dl
    mapfile -t dl < <(pveam list "$storage" 2>/dev/null | awk 'NR>1 {print $1}' | sed 's/^[^:]*:\?vztmpl\///')
    local picked=""
    while [[ -z "$picked" ]]; do
        echo "" >&2
        echo "--- Downloaded Templates on $storage ---" >&2
        local i=1
        if (( ${#dl[@]} > 0 )); then
            for t in "${dl[@]}"; do
                [[ -n "$t" ]] || continue
                echo "  $i) $t" >&2
                i=$((i+1))
            done
        else
            echo "  (belum ada template di $storage)" >&2
        fi
        echo "" >&2
        local choice=""
        read -r -p "Pilih template (nomor / keyword / nama lengkap, q=cancel): " choice
        [[ "$choice" == "q" || -z "$choice" ]] && { echo ""; return 1; }

        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            local n=1 ok=0
            for t in "${dl[@]}"; do
                [[ -n "$t" ]] || continue
                if (( n == choice )); then picked="$t"; ok=1; break; fi
                n=$((n+1))
            done
            (( ok )) || { echo "Invalid number (1-$(( ${#dl[@]} )))" >&2; continue; }
        else
            # keyword / nama lengkap — exact dulu, lalu substring (case-insensitive)
            local -a matches=()
            local t
            for t in "${dl[@]}"; do
                [[ -n "$t" ]] || continue
                if [[ "$t" == "$choice" ]]; then
                    matches=("$t"); break
                elif [[ "${t,,}" == *"${choice,,}"* ]]; then
                    matches+=("$t")
                fi
            done
            if (( ${#matches[@]} == 0 )); then
                echo "Template '$choice' tidak tersedia di $storage" >&2
                read -r -p "Cari & unduh template '$choice' dari pveam? (y/N): " dl_yn
                if [[ "$dl_yn" == "y" || "$dl_yn" == "Y" ]]; then
                    pveam update >/dev/null 2>&1 || true
                    local cand
                    cand=$(pveam available 2>/dev/null | awk -v k="${choice,,}" 'NR>1 && tolower($2) ~ k {print $2}' | head -n1)
                    if [[ -n "$cand" ]]; then
                        echo "Menemukan: $cand — mengunduh..." >&2
                        pveam download "$storage" "$cand" || { echo "Download gagal" >&2; continue; }
                        dl+=("$cand")
                        picked="$cand"
                    else
                        echo "Tidak ada template cocok '$choice' di pveam" >&2
                    fi
                fi
                continue
            elif (( ${#matches[@]} == 1 )); then
                picked="${matches[0]}"
            else
                echo "Multiple matches:" >&2
                local mi=1
                for t in "${matches[@]}"; do
                    echo "  $mi) $t" >&2
                    mi=$((mi+1))
                done
                local mi_choice=""
                read -r -p "Choose number: " mi_choice
                if [[ "$mi_choice" =~ ^[0-9]+$ ]] && (( mi_choice >= 1 && mi_choice <= ${#matches[@]} )); then
                    picked="${matches[$((mi_choice-1))]}"
                else
                    echo "Invalid" >&2
                fi
            fi
        fi
    done

    echo "$storage:vztmpl/$picked"
}

# Wizard: create new Proxmox storage (pvesm add)
create_new_storage() {
    local name type path
    read -r -p "Storage name: " name
    [[ -z "$name" ]] && { echo "Nama kosong â€” batal" >&2; return 1; }
    echo "Type: dir | lvm | lvmthin | zfspool | nfs | cifs | rbd" >&2
    read -r -p "Storage type: " type
    case "$type" in
        dir)
            read -r -p "Path (e.g. /mnt/storage): " path
            pvesm add dir "$name" --path "$path" --content vztmpl,iso,rootdir,images
            ;;
        lvm)
            read -r -p "VG name (e.g. pve): " vg
            pvesm add lvm "$name" --vgname "$vg" --content vztmpl,rootdir,images
            ;;
        lvmthin)
            read -r -p "VG name: " vg
            read -r -p "Thinpool name: " pool
            pvesm add lvmthin "$name" --vgname "$vg" --thinpool "$pool" --content vztmpl,rootdir,images
            ;;
        zfspool)
            read -r -p "ZFS pool name: " pool
            pvesm add zfspool "$name" --pool "$pool" --content vztmpl,rootdir,images
            ;;
        nfs)
            read -r -p "Server: " server
            read -r -p "Export path: " export
            pvesm add nfs "$name" --server "$server" --export "$export" --content vztmpl,iso
            ;;
        cifs)
            read -r -p "Server: " server
            read -r -p "Share: " share
            read -r -p "Username: " user
            read -r -sp "Password: " pass
            echo "" >&2
            pvesm add cifs "$name" --server "$server" --share "$share" --username "$user" --password "$pass" --content vztmpl,iso
            ;;
        rbd)
            read -r -p "Pool: " pool
            read -r -p "Ceph mon host: " monhost
            pvesm add rbd "$name" --pool "$pool" --monhost "$monhost" --content vztmpl,rootdir,images
            ;;
        *)
            echo "Type tidak dikenal: $type â€” batal" >&2
            return 1
            ;;
    esac
    if [[ $? -eq 0 ]]; then
        log_success "Storage $name dibuat"
    else
        log_error "Gagal membuat storage $name"
        return 1
    fi
}

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

# --- Package manager abstraction (Debian/apt vs Alpine/apk) ---
detect_pkg_manager() {
    if command -v apk >/dev/null 2>&1; then
        echo "apk"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    else
        echo "unknown"
    fi
}

pkg_update() {
    case "$(detect_pkg_manager)" in
        apk) apk update ;;
        apt) apt-get update -y ;;
        *) log_error "No supported package manager found"; return 1 ;;
    esac
}

pkg_install() {
    case "$(detect_pkg_manager)" in
        apk) apk add --no-cache "$@" ;;
        apt) apt-get install -y "$@" ;;
        *) log_error "No supported package manager found"; return 1 ;;
    esac
}

pkg_remove() {
    case "$(detect_pkg_manager)" in
        apk) apk del "$@" ;;
        apt) apt-get remove -y "$@" 2>/dev/null || true ;;
        *) log_error "No supported package manager found"; return 1 ;;
    esac
}

pkg_upgrade() {
    case "$(detect_pkg_manager)" in
        apk) apk upgrade ;;
        apt) apt-get update -y && apt-get install -y --only-upgrade "$@" ;;
        *) log_error "No supported package manager found"; return 1 ;;
    esac
}

# Pastikan tool dasar tersedia (curl, ca-certificates, dsb) — container minimal sering kosong
ensure_curl() {
    if ! command -v curl >/dev/null 2>&1; then
        log_warn "curl tidak ada — menginstal..."
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache curl ca-certificates
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1 || true
            apt-get install -y curl ca-certificates
        fi
    fi
}

# systemd vs openrc abstraction (Alpine uses openrc, no systemctl)
svc_enable() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable "$1"
    elif command -v rc-update >/dev/null 2>&1; then
        rc-update add "$1" default
    fi
}

svc_start() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl start "$1"
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$1" start
    fi
}

# Main entry point for testing
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "Common library loaded. Use: source lib/common.sh"
fi