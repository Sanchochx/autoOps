#!/usr/bin/env bash
# Verifies the controls of US-CICD-003 AC-3 (read-only). Same variables as 75_runner.sh:
#
#   sudo ./scripts/provision/checks/75_runner.sh
# Skipped (not failed) when RUNNER_REPO_URL is not set in ${APP_DIR}/.env: the runner is an optional step.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SERVICE_USER="${SERVICE_USER:-autoops}"
APP_DIR="${APP_DIR:-/opt/autoops}"
APP_ENV_FILE="${APP_ENV_FILE:-${APP_DIR}/.env}"
UNIT=/etc/systemd/system/autoops-runner.service
NETWORK=autoops-runner_runner_net
SECRET_MOUNT=/run/secrets/runner_token
# Deploy spool (US-CICD-004): same settings and defaults as 70_systemd.sh / 75_runner.sh.
DEPLOY_STATE_DIR="$(env_value "$APP_ENV_FILE" DEPLOY_STATE_DIR)"; DEPLOY_STATE_DIR="${DEPLOY_STATE_DIR:-${APP_DIR}/.deploy}"
DEPLOY_INBOX_DIR="$(env_value "$APP_ENV_FILE" DEPLOY_INBOX_DIR)"; DEPLOY_INBOX_DIR="${DEPLOY_INBOX_DIR:-${DEPLOY_STATE_DIR}/inbox}"
DEPLOY_OUTBOX_DIR="$(env_value "$APP_ENV_FILE" DEPLOY_OUTBOX_DIR)"; DEPLOY_OUTBOX_DIR="${DEPLOY_OUTBOX_DIR:-${DEPLOY_STATE_DIR}/outbox}"

if [[ -z "$(env_value "$APP_ENV_FILE" RUNNER_REPO_URL)" ]]; then
  log_info "RUNNER_REPO_URL is not set in ${APP_ENV_FILE}: skipping the runner checks."
  exit 0
fi

CID="$(docker ps -q --filter label=com.docker.compose.project=autoops-runner --filter label=com.docker.compose.service=runner | head -n1)"
inspect()          { docker inspect -f "$1" "$CID"; }
render()           { sed -e "s|@@APP_DIR@@|${APP_DIR}|g" -e "s|@@SERVICE_USER@@|${SERVICE_USER}|g" \
                      -e "s|@@DEPLOY_INBOX_DIR@@|${DEPLOY_INBOX_DIR}|g" -e "s|@@DEPLOY_OUTBOX_DIR@@|${DEPLOY_OUTBOX_DIR}|g" "$1"; }
unit_matches()     { [[ "$(render "${REPO_ROOT}/infra/systemd/autoops-runner.service.tpl")" == "$(cat "$UNIT")" ]]; }
unit_prop()        { [[ "$(systemctl show autoops-runner --property="$1" --value)" == "$2" ]]; }
sandbox_on()       { local d; for d in NoNewPrivileges ProtectHome PrivateTmp; do unit_prop "$d" yes || return 1; done; unit_prop ProtectSystem full; }
# The unit carries no secret: the registration token file is blanked (Environment=, empty) so the service never needs it.
no_secrets()       { ! grep -Eqi '(password|secret|api_key)=|token=[^[:space:]]' "$UNIT" && grep -q '^Environment=RUNNER_REGISTRATION_TOKEN_FILE=$' "$UNIT"; }
enabled()          { systemctl is-enabled --quiet autoops-runner; }
active()           { systemctl is-active --quiet autoops-runner; }
running()          { [[ -n $CID && "$(inspect '{{.State.Status}}')" == running ]]; }
not_privileged()   { [[ "$(inspect '{{.HostConfig.Privileged}}')" == false ]]; }
cap_drop_all()     { [[ "$(inspect '{{.HostConfig.CapDrop}}')" == '[ALL]' && "$(inspect '{{.HostConfig.CapAdd}}')" == '[]' ]]; }
no_new_privs()     { inspect '{{.HostConfig.SecurityOpt}}' | grep -q 'no-new-privileges'; }
read_only_root()   { [[ "$(inspect '{{.HostConfig.ReadonlyRootfs}}')" == true ]]; }
non_root_user()    { local u; u="$(inspect '{{.Config.User}}')"; [[ -n $u && $u != root && $u != 0 && $u != 0:* ]]; }
no_ports()         { [[ "$(inspect '{{.HostConfig.PortBindings}}')" == 'map[]' ]]; }
no_docker_sock()   { ! inspect '{{json .Mounts}}{{json .HostConfig.Binds}}' | grep -q 'docker\.sock'; }
# Mounts: named volumes and tmpfs, the token Compose secret (a bind of one file) and EXACTLY two host binds: the deploy
# inbox (read-write) and outbox (read-only), with these sources and targets. Nothing else from the host.
mounts()           { inspect '{{range .Mounts}}{{.Type}} {{.Destination}} {{.RW}} {{.Source}}{{"\n"}}{{end}}'; }
bind_mounts()      { mounts | awk '$1 == "bind" && $2 != "'"$SECRET_MOUNT"'"' | sort; }
only_spool_mounts() { [[ "$(bind_mounts)" == "$(printf 'bind /deploy/inbox true %s\nbind /deploy/outbox false %s' "$DEPLOY_INBOX_DIR" "$DEPLOY_OUTBOX_DIR")" ]]; }
only_runner_net()  { [[ "$(inspect '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}')" == "${NETWORK} " ]]; }
connected()        { docker logs "$CID" 2>&1 | grep -q 'Listening for Jobs'; }
# The registration token is a one-time secret: not in the repository nor APP_DIR, not accessible to group/others.
# An unset or already deleted file is fine (the runner keeps its own credentials).
token_file_safe() {
  local f real
  f="$(env_file_value "$APP_ENV_FILE" RUNNER_REGISTRATION_TOKEN_FILE)"
  [[ -z $f || ! -e $f ]] && return 0
  real="$(realpath "$f")"
  [[ $real != "$REPO_ROOT"/* && $real != "$APP_DIR"/* ]] || return 1
  (( (8#$(stat -c '%a' "$real") & 8#077) == 0 ))
}

check "autoops-runner.service installed and matches the template" unit_matches
check "autoops-runner.service pasa systemd-analyze verify" systemd-analyze verify "$UNIT"
check "runs as ${SERVICE_USER} with Restart=always" bash -c "[[ \$(systemctl show autoops-runner -p User --value) == '${SERVICE_USER}' && \$(systemctl show autoops-runner -p Restart --value) == always ]]"
check "sandboxing activo (NoNewPrivileges, ProtectHome, PrivateTmp, ProtectSystem=full)" sandbox_on
check "no secrets in the unit and no token file (empty Environment)" no_secrets
check "autoops-runner.service enabled at boot" enabled
check "autoops-runner.service activa" active
check "runner container running" running
if [[ -n $CID ]]; then
  check "container is not privileged" not_privileged
  check "container has cap_drop ALL and no cap_add" cap_drop_all
  check "container has no-new-privileges" no_new_privs
  check "container has a read-only root filesystem" read_only_root
  check "container runs as a non-root user" non_root_user
  check "container has no published ports" no_ports
  check "container has no docker.sock" no_docker_sock
  check "container has only two host mounts: deploy inbox (rw) and outbox (ro)" only_spool_mounts
  check "container connected only to ${NETWORK}" only_runner_net
  check "runner conectado a GitHub (Listening for Jobs)" connected
fi
check "token file outside the repository and inaccessible to others (or already deleted)" token_file_safe

check_finish
