#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_DIR="$REPO_DIR/services"
DOCKER_BASE="/opt/docker"

# shellcheck source=lib/stack.sh
source "$REPO_DIR/lib/stack.sh"

# Determine target service from argument or hostname
if [[ $# -ge 1 ]]; then
    SERVICE="$1"
else
    HOSTNAME="$(hostname -s)"
    case "$HOSTNAME" in
        arr-stack*)  SERVICE="arr-stack" ;;
        plex*)       SERVICE="plex" ;;
        monitoring*) SERVICE="monitoring" ;;
        *)
            echo "Error: cannot auto-detect service from hostname '$HOSTNAME'."
            echo "Usage: $0 <service-name>"
            exit 1
            ;;
    esac
fi

SERVICE_DIR="$SERVICES_DIR/$SERVICE"

# --- Native (non-Docker) services ---
case "$SERVICE" in
    nut-server)
        echo "==> Deploying: nut-server (native)"
        echo

        # Ensure the nut user can access the UPS USB device
        UDEV_RULE='/etc/udev/rules.d/99-nut-ups.rules'
        if [[ ! -f "$UDEV_RULE" ]]; then
            echo "==> Installing udev rule for UPS USB access"
            echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="0764", ATTR{idProduct}=="0601", MODE="0660", GROUP="nut"' | sudo tee "$UDEV_RULE" > /dev/null
            sudo udevadm control --reload-rules && sudo udevadm trigger
        fi

        echo "==> Copying NUT config files to /etc/nut/"
        # Remove any old symlinks first
        for f in nut.conf ups.conf upsd.conf upsd.users upsmon.conf; do
            [[ -L "/etc/nut/$f" ]] && sudo rm "/etc/nut/$f"
        done
        # Always copy non-sensitive config files
        for f in nut.conf ups.conf upsd.conf; do
            sudo cp "$SERVICE_DIR/etc/$f" "/etc/nut/$f"
            echo "    $f"
        done
        # Only copy password files if they haven't been configured with our UPS yet
        for f in upsd.users upsmon.conf; do
            if [[ ! -f "/etc/nut/$f" ]] || ! sudo grep -q 'cyberpower' "/etc/nut/$f"; then
                sudo cp "$SERVICE_DIR/etc/$f" "/etc/nut/$f"
                echo "    $f (new)"
            else
                echo "    $f (keeping existing)"
            fi
        done

        # Fix ownership and permissions
        sudo chown root:nut /etc/nut/nut.conf /etc/nut/ups.conf /etc/nut/upsd.conf
        sudo chmod 644 /etc/nut/nut.conf /etc/nut/ups.conf /etc/nut/upsd.conf
        sudo chown root:nut /etc/nut/upsd.users /etc/nut/upsmon.conf
        sudo chmod 640 /etc/nut/upsd.users /etc/nut/upsmon.conf

        echo "==> Copying shutdown script to /etc/nut/"
        sudo cp "$SERVICE_DIR/scripts/shutdown-ups.sh" /etc/nut/shutdown-ups.sh
        sudo chmod +x /etc/nut/shutdown-ups.sh

        # Prompt for passwords if placeholders are still present
        if sudo grep -q '<to-be-set>' /etc/nut/upsd.users; then
            echo
            echo "==> NUT passwords not yet configured"
            read -rsp "    Enter admin password (primary/Pi): " ADMIN_PASS
            echo
            read -rsp "    Enter monitor password (secondary/Proxmox): " MON_PASS
            echo
            sudo sed -i "0,/<to-be-set>/s/<to-be-set>/$ADMIN_PASS/" /etc/nut/upsd.users
            sudo sed -i "s/<to-be-set>/$MON_PASS/" /etc/nut/upsd.users
            sudo sed -i "s/<to-be-set>/$ADMIN_PASS/" /etc/nut/upsmon.conf
            echo "    Passwords set in upsd.users and upsmon.conf"
        fi

        # Create shutdown-ups.env if it doesn't exist
        if [[ ! -f /etc/nut/shutdown-ups.env ]]; then
            echo
            echo "==> SSH passwords for UPS shutdown not yet configured"
            read -rsp "    Enter UDM SE SSH password (root@192.168.1.1): " UDM_PASS
            echo
            read -rsp "    Enter UNAS Pro SSH password (root@192.168.1.33): " UNAS_PASS
            echo
            printf 'UDM_SSH_PASS="%s"\nUNAS_SSH_PASS="%s"\n' "$UDM_PASS" "$UNAS_PASS" | sudo tee /etc/nut/shutdown-ups.env > /dev/null
            sudo chmod 600 /etc/nut/shutdown-ups.env
            echo "    Created /etc/nut/shutdown-ups.env"
        fi

        echo
        echo "==> Restarting NUT services"
        sudo systemctl restart nut-driver.target nut-server nut-monitor
        echo
        sudo systemctl status nut-driver.target nut-server nut-monitor --no-pager
        echo
        echo "==> Done."
        exit 0
        ;;
    homelab-agent)
        echo "==> Deploying: homelab-agent (native)"
        echo

        # Dedicated unprivileged account. It needs the docker group to talk to
        # the daemon, and nothing else beyond the three systemctl restart
        # commands granted in sudoers below.
        if ! id hlagent >/dev/null 2>&1; then
            echo "==> Creating system user: hlagent"
            sudo useradd --system --no-create-home --shell /usr/sbin/nologin hlagent
        fi
        if ! id -nG hlagent | tr ' ' '\n' | grep -qx docker; then
            echo "==> Adding hlagent to the docker group"
            sudo usermod -aG docker hlagent
        fi

        # The agent runs update.sh straight out of this checkout so there is
        # exactly one copy of it. /home/alex is 0700 by default, which blocks
        # that; 0711 lets hlagent traverse to the repo without being able to
        # list the home directory. The repo itself is already world-readable.
        HOME_MODE="$(stat -c '%a' "$HOME")"
        if [[ "$HOME_MODE" == "700" ]]; then
            echo "==> Relaxing $HOME to 0711 so hlagent can reach the repo"
            echo "    (traverse only -- the directory still cannot be listed)"
            sudo chmod 0711 "$HOME"
        fi

        echo "==> Installing sudoers rule"
        sudo visudo -cf "$REPO_DIR/system/sudoers.d/homelab-update" >/dev/null
        sudo install -m 0440 -o root -g root \
            "$REPO_DIR/system/sudoers.d/homelab-update" /etc/sudoers.d/homelab-update

        echo "==> Configuring /etc/homelab-agent/env"
        sudo mkdir -p /etc/homelab-agent
        if [[ ! -f /etc/homelab-agent/env ]]; then
            LAN_IP="$(hostname -I | awk '{print $1}')"
            TOKEN="$(openssl rand -hex 32)"
            sudo tee /etc/homelab-agent/env >/dev/null <<AGENTENV
# Generated by deploy.sh on $(date -Iseconds). Keep this file secret.
HOMELAB_AGENT_TOKEN=$TOKEN
HOMELAB_AGENT_BIND=$LAN_IP
HOMELAB_AGENT_PORT=9180
AGENTENV
            echo "    Created with a fresh token, bound to $LAN_IP"
            echo
            echo "    Add this to VM 104's .env so the admin API can reach this host:"
            echo "      HOMELAB_AGENT_TOKEN_${SERVICE_ENV_SUFFIX:-$(hostname -s | tr 'a-z-' 'A-Z_')}=$TOKEN"
            echo
        else
            echo "    Keeping existing /etc/homelab-agent/env"
        fi
        sudo chown root:root /etc/homelab-agent/env
        sudo chmod 0600 /etc/homelab-agent/env

        echo "==> Linking systemd unit"
        UNIT_FILE=/etc/systemd/system/homelab-agent.service
        [[ -e "$UNIT_FILE" || -L "$UNIT_FILE" ]] && sudo rm "$UNIT_FILE"
        sudo systemctl link "$SERVICE_DIR/homelab-agent.service"
        sudo systemctl daemon-reload
        sudo systemctl enable homelab-agent
        sudo systemctl restart homelab-agent

        sleep 1
        echo
        sudo systemctl status homelab-agent --no-pager | head -12
        echo
        echo "==> Done."
        exit 0
        ;;
    nut-client)
        echo "==> Deploying: nut-client (native)"
        echo

        echo "==> Copying NUT config files to /etc/nut/"
        # Remove any old symlinks first
        for f in nut.conf upsmon.conf; do
            [[ -L "/etc/nut/$f" ]] && sudo rm "/etc/nut/$f"
        done
        sudo cp "$SERVICE_DIR/nut.conf" /etc/nut/nut.conf
        echo "    nut.conf"
        if [[ ! -f /etc/nut/upsmon.conf ]] || ! sudo grep -q 'cyberpower' /etc/nut/upsmon.conf; then
            sudo cp "$SERVICE_DIR/upsmon.conf" /etc/nut/upsmon.conf
            echo "    upsmon.conf (new)"
        else
            echo "    upsmon.conf (keeping existing)"
        fi

        # Fix ownership and permissions
        sudo chown root:nut /etc/nut/nut.conf
        sudo chmod 644 /etc/nut/nut.conf
        sudo chown root:nut /etc/nut/upsmon.conf
        sudo chmod 640 /etc/nut/upsmon.conf

        # Prompt for password if placeholder is still present
        if sudo grep -q '<to-be-set>' /etc/nut/upsmon.conf; then
            echo
            echo "==> NUT monitor password not yet configured"
            read -rsp "    Enter monitor password (must match Pi's upsd.users [monitor]): " MON_PASS
            echo
            sudo sed -i "s/<to-be-set>/$MON_PASS/" /etc/nut/upsmon.conf
            echo "    Password set in upsmon.conf"
        fi

        echo
        echo "==> Restarting nut-monitor"
        sudo systemctl restart nut-monitor
        echo
        sudo systemctl status nut-monitor --no-pager
        echo
        echo "==> Done."
        exit 0
        ;;
esac

# --- Docker-based services ---
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

# --- Deploy systemd drop-in overrides ---
SYSTEMD_DIR="$SERVICE_DIR/systemd"
if [[ -d "$SYSTEMD_DIR" ]]; then
    echo "==> Installing systemd drop-in overrides"
    for override_dir in "$SYSTEMD_DIR"/*.d; do
        if [[ -d "$override_dir" ]]; then
            TARGET="/etc/systemd/system/$(basename "$override_dir")"
            echo "    $TARGET/"
            sudo mkdir -p "$TARGET"
            sudo cp "$override_dir"/* "$TARGET/"
        fi
    done
    sudo systemctl daemon-reload
fi

# --- Runtime state directory ---
# The units read COMPOSE_FILE from here, and update.sh writes rollback snapshots
# into it. It lives outside /opt/docker/<service> because that path is a symlink
# back into this git checkout -- generated state there would dirty the worktree.
if stack_is_known_service "$SERVICE"; then
    STATE_DIR="$(stack_state_dir "$SERVICE")"
    ENV_FILE="$(stack_env_file "$SERVICE")"

    echo "==> Runtime state: $STATE_DIR"
    sudo mkdir -p "$(stack_history_dir "$SERVICE")"
    # Group-owned by docker, setgid: update.sh runs as a normal user today and as
    # the agent user in future, and both need docker group membership anyway, so
    # write access here grants nothing that group doesn't already confer.
    sudo chgrp -R docker "$STATE_DIR"
    sudo chmod 2775 "$STATE_DIR" "$(stack_history_dir "$SERVICE")"

    if stack_is_pinned "$SERVICE"; then
        # Rewriting stack.env here would silently unpin a rolled-back stack and
        # the next start would quietly pull the bad image back in.
        echo "    Keeping existing stack.env -- rollback pin active on:" \
             "$(stack_pinned_services "$SERVICE" | tr '\n' ' ')"
        echo "    Clear it with: ./update.sh --rollback --clear $SERVICE"
    else
        echo "    Writing $ENV_FILE"
        sudo tee "$ENV_FILE" >/dev/null <<ENVEOF
# Written by deploy.sh -- systemd reads this via EnvironmentFile.
# COMPOSE_PROJECT_NAME is pinned so adding a rollback overlay can never change
# the project name and orphan the running containers.
COMPOSE_PROJECT_NAME=$SERVICE
COMPOSE_FILE=$(stack_base_compose "$SERVICE")
ENVEOF
        sudo chgrp docker "$ENV_FILE"
        sudo chmod 664 "$ENV_FILE"
    fi
    echo
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
