#!/usr/bin/env bash
# Verifies the controls of US-CICD-004 AC-3 (read-only apart from a probe file created and removed in the inbox).
# Same variables as 70_systemd.sh; the paths come from ${APP_DIR}/.env like there:
#
#   sudo ./scripts/provision/checks/85_deploy.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SERVICE_USER="${SERVICE_USER:-autoops}"
APP_DIR="${APP_DIR:-/opt/autoops}"
APP_ENV_FILE="${APP_ENV_FILE:-${APP_DIR}/.env}"
DEPLOY_INBOX_UID="${DEPLOY_INBOX_UID:-10001}"
SERVICE=/etc/systemd/system/autoops-deploy.service
PATH_UNIT=/etc/systemd/system/autoops-deploy.path

STATE_DIR="$(env_value "$APP_ENV_FILE" DEPLOY_STATE_DIR)"; STATE_DIR="${STATE_DIR:-${APP_DIR}/.deploy}"
INBOX="$(env_value "$APP_ENV_FILE" DEPLOY_INBOX_DIR)"; INBOX="${INBOX:-${STATE_DIR}/inbox}"
OUTBOX="$(env_value "$APP_ENV_FILE" DEPLOY_OUTBOX_DIR)"; OUTBOX="${OUTBOX:-${STATE_DIR}/outbox}"
BACKUP_DIR="$(env_value "$APP_ENV_FILE" BACKUP_DIR)"

render() {
  sed -e "s|@@APP_DIR@@|${APP_DIR}|g" -e "s|@@SERVICE_USER@@|${SERVICE_USER}|g" -e "s|@@BACKUP_DIR@@|${BACKUP_DIR}|g" \
    -e "s|@@DEPLOY_INBOX_DIR@@|${INBOX}|g" -e "s|@@DEPLOY_OUTBOX_DIR@@|${OUTBOX}|g" "$1"
}
service_matches() { [[ "$(render "${REPO_ROOT}/infra/systemd/autoops-deploy.service.tpl")" == "$(cat "$SERVICE")" ]]; }
path_matches()    { [[ "$(render "${REPO_ROOT}/infra/systemd/autoops-deploy.path.tpl")" == "$(cat "$PATH_UNIT")" ]]; }
both_match()      { service_matches && path_matches; }
verifies()        { [[ -z "$(systemd-analyze verify "$PATH_UNIT" "$SERVICE" 2>&1)" ]]; }
svc_prop()        { [[ "$(systemctl show autoops-deploy.service --property="$1" --value)" == "$2" ]]; }
sandbox_on()      { local d; for d in NoNewPrivileges ProtectHome PrivateTmp; do svc_prop "$d" yes || return 1; done; svc_prop ProtectSystem full; }
no_install()      { ! grep -q '^\[Install\]' "$SERVICE"; }
no_secrets()      { ! grep -Eqi '(password|secret|api_key|token)=' "$SERVICE"; }
rw_paths()        { local p; p="$(systemctl show autoops-deploy.service --property=ReadWritePaths --value)"; [[ $p == *"$INBOX"* && $p == *"$OUTBOX"* ]]; }
watches_inbox()   { [[ "$(systemctl show autoops-deploy.path --property=PathExists --value)" == *"${INBOX}/request"* ]]; }
path_enabled()    { systemctl is-enabled --quiet autoops-deploy.path; }
path_active()     { systemctl is-active --quiet autoops-deploy.path; }
service_exec()    { sudo -u "$SERVICE_USER" test -x "${APP_DIR}/scripts/ops/deploy.sh"; }
state_perms()     { [[ "$(stat -c '%U:%G %a' "$STATE_DIR")" == "${SERVICE_USER}:${SERVICE_USER} 700" ]]; }
inbox_perms()     { [[ "$(stat -c '%u:%G %a' "$INBOX")" == "${DEPLOY_INBOX_UID}:${SERVICE_USER} 730" ]]; }
outbox_perms()    { [[ "$(stat -c '%U:%G %a' "$OUTBOX")" == "${SERVICE_USER}:${SERVICE_USER} 755" ]]; }
# Functional: what the runner and the service user can really do in the two directories (no residue is left behind).
runner_writes_inbox() { sudo -u "#${DEPLOY_INBOX_UID}" sh -c "umask 022; echo probe > '${INBOX}/.probe'"; }
service_reads_and_removes() { sudo -u "$SERVICE_USER" sh -c "cat '${INBOX}/.probe' >/dev/null && rm -f '${INBOX}/.probe'" && [[ ! -e ${INBOX}/.probe ]]; }
runner_cannot_list_inbox_as_other() { ! sudo -u nobody ls "$INBOX"; }
runner_cannot_write_outbox() { ! sudo -u "#${DEPLOY_INBOX_UID}" sh -c "echo x > '${OUTBOX}/.probe'"; }
runner_reads_outbox() { sudo -u "#${DEPLOY_INBOX_UID}" ls "$OUTBOX"; }
runner_cannot_enter_state() { ! sudo -u "#${DEPLOY_INBOX_UID}" ls "$STATE_DIR"; }

check "autoops-deploy.service y .path instaladas y coinciden con las plantillas" both_match
check "autoops-deploy pasa systemd-analyze verify" verifies
check "autoops-deploy.service: Type=oneshot, corre como ${SERVICE_USER}" bash -c "[[ \$(systemctl show autoops-deploy.service -p Type --value) == oneshot && \$(systemctl show autoops-deploy.service -p User --value) == '${SERVICE_USER}' ]]"
check "autoops-deploy.service sin sección [Install] (solo la arranca el .path)" no_install
check "autoops-deploy.service sin secretos" no_secrets
check "autoops-deploy.service con sandboxing (NoNewPrivileges, ProtectHome, PrivateTmp, ProtectSystem=full)" sandbox_on
check "autoops-deploy.service puede escribir solo en APP_DIR, backups, inbox y outbox (ReadWritePaths)" rw_paths
check "${SERVICE_USER} puede ejecutar scripts/ops/deploy.sh" service_exec
check "autoops-deploy.path vigila ${INBOX}/request" watches_inbox
check "autoops-deploy.path habilitada" path_enabled
check "autoops-deploy.path activa" path_active
check "${STATE_DIR} es ${SERVICE_USER}:${SERVICE_USER} 0700" state_perms
check "inbox es UID ${DEPLOY_INBOX_UID}:${SERVICE_USER} 0730 (el runner escribe, el resto no lista)" inbox_perms
check "outbox es ${SERVICE_USER}:${SERVICE_USER} 0755 (solo el servicio escribe)" outbox_perms
check "el runner (UID ${DEPLOY_INBOX_UID}) puede dejar una petición en el inbox" runner_writes_inbox
check "${SERVICE_USER} puede leer y borrar lo que dejó el runner" service_reads_and_removes
check "un tercero no puede listar el inbox" runner_cannot_list_inbox_as_other
check "el runner puede leer el outbox" runner_reads_outbox
check "el runner no puede escribir en el outbox" runner_cannot_write_outbox
check "el runner no puede entrar en el directorio de estado" runner_cannot_enter_state
rm -f "${INBOX}/.probe" 2>/dev/null || true

check_finish
