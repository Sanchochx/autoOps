#!/usr/bin/env bash
# US-CICD-005 (AC-2): post-deploy smoke test over HTTPS, as a client reaches the stack through Traefik. Read-only requests: it
# creates no data. deploy.sh runs it after the health probe; a failure rolls the release back. It can also be run by hand.
#
#   SMOKE_DOMAIN=autoops.local SMOKE_HTTPS_PORT=443 SMOKE_HEALTH_PATH=/api/v1/health SMOKE_PROTECTED_PATH=/api/v1/tickets scripts/ops/smoke_test.sh
#
# Variables (no host, port or path is hardcoded; deploy.sh passes the values it already reads from .env):
#   SMOKE_DOMAIN            the only Host Traefik routes                          (required)
#   SMOKE_HTTPS_PORT        published HTTPS port                                  (required)
#   SMOKE_HEALTH_PATH       public API path that must answer 200 (/api/v1/health) (required)
#   SMOKE_PROTECTED_PATH    API path that must answer 401 without a token         (optional; empty skips that check)
#   SMOKE_HTTP_PORT         published HTTP port, which must redirect to HTTPS     (default 80)
#   SMOKE_CACERT            CA that signed the certificate (TLS_MODE=selfsigned); empty = system trust
#   SMOKE_CONNECT_ADDR      where the domain is reached from here                 (default 127.0.0.1, like curl --resolve)
#   SMOKE_EXPECT_IMAGE      image the api-gateway container must run; empty skips that check
#   SMOKE_APP_DIR           directory with docker-compose.yml (for the image check)
# Checks: the frontend answers 200 with HTML; the API answers 200; the protected API path answers 401 without a token; HSTS is set; HTTP redirects to HTTPS; the gateway runs the
# deployed image. Exit 0 = every check passed, 1 = at least one failed (each failure is printed), 2 = bad usage.
set -uo pipefail

: "${SMOKE_DOMAIN:?SMOKE_DOMAIN is required}"
: "${SMOKE_HTTPS_PORT:?SMOKE_HTTPS_PORT is required}"
: "${SMOKE_HEALTH_PATH:?SMOKE_HEALTH_PATH is required}"
HTTP_PORT="${SMOKE_HTTP_PORT:-80}"
CONNECT_ADDR="${SMOKE_CONNECT_ADDR:-127.0.0.1}"
[[ $SMOKE_DOMAIN =~ ^[A-Za-z0-9.-]+$ && $SMOKE_HTTPS_PORT =~ ^[0-9]{1,5}$ && $HTTP_PORT =~ ^[0-9]{1,5}$ && $SMOKE_HEALTH_PATH == /* && ${SMOKE_PROTECTED_PATH:-/} == /* ]] \
  || { echo "smoke: invalid SMOKE_DOMAIN, port or path" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failed=0

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; failed=1; }

# fetch <scheme> <port> <path> <tag>: leaves the status code in ${WORK}/<tag>.code and the headers in ${WORK}/<tag>.headers.
fetch() {
  local scheme=$1 port=$2 path=$3 tag=$4 args=()
  [[ $scheme == https && -n ${SMOKE_CACERT:-} ]] && args+=(--cacert "$SMOKE_CACERT")
  curl --silent --show-error --max-time 10 --output /dev/null --dump-header "${WORK}/${tag}.headers" \
    --write-out '%{http_code}' --resolve "${SMOKE_DOMAIN}:${port}:${CONNECT_ADDR}" "${args[@]}" \
    "${scheme}://${SMOKE_DOMAIN}:${port}${path}" >"${WORK}/${tag}.code" 2>"${WORK}/${tag}.err" || echo 000 >"${WORK}/${tag}.code"
}
code() { cat "${WORK}/$1.code"; }
header() { LC_ALL=C grep -i -m1 "^$2:" "${WORK}/$1.headers" 2>/dev/null | cut -d: -f2- | tr -d '\r' | sed 's/^ *//'; }

fetch https "$SMOKE_HTTPS_PORT" / front
if [[ $(code front) == 200 ]]; then pass "the frontend answers 200"; else fail "the frontend answers $(code front), expected 200"; fi
if [[ $(header front content-type) == text/html* ]]; then pass "the frontend serves HTML"; else fail "the frontend content type is '$(header front content-type)', expected text/html"; fi
if [[ -n $(header front strict-transport-security) ]]; then pass "HSTS is set"; else fail "the Strict-Transport-Security header is missing"; fi

fetch https "$SMOKE_HTTPS_PORT" "$SMOKE_HEALTH_PATH" api
if [[ $(code api) == 200 ]]; then pass "the API answers 200 on ${SMOKE_HEALTH_PATH}"; else fail "the API answers $(code api) on ${SMOKE_HEALTH_PATH}, expected 200"; fi

if [[ -n ${SMOKE_PROTECTED_PATH:-} ]]; then
  fetch https "$SMOKE_HTTPS_PORT" "$SMOKE_PROTECTED_PATH" protected # no credentials are sent: a 200 means the API is open
  if [[ $(code protected) == 401 ]]; then pass "${SMOKE_PROTECTED_PATH} answers 401 without a token"; else fail "${SMOKE_PROTECTED_PATH} answers $(code protected) without a token, expected 401"; fi
fi

fetch http "$HTTP_PORT" / redirect
if [[ $(code redirect) =~ ^30[1278]$ && $(header redirect location) == https://* ]]; then
  pass "HTTP redirects to HTTPS"
else
  fail "HTTP answers $(code redirect) with Location '$(header redirect location)', expected a redirect to https://"
fi

if [[ -n ${SMOKE_EXPECT_IMAGE:-} ]]; then
  running="$( (cd "${SMOKE_APP_DIR:-.}" && docker compose ps --format '{{.Image}}' api-gateway) 2>/dev/null | head -n1)"
  if [[ $running == "$SMOKE_EXPECT_IMAGE" ]]; then pass "the gateway runs ${SMOKE_EXPECT_IMAGE##*:}"; else fail "the gateway runs '${running}', expected '${SMOKE_EXPECT_IMAGE}'"; fi
fi

exit "$failed"
