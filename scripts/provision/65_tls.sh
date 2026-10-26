#!/usr/bin/env bash
# US-PROXY-002 (AC-1): local root CA and the leaf certificate Traefik serves. Idempotent.
#
#   sudo ./scripts/provision/65_tls.sh
#
# Settings are read from the environment first, then from ${APP_ENV_FILE:-${APP_DIR}/.env} (the same
# precedence docker compose uses), because the compose file needs them too:
#   TLS_MODE=selfsigned|acme   required, no default. Anything but `selfsigned` creates nothing.
#   DOMAIN                     host name the certificate is issued for (required in selfsigned mode)
#   TLS_EXTRA_SANS             extra DNS names / IPv4 addresses, separated by spaces or commas
#   TLS_DIR=<APP_DIR>/tls      where the CA and the leaf live (a relative path is relative to APP_DIR)
# Variables of this step only (provision.env or environment):
#   APP_DIR=/opt/autoops
#   TLS_PROXY_UID=65532  TLS_PROXY_GID=65532   identity Traefik runs as (docker-compose.yml `user:`)
#
# The CA is created once and kept. The leaf is reissued only if it is missing, signed by another CA,
# has less than 30 days left or its SANs differ from the wanted ones. The CA private key stays
# root-only and outside the directory that is mounted into the proxy. See infra/traefik/README.md.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/tls.sh"

require_root
APP_DIR="${APP_DIR:-/opt/autoops}"
APP_ENV_FILE="${APP_ENV_FILE:-${APP_DIR}/.env}"
[[ $APP_DIR == /* && $APP_DIR =~ ^[A-Za-z0-9_./-]+$ ]] || die "APP_DIR inválido: '${APP_DIR}'."
[[ -f $APP_ENV_FILE ]] || die "No existe ${APP_ENV_FILE}."

TLS_MODE="$(env_file_value "$APP_ENV_FILE" TLS_MODE)"
case $TLS_MODE in
  selfsigned) ;;
  acme)
    log_info "TLS_MODE=acme: Traefik pide el certificado a Let's Encrypt; no se crea CA local."
    exit 0
    ;;
  *) die "TLS_MODE es obligatorio y debe ser 'selfsigned' o 'acme' (valor actual: '${TLS_MODE}'). Defínelo en ${APP_ENV_FILE}." ;;
esac

DOMAIN="$(env_file_value "$APP_ENV_FILE" DOMAIN)"
[[ -n $DOMAIN ]] || die "DOMAIN es obligatorio en ${APP_ENV_FILE} con TLS_MODE=selfsigned."
TLS_DIR="$(env_file_value "$APP_ENV_FILE" TLS_DIR)"
TLS_DIR="${TLS_DIR:-${APP_DIR}/tls}"
[[ $TLS_DIR == /* ]] || TLS_DIR="${APP_DIR}/${TLS_DIR#./}"
[[ $TLS_DIR =~ ^[A-Za-z0-9_./-]+$ ]] || die "TLS_DIR inválido: '${TLS_DIR}'."
TLS_PROXY_UID="${TLS_PROXY_UID:-65532}"
TLS_PROXY_GID="${TLS_PROXY_GID:-65532}"
[[ $TLS_PROXY_UID =~ ^[0-9]+$ && $TLS_PROXY_GID =~ ^[0-9]+$ ]] || die "TLS_PROXY_UID/TLS_PROXY_GID deben ser numéricos."
command -v openssl >/dev/null || die "openssl no está instalado."

# Main host first; extras may be separated by spaces or commas.
extras="$(env_file_value "$APP_ENV_FILE" TLS_EXTRA_SANS)"
read -r -a names <<<"${DOMAIN} ${extras//,/ }"
tls_desired_sans "${names[@]}" >/dev/null   # validates every name before anything is written

install -d -m 755 -o root -g root "$TLS_DIR"
tls_ensure_ca "$TLS_DIR"
if tls_leaf_valid "$TLS_DIR" "${names[@]}"; then
  log_info "Certificado de ${DOMAIN} vigente: sin cambios."
else
  tls_issue_leaf "$TLS_DIR" "${names[@]}"
fi
tls_enforce_perms "$TLS_DIR" "${TLS_PROXY_UID}:${TLS_PROXY_GID}"

log_info "CA para importar en el navegador/SO: ${TLS_DIR}/ca/ca.crt"
