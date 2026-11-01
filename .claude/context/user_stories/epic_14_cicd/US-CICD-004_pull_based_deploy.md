# US-CICD-004: Pull-Based Deployment on the Host

**Epic:** 14 — CI/CD
**Priority:** CRITICAL
**Estimate:** 8 pts
**Dependencies:** US-CICD-003, US-SYS-004
**Status:** In progress

---

## User Story

**As** a DevOps engineer,
**I need** the host to deploy a validated image tag when the runner asks for it, verify that the stack is healthy and roll back automatically if it is not,
**so that** continuous delivery works without giving CI any power over Docker: the runner can only ask, the host decides and executes.

---

## Decisions

- **Handoff through a pair of spool directories watched by `systemd.path`.** The runner writes one request file into `inbox/`; `autoops-deploy.path` (`PathChanged=`) starts `autoops-deploy.service` on the host, which runs `scripts/ops/deploy.sh`. The host writes the outcome to `outbox/status`, which the runner only reads. A cron job was rejected: it adds polling latency and can overlap with a running deploy, while a `Type=oneshot` unit is serialized by systemd.
- **The runner builds nothing and executes nothing on the host.** Images are built by GitHub Actions and published to GHCR (US-CICD-002). The runner hands over a request; the host validates it, pulls the images itself and applies them.
- **Exactly two host mounts in the runner, fixed sources:** `inbox` (read-write) and `outbox` (read-only). This relaxes the "no host bind mounts" rule of US-CICD-003 to "only these two"; the runner still has no `docker.sock`, no Docker client, no `.env`, no state directory. Every other control of US-CICD-003 stays.
- **The request is untrusted input.** It is `key=value` lines read with a size limit and without following symlinks. Only `tag` (`^[0-9a-f]{40}$`) and `run_id` (`^[0-9]+$`) are accepted; any other key or shape rejects the request. Nothing from the file is passed to a shell, `eval` or a command line unquoted.
- **Forward-only from CI.** The host checks through the GitHub API (public repository, unauthenticated or read-only) that the SHA is reachable from `main` and ahead of or equal to the current one, and that the four images exist in GHCR at that tag. A compromised runner therefore cannot force an old, vulnerable version. Downgrades come only from the automatic rollback or from an operator running `deploy.sh --tag` on the host.
- **Runs as the service user, not root, and reloads with the same Compose command.** The user cannot call `systemctl reload autoops` without polkit, and a polkit rule is extra complexity. `deploy.sh` runs `docker compose up -d --wait --wait-timeout 240 --remove-orphans`, the same command as `ExecReload` in `autoops.service`, which stays `active (exited)` and untouched. (This replaces the "`systemctl reload autoops`" wording in the plan.)
- **State in `${APP_DIR}/.deploy/`** (host-owned, 0700): `current`, `previous` and `history`. A release is applied by rewriting the single `IMAGE_TAG=` line of `${APP_DIR}/.env` atomically (temp file in the same directory, mode 0600 kept). `IMAGE_REPOSITORY` and every other line are never touched.
- **Fixed order, failure before the point of no return changes nothing:** validate → provenance → `pull` the four images → backup (US-SYS-004, always) → migrate → rewrite the tag → `up --wait` → health-gate → record the status. A failure at `pull` or at the backup leaves the stack, the tag and the schema as they were.
- **Backup before every deploy.** The seconds it adds are accepted: migrating without a restore point is the only step with no way back. A failed backup aborts the deploy.
- **Health gate:** `--wait` (container healthchecks) plus an HTTPS probe through Traefik to `DEPLOY_HEALTH_PATH` (default `/api/v1/tickets`, expects 200; the gateway's `/health` is not routed by Traefik), with retries and a timeout, using the local CA or the public certificate as configured.
- **Rollback restores the images, not the schema.** Migrations must stay backward-compatible with the previous release (expand/contract), or the rollback may run old code on a newer schema. The pre-deploy backup is the manual restore point. This limit is documented, not hidden.
- **No registry credential on the host.** The GHCR packages are made public (the repository already is), so `docker compose pull` needs no token and no secret is stored for it. The package visibility setting and the `gh`/UI step to verify it are documented, like the settings of US-CICD-003.
- **Serialization.** `flock` inside `deploy.sh` plus the oneshot unit: two requests never deploy at the same time; one that arrives during a deploy is processed afterwards.
- **Out of scope:** the CD workflow and the post-deploy smoke test (US-CICD-005), image signing and provenance attestation, blue/green or canary, pruning of old images beyond the previous tag, a GitHub App.

---

## Acceptance Criteria

> Work ONE AT A TIME, in order. Mark `[x]` when each one is done and pause at the final checkpoint before closing the US.

- [x] **AC-1: Deploy Action `scripts/ops/deploy.sh`**
  - Flags `--tag <sha>`, `--request-file <path>` and `--dry-run`; reads `APP_DIR` and the rest of its settings from the environment and `.env`, nothing hardcoded. Implements the fixed order above, the `.deploy/` state files, the automatic rollback to `previous` on any failure after the tag was rewritten (including a failed health-gate), and an atomic `outbox/status` (`state=succeeded|rolled_back|failed`, `tag`, `run_id`, `started_at`, `finished_at`). Logs to stdout/stderr (journal). Exit code is non-zero unless the state is `succeeded`.
  - **Verification:** `shellcheck` is clean; deploying a good SHA ends `succeeded` and `current` holds it; a nonexistent SHA fails at `pull` and leaves the stack, `.env` and `.deploy/` unchanged; an image whose healthcheck fails ends `rolled_back` with the previous tag serving; a failed backup aborts before migrating; `--dry-run` changes nothing.
  - **Evidence status:** `shellcheck` is clean and `scripts/ci/test_deploy.sh` (fake `docker`/`curl`, 23 assertions: success, failed pull, backup and migrate, failed `up`, failed health-gate with rollback, first deploy without a previous tag, request file, dry-run, usage) passes. The drills against the real stack on the VM are **pending**; the commands are in the hand-over of this AC and go to `infra/deploy/README.md` in AC-5.

- [x] **AC-2: Input and Provenance Guards**
  - The request parser and the provenance check described in Decisions, as functions of `deploy.sh` (or a sourced library) that can be tested without Docker. Rejects: wrong length, uppercase, non-hex, injection characters (`;`, `$(`, backticks, `../`, newlines), unknown or duplicated keys, a symlink, an oversized file, an empty file; a SHA not on `main`, not ahead of `current`, or without all four images in GHCR.
  - New CI job `deploy-guards` (in `needs:` of `ci`) running a table-driven test in `scripts/ci/` with fake `docker` and `curl` on the `PATH`; every rejection case above must fail the request and the fake `docker` must record no call.
  - **Verification:** each accepted and rejected case in the table passes; removing a guard turns the job (and `ci`) red.
  - **Evidence status:** `scripts/ci/test_deploy.sh` now has 62 assertions (23 flow + 39 guards: 24 parser cases, 12 provenance and operator-mode cases, 3 registry cases) and runs in the `deploy-guards` job, which is in `needs:` of `ci`. Mutation checks done locally: widening the accepted compare statuses, dropping the provenance call and accepting unknown keys each turn the test red. The symlink check is covered twice (the explicit `-L` test and the descriptor-vs-path inode comparison), so removing only the first is not detected by design. The registry check uses `docker manifest inspect`; its behaviour against real GHCR is verified on the VM with the AC-1 drills (a non-existent SHA must end `images_missing`, not `pull_failed`).

- [x] **AC-3: Handoff Units and Provisioning**
  - `infra/systemd/autoops-deploy.path.tpl` and `autoops-deploy.service.tpl` (oneshot, same sandboxing style as the other units, `ReadWritePaths` limited to `APP_DIR` and the spool directories), rendered and verified by `70_systemd.sh` (`systemd-analyze verify`); the path unit is enabled by provisioning. Provisioning creates `inbox` (writable by the runner UID, not readable by others) and `outbox` (writable by the service user, readable by the runner) and `.deploy/`. New check `scripts/provision/checks/85_deploy.sh` picked up by `verify.sh`.
  - **Verification:** writing a request with `mv` (atomic) triggers exactly one run; two quick requests run one after the other; an invalid request produces `failed` and no Docker call; `bootstrap.sh` twice leaves the host unchanged; `verify.sh` is all OK.
  - **Evidence status:** units, spool provisioning and `checks/85_deploy.sh` are in place and were validated on the VM by the operator (path unit triggering the oneshot service). Side fix found while validating the runner on the VM: `run.sh` only traps SIGTERM with `RUNNER_MANUALLY_TRAP_SIG=1`, otherwise the listener is SIGKILLed with its GitHub session open and the next start gets `Conflict` for ~3 min; the Compose now sets it, `check_runner_compose.sh` guards it and `RUNNER_CONNECT_TIMEOUT` defaults to 300 s.

- [x] **AC-4: Runner Side**
  - `infra/runner/docker-compose.yml` gains exactly the two mounts (`inbox` rw, `outbox` ro), sources given by variables documented in `.env.example`. `scripts/ci/check_runner_compose.sh` and `checks/75_runner.sh` change from "no host bind mounts" to "only these two, with these targets and modes". `scripts/ci/request_deploy.sh` writes the request atomically (temp file + `mv`), waits for an `outbox/status` with the matching `run_id` and a timeout, and exits by state. `runner-smoke.yml` also asserts that the runner cannot see `.env`, `.deploy/` or the socket and cannot write to `outbox`.
  - **Verification:** adding a third mount, an rw `outbox`, `docker.sock` or a host path to the runner Compose turns `runner-compose` red; from the runner, writing to `inbox` works and writing to `outbox` fails; `request_deploy.sh` returns 0 for `succeeded` and non-zero for `rolled_back`, `failed` and timeout.
  - **Evidence status:** `shellcheck` is clean. `scripts/ci/test_request_deploy.sh` (fake host, 35 assertions: exit code per state, request bytes and mode, a running status waited out, stale/foreign statuses ignored, timeout withdrawing the request, pending request, invalid input, symlinked status, no workflow-command injection) runs in `deploy-guards`; three mutations of the script (stale-status guard, withdraw on timeout, run id match) turn it red. `scripts/ci/test_runner_compose_guard.sh` (in `runner-compose`) shows the real Compose passing and six weakenings (third mount, writable outbox, wrong target, socket, root as source, creatable source) turning `check_runner_compose.sh` red. The spool sources reach the Compose through `DEPLOY_INBOX_DIR`/`DEPLOY_OUTBOX_DIR`, which `75_runner.sh` resolves with the defaults of `70_systemd.sh` and writes into the unit. The checks inside the real container (`checks/75_runner.sh`, `runner-smoke.yml`) and the end-to-end request against `autoops-deploy.path` are **pending on the VM**: update `/opt/autoops`, `sudo ./scripts/provision/bootstrap.sh`, `sudo ./scripts/provision/verify.sh`, `gh workflow run runner-smoke.yml --ref main`.

- [ ] **AC-5: Failure Drills, Documentation and Closing**
  - Recorded evidence of: a successful deploy, a failed `pull`, a failed health-gate with automatic rollback, a malformed request, a request for an old SHA, and two concurrent requests. `infra/deploy/README.md` (flow, threat model, request format, the operator rollback `deploy.sh --tag`, restoring the pre-deploy backup, the schema limit, GHCR package visibility with its verification command). `infra/runner/README.md` replaces "designed in US-CICD-004" with the actual channel and the new two-mount rule; `infra/ci/README.md`, `infra/README.md`, `infra/systemd/README.md`, `.claude/CLAUDE.md` and `README.md` mention it.
  - **Verification:** a reader can deploy, roll back and restore a backup following only the documents; plan updated (Epic 14 at 80%, Phase 5 at 7/8).

---

## Technical Notes

- **Atomic hand-off:** `PathChanged=` fires when a file opened for writing is closed, so a half-written request could trigger a run. The runner writes `request.tmp` and renames it to `request`; `deploy.sh` ignores any other name.
- **Why not root:** membership of the `docker` group is already root-equivalent for Docker, but not for the rest of the host; running as the service user keeps `deploy.sh` unable to touch SSH, UFW or the system packages, and the unit adds the usual sandboxing on top.
- **Why compare against `main` in the host and not in the workflow:** the workflow runs inside the runner, the component this design does not trust. The host re-derives everything it needs from public data.
- **Test environment:** the Ubuntu Server 26.04 VM used for Phase 4/5; the drills of AC-5 and the unit behaviour of AC-3 need systemd and Docker there. The guards of AC-2 run in CI without Docker.
