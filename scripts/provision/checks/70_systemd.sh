#!/usr/bin/env bash
# Verifies the controls of US-SYS-003 (read-only). Same variables as 70_systemd.sh:
#
#   sudo ./scripts/provision/checks/70_systemd.sh
# STACK_REQUIRED=0 skips the runtime checks (active unit and healthy services).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SERVICE_USER="${SERVICE_USER:-autoops}"
APP_DIR="${APP_DIR:-/opt/autoops}"
STACK_REQUIRED="${STACK_REQUIRED:-1}"
UNIT=/etc/systemd/system/autoops.service
MIGRATE=/etc/systemd/system/autoops-migrate.service

render()         { sed -e "s|@@APP_DIR@@|${APP_DIR}|g" -e "s|@@SERVICE_USER@@|${SERVICE_USER}|g" "$1"; }
unit_matches()   { [[ "$(render "${REPO_ROOT}/infra/systemd/$1.service.tpl")" == "$(cat "/etc/systemd/system/$1.service")" ]]; }
unit_prop()      { [[ "$(systemctl show "$1" --property="$2" --value)" == "$3" ]]; }
unit_verifies()  { systemd-analyze verify "$1"; }
env_file_ok()    { [[ "$(stat -c '%U:%G %a' "${APP_DIR}/.env")" == "${SERVICE_USER}:${SERVICE_USER} 600" ]]; }
prestart_guard() { grep -q "^ExecStartPre=${APP_DIR}/scripts/ops/validate_env.sh\$" "$UNIT" && [[ -x ${APP_DIR}/scripts/ops/validate_env.sh ]]; }
# Tested AS the service user: root passes `-x` on any file with an execute bit, which hides
# ownership/mode problems on the path (e.g. a tree copied with umask 0007) that surface as 203/EXEC.
service_can_exec() { sudo -u "$SERVICE_USER" test -x "${APP_DIR}/scripts/ops/validate_env.sh"; }
no_secrets()     { ! grep -Eqi '(password|secret|api_key|token)=' "$UNIT" "$MIGRATE"; }
never_enabled() { [[ "$(systemctl is-enabled autoops-migrate 2>/dev/null)" == "static" ]]; }
no_install()     { ! grep -q '^\[Install\]' "$MIGRATE"; }
migrate_is_manual() { ! grep -q 'migrate' "$UNIT"; }
no_volume_wipe() { ! grep -Eq '^ExecStop=.*(-v|--volumes)' "$UNIT"; }
sandbox_on()     { local d; for d in NoNewPrivileges ProtectHome PrivateTmp; do unit_prop autoops "$d" yes || return 1; done; unit_prop autoops ProtectSystem full; }
enabled()        { systemctl is-enabled --quiet autoops; }
active()         { systemctl is-active --quiet autoops; }
all_healthy() {
  local ids id state
  ids="$(sudo -u "$SERVICE_USER" bash -c "cd '${APP_DIR}' && docker compose ps -q")" || return 1
  [[ -n $ids ]] || return 1
  for id in $ids; do
    state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id")"
    [[ $state == healthy || $state == running ]] || return 1
  done
}
restart_policy() { local id; for id in $(sudo -u "$SERVICE_USER" bash -c "cd '${APP_DIR}' && docker compose ps -q"); do [[ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$id")" == unless-stopped ]] || return 1; done; }
live_restore()   { [[ "$(docker info --format '{{.LiveRestoreEnabled}}')" == true ]]; }

check "autoops.service instalada y coincide con la plantilla" unit_matches autoops
check "autoops-migrate.service instalada y coincide con la plantilla" unit_matches autoops-migrate
check "autoops.service pasa systemd-analyze verify" unit_verifies "$UNIT"
check "autoops-migrate.service pasa systemd-analyze verify" unit_verifies "$MIGRATE"
check "Type=oneshot con RemainAfterExit=yes" bash -c "[[ \$(systemctl show autoops -p Type --value) == oneshot && \$(systemctl show autoops -p RemainAfterExit --value) == yes ]]"
check "corre como ${SERVICE_USER}" unit_prop autoops User "$SERVICE_USER"
check "ExecStop sin -v (los datos persisten)" no_volume_wipe
check "sin secretos en las unidades" no_secrets
check "autoops.service valida secretos por defecto antes de arrancar (ExecStartPre)" prestart_guard
check "${SERVICE_USER} puede ejecutar scripts/ops/validate_env.sh (propiedad y modos del árbol)" service_can_exec
check "${APP_DIR}/.env es ${SERVICE_USER}:${SERVICE_USER} 0600" env_file_ok
check "sandboxing activo (NoNewPrivileges, ProtectHome, PrivateTmp, ProtectSystem=full)" sandbox_on
check "autoops.service no ejecuta migraciones" migrate_is_manual
check "autoops-migrate.service sin sección [Install]" no_install
check "autoops-migrate.service nunca habilitada" never_enabled
check "autoops.service habilitada al arranque" enabled
check "Docker: live-restore habilitado" live_restore
if [[ $STACK_REQUIRED == 1 ]]; then
  check "autoops.service activa" active
  check "todos los servicios del stack en healthy/running" all_healthy
  check "restart policy unless-stopped en todos los contenedores" restart_policy
fi

check_finish
