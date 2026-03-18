# homelab

Infrastructure-as-code for a Proxmox homelab running on an HP EliteDesk 800 G4. Manages Docker Compose stacks and systemd service files for media, monitoring, and web hosting across VMs and a dedicated Raspberry Pi.

---

## Hosts

| Host | IP | Purpose |
|------|----|---------|
| Arr Stack (VM 102) | 192.168.1.75 | Sonarr, Radarr, Prowlarr, Bazarr, SABnzbd, FlareSolverr, Recyclarr, Pulsarr, cAdvisor |
| Plex (VM 103) | 192.168.1.103 | Plex Media Server (Intel QuickSync transcoding) |
| Web Server (VM 104) | 192.168.1.104 | [alexsubramanian.com](https://alexsubramanian.com) (Hugo + Caddy + Cloudflare) |
| Monitoring + NUT Server (Raspberry Pi 4B) | 192.168.1.228 | Grafana, Prometheus, Blackbox Exporter, node-exporter, NUT server |
| Proxmox Host | 192.168.1.234 | NUT client (graceful VM shutdown on low battery) |
| UDM SE | 192.168.1.1 | UniFi gateway (shut down via SSH from Pi on low battery) |
| UNAS Pro | 192.168.1.33 | UniFi NAS (shut down via SSH from Pi on low battery) |

The **monitoring stack** runs on a dedicated Raspberry Pi 4B (booting from a Samsung T7 SSD) so it's independent from the Proxmox host and VMs it monitors. Each host includes **node-exporter** in its compose stack for system metrics, and the arr-stack and plex VMs also run **cAdvisor** for container metrics. The webserver's node-exporter is managed by the [alexsubramanian.com](https://github.com/AlexSubramanian/alexsubramanian.com) repo.

A **CyberPower CP1500PFCRM2U UPS** is connected via USB to the Pi, which runs a NUT server. On low battery, Proxmox receives a NUT notification and shuts down gracefully (stopping all VMs), the Pi SSHes into the UDM SE and UNAS Pro to shut them down, and then the Pi shuts itself down last. The UPS cuts power after a timeout.

All VMs run Debian 13 with Docker. The Pi runs Raspberry Pi OS with Docker. Media lives on NFS (`/mnt/media`) from a UniFi NAS Pro. App configs and metric databases are stored locally on each host to avoid SQLite/NFS locking issues.

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
    docker-compose.yml    # Grafana, Prometheus, Blackbox, node-exporter (runs on Pi)
    monitoring.service    # systemd unit (manages docker compose)
    prometheus/           # Prometheus scrape config
    grafana/              # Grafana provisioning and dashboards
    blackbox/             # Blackbox exporter config
  nut-server/
    etc/                  # NUT config files (symlinked to /etc/nut/ on Pi)
    scripts/              # shutdown-ups.sh (SSHes into UDM SE + UNAS Pro)
  nut-client/
    nut.conf              # NUT client config (symlinked to /etc/nut/ on Proxmox)
    upsmon.conf           # Secondary monitor config pointing to Pi
deploy.sh                 # Deploy script (run on the target host)
```

---

## How it works

Docker Compose files are symlinked from this repo into `/opt/docker/<service>/`. Each service has a systemd unit file that manages the compose stack — `systemctl start arr-stack` runs `docker compose up` from `/opt/docker/arr-stack/`.

The repo is cloned on each host at `/home/alex/homelab`. `deploy.sh` handles the stop → re-link → start cycle.

### What runs where

| Host | Services deployed |
|------|-------------------|
| Arr Stack (VM 102) | `arr-stack` |
| Plex (VM 103) | `plex` |
| Web Server (VM 104) | managed by [alexsubramanian.com](https://github.com/AlexSubramanian/alexsubramanian.com) repo |
| Monitoring (Pi) | `monitoring`, `nut-server` |
| Proxmox Host | `nut-client` |

---

## Deploying

Clone or pull the repo on the target host, then run:

```bash
# Auto-detects the service from hostname (arr-stack, plex, or monitoring)
./deploy.sh

# Or pass the service name explicitly
./deploy.sh arr-stack
./deploy.sh plex
./deploy.sh monitoring
./deploy.sh nut-server    # On Pi — symlinks NUT config to /etc/nut/, restarts NUT services
./deploy.sh nut-client    # On Proxmox — symlinks NUT config to /etc/nut/, restarts nut-monitor
```

For Docker-based services, the script will:
1. Stop the systemd service (which brings down the containers)
2. Re-symlink `docker-compose.yml` into `/opt/docker/<service>/`
3. Re-link the systemd unit file into `/etc/systemd/system/` and reload the daemon
4. Enable and start the service
5. Print the service status

For native services (`nut-server`, `nut-client`), the script symlinks config files to `/etc/nut/` and restarts the relevant systemd services.

### First-time setup

The script creates `/opt/docker/<service>/` automatically, but service-specific directories need to exist first.

#### Raspberry Pi (monitoring)

Create the data directories:

```bash
sudo mkdir -p /opt/configs/grafana /opt/configs/prometheus
sudo chown 472:0 /opt/configs/grafana        # Grafana runs as UID 472
sudo chown 65534:65534 /opt/configs/prometheus # Prometheus runs as nobody
```

#### VMs with NFS (arr-stack, plex)

Add the NFS entry to `/etc/fstab` with `x-systemd.automount` so it mounts on first access rather than at boot (avoids a network race condition):

```
<NAS_IP>:/var/nfs/shared/media /mnt/media nfs vers=3,rsize=1048576,wsize=1048576,proto=tcp,hard,noatime,nconnect=8,timeo=600,retrans=2,_netdev,x-systemd.automount,x-systemd.mount-timeout=120 0 0
```

Then enable the network wait service and create the mount point:

```bash
sudo systemctl enable ifupdown-wait-online.service
sudo mkdir -p /mnt/media
sudo systemctl daemon-reload
```

#### Raspberry Pi (NUT server)

1. Install NUT and sshpass:

```bash
sudo apt install nut sshpass
```

2. Deploy the config files:

```bash
./deploy.sh nut-server
```

3. Set real passwords in `/etc/nut/upsd.users` and `/etc/nut/upsmon.conf` (the symlinked files contain `<to-be-set>` placeholders).

4. Create `/etc/nut/shutdown-ups.env` with SSH passwords for the UniFi devices (this file is NOT in the repo):

```bash
UDM_SSH_PASS="<udm-ssh-password>"
UNAS_SSH_PASS="<unas-ssh-password>"
```

5. Restart NUT services:

```bash
sudo systemctl restart nut-driver nut-server nut-monitor
```

6. Verify the UPS is detected:

```bash
upsc cyberpower@localhost
```

#### Proxmox (NUT client)

1. Install the NUT client:

```bash
apt install nut-client
```

2. Deploy the config files:

```bash
./deploy.sh nut-client
```

3. Set the monitor password in `/etc/nut/upsmon.conf` to match the `[monitor]` password in the Pi's `upsd.users`.

4. Restart and verify:

```bash
systemctl restart nut-monitor
upsc cyberpower@192.168.1.228
```