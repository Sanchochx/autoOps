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
# systemd up to 255 exposes the watched path as PathExists=<path>; newer releases (259 on Ubuntu 26.04) as Paths=<path> (PathExists).
watches_inbox()   { [[ "$(systemctl show autoops-deploy.path --property=Paths --property=PathExists --value)" == *"${INBOX}/request"* ]]; }
path_enabled()    { systemctl is-enabled --quiet autoops-deploy.path; }
path_active()     { systemctl is-active --quiet autoops-deploy.path; }
service_exec()    { sudo -u "$SERVICE_USER" test -x "${APP_DIR}/scripts/ops/deploy.sh"; }
state_perms()     { [[ "$(stat -c '%U:%G %a' "$STATE_DIR")" == "${SERVICE_USER}:${SERVICE_USER} 700" ]]; }
inbox_perms()     { [[ "$(stat -c '%u:%G %a' "$INBOX")" == "${DEPLOY_INBOX_UID}:${SERVICE_USER} 730" ]]; }
outbox_perms()    { [[ "$(stat -c '%U:%G %a' "$OUTBOX")" == "${SERVICE_USER}:${SERVICE_USER} 755" ]]; }
# Functional: what the runner and the service user can really do in the two directories (no residue is left behind).
# The runner UID has no passwd entry on the host and cannot traverse APP_DIR (750 autoops) from there, but the container mounts
# the inbox (rw) and the outbox (ro) directly. So the runner-side probes run INSIDE the runner container, which is exactly what
# the runner can do in a job; when the runner is not running they are skipped (it is optional).
RUNNER_CID="$(docker ps -q --filter label=com.docker.compose.project=autoops-runner --filter label=com.docker.compose.service=runner 2>/dev/null | head -n1)"
in_runner() { docker exec "$RUNNER_CID" "$@"; }
runner_identity() { [[ "$(in_runner id -u)" == "${DEPLOY_INBOX_UID}" ]]; }
runner_writes_inbox() { in_runner sh -c "umask 022; echo probe > /deploy/inbox/.probe"; }
service_reads_and_removes() { sudo -u "$SERVICE_USER" sh -c "cat '${INBOX}/.probe' >/dev/null && rm -f '${INBOX}/.probe'" && [[ ! -e ${INBOX}/.probe ]]; }
runner_cannot_list_inbox_as_other() { ! sudo -u nobody ls "$INBOX"; }
runner_cannot_write_outbox() { runner_identity && ! in_runner sh -c "echo x > /deploy/outbox/.probe"; }
runner_reads_outbox() { in_runner ls /deploy/outbox; }
runner_cannot_see_state() { runner_identity && ! in_runner test -e "${STATE_DIR}/current" && ! in_runner test -e "$STATE_DIR"; }

check "autoops-deploy.service and .path installed and match the templates" both_match
check "autoops-deploy pasa systemd-analyze verify" verifies
check "autoops-deploy.service: Type=oneshot, corre como ${SERVICE_USER}" bash -c "[[ \$(systemctl show autoops-deploy.service -p Type --value) == oneshot && \$(systemctl show autoops-deploy.service -p User --value) == '${SERVICE_USER}' ]]"
check "autoops-deploy.service has no [Install] section (only the .path starts it)" no_install
check "autoops-deploy.service has no secrets" no_secrets
check "autoops-deploy.service is sandboxed (NoNewPrivileges, ProtectHome, PrivateTmp, ProtectSystem=full)" sandbox_on
check "autoops-deploy.service can only write to APP_DIR, backups, inbox and outbox (ReadWritePaths)" rw_paths
check "${SERVICE_USER} puede ejecutar scripts/ops/deploy.sh" service_exec
check "autoops-deploy.path vigila ${INBOX}/request" watches_inbox
check "autoops-deploy.path habilitada" path_enabled
check "autoops-deploy.path activa" path_active
check "${STATE_DIR} es ${SERVICE_USER}:${SERVICE_USER} 0700" state_perms
check "inbox is UID ${DEPLOY_INBOX_UID}:${SERVICE_USER} 0730 (the runner writes, others cannot list)" inbox_perms
check "outbox is ${SERVICE_USER}:${SERVICE_USER} 0755 (only the service writes)" outbox_perms
check "a third party cannot list the inbox" runner_cannot_list_inbox_as_other
if [[ -n $RUNNER_CID ]]; then
  check "the runner container runs with UID ${DEPLOY_INBOX_UID}" runner_identity
  check "the runner (UID ${DEPLOY_INBOX_UID}) can leave a request in the inbox" runner_writes_inbox
  check "${SERVICE_USER} can read and delete what the runner left" service_reads_and_removes
  check "the runner can read the outbox" runner_reads_outbox
  check "the runner cannot write to the outbox" runner_cannot_write_outbox
  check "the deploy state is not visible from the runner" runner_cannot_see_state
else
  log_info "The runner container is not running: skipping the functional tests from the runner."
fi
rm -f "${INBOX}/.probe" 2>/dev/null || true

check_finish
