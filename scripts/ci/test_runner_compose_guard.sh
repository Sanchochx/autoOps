#!/usr/bin/env bash
# US-CICD-004 (AC-4): proves that scripts/ci/check_runner_compose.sh really bites. The real runner Compose must pass and
# each weakening of it must turn the guard red: a third mount, a writable outbox, the Docker socket, a source that Docker
# may create. Needs `docker compose config` and jq; DEPLOY_INBOX_DIR / DEPLOY_OUTBOX_DIR / RUNNER_REPO_URL are provided
# here when unset.
#
#   scripts/ci/test_runner_compose_guard.sh [compose-file]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILE="${1:-${ROOT}/infra/runner/docker-compose.yml}"
GUARD="${ROOT}/scripts/ci/check_runner_compose.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export RUNNER_REPO_URL="${RUNNER_REPO_URL:-https://github.com/example/example}"
export DEPLOY_INBOX_DIR="${DEPLOY_INBOX_DIR:-/srv/autoops/deploy/inbox}"
export DEPLOY_OUTBOX_DIR="${DEPLOY_OUTBOX_DIR:-/srv/autoops/deploy/outbox}"
failed=0

"$GUARD" "$FILE" >/dev/null 2>&1 && echo "ok   the real Compose passes the guard" || { echo "FAIL the real Compose does not pass the guard" >&2; failed=1; }

# mutate <description> <old text> <new text>: replaces the first occurrence and expects the guard to fail.
mutate() {
  python3 -I - "$FILE" "$2" "$3" >"${WORK}/mutated.yml" <<'PY'
import sys

path, old, new = sys.argv[1:]
text = open(path, encoding="utf-8").read()
assert old in text, f"mutation target not found: {old!r}"
sys.stdout.write(text.replace(old, new, 1))
PY
  [[ -s ${WORK}/mutated.yml ]] || { echo "FAIL could not build the mutation: $1" >&2; failed=1; return; }
  if "$GUARD" "${WORK}/mutated.yml" >/dev/null 2>&1; then
    echo "FAIL the guard accepted: $1" >&2
    failed=1
  else
    echo "ok   the guard rejects: $1"
  fi
}

mutate "a third host mount" $'    tmpfs:' $'      - type: bind\n        source: /etc\n        target: /host-etc\n    tmpfs:'
mutate "a writable outbox" $'        read_only: true\n        bind:' $'        bind:'
mutate "a spool mounted at the wrong target" 'target: /deploy/inbox' 'target: /deploy/inbox2'
mutate "the Docker socket as the inbox" 'source: ${DEPLOY_INBOX_DIR:?define DEPLOY_INBOX_DIR (host spool, see .env.example)}' 'source: /var/run/docker.sock'
mutate "a source Docker may create" $'target: /deploy/inbox\n        bind: {create_host_path: false}' 'target: /deploy/inbox'
mutate "the filesystem root as the inbox" 'source: ${DEPLOY_INBOX_DIR:?define DEPLOY_INBOX_DIR (host spool, see .env.example)}' 'source: /'

exit "$failed"
