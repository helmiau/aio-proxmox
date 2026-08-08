# aio-proxmox — Proxmox Services Manager v4.2.5

## Overview

Proxmox Services Manager (CLI) untuk **personal homelab** di **Intel J1900 Mini PC (8GB RAM, SSD 64GB, Legacy/UEFI BIOS)** — instalasi Debian→PVE, lifecycle service, LXC & VM, backup/restore.

- **Debian 13 (Trixie)** → **Proxmox VE 9** → **AI gateway, VPN, NAS, remote access, monitoring**
- **Flexible placement**: host, new LXC, or existing LXC per service
- **Port/IP Registry** to prevent conflicts
- **Debian 13.5.0 → 13.6.0 upgrade** integrated
- **Proxmox repair/reinstall** capability
- **Full Alpine Linux support (P12)**: service LXC bisa jalan di Alpine (barebone, lightweight) atau Debian — `LXC_TEMPLATE` global atau `<PREFIX>_LXC_TEMPLATE` per service
- **Script versioning (P13)**: single-source `VERSION` file, `--version` flag di install & updater
- **Service run di dalam LXC (P14)**: svc script dijalankan di container (bukan host) — copy lib+ENV+script, auto-start stopped LXC
- **Base package bootstrap (P15)**: template minimal dijamin punya curl/wget/git/jq/venv dll sebelum install
- **PATH permanen (P16)**: `pct/qm` tersedia di semua sesi SSH (`/etc/profile.d` + symlink)

## Quick Start

> **Asumsi:** Debian 13 minimal / Proxmox VE base **tidak menyertakan** paket dasar
> (curl, wget, git, bash, jq, ca-certificates, build tools, dll). Langkah 0 memastikan semuanya ada.

```bash
# 0. Install paket dasar (Debian minimal / Proxmox base sering kosong)
apt-get update -y
apt-get install -y curl wget git bash ca-certificates gnupg jq \
    sed awk grep tar gzip xz-utils procps iproute2 openssh-client

# 1. Install Debian 13 minimal (netinst) dengan root 26 GiB + swap 1 GiB
#    (lewati langkah 0 jika sudah Proxmox VE dengan paket lengkap)

# 2. Clone repo
git clone https://github.com/helmiau/aio-proxmox
cd aio-proxmox

# 3. Run installer (ENVIRONMENT akan auto-initialized;
#    paket dasar untuk LXC dijamin otomatis via ensure_base_packages)
bash install
```

**Paket dasar untuk LXC** dijamin otomatis oleh installer:
`ensure_base_packages()` menginstal `curl wget git bash jq ca-certificates` (dan lainnya)
di dalam container **sebelum** service di-install — template LXC minimal tidak perlu di-setup manual.

## Features

- **Unified lifecycle**: `install`, `uninstall`, `update`, `reinstall`, `status`, `start`, `stop`, `restart` per service
- **Comma-separated multi-install**: `install 9router,hermes,headroom`
- **Idempotent & re-runnable**: safe to run multiple times
- **Port/IP Registry**: single source of truth for allocations
- **Config-as-template**: render from `/config/<service>/` templates
- **Debian upgrade**: 13.5.0 → 13.6.0 (automatic + standalone script)
- **Proxmox repair**: reinstall PVE without losing LXC/VM
- **ENV Manager (P8)**: auto-init ENVIRONMENT, interactive prompts, backups, and file protection

## ENV Manager (P8) — New in v4.1
- **Auto-init**: First run copies `ENVIRONMENT.example` → `ENVIRONMENT` with header marker.
- **Interactive prompts**: When installing a service, if its ENV section is `(DEFAULT)`, prompt user for values.
- **Progressive config**: ENV updated only for services being installed.
- **Backup strategy**: Before any ENV modification, backup to `ENVIRONMENT.bak.<timestamp>` (max 3 kept).
- **File protection**: `ENVIRONMENT` file is never deleted — only its content is edited.

## Service List

| Service | Default Target | Notes |
|--------|---------------|-------|
| 9Router | LXC | AI API gateway |
| Headroom AI | LXC (co-located with 9Router) | Context compression |
| Hermes Agent | LXC | AI agent runtime + MCP |
| Hermes WebUI | LXC | AI chat UI |
| Cloudflared | Host | Cloudflare Tunnel |
| Tailscale | Host | Mesh VPN |
| Mihomo | Host | Proxy/routing/filtering |
| Storage Manager | LXC | FBQ+SFTP+FTP+Samba stack |
| Copyparty | LXC | NAS alternative |
| 3x-ui | LXC | Xray VPN panel |
| ttyd | Host | Web terminal |
| Oh My Zsh | Host | Shell enhancement |
| Fastfetch | Host | System info |
| Health Check | Host | Install verification |
| MikroTik CHR | VM | Patched RouterOS |
| Obsidian Obsidian | LXC | CouchDB sync (Docker) |
| OmniRoute | LXC | Router UI |
| RustDesk Server | LXC | Remote desktop server (hbbs/hbbr) |

## Documentation

- **PRD v4.2.5**: [PRD.md](PRD.md) — full architecture, principles, requirements
- **ENVIRONMENT**: [ENVIRONMENT.example](ENVIRONMENT.example) — all variables
- **Scripts**: `scripts/` — numbered steps + service scripts
- **Libs**: `lib/` — shared helpers (common, service-actions, lxc, logging, env-manager, backup)

## Usage

```bash
# Interactive menu
./install

# Standalone Debian upgrade
./upgrade-debian.sh

# Repair Proxmox
./scripts/03-install-proxmox-ve9.sh repair

# Update services
updater 9router hermes

# Lint & test
make lint test
```

## License

GPL-3.0 — see [LICENSE](LICENSE)
