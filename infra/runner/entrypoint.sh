#!/usr/bin/env bash
# US-CICD-003: entrypoint of the self-hosted runner image.
#   1. refreshes the runner binaries in RUNNER_HOME from the pristine copy baked in the image;
#   2. registers the runner on first start (no `.runner` in RUNNER_HOME), then never again;
#   3. execs the runner (its output goes to stdout/stderr).
#
# Variables:
#   RUNNER_REPO_URL                  https://github.com/<owner>/<repo>; required on first start
#   RUNNER_REGISTRATION_TOKEN_FILE   file with the one-hour registration token; required on first start, never logged
#   RUNNER_LABELS=autoops-prod       comma-separated; the default labels (self-hosted, OS, arch) are NOT added
#   RUNNER_NAME=<hostname>           runner name shown in GitHub
#   RUNNER_HOME=/home/runner/runner  writable working copy and credentials (a volume)
#   RUNNER_DIST_DIR=/opt/actions-runner
set -euo pipefail

log() { echo "runner-entrypoint: $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

DIST_DIR="${RUNNER_DIST_DIR:-/opt/actions-runner}"
RUNNER_HOME="${RUNNER_HOME:-/home/runner/runner}"
RUNNER_LABELS="${RUNNER_LABELS:-autoops-prod}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"

[[ -x ${DIST_DIR}/run.sh ]] || die "no runner found in ${DIST_DIR}."
[[ -d $RUNNER_HOME && -w $RUNNER_HOME ]] || die "RUNNER_HOME '${RUNNER_HOME}' is missing or not writable."

# Binaries only: the credentials (.runner, .credentials*) are not part of the distribution and are left alone.
cp -a --no-preserve=ownership "${DIST_DIR}/." "${RUNNER_HOME}/"

if [[ ! -f ${RUNNER_HOME}/.runner ]]; then
  [[ -n ${RUNNER_REPO_URL:-} ]] || die "RUNNER_REPO_URL is required to register the runner."
  [[ $RUNNER_REPO_URL =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
    || die "RUNNER_REPO_URL must look like https://github.com/<owner>/<repo>."
  [[ $RUNNER_LABELS =~ ^[A-Za-z0-9._,-]+$ ]] || die "RUNNER_LABELS may only contain letters, digits, '.', '_', '-' and ','."

  token_file="${RUNNER_REGISTRATION_TOKEN_FILE:-}"
  [[ -n $token_file ]] || die "RUNNER_REGISTRATION_TOKEN_FILE is required on first start."
  [[ -r $token_file ]] || die "token file '${token_file}' is missing or not readable."
  token="$(tr -d '[:space:]' <"$token_file")"
  [[ -n $token ]] || die "token file '${token_file}' is empty."

  log "registering '${RUNNER_NAME}' for ${RUNNER_REPO_URL} with labels '${RUNNER_LABELS}'."
  # --disableupdate: the root filesystem is read-only, upgrades are image rebuilds.
  (cd "$RUNNER_HOME" && ./config.sh --unattended --replace --disableupdate --no-default-labels \
    --url "$RUNNER_REPO_URL" --token "$token" --name "$RUNNER_NAME" --labels "$RUNNER_LABELS" --work _work) \
    || die "registration failed (is the token older than one hour?)."
  unset token
else
  log "already registered; skipping registration."
fi

cd "$RUNNER_HOME"
exec ./run.sh
