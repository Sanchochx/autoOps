#!/usr/bin/env bash
# US-CICD-003 (AC-3): self-hosted GitHub Actions runner as autoops-runner.service. Idempotent.
#
#   sudo RUNNER_REGISTRATION_TOKEN_FILE=<file> ./scripts/provision/75_runner.sh
#
# OPTIONAL step: it does nothing (and succeeds) unless RUNNER_REPO_URL is set in ${APP_DIR}/.env, so a host without
# CD still provisions and verifies cleanly. The runner settings (RUNNER_REPO_URL, RUNNER_LABELS, RUNNER_NAME, limits)
# are read by docker compose and by the unit from that same .env (see .env.example).
# Variables (all optional here):
#   SERVICE_USER=autoops               user that runs the unit (must be in the docker group)
#   APP_DIR=/opt/autoops               deployment directory (infra/runner/ and .env)
#   RUNNER_REGISTRATION_TOKEN_FILE     one-hour registration token (GitHub: Settings > Actions > Runners > New
#                                      self-hosted runner). Required only while the runner is not registered yet; set
#                                      it in the environment, provision.env or ${APP_DIR}/.env. Outside the repository
#                                      and APP_DIR; this script makes it 10001:10001 0600 (the UID of the runner).
#   RUNNER_CONNECT_TIMEOUT=120         seconds to wait for "Listening for Jobs"
# Steps: validate -> build the image -> register once (credentials stay in the runner_home volume) -> install, enable
# and start the unit -> wait until the runner is connected. See infra/runner/README.md.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UNIT_SRC="${REPO_ROOT}/infra/systemd/autoops-runner.service.tpl"
UNIT=/etc/systemd/system/autoops-runner.service
RUNNER_UID=10001
IMAGE=autoops/runner:local
VOLUME_CREDENTIALS_FILE=/home/runner/runner/.runner

require_root
SERVICE_USER="${SERVICE_USER:-autoops}"
APP_DIR="${APP_DIR:-/opt/autoops}"
APP_ENV_FILE="${APP_ENV_FILE:-${APP_DIR}/.env}"
COMPOSE_FILE="${APP_DIR}/infra/runner/docker-compose.yml"
CONNECT_TIMEOUT="${RUNNER_CONNECT_TIMEOUT:-120}"

[[ $APP_DIR == /* && $APP_DIR =~ ^[A-Za-z0-9_./-]+$ ]] || die "APP_DIR inválido: '${APP_DIR}'."
[[ -f $APP_ENV_FILE ]] || die "No existe ${APP_ENV_FILE}."

# The unit reads the settings from the .env only, so that is the single source (a value that exists only in the
# environment of this run would be missing when systemd starts the runner).
RUNNER_REPO_URL="$(env_value "$APP_ENV_FILE" RUNNER_REPO_URL)"
if [[ -z $RUNNER_REPO_URL ]]; then
  log_info "RUNNER_REPO_URL no está definido en ${APP_ENV_FILE}: se omite el runner self-hosted."
  exit 0
fi

# --- Validation: nothing is touched until it passes --------------------------------------
RUNNER_LABELS="$(env_value "$APP_ENV_FILE" RUNNER_LABELS)"
RUNNER_NAME="$(env_value "$APP_ENV_FILE" RUNNER_NAME)"
[[ $RUNNER_REPO_URL =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
  || die "RUNNER_REPO_URL debe tener la forma https://github.com/<owner>/<repo>: '${RUNNER_REPO_URL}'."
[[ -z $RUNNER_LABELS || $RUNNER_LABELS =~ ^[A-Za-z0-9._,-]+$ ]] || die "RUNNER_LABELS inválido: '${RUNNER_LABELS}'."
[[ -z $RUNNER_NAME || $RUNNER_NAME =~ ^[A-Za-z0-9._-]+$ ]] || die "RUNNER_NAME inválido: '${RUNNER_NAME}'."
[[ $CONNECT_TIMEOUT =~ ^[0-9]+$ ]] || die "RUNNER_CONNECT_TIMEOUT inválido: '${CONNECT_TIMEOUT}'."
[[ -d /run/systemd/system ]] || die "systemd no está activo en este sistema."
[[ $SERVICE_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "SERVICE_USER inválido: '${SERVICE_USER}'."
id "$SERVICE_USER" >/dev/null 2>&1 || die "El usuario ${SERVICE_USER} no existe (ejecuta antes 10_users.sh)."
in_group "$SERVICE_USER" docker || die "${SERVICE_USER} no pertenece al grupo docker (ejecuta antes 60_docker.sh)."
[[ -x /usr/bin/docker ]] || die "No existe /usr/bin/docker (ejecuta antes 60_docker.sh)."
[[ -f $COMPOSE_FILE ]] || die "No existe ${COMPOSE_FILE}."
[[ -f $UNIT_SRC ]] || die "No existe la plantilla ${UNIT_SRC}."
# The unit writes its Docker config here (70_systemd.sh creates it too).
install -d -m 700 -o "$SERVICE_USER" -g "$SERVICE_USER" "${APP_DIR}/.docker"

# compose <token-file|""> <args...>: the runner Compose project, configured only from ${APP_ENV_FILE} (exactly what the
# unit sees). The RUNNER_* variables of this process are dropped so they cannot override the .env.
compose() {
  local token_file=$1
  shift
  env -u RUNNER_REPO_URL -u RUNNER_LABELS -u RUNNER_NAME -u RUNNER_VERSION -u RUNNER_SHA256 \
    -u RUNNER_CPUS -u RUNNER_MEMORY_LIMIT -u RUNNER_PIDS_LIMIT -u RUNNER_WORKSPACE_SIZE \
    "RUNNER_REGISTRATION_TOKEN_FILE=${token_file}" \
    docker compose -f "$COMPOSE_FILE" --env-file "$APP_ENV_FILE" "$@"
}

# connected <token-file|"">: the runner printed "Listening for Jobs" (registered and polling GitHub).
connected() { compose "$1" logs --no-color runner 2>&1 | grep -q 'Listening for Jobs'; }
wait_connected() {
  local waited=0
  until connected "$1"; do
    ((waited < CONNECT_TIMEOUT)) || {
      compose "$1" logs --no-color --tail 20 runner >&2 || true
      return 1
    }
    sleep 2
    waited=$((waited + 2))
  done
}

# --- Image: built on the host from the pinned Dockerfile ------------------------------------
image_before="$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
compose "" build --quiet runner >/dev/null
image_after="$(docker image inspect -f '{{.Id}}' "$IMAGE")"
[[ $image_before == "$image_after" ]] || log_change "imagen ${IMAGE} construida (${image_after:7:12})"

# --- Registration: only when the credentials volume has no .runner yet -----------------------
if compose "" run --rm -T --no-deps --entrypoint test runner -f "$VOLUME_CREDENTIALS_FILE" >/dev/null 2>&1; then
  log_info "El runner ya está registrado (credenciales en el volumen); no se necesita token."
else
  TOKEN_FILE="$(env_file_value "$APP_ENV_FILE" RUNNER_REGISTRATION_TOKEN_FILE)"
  [[ -n $TOKEN_FILE ]] \
    || die "El runner no está registrado: define RUNNER_REGISTRATION_TOKEN_FILE (token de 1 h, GitHub > Settings > Actions > Runners > New self-hosted runner)."
  [[ $TOKEN_FILE == /* && -f $TOKEN_FILE ]] || die "RUNNER_REGISTRATION_TOKEN_FILE debe ser la ruta absoluta de un archivo existente: '${TOKEN_FILE}'."
  real="$(realpath "$TOKEN_FILE")"
  [[ $real != "$REPO_ROOT"/* && $real != "$APP_DIR"/* ]] \
    || die "El archivo del token no puede estar dentro del repositorio ni de ${APP_DIR}: '${real}'."
  [[ -n "$(tr -d '[:space:]' <"$real")" ]] || die "El archivo del token está vacío: '${real}'."
  # The container reads it as the runner user (it is mounted as a Compose secret keeping owner and mode).
  ensure_perms "$real" "${RUNNER_UID}:${RUNNER_UID}" 600

  log_info "Registrando el runner (token de ${real})..."
  compose "$real" up -d --no-build >/dev/null
  if ! wait_connected "$real"; then
    compose "$real" down >/dev/null 2>&1 || true
    die "El runner no llegó a conectarse en ${CONNECT_TIMEOUT} s (¿token de más de 1 h?)."
  fi
  # Hand over to systemd: from now on the unit runs it, without the token.
  compose "$real" down >/dev/null
  log_change "runner registrado en ${RUNNER_REPO_URL}"
  log_info "Ya puedes borrar ${real}: el runner conserva sus propias credenciales."
fi

# --- The unit: render, verify, install, enable and start ---------------------------------------
rendered="$(sed -e "s|@@APP_DIR@@|${APP_DIR}|g" -e "s|@@SERVICE_USER@@|${SERVICE_USER}|g" "$UNIT_SRC")"
tmp="$(mktemp --suffix=".service")"
printf '%s\n' "$rendered" >"$tmp"
if ! systemd-analyze verify "$tmp" >/dev/null 2>&1; then
  systemd-analyze verify "$tmp" >&2 || true
  rm -f "$tmp"
  die "autoops-runner.service no pasa 'systemd-analyze verify'; no se instala."
fi
rm -f "$tmp"
ensure_file "$UNIT" "$rendered"
chmod 644 "$UNIT"
UNIT_CHANGED=$FILE_CHANGED
if ((UNIT_CHANGED)); then
  systemctl daemon-reload
  log_change "systemd recargado"
fi

systemctl is-enabled --quiet autoops-runner || { systemctl enable autoops-runner >/dev/null 2>&1; log_change "autoops-runner habilitado al arranque"; }
if ! systemctl is-active --quiet autoops-runner; then
  systemctl start autoops-runner
  log_change "autoops-runner iniciado"
elif ((UNIT_CHANGED)) || [[ -n $image_before && $image_before != "$image_after" ]]; then
  # A new unit or a rebuilt image (upgrade): restart so the running runner is the installed one.
  systemctl restart autoops-runner
  log_change "autoops-runner reiniciado"
fi

wait_connected "" || die "El runner no llegó a conectarse en ${CONNECT_TIMEOUT} s: journalctl -u autoops-runner"
log_info "75_runner.sh finalizado: el runner está escuchando trabajos (etiqueta '${RUNNER_LABELS:-autoops-prod}')."
