# Proxmox Homelab Configuration Reference
## Complete System Documentation

Last Updated: March 2026
**Version 4.0** — Corrected to match actual running config; web server VM planned

---

## Changelog from v3.0

- **Corrected VM Configs to Match Reality:** Fixed Plex BIOS (OVMF, not SeaBIOS), CPU type (x86-64-v2-AES, not host), GPU passthrough flags, SCSI controllers, and missing onboot/startup settings
- **NFS Path Corrected:** Actual export is `/var/nfs/shared/media`, not the old UUID-based path
- **NFS Mount Options Updated:** Now includes `nconnect=8` and `noatime` (already in use)
- **Minecraft VM (101) Documented:** 2 cores, 8GB RAM, 100GB disk, Debian 12, stopped by default
- **Additional Arr Stack Services Documented:** Pulsarr, Recyclarr, and Profilarr added
- **Web Server VM (104) Planned:** alexsubramanian.com hosting with Hugo + Caddy + Cloudflare
- **GRUB Parameters Updated:** Added vfio-pci pre-binding and PCIe ASPM policy
- **Accurate Disk and Config Sizes:** Updated from actual `df` and `du` output

---

## Hardware Specifications

### Proxmox Host
- **Model:** HP EliteDesk 800 G4 SFF
- **CPU:** Intel Core i5-8500 (6 cores, 6 threads, 3.0GHz base)
- **RAM:** 32GB DDR4
- **GPU:** Intel UHD Graphics 630 (integrated, device ID `8086:3e92`)
- **Storage:** local (98GB dir) + local-lvm (856GB thin-provisioned LVM)
- **Network:** Intel X520-DA1 10 Gbps SFP+ NIC (`enp1s0`), onboard GbE (`eno1`, unused/DOWN)

### Network Infrastructure
- **Router:** UniFi Dream Machine SE (UDM SE)
- **NAS:** UniFi NAS Pro (U-NAS Pro) — 10 Gbps SFP+
- **Internet:** 2 Gbps down / 1 Gbps up fiber connection
- **Local Network:** 192.168.1.0/24
- **Storage Network:** 10 Gbps between Proxmox host and NAS

### Smart Home Hardware
- **Zigbee/Thread Coordinator:** Nabu Casa SkyConnect (ZWA-2) USB dongle (Bus 001 Device 003: ID 303a:4001)
- **Voice Assistants:** 2x Home Assistant Voice Preview Edition (Voice PE) devices

---

## Network Configuration

### IP Assignments (Static DHCP Reservations)
| Service | IP Address | Type | VM ID |
|---------|------------|------|-------|
| Proxmox Host | 192.168.1.234 | Bare Metal | — |
| U-NAS Pro | 192.168.1.33 | Physical Device | — |
| Home Assistant | 192.168.1.162 | VM | 100 |
| Minecraft | TBD | VM | 101 |
| Arr Stack + SABnzbd | 192.168.1.75 | VM | 102 |
| Plex Server | 192.168.1.103 | VM | 103 |
| Web Server (planned) | 192.168.1.104 | VM | 104 |

### External Access (Planned)
- **Domain:** alexsubramanian.com (registered at Porkbun, DNS via Cloudflare)
- **Cloudflare:** Free tier, proxy mode enabled (hides home IP)
- **Port Forwarding (UDM SE):** Ports 80 and 443 → 192.168.1.104 only
- **Firewall:** Only VM 104 will be reachable from the internet; all other VMs are internal-only

---

## Storage Architecture

### Design Philosophy: Separation of Configs and Media

**Why configs are stored locally on each VM:**
- SQLite databases (used by Plex, Sonarr, Radarr, etc.) require proper file locking
- NFS does not handle SQLite locking well, causing database corruption and deadlocks
- Local SSD storage provides faster database access
- Plex Butler tasks and overnight maintenance run reliably without hanging

**Why media stays on NFS:**
- Large files benefit from centralized storage
- Hardlinks work within the same filesystem (NFS mount)
- Easy to expand storage on NAS
- Media files are read-heavy, not write-heavy with locking needs

### NFS Share Structure (Media Only)
**NAS Share:** Single NFS mount from U-NAS Pro
- **Export Path:** `192.168.1.33:/var/nfs/shared/media`
- **Mount Point on VMs:** `/mnt/media`
- **Protocol:** NFSv3 (U-NAS Pro does not support NFSv4)
- **Mount Options:** `vers=3,rsize=1048576,wsize=1048576,proto=tcp,hard,nconnect=8,noatime,timeo=600,retrans=2,_netdev`
- **Used by:** VM 102 (Arr Stack) and VM 103 (Plex) only

### NFS Directory Structure
```
/mnt/media/                    # NFS mount point (media only)
├── data/                      # Downloads
│   └── usenet/                # Usenet downloads
│       ├── incomplete/
│       ├── complete/
│       │   ├── movies/
│       │   └── tv/
│       └── nzb/
└── library/                   # Final media library
    ├── movies/                # Movie collection
    └── tv/                    # TV show collection
```

### Local Config Storage (Per VM)

**Plex VM (103):**
```
/opt/plex-config/              # Plex configuration (local SSD)
└── Library/
    └── Application Support/
        └── Plex Media Server/
            ├── Plug-in Support/
            │   └── Databases/     # SQLite databases
            ├── Metadata/
            ├── Cache/
            └── Codecs/            # Must have execute permissions!
```

**Arr Stack VM (102):**
```
/opt/configs/                  # All arr configs (local SSD)
├── sonarr/                    # ~45 MB
├── radarr/                    # ~7.7 MB
├── prowlarr/                  # ~2.6 MB
├── bazarr/                    # ~28 KB
├── sabnzbd/                   # ~40 KB
├── pulsarr/                   # ~101 MB
├── recyclarr/                 # ~292 MB
└── profilarr/                 # ~128 MB
```

---

## Virtual Machine Architecture

### Resource Allocation Summary

| Service | ID | vCPU | RAM | Disk | Status | Special Features |
|---------|-----|------|-----|------|--------|------------------|
| Home Assistant | 100 | 2 | 6GB | 32GB | Running, onboot | USB Passthrough, UEFI |
| Minecraft | 101 | 2 | 8GB | 100GB | Stopped, manual start | — |
| Arr Stack | 102 | 4 | 6GB | 64GB | Running | Local configs, firewall |
| Plex | 103 | 4 | 8GB | 32GB | Running, onboot | GPU Passthrough, UEFI, Secure Boot |
| Web Server (planned) | 104 | 1 | 1GB | 16GB | Not yet created | Public-facing, Cloudflare proxied |

**Resources When Minecraft Stopped (typical):**
- **vCPU allocated:** 10 (1.7x overprovisioning on 6 physical cores)
- **RAM allocated:** 20GB of 32GB — ~10GB available for host + buffers
- **Overprovisioning:** Managed by Proxmox scheduler

**Resources When Minecraft Running:**
- **vCPU allocated:** 12 (2x overprovisioning)
- **RAM allocated:** 28GB of 32GB — only ~4GB for host
- **Note:** Minecraft VM is allocated 8GB but only needs 2-4GB for 2 players (few nights/month). Consider reducing to 3-4GB.

**Resources With All VMs + Web Server (planned):**
- **vCPU allocated:** 13 (2.2x overprovisioning)
- **RAM allocated:** 29GB of 32GB with Minecraft at 8GB, or 24-25GB if Minecraft reduced to 3-4GB

All VMs run Debian with Docker, except Home Assistant (HAOS) and Minecraft (Debian 12).

### Disk Usage (Actual)

| VM | Total Disk | Used | Configs | Available |
|----|------------|------|---------|-----------|
| Arr Stack (102) | 60 GB | 7.3 GB | ~575 MB | 50 GB |
| Plex (103) | 29 GB | 5.0 GB | ~92 KB (fresh) | 23 GB |
| Minecraft (101) | 100 GB | — (stopped) | — | — |

Plex config will grow to 2-5 GB with a large library and thumbnails enabled. Arr stack config sizes dominated by Recyclarr (~292 MB) and Profilarr (~128 MB).

---

## Home Assistant VM Configuration (ID 100)

### VM Specifications
- **VM Name:** haos14.1
- **OS:** Home Assistant OS (updated via HA interface, not Proxmox)
- **Boot Type:** UEFI with 4MB EFI disk
- **CPU Type:** Host passthrough
- **Storage:** 32GB with SSD optimizations (discard, writethrough cache)
- **Network:** Virtio NIC on default bridge
- **Auto-start:** Enabled (`onboot: 1`)

### Hardware Passthrough
- **USB Device:** Nabu Casa SkyConnect (ZWA-2) Zigbee/Thread coordinator
- **USB Host Port:** `1-12` (Bus 001 Device 003: ID 303a:4001)
- **Purpose:** Zigbee device coordination and Thread border router

### Voice Assistant Hardware
- **Devices:** 2x Home Assistant Voice Preview Edition
- **Connection:** Wi-Fi (ESP32-S3 based)
- **Management:** ESPHome integration
- **Voice Pipeline:** Whisper (STT) → Gemini (LLM) → Piper (TTS)

### VM Configuration File (`/etc/pve/qemu-server/100.conf`)
```
agent: 1
bios: ovmf
boot: order=scsi0
cores: 2
cpu: host
efidisk0: local-lvm:vm-100-disk-0,efitype=4m,size=4M
localtime: 1
memory: 6144
name: haos14.1
net0: virtio=02:E4:65:58:D1:21,bridge=vmbr0
onboot: 1
ostype: l26
scsi0: local-lvm:vm-100-disk-1,cache=writethrough,discard=on,size=32G,ssd=1
scsihw: virtio-scsi-pci
tablet: 0
tags: smarthome
usb0: host=1-12
```

---

## Minecraft VM Configuration (ID 101)

### VM Specifications
- **OS:** Debian 12.9 (Bookworm)
- **Boot Type:** SeaBIOS (legacy)
- **CPU Type:** Host passthrough, 2 cores
- **RAM:** 8192 MB (overprovisioned — 3-4 GB sufficient for 2 players)
- **Storage:** 100GB on local-lvm with iothread
- **Network:** Virtio NIC on default bridge, firewall enabled
- **Auto-start:** Disabled (manual start, used a few nights per month)
- **SCSI Controller:** virtio-scsi-single

### Usage Notes
- Light usage: 2 players, a few nights per month
- RAM should be reduced to 3-4 GB to free headroom for other VMs
- Still has Debian 12.9 install ISO attached as ide2

### VM Configuration File (`/etc/pve/qemu-server/101.conf`)
```
agent: 1
boot: order=scsi0;ide2;net0
cores: 2
cpu: host
ide2: local:iso/debian-12.9.0-amd64-DVD-1.iso,media=cdrom,size=3887968K
memory: 8192
name: minecraft
net0: virtio=BC:24:11:43:0E:23,bridge=vmbr0,firewall=1
numa: 0
ostype: l26
scsi0: local-lvm:vm-101-disk-0,iothread=1,size=100G
scsihw: virtio-scsi-single
sockets: 1
```

---

## Service Stack Details

### Arr Stack + SABnzbd (VM 102)
**Purpose:** Media automation, indexing, and Usenet downloading

**OS:** Debian 13 (Trixie)
**BIOS:** SeaBIOS
**Machine Type:** q35
**SCSI Controller:** virtio-scsi-single with iothread

**Docker Services:**
- **SABnzbd:** Usenet download client (Port 8080)
- **Radarr:** Movie management (Port 7878)
- **Sonarr:** TV show management (Port 8989)
- **Prowlarr:** Indexer management (Port 9696)
- **Bazarr:** Subtitle management (Port 6767)
- **FlareSolverr:** Cloudflare bypass (Port 8191)
- **Pulsarr:** Request management (Port 3003)
- **Recyclarr:** Automatic quality profile syncing (no exposed port)
- **Profilarr:** Profile management (config at `/opt/configs/profilarr/`)

**Key Configuration:**
- All services run as UID 977 / GID 988 (matches NFS squash settings)
- **Configs stored locally** at `/opt/configs/`
- Hardlink support enabled via single NFS mount
- Root folders: `/movies` (Radarr), `/tv` (Sonarr)
- No VPN needed — Usenet uses SSL encryption
- Network firewall enabled on Proxmox interface

**Note:** VM 102 does not currently have `onboot` or `startup` order set. Consider adding `onboot: 1` and `startup: order=2` for automatic start after host reboot.

**Volume Mounts (Docker):**
```yaml
# Local config storage (SQLite databases)
- /opt/configs/sonarr:/config
- /opt/configs/radarr:/config
- /opt/configs/prowlarr:/config
- /opt/configs/bazarr:/config
- /opt/configs/sabnzbd:/config
- /opt/configs/pulsarr:/config
- /opt/configs/recyclarr:/config
- /opt/configs/profilarr:/config

# NFS media storage
- /mnt/media/library/movies:/movies
- /mnt/media/library/tv:/tv
- /mnt/media/data:/data
```

### VM Configuration File (`/etc/pve/qemu-server/102.conf`)
```
agent: 1
boot: order=scsi0;ide2;net0
cores: 4
cpu: host
ide2: none,media=cdrom
machine: q35
memory: 6144
name: arr-stack
net0: virtio=BC:24:11:0A:07:A2,bridge=vmbr0,firewall=1
numa: 0
ostype: l26
scsi0: local-lvm:vm-102-disk-0,cache=writeback,discard=on,iothread=1,size=64G
scsihw: virtio-scsi-single
sockets: 1
```

### Plex Server (VM 103)
**Purpose:** Media server with hardware transcoding

**OS:** Debian 13 (Trixie)
**BIOS:** OVMF (UEFI with Secure Boot — pre-enrolled Microsoft keys)
**Machine Type:** q35
**SCSI Controller:** virtio-scsi-single with iothread

**Docker Services:**
- Plex Media Server (latest)

**Key Features:**
- Intel QuickSync hardware transcoding via iGPU passthrough (PCIe mode)
- **Config stored locally** at `/opt/plex-config/`
- Network mode: host
- Transcode directory: `/dev/shm` (RAM)
- CPU type: `x86-64-v2-AES` (not host passthrough — required for OVMF/Secure Boot compatibility)
- Network firewall enabled on Proxmox interface

**GPU Passthrough Configuration:**
```
# In /etc/pve/qemu-server/103.conf
# PCIe mode (pcie=1), GPU pre-bound via vfio-pci.ids in GRUB
hostpci0: 0000:00:02.0,pcie=1
```

**Volume Mounts (Docker):**
```yaml
# Local config storage (SQLite databases, codecs)
- /opt/plex-config:/config

# NFS media storage
- /mnt/media/library:/media

# RAM-based transcoding
- /dev/shm:/transcode
```

### VM Configuration File (`/etc/pve/qemu-server/103.conf`)
```
agent: 1
bios: ovmf
boot: order=scsi0;ide2;net0
cores: 4
cpu: x86-64-v2-AES
efidisk0: local-lvm:vm-103-disk-0,efitype=4m,ms-cert=2023,pre-enrolled-keys=1,size=4M
hostpci0: 0000:00:02.0,pcie=1
ide2: none,media=cdrom
machine: q35
memory: 8192
name: plex
net0: virtio=BC:24:11:EE:33:0C,bridge=vmbr0,firewall=1
numa: 0
onboot: 1
ostype: l26
scsi0: local-lvm:vm-103-disk-1,cache=writeback,discard=on,iothread=1,size=32G
scsihw: virtio-scsi-single
sockets: 1
```

### Web Server (VM 104) — Planned
**Purpose:** Personal website hosting at alexsubramanian.com

**Status:** Not yet created. See `personal-site-plan.md` for full implementation plan.

**Planned Software Stack:**
- **Hugo:** Static site generator (builds HTML from Markdown)
- **Caddy:** Web server with automatic HTTPS
- **Cloudflare:** CDN, DNS, and bot protection (free tier)

**Planned Specs:** 1 vCPU, 1GB RAM, 16GB disk, Debian 13, SeaBIOS

---

## Critical Configuration Elements

### Proxmox Host Requirements
1. **GRUB Configuration:** `intel_iommu=on iommu=pt vfio-pci.ids=8086:3e92 pcie_aspm.policy=performance`
2. **VFIO Pre-binding:** GPU device `8086:3e92` bound to vfio-pci at boot for passthrough to VM 103
3. **PCIe ASPM Policy:** Set to `performance` to prevent power-saving interference with GPU passthrough
4. **NFS Tools:** `nfs-common` package installed
5. **Intel GPU Tools:** For monitoring transcoding (`intel_gpu_top` — run on host, not VM)
6. **USB Device:** Nabu Casa SkyConnect (ZWA-2) passed to VM 100 for Zigbee/Thread
7. **10 Gbps NIC:** Intel X520-DA1 (`enp1s0`) for NAS connectivity; onboard GbE (`eno1`) unused

### VM Features (Home Assistant — VM 100)
```
agent: 1              # QEMU guest agent enabled
bios: ovmf            # UEFI boot
cpu: host             # Host CPU passthrough
localtime: 1          # Use local timezone
onboot: 1             # Auto-start with host
usb0: host=1-12       # SkyConnect passthrough
scsihw: virtio-scsi-pci
```

### VM Features (Minecraft — VM 101)
```
agent: 1              # QEMU guest agent enabled
bios: seabios         # Legacy BIOS (default)
cpu: host             # Host CPU passthrough
                      # No onboot — started manually
scsihw: virtio-scsi-single
```

### VM Features (Arr Stack — VM 102)
```
agent: 1              # QEMU guest agent enabled
bios: seabios         # Legacy BIOS (default, q35 machine)
cpu: host             # Host CPU passthrough
machine: q35          # Modern chipset emulation
                      # No onboot or startup order currently set
                      # TODO: Add onboot=1, startup order=2
scsihw: virtio-scsi-single
```

### VM Features (Plex — VM 103)
```
agent: 1              # QEMU guest agent enabled
bios: ovmf            # UEFI boot with Secure Boot
cpu: x86-64-v2-AES    # Not host — needed for OVMF compatibility
machine: q35          # Modern chipset emulation
onboot: 1             # Auto-start with host
                      # No startup order currently set
                      # TODO: Add startup order=3
hostpci0: 0000:00:02.0,pcie=1  # iGPU passthrough (PCIe mode)
scsihw: virtio-scsi-single
```

---

## Service Ports
| Service | Port | Purpose | External |
|---------|------|---------|----------|
| Home Assistant | 8123 | Web UI & API | No |
| Plex | 32400 | Web UI & API | No |
| SABnzbd | 8080 | Web UI | No |
| Radarr | 7878 | Web UI | No |
| Sonarr | 8989 | Web UI | No |
| Prowlarr | 9696 | Web UI | No |
| Bazarr | 6767 | Web UI | No |
| FlareSolverr | 8191 | API | No |
| Pulsarr | 3003 | Web UI | No |
| Caddy HTTP (planned) | 80 | Redirect to HTTPS | Yes |
| Caddy HTTPS (planned) | 443 | alexsubramanian.com | Yes |

---

## Media Workflow (Usenet)

1. **Content Discovery:** User adds media via Radarr/Sonarr (or Pulsarr for requests)
2. **Indexer Search:** Prowlarr queries configured Usenet indexers
3. **Quality Profiles:** Recyclarr syncs TRaSH Guides quality profiles to Radarr/Sonarr
4. **Download Initiation:** Radarr/Sonarr sends NZB to SABnzbd
5. **Secure Download:** SABnzbd downloads via SSL (port 563) — no VPN needed
6. **Download Location:** Files saved to `/mnt/media/data/usenet/complete/`
7. **Import Process:** Radarr/Sonarr hardlinks from `/data/usenet/complete/` to `/library/[movies|tv]/`
8. **Subtitle Search:** Bazarr automatically searches for and downloads subtitles
9. **Media Server:** Plex detects new files and adds to library
10. **Streaming:** Plex serves content with hardware transcoding if needed

---

## Maintenance Notes

### Local Config Considerations
- **Backup Strategy:** Local configs must be backed up separately (not on NAS)
- **Disk Space:** Monitor with `df -h /` — Arr Stack configs total ~575 MB, Plex will grow to 2-5 GB
- **Database Health:** SQLite databases perform much better on local storage

### U-NAS Pro Considerations
- **NFS Version:** Only NFSv3 is supported (NFSv4 not available)
- **Performance:** 10 Gbps capable with proper mount options
- **Mount Options:** Using large rsize/wsize (1MB) and `nconnect=8` for optimal throughput
- **Export Path:** `/var/nfs/shared/media` (discovered via `showmount -e 192.168.1.33`)

### Home Assistant Considerations
- **USB Device Stability:** SkyConnect passthrough is stable across VM reboots
- **Voice PE Devices:** Require stable Wi-Fi connection for optimal performance
- **Backup Strategy:** VM snapshots capture entire HA OS state
- **Updates:** HA OS updates handled through HA interface, not Proxmox
- **Voice Pipeline:** Resource-intensive, monitor CPU/RAM usage during voice processing

### Minecraft VM Considerations
- **RAM:** Currently allocated 8GB but only 2 players — reduce to 3-4GB
- **ISO Cleanup:** Debian 12.9 install ISO still attached as ide2 — can be removed
- **Impact When Running:** Consumes most of the remaining host RAM headroom

### Web Server Considerations (Planned)
- **Security:** Will be the only VM exposed to the internet — keep Caddy and OS updated
- **Cloudflare:** Handles DDoS protection and caching; home IP never exposed
- **Backups:** Site source in Git; VM is disposable and rebuildable from plan
- **CI/CD:** GitHub Actions will deploy on push to main via SSH

### Backup Recommendations
- **VM Snapshots:** All VMs before major updates
- **VM Configurations:** `/etc/pve/qemu-server/*.conf`
- **Docker Compose Files:** `/opt/docker/*/docker-compose.yml` (on each VM)
- **Local Application Configs:**
  - Plex: `/opt/plex-config/`
  - Arr Stack: `/opt/configs/`
- **ESPHome Configurations:** Backed up within Home Assistant
- **Web Server (planned):** Source in Git — no config backup needed

### Performance Optimizations
- Plex transcoding uses RAM (`/dev/shm`)
- Hardlinks enabled for instant media moves
- Over-provisioned vCPUs managed by Proxmox scheduler
- Intel QuickSync reduces CPU load during transcoding
- Home Assistant VM uses host CPU passthrough for optimal performance
- **SQLite databases on local SSD** — eliminates NFS locking issues
- 10 Gbps NFS with `nconnect=8` and optimized mount options
- GPU pre-bound to vfio-pci at boot for reliable passthrough
- PCIe ASPM set to `performance` to prevent power-state issues
- Disk I/O optimized with `iothread=1` on VMs 101, 102, 103

---

## Past Issues & Solutions

### Issue: Plex hanging overnight / "No content available"
**Cause:** Previously caused by SQLite databases on NFS with locking issues, or missing execute permissions on codec binaries
**Solution:**
1. Configs now stored locally — this should not recur
2. If it does, check codec permissions (see below)

### Issue: Missing execute permissions on Plex codecs after config migration
**Cause:** Copying configs from NFS may not preserve execute bits
**Solution:**
```bash
# Find and fix all binaries missing execute permission
find /opt/plex-config -type f -exec sh -c \
  'file "$1" | grep -q "ELF" && [ ! -x "$1" ] && chmod +x "$1" && echo "Fixed: $1"' _ {} \;
```

### Issue: Permission denied on NFS operations
**Cause:** Containers not using matching UID/GID
**Solution:**
1. Ensure PUID=977 and PGID=988 in Docker containers
2. These match U-NAS Pro's NFS squash settings

### Issue: Plex not using hardware transcoding
**Cause:** GPU not properly passed through
**Solution:**
1. Verify `hostpci0` line in VM config (should be `0000:00:02.0,pcie=1`)
2. Check `/dev/dri` exists in VM: `ls -la /dev/dri/`
3. Install VA-API drivers: `apt install vainfo intel-media-va-driver-non-free`
4. Test with `vainfo`
5. Verify GPU is pre-bound to vfio-pci in GRUB: `vfio-pci.ids=8086:3e92`

---

## Future Considerations

- **NFSv4 Support:** When Ubiquiti adds NFSv4 to UNAS Pro, evaluate benefits (already using `nconnect` with NFSv3)
- **Storage Expansion:** Monitor NAS usage (currently 22TB total capacity)
- **Smart Home Growth:** SkyConnect supports large Zigbee networks (100+ devices)
- **Voice Assistant Expansion:** Add more Voice PE devices for whole-home coverage
- **Backup Automation:** Implement automated VM snapshots and config backups
- **Home Assistant Growth:** VM resources can be expanded as automation grows
- **Local LLM:** Consider running local LLM (like Ollama) if resources permit
- **AWS Fallback:** S3 + CloudFront static hosting as failover for alexsubramanian.com
- **Monitoring Stack:** Consider Uptime Kuma or similar for web server health checks

---

*This document provides complete context for troubleshooting, maintenance, or reconstruction of the entire homelab infrastructure including media automation, smart home, voice assistants, and personal web hosting.*
