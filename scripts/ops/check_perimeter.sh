#!/usr/bin/env bash
# External perimeter check (US-PROXY-003 AC-5). Run it from ANOTHER machine, never from the VM itself:
#
#   DOMAIN=autoops.local ./scripts/ops/check_perimeter.sh <vm-ip> [--ca <ca.crt>]
#
# Variables (all optional):
#   DOMAIN              Host header / SNI the proxy answers for (default: autoops.local)
#   PROXY_HTTP_PORT     port that must redirect to HTTPS (default 80)
#   PROXY_HTTPS_PORT    port that must serve the dashboard (default 443)
#   CLOSED_PORTS        TCP ports that must NOT accept connections
#                       (default: gateway 8000, old frontend 3000, PostgreSQL 5432, MCP logs 5001, Docker API 2375 2376)
#   CONNECT_TIMEOUT     seconds before a port counts as filtered (default 3)
# Exit 0 = perimeter as designed, 1 = any control failed. Needs bash, curl and coreutils `timeout`.
set -euo pipefail

usage() { sed -n '2,/^set -/{/^set -/!s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; }

HOST=''
CA=''
while (($#)); do
  case $1 in
    --ca) [[ $# -ge 2 ]] || { echo "--ca requiere una ruta." >&2; exit 1; }; CA=$2; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) echo "Argumento desconocido '$1'." >&2; exit 1 ;;
    *) HOST=$1 ;;
  esac
  shift
done
[[ -n $HOST ]] || { usage >&2; exit 1; }

DOMAIN="${DOMAIN:-autoops.local}"
HTTP_PORT="${PROXY_HTTP_PORT:-80}"
HTTPS_PORT="${PROXY_HTTPS_PORT:-443}"
CLOSED_PORTS="${CLOSED_PORTS-8000 3000 5432 5001 2375 2376}"
TIMEOUT="${CONNECT_TIMEOUT:-3}"

failed=0
report() { # report <ok|fail> <description>
  if [[ $1 == ok ]]; then printf '[ OK ]   %s\n' "$2"; else printf '[FAIL]   %s\n' "$2"; failed=$((failed + 1)); fi
}
tcp_open() { timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/$HOST/$1" 2>/dev/null; }

for port in "$HTTP_PORT" "$HTTPS_PORT"; do
  if tcp_open "$port"; then report ok "puerto ${port} abierto (proxy)"; else report fail "puerto ${port} cerrado: el proxy debe responder"; fi
done

resolve=(--resolve "${DOMAIN}:${HTTP_PORT}:${HOST}" --resolve "${DOMAIN}:${HTTPS_PORT}:${HOST}")
redirect="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 "${resolve[@]}" "http://${DOMAIN}:${HTTP_PORT}/" || true)"
if [[ $redirect == 30[1278]\ https://* ]]; then report ok "http redirige a https (${redirect})"; else report fail "http no redirige a https (${redirect:-sin respuesta})"; fi

tls_args=("${resolve[@]}")
[[ -z $CA ]] || tls_args+=(--cacert "$CA")
status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${tls_args[@]}" "https://${DOMAIN}:${HTTPS_PORT}/" || true)"
if [[ $status == 200 ]]; then report ok "https://${DOMAIN}:${HTTPS_PORT}/ responde 200${CA:+ (cadena verificada con la CA local)}"; else report fail "https no responde 200 (código: ${status:-sin respuesta}${CA:+; ¿ca.crt correcto?})"; fi

for port in $CLOSED_PORTS; do
  if tcp_open "$port"; then report fail "puerto ${port} ACCESIBLE desde fuera"; else report ok "puerto ${port} cerrado o filtrado"; fi
done

if ((failed > 0)); then printf '\nFAIL: %d control(es) del perímetro fallaron.\n' "$failed" >&2; exit 1; fi
printf '\nOK: el perímetro de %s es el diseñado.\n' "$HOST"
