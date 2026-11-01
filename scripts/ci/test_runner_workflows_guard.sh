#!/usr/bin/env bash
# US-CICD-005 (AC-1): proves that scripts/ci/check_runner_workflows.sh really bites. The real workflows must pass and each
# weakening of the workflow that uses the runner (deploy.yml) must turn the guard red: a pull_request or workflow_run trigger,
# a push that is not limited to main, a missing `production` environment, a runner picked by an expression.
#
#   scripts/ci/test_runner_workflows_guard.sh     # needs python3 with PyYAML
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="${ROOT}/scripts/ci/check_runner_workflows.sh"
TARGET=deploy.yml
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failed=0

"$GUARD" "${ROOT}/.github/workflows" >/dev/null 2>&1 && echo "ok   the real workflows pass the guard" || { echo "FAIL the real workflows do not pass the guard" >&2; failed=1; }

# mutate <description> <old text> <new text>: copies the workflows, replaces the first occurrence in $TARGET, expects red.
mutate() {
  rm -rf "${WORK}/wf" && mkdir "${WORK}/wf" && cp "${ROOT}"/.github/workflows/*.yml "${WORK}/wf/"
  python3 -I - "${WORK}/wf/${TARGET}" "$2" "$3" <<'PY' || { echo "FAIL could not build the mutation: $1" >&2; failed=1; return; }
import sys

path, old, new = sys.argv[1:]
text = open(path, encoding="utf-8").read()
assert old in text, f"mutation target not found: {old!r}"
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
  if "$GUARD" "${WORK}/wf" >/dev/null 2>&1; then
    echo "FAIL the guard accepted: $1" >&2
    failed=1
  else
    echo "ok   the guard rejects: $1"
  fi
}

mutate "a pull_request trigger" $'on:\n  push:' $'on:\n  pull_request:\n  push:'
mutate "a workflow_run trigger" $'on:\n  push:' $'on:\n  workflow_run:\n    workflows: [CI]\n  push:'
mutate "a push that is not limited to main" 'branches: [main]' 'branches: [main, develop]'
mutate "a push without branch limit" $'  push:\n    branches: [main]\n' $'  push:\n'
mutate "a runner job without the production environment" $'    runs-on: autoops-prod\n    environment: production\n' $'    runs-on: autoops-prod\n'
mutate "a runner job in another environment" $'    runs-on: autoops-prod\n    environment: production' $'    runs-on: autoops-prod\n    environment: staging'
# An expression cannot be resolved statically, so the guard treats the job as a runner job: it has no `production` environment.
mutate "a job whose runner is an expression, without the production environment" $'  wait-for-ci:\n    runs-on: ubuntu-24.04' $'  wait-for-ci:\n    runs-on: ${{ inputs.runner }}'

exit "$failed"
