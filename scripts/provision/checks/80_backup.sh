#!/usr/bin/env bash
# Verifies the controls of US-SYS-004 (read-only). Same variables as 70_systemd.sh:
#
#   sudo ./scripts/provision/checks/80_backup.sh
# BACKUP_DIR is read from ${APP_DIR}/.env (or the environment, which takes precedence).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SERVICE_USER="${SERVICE_USER:-autoops}"
APP_DIR="${APP_DIR:-/opt/autoops}"
SERVICE=/etc/systemd/system/autoops-backup.service
TIMER=/etc/systemd/system/autoops-backup.timer

# Reads one KEY from .env without sourcing it (values may contain spaces or '*').
env_value() {
  local line
  line="$(grep -E "^$1=" "${APP_DIR}/.env" 2>/dev/null | tail -n1)" || true
  line="${line#*=}"; line="${line%\"}"; echo "${line#\"}"
}
BACKUP_DIR="${BACKUP_DIR:-$(env_value BACKUP_DIR)}"
RETENTION="${BACKUP_RETENTION_DAYS:-$(env_value BACKUP_RETENTION_DAYS)}"

dir_set()        { [[ -n $BACKUP_DIR && $BACKUP_DIR == /* ]]; }
dir_exists()     { [[ -d $BACKUP_DIR ]]; }
dir_perms()      { [[ "$(stat -c '%U:%G %a' "$BACKUP_DIR")" == "${SERVICE_USER}:${SERVICE_USER} 700" ]]; }
outside_volume() { [[ "$(readlink -f "$BACKUP_DIR")" != /var/lib/docker/* ]]; }
dumps_private()  { ! find "$BACKUP_DIR" -maxdepth 1 -type f -name 'autoops_db_*.dump' ! -perm 0600 | grep -q .; }
retention_ok()   { [[ $RETENTION =~ ^[1-9][0-9]*$ ]]; }
scripts_exec()   { [[ -x ${APP_DIR}/scripts/ops/backup_postgres.sh && -x ${APP_DIR}/scripts/ops/restore_postgres.sh ]]; }
installed()      { [[ -f $SERVICE && -f $TIMER ]]; }
unit_verifies()  { systemd-analyze verify "$SERVICE" "$TIMER"; }
persistent()     { grep -q '^Persistent=true$' "$TIMER"; }
enabled()        { systemctl is-enabled --quiet autoops-backup.timer; }
active()         { systemctl is-active --quiet autoops-backup.timer; }
scheduled()      { [[ -n "$(systemctl show autoops-backup.timer --property=NextElapseUSecRealtime --value)" ]]; }
not_failed()     { [[ "$(systemctl show autoops-backup.service --property=ActiveState --value)" != failed ]]; }

check "BACKUP_DIR definida (ruta absoluta) en .env o entorno" dir_set
if dir_set; then
  check "BACKUP_DIR existe" dir_exists
  if dir_exists; then
    check "BACKUP_DIR es ${SERVICE_USER}:${SERVICE_USER} 0700" dir_perms
    check "BACKUP_DIR fuera de /var/lib/docker (no en postgres_data)" outside_volume
    check "dumps existentes con modo 0600" dumps_private
  fi
fi
check "BACKUP_RETENTION_DAYS es un entero >= 1" retention_ok
check "backup_postgres.sh y restore_postgres.sh ejecutables" scripts_exec
check "autoops-backup.service y .timer instalados" installed
if installed; then
  check "unidades pasan systemd-analyze verify" unit_verifies
  check "timer con Persistent=true" persistent
fi
check "autoops-backup.timer habilitado" enabled
check "autoops-backup.timer activo" active
check "autoops-backup.timer con próxima ejecución programada" scheduled
check "última ejecución de autoops-backup.service no está en failed" not_failed

check_finish
