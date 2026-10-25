#!/usr/bin/env bash
# Verifies the controls of US-HOST-001 (read-only). Same variables as 10_users.sh:
#
#   sudo ADMIN_USER=<user> ./scripts/provision/checks/10_users.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_root
require_var ADMIN_USER
SERVICE_USER="${SERVICE_USER:-autoops}"
SERVICE_UID="${SERVICE_UID:-1500}"
SERVICE_GID="${SERVICE_GID:-1500}"
APP_DIR="${APP_DIR:-/opt/autoops}"
PWQUALITY_MINLEN="${PWQUALITY_MINLEN:-14}"

root_locked()        { [[ "$(passwd_status root)" == L ]]; }
admin_has_password() { [[ "$(passwd_status "$ADMIN_USER")" == P ]]; }
admin_in_sudo()      { in_group "$ADMIN_USER" sudo; }
admin_not_docker()   { ! getent group docker >/dev/null || ! in_group "$ADMIN_USER" docker; }
admin_sudo_asks_pw() { ! sudo -l -U "$ADMIN_USER" | grep -q 'NOPASSWD'; }
svc_ids()            { [[ "$(id -u "$SERVICE_USER"):$(id -g "$SERVICE_USER")" == "${SERVICE_UID}:${SERVICE_GID}" ]]; }
svc_shell()          { [[ "$(getent passwd "$SERVICE_USER" | cut -d: -f7)" == /usr/sbin/nologin ]]; }
svc_home()           { [[ "$(getent passwd "$SERVICE_USER" | cut -d: -f6)" == "$APP_DIR" ]]; }
svc_locked()         { [[ "$(passwd_status "$SERVICE_USER")" == L ]]; }
# Own group plus `docker` only: 60_docker.sh adds it on purpose and 70_systemd.sh requires it.
svc_no_extra_groups() {
  local group
  for group in $(id -nG "$SERVICE_USER"); do
    [[ $group == "$SERVICE_USER" || $group == docker ]] || return 1
  done
}
app_dir_perms()      { [[ "$(stat -c '%U:%G %a' "$APP_DIR")" == "${SERVICE_USER}:${SERVICE_USER} 750" ]]; }
env_perms()          { [[ ! -f $APP_DIR/.env ]] || [[ "$(stat -c '%U:%G %a' "$APP_DIR/.env")" == "${SERVICE_USER}:${SERVICE_USER} 600" ]]; }
others_blocked()     { ! runuser -u nobody -- ls "$APP_DIR"; }
umask_027()          { grep -Eq '^UMASK[[:space:]]+027$' /etc/login.defs; }
pwquality_minlen()   { grep -Eq "^minlen = ${PWQUALITY_MINLEN}$" /etc/security/pwquality.conf.d/10-autoops.conf; }

check "root tiene la contraseña bloqueada" root_locked
check "${ADMIN_USER} tiene contraseña usable" admin_has_password
check "${ADMIN_USER} pertenece al grupo sudo" admin_in_sudo
check "sudo de ${ADMIN_USER} exige contraseña (sin NOPASSWD)" admin_sudo_asks_pw
check "${ADMIN_USER} no pertenece al grupo docker" admin_not_docker
check "${SERVICE_USER} tiene UID:GID ${SERVICE_UID}:${SERVICE_GID}" svc_ids
check "${SERVICE_USER} usa /usr/sbin/nologin" svc_shell
check "${SERVICE_USER} tiene home en ${APP_DIR}" svc_home
check "${SERVICE_USER} tiene la contraseña bloqueada" svc_locked
check "${SERVICE_USER} no pertenece a otros grupos (salvo docker)" svc_no_extra_groups
check "${APP_DIR} es ${SERVICE_USER}:${SERVICE_USER} 750" app_dir_perms
check "${APP_DIR}/.env (si existe) es ${SERVICE_USER}:${SERVICE_USER} 600" env_perms
check "un usuario sin privilegios no lee ${APP_DIR}" others_blocked
check "UMASK 027 en /etc/login.defs" umask_027
check "pwquality exige minlen ${PWQUALITY_MINLEN}" pwquality_minlen

check_finish
