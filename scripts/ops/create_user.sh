#!/usr/bin/env bash
# Creates (or resets the password of) a dashboard user. Run it on the host, from an interactive terminal, once after the
# first deploy of the authentication release and whenever a user must be added:
#
#   scripts/ops/create_user.sh
#
# The username and the password are typed at a prompt (no echo, asked twice). They are NOT read from .env or the
# environment and are NOT passed as arguments, so they never reach a file, `ps` or the shell history: the prompt runs inside
# the already running api-gateway container (`docker compose exec -it`), which stores only the argon2 hash.
#
# Variables:
#   APP_DIR=<repo root>   directory with docker-compose.yml and .env
set -euo pipefail

APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

[[ -t 0 && -t 1 ]] || { echo "create_user: run this from an interactive terminal (credentials are prompted)." >&2; exit 2; }
[[ -f ${APP_DIR}/docker-compose.yml && -f ${APP_DIR}/.env ]] || { echo "create_user: docker-compose.yml or .env not found in ${APP_DIR}." >&2; exit 2; }

cd "$APP_DIR"
exec docker compose exec api-gateway python -m apps.api_gateway.create_user
