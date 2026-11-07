#!/usr/bin/env bash
# US-CICD-004 (AC-1): deploys a published image tag on the host, health-gates it and rolls back on failure.
#
#   ./scripts/ops/deploy.sh --request-file <path>   # a request left by the runner (autoops-deploy.service)
#   ./scripts/ops/deploy.sh --tag <40-hex sha>      # operator: deploy or roll back to an exact commit
#   ./scripts/ops/deploy.sh --tag <sha> --dry-run   # validate and print the plan, change nothing
#
# Order (a failure before "apply" changes neither .env nor the running stack):
#   validate -> pull the images -> postgres up + backup -> migrate -> rewrite IMAGE_TAG -> up --wait -> HTTPS probe -> smoke test
#   (scripts/ops/smoke_test.sh: frontend, API, 401 without a token, HSTS, HTTP->HTTPS redirect, gateway image)
# Any failure after IMAGE_TAG was rewritten restores the previous tag. The rollback restores images only, not the schema.
#
# Variables (process environment first, then ${APP_DIR}/.env, like docker compose):
#   APP_DIR=<repo root>              directory with docker-compose.yml and .env
#   DEPLOY_STATE_DIR=<APP_DIR>/.deploy          current / previous / history / lock (0700)
#   DEPLOY_OUTBOX_DIR=<state dir>/outbox        where `status` is written (the runner reads it, never writes it)
#   DEPLOY_HEALTH_PATH=/api/v1/health           public path probed through the proxy (200 expected); /health is not routed
#   DEPLOY_PROTECTED_PATH=/api/v1/tickets       path the smoke test must find answering 401 without a token
#   DEPLOY_HEALTH_RETRIES=12  DEPLOY_HEALTH_INTERVAL=5  DEPLOY_LOCK_TIMEOUT=600  DEPLOY_WAIT_TIMEOUT=240
#   IMAGE_REPOSITORY (required), DOMAIN, PROXY_HTTPS_PORT, TLS_MODE, TLS_DIR   as in .env.example
#   DEPLOY_REPO=<owner>/<repo>       repository whose `main` is the source of truth (default: from RUNNER_REPO_URL)
#   DEPLOY_NET_RETRIES=4  DEPLOY_NET_RETRY_DELAY=2   attempts and pause (s) of the read-only network checks (GitHub API, registry)
#   DEPLOY_TLS_CLASSIC_KEX=1         opt-in: classic TLS key exchange for those checks (curl --curves X25519:secp256r1, docker
#                                    GODEBUG=tlsmlkem=0). For networks that cut the post-quantum ClientHello of recent OpenSSL/Go
#                                    (symptom: random `unexpected eof`, deploys failing with images_missing/provenance_unavailable)
#   DEPLOY_BRANCH=main  DEPLOY_GITHUB_API=https://api.github.com  DEPLOY_IMAGE_SERVICES="api-gateway frontend mcp-logs traefik"
# Guards (US-CICD-004 AC-2): a runner request (--request-file) must name a SHA that is on DEPLOY_BRANCH and not older than the
# current release; any mode requires the images to exist in the registry. An operator's --tag skips the ancestry check (the
# operator may roll back) but not the image check.
# Exit 0 only when the final state is `succeeded`. Logs go to stdout/stderr (journal).
# The request is untrusted input: only `tag` and `run_id` are read, and never passed to a shell.
# The functions are meant to be testable by sourcing this file (main only runs when executed).

TAG_RE='^[0-9a-f]{40}$'
RUN_ID_RE='^[0-9]{1,20}$'
REQUEST_MAX_BYTES=256

log() { echo "deploy: $*" >&2; }
die() { log "ERROR: $*"; exit 2; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Reads one KEY: process environment first, then ${APP_DIR}/.env (never sourced; values may contain spaces or '*').
env_value() {
  local name=$1 line
  if [[ -n ${!name:-} ]]; then echo "${!name}"; return; fi
  line="$(grep -E "^${name}=" "${APP_DIR}/.env" 2>/dev/null | tail -n1)" || true
  line="${line#*=}"; line="${line%\"}"; echo "${line#\"}"
}

# Rewrites (or appends) a single KEY=value line of .env atomically; mode 0600 and every other line are kept.
set_env_value() {
  local name=$1 value=$2 file="${APP_DIR}/.env" tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  awk -v n="$name" -v v="$value" \
    'BEGIN { done = 0 } $0 ~ ("^" n "=") { print n "=" v; done = 1; next } { print } END { if (!done) print n "=" v }' \
    "$file" >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp"
  mv "$tmp" "$file"
}

# --- request ---------------------------------------------------------------------------------------------------------
# parse_request <file>: sets TAG and RUN_ID, or returns 1 (REQUEST_ERROR says why). Accepts only the keys `tag`
# (40 lowercase hex) and `run_id` (digits), each at most once, in a regular file (not a symlink) of at most 256 bytes.
parse_request() {
  local file=$1 size content line key value seen_tag=0 seen_run=0 fd fd_id path_id
  TAG=""; RUN_ID=""; REQUEST_ERROR=""
  [[ -L $file ]] && { REQUEST_ERROR="request is a symlink"; return 1; }
  [[ -f $file ]] || { REQUEST_ERROR="request is not a regular file"; return 1; }
  # Open once, then check that the descriptor and the path are the same inode: the writer (the runner) cannot swap the
  # file for a symlink between the check and the read.
  # The redirection is on the group, not on `exec`: `exec ... 2>/dev/null` would redirect the stderr of the whole script for good.
  { exec {fd}<"$file"; } 2>/dev/null || { REQUEST_ERROR="request cannot be opened"; return 1; }
  fd_id="$(stat -L -c '%d:%i' "/proc/self/fd/${fd}")"; path_id="$(stat -c '%d:%i' -- "$file")"
  if [[ $fd_id != "$path_id" || -L $file ]]; then exec {fd}<&-; REQUEST_ERROR="request changed while being read"; return 1; fi
  size="$(stat -L -c %s "/proc/self/fd/${fd}")"
  if ! ((size > 0 && size <= REQUEST_MAX_BYTES)); then exec {fd}<&-; REQUEST_ERROR="request size out of range"; return 1; fi
  content="$(LC_ALL=C head -c "$REQUEST_MAX_BYTES" <&"$fd" | LC_ALL=C tr -d '\000')"
  exec {fd}<&-
  [[ ${#content} -ge $((size - 1)) ]] || { REQUEST_ERROR="request contains NUL bytes"; return 1; }
  [[ $content != *$'\r'* ]] || { REQUEST_ERROR="request contains CR"; return 1; }
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == *=* ]] || { REQUEST_ERROR="malformed line"; return 1; }
    key="${line%%=*}"; value="${line#*=}"
    case "$key" in
      tag)
        ((seen_tag)) && { REQUEST_ERROR="duplicate key"; return 1; }
        seen_tag=1
        [[ $value =~ $TAG_RE ]] || { REQUEST_ERROR="invalid tag"; return 1; }
        TAG=$value ;;
      run_id)
        ((seen_run)) && { REQUEST_ERROR="duplicate key"; return 1; }
        seen_run=1
        [[ $value =~ $RUN_ID_RE ]] || { REQUEST_ERROR="invalid run_id"; return 1; }
        RUN_ID=$value ;;
      *) REQUEST_ERROR="unknown key"; return 1 ;;
    esac
  done <<<"$content"
  ((seen_tag)) || { REQUEST_ERROR="missing tag"; return 1; }
  return 0
}

# Best effort on a rejected request: keeps a well-formed run_id so the runner's wait ends with `failed` instead of a timeout.
salvage_run_id() {
  local value=""
  if [[ ! -L $1 && -f $1 ]]; then
    value="$(LC_ALL=C head -c "$REQUEST_MAX_BYTES" -- "$1" | grep -m1 -E '^run_id=[0-9]{1,20}$' | cut -d= -f2)" || true
  fi
  RUN_ID=$value
}

# --- state -----------------------------------------------------------------------------------------------------------
# read_tag_file <file>: prints the 40-hex tag stored there, or nothing.
read_tag_file() {
  local value=""
  [[ -f $1 ]] && value="$(head -c 64 -- "$1" | tr -d '[:space:]')"
  [[ $value =~ $TAG_RE ]] && echo "$value"
  return 0
}

write_tag_file() { printf '%s\n' "$2" >"$1.tmp" && mv "$1.tmp" "$1"; }

# Atomic status for the runner. Only fixed codes are written: never raw command output.
write_status() { # state reason rollback
  local out="${OUTBOX_DIR}/status" tmp
  tmp="$(mktemp "${OUTBOX_DIR}/.status.XXXXXX")"
  {
    echo "state=$1"
    echo "reason=$2"
    echo "rollback=$3"
    echo "tag=${TAG}"
    echo "previous=${PREVIOUS}"
    echo "run_id=${RUN_ID}"
    echo "started_at=${STARTED_AT}"
    echo "finished_at=$([[ $1 == running ]] || now)"
  } >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$out"
}

# finish <state> <reason> <rollback>: records the final outcome; returns 0 only for `succeeded`.
finish() {
  FINISHED=1
  write_status "$1" "$2" "$3"
  echo "$(now) $1 ${TAG:-none} ${RUN_ID:-none} $2" >>"${STATE_DIR}/history"
  log "state=$1 reason=$2 rollback=$3 tag=${TAG:-none}"
  [[ $1 == succeeded ]]
}

# --- guards (US-CICD-004 AC-2) ----------------------------------------------------------------------------------------
# compare_status <base> <head>: prints the GitHub compare status of head relative to base (ahead|identical|behind|diverged).
# The response is parsed as JSON (its `files[]` entries have their own `status`); a transport error or an unparsable body
# returns 1 so the caller fails closed.
# net_retry <command...>: runs a read-only network check up to NET_RETRIES times, NET_RETRY_DELAY seconds apart. A flaky link must
# not fail a deploy; a check that keeps failing still fails closed (the caller reports provenance_unavailable / images_missing).
net_retry() {
  local attempt=1
  until "$@"; do
    ((attempt >= NET_RETRIES)) && return 1
    log "network check failed (attempt ${attempt}/${NET_RETRIES}), retrying in ${NET_RETRY_DELAY}s"
    sleep "$NET_RETRY_DELAY"
    attempt=$((attempt + 1))
  done
}

compare_status() {
  local body
  body="$(net_retry curl --fail --silent --show-error --max-time 15 "${CURL_KEX[@]}" --header 'Accept: application/vnd.github+json' \
    "${GITHUB_API}/repos/${DEPLOY_REPO}/compare/${1}...${2}?per_page=1")" || return 1
  python3 -I -c 'import json, sys; print(json.load(sys.stdin)["status"])' <<<"$body" 2>/dev/null
}

# verify_provenance <tag> <current>: sets PROV_REASON. The tag must be on DEPLOY_BRANCH (main is ahead of it or the same)
# and, when a release is running, not older than it (the tag is ahead of the current one).
verify_provenance() {
  local tag=$1 current=$2 st
  PROV_REASON=provenance_unavailable
  [[ $DEPLOY_REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { log "DEPLOY_REPO is not set or invalid: cannot verify the request"; return 1; }
  st="$(compare_status "$tag" "$DEPLOY_BRANCH")" || { log "could not query the GitHub compare API"; return 1; }
  PROV_REASON=provenance_rejected
  case $st in ahead | identical) ;; *) log "${tag} is not on ${DEPLOY_BRANCH} (compare: ${st})"; return 1 ;; esac
  if [[ -n $current && $current != "$tag" ]]; then
    PROV_REASON=provenance_unavailable
    st="$(compare_status "$current" "$tag")" || { log "could not query the GitHub compare API"; return 1; }
    PROV_REASON=provenance_rejected
    [[ $st == ahead ]] || { log "${tag} is not ahead of the current release ${current} (compare: ${st})"; return 1; }
  fi
  PROV_REASON=""
}

# verify_images <tag>: every image of the release exists in the registry (nothing is pulled).
manifest_exists() { docker manifest inspect "$1" >/dev/null 2>&1; }
verify_images() {
  local svc services
  read -ra services <<<"$IMAGE_SERVICES"
  for svc in "${services[@]}"; do
    net_retry manifest_exists "${IMAGE_REPO}/${svc}:${1}" || { log "image ${IMAGE_REPO}/${svc}:${1} not found"; return 1; }
  done
}

# --- steps -----------------------------------------------------------------------------------------------------------
# The new tag reaches pull/migrate only through the environment of the command; .env is untouched until `apply`.
compose_tag() { local tag=$1; shift; (cd "$APP_DIR" && IMAGE_TAG="$tag" docker compose "$@"); }
compose_env() { (cd "$APP_DIR" && docker compose "$@"); }

step_pull() { compose_tag "$1" pull --quiet; }

# Postgres does not depend on the release tag; starting it (if down) guarantees there is something to dump.
step_backup() {
  compose_tag "$1" up -d --wait --wait-timeout "$WAIT_TIMEOUT" postgres \
    && env APP_DIR="$APP_DIR" "${APP_DIR}/scripts/ops/backup_postgres.sh"
}

step_migrate() { compose_tag "$1" --profile tools run --rm -T migrate; }

# Same command as ExecReload in autoops.service.
step_up() { compose_env up -d --wait --wait-timeout "$WAIT_TIMEOUT" --remove-orphans; }

step_apply() { set_env_value IMAGE_TAG "$1" && step_up; }

# CA that signed the certificate when TLS_MODE=selfsigned (empty otherwise: the public certificate is trusted as usual).
tls_cacert() {
  local tls_dir
  [[ "$(env_value TLS_MODE)" == selfsigned ]] || return 0
  tls_dir="$(env_value TLS_DIR)"; tls_dir="${tls_dir:-${APP_DIR}/tls}"
  [[ $tls_dir == /* ]] || tls_dir="${APP_DIR}/${tls_dir#./}"
  echo "${tls_dir}/ca/ca.crt"
}

# HTTPS through Traefik, as a client would reach it (the local CA is trusted explicitly when TLS_MODE=selfsigned).
probe_once() {
  local domain port cacert args=()
  domain="$(env_value DOMAIN)"; port="$(env_value PROXY_HTTPS_PORT)"; port="${port:-443}"
  cacert="$(tls_cacert)"
  [[ -n $cacert ]] && args+=(--cacert "$cacert")
  curl --fail --silent --show-error --max-time 10 --output /dev/null \
    --resolve "${domain}:${port}:127.0.0.1" "${args[@]}" "https://${domain}:${port}${HEALTH_PATH}"
}

step_health() {
  local i
  for ((i = 1; i <= HEALTH_RETRIES; i++)); do
    if probe_once; then log "health probe ok (attempt ${i}/${HEALTH_RETRIES})"; return 0; fi
    log "health probe failed (attempt ${i}/${HEALTH_RETRIES})"
    ((i < HEALTH_RETRIES)) && sleep "$HEALTH_INTERVAL"
  done
  return 1
}

# Post-deploy smoke test (US-CICD-005): the script reads nothing from the request; it gets the values deploy.sh already uses.
step_smoke() { # <tag the stack must be running>
  local https_port http_port
  https_port="$(env_value PROXY_HTTPS_PORT)"; http_port="$(env_value PROXY_HTTP_PORT)"
  SMOKE_DOMAIN="$(env_value DOMAIN)" SMOKE_HTTPS_PORT="${https_port:-443}" SMOKE_HTTP_PORT="${http_port:-80}" \
  SMOKE_HEALTH_PATH="$HEALTH_PATH" SMOKE_PROTECTED_PATH="$PROTECTED_PATH" SMOKE_CACERT="$(tls_cacert)" SMOKE_APP_DIR="$APP_DIR" \
  SMOKE_EXPECT_IMAGE="${IMAGE_REPO}/api-gateway:${1}" \
    "${APP_DIR}/scripts/ops/smoke_test.sh" >&2
}

# Restores the previous tag. Images only: the schema stays as migrated (see the README: expand/contract).
rollback() {
  [[ -n $PREVIOUS ]] || { log "no previous release to roll back to"; return 2; }
  log "rolling back to ${PREVIOUS}"
  set_env_value IMAGE_TAG "$PREVIOUS" && step_up && step_health && step_smoke "$PREVIOUS"
}

# --- main ------------------------------------------------------------------------------------------------------------
usage() { echo "usage: deploy.sh (--request-file <path> | --tag <sha>) [--dry-run]" >&2; exit 2; }

on_exit() {
  local rc=$?
  if ((STARTED && !FINISHED)); then
    write_status failed unexpected_error none 2>/dev/null || true
    log "ERROR: aborted unexpectedly (exit ${rc})"
  fi
}

main() {
  local request_file="" cli_tag="" dry_run=0 reason
  STARTED=0; FINISHED=0; TAG=""; RUN_ID=""; PREVIOUS=""
  while (($#)); do
    case "$1" in
      --request-file) [[ $# -ge 2 ]] || usage; request_file=$2; shift 2 ;;
      --tag) [[ $# -ge 2 ]] || usage; cli_tag=$2; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) usage ;;
    esac
  done
  [[ -n $request_file || -n $cli_tag ]] || usage
  [[ -z $request_file || -z $cli_tag ]] || usage

  APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  [[ -f ${APP_DIR}/docker-compose.yml && -f ${APP_DIR}/.env ]] || die "docker-compose.yml or .env not found in ${APP_DIR}."
  STATE_DIR="$(env_value DEPLOY_STATE_DIR)"; STATE_DIR="${STATE_DIR:-${APP_DIR}/.deploy}"
  OUTBOX_DIR="$(env_value DEPLOY_OUTBOX_DIR)"; OUTBOX_DIR="${OUTBOX_DIR:-${STATE_DIR}/outbox}"
  [[ $STATE_DIR == /* && $OUTBOX_DIR == /* ]] || die "DEPLOY_STATE_DIR and DEPLOY_OUTBOX_DIR must be absolute paths."
  HEALTH_PATH="${DEPLOY_HEALTH_PATH:-/api/v1/health}"
  PROTECTED_PATH="${DEPLOY_PROTECTED_PATH:-/api/v1/tickets}"
  HEALTH_RETRIES="${DEPLOY_HEALTH_RETRIES:-12}"
  HEALTH_INTERVAL="${DEPLOY_HEALTH_INTERVAL:-5}"
  WAIT_TIMEOUT="${DEPLOY_WAIT_TIMEOUT:-240}"
  LOCK_TIMEOUT="${DEPLOY_LOCK_TIMEOUT:-600}"
  NET_RETRIES="${DEPLOY_NET_RETRIES:-4}"
  NET_RETRY_DELAY="${DEPLOY_NET_RETRY_DELAY:-2}"
  CURL_KEX=()
  if [[ "$(env_value DEPLOY_TLS_CLASSIC_KEX)" == 1 ]]; then
    CURL_KEX=(--curves X25519:secp256r1)
    export GODEBUG="${GODEBUG:+${GODEBUG},}tlsmlkem=0"
  fi
  IMAGE_REPO="$(env_value IMAGE_REPOSITORY)"
  IMAGE_SERVICES="${DEPLOY_IMAGE_SERVICES:-api-gateway frontend mcp-logs traefik}"
  DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
  GITHUB_API="${DEPLOY_GITHUB_API:-https://api.github.com}"
  DEPLOY_REPO="$(env_value DEPLOY_REPO)"
  if [[ -z $DEPLOY_REPO ]]; then
    local url
    url="$(env_value RUNNER_REPO_URL)"
    [[ $url == https://github.com/* ]] && { DEPLOY_REPO="${url#https://github.com/}"; DEPLOY_REPO="${DEPLOY_REPO%.git}"; }
  fi
  [[ $IMAGE_SERVICES =~ ^[a-z0-9\ -]+$ ]] || die "DEPLOY_IMAGE_SERVICES is invalid."
  [[ $DEPLOY_BRANCH =~ ^[A-Za-z0-9._/-]+$ ]] || die "DEPLOY_BRANCH is invalid."
  [[ $GITHUB_API == https://* && $GITHUB_API =~ ^[A-Za-z0-9:/._-]+$ ]] || die "DEPLOY_GITHUB_API must be an https URL."
  local n
  for n in "$HEALTH_RETRIES" "$HEALTH_INTERVAL" "$WAIT_TIMEOUT" "$LOCK_TIMEOUT" "$NET_RETRIES" "$NET_RETRY_DELAY"; do
    [[ $n =~ ^[0-9]+$ ]] || die "DEPLOY_* numeric settings must be non-negative integers."
  done
  [[ $HEALTH_PATH == /* && $HEALTH_PATH =~ ^[A-Za-z0-9_./-]+$ ]] || die "DEPLOY_HEALTH_PATH is invalid."
  [[ $PROTECTED_PATH == /* && $PROTECTED_PATH =~ ^[A-Za-z0-9_./-]+$ ]] || die "DEPLOY_PROTECTED_PATH is invalid."

  if ((dry_run)); then
    if [[ -n $request_file ]]; then
      parse_request "$request_file" || die "invalid request: ${REQUEST_ERROR}."
    else
      [[ $cli_tag =~ $TAG_RE ]] || die "--tag must be 40 lowercase hex characters."
      TAG=$cli_tag
    fi
    log "dry-run: would deploy ${TAG} (run_id=${RUN_ID:-manual})"
    log "dry-run: current=$(read_tag_file "${STATE_DIR}/current") previous=$(read_tag_file "${STATE_DIR}/previous")"
    log "dry-run: pull -> postgres up + backup -> migrate -> IMAGE_TAG -> up --wait -> probe ${HEALTH_PATH} -> smoke test -> rollback on failure"
    return 0
  fi

  umask 077
  mkdir -p "$STATE_DIR" "$OUTBOX_DIR"
  chmod 0700 "$STATE_DIR"
  chmod 0755 "$OUTBOX_DIR"
  exec 9>"${STATE_DIR}/lock"
  flock -w "$LOCK_TIMEOUT" 9 || die "another deploy is running (lock wait exceeded ${LOCK_TIMEOUT}s)."
  STARTED_AT="$(now)"
  trap on_exit EXIT
  STARTED=1

  # --- AC: request (a failure here changes nothing) ---
  if [[ -n $request_file ]]; then
    if ! parse_request "$request_file"; then
      log "invalid request: ${REQUEST_ERROR}"
      salvage_run_id "$request_file"
      rm -f -- "$request_file" || true
      finish failed invalid_request none || true
      return 1
    fi
    rm -f -- "$request_file" || log "warning: could not remove ${request_file}"
  else
    [[ $cli_tag =~ $TAG_RE ]] || { log "--tag must be 40 lowercase hex characters"; finish failed invalid_request none || true; return 1; }
    TAG=$cli_tag; RUN_ID=manual
  fi

  local current
  current="$(read_tag_file "${STATE_DIR}/current")"
  # First deploy on a host whose .env was set by hand: that tag is the one to go back to.
  [[ -n $current ]] || current="$(env_value IMAGE_TAG)"
  [[ $current =~ $TAG_RE ]] || current=""
  PREVIOUS=$current

  [[ -n $IMAGE_REPO ]] || { log "IMAGE_REPOSITORY is not set: the host only pulls published images"; finish failed preflight none || true; return 1; }
  if [[ -n $request_file ]]; then
    verify_provenance "$TAG" "$current" || { finish failed "$PROV_REASON" none || true; return 1; }
  fi
  verify_images "$TAG" || { finish failed images_missing none || true; return 1; }
  write_status running none none
  log "deploying ${TAG} (run_id=${RUN_ID}, current=${current:-none})"

  # --- nothing below changes .env until `apply` ---
  step_pull "$TAG" || { finish failed pull_failed none || true; return 1; }
  step_backup "$TAG" || { finish failed backup_failed none || true; return 1; }
  step_migrate "$TAG" || { finish failed migrate_failed none || true; return 1; }

  # --- point of no return: .env now names the new tag ---
  if step_apply "$TAG"; then
    if step_health; then
      if step_smoke "$TAG"; then
        [[ -n $current && $current != "$TAG" ]] && write_tag_file "${STATE_DIR}/previous" "$current"
        write_tag_file "${STATE_DIR}/current" "$TAG"
        finish succeeded none none
        return
      fi
      reason=smoke_failed
    else
      reason=health_failed
    fi
  else
    reason=apply_failed
  fi

  local rb=0
  rollback || rb=$?
  case $rb in
    0) finish rolled_back "$reason" ok || true ;;
    2) finish failed "$reason" none || true ;;
    *) log "ERROR: the rollback failed too; the stack needs manual attention"; finish failed "$reason" failed || true ;;
  esac
  return 1
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -eo pipefail
  main "$@"
fi
