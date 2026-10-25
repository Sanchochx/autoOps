#!/usr/bin/env bash
# US-SYS-003: autoops.service and autoops-migrate.service. Idempotent.
#
#   sudo ./scripts/provision/70_systemd.sh
#
# Variables (all optional):
#   SERVICE_USER=autoops     user that runs the units (must be in the docker group)
#   APP_DIR=/opt/autoops     deployment directory (docker-compose.yml and .env)
#   AUTOOPS_ENABLE=0         1 = also `systemctl enable autoops` (start at boot, AC-4)
# Backup timer (US-SYS-004): BACKUP_DIR / BACKUP_SCHEDULE are read from ${APP_DIR}/.env.
# Installs the units but does NOT start them: start is a manual verification step.
# See infra/systemd/README.md.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UNIT_SRC="${REPO_ROOT}/infra/systemd"
UNIT_DIR=/etc/systemd/system
UNITS=(autoops autoops-migrate autoops-backup)

require_root
SERVICE_USER="${SERVICE_USER:-autoops}"
APP_DIR="${APP_DIR:-/opt/autoops}"
AUTOOPS_ENABLE="${AUTOOPS_ENABLE:-0}"

[[ -d /run/systemd/system ]] || die "systemd no está activo en este sistema."
[[ $APP_DIR == /* && $APP_DIR =~ ^[A-Za-z0-9_./-]+$ ]] || die "APP_DIR inválido: '${APP_DIR}'."
[[ $SERVICE_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "SERVICE_USER inválido: '${SERVICE_USER}'."
id "$SERVICE_USER" >/dev/null 2>&1 || die "El usuario ${SERVICE_USER} no existe (ejecuta antes 10_users.sh)."
in_group "$SERVICE_USER" docker || die "${SERVICE_USER} no pertenece al grupo docker (ejecuta antes 60_docker.sh)."
[[ -x /usr/bin/docker ]] || die "No existe /usr/bin/docker (ejecuta antes 60_docker.sh)."
[[ -f ${APP_DIR}/docker-compose.yml ]] || die "No existe ${APP_DIR}/docker-compose.yml."
[[ -f ${APP_DIR}/.env ]] || die "No existe ${APP_DIR}/.env (cp .env.example .env y complétalo)."

# --- AC-2: the .env holds the secrets: only the service user can read it -----------------
ensure_perms "${APP_DIR}/.env" "${SERVICE_USER}:${SERVICE_USER}" 600
# DOCKER_CONFIG directory used by the units (the CLI cannot use ~ under ProtectHome).
install -d -m 700 -o "$SERVICE_USER" -g "$SERVICE_USER" "${APP_DIR}/.docker"

# --- US-SYS-004 AC-2: backup settings from .env (systemd cannot read them itself) ---------
env_value() { local l; l="$(grep -E "^$1=" "${APP_DIR}/.env" | tail -n1)" || true; l="${l#*=}"; l="${l%\"}"; echo "${l#\"}"; }
BACKUP_DIR="$(env_value BACKUP_DIR)"
BACKUP_SCHEDULE="$(env_value BACKUP_SCHEDULE)"
[[ $BACKUP_DIR == /* && $BACKUP_DIR =~ ^[A-Za-z0-9_./-]+$ ]] || die "BACKUP_DIR inválido o ausente en .env: '${BACKUP_DIR}'."
[[ -n $BACKUP_SCHEDULE && $BACKUP_SCHEDULE =~ ^[A-Za-z0-9*:/,.~\ -]+$ ]] || die "BACKUP_SCHEDULE inválido o ausente en .env: '${BACKUP_SCHEDULE}'."
systemd-analyze calendar "$BACKUP_SCHEDULE" >/dev/null 2>&1 || die "BACKUP_SCHEDULE no es una expresión OnCalendar válida: '${BACKUP_SCHEDULE}'."
# ReadWritePaths= requires the directory to exist when the unit starts.
install -d -m 700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$BACKUP_DIR"

# --- AC-1 / AC-3: render, verify and install the units ----------------------------------
UNITS_CHANGED=0
for unit in "${UNITS[@]}"; do
  tpl="${UNIT_SRC}/${unit}.service.tpl"
  [[ -f $tpl ]] || die "No existe la plantilla ${tpl}."
  rendered="$(sed -e "s|@@APP_DIR@@|${APP_DIR}|g" -e "s|@@SERVICE_USER@@|${SERVICE_USER}|g" -e "s|@@BACKUP_DIR@@|${BACKUP_DIR}|g" "$tpl")"
  tmp="$(mktemp --suffix=".service")"
  printf '%s\n' "$rendered" >"$tmp"
  if ! systemd-analyze verify "$tmp" >/dev/null 2>&1; then
    systemd-analyze verify "$tmp" >&2 || true
    rm -f "$tmp"
    die "${unit}.service no pasa 'systemd-analyze verify'; no se instala."
  fi
  rm -f "$tmp"
  ensure_file "${UNIT_DIR}/${unit}.service" "$rendered"
  chmod 644 "${UNIT_DIR}/${unit}.service"
  ((FILE_CHANGED)) && UNITS_CHANGED=1
done
# autoops-backup.timer: only verified together with its service (same temp dir).
tpl="${UNIT_SRC}/autoops-backup.timer.tpl"
[[ -f $tpl ]] || die "No existe la plantilla ${tpl}."
timer="$(sed -e "s|@@APP_DIR@@|${APP_DIR}|g" -e "s|@@BACKUP_SCHEDULE@@|${BACKUP_SCHEDULE}|g" "$tpl")"
ensure_file "${UNIT_DIR}/autoops-backup.timer" "$timer"
chmod 644 "${UNIT_DIR}/autoops-backup.timer"
((FILE_CHANGED)) && UNITS_CHANGED=1
if ((UNITS_CHANGED)); then
  systemctl daemon-reload
  log_change "systemd recargado"
fi

# --- AC-4: start at boot (opt-in) -------------------------------------------------------
if [[ $AUTOOPS_ENABLE == 1 ]]; then
  systemctl is-enabled --quiet autoops || { systemctl enable autoops >/dev/null 2>&1; log_change "autoops habilitado al arranque"; }
fi
if [[ $AUTOOPS_ENABLE == 1 ]]; then
  systemctl is-enabled --quiet autoops-backup.timer || { systemctl enable --now autoops-backup.timer >/dev/null 2>&1; log_change "autoops-backup.timer habilitado"; }
fi
# autoops-migrate must never be enabled. A unit without [Install] reports "static" and `is-enabled`
# exits 0 for it, so compare the state text instead of the exit code.
if [[ "$(systemctl is-enabled autoops-migrate 2>/dev/null || true)" == enabled ]]; then
  systemctl disable autoops-migrate >/dev/null 2>&1
  log_change "autoops-migrate deshabilitado"
fi

log_info "70_systemd.sh finalizado. Arranque manual: sudo systemctl start autoops"
