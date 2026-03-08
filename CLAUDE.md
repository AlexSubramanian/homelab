# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Infrastructure-as-code for a Proxmox homelab on an HP EliteDesk 800 G4. Manages Docker Compose stacks and systemd service files for media VMs (arr-stack on VM 102, plex on VM 103) and a monitoring stack (Grafana/Prometheus on VM 102). This repo is developed locally on macOS but deployed on Debian VMs.

## Deploying

The repo is cloned on each VM at `/home/alex/homelab`. Deploy by running on the target VM:

```bash
./deploy.sh              # auto-detects service from hostname
./deploy.sh arr-stack    # explicit
./deploy.sh plex         # explicit
./deploy.sh monitoring   # explicit (runs on arr-stack VM)
./deploy.sh node-exporter # explicit (runs on plex/web VMs)
```

The script stops the systemd service, re-symlinks compose and unit files, reloads systemd, and starts the service.

## Architecture

- `services/<name>/docker-compose.yml` — Docker Compose stack definition
- `services/<name>/<name>.service` — systemd unit that manages the compose stack
- `deploy.sh` — stop → symlink → reload → start cycle (runs on VM, requires sudo)
- `docs/homelab-config.md` — full hardware specs, network layout, storage, and troubleshooting reference

Compose files are symlinked into `/opt/docker/<service>/` on each VM. Systemd units call `docker compose up/down` from that directory.

## Reference Docs

Read these on-demand when the task requires their context — don't load by default.

- **`docs/homelab-config.md`** — Complete system reference: Proxmox host specs, all VM configurations (IDs 100-104), network/IP assignments, NFS storage architecture, service ports, media workflow, past issues and solutions, and maintenance notes. Consult when troubleshooting, changing VM configs, or modifying storage/network setup.
- **`docs/personal-site-plan.md`** — Implementation plan for alexsubramanian.com (VM 104, not yet built). Covers Hugo + Caddy + Cloudflare stack, phased build steps, CI/CD via GitHub Actions, security checklist, and AWS failover strategy. Consult when working on the web server VM or personal site.

## Key Conventions

- **UID/GID:** All containers run as PUID=977 / PGID=988 (matches NFS squash settings on U-NAS Pro)
- **Configs:** Stored locally on each VM (`/opt/configs/` for arr-stack + monitoring, `/opt/plex-config/` for plex) — never on NFS (SQLite/TSDB locking issues)
- **Media:** NFS mount at `/mnt/media` from `192.168.1.33:/var/nfs/shared/media`
- **Timezone:** `America/Denver` across all services
- **Images:** LinuxServer.io images (`lscr.io/linuxserver/*`) for arr services; official `plexinc/pms-docker` for Plex
- **Restart policy:** `unless-stopped` for all containers
