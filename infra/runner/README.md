# Self-hosted runner (US-CICD-003)

A GitHub Actions runner that lives on the AutoOps host, in a locked-down container, for the deploy job of
US-CICD-004/005. It only makes outbound HTTPS connections: no inbound port, no `docker.sock`, no host mounts.

| | |
|---|---|
| Image | [`Dockerfile`](Dockerfile) + [`entrypoint.sh`](entrypoint.sh), built on the host (`autoops/runner:local`) |
| Compose project | [`docker-compose.yml`](docker-compose.yml), project `autoops-runner`, separate from the application stack |
| Unit | `autoops-runner.service` (template [`../systemd/autoops-runner.service.tpl`](../systemd/autoops-runner.service.tpl)) |
| Provisioning | [`scripts/provision/75_runner.sh`](../../scripts/provision/75_runner.sh), check `checks/75_runner.sh` |
| Label | `autoops-prod` (the only one: no `self-hosted`, OS or arch labels) |

## Threat model

A runner executes whatever a workflow tells it to, and this repository is public. The design assumes a workflow can be
malicious and limits what that can reach.

| The runner **can** | The runner **cannot** |
|---|---|
| Make outbound HTTPS connections (GitHub, GHCR) | Receive any inbound connection: no `ports:`, UFW unchanged |
| Write to `/tmp`, its job workspace and its credentials volume | Write to its root filesystem (`read_only: true`) |
| Use up to the CPU, memory and PID limits | Gain privileges: non-root (UID 10001), `cap_drop: [ALL]`, `no-new-privileges`, never `privileged` |
| Run `bash`, `curl`, `jq` and `git` | Touch Docker: no `docker.sock`, no Docker client, no host bind mounts |
| | Reach `postgres`, the gateway or the MCP server: `runner_net` is attached to nothing else |
| | Keep anything between restarts except its own credentials: the workspace is a `tmpfs` |

What the runner may ask of the host (handing over a validated image tag) is designed in US-CICD-004.

Accepted trade-off: the runner is **not ephemeral** (it does not deregister after one job). An ephemeral runner needs a
long-lived credential on the host able to create registration tokens (a PAT or a GitHub App), a bigger secret than the
runner itself. The `tmpfs` workspace and the trusted-workflow rules below bound the cost. Revisit if a GitHub App is
introduced.

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

## Variables

Read from `${APP_DIR}/.env` (the only source: both Compose and the unit use it). Documented in `.env.example`.

| Variable | Default | Meaning |
|---|---|---|
| `RUNNER_REPO_URL` | none | `https://github.com/<owner>/<repo>` the runner serves. **When unset the provisioning step is skipped** |
| `RUNNER_LABELS` | `autoops-prod` | The only labels of the runner |
| `RUNNER_NAME` | `autoops-runner` | Name shown in GitHub |
| `RUNNER_VERSION` / `RUNNER_SHA256` | pin in the `Dockerfile` | Override the pinned runner release; change both together |
| `RUNNER_CPUS`, `RUNNER_MEMORY_LIMIT`, `RUNNER_PIDS_LIMIT`, `RUNNER_WORKSPACE_SIZE` | `2`, `2g`, `512`, `2g` | Limits and size of the job workspace `tmpfs` |
| `RUNNER_REGISTRATION_TOKEN_FILE` | none | One-time token file, only while registering (environment, `provision.env` or `.env`) |
| `RUNNER_CONNECT_TIMEOUT` | `120` | Seconds `75_runner.sh` waits for `Listening for Jobs` |

## Provision

1. Set `RUNNER_REPO_URL=https://github.com/<owner>/<repo>` in `${APP_DIR}/.env`.
2. Get a registration token (valid one hour): GitHub -> Settings -> Actions -> Runners -> New self-hosted runner, or
   `gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token`.
3. Save it to a file **outside the repository and `APP_DIR`**, set `RUNNER_REGISTRATION_TOKEN_FILE` to its path
   (`provision.env` is the usual place) and run:

   ```bash
   sudo ./scripts/provision/bootstrap.sh --env-file provision.env     # or just: sudo ./scripts/provision/75_runner.sh
   sudo ./scripts/provision/verify.sh --env-file provision.env
   ```

`75_runner.sh` builds the image, registers the runner once (a short `up`/`down` outside systemd, so the token never
reaches the unit), installs and starts `autoops-runner.service` and waits for `Listening for Jobs`. The credentials
stay in the `autoops-runner_runner_home` volume. Running it again changes nothing; it skips registration while the
volume holds `.runner`. The token file can then be deleted. Configure the GitHub settings below before relying on it.

Logs go to the journal: `journalctl -u autoops-runner -f`. Restart: `sudo systemctl restart autoops-runner`.

## Operate

**Upgrade the runner.** Take the new release from <https://github.com/actions/runner/releases>, copy the SHA-256 of
`actions-runner-linux-x64-<version>.tar.gz` from its notes, change `RUNNER_VERSION` and `RUNNER_SHA256` together (in the
`Dockerfile`, or in `.env`) and run `75_runner.sh` again: it rebuilds the image (the build fails on a checksum mismatch)
and restarts the unit. The runner never updates itself (`--disableupdate`) because its root filesystem is read-only.

**Rotate the registration token.** The token is single-purpose and expires in an hour, so there is nothing to rotate on
a registered runner. To register again (lost volume, changed repository or labels), get a new token and run the
removal below followed by *Provision*.

**Remove the runner.** (Written from the `config.sh remove` documentation; not yet exercised against the production runner.)

```bash
APP=/opt/autoops
C="docker compose -f $APP/infra/runner/docker-compose.yml --env-file $APP/.env"
sudo systemctl disable --now autoops-runner

# 1. Deregister it from GitHub with a removal token (also valid one hour), mounted like the registration token.
gh api -X POST repos/<owner>/<repo>/actions/runners/remove-token --jq .token | sudo tee /root/runner-remove.token >/dev/null
sudo chown 10001:10001 /root/runner-remove.token && sudo chmod 600 /root/runner-remove.token
sudo env RUNNER_REGISTRATION_TOKEN_FILE=/root/runner-remove.token $C run --rm -T --no-deps --entrypoint bash runner \
  -c './config.sh remove --token "$(cat /run/secrets/runner_token)"'
sudo shred -u /root/runner-remove.token

# 2. Drop the container, network and credentials volume, and the unit.
sudo $C down -v
sudo rm /etc/systemd/system/autoops-runner.service && sudo systemctl daemon-reload
```

If the host is gone, delete the runner under Settings -> Actions -> Runners instead.

Removing `RUNNER_REPO_URL` from `.env` makes `bootstrap.sh` and `verify.sh` skip the runner again.

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

## Evidence

Recorded on 2026-10-29 for `Sanchochx/autoOps`.

| Check | Status | Evidence |
|---|---|---|
| Runner registered, label only `autoops-prod` | Done | `gh api repos/Sanchochx/autoOps/actions/runners` -> `{"name":"autoops-runner","status":"online","busy":false,"labels":["autoops-prod"]}` |
| Smoke run on `main` | Done | Run `40961924146` (`workflow_dispatch`, `main`), job `isolation` green; log below |
| Environment `production` limited to `main`, fork approval, read-only token | Done | Applied and verified with the commands above (`custom_branch_policies: true`, `["main"]`, `all_external_contributors`, `read`) |
| Dispatch from another branch is rejected | **Pending** | Covered by the environment setting, not yet dispatched: `gh workflow run runner-smoke.yml --ref <other-branch>` must be refused with "not allowed to deploy to production" |
| Fork pull request does not reach the runner without approval | **Pending** | Needs a fork owned by another account (see Smoke test); until then the covered assumption is `all_external_contributors` plus the `runner-workflows` guard |

```text
host=77b5104b8d9d runner=autoops-runner os=Linux/X64 uid=10001
ok   does not run as root
ok   no Docker socket (/var/run/docker.sock)
ok   no Docker client installed
ok   root filesystem is mounted read-only
ok   job temp directory is writable
ok   the name 'postgres' does not resolve
ok   the name 'api-gateway' does not resolve
ok   the name 'mcp-logs' does not resolve
ok   HTTPS to api.github.com works
```
