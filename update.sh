#!/usr/bin/env bash
set -euo pipefail

# Pull newer images for this host's compose stack, show what changed, and
# restart the stack through systemd if anything did.

usage() {
    cat <<EOF
Usage: $0 [--check] [-y] [--force] [--prune] [service]

  --check   Pull and report what would change, but don't restart
  -y        Don't ask before restarting
  --force   Restart even if no images changed
  --prune   Remove dangling (replaced) images after a successful update
  service   arr-stack, plex, or monitoring (auto-detected from hostname)
EOF
}

CHECK=0; YES=0; FORCE=0; PRUNE=0; SERVICE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)   CHECK=1 ;;
        -y|--yes)  YES=1 ;;
        --force)   FORCE=1 ;;
        --prune)   PRUNE=1 ;;
        -h|--help) usage; exit 0 ;;
        -*)        echo "Unknown option: $1"; usage; exit 1 ;;
        *)         SERVICE="$1" ;;
    esac
    shift
done

# Determine target service from argument or hostname
if [[ -z "$SERVICE" ]]; then
    HOSTNAME="$(hostname -s)"
    case "$HOSTNAME" in
        arr-stack*)         SERVICE="arr-stack" ;;
        plex*)              SERVICE="plex" ;;
        monitoring*|rpi4b*) SERVICE="monitoring" ;;
        *)
            echo "Error: cannot auto-detect service from hostname '$HOSTNAME'."
            usage
            exit 1
            ;;
    esac
fi

COMPOSE="/opt/docker/$SERVICE/docker-compose.yml"
if [[ ! -f "$COMPOSE" ]]; then
    echo "Error: $COMPOSE not found (has $SERVICE been deployed?)"
    exit 1
fi

dc() { docker compose -f "$COMPOSE" "$@"; }

# Human-readable version of an image: PMS package version for Plex, the OCI
# version label for everything else, or a short image ID as a fallback.
version_of() {
    local svc="$1" image="$2" v=""
    if [[ "$svc" == "plex" ]]; then
        v="$(docker run --rm --entrypoint dpkg-query "$image" -W -f='${Version}' plexmediaserver 2>/dev/null || true)"
    else
        v="$(docker image inspect -f '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$image" 2>/dev/null || true)"
    fi
    [[ -z "$v" || "$v" == "<no value>" ]] && v="${image#sha256:}" && v="${v:0:12}"
    echo "$v"
}

# --- Pull ---
echo "==> Pulling images for: $SERVICE"
dc pull --quiet --ignore-pull-failures || true

# --- Compare running containers against freshly pulled images ---
echo "==> Comparing running containers to latest images"
CHANGED=()
for svc in $(dc config --services); do
    ctn="$(dc ps -q "$svc")"
    if [[ -z "$ctn" ]]; then
        echo "    $svc: not running"
        continue
    fi
    ref="$(docker inspect -f '{{.Config.Image}}' "$ctn")"
    running="$(docker inspect -f '{{.Image}}' "$ctn")"
    latest="$(docker image inspect -f '{{.Id}}' "$ref")"
    if [[ "$running" != "$latest" ]]; then
        printf '    %-14s %s -> %s\n' "$svc" "$(version_of "$svc" "$running")" "$(version_of "$svc" "$latest")"
        CHANGED+=("$svc")
    fi
done

if [[ ${#CHANGED[@]} -eq 0 && $FORCE -eq 0 ]]; then
    echo "==> Everything is up to date."
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    echo "==> --check given, not restarting."
    exit 0
fi

# --- Warn about active Plex streams ---
if [[ "$SERVICE" == "plex" ]]; then
    token="$(docker exec plex sed -n 's/.*PlexOnlineToken="\([^"]*\)".*/\1/p' \
        "/config/Library/Application Support/Plex Media Server/Preferences.xml" 2>/dev/null || true)"
    streams="$(curl -s "http://localhost:32400/status/sessions?X-Plex-Token=$token" \
        | sed -n 's/.*<MediaContainer size="\([0-9]*\)".*/\1/p' | head -1 || true)"
    if [[ -z "$streams" ]]; then
        echo "    Note: could not check for active Plex streams"
    elif [[ "$streams" -gt 0 ]]; then
        echo "    WARNING: $streams active Plex stream(s) will be interrupted"
    fi
fi

# --- Confirm ---
if [[ $YES -eq 0 ]]; then
    if [[ ! -t 0 ]]; then
        echo "Not running in a terminal; re-run with -y to restart."
        exit 1
    fi
    read -rp "Restart $SERVICE now? All containers in the stack will be recreated. [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# --- Restart ---
echo "==> Restarting systemd service: $SERVICE"
sudo systemctl restart "$SERVICE"

echo "==> Waiting for containers to come up"
READY=0
for _ in $(seq 40); do
    # shellcheck disable=SC2046 # word splitting of container IDs is intended
    states="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
        $(dc ps -aq) 2>/dev/null || true)"
    if [[ -n "$states" ]] && ! grep -qvE '^running ?(healthy)?$' <<<"$states"; then
        READY=1
        break
    fi
    sleep 3
done

echo
dc ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}'
echo
[[ $READY -eq 1 ]] || echo "WARNING: not every container is running/healthy after 2 minutes — check 'docker compose logs'."

if [[ "$SERVICE" == "plex" ]]; then
    v="$(curl -s --retry 10 --retry-connrefused --retry-delay 3 http://localhost:32400/identity \
        | grep -o 'MediaContainer[^>]*' | sed -n 's/.* version="\([^"]*\)".*/\1/p' || true)"
    echo "==> Plex Media Server version: ${v:-unknown}"
fi

# --- Prune ---
if [[ $PRUNE -eq 1 ]]; then
    echo "==> Removing dangling images"
    docker image prune -f
fi

echo "==> Done."
