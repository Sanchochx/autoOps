#!/usr/bin/env bash
# Verifies the controls of US-PROXY-002 AC-1 (read-only). Same variables as 65_tls.sh:
#
#   sudo ./scripts/provision/checks/65_tls.sh
# With TLS_MODE=acme only the mode is checked: there is no local CA to verify.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/tls.sh"

require_root
APP_DIR="${APP_DIR:-/opt/autoops}"
APP_ENV_FILE="${APP_ENV_FILE:-${APP_DIR}/.env}"
TLS_MODE="$(env_file_value "$APP_ENV_FILE" TLS_MODE)"
DOMAIN="$(env_file_value "$APP_ENV_FILE" DOMAIN)"
TLS_DIR="$(env_file_value "$APP_ENV_FILE" TLS_DIR)"
TLS_DIR="${TLS_DIR:-${APP_DIR}/tls}"
[[ $TLS_DIR == /* ]] || TLS_DIR="${APP_DIR}/${TLS_DIR#./}"
PROXY_IDS="${TLS_PROXY_UID:-65532}:${TLS_PROXY_GID:-65532}"
CA="${TLS_DIR}/ca"
SRV="${TLS_DIR}/server"
CERT="${SRV}/cert.pem"

mode_valid()      { [[ $TLS_MODE == selfsigned || $TLS_MODE == acme ]]; }
perms_are()       { [[ "$(stat -c '%u:%g %a' "$1")" == "$2 $3" ]]; }
ca_is_ca_pair()   { openssl x509 -in "$CA/ca.crt" -noout -text | grep -q 'CA:TRUE' && tls_pubkey_matches "$CA/ca.crt" "$CA/ca.key"; }
ca_perms()        { perms_are "$CA/ca.key" 0:0 400 && perms_are "$CA/ca.crt" 0:0 644; }
srv_perms()       { perms_are "$SRV" "$PROXY_IDS" 750 && perms_are "$SRV/key.pem" "$PROXY_IDS" 400 && perms_are "$CERT" "$PROXY_IDS" 444; }
chain_verifies()  { openssl verify -CAfile "$CA/ca.crt" "$CERT"; }
san_has_domain()  { tls_cert_sans "$CERT" | grep -qx "DNS:${DOMAIN,,}"; }
not_expiring()    { openssl x509 -in "$CERT" -noout -checkend $((TLS_RENEW_BEFORE_DAYS * 86400)); }
lifetime_ok() {
  local from to
  from="$(date -d "$(openssl x509 -in "$CERT" -noout -startdate | cut -d= -f2)" +%s)"
  to="$(date -d "$(openssl x509 -in "$CERT" -noout -enddate | cut -d= -f2)" +%s)"
  (((to - from) / 86400 <= 398))
}
key_matches()     { tls_pubkey_matches "$CERT" "$SRV/key.pem"; }
only_leaf_files() { [[ "$(ls -A "$SRV" | sort | paste -sd' ' -)" == "cert.pem key.pem" ]]; }
no_ca_key_in_srv() { [[ ! -e $SRV/ca.key ]] && ! cmp -s "$CA/ca.key" "$SRV/key.pem"; }

check "TLS_MODE definido (selfsigned o acme)" mode_valid
if [[ $TLS_MODE == selfsigned ]]; then
  check "CA local: ca.crt es una CA y ca.key es su par" ca_is_ca_pair
  check "ca.key es root:root 0400 y ca.crt root:root 0644" ca_perms
  check "el certificado se verifica contra la CA local" chain_verifies
  check "el SAN del certificado incluye DOMAIN (${DOMAIN})" san_has_domain
  check "al certificado le quedan más de ${TLS_RENEW_BEFORE_DAYS} días" not_expiring
  check "validez del certificado <= 398 días (límite de los navegadores)" lifetime_ok
  check "la clave del servidor corresponde al certificado" key_matches
  check "server/ es ${PROXY_IDS} 0750, key.pem 0400 y cert.pem 0444" srv_perms
  check "server/ solo contiene cert.pem y key.pem" only_leaf_files
  check "la clave de la CA no está en server/ (lo único que se monta en el proxy)" no_ca_key_in_srv
fi

check_finish
