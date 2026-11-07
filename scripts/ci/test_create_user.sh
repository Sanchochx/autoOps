#!/usr/bin/env bash
# Exercises scripts/ops/create_user.sh with a fake `docker`: it needs a terminal, passes NO credentials (no argument, no
# environment variable) and delegates the prompt to the gateway container. A terminal is simulated with `script`.
#
#   scripts/ci/test_create_user.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
mkdir -p "${WORK}/bin" "${WORK}/app/scripts/ops"
touch "${WORK}/app/docker-compose.yml" "${WORK}/app/.env"
cat >"${WORK}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
{ echo "docker $*"; env | grep -i -E 'pass|user|AUTH_' || true; } >"${WORK_LOG}"
FAKE
chmod +x "${WORK}/bin/docker"

check() { # description, command...
  local d=$1; shift
  if "$@"; then PASS=$((PASS + 1)); echo "ok   - $d"; else FAIL=$((FAIL + 1)); echo "FAIL - $d"; fi
}

run_plain() { # no terminal: stdin and stdout are pipes
  : >"${WORK}/log"
  echo | env PATH="${WORK}/bin:${PATH}" WORK_LOG="${WORK}/log" APP_DIR="${WORK}/app" "${ROOT}/scripts/ops/create_user.sh" >/dev/null 2>&1
}
run_tty() { # a pseudo-terminal from util-linux `script`
  : >"${WORK}/log"
  script -qec "env PATH=${WORK}/bin:${PATH} WORK_LOG=${WORK}/log APP_DIR=${WORK}/app ${ROOT}/scripts/ops/create_user.sh" /dev/null </dev/null >/dev/null 2>&1
}

run_plain; rc=$?
check "without a terminal: exit 2 and docker is never called" bash -c "[[ $rc == 2 && ! -s '${WORK}/log' ]]"
if command -v script >/dev/null; then
  run_tty
  check "with a terminal: runs the prompt module inside the api-gateway container" grep -qx 'docker compose exec api-gateway python -m apps.api_gateway.create_user' "${WORK}/log"
  check "no credential-looking argument or variable is passed to docker" bash -c "! grep -i -E 'AUTH_INITIAL|--env|-e ' '${WORK}/log'"
fi
check "the script never reads credentials from .env or the environment" bash -c "! grep -E 'AUTH_INITIAL|source .*\.env|\\\$1|\\\$@' '${ROOT}/scripts/ops/create_user.sh'"

echo "passed=${PASS} failed=${FAIL}"
[[ $FAIL -eq 0 ]]
