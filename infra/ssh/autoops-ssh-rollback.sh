#!/usr/bin/env bash
# Reverts the SSH drop-in to the state prior to the last run of 20_ssh.sh.
# Triggered by a systemd timer if the change is not confirmed in time
# (`20_ssh.sh --confirm`). Installed at /usr/local/sbin/autoops-ssh-rollback.
set -euo pipefail

CONF=/etc/ssh/sshd_config.d/10-autoops.conf
STATE_DIR=/var/lib/autoops-provision/ssh

if [[ -f $STATE_DIR/10-autoops.conf.prev ]]; then
  cp -p "$STATE_DIR/10-autoops.conf.prev" "$CONF"
elif [[ -f $STATE_DIR/10-autoops.conf.absent ]]; then
  rm -f "$CONF"
else
  echo "autoops-ssh-rollback: no previous state saved." >&2
  exit 1
fi

/usr/sbin/sshd -t
if systemctl is-active --quiet ssh; then
  systemctl reload ssh
fi
logger -t autoops-ssh-rollback "SSH configuration reverted to the previous state"
echo "autoops-ssh-rollback: SSH configuration reverted."
