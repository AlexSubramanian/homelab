# homelab

Infrastructure-as-code for a Proxmox homelab running on an HP EliteDesk 800 G4. Manages Docker Compose stacks and systemd service files for two media VMs.

See [`docs/homelab-config.md`](docs/homelab-config.md) for full hardware specs, network layout, storage architecture, and troubleshooting history.

---

## VMs

| VM | ID | IP | Purpose |
|----|----|----|---------|
| Arr Stack | 102 | 192.168.1.75 | Sonarr, Radarr, Prowlarr, Bazarr, SABnzbd, FlareSolverr, Recyclarr, Pulsarr |
| Plex | 103 | 192.168.1.103 | Plex Media Server (Intel QuickSync transcoding) |

Both VMs run Debian 13 with Docker. Media lives on NFS (`/mnt/media`) from a UniFi NAS Pro. App configs are stored locally on each VM to avoid SQLite/NFS locking issues.

---

## Repo structure

```
services/
  arr-stack/
    docker-compose.yml    # All arr services
    arr-stack.service     # systemd unit (manages docker compose)
  plex/
    docker-compose.yml    # Plex Media Server
    plex.service          # systemd unit (manages docker compose)
docs/
  homelab-config.md       # Full reference documentation
deploy.sh                 # Deploy script (run on the target VM)
```

---

## How it works

Docker Compose files are symlinked from this repo into `/opt/docker/<service>/`. Each service has a systemd unit file that manages the compose stack — `systemctl start arr-stack` runs `docker compose up` from `/opt/docker/arr-stack/`.

The repo is cloned on each VM at `/home/alex/homelab`. `deploy.sh` handles the stop → re-link → start cycle.

---

## Deploying

Clone or pull the repo on the target VM, then run:

```bash
# Auto-detects the service from hostname (arr-stack or plex)
./deploy.sh

# Or pass the service name explicitly
./deploy.sh arr-stack
./deploy.sh plex
```

The script will:
1. Stop the systemd service (which brings down the containers)
2. Re-symlink `docker-compose.yml` into `/opt/docker/<service>/`
3. Re-link the systemd unit file into `/etc/systemd/system/` and reload the daemon
4. Enable and start the service
5. Print the service status

### First-time setup

If this is the first deploy on a fresh VM, you'll need Docker installed and the NFS share mounted at `/mnt/media`. The script creates `/opt/docker/<service>/` automatically, but the NFS mount and `/opt/configs/` (arr-stack) or `/opt/plex-config/` (plex) directories need to exist first.
