# Self-hosted runner (US-CICD-003)

A GitHub Actions runner that lives on the AutoOps host, in a locked-down container, for the deploy job of
US-CICD-004/005. It only makes outbound HTTPS connections: no inbound port, no `docker.sock`, no host mounts.

> Work in progress: this file holds what AC-4 needs (the GitHub settings and the smoke test). The threat model,
> provisioning, upgrade, token rotation and removal procedures are added in AC-5.

## Only trusted workflows may use the runner

The repository is public and a self-hosted runner executes whatever a workflow says. Four layers keep it to trusted code:

1. **A unique label and no default ones.** The runner is registered with `--no-default-labels --labels autoops-prod`, so
   `runs-on: self-hosted` never matches it. Jobs target it with `runs-on: autoops-prod`.
2. **Triggers.** A workflow that uses it is triggered only by `workflow_dispatch` or by `push` to `main`, never by
   `pull_request`. `scripts/ci/check_runner_workflows.sh` (job `runner-workflows` of `ci`) fails the build otherwise.
3. **Environment.** Its jobs declare `environment: production`, which is restricted to the `main` branch: a dispatch
   from any other branch is rejected before it reaches the host. The same script requires the declaration.
4. **GitHub settings** (below), which are not in the repository.

Known limit: the environment rule only protects jobs that declare it. A collaborator with write access could push a
branch whose workflow has a job with `runs-on: autoops-prod` and no environment. `runner-workflows` fails that pull
request, but a collaborator can also edit the check. What contains it is that the runner has no Docker socket, shares
no network with the application and has a read-only root filesystem, plus keeping write access to the repository small.

## GitHub settings

Set `REPO=<owner>/<repo>` and run with a token that has admin rights on the repository (`gh auth login`).

```bash
REPO=<owner>/<repo>

# 1. Environment `production`, deployable only from `main`
gh api -X PUT repos/$REPO/environments/production --input - \
  <<< '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
gh api -X POST repos/$REPO/environments/production/deployment-branch-policies -f name=main -f type=branch

# 2. Workflows from fork pull requests need approval for every outside collaborator
gh api -X PUT repos/$REPO/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors

# 3. The default GITHUB_TOKEN is read-only
gh api -X PUT repos/$REPO/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
```

Verify (each line must print what the comment says):

```bash
gh api repos/$REPO/environments/production --jq .deployment_branch_policy                      # custom_branch_policies:true
gh api repos/$REPO/environments/production/deployment-branch-policies --jq '[.branch_policies[].name]'   # ["main"]
gh api repos/$REPO/actions/permissions/fork-pr-contributor-approval --jq .approval_policy      # all_external_contributors
gh api repos/$REPO/actions/permissions/workflow --jq .default_workflow_permissions             # read
gh api repos/$REPO/actions/runners --jq '[.runners[] | [.labels[].name]]'                        # [["autoops-prod"]]
```

## Smoke test

`.github/workflows/runner-smoke.yml` (manual, `environment: production`, `permissions: {}`, no third-party actions)
runs on the runner and asserts from the inside that it is not root, has no `/var/run/docker.sock` and no `docker`
client, has a read-only root, cannot resolve `postgres`, `api-gateway` or `mcp-logs`, and can reach `api.github.com`.

```bash
gh workflow run runner-smoke.yml --ref main     # green: every line `ok`
gh workflow run runner-smoke.yml --ref <other>  # rejected: the branch is not allowed to deploy to `production`
gh run list --workflow runner-smoke.yml
```

The "fork pull request does not reach the runner without approval" check needs a fork owned by **another account**: a
pull request from a branch of this repository is written by a collaborator with write access, so it would run.
