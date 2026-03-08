#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_DIR="$REPO_DIR/services"
DOCKER_BASE="/opt/docker"

# Determine target service from argument or hostname
if [[ $# -ge 1 ]]; then
    SERVICE="$1"
else
    HOSTNAME="$(hostname -s)"
    case "$HOSTNAME" in
        arr-stack*) SERVICE="arr-stack" ;;
        plex*)      SERVICE="plex" ;;
        *)
            echo "Error: cannot auto-detect service from hostname '$HOSTNAME'."
            echo "Usage: $0 <service-name>"
            exit 1
            ;;
    esac
fi

SERVICE_DIR="$SERVICES_DIR/$SERVICE"
COMPOSE_SRC="$SERVICE_DIR/docker-compose.yml"
DOCKER_DIR="$DOCKER_BASE/$SERVICE"

if [[ ! -d "$SERVICE_DIR" ]]; then
    echo "Error: no service directory at $SERVICE_DIR"
    exit 1
fi

if [[ ! -f "$COMPOSE_SRC" ]]; then
    echo "Error: no docker-compose.yml found in $SERVICE_DIR"
    exit 1
fi

# Find a .service file in the service directory, if any
SYSTEMD_SRC="$(ls "$SERVICE_DIR"/*.service 2>/dev/null | head -1 || true)"

echo "==> Deploying: $SERVICE"
[[ -n "$SYSTEMD_SRC" ]] && echo "    Service file: $(basename "$SYSTEMD_SRC")"
echo "    Compose:      $COMPOSE_SRC"
echo "    Target dir:   $DOCKER_DIR"
echo

# --- Stop ---
if [[ -n "$SYSTEMD_SRC" ]]; then
    UNIT_NAME="$(basename "$SYSTEMD_SRC" .service)"
    echo "==> Stopping systemd service: $UNIT_NAME"
    sudo systemctl daemon-reload
    sudo systemctl stop "$UNIT_NAME" || true
else
    echo "==> Stopping docker compose: $SERVICE"
    if [[ -f "$DOCKER_DIR/docker-compose.yml" ]]; then
        sudo docker compose -f "$DOCKER_DIR/docker-compose.yml" down || true
    fi
fi

# --- Link service directory into /opt/docker ---
if [[ -L "$DOCKER_DIR" ]]; then
    CURRENT_TARGET="$(readlink "$DOCKER_DIR")"
    if [[ "$CURRENT_TARGET" != "$SERVICE_DIR" ]]; then
        echo "==> Updating symlink: $DOCKER_DIR -> $SERVICE_DIR"
        sudo rm "$DOCKER_DIR"
        sudo ln -s "$SERVICE_DIR" "$DOCKER_DIR"
    else
        echo "==> Symlink OK: $DOCKER_DIR -> $SERVICE_DIR"
    fi
elif [[ -d "$DOCKER_DIR" ]]; then
    echo "==> WARNING: $DOCKER_DIR is a real directory, replacing with symlink"
    sudo rm -rf "$DOCKER_DIR"
    sudo ln -s "$SERVICE_DIR" "$DOCKER_DIR"
else
    echo "==> Linking: $DOCKER_DIR -> $SERVICE_DIR"
    sudo mkdir -p "$DOCKER_BASE"
    sudo ln -s "$SERVICE_DIR" "$DOCKER_DIR"
fi

# --- Link systemd service file ---
if [[ -n "$SYSTEMD_SRC" ]]; then
    UNIT_FILE="/etc/systemd/system/$(basename "$SYSTEMD_SRC")"
    echo "==> Linking systemd unit: $UNIT_FILE"
    # Remove existing unit file (symlink or regular) so systemctl link doesn't fail
    if [[ -e "$UNIT_FILE" ]] || [[ -L "$UNIT_FILE" ]]; then
        sudo rm "$UNIT_FILE"
    fi
    sudo systemctl link "$SYSTEMD_SRC"
    sudo systemctl daemon-reload
fi

# --- Start ---
if [[ -n "$SYSTEMD_SRC" ]]; then
    echo "==> Enabling and starting: $UNIT_NAME"
    sudo systemctl enable "$UNIT_NAME"
    sudo systemctl start "$UNIT_NAME"
    echo
    sudo systemctl status "$UNIT_NAME" --no-pager
else
    echo "==> Starting docker compose: $SERVICE"
    sudo docker compose -f "$DOCKER_DIR/docker-compose.yml" up -d
    echo
    sudo docker compose -f "$DOCKER_DIR/docker-compose.yml" ps
fi

echo
echo "==> Done."
