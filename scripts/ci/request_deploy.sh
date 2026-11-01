#!/usr/bin/env bash
# US-CICD-004 (AC-4): runner side of the deploy handoff. The runner can only ASK: it leaves a request in the inbox and
# waits for the host (autoops-deploy.path -> scripts/ops/deploy.sh) to write the outcome to the outbox.
#
#   scripts/ci/request_deploy.sh [--tag <40-hex sha>] [--run-id <digits>] [--timeout <s>] [--interval <s>]
#
# Defaults: tag = $GITHUB_SHA, run id = $GITHUB_RUN_ID (so it works as-is in a workflow step).
# Variables (all optional):
#   DEPLOY_INBOX_DIR=/deploy/inbox       where `request` is written (read-write mount of the runner)
#   DEPLOY_OUTBOX_DIR=/deploy/outbox     where the host writes `status` (read-only mount of the runner)
#   DEPLOY_WAIT_TIMEOUT=900              seconds to wait for the outcome (pull + backup + migrate + up --wait + health)
#   DEPLOY_POLL_INTERVAL=3               seconds between reads of `status`
#
# The request is `tag=<sha>` and `run_id=<digits>`; it is written to a temporary name and renamed, so the host's path unit
# never sees a half-written file. The outcome is the `status` whose run_id matches AND that started after the request was
# written (a re-run of a workflow keeps its run_id, so an old status of the same run must not be mistaken for the new one).
# The host re-validates everything; the checks here only fail fast and keep the output free of workflow commands.
#
# Exit codes: 0 succeeded | 1 rolled_back | 2 failed | 3 timeout (request withdrawn) | 4 spool unusable or a request
# already pending | 64 usage.
set -euo pipefail

TAG_RE='^[0-9a-f]{40}$'
RUN_ID_RE='^[0-9]{1,20}$'
NUM_RE='^[0-9]{1,6}$'
TIME_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
WORD_RE='^[a-z_]{1,40}$'
STATUS_MAX_BYTES=2048

log() { echo "request_deploy: $*" >&2; }
die() { local code=$1; shift; log "ERROR: $*"; exit "$code"; }
usage() { echo "usage: request_deploy.sh [--tag <sha>] [--run-id <digits>] [--timeout <s>] [--interval <s>]" >&2; exit 64; }

INBOX="${DEPLOY_INBOX_DIR:-/deploy/inbox}"
OUTBOX="${DEPLOY_OUTBOX_DIR:-/deploy/outbox}"
TIMEOUT="${DEPLOY_WAIT_TIMEOUT:-900}"
INTERVAL="${DEPLOY_POLL_INTERVAL:-3}"
TAG="${GITHUB_SHA:-}"
RUN_ID="${GITHUB_RUN_ID:-}"

while (($#)); do
  case "$1" in
    --tag) [[ $# -ge 2 ]] || usage; TAG=$2; shift 2 ;;
    --run-id) [[ $# -ge 2 ]] || usage; RUN_ID=$2; shift 2 ;;
    --timeout) [[ $# -ge 2 ]] || usage; TIMEOUT=$2; shift 2 ;;
    --interval) [[ $# -ge 2 ]] || usage; INTERVAL=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ $TAG =~ $TAG_RE ]] || die 64 "the tag must be 40 lowercase hex characters."
[[ $RUN_ID =~ $RUN_ID_RE ]] || die 64 "the run id must be 1-20 digits."
[[ $TIMEOUT =~ $NUM_RE && $INTERVAL =~ $NUM_RE && $INTERVAL -ge 1 ]] || die 64 "timeout/interval must be whole seconds (interval >= 1)."
[[ -d $INBOX && -w $INBOX ]] || die 4 "inbox '${INBOX}' is missing or not writable."
[[ -d $OUTBOX ]] || die 4 "outbox '${OUTBOX}' is missing."
# A pending request would be overwritten by the rename and its owner would never get an answer.
[[ ! -e ${INBOX}/request && ! -L ${INBOX}/request ]] || die 4 "another deploy request is already pending in ${INBOX}."

# status_field <file> <key>: the last value of <key> in the (small, regular, non-symlink) status file.
status_field() {
  { LC_ALL=C head -c "$STATUS_MAX_BYTES" -- "$1" | grep -E "^$2=" | tail -n1 | cut -d= -f2-; } || true
}

STARTED_AFTER="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TMP="$(mktemp "${INBOX}/.request.XXXXXX")"
trap 'rm -f -- "$TMP"' EXIT
printf 'tag=%s\nrun_id=%s\n' "$TAG" "$RUN_ID" >"$TMP"
# The host runs as another user (group of the inbox): it must be able to read the file. The content is not secret.
chmod 0644 "$TMP"
mv -f -- "$TMP" "${INBOX}/request"
log "requested ${TAG} (run_id=${RUN_ID}); waiting up to ${TIMEOUT}s for the host."

waited=0
last_state=""
while :; do
  status="${OUTBOX}/status"
  if [[ -f $status && ! -L $status ]]; then
    s_run="$(status_field "$status" run_id)"
    s_tag="$(status_field "$status" tag)"
    s_start="$(status_field "$status" started_at)"
    if [[ $s_run == "$RUN_ID" && $s_tag == "$TAG" && $s_start =~ $TIME_RE && ( ! $s_start < $STARTED_AFTER ) ]]; then
      state="$(status_field "$status" state)"
      [[ $state =~ $WORD_RE ]] || state=invalid
      if [[ $state != "$last_state" ]]; then log "host state: ${state}"; last_state=$state; fi
      if [[ $state != running ]]; then
        reason="$(status_field "$status" reason)"; [[ $reason =~ $WORD_RE ]] || reason=unknown
        rollback="$(status_field "$status" rollback)"; [[ $rollback =~ $WORD_RE ]] || rollback=unknown
        echo "state=${state} reason=${reason} rollback=${rollback} tag=${TAG} run_id=${RUN_ID}"
        case "$state" in
          succeeded) exit 0 ;;
          rolled_back) exit 1 ;;
          *) exit 2 ;;
        esac
      fi
    fi
  fi
  if ((waited >= TIMEOUT)); then
    # Never leave a request behind that the host might deploy long after this job gave up.
    rm -f -- "${INBOX}/request" 2>/dev/null || true
    die 3 "no outcome from the host after ${TIMEOUT}s; the request was withdrawn (see: journalctl -u autoops-deploy)."
  fi
  sleep "$INTERVAL"
  waited=$((waited + INTERVAL))
done
