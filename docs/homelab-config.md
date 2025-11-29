# Proxmox Homelab Configuration Reference
## Complete System Documentation

Last Updated: November 2025
**Version 3.0** - Configs moved to local VM storage

---

## Changelog from v2.0

- **Application Configs Moved to Local Storage**: All application configurations (Plex, Sonarr, Radarr, Prowlarr, Bazarr, SABnzbd) now stored on local VM disks instead of NFS
- **NFS Now Media-Only**: NFS share only used for media library and download data directories
- **SQLite Performance Fix**: Moving databases off NFS eliminates locking issues and improves performance
- **Permission Documentation**: Added notes about preserving execute permissions when copying configs
- **Butler Task Stability**: Plex overnight maintenance tasks now run without causing deadlocks

---

## Hardware Specifications

### Proxmox Host
- **Model:** HP EliteDesk 800 G4 SFF
- **CPU:** Intel Core i5-8500 (6 cores, 6 threads, 3.0GHz base)
- **RAM:** 32GB DDR4
- **GPU:** Intel UHD Graphics 630 (integrated)
- **Storage:** Local-LVM for VM storage
- **Network:** Intel X520-DA1 10 Gbps SFP+ NIC

### Network Infrastructure
- **Router:** UniFi Dream Machine SE (UDM SE)
- **NAS:** UniFi NAS Pro (U-NAS Pro) - 10 Gbps SFP+
- **Internet:** 2 Gbps down / 1 Gbps up fiber connection
- **Local Network:** 192.168.1.0/24
- **Storage Network:** 10 Gbps between Proxmox host and NAS

### Smart Home Hardware
- **Zigbee/Thread Coordinator:** Nabu Casa SkyConnect (ZWA-2) USB dongle
- **Voice Assistants:** 2x Home Assistant Voice Preview Edition (Voice PE) devices

---

## Network Configuration

### IP Assignments (Static DHCP Reservations)
| Service | IP Address | Type | VM ID |
|---------|------------|------|-------|
| Proxmox Host | 192.168.1.234 | Bare Metal | - |
| U-NAS Pro | 192.168.1.33 | Physical Device | - |
| Home Assistant | 192.168.1.162 | VM | 100 |
| Arr Stack + SABnzbd | 192.168.1.75 | VM | 102 |
| Plex Server | 192.168.1.103 | VM | 103 |

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
- **Export Path:** `/volume/b54f4a01-ce91-4ccc-9183-ab8cba945e4a/.srv/.unifi-drive/media/.data`
- **Mount Point on VMs:** `/mnt/media`
- **Protocol:** NFSv3 (U-NAS Pro does not support NFSv4)
- **Mount Options:** `vers=3,rsize=1048576,wsize=1048576,proto=tcp,hard,timeo=600,retrans=2,_netdev`

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
├── sonarr/
│   └── sonarr.db              # SQLite database
├── radarr/
│   └── radarr.db              # SQLite database
├── prowlarr/
│   └── prowlarr.db            # SQLite database
├── bazarr/
└── sabnzbd/
```

---

## Virtual Machine Architecture

### Resource Allocation Summary

| Service | ID | Type | vCPU | RAM | Disk | Special Features |
|---------|-----|------|------|-----|------|------------------|
| Home Assistant | 100 | VM | 2 | 6GB | 32GB | USB Passthrough, UEFI |
| Arr Stack + SABnzbd | 102 | VM | 4 | 6GB | 64GB | Local configs |
| Plex | 103 | VM | 4 | 8GB | 32GB | GPU Passthrough, Local configs |

**Total Resources:**
- **vCPU allocated:** 10 (1.7x overprovisioning on 6 physical cores)
- **RAM allocated:** 20GB of 32GB available
- **Overprovisioning:** Managed by Proxmox scheduler

All media VMs run Debian 13 (Trixie) with Docker.

### Disk Usage (Typical)

| VM | Total Disk | OS + Docker | Configs | Available |
|----|------------|-------------|---------|-----------|
| Arr Stack (102) | 64 GB | ~4 GB | ~150 MB | ~59 GB |
| Plex (103) | 32 GB | ~3 GB | ~600 MB | ~28 GB |

Config sizes grow slowly. Plex may reach 2-5 GB with large libraries and thumbnails enabled.

---

## Home Assistant VM Configuration (ID 100)

### VM Specifications
- **OS:** Home Assistant OS 16.2 (Updated January 2025)
- **Boot Type:** UEFI with 4MB EFI disk
- **CPU Type:** Host passthrough for optimal performance
- **Storage:** 32GB with SSD optimizations (discard, writethrough cache)
- **Network:** Virtio NIC on default bridge
- **Auto-start:** Enabled (`onboot: 1`)

### Hardware Passthrough
- **USB Device:** Nabu Casa SkyConnect (ZWA-2) Zigbee/Thread coordinator
- **USB Host Port:** `1-12` (Bus 001 Device 002: ID 303a:4001)
- **Purpose:** Zigbee device coordination and Thread border router

### Voice Assistant Hardware
- **Devices:** 2x Home Assistant Voice Preview Edition
- **Connection:** Wi-Fi (ESP32-S3 based)
- **Management:** ESPHome integration
- **Voice Pipeline:** Whisper (STT) → Gemini (LLM) → Piper (TTS)

## Service Stack Details

### Arr Stack + SABnzbd (VM 102)
**Purpose:** Media automation, indexing, and Usenet downloading

**OS:** Debian 13 (Trixie)
**BIOS:** SeaBIOS

**Docker Services:**
- **SABnzbd:** Usenet download client (Port 8080)
- **Radarr:** Movie management (Port 7878)
- **Sonarr:** TV show management (Port 8989)
- **Prowlarr:** Indexer management (Port 9696)
- **Bazarr:** Subtitle management (Port 6767)
- **FlareSolverr:** Cloudflare bypass (Port 8191)

**Key Configuration:**
- All services run as UID 977 / GID 988 (matches NFS squash settings)
- **Configs stored locally** at `/opt/configs/`
- Hardlink support enabled via single NFS mount
- Root folders: `/movies` (Radarr), `/tv` (Sonarr)
- No VPN needed - Usenet uses SSL encryption

**Volume Mounts (Docker):**
```yaml
# Local config storage (SQLite databases)
- /opt/configs/sonarr:/config
- /opt/configs/radarr:/config
- /opt/configs/prowlarr:/config
- /opt/configs/bazarr:/config
- /opt/configs/sabnzbd:/config

# NFS media storage
- /mnt/media/library/movies:/movies
- /mnt/media/library/tv:/tv
- /mnt/media/data:/data
```

### Plex Server (VM 103)
**Purpose:** Media server with hardware transcoding

**OS:** Debian 13 (Trixie)
**BIOS:** SeaBIOS

**Docker Services:**
- Plex Media Server (latest)

**Key Features:**
- Intel QuickSync hardware transcoding via iGPU passthrough
- **Config stored locally** at `/opt/plex-config/`
- Network mode: host
- Transcode directory: `/dev/shm` (RAM)

**GPU Passthrough Configuration:**
```
# In /etc/pve/qemu-server/103.conf
hostpci0: 0000:00:02.0,rombar=0
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

---

## Critical Configuration Elements

### Proxmox Host Requirements
1. **GRUB Configuration:** `intel_iommu=on iommu=pt` enabled
2. **GPU Device:** Major number 226 (`/dev/dri`)
3. **NFS Tools:** `nfs-common` package installed
4. **Intel GPU Tools:** For monitoring transcoding
5. **USB Device:** ZWA-2 for Home Assistant Z-Wave integration
6. **10 Gbps NIC:** Intel X520-DA1 for NAS connectivity

### VM Features (Home Assistant)
```
agent: 1              # QEMU guest agent enabled
bios: ovmf            # UEFI boot
cpu: host             # Host CPU passthrough
localtime: 1          # Use local timezone
onboot: 1             # Auto-start with host
usb0: host=1-12       # SkyConnect passthrough
```

### VM Features (Arr Stack - VM 102)
```
agent: 1              # QEMU guest agent enabled
bios: seabios         # Legacy BIOS
cpu: host             # Host CPU passthrough
onboot: 1             # Auto-start with host
startup: order=2      # Start after HA
```

### VM Features (Plex - VM 103)
```
agent: 1              # QEMU guest agent enabled
bios: seabios         # Legacy BIOS
cpu: host             # Host CPU passthrough
onboot: 1             # Auto-start with host
startup: order=3      # Start after Arr Stack
hostpci0: 0000:00:02.0,rombar=0  # iGPU passthrough
```

---

## Service Ports
| Service | Port | Purpose |
|---------|------|---------|
| Home Assistant | 8123 | Web UI & API |
| Plex | 32400 | Web UI & API |
| SABnzbd | 8080 | Web UI |
| Radarr | 7878 | Web UI |
| Sonarr | 8989 | Web UI |
| Prowlarr | 9696 | Web UI |
| Bazarr | 6767 | Web UI |
| FlareSolverr | 8191 | API |

---

## Media Workflow (Usenet)

1. **Content Discovery:** User adds media via Radarr/Sonarr
2. **Indexer Search:** Prowlarr queries configured Usenet indexers
3. **Download Initiation:** Radarr/Sonarr sends NZB to SABnzbd
4. **Secure Download:** SABnzbd downloads via SSL (port 563) - no VPN needed
5. **Download Location:** Files saved to `/mnt/media/data/usenet/complete/`
6. **Import Process:** Radarr/Sonarr hardlinks from `/data/usenet/complete/` to `/library/[movies|tv]/`
7. **Subtitle Search:** Bazarr automatically searches for and downloads subtitles
8. **Media Server:** Plex detects new files and adds to library
9. **Streaming:** Plex serves content with hardware transcoding if needed

---

## Maintenance Notes

### Local Config Considerations
- **Backup Strategy:** Local configs must be backed up separately (not on NAS)
- **Disk Space:** Monitor with `df -h /` - configs rarely exceed 1GB each
- **Database Health:** SQLite databases perform much better on local storage

### U-NAS Pro Considerations
- **NFS Version:** Only NFSv3 is supported (NFSv4 not available)
- **Performance:** 10 Gbps capable with proper mount options
- **Mount Options:** Use large rsize/wsize (1MB) for optimal throughput

### Home Assistant Considerations
- **USB Device Stability:** SkyConnect passthrough is stable across VM reboots
- **Voice PE Devices:** Require stable Wi-Fi connection for optimal performance
- **Backup Strategy:** VM snapshots capture entire HA OS state
- **Updates:** HA OS updates handled through HA interface, not Proxmox
- **Voice Pipeline:** Resource-intensive, monitor CPU/RAM usage during voice processing

### Backup Recommendations
- **VM Snapshots:** All VMs before major updates
- **VM Configurations:** `/etc/pve/qemu-server/*.conf`
- **Docker Compose Files:** `/opt/docker/*/docker-compose.yml` (on each VM)
- **Local Application Configs:** 
  - Plex: `/opt/plex-config/`
  - Arr Stack: `/opt/configs/`
- **ESPHome Configurations:** Backed up within Home Assistant


### Performance Optimizations
- Plex transcoding uses RAM (`/dev/shm`)
- Hardlinks enabled for instant media moves
- Over-provisioned vCPUs managed by Proxmox scheduler
- Intel QuickSync reduces CPU load during transcoding
- Home Assistant VM uses host CPU passthrough for optimal performance
- **SQLite databases on local SSD** - eliminates NFS locking issues
- 10 Gbps NFS with optimized mount options for fast transfers

---

## Past Issues & Solutions

### Issue: Plex hanging overnight / "No content available"
**Cause:** Previously caused by SQLite databases on NFS with locking issues, or missing execute permissions on codec binaries
**Solution:** 
1. Configs now stored locally - this should not recur
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
1. Verify `hostpci0` line in VM config
2. Check `/dev/dri` exists in VM: `ls -la /dev/dri/`
3. Install VA-API drivers: `apt install vainfo intel-media-va-driver-non-free`
4. Test with `vainfo`

### Issue: Slow NFS performance
**Cause:** Suboptimal mount options
**Solution:**
1. Verify mount options include large rsize/wsize
2. Check 10 Gbps link is active: `ethtool <interface>`
3. Test with iperf3 between host and NAS

---

## Future Considerations

- **NFSv4 Support:** When Ubiquiti adds NFSv4 to UNAS Pro, enable `nconnect` for better throughput
- **Storage Expansion:** Monitor NAS usage (currently 22TB total capacity)
- **Smart Home Growth:** Connect SLZB-06 for zigbee support
- **Voice Assistant Expansion:** Add more Voice PE devices for whole-home coverage
- **Backup Automation:** Implement automated VM snapshots and config backups
- **Home Assistant Growth:** VM resources can be expanded as automation grows
- **Local LLM:** Consider running local LLM (like Ollama) if resources permit

---

*This document provides complete context for troubleshooting, maintenance, or reconstruction of the entire homelab infrastructure including media automation, smart home systems, and voice assistant integration.*
