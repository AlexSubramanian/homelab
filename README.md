# homelab

Infrastructure-as-code for a Proxmox homelab running on an HP EliteDesk 800 G4. Manages Docker Compose stacks and systemd service files for media, monitoring, and web hosting VMs.

---

## VMs

| VM | ID | Purpose |
|----|-----|---------|
| Arr Stack | 102 | Sonarr, Radarr, Prowlarr, Bazarr, SABnzbd, FlareSolverr, Recyclarr, Pulsarr |
| Plex | 103 | Plex Media Server (Intel QuickSync transcoding) |
| Web Server | 104 | [alexsubramanian.com](https://alexsubramanian.com) (Hugo + Caddy + Cloudflare) |

VM 102 also runs the **monitoring stack** (Grafana, Prometheus, cAdvisor, node-exporter) as a separate systemd-managed compose service.  I plan to move this stack to a separate machine or raspberry pi so it's not on the same hardware as the VMs being monitored. A standalone **node-exporter** service is deployed on VMs 103 and 104 for remote metric collection.

All VMs run Debian 13 with Docker. Media lives on NFS (`/mnt/media`) from a UniFi NAS Pro. App configs and metric databases are stored locally on each VM to avoid SQLite/NFS locking issues.

Home Assistant (VM 100) and Minecraft (VM 101) are not managed by this repo — HA runs HAOS and is configured through its own interface.

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
  monitoring/
    docker-compose.yml    # Grafana, Prometheus, cAdvisor, node-exporter
    monitoring.service    # systemd unit (manages docker compose)
    prometheus/           # Prometheus scrape config
    grafana/              # Grafana provisioning (datasources)
  node-exporter/
    docker-compose.yml    # Standalone node-exporter (for plex/web VMs)
    node-exporter.service # systemd unit (manages docker compose)
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
./deploy.sh monitoring
./deploy.sh node-exporter
```

The script will:
1. Stop the systemd service (which brings down the containers)
2. Re-symlink `docker-compose.yml` into `/opt/docker/<service>/`
3. Re-link the systemd unit file into `/etc/systemd/system/` and reload the daemon
4. Enable and start the service
5. Print the service status

### First-time setup

If this is the first deploy on a fresh VM, you'll need Docker installed. The script creates `/opt/docker/<service>/` automatically, but service-specific directories need to exist first.

For VMs that use NFS (arr-stack, plex), add the NFS entry to `/etc/fstab` with `x-systemd.automount` so it mounts on first access rather than at boot (avoids a network race condition):

```
<NAS_IP>:/var/nfs/shared/media /mnt/media nfs vers=3,rsize=1048576,wsize=1048576,proto=tcp,hard,noatime,nconnect=8,timeo=600,retrans=2,_netdev,x-systemd.automount,x-systemd.mount-timeout=120 0 0
```

Then enable the network wait service and create the mount point:

```bash
sudo systemctl enable ifupdown-wait-online.service
sudo mkdir -p /mnt/media
sudo systemctl daemon-reload
```

For the monitoring service, create the data directories before first deploy:

```bash
sudo mkdir -p /opt/configs/grafana /opt/configs/prometheus
sudo chown 472:0 /opt/configs/grafana        # Grafana runs as UID 472
sudo chown 65534:65534 /opt/configs/prometheus # Prometheus runs as nobody
```
