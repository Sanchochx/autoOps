#!/usr/bin/env bash
# US-CICD-003: asserts that only trusted workflows can reach the self-hosted runner. Runs in CI (job runner-workflows).
#
#   scripts/ci/check_runner_workflows.sh [workflow-dir]        # needs python3 with PyYAML
#   RUNNER_LABEL=autoops-prod                                   # label of the runner (default)
#
# The repository is public and a self-hosted runner executes whatever a workflow says. Any job whose `runs-on` mentions
# the runner label (or is an expression that cannot be resolved statically) must live in a workflow that is:
#   - triggered only by `workflow_dispatch` or by `push` to the `main` branch (never pull_request, pull_request_target,
#     schedule, workflow_run, tags...), and
#   - declares `environment: production` on that job (the environment is limited to `main` in GitHub settings).
# Exit 0 = every use of the runner complies, 1 = a workflow breaks a rule.
set -euo pipefail

DIR="${1:-.github/workflows}"
export RUNNER_LABEL="${RUNNER_LABEL:-autoops-prod}"

exec python3 -I - "$DIR" <<'PY'
import glob
import os
import sys

import yaml

label = os.environ["RUNNER_LABEL"]
failed = False


def fail(message):
    global failed
    failed = True
    print(f"FAIL {message}", file=sys.stderr)


def mentions_runner(runs_on):
    text = yaml.safe_dump(runs_on)
    return label in text or "${{" in text


def trigger_problem(on):
    # YAML 1.1 reads the key `on` as True.
    if isinstance(on, str):
        on = {on: None}
    elif isinstance(on, list):
        on = {event: None for event in on}
    for event, config in on.items():
        if event == "workflow_dispatch":
            continue
        if event == "push":
            config = config or {}
            if config.get("branches") != ["main"] or "tags" in config or "tags-ignore" in config:
                return "push must be limited to `branches: [main]` (no tags)"
            continue
        return f"trigger `{event}` is not allowed (only workflow_dispatch and push to main)"
    return None


def environment_name(environment):
    return environment.get("name") if isinstance(environment, dict) else environment


files = sorted(glob.glob(os.path.join(sys.argv[1], "*.yml")) + glob.glob(os.path.join(sys.argv[1], "*.yaml")))
if not files:
    print(f"FAIL no workflows found in {sys.argv[1]}", file=sys.stderr)
    sys.exit(1)

for path in files:
    with open(path, encoding="utf-8") as handle:
        workflow = yaml.safe_load(handle) or {}
    jobs = workflow.get("jobs") or {}
    runner_jobs = [name for name, job in jobs.items() if "runs-on" in (job or {}) and mentions_runner(job["runs-on"])]
    if not runner_jobs:
        print(f"ok   {path}: does not use the runner")
        continue
    problem = trigger_problem(workflow.get(True, workflow.get("on")) or {})
    if problem:
        fail(f"{path}: uses the runner but {problem}")
    for name in runner_jobs:
        if environment_name(jobs[name].get("environment")) != "production":
            fail(f"{path}: job `{name}` uses the runner without `environment: production`")
    if not problem and all(environment_name(jobs[n].get("environment")) == "production" for n in runner_jobs):
        print(f"ok   {path}: runner jobs {runner_jobs} are workflow_dispatch/push-to-main with environment production")

sys.exit(1 if failed else 0)
PY
