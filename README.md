# aio-proxmox — Debian → Proxmox VE Homelab Installer v4.0

## Overview

Automated installer for a **personal homelab** on **Intel J1900 Mini PC (8GB RAM, SSD 64GB, Legacy/UEFI BIOS)**.

- **Debian 13 (Trixie)** → **Proxmox VE 9** → **AI gateway, VPN, NAS, remote access, monitoring**
- **Flexible placement**: host, new LXC, or existing LXC per service
- **Port/IP Registry** to prevent conflicts
- **Debian 13.5.0 → 13.6.0 upgrade** integrated
- **Proxmox repair/reinstall** capability

## Quick Start

```bash
# 1. Install Debian 13 minimal (netinst) with 26 GiB root + 1 GiB swap
# 2. Clone repo
git clone https://github.com/helmiau/aio-proxmox
cd aio-proxmox
# 3. Copy and edit ENVIRONMENT
cp ENVIRONMENT.example ENVIRONMENT
vim ENVIRONMENT
# 4. Run installer
bash install
```

## Features

- **Unified lifecycle**: `install`, `uninstall`, `update`, `reinstall`, `status`, `start`, `stop`, `restart` per service
- **Comma-separated multi-install**: `install 9router,hermes,headroom`
- **Idempotent & re-runnable**: safe to run multiple times
- **Port/IP Registry**: single source of truth for allocations
- **Config-as-template**: render from `/config/<service>/` templates
- **Debian upgrade**: 13.5.0 → 13.6.0 (automatic + standalone script)
- **Proxmox repair**: reinstall PVE without losing LXC/VM

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

## Documentation

- **PRD v4.0**: [PRD.md](PRD.md) — full architecture, principles, requirements
- **ENVIRONMENT**: [ENVIRONMENT.v4.example](ENVIRONMENT.v4.example) — all variables
- **Scripts**: `scripts/` — numbered steps + service scripts
- **Libs**: `lib/` — shared helpers (common, service-actions, lxc, logging)

## Usage

```bash
# Interactive menu
./install

# Standalone Debian upgrade
./upgrade-debian.sh

# Repair Proxmox
./scripts/03-install-proxmox-ve9.sh repair

# Update services
homelab-updater 9router hermes

# Lint & test
make lint test
```

## License

GPL-3.0 — see [LICENSE](LICENSE)
