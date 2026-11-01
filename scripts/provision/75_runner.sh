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
#   RUNNER_CONNECT_TIMEOUT=300         seconds to wait for "Listening for Jobs" (a session left open by an unclean
#                                      shutdown takes ~3 min to expire on GitHub's side)
# The deploy spool (US-CICD-004) is mounted into the runner: DEPLOY_STATE_DIR / DEPLOY_INBOX_DIR / DEPLOY_OUTBOX_DIR are
# read from ${APP_DIR}/.env with the defaults of 70_systemd.sh, which must have created them (it runs before this step).
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
CONNECT_TIMEOUT="${RUNNER_CONNECT_TIMEOUT:-300}"

[[ $APP_DIR == /* && $APP_DIR =~ ^[A-Za-z0-9_./-]+$ ]] || die "Invalid APP_DIR: '${APP_DIR}'."
[[ -f $APP_ENV_FILE ]] || die "${APP_ENV_FILE} does not exist."

# The unit reads the settings from the .env only, so that is the single source (a value that exists only in the
# environment of this run would be missing when systemd starts the runner).
RUNNER_REPO_URL="$(env_value "$APP_ENV_FILE" RUNNER_REPO_URL)"
if [[ -z $RUNNER_REPO_URL ]]; then
  log_info "RUNNER_REPO_URL is not set in ${APP_ENV_FILE}: skipping the self-hosted runner."
  exit 0
fi

# --- Validation: nothing is touched until it passes --------------------------------------
RUNNER_LABELS="$(env_value "$APP_ENV_FILE" RUNNER_LABELS)"
RUNNER_NAME="$(env_value "$APP_ENV_FILE" RUNNER_NAME)"
[[ $RUNNER_REPO_URL =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
  || die "RUNNER_REPO_URL must look like https://github.com/<owner>/<repo>: '${RUNNER_REPO_URL}'."
[[ -z $RUNNER_LABELS || $RUNNER_LABELS =~ ^[A-Za-z0-9._,-]+$ ]] || die "Invalid RUNNER_LABELS: '${RUNNER_LABELS}'."
[[ -z $RUNNER_NAME || $RUNNER_NAME =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid RUNNER_NAME: '${RUNNER_NAME}'."
[[ $CONNECT_TIMEOUT =~ ^[0-9]+$ ]] || die "Invalid RUNNER_CONNECT_TIMEOUT: '${CONNECT_TIMEOUT}'."
[[ -d /run/systemd/system ]] || die "systemd is not active on this system."
[[ $SERVICE_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid SERVICE_USER: '${SERVICE_USER}'."
id "$SERVICE_USER" >/dev/null 2>&1 || die "User ${SERVICE_USER} does not exist (run 10_users.sh first)."
in_group "$SERVICE_USER" docker || die "${SERVICE_USER} is not in the docker group (run 60_docker.sh first)."
[[ -x /usr/bin/docker ]] || die "/usr/bin/docker does not exist (run 60_docker.sh first)."
[[ -f $COMPOSE_FILE ]] || die "${COMPOSE_FILE} does not exist."
[[ -f $UNIT_SRC ]] || die "Template ${UNIT_SRC} does not exist."
# The deploy spool: same settings and defaults as 70_systemd.sh. The directories must exist (70_systemd.sh creates
# them with the right owner and mode); Docker is told never to create them.
DEPLOY_STATE_DIR="$(env_value "$APP_ENV_FILE" DEPLOY_STATE_DIR)"; DEPLOY_STATE_DIR="${DEPLOY_STATE_DIR:-${APP_DIR}/.deploy}"
DEPLOY_INBOX_DIR="$(env_value "$APP_ENV_FILE" DEPLOY_INBOX_DIR)"; DEPLOY_INBOX_DIR="${DEPLOY_INBOX_DIR:-${DEPLOY_STATE_DIR}/inbox}"
DEPLOY_OUTBOX_DIR="$(env_value "$APP_ENV_FILE" DEPLOY_OUTBOX_DIR)"; DEPLOY_OUTBOX_DIR="${DEPLOY_OUTBOX_DIR:-${DEPLOY_STATE_DIR}/outbox}"
for _d in "$DEPLOY_INBOX_DIR" "$DEPLOY_OUTBOX_DIR"; do
  [[ $_d == /* && $_d =~ ^[A-Za-z0-9_./-]+$ ]] || die "Invalid deploy path in ${APP_ENV_FILE}: '${_d}'."
  [[ -d $_d ]] || die "${_d} does not exist: run 70_systemd.sh first (it creates the deploy spool)."
done
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
    "DEPLOY_INBOX_DIR=${DEPLOY_INBOX_DIR}" "DEPLOY_OUTBOX_DIR=${DEPLOY_OUTBOX_DIR}" \
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
  log_info "The runner is already registered (credentials in the volume); no token needed."
else
  TOKEN_FILE="$(env_file_value "$APP_ENV_FILE" RUNNER_REGISTRATION_TOKEN_FILE)"
  [[ -n $TOKEN_FILE ]] \
    || die "The runner is not registered: set RUNNER_REGISTRATION_TOKEN_FILE (1 h token, GitHub > Settings > Actions > Runners > New self-hosted runner)."
  [[ $TOKEN_FILE == /* && -f $TOKEN_FILE ]] || die "RUNNER_REGISTRATION_TOKEN_FILE must be the absolute path of an existing file: '${TOKEN_FILE}'."
  real="$(realpath "$TOKEN_FILE")"
  [[ $real != "$REPO_ROOT"/* && $real != "$APP_DIR"/* ]] \
    || die "The token file cannot be inside the repository or ${APP_DIR}: '${real}'."
  [[ -n "$(tr -d '[:space:]' <"$real")" ]] || die "The token file is empty: '${real}'."
  # The container reads it as the runner user (it is mounted as a Compose secret keeping owner and mode).
  ensure_perms "$real" "${RUNNER_UID}:${RUNNER_UID}" 600

  log_info "Registering the runner (token from ${real})..."
  compose "$real" up -d --no-build >/dev/null
  if ! wait_connected "$real"; then
    compose "$real" down >/dev/null 2>&1 || true
    die "The runner did not connect within ${CONNECT_TIMEOUT} s (token older than 1 h?)."
  fi
  # Hand over to systemd: from now on the unit runs it, without the token.
  compose "$real" down >/dev/null
  log_change "runner registered at ${RUNNER_REPO_URL}"
  log_info "You can now delete ${real}: the runner keeps its own credentials."
fi

# --- The unit: render, verify, install, enable and start ---------------------------------------
rendered="$(sed -e "s|@@APP_DIR@@|${APP_DIR}|g" -e "s|@@SERVICE_USER@@|${SERVICE_USER}|g" \
  -e "s|@@DEPLOY_INBOX_DIR@@|${DEPLOY_INBOX_DIR}|g" -e "s|@@DEPLOY_OUTBOX_DIR@@|${DEPLOY_OUTBOX_DIR}|g" "$UNIT_SRC")"
tmp="$(mktemp --suffix=".service")"
printf '%s\n' "$rendered" >"$tmp"
if ! systemd-analyze verify "$tmp" >/dev/null 2>&1; then
  systemd-analyze verify "$tmp" >&2 || true
  rm -f "$tmp"
  die "autoops-runner.service does not pass 'systemd-analyze verify'; not installing."
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

wait_connected "" || die "The runner did not connect within ${CONNECT_TIMEOUT} s: journalctl -u autoops-runner"
log_info "75_runner.sh finished: the runner is listening for jobs (label '${RUNNER_LABELS:-autoops-prod}')."
