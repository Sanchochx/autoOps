#!/usr/bin/env bash
# US-CICD-004 (AC-1): exercises scripts/ops/deploy.sh against a fake `docker` and `curl` (no Docker needed).
#
#   scripts/ci/test_deploy.sh
#
# Each case builds a throw-away APP_DIR, runs deploy.sh and asserts on the exit code, .env, .deploy/ state, outbox/status
# and the calls the fake docker recorded. Exit 0 = every case passed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY="${ROOT}/scripts/ops/deploy.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

GOOD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
BAD=cccccccccccccccccccccccccccccccccccccccc
PASS=0; FAIL=0

# Fake docker: logs "<IMAGE_TAG env> | <args>"; fails per FAKE_* flags. `up` reads the tag from .env like compose does.
mkdir -p "${WORK}/bin"
cat >"${WORK}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
envtag="$(grep -E '^IMAGE_TAG=' "${APP_DIR}/.env" | tail -n1 | cut -d= -f2)"
echo "${IMAGE_TAG:-} | env=${envtag} | $*" >>"${APP_DIR}/docker.log"
case " $* " in
  *" pull "*) [[ -z ${FAKE_FAIL_PULL:-} ]] || exit 1 ;;
  *" run "*) [[ -z ${FAKE_FAIL_MIGRATE:-} ]] || exit 1 ;;
  *" --remove-orphans"*) [[ $envtag != "${FAKE_BAD_UP_TAG:-none}" ]] || exit 1 ;;
esac
exit 0
FAKE
cat >"${WORK}/bin/curl" <<'FAKE'
#!/usr/bin/env bash
envtag="$(grep -E '^IMAGE_TAG=' "${APP_DIR}/.env" | tail -n1 | cut -d= -f2)"
echo "curl env=${envtag} | $*" >>"${APP_DIR}/docker.log"
[[ $envtag != "${FAKE_BAD_HEALTH_TAG:-none}" ]]
FAKE
chmod +x "${WORK}/bin/docker" "${WORK}/bin/curl"

# new_app: fresh APP_DIR with a stub backup script; $1 = IMAGE_TAG already in .env (may be empty), $2 = current file content.
new_app() {
  APP="$(mktemp -d "${WORK}/app.XXXXXX")"
  mkdir -p "${APP}/scripts/ops"
  : >"${APP}/docker-compose.yml"
  printf 'DOMAIN=autoops.local\nPROXY_HTTPS_PORT=8443\nTLS_MODE=selfsigned\nIMAGE_REPOSITORY=ghcr.io/o/autoops\nSECRET_KEY=a b*c\nIMAGE_TAG=%s\n' "${1:-}" >"${APP}/.env"
  chmod 600 "${APP}/.env"
  cat >"${APP}/scripts/ops/backup_postgres.sh" <<'STUB'
#!/usr/bin/env bash
echo backup >>"${APP_DIR}/docker.log"
[[ -z ${FAKE_FAIL_BACKUP:-} ]]
STUB
  chmod +x "${APP}/scripts/ops/backup_postgres.sh"
  if [[ -n ${2:-} ]]; then mkdir -p "${APP}/.deploy"; echo "$2" >"${APP}/.deploy/current"; fi
}

run() { # args to deploy.sh; output in $OUT, exit code in $RC
  OUT="$(PATH="${WORK}/bin:${PATH}" APP_DIR="$APP" DEPLOY_HEALTH_INTERVAL=0 DEPLOY_HEALTH_RETRIES=3 "$DEPLOY" "$@" 2>&1)"; RC=$?
}
status_of() { grep -E "^$1=" "${APP}/.deploy/outbox/status" 2>/dev/null | cut -d= -f2-; }
env_tag() { grep -E '^IMAGE_TAG=' "${APP}/.env" | cut -d= -f2; }

check() { # description, command...
  local d=$1; shift
  if "$@"; then PASS=$((PASS + 1)); echo "ok   - $d"; else FAIL=$((FAIL + 1)); echo "FAIL - $d"; printf '       %s\n' "${OUT//$'\n'/$'\n       '}"; fi
}
eq() { [[ $1 == "$2" ]]; }
logged() { grep -q -- "$1" "${APP}/docker.log" 2>/dev/null; }
not_logged() { ! logged "$1"; }

# 1. success
new_app "$OLD" "$OLD"; run --tag "$GOOD"
check "success: exit 0" eq "$RC" 0
check "success: status succeeded" eq "$(status_of state)" succeeded
check "success: .env names the new tag" eq "$(env_tag)" "$GOOD"
check "success: current/previous recorded" eq "$(cat "${APP}/.deploy/current")/$(cat "${APP}/.deploy/previous")" "$GOOD/$OLD"
check "success: pull and migrate got the tag through the environment only" logged "^${GOOD} | env=${OLD} | compose pull"
check "success: backup ran before migrate" bash -c "grep -n 'backup\|run --rm' '${APP}/docker.log' | head -2 | tail -2 | head -1 | grep -q backup"
check "success: .env keeps mode 0600 and other lines" bash -c "[[ \$(stat -c %a '${APP}/.env') == 600 ]] && grep -q 'SECRET_KEY=a b\*c' '${APP}/.env'"

# 2. pull fails: nothing changes
new_app "$OLD" "$OLD"; FAKE_FAIL_PULL=1 run --tag "$GOOD"
check "pull fails: exit 1, failed/pull_failed" bash -c "[[ $RC == 1 && '$(status_of state)' == failed && '$(status_of reason)' == pull_failed ]]"
check "pull fails: .env and current untouched" bash -c "[[ '$(env_tag)' == $OLD && \$(cat '${APP}/.deploy/current') == $OLD ]]"
check "pull fails: no backup, no migrate, no up" bash -c "! grep -q 'backup\|run --rm\|remove-orphans' '${APP}/docker.log'"

# 3. backup fails: aborts before migrating
new_app "$OLD" "$OLD"; FAKE_FAIL_BACKUP=1 run --tag "$GOOD"
check "backup fails: failed/backup_failed" bash -c "[[ $RC == 1 && '$(status_of reason)' == backup_failed ]]"
check "backup fails: no migrate and .env untouched" bash -c "! grep -q 'run --rm' '${APP}/docker.log' && [[ '$(env_tag)' == $OLD ]]"

# 4. migrate fails: image rollback not needed
new_app "$OLD" "$OLD"; FAKE_FAIL_MIGRATE=1 run --tag "$GOOD"
check "migrate fails: failed/migrate_failed, .env untouched" bash -c "[[ $RC == 1 && '$(status_of reason)' == migrate_failed && '$(env_tag)' == $OLD ]]"

# 5. health gate fails: automatic rollback
new_app "$OLD" "$OLD"; FAKE_BAD_HEALTH_TAG="$BAD" run --tag "$BAD"
check "health fails: exit 1, rolled_back/health_failed" bash -c "[[ $RC == 1 && '$(status_of state)' == rolled_back && '$(status_of reason)' == health_failed && '$(status_of rollback)' == ok ]]"
check "health fails: .env and current back on the previous tag" bash -c "[[ '$(env_tag)' == $OLD && \$(cat '${APP}/.deploy/current') == $OLD ]]"

# 6. up fails: rollback too
new_app "$OLD" "$OLD"; FAKE_BAD_UP_TAG="$BAD" run --tag "$BAD"
check "up fails: rolled_back/apply_failed" bash -c "[[ $RC == 1 && '$(status_of state)' == rolled_back && '$(status_of reason)' == apply_failed && '$(env_tag)' == $OLD ]]"

# 7. first deploy, no previous: a failure cannot roll back
new_app "" ""; FAKE_BAD_HEALTH_TAG="$BAD" run --tag "$BAD"
check "first deploy fails: failed, rollback none" bash -c "[[ $RC == 1 && '$(status_of state)' == failed && '$(status_of rollback)' == none ]]"

# 8. hand-set .env tag is the rollback target on the first managed deploy
new_app "$OLD" ""; FAKE_BAD_HEALTH_TAG="$BAD" run --tag "$BAD"
check "hand-set tag: rolled_back to it" bash -c "[[ '$(status_of state)' == rolled_back && '$(env_tag)' == $OLD ]]"

# 9. request file: valid is consumed and its run_id reported; invalid changes nothing
new_app "$OLD" "$OLD"; printf 'tag=%s\nrun_id=42\n' "$GOOD" >"${APP}/req"; run --request-file "${APP}/req"
check "request: succeeded with run_id, file consumed" bash -c "[[ $RC == 0 && '$(status_of run_id)' == 42 && ! -e '${APP}/req' ]]"
new_app "$OLD" "$OLD"; printf 'tag=%s\nrun_id=7\n' 'xyz;reboot' >"${APP}/req"; run --request-file "${APP}/req"
check "request: invalid -> failed/invalid_request, no docker call" bash -c "[[ $RC == 1 && '$(status_of reason)' == invalid_request && '$(status_of run_id)' == 7 && ! -e '${APP}/docker.log' ]]"

# 10. dry run
new_app "$OLD" "$OLD"; run --tag "$GOOD" --dry-run
check "dry-run: exit 0, nothing written or called" bash -c "[[ $RC == 0 && ! -e '${APP}/docker.log' && '$(env_tag)' == $OLD && ! -e '${APP}/.deploy/outbox' ]]"

# 11. usage and missing IMAGE_REPOSITORY
new_app "$OLD" "$OLD"; run
check "usage: no arguments -> exit 2" eq "$RC" 2
new_app "$OLD" "$OLD"; sed -i '/^IMAGE_REPOSITORY=/d' "${APP}/.env"; run --tag "$GOOD"
check "preflight: IMAGE_REPOSITORY unset -> failed, no docker call" bash -c "[[ $RC == 1 && '$(status_of reason)' == preflight && ! -e '${APP}/docker.log' ]]"

echo "passed=${PASS} failed=${FAIL}"
[[ $FAIL -eq 0 ]]
