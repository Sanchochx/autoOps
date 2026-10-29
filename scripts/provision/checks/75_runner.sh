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

if [[ -z "$(env_value "$APP_ENV_FILE" RUNNER_REPO_URL)" ]]; then
  log_info "RUNNER_REPO_URL no está definido en ${APP_ENV_FILE}: se omiten los controles del runner."
  exit 0
fi

CID="$(docker ps -q --filter label=com.docker.compose.project=autoops-runner --filter label=com.docker.compose.service=runner | head -n1)"
inspect()          { docker inspect -f "$1" "$CID"; }
render()           { sed -e "s|@@APP_DIR@@|${APP_DIR}|g" -e "s|@@SERVICE_USER@@|${SERVICE_USER}|g" "$1"; }
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
# Mounts: named volumes and tmpfs, plus the token Compose secret (a bind of one file); nothing else from the host.
no_host_mounts()   { [[ -z "$(inspect '{{range .Mounts}}{{if eq .Type "bind"}}{{.Destination}}{{"\n"}}{{end}}{{end}}' | grep -vx "$SECRET_MOUNT")" ]]; }
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

check "autoops-runner.service instalada y coincide con la plantilla" unit_matches
check "autoops-runner.service pasa systemd-analyze verify" systemd-analyze verify "$UNIT"
check "corre como ${SERVICE_USER} con Restart=always" bash -c "[[ \$(systemctl show autoops-runner -p User --value) == '${SERVICE_USER}' && \$(systemctl show autoops-runner -p Restart --value) == always ]]"
check "sandboxing activo (NoNewPrivileges, ProtectHome, PrivateTmp, ProtectSystem=full)" sandbox_on
check "sin secretos en la unidad y sin archivo de token (Environment vacío)" no_secrets
check "autoops-runner.service habilitada al arranque" enabled
check "autoops-runner.service activa" active
check "contenedor del runner en ejecución" running
if [[ -n $CID ]]; then
  check "contenedor no privilegiado" not_privileged
  check "contenedor con cap_drop ALL y sin cap_add" cap_drop_all
  check "contenedor con no-new-privileges" no_new_privs
  check "contenedor con sistema de archivos raíz de solo lectura" read_only_root
  check "contenedor corre con un usuario no root" non_root_user
  check "contenedor sin puertos publicados" no_ports
  check "contenedor sin docker.sock" no_docker_sock
  check "contenedor sin montajes del host (solo volumen, tmpfs y el secret del token)" no_host_mounts
  check "contenedor conectado solo a ${NETWORK}" only_runner_net
  check "runner conectado a GitHub (Listening for Jobs)" connected
fi
check "archivo del token fuera del repositorio y sin acceso para otros (o ya borrado)" token_file_safe

check_finish
