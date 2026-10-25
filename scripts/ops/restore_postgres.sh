#!/usr/bin/env bash
# US-SYS-004 (AC-4): restores a pg_dump (custom format) into PostgreSQL. DESTRUCTIVE.
#
#   ./scripts/ops/restore_postgres.sh                  # lists the available dumps
#   ./scripts/ops/restore_postgres.sh <file.dump>      # restores it (asks for confirmation)
#
# Variables (read from the environment, falling back to ${APP_DIR}/.env):
#   APP_DIR=<repo root>          directory with docker-compose.yml and .env
#   BACKUP_DIR=/opt/autoops/backups   where the dumps live (used by the listing)
#   RESTORE_DB=<name>            target database; default: POSTGRES_DB of the container.
#                                It must already exist (e.g. a clean one to verify a backup).
# The restore runs in a single transaction with --clean --if-exists: either everything is
# replaced or nothing changes. Credentials never leave the container.
set -eo pipefail

APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CONFIRM_WORD="CONFIRMAR"

log() { echo "restore_postgres: $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Reads one KEY from .env without sourcing it (values may contain spaces or '*').
env_value() {
  local line
  line="$(grep -E "^$1=" "${APP_DIR}/.env" 2>/dev/null | tail -n1)" || true
  line="${line#*=}"; line="${line%\"}"; echo "${line#\"}"
}

BACKUP_DIR="${BACKUP_DIR:-$(env_value BACKUP_DIR)}"
RESTORE_DB="${RESTORE_DB:-}"
[[ -z $RESTORE_DB || $RESTORE_DB =~ ^[A-Za-z0-9_]+$ ]] || die "RESTORE_DB invalid: '${RESTORE_DB}'."

list_dumps() {
  [[ -n $BACKUP_DIR && -d $BACKUP_DIR ]] || die "BACKUP_DIR '${BACKUP_DIR}' does not exist."
  log "available dumps in ${BACKUP_DIR} (newest first):"
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'autoops_db_*.dump' -printf '%T@ %s %f\n' \
    | sort -rn | awk '{ printf "  %s  (%.1f KiB)\n", $3, $2 / 1024 }'
}

if [[ $# -eq 0 ]]; then
  list_dumps
  log "usage: $0 <file.dump>"
  exit 0
fi
[[ $# -eq 1 ]] || die "usage: $0 [file.dump]"

dump="$1"
# A bare file name is looked up in BACKUP_DIR.
[[ -f $dump || $dump == */* || -z $BACKUP_DIR ]] || dump="${BACKUP_DIR}/${dump}"
[[ -f $dump && -r $dump && -s $dump ]] || die "'${dump}' is not a readable, non-empty file."
[[ -f ${APP_DIR}/docker-compose.yml ]] || die "${APP_DIR}/docker-compose.yml not found."
[[ -t 0 ]] || die "interactive confirmation required: run this from a terminal."

cd "$APP_DIR"
# Never restore a file that is not a valid dump.
docker compose exec -T postgres pg_restore --list < "$dump" > /dev/null \
  || die "'${dump}' is not a valid pg_dump custom-format file."

target="$RESTORE_DB"
[[ -n $target ]] || target="$(docker compose exec -T postgres sh -c 'echo "$POSTGRES_DB"' </dev/null)" || true
[[ -n $target ]] || die "could not determine the target database."

log "WARNING: this will OVERWRITE database '${target}' with the contents of:"
log "  ${dump} ($(stat -c '%y' "$dump" | cut -d. -f1))"
log "Current data in '${target}' that is not in the dump will be LOST."
log "Tip: stop the gateway first (docker compose stop api-gateway) to release connections."
read -r -p "Type ${CONFIRM_WORD} to continue: " answer
[[ $answer == "$CONFIRM_WORD" ]] || die "not confirmed; nothing was changed."

log "restoring into '${target}'..."
docker compose exec -T -e "TARGET_DB=${target}" postgres \
  sh -c 'exec pg_restore -U "$POSTGRES_USER" -d "$TARGET_DB" --clean --if-exists --no-owner --single-transaction --exit-on-error' \
  < "$dump" \
  || die "pg_restore failed; the transaction was rolled back and '${target}' is unchanged."
log "OK: '${target}' restored from $(basename "$dump")."
