#!/usr/bin/env bash
# US-CICD-005 (AC-2): exercises scripts/ops/smoke_test.sh against a fake `curl` and `docker` (no stack needed). The healthy
# case must pass and each check must turn the script red when its own condition is broken, and only that check.
#
#   scripts/ci/test_smoke.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE="${ROOT}/scripts/ops/smoke_test.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
EXPECT=ghcr.io/o/autoops/api-gateway:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# Fake curl: answers by URL (http:// = the redirect, "/" = the frontend, anything else = the API) and honours
# --dump-header / --write-out like the real one. FAKE_* flags break one thing at a time. Every call is logged.
mkdir -p "${WORK}/bin"
cat >"${WORK}/bin/curl" <<'FAKE'
#!/usr/bin/env bash
args=("$@"); url="${args[$#-1]}"; hdr=""
for ((i = 0; i < $#; i++)); do [[ ${args[i]} == --dump-header ]] && hdr="${args[i+1]}"; done
echo "curl $*" >>"${WORK_LOG}"
if [[ $url == http://* ]]; then
  code="${FAKE_REDIRECT_CODE:-308}"; headers="Location: https://${url#http://}"
  [[ -z ${FAKE_NO_LOCATION:-} ]] || headers=""
elif [[ $url =~ ^https://[^/]+/$ ]]; then
  code="${FAKE_FRONT_CODE:-200}"; headers="Content-Type: ${FAKE_CONTENT_TYPE:-text/html}"
  [[ -n ${FAKE_NO_HSTS:-} ]] || headers+=$'\r\n'"Strict-Transport-Security: max-age=31536000"
else
  code="${FAKE_API_CODE:-200}"; headers="Content-Type: application/json"
fi
[[ -z ${FAKE_CURL_FAILS:-} ]] || exit 7
[[ -z $hdr ]] || printf 'HTTP/2 %s\r\n%s\r\n\r\n' "$code" "$headers" >"$hdr"
printf '%s' "$code"
FAKE
cat >"${WORK}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "docker $*" >>"${WORK_LOG}"
printf '%s\n' "${FAKE_PS_IMAGE-ghcr.io/o/autoops/api-gateway:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
FAKE
chmod +x "${WORK}/bin/curl" "${WORK}/bin/docker"

run() { # extra env assignments as arguments; output in $OUT, exit code in $RC
  : >"${WORK}/log"
  OUT="$(env PATH="${WORK}/bin:${PATH}" WORK_LOG="${WORK}/log" SMOKE_DOMAIN=autoops.local SMOKE_HTTPS_PORT=8443 SMOKE_HTTP_PORT=8080 \
    SMOKE_HEALTH_PATH=/api/v1/tickets SMOKE_EXPECT_IMAGE="$EXPECT" SMOKE_APP_DIR="$WORK" "$@" "$SMOKE" 2>&1)"; RC=$?
}
check() { # description, command...
  local d=$1; shift
  if "$@"; then PASS=$((PASS + 1)); echo "ok   - $d"; else FAIL=$((FAIL + 1)); echo "FAIL - $d"; printf '       %s\n' "${OUT//$'\n'/$'\n       '}"; fi
}
eq() { [[ $1 == "$2" ]]; }
# only_fails <text>: the script failed and exactly one FAIL line was printed, the one that mentions <text>.
only_fails() { [[ $RC == 1 && $(grep -c '^FAIL' <<<"$OUT") == 1 ]] && grep -q "^FAIL.*$1" <<<"$OUT"; }

run
check "healthy: exit 0, six checks ok" bash -c "[[ $RC == 0 && \$(grep -c '^ok' <<<'$OUT') == 6 ]]"
check "healthy: requests use the configured domain and ports with --resolve (nothing hardcoded)" \
  bash -c "grep -q -- '--resolve autoops.local:8443:127.0.0.1' '${WORK}/log' && grep -q 'https://autoops.local:8443/api/v1/tickets' '${WORK}/log' && grep -q -- '--resolve autoops.local:8080:127.0.0.1' '${WORK}/log'"
check "healthy: the redirect is not followed and nothing but GET is sent" bash -c "! grep -q -- '--location\| -L \|--data\| -X \|--request' '${WORK}/log'"

run FAKE_FRONT_CODE=502;            check "frontend 502 -> only the frontend check fails" only_fails "frontend answers 502"
run FAKE_CONTENT_TYPE=text/plain;   check "frontend not HTML -> only that check fails" only_fails "content type"
run FAKE_NO_HSTS=1;                 check "HSTS missing -> only that check fails" only_fails "Strict-Transport-Security"
run FAKE_API_CODE=404;              check "API 404 -> only the API check fails" only_fails "API answers 404"
run FAKE_REDIRECT_CODE=200;         check "HTTP answered without redirect -> only that check fails" only_fails "HTTP answers 200"
run FAKE_NO_LOCATION=1;             check "redirect without Location -> only that check fails" only_fails "HTTP answers 308"
run FAKE_PS_IMAGE=ghcr.io/o/autoops/api-gateway:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
                                    check "gateway on another tag -> only the image check fails" only_fails "gateway runs"
run FAKE_PS_IMAGE=;                 check "gateway not running -> only the image check fails" only_fails "gateway runs"
run FAKE_CURL_FAILS=1;              check "curl cannot connect -> all five HTTP checks fail (000), exit 1" bash -c "[[ $RC == 1 && \$(grep -c '^FAIL' <<<'$OUT') == 5 ]]"

run SMOKE_EXPECT_IMAGE=
check "no expected image: the image check is skipped and docker is never called" bash -c "[[ $RC == 0 && \$(grep -c '^ok' <<<'$OUT') == 5 ]] && ! grep -q '^docker' '${WORK}/log'"
run SMOKE_CACERT=/tls/ca.crt
check "a CA is passed to curl for HTTPS only" bash -c "grep -c -- '--cacert /tls/ca.crt' '${WORK}/log' | grep -qx 2"
run SMOKE_DOMAIN='bad host;id'
check "invalid domain -> exit 2, no request" bash -c "[[ $RC == 2 ]] && ! grep -q '^curl' '${WORK}/log'"
run SMOKE_HEALTH_PATH=api
check "path without a leading slash -> exit 2" eq "$RC" 2
run SMOKE_HTTPS_PORT=
check "a required variable missing -> exit 1 or 2 with its name" bash -c "[[ $RC != 0 ]] && grep -q SMOKE_HTTPS_PORT <<<'$OUT'"

echo "passed=${PASS} failed=${FAIL}"
[[ $FAIL -eq 0 ]]
