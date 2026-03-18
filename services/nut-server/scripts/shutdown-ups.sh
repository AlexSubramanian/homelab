#!/usr/bin/env bash
# Shut down UniFi devices via SSH, then shut down the Pi.
# Requires: apt install sshpass
# Passwords are read from /etc/nut/shutdown-ups.env (not committed to repo):
#   UDM_SSH_PASS="<udm-ssh-password>"
#   UNAS_SSH_PASS="<unas-ssh-password>"

set -u
LOG="/var/log/nut-shutdown.log"

# Source passwords (UDM_SSH_PASS, UNAS_SSH_PASS)
. /etc/nut/shutdown-ups.env

echo "$(date): UPS low battery — initiating shutdown sequence" >> "$LOG"

# Shut down UDM SE
sshpass -p "$UDM_SSH_PASS" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@192.168.1.1 "ubnt-systool poweroff" &
echo "$(date): Sent shutdown to UDM SE" >> "$LOG"

# Shut down UNAS Pro
sshpass -p "$UNAS_SSH_PASS" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@192.168.1.33 "shutdown -h now" &
echo "$(date): Sent shutdown to UNAS Pro" >> "$LOG"

# Wait briefly for SSH commands to dispatch
sleep 5

# Shut down the Pi
echo "$(date): Shutting down Pi" >> "$LOG"
/sbin/shutdown -h +0
