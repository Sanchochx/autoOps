#!/bin/sh
# Builds the effective static configuration (US-PROXY-002 AC-4) and starts Traefik.
# Traefik's static configuration cannot read environment variables and its sources (file, CLI,
# env) cannot be mixed, so the ACME resolver is appended to the baked file here, only when
# TLS_MODE=acme. The result lives in /tmp (tmpfs); the image's files are never modified.
set -eu

BASE=/etc/traefik/traefik.yml
EFFECTIVE=/tmp/traefik.yml

case "${TLS_MODE:-}" in
  selfsigned)
    exec traefik --configFile="$BASE" "$@"
    ;;
  acme)
    : "${ACME_EMAIL:?ACME_EMAIL is required when TLS_MODE=acme}"
    # Values are written inside double quotes: reject anything that could break out of them.
    for v in "$ACME_EMAIL" "${ACME_CA_SERVER:-}"; do
      case "$v" in
        *\"*|*\\*|*"
"*) echo "ACME_EMAIL / ACME_CA_SERVER contain forbidden characters" >&2; exit 1 ;;
      esac
    done
    cp "$BASE" "$EFFECTIVE"
    {
      echo
      echo "certificatesResolvers:"
      echo "  le:"
      echo "    acme:"
      echo "      email: \"$ACME_EMAIL\""
      echo "      storage: /acme/acme.json"
      [ -z "${ACME_CA_SERVER:-}" ] || echo "      caServer: \"$ACME_CA_SERVER\""
      echo "      httpChallenge:"
      echo "        entryPoint: web"
    } >> "$EFFECTIVE"
    exec traefik --configFile="$EFFECTIVE" "$@"
    ;;
  *)
    echo "TLS_MODE must be 'selfsigned' or 'acme' (got '${TLS_MODE:-}')" >&2
    exit 1
    ;;
esac
