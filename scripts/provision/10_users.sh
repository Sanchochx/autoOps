#!/usr/bin/env bash
# US-HOST-001: native users and privilege model. Idempotent.
#
#   sudo ADMIN_USER=<user> ./scripts/provision/10_users.sh
#
# Variables: ADMIN_USER (required), SERVICE_USER=autoops, SERVICE_UID=1500,
# SERVICE_GID=1500, APP_DIR=/opt/autoops, PWQUALITY_MINLEN=14.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_root
require_var ADMIN_USER
SERVICE_USER="${SERVICE_USER:-autoops}"
SERVICE_UID="${SERVICE_UID:-1500}"
SERVICE_GID="${SERVICE_GID:-1500}"
APP_DIR="${APP_DIR:-/opt/autoops}"
PWQUALITY_MINLEN="${PWQUALITY_MINLEN:-14}"
NOLOGIN_SHELL=/usr/sbin/nologin

[[ $ADMIN_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "ADMIN_USER '${ADMIN_USER}' is not a valid user name."
[[ $ADMIN_USER != root && $ADMIN_USER != "$SERVICE_USER" ]] \
  || die "ADMIN_USER cannot be root or ${SERVICE_USER}."

# --- AC-1: admin user and locked root ---------------------------
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --groups sudo "$ADMIN_USER"
  log_change "created user ${ADMIN_USER}"
fi

if ! in_group "$ADMIN_USER" sudo; then
  usermod --append --groups sudo "$ADMIN_USER"
  log_change "${ADMIN_USER} added to the sudo group"
fi

# AC-4: the docker group is equivalent to root; the admin operates with `sudo docker`.
if getent group docker >/dev/null && in_group "$ADMIN_USER" docker; then
  gpasswd --delete "$ADMIN_USER" docker >/dev/null
  log_change "${ADMIN_USER} removed from the docker group"
fi

if sudo -l -U "$ADMIN_USER" 2>/dev/null | grep -q 'NOPASSWD'; then
  log_warn "${ADMIN_USER} has NOPASSWD sudo rules; review /etc/sudoers.d (the check will mark it as FAIL)."
fi

# Anti-lockout safeguard: root is not locked unless an admin with a password and sudo exists.
if [[ "$(passwd_status "$ADMIN_USER")" != P ]]; then
  die "${ADMIN_USER} has no usable password. Run 'sudo passwd ${ADMIN_USER}' and retry; root has not been locked."
fi

if [[ "$(passwd_status root)" != L ]]; then
  passwd --lock root >/dev/null
  log_change "root password locked"
fi

# --- AC-2: service user without login --------------------------------------
if getent group "$SERVICE_USER" >/dev/null; then
  [[ "$(getent group "$SERVICE_USER" | cut -d: -f3)" == "$SERVICE_GID" ]] \
    || die "Group ${SERVICE_USER} exists with a GID other than ${SERVICE_GID}."
else
  [[ -z "$(getent group "$SERVICE_GID")" ]] || die "GID ${SERVICE_GID} is already in use."
  groupadd --gid "$SERVICE_GID" "$SERVICE_USER"
  log_change "created group ${SERVICE_USER} (GID ${SERVICE_GID})"
fi

if getent passwd "$SERVICE_USER" >/dev/null; then
  [[ "$(id -u "$SERVICE_USER")" == "$SERVICE_UID" ]] \
    || die "User ${SERVICE_USER} exists with a UID other than ${SERVICE_UID}."
  if [[ "$(getent passwd "$SERVICE_USER" | cut -d: -f7)" != "$NOLOGIN_SHELL" ]]; then
    usermod --shell "$NOLOGIN_SHELL" "$SERVICE_USER"
    log_change "shell de ${SERVICE_USER} -> ${NOLOGIN_SHELL}"
  fi
else
  [[ -z "$(getent passwd "$SERVICE_UID")" ]] || die "UID ${SERVICE_UID} is already in use."
  useradd --system --uid "$SERVICE_UID" --gid "$SERVICE_GID" \
    --home-dir "$APP_DIR" --no-create-home --shell "$NOLOGIN_SHELL" "$SERVICE_USER"
  log_change "created service user ${SERVICE_USER} (UID ${SERVICE_UID})"
fi

if [[ "$(passwd_status "$SERVICE_USER")" != L ]]; then
  passwd --lock "$SERVICE_USER" >/dev/null
  log_change "${SERVICE_USER} password locked"
fi

if [[ ! -d $APP_DIR ]]; then
  install --directory --owner="$SERVICE_USER" --group="$SERVICE_USER" --mode=750 "$APP_DIR"
  log_change "creado ${APP_DIR}"
fi
ensure_perms "$APP_DIR" "${SERVICE_USER}:${SERVICE_USER}" 750

# --- AC-3: secrets, umask and password policy -------------------------
if [[ -f $APP_DIR/.env ]]; then
  ensure_perms "$APP_DIR/.env" "${SERVICE_USER}:${SERVICE_USER}" 600
else
  log_info "${APP_DIR}/.env does not exist yet: once deployed it must be owned by ${SERVICE_USER}:${SERVICE_USER} with mode 0600."
fi

# Umask 027 for login sessions (pam_umask reads it from login.defs). The service
# process gets it from the systemd unit (UMask=0027, US-SYS-003).
if grep -Eq '^UMASK[[:space:]]+027$' /etc/login.defs; then
  :
elif grep -Eq '^UMASK[[:space:]]' /etc/login.defs; then
  sed -i -E 's/^UMASK[[:space:]]+.*/UMASK\t\t027/' /etc/login.defs
  log_change "UMASK 027 en /etc/login.defs"
else
  printf 'UMASK\t\t027\n' >>/etc/login.defs
  log_change "UMASK 027 added to /etc/login.defs"
fi

if ! dpkg -s libpam-pwquality >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y libpam-pwquality >/dev/null
  log_change "instalado libpam-pwquality"
fi
install -d -m 755 /etc/security/pwquality.conf.d
ensure_file /etc/security/pwquality.conf.d/10-autoops.conf "# Managed by scripts/provision/10_users.sh
minlen = ${PWQUALITY_MINLEN}
minclass = 3
maxrepeat = 3
dictcheck = 1
enforce_for_root"

log_info "10_users.sh finished."
