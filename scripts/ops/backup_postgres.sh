#!/usr/bin/env bash
# US-SYS-004 (AC-1, AC-3): PostgreSQL backup in pg_dump custom format with age-based rotation.
#
#   ./scripts/ops/backup_postgres.sh
#
# Variables (read from the environment, falling back to ${APP_DIR}/.env):
#   APP_DIR=<repo root>          directory with docker-compose.yml and .env
#   BACKUP_DIR=/opt/autoops/backups   destination (created if missing, outside postgres_data)
#   BACKUP_OWNER=autoops         owner of the dump when run as root (default: autoops)
#   BACKUP_RETENTION_DAYS=7      dumps older than this many days are deleted (integer >= 1)
# Any failure (dump or rotation) exits 1 so systemd records the unit as 'failed'.
# Credentials never touch the host: pg_dump runs inside the container and uses the
# POSTGRES_USER / POSTGRES_DB variables already injected into it.
set -eo pipefail

APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BACKUP_OWNER="${BACKUP_OWNER:-autoops}"

log() { echo "backup_postgres: $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Reads one KEY from .env without sourcing it (values may contain spaces or '*').
env_value() {
  local line
  line="$(grep -E "^$1=" "${APP_DIR}/.env" 2>/dev/null | tail -n1)" || true
  line="${line#*=}"; line="${line%\"}"; echo "${line#\"}"
}

BACKUP_DIR="${BACKUP_DIR:-$(env_value BACKUP_DIR)}"
[[ -n $BACKUP_DIR && $BACKUP_DIR == /* ]] || die "BACKUP_DIR must be an absolute path (set it in the environment or .env)."
[[ -f ${APP_DIR}/docker-compose.yml ]] || die "${APP_DIR}/docker-compose.yml not found."

BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-$(env_value BACKUP_RETENTION_DAYS)}"
[[ $BACKUP_RETENTION_DAYS =~ ^[1-9][0-9]*$ ]] \
  || die "BACKUP_RETENTION_DAYS must be an integer >= 1 (got '${BACKUP_RETENTION_DAYS}')."

umask 077
mkdir -p "$BACKUP_DIR"
chmod 0700 "$BACKUP_DIR"
[[ $EUID -ne 0 ]] || chown "$BACKUP_OWNER:$BACKUP_OWNER" "$BACKUP_DIR"

final="${BACKUP_DIR}/autoops_db_$(date +%Y%m%d_%H%M%S).dump"
partial="${final}.partial"
trap 'rm -f "$partial"' EXIT

cd "$APP_DIR"
log "dumping to ${final}"
docker compose exec -T postgres \
  sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -F c' > "$partial" \
  || die "pg_dump failed."

[[ -s $partial ]] || die "pg_dump produced an empty file."
chmod 0600 "$partial"
[[ $EUID -ne 0 ]] || chown "$BACKUP_OWNER:$BACKUP_OWNER" "$partial"
mv "$partial" "$final" || die "could not move the dump into place."
log "OK: $(stat -c '%s bytes, mode %a, owner %U' "$final")"

# Rotation: only regular files that exactly match our dump name pattern, directly inside
# BACKUP_DIR, older than BACKUP_RETENTION_DAYS. The dump just created is never a candidate.
log "rotating dumps older than ${BACKUP_RETENTION_DAYS} day(s)"
deleted="$(find "$BACKUP_DIR" -maxdepth 1 -type f \
  -regextype posix-extended -regex '.*/autoops_db_[0-9]{8}_[0-9]{6}\.dump' \
  ! -path "$final" -mtime "+${BACKUP_RETENTION_DAYS}" -print -delete)" \
  || die "rotation failed."
if [[ -n $deleted ]]; then
  log "deleted $(wc -l <<< "$deleted") old dump(s)"
else
  log "no old dumps to delete"
fi

echo "$final"
