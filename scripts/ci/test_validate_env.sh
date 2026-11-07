#!/usr/bin/env bash
# Exercises scripts/ops/validate_env.sh: JWT_SECRET is required and strong in production, the legacy SECRET_KEY may stay
# (or be absent) but not as a placeholder, and no user credentials (AUTH_INITIAL_*) are ever required.
#
#   scripts/ci/test_validate_env.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
GOOD_SECRET=0123456789abcdef0123456789abcdef0123456789abcdef

# run [KEY=value ...]: a production .env with valid values, overridden by the arguments. OUT/RC hold the result.
run() {
  local env_file="${WORK}/.env" kv key
  declare -A vars=(
    [ENVIRONMENT]=production [DB_PASSWORD]=$GOOD_SECRET [JWT_SECRET]=$GOOD_SECRET [DOMAIN]=autoops.example.com
    [PUBLIC_SCHEME]=https [TLS_MODE]=selfsigned [IMAGE_TAG]=abc123
  )
  for kv in "$@"; do vars[${kv%%=*}]=${kv#*=}; done
  : >"$env_file"
  for key in "${!vars[@]}"; do [[ ${vars[$key]} == __unset__ ]] || echo "${key}=${vars[$key]}" >>"$env_file"; done
  OUT="$(env -i PATH="$PATH" APP_DIR="$WORK" "${ROOT}/scripts/ops/validate_env.sh" 2>&1)"; RC=$?
}
check() { # description, command...
  local d=$1; shift
  if "$@"; then PASS=$((PASS + 1)); echo "ok   - $d"; else FAIL=$((FAIL + 1)); echo "FAIL - $d"; printf '       %s\n' "${OUT//$'\n'/$'\n       '}"; fi
}
fails_on() { [[ $RC == 1 ]] && grep -q "$1" <<<"$OUT"; }

run;                                                  check "valid production config passes" test "$RC" = 0
run JWT_SECRET=__unset__;                             check "missing JWT_SECRET fails" fails_on JWT_SECRET
run JWT_SECRET=short;                                 check "short JWT_SECRET fails" fails_on JWT_SECRET
run JWT_SECRET=autoops_jwt_secret_key;                check "placeholder JWT_SECRET fails" fails_on JWT_SECRET
run SECRET_KEY=__unset__;                             check "no SECRET_KEY is fine" test "$RC" = 0
run SECRET_KEY=strong-legacy-value-that-is-not-a-default; check "a non-default legacy SECRET_KEY may stay" test "$RC" = 0
run SECRET_KEY=cambia_esta_clave;                     check "a placeholder legacy SECRET_KEY fails" fails_on SECRET_KEY
run AUTH_INITIAL_USER=__unset__ AUTH_INITIAL_PASSWORD=__unset__; check "AUTH_INITIAL_* are not required" test "$RC" = 0
run ENVIRONMENT=development JWT_SECRET=__unset__;     check "outside production nothing is enforced" test "$RC" = 0

echo "passed=${PASS} failed=${FAIL}"
[[ $FAIL -eq 0 ]]
