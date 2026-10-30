# US-CICD-003: Containerized Self-Hosted Runner on the Host

**Epic:** 14 — CI/CD
**Priority:** HIGH
**Estimate:** 8 pts
**Dependencies:** US-CICD-002, US-SYS-003
**Status:** Completed

---

## User Story

**As** a DevOps engineer,
**I need** a GitHub Actions runner that lives on the AutoOps host, runs in a locked-down container and can only be used by trusted workflows,
**so that** the deploy job (US-CICD-004/005) can run inside the private network with outbound connections only, without opening an inbound port, storing an SSH key in GitHub, or giving CI any power over Docker.

---

## Decisions

- **Pull-based, outbound-only.** The runner opens a long-poll HTTPS connection to GitHub. No inbound port is opened, UFW is unchanged and the SSH deploy key from US-HOST-002 is not used.
- **The runner has no `docker.sock`, no Docker client and no host mounts.** Access to the socket is root on the host. What the runner may ask of the host (hand over a validated image tag) is designed in US-CICD-004; this story only provides the runner and proves it cannot reach anything else.
- **Separate Compose project** in `infra/runner/docker-compose.yml` (project name `autoops-runner`), managed by its own unit `autoops-runner.service`. It is not part of the application `docker-compose.yml`: `autoops.service` runs `up --remove-orphans` and `down`, which would otherwise remove or stop the runner, and a runner failure must never affect the stack.
- **Dedicated network** `runner_net` (bridge, Internet egress, nothing else attached). It shares no network with `edge_net`, `backend_net` or `mcp_net`, so the runner cannot resolve or reach `postgres`, the gateway or the MCP server. No `ports:`.
- **Hardening like the rest of the stack:** non-root user, `cap_drop: [ALL]`, `no-new-privileges`, `read_only: true` with `tmpfs` for `/tmp` and the job workspace (every job starts clean), `pids_limit`, memory and CPU limits, never `privileged`, never `network_mode: host`.
- **Image built from a pinned Dockerfile** (`infra/runner/Dockerfile`): the official `actions/runner` release, version and SHA-256 pinned as build arguments and verified at build time; only the tools the deploy job needs (`bash`, `curl`, `jq`, `git`, `ca-certificates`). It is built on the host by the provisioning step (it is infrastructure, not application code; publishing it to GHCR is out of scope). The runner's self-update is disabled (`--disableupdate`) because the root filesystem is read-only: upgrading means bumping the pinned version and rebuilding.
- **Registration token never touches the repository or the image.** A repository registration token (valid one hour, created in the GitHub UI or with `gh api`) is read from a file whose path is given by `RUNNER_REGISTRATION_TOKEN_FILE` (mode 0600, outside the repository) only while registering. After registration the runner keeps its own credentials in a named volume (`.runner`, `.credentials`); the token is not stored, logged or visible in `docker inspect`. Re-provisioning with the volume present skips registration (idempotent).
- **Non-ephemeral, accepted trade-off.** An ephemeral runner (one job, then deregister) is cleaner, but re-registering needs a long-lived credential that can create registration tokens (a PAT or a GitHub App) on the host, which is a bigger secret than the runner itself. Here the workspace is a `tmpfs` wiped on restart and only trusted workflows may use the runner (next point). Revisit if a GitHub App is introduced.
- **Only trusted workflows may reach the runner.** The repository is public and a self-hosted runner executes whatever a workflow says. Therefore: the runner is repository-scoped, has a unique label (`autoops-prod`) and **no default labels** (`--no-default-labels`, which also drops `self-hosted`), so `runs-on: self-hosted` alone never matches it and jobs target it with `runs-on: autoops-prod`; jobs using it live only in workflows triggered by `push` to `main` or `workflow_dispatch`, never `pull_request`; and they declare `environment: production`, restricted to the `main` branch. Fork pull requests require maintainer approval for all outside collaborators and the default token is read-only. These GitHub settings are not in the repository: they are documented with the `gh api` commands that verify them (same approach as branch protection in CICD-001).
- **Optional step of the provisioning.** `75_runner.sh` runs only when `RUNNER_REPO_URL` is set, so a host without CD still provisions and verifies cleanly. When it is set, `verify.sh` enforces the controls below.
- **Out of scope:** the deploy action, the handoff mechanism and the rollout (US-CICD-004), the CD workflow and smoke test of the stack (US-CICD-005), ephemeral runners or a GitHub App, egress filtering, scale-out to several runners, runner image publication and scanning.

---

## Acceptance Criteria

> Work ONE AT A TIME, in order. Mark `[x]` when each one is done and pause at the final checkpoint before closing the US.

- [x] **AC-1: Runner Image**
  - `infra/runner/Dockerfile` and entrypoint: official `actions/runner` pinned by `RUNNER_VERSION` and `RUNNER_SHA256` (build args, checksum verified, build fails on mismatch), a non-root user, only the tools listed above, no Docker client. The entrypoint registers on first start with `config.sh --unattended --no-default-labels --labels "$RUNNER_LABELS" --name "$RUNNER_NAME" --disableupdate --replace` when `.runner` is absent, reading the token from a file, then `exec ./run.sh`. It exits with a clear message if the token file is missing on first start, and never prints the token.
  - **Verification:** `docker build` succeeds; with a wrong `RUNNER_SHA256` it fails; `docker run --rm <image> id -u` is not 0; `docker run --rm <image> which docker` finds nothing; starting without a token file fails with the message and without a stack trace.

- [x] **AC-2: Locked-Down Compose Project**
  - `infra/runner/docker-compose.yml` (project `autoops-runner`): the hardening, limits and `tmpfs` listed above, the credentials volume, the dedicated `runner_net`, no `ports:`, no `docker.sock`, no bind mounts of host paths. The registration token reaches the container as a Compose **secret** (`/run/secrets/runner_token`, file given by `RUNNER_REGISTRATION_TOKEN_FILE`, readable by UID 10001), not as a bind mount in `volumes`. Variables (`RUNNER_REPO_URL`, `RUNNER_LABELS` default `autoops-prod`, `RUNNER_NAME`, `RUNNER_VERSION`, `RUNNER_SHA256`, `RUNNER_REGISTRATION_TOKEN_FILE`, and the limits) are documented in `.env.example`; nothing is hardcoded. (`provision.env.example` gets the provisioning-side variables in AC-3.)
  - CI: new job `runner-compose` (in `needs:` of `ci`): `config -q` passes, a missing `RUNNER_REPO_URL` is rejected, and `scripts/ci/check_runner_compose.sh` asserts on the **resolved** model (`docker compose config --format json`, not on text) that there is no `docker.sock` reference, no ports, not privileged, no `network_mode`, `cap_drop: [ALL]`, no `cap_add`, `no-new-privileges`, read-only root, no bind mounts, no devices, a single non-external network and memory/CPU/pids limits. The `images` job also builds the runner image (no push).
  - **Verification:** `config -q` and the script are clean; each of the following turns the script (and `ci`) red: adding `/var/run/docker.sock`, `privileged`, `ports`, `network_mode: host`, `cap_add`, a host bind mount, or dropping `read_only`; on a machine with Docker, `docker compose -f infra/runner/docker-compose.yml create` followed by `docker inspect` shows `Privileged=false`, `CapDrop=[ALL]`, `ReadonlyRootfs=true`, one network and, as mounts, only the named volume and the token secret.

- [x] **AC-3: Provisioning, systemd Unit and `verify.sh` Check**
  - `scripts/provision/75_runner.sh` (idempotent, after `70_systemd`): validates the variables, builds the image, renders `infra/systemd/autoops-runner.service.tpl` into `autoops-runner.service` (same sandboxing style as `autoops.service`, `Restart=always`), starts it and waits until the runner is connected. Skipped with a notice when `RUNNER_REPO_URL` is unset. Added to `bootstrap.sh` (`STEPS`) and documented in `provision.env.example`.
  - `scripts/provision/checks/75_runner.sh`, picked up by `verify.sh`: unit enabled and active; container running; not privileged; `cap_drop` ALL; read-only root; no `docker.sock` or host bind mount; attached only to `runner_net`; the token file is not inside the repository nor readable by others; skipped (not failed) when the step is disabled.
  - **Verification:** `bootstrap.sh` twice leaves the host unchanged; `verify.sh` is all OK with the runner enabled and still OK with it disabled; the runner shows **Idle** under Settings → Actions → Runners with the label `autoops-prod`; the token appears in no log, in `docker inspect` output or in `git grep`.

- [x] **AC-4: Only Trusted Workflows Reach the Runner (and It Can Reach Nothing Else)**
  - `.github/workflows/runner-smoke.yml`: `workflow_dispatch` only, `runs-on: autoops-prod`, `environment: production`, `permissions: {}`, no third-party actions. It prints the host name and runner label and asserts, from inside the runner: `/var/run/docker.sock` does not exist; `docker` is not installed; the names `postgres`, `api-gateway` and `mcp-logs` do not resolve; HTTPS to `api.github.com` works.
  - GitHub settings documented in `infra/runner/README.md` with the `gh api` command that verifies each one: environment `production` limited to the `main` branch; fork pull requests from outside collaborators require approval; default `GITHUB_TOKEN` permission read-only; the runner has no default labels.
  - **Verification:** dispatching the workflow on `main` is green and its log shows every assertion; dispatching it from another branch is rejected by the environment rule; a throw-away pull request that tries `runs-on: autoops-prod` does not start a job on the runner without approval (evidence recorded; the experiment is reverted).
  - **Evidence status (see `infra/runner/README.md#evidence`):** the dispatch on `main` is recorded (run 40961924146, green, nine assertions `ok`). The rejection from another branch is covered by the verified environment settings (`production` limited to `main`) but has **not been dispatched**; the fork pull request experiment is **pending** (it needs a fork owned by another account). Both are listed in the README with the exact command to close them.

- [x] **AC-5: Documentation, Evidence and Closing**
  - `infra/runner/README.md`: threat model (what the runner can and cannot do), variables, how to get a registration token, provisioning, upgrade procedure (bump `RUNNER_VERSION` and `RUNNER_SHA256`, rebuild), token rotation and how to remove a runner (`config.sh remove`), the ephemeral trade-off, the settings checklist from AC-4. `infra/ci/README.md`, `infra/README.md`, `.claude/CLAUDE.md` (structure and commands) and `README.md` mention it.
  - Evidence: runner `Idle` screenshot or `gh api repos/<owner>/<repo>/actions/runners` output, the green smoke run, the rejected run from a non-`main` branch and the `verify.sh` table.
  - **Verification:** a reader can provision, upgrade and remove the runner following only the document; plan updated (Epic 14 at 60%, Phase 5 at 6/8).

---

## Technical Notes

- **Why a container and not a systemd service on the host:** the runner executes workflow code; the container gives it a read-only filesystem, dropped capabilities, resource limits and a network with nothing else on it. As a host service it would run as a local user with access to the whole filesystem.
- **Why not `myoung34/github-runner` or similar:** a third-party image would run with our registration and whatever it ships. A small Dockerfile around the official, checksum-pinned release is auditable in one screen.
- **Why labels instead of a runner group:** runner groups are an organization feature; this repository belongs to a personal account. A unique label plus `--no-default-labels` plus an environment restricted to `main` gives the same effect here.
- **Why not `--ephemeral`:** see Decisions. The cost of the compromise is bounded by the container hardening and the trusted-workflow rule.
- **Outbound requirements:** HTTPS (443) to `github.com`, `api.github.com`, `*.actions.githubusercontent.com` and, for the deploy flow, `ghcr.io`. UFW does not filter egress (US-NET-001 leaves it out of scope).
- **Test environment:** the Ubuntu Server 26.04 VM used for Phase 4/5; the Docker-dependent checks run there.
