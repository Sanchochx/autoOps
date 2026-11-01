#!/usr/bin/env bash
# US-CICD-004 (AC-4): exercises scripts/ci/request_deploy.sh against a fake host (no Docker, no systemd needed).
#
#   scripts/ci/test_request_deploy.sh
#
# Each case gets a throw-away inbox/outbox. A background "host" waits for `request` in the inbox, optionally writes a
# `running` status and then the final one, exactly like deploy.sh would (atomic rename). Cases: exit code per state, the
# request bytes and mode, stale or foreign statuses ignored, timeout withdrawing the request, a pending request, invalid
# input, a symlinked status. Exit 0 = every case passed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT}/scripts/ci/request_deploy.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TAG=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OTHER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PASS=0; FAIL=0

ok()   { PASS=$((PASS + 1)); echo "ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1" >&2; }
expect() { # expect <description> <expected> <actual>
  if [[ $2 == "$3" ]]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# new_spool: fresh INBOX/OUTBOX in $WORK/<n>.
n=0
new_spool() {
  n=$((n + 1)); CASE="${WORK}/${n}"; INBOX="${CASE}/inbox"; OUTBOX="${CASE}/outbox"
  mkdir -p "$INBOX" "$OUTBOX"; chmod 0730 "$INBOX"
}

# write_status <state> <tag> <run_id> <started_at> [reason] [rollback]: atomic, like deploy.sh.
write_status() {
  local tmp="${OUTBOX}/.status.$$.$RANDOM"
  printf 'state=%s\nreason=%s\nrollback=%s\ntag=%s\nprevious=\nrun_id=%s\nstarted_at=%s\nfinished_at=2999-01-01T00:00:00Z\n' \
    "$1" "${5:-none}" "${6:-none}" "$2" "$3" "$4" >"$tmp"
  mv "$tmp" "${OUTBOX}/status"
}

# fake_host <final state> <run_id> [tag] [started_at] [running first? 1]: answers the first request that shows up.
fake_host() {
  (
    for _ in $(seq 1 100); do
      [[ -f ${INBOX}/request ]] && break
      sleep 0.1
    done
    [[ -f ${INBOX}/request ]] || exit 0
    cp -p "${INBOX}/request" "${CASE}/request.seen"
    rm -f "${INBOX}/request"
    started="${4:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    if [[ ${5:-0} == 1 ]]; then write_status running "${3:-$TAG}" "$2" "$started"; sleep 1.5; fi
    write_status "$1" "${3:-$TAG}" "$2" "$started" "${6:-none}" "${7:-none}"
  ) &
  HOST_PID=$!
}

run() { # run [args...]: the script under test with a short poll interval; prints stdout, sets RC
  OUT="$(DEPLOY_INBOX_DIR=$INBOX DEPLOY_OUTBOX_DIR=$OUTBOX DEPLOY_POLL_INTERVAL=1 "$SCRIPT" "$@" 2>"${CASE}/stderr")"
  RC=$?
}

# --- exit code by state --------------------------------------------------------------------------------------------------
for entry in "succeeded:0" "rolled_back:1" "failed:2"; do
  state="${entry%%:*}"; want="${entry##*:}"
  new_spool; fake_host "$state" 100 "$TAG"; run --tag "$TAG" --run-id 100 --timeout 20; wait "$HOST_PID"
  expect "state=${state} exits ${want}" "$want" "$RC"
  [[ $OUT == "state=${state} "* ]] && ok "${state}: prints the validated outcome" || fail "${state}: prints the outcome ('${OUT}')"
done

# --- the request itself --------------------------------------------------------------------------------------------------
new_spool; fake_host succeeded 101 "$TAG"; run --tag "$TAG" --run-id 101 --timeout 20; wait "$HOST_PID"
expect "request content is exactly tag + run_id" "$(printf 'tag=%s\nrun_id=101' "$TAG")" "$(cat "${CASE}/request.seen")"
expect "request is world-readable (the host user is not its owner)" "644" "$(stat -c %a "${CASE}/request.seen")"
expect "no temporary file is left in the inbox" "" "$(ls -A "$INBOX")"

# defaults from the workflow environment
new_spool; fake_host succeeded 102 "$TAG"
OUT="$(GITHUB_SHA=$TAG GITHUB_RUN_ID=102 DEPLOY_INBOX_DIR=$INBOX DEPLOY_OUTBOX_DIR=$OUTBOX DEPLOY_POLL_INTERVAL=1 "$SCRIPT" 2>/dev/null)"; RC=$?; wait "$HOST_PID"
expect "GITHUB_SHA / GITHUB_RUN_ID are the defaults" "0" "$RC"

# --- waiting for the right status ---------------------------------------------------------------------------------------
new_spool; fake_host succeeded 103 "$TAG" "" 1; run --tag "$TAG" --run-id 103 --timeout 20; wait "$HOST_PID"
expect "a running status is waited out, then succeeded" "0" "$RC"

new_spool; write_status succeeded "$TAG" 104 2000-01-01T00:00:00Z; fake_host failed 104 "$TAG"
run --tag "$TAG" --run-id 104 --timeout 20; wait "$HOST_PID"
expect "an old status of the same run id (workflow re-run) is ignored" "2" "$RC"

new_spool; write_status succeeded "$TAG" 999 2999-01-01T00:00:00Z; fake_host failed 105 "$TAG"
run --tag "$TAG" --run-id 105 --timeout 20; wait "$HOST_PID"
expect "a status of another run id is ignored" "2" "$RC"

new_spool; write_status succeeded "$OTHER" 106 2999-01-01T00:00:00Z; fake_host rolled_back 106 "$TAG"
run --tag "$TAG" --run-id 106 --timeout 20; wait "$HOST_PID"
expect "a status for another tag is ignored" "1" "$RC"

# --- timeout, pending request, spool problems ---------------------------------------------------------------------------
new_spool; run --tag "$TAG" --run-id 107 --timeout 2
expect "no answer: exits 3" "3" "$RC"
expect "no answer: the request is withdrawn from the inbox" "" "$(ls -A "$INBOX")"

new_spool; echo "tag=${OTHER}" >"${INBOX}/request"; run --tag "$TAG" --run-id 108 --timeout 2
expect "a pending request: exits 4" "4" "$RC"
expect "a pending request is left untouched" "tag=${OTHER}" "$(cat "${INBOX}/request")"

new_spool; rmdir "$OUTBOX"; run --tag "$TAG" --run-id 109 --timeout 2
expect "missing outbox: exits 4, writes nothing" "4:" "${RC}:$(ls -A "$INBOX")"

new_spool; ln -s /etc/hostname "${OUTBOX}/status"; run --tag "$TAG" --run-id 110 --timeout 2
expect "a symlinked status is never followed (timeout)" "3" "$RC"

# --- invalid input never reaches the inbox -------------------------------------------------------------------------------
bad_tags=("${TAG:0:39}" "${TAG}0" "${TAG^^}" "${TAG:0:38};x" 'a$(id)aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "../../etc/passwdaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "")
for t in "${bad_tags[@]}"; do
  new_spool; run --tag "$t" --run-id 111 --timeout 2
  expect "invalid tag '${t:0:24}' exits 64 and writes nothing" "64:" "${RC}:$(ls -A "$INBOX")"
done
for r in "" "12a" "1;2" "-1" "123456789012345678901"; do
  new_spool; run --tag "$TAG" --run-id "$r" --timeout 2
  expect "invalid run id '${r}' exits 64 and writes nothing" "64:" "${RC}:$(ls -A "$INBOX")"
done
new_spool; run --tag "$TAG" --run-id 112 --bogus
expect "unknown option exits 64" "64" "$RC"
new_spool; run --tag "$TAG" --run-id 113 --timeout abc
expect "invalid timeout exits 64" "64" "$RC"

# --- no workflow-command injection through the status -------------------------------------------------------------------
new_spool
( for _ in $(seq 1 100); do [[ -f ${INBOX}/request ]] && break; sleep 0.1; done; rm -f "${INBOX}/request"
  printf 'state=succeeded\nreason=::set-output name=x::y\nrollback=none\ntag=%s\nrun_id=114\nstarted_at=%s\n' "$TAG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${OUTBOX}/status" ) &
HOST_PID=$!
run --tag "$TAG" --run-id 114 --timeout 20; wait "$HOST_PID"
expect "an unvalidated reason is replaced, not echoed" "state=succeeded reason=unknown rollback=none tag=${TAG} run_id=114" "$OUT"

echo
echo "${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
