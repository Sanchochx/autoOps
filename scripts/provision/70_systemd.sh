#!/usr/bin/env bash
# US-SYS-003: autoops.service and autoops-migrate.service (+ US-SYS-004 backup units, US-CICD-004 deploy units). Idempotent.
#
#   sudo ./scripts/provision/70_systemd.sh
#
# Variables (all optional):
#   SERVICE_USER=autoops     user that runs the units (must be in the docker group)
#   APP_DIR=/opt/autoops     deployment directory (docker-compose.yml and .env)
#   AUTOOPS_ENABLE=0         1 = also `systemctl enable autoops` (start at boot, AC-4)
# Backup timer (US-SYS-004): BACKUP_DIR / BACKUP_SCHEDULE are read from ${APP_DIR}/.env.
# Deploy handoff (US-CICD-004): DEPLOY_INBOX_DIR / DEPLOY_OUTBOX_DIR / DEPLOY_STATE_DIR are read from ${APP_DIR}/.env
# (defaults ${APP_DIR}/.deploy/{inbox,outbox} and ${APP_DIR}/.deploy); DEPLOY_INBOX_UID=10001 is the runner's UID.
# Installs the units but does NOT start them (except autoops-deploy.path, which is inert until a request exists): start is a manual verification step.
# See infra/systemd/README.md.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UNIT_SRC="${REPO_ROOT}/infra/systemd"
UNIT_DIR=/etc/systemd/system
UNITS=(autoops autoops-migrate autoops-backup autoops-deploy)

require_root
SERVICE_USER="${SERVICE_USER:-autoops}"
APP_DIR="${APP_DIR:-/opt/autoops}"
AUTOOPS_ENABLE="${AUTOOPS_ENABLE:-0}"

[[ -d /run/systemd/system ]] || die "systemd is not active on this system."
[[ $APP_DIR == /* && $APP_DIR =~ ^[A-Za-z0-9_./-]+$ ]] || die "Invalid APP_DIR: '${APP_DIR}'."
[[ $SERVICE_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid SERVICE_USER: '${SERVICE_USER}'."
id "$SERVICE_USER" >/dev/null 2>&1 || die "User ${SERVICE_USER} does not exist (run 10_users.sh first)."
in_group "$SERVICE_USER" docker || die "${SERVICE_USER} is not in the docker group (run 60_docker.sh first)."
[[ -x /usr/bin/docker ]] || die "/usr/bin/docker does not exist (run 60_docker.sh first)."
[[ -f ${APP_DIR}/docker-compose.yml ]] || die "${APP_DIR}/docker-compose.yml does not exist."
[[ -f ${APP_DIR}/.env ]] || die "${APP_DIR}/.env does not exist (cp .env.example .env and fill it in)."

# --- AC-2: the .env holds the secrets: only the service user can read it -----------------
ensure_perms "${APP_DIR}/.env" "${SERVICE_USER}:${SERVICE_USER}" 600
# DOCKER_CONFIG directory used by the units (the CLI cannot use ~ under ProtectHome).
install -d -m 700 -o "$SERVICE_USER" -g "$SERVICE_USER" "${APP_DIR}/.docker"

# --- US-SYS-004 AC-2: backup settings from .env (systemd cannot read them itself) ---------
env_value() { local l; l="$(grep -E "^$1=" "${APP_DIR}/.env" | tail -n1)" || true; l="${l#*=}"; l="${l%\"}"; echo "${l#\"}"; }
BACKUP_DIR="$(env_value BACKUP_DIR)"
BACKUP_SCHEDULE="$(env_value BACKUP_SCHEDULE)"
[[ $BACKUP_DIR == /* && $BACKUP_DIR =~ ^[A-Za-z0-9_./-]+$ ]] || die "Invalid or missing BACKUP_DIR in .env: '${BACKUP_DIR}'."
[[ -n $BACKUP_SCHEDULE && $BACKUP_SCHEDULE =~ ^[A-Za-z0-9*:/,.~\ -]+$ ]] || die "Invalid or missing BACKUP_SCHEDULE in .env: '${BACKUP_SCHEDULE}'."
systemd-analyze calendar "$BACKUP_SCHEDULE" >/dev/null 2>&1 || die "BACKUP_SCHEDULE is not a valid OnCalendar expression: '${BACKUP_SCHEDULE}'."
# ReadWritePaths= requires the directory to exist when the unit starts.
install -d -m 700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$BACKUP_DIR"

# --- US-CICD-004 AC-3: spool directories of the deploy handoff -----------------------------------------------------------
# inbox: the runner (UID 10001) writes `request` here; the service user gets -wx through the group, so it can read the
# file by name and delete it, but the directory is not listable by anyone else. outbox: only the service user writes
# `status`; the runner reads it. State (current/previous/history/lock) is private to the service user.
DEPLOY_STATE_DIR="$(env_value DEPLOY_STATE_DIR)"; DEPLOY_STATE_DIR="${DEPLOY_STATE_DIR:-${APP_DIR}/.deploy}"
DEPLOY_INBOX_DIR="$(env_value DEPLOY_INBOX_DIR)"; DEPLOY_INBOX_DIR="${DEPLOY_INBOX_DIR:-${DEPLOY_STATE_DIR}/inbox}"
DEPLOY_OUTBOX_DIR="$(env_value DEPLOY_OUTBOX_DIR)"; DEPLOY_OUTBOX_DIR="${DEPLOY_OUTBOX_DIR:-${DEPLOY_STATE_DIR}/outbox}"
DEPLOY_INBOX_UID="${DEPLOY_INBOX_UID:-10001}"
for _d in "$DEPLOY_STATE_DIR" "$DEPLOY_INBOX_DIR" "$DEPLOY_OUTBOX_DIR"; do
  [[ $_d == /* && $_d =~ ^[A-Za-z0-9_./-]+$ ]] || die "Invalid deploy path in .env: '${_d}'."
done
[[ $DEPLOY_INBOX_UID =~ ^[0-9]+$ ]] || die "Invalid DEPLOY_INBOX_UID: '${DEPLOY_INBOX_UID}'."
install -d -m 700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DEPLOY_STATE_DIR"
install -d -m 755 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DEPLOY_OUTBOX_DIR"
install -d -m 730 -o "$DEPLOY_INBOX_UID" -g "$SERVICE_USER" "$DEPLOY_INBOX_DIR"

# --- AC-1 / AC-3: render, verify and install the units ----------------------------------
UNITS_CHANGED=0
for unit in "${UNITS[@]}"; do
  tpl="${UNIT_SRC}/${unit}.service.tpl"
  [[ -f $tpl ]] || die "Template ${tpl} does not exist."
  rendered="$(sed -e "s|@@APP_DIR@@|${APP_DIR}|g" -e "s|@@SERVICE_USER@@|${SERVICE_USER}|g" -e "s|@@BACKUP_DIR@@|${BACKUP_DIR}|g" \
    -e "s|@@DEPLOY_INBOX_DIR@@|${DEPLOY_INBOX_DIR}|g" -e "s|@@DEPLOY_OUTBOX_DIR@@|${DEPLOY_OUTBOX_DIR}|g" "$tpl")"
  tmp="$(mktemp --suffix=".service")"
  printf '%s\n' "$rendered" >"$tmp"
  if ! systemd-analyze verify "$tmp" >/dev/null 2>&1; then
    systemd-analyze verify "$tmp" >&2 || true
    rm -f "$tmp"
    die "${unit}.service does not pass 'systemd-analyze verify'; not installing."
  fi
  rm -f "$tmp"
  ensure_file "${UNIT_DIR}/${unit}.service" "$rendered"
  chmod 644 "${UNIT_DIR}/${unit}.service"
  ((FILE_CHANGED)) && UNITS_CHANGED=1
done
# autoops-backup.timer: only verified together with its service (same temp dir).
tpl="${UNIT_SRC}/autoops-backup.timer.tpl"
[[ -f $tpl ]] || die "Template ${tpl} does not exist."
timer="$(sed -e "s|@@APP_DIR@@|${APP_DIR}|g" -e "s|@@BACKUP_SCHEDULE@@|${BACKUP_SCHEDULE}|g" "$tpl")"
ensure_file "${UNIT_DIR}/autoops-backup.timer" "$timer"
chmod 644 "${UNIT_DIR}/autoops-backup.timer"
((FILE_CHANGED)) && UNITS_CHANGED=1
# autoops-deploy.path: verified together with the service it triggers (systemd checks that Unit= exists).
tpl="${UNIT_SRC}/autoops-deploy.path.tpl"
[[ -f $tpl ]] || die "Template ${tpl} does not exist."
dpath="$(sed -e "s|@@APP_DIR@@|${APP_DIR}|g" -e "s|@@DEPLOY_INBOX_DIR@@|${DEPLOY_INBOX_DIR}|g" "$tpl")"
vdir="$(mktemp -d)"
printf '%s\n' "$dpath" >"${vdir}/autoops-deploy.path"
cp "${UNIT_DIR}/autoops-deploy.service" "${vdir}/autoops-deploy.service"
systemd-analyze verify "${vdir}/autoops-deploy.path" >/dev/null 2>&1 \
  || { systemd-analyze verify "${vdir}/autoops-deploy.path" >&2 || true; rm -rf "$vdir"; die "autoops-deploy.path does not pass 'systemd-analyze verify'; not installing."; }
rm -rf "$vdir"
ensure_file "${UNIT_DIR}/autoops-deploy.path" "$dpath"
chmod 644 "${UNIT_DIR}/autoops-deploy.path"
((FILE_CHANGED)) && UNITS_CHANGED=1
if ((UNITS_CHANGED)); then
  systemctl daemon-reload
  log_change "systemd recargado"
fi

# --- AC-4: start at boot (opt-in) -------------------------------------------------------
if [[ $AUTOOPS_ENABLE == 1 ]]; then
  systemctl is-enabled --quiet autoops || { systemctl enable autoops >/dev/null 2>&1; log_change "autoops enabled at boot"; }
fi
if [[ $AUTOOPS_ENABLE == 1 ]]; then
  systemctl is-enabled --quiet autoops-backup.timer || { systemctl enable --now autoops-backup.timer >/dev/null 2>&1; log_change "autoops-backup.timer habilitado"; }
fi
# The deploy inbox watcher is always enabled: it is inert until the runner (or an operator) leaves a request.
systemctl is-enabled --quiet autoops-deploy.path || { systemctl enable --now autoops-deploy.path >/dev/null 2>&1; log_change "autoops-deploy.path habilitado"; }
systemctl is-active --quiet autoops-deploy.path || { systemctl start autoops-deploy.path >/dev/null 2>&1; log_change "autoops-deploy.path iniciado"; }
# autoops-migrate must never be enabled. A unit without [Install] reports "static" and `is-enabled`
# exits 0 for it, so compare the state text instead of the exit code.
if [[ "$(systemctl is-enabled autoops-migrate 2>/dev/null || true)" == enabled ]]; then
  systemctl disable autoops-migrate >/dev/null 2>&1
  log_change "autoops-migrate deshabilitado"
fi

log_info "70_systemd.sh finished. Manual start: sudo systemctl start autoops"
