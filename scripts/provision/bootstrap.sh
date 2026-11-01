#!/usr/bin/env bash
# US-PROV-001 (AC-1): provisions a clean Ubuntu Server 26.04 end to end. Idempotent.
#
#   sudo ADMIN_USER=<user> ADMIN_SSH_PUBKEY_FILE=<path.pub> FAIL2BAN_IGNOREIP="<IP/CIDR ...>" \
#     ./scripts/provision/bootstrap.sh [--env-file <provision.env>] [--confirm-ssh]
#
# Variables can also come from a file (--env-file or PROVISION_ENV_FILE; template: provision.env.example);
# the environment takes precedence over the file.
# Required variables: ADMIN_USER, ADMIN_SSH_PUBKEY_FILE, FAIL2BAN_IGNOREIP.
# Every other variable (SERVICE_USER, APP_DIR, SSH_PORT, ADMIN_CIDR, UFW_WEB_PORTS, ...) is optional
# and documented in the header of the script that uses it; they are passed through unchanged.
# Also required on disk before starting: ${APP_DIR}/docker-compose.yml and ${APP_DIR}/.env (70_systemd.sh).
#
# Execution order (dependencies, not just numeric):
#   10_users -> 20_ssh -> 30_fail2ban -> 40_ufw -> 50_os_baseline -> 60_docker -> 65_tls -> 45_docker_ufw -> 70_systemd -> 75_runner
# 45_docker_ufw runs AFTER 60_docker (it needs Docker installed) although its number is lower.
# 65_tls (US-PROXY-002) reads TLS_MODE and DOMAIN from ${APP_DIR}/.env and must exist before the stack starts.
# SSH keys (20) and the UFW SSH rule (40) are in place before anything that could close off access.
# 75_runner (US-CICD-003) is optional: it does nothing unless RUNNER_REPO_URL is set in ${APP_DIR}/.env.
# The backup units/timer (US-SYS-004) are installed by 70_systemd; their check is checks/80_backup.sh.
#
# 20_ssh.sh arms an automatic SSH rollback. This script lengthens it (SSH_ROLLBACK_MINUTES, default 30)
# so it does not fire while later steps run, and does NOT cancel it by itself: open a second terminal,
# check that your key works and then run `20_ssh.sh --confirm` (or pass --confirm-ssh to do it here).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEPS=(10_users 20_ssh 30_fail2ban 40_ufw 50_os_baseline 60_docker 65_tls 45_docker_ufw 70_systemd 75_runner)
REQUIRED_VARS=(ADMIN_USER ADMIN_SSH_PUBKEY_FILE FAIL2BAN_IGNOREIP)

CONFIRM_SSH=0
ENV_FILE="${PROVISION_ENV_FILE:-}"
while (($#)); do
  case $1 in
    --confirm-ssh) CONFIRM_SSH=1 ;;
    --env-file)
      [[ $# -ge 2 ]] || die "--env-file requires a path."
      ENV_FILE=$2
      shift
      ;;
    -h | --help) sed -n '2,/^set -/{/^set -/!s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "Argumento desconocido '$1' (admitidos: --env-file, --confirm-ssh, --help)." ;;
  esac
  shift
done

# --- Preflight: nothing is touched until everything below passes -------------------------
require_root
[[ -z $ENV_FILE ]] || load_env_file "$ENV_FILE"

os_id="$(. /etc/os-release 2>/dev/null && echo "${ID:-}")"
os_version="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}")"
[[ $os_id == ubuntu && $os_version == 26.04 ]] \
  || die "Unsupported system: '${os_id:-?} ${os_version:-?}'. Ubuntu 26.04 is required."
[[ -d /run/systemd/system ]] || die "systemd is not active on this system."

missing=()
for name in "${REQUIRED_VARS[@]}"; do
  [[ -n "${!name:-}" ]] || missing+=("$name")
done
((${#missing[@]} == 0)) || die "Missing required variables: ${missing[*]}. See the header of ${BASH_SOURCE[0]}."

APP_DIR="${APP_DIR:-/opt/autoops}"
[[ -r $ADMIN_SSH_PUBKEY_FILE ]] || die "ADMIN_SSH_PUBKEY_FILE is not readable: '${ADMIN_SSH_PUBKEY_FILE}'."
[[ -f ${APP_DIR}/docker-compose.yml ]] || die "${APP_DIR}/docker-compose.yml does not exist (deploy the repository into APP_DIR)."
[[ -f ${APP_DIR}/.env ]] || die "${APP_DIR}/.env does not exist (cp .env.example .env and fill it in)."
for step in "${STEPS[@]}"; do
  [[ -f ${HERE}/${step}.sh ]] || die "Missing step script: ${HERE}/${step}.sh."
done

# Values the steps share: exported so every child sees the same configuration.
export APP_DIR
export APP_ENV_FILE="${APP_ENV_FILE:-${APP_DIR}/.env}"
export SSH_ROLLBACK_MINUTES="${SSH_ROLLBACK_MINUTES:-30}"

# --- Run the steps in order; the first failure stops the whole run ----------------------
# Each [CAMBIO] line a step prints is a real modification; the total tells whether a run was a no-op.
RUN_LOG="$(mktemp)"
trap 'rm -f "$RUN_LOG"' EXIT
total=${#STEPS[@]}
index=0
for step in "${STEPS[@]}"; do
  index=$((index + 1))
  log_info "=== [${index}/${total}] ${step} ==="
  # pipefail makes a failing step fail the pipeline even though tee succeeds.
  if ! bash "${HERE}/${step}.sh" 2>&1 | tee -a "$RUN_LOG"; then
    die "Step ${step} failed. Fix the cause and run bootstrap.sh again (the steps are idempotent)."
  fi
done
changes="$(grep -c '^\[CAMBIO\]' "$RUN_LOG" || true)"

if ((CONFIRM_SSH)); then
  bash "${HERE}/20_ssh.sh" --confirm || die "Could not confirm the SSH change."
elif systemctl is-active --quiet autoops-ssh-rollback.timer; then
  log_warn "SSH rollback ARMED. If your key works: sudo ADMIN_USER=${ADMIN_USER} ${HERE}/20_ssh.sh --confirm"
else
  log_info "No SSH rollback pending."
fi

if ((changes == 0)); then
  log_info "No changes: the system was already provisioned (${total} steps)."
else
  log_info "${changes} change(s) applied in ${total} steps."
fi
log_info "bootstrap.sh finished. Next: ${HERE}/verify.sh"
