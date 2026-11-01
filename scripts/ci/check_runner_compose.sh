#!/usr/bin/env bash
# US-CICD-003: asserts that the self-hosted runner Compose keeps its isolation. Runs in CI (job runner-compose).
#
#   RUNNER_REPO_URL=https://github.com/<owner>/<repo> scripts/ci/check_runner_compose.sh [compose-file]
#
# Checks the RESOLVED model (`docker compose config`), so comments, anchors and overrides cannot hide a change.
# Exit 0 = locked down, 1 = a control is missing.
set -euo pipefail

FILE="${1:-infra/runner/docker-compose.yml}"
model="$(docker compose -f "$FILE" config --format json)"

failed=0
check() { # check <description> <jq filter that must be true>
  if jq -e "$2" <<<"$model" >/dev/null; then
    echo "ok   $1"
  else
    echo "FAIL $1" >&2
    failed=1
  fi
}

check "no reference to the Docker socket anywhere" '[.. | strings | select(test("docker\\.sock"))] | length == 0'
check "no published ports" 'all(.services[]; (.ports // []) | length == 0)'
check "not privileged" 'all(.services[]; (.privileged // false) == false)'
check "no host (or shared) network mode" 'all(.services[]; .network_mode == null)'
check "all capabilities dropped" 'all(.services[]; (.cap_drop // []) | index("ALL") != null)'
check "no capabilities added" 'all(.services[]; (.cap_add // []) | length == 0)'
check "no-new-privileges" 'all(.services[]; (.security_opt // []) | index("no-new-privileges:true") != null)'
check "read-only root filesystem" 'all(.services[]; .read_only == true)'
# US-CICD-004: the ONLY host mounts are the deploy spool: inbox read-write, outbox read-only, fixed targets, and Docker
# must not create the sources (they are made by 70_systemd.sh with the right owner). Anything else turns this red.
check "host bind mounts are exactly the deploy inbox (rw) and outbox (ro)" \
  'all(.services[]; [(.volumes // [])[] | select(.type == "bind")] | sort_by(.target)
     | map({target, read_only: (.read_only // false), create: (.bind.create_host_path | if . == null then true else . end), abs: (.source | startswith("/"))})
     == [{target: "/deploy/inbox", read_only: false, create: false, abs: true},
         {target: "/deploy/outbox", read_only: true, create: false, abs: true}])'
check "the two spool sources differ and are not the Docker socket or the filesystem root" \
  'all(.services[]; [(.volumes // [])[] | select(.type == "bind") | .source] | (unique | length == 2) and all(. != "/" and (test("/var/run|/run/docker") | not)))'
check "no devices, no host PID/IPC" 'all(.services[]; (.devices // []) == [] and .pid == null and .ipc == null)'
check "a single dedicated network, not external" '((.networks // {}) | keys) == ["runner_net"] and (.networks.runner_net.external // false) == false'
check "memory, CPU and pids limits" 'all(.services[]; .mem_limit != null and .cpus != null and .pids_limit != null)'

check "graceful shutdown (run.sh traps SIGTERM and closes the GitHub session)" \
  'all(.services[]; .environment.RUNNER_MANUALLY_TRAP_SIG == "1")'

exit "$failed"
