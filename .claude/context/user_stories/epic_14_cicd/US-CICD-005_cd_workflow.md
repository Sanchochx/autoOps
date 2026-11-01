# US-CICD-005: CD Workflow, Smoke Test and Phase Closing

**Epic:** 14 — CI/CD
**Priority:** HIGH
**Estimate:** 5 pts
**Dependencies:** US-CICD-004
**Status:** Draft (pending user validation before implementation)

---

## User Story

**As** a DevOps engineer,
**I need** a commit that reaches `main` with a green CI to be deployed automatically on the host, checked by a smoke test over HTTPS and rolled back if the check fails,
**so that** shipping is "merge and watch", with every step visible in GitHub Actions and none of them able to reach Docker from CI.

---

## Decisions

- **A separate workflow, `deploy.yml`, not a job in `ci.yml`.** `ci.yml` runs on pull requests, and `check_runner_workflows.sh` (US-CICD-003) forbids any workflow that uses the runner from having a trigger other than `workflow_dispatch` or `push` to `main`. `deploy.yml` therefore has exactly those two triggers, and its runner job declares `environment: production`.
- **Wait for CI, do not repeat it.** `workflow_run` is not allowed for runner workflows, so `deploy.yml` starts on the same `push` to `main` and its first job, on a GitHub-hosted runner, waits until the `ci` and `publish` jobs of that commit's `CI` run have succeeded (GitHub API with the built-in `GITHUB_TOKEN`, `actions: read`), with a timeout. A red or cancelled CI ends the workflow without touching the host. The images are therefore published before any request is made, and the host would reject the request anyway if they were not (US-CICD-004).
- **The runner job only calls `scripts/ci/request_deploy.sh`.** It checks out the commit (`persist-credentials: false`, pinned actions like the rest of the repo), runs the script with the SHA of the push and maps its exit code to the job result (0 green; 1 rolled back, 2 failed and 3 timeout red). No Docker, no secret, no SSH.
- **One deploy at a time, in order.** `concurrency: { group: deploy, cancel-in-progress: false }`: two merges in a row queue instead of cancelling a deploy in flight (cancelling would leave a request half-processed). The host already serializes (US-CICD-004); this keeps the GitHub side honest too.
- **The smoke test runs on the host, as the last step of the health gate.** The runner cannot reach the stack (isolated network, by design) and a GitHub-hosted runner cannot reach a VM without exposing it, so a smoke test from the workflow would need a hole this project closed on purpose. `scripts/ops/smoke_test.sh` runs from `deploy.sh` after the current probe and, if it fails, the existing rollback applies. Its result reaches the workflow through the same `status` file (`reason=smoke_failed`). The probe of US-CICD-004 stays: it is the cheap first check and keeps the rollback path unchanged.
- **What the smoke test checks (HTTPS through Traefik, same client setup as the probe):** the frontend answers `200` with HTML; the API answers `200` on `DEPLOY_HEALTH_PATH`; HTTP redirects to HTTPS; the security headers set by Traefik are present (HSTS); the running gateway container uses the image of the deployed tag. Read-only requests only; no data is created.
- **Rollback evidence needs a release that is broken only for itself.** US-CICD-004 could not produce a clean `rolled_back` on the VM because a flag that breaks the probe also breaks the rollback. The drill here uses a real, published commit on `main` whose smoke test fails, then recovers by reverting it; evidence is the `status`, the journal and the GitHub run.
- **The deploy job's summary is the operator's dashboard.** The job writes the final `state`, `reason`, `rollback`, tag and duration to `$GITHUB_STEP_SUMMARY`, copied from the fixed-code `status` (never raw command output).
- **GitHub settings are documented, like US-CICD-003:** `production` environment limited to `main`, optional required reviewers (a manual gate before each deploy), and what changes if the repository becomes private (runner token, GHCR pull credentials).
- **Out of scope:** blue/green or canary, notifications (Slack, email), deploying a tag from a workflow dispatch with an arbitrary SHA (the operator command on the host exists for that), image signing and attestations, a GitHub App.

---

## Acceptance Criteria

> Work ONE AT A TIME, in order. Mark `[x]` when each one is done and pause at the final checkpoint before closing the US.

- [ ] **AC-1: Deploy Workflow**
  - `.github/workflows/deploy.yml` with triggers `push: branches: [main]` and `workflow_dispatch`; `permissions: {}` at workflow level and `actions: read` only on the gate job; actions pinned by commit SHA; `concurrency` as above. Job `wait-for-ci` (GitHub-hosted) and job `deploy` (`runs-on: autoops-prod`, `environment: production`, `needs: wait-for-ci`, timeout above the host's maximum) that checks out the commit and runs `request_deploy.sh`. The exit code is mapped to the job result and the outcome is written to the job summary.
  - **Verification:** `scripts/ci/check_runner_workflows.sh` passes with the new file (and a variant with a `pull_request` trigger or without `environment` turns it red); `shellcheck` and the YAML lint are clean; a red CI for a commit leaves `deploy` skipped and no request in the inbox; a push to a branch other than `main` starts nothing.

- [ ] **AC-2: Post-Deploy Smoke Test**
  - `scripts/ops/smoke_test.sh` with the checks listed in Decisions, configurable only through the variables `deploy.sh` already reads (`DOMAIN`, `PROXY_*`, `TLS_*`, `DEPLOY_HEALTH_PATH`), no hardcoded host; `deploy.sh` calls it after the probe and treats a failure as `smoke_failed` with the normal rollback. `scripts/ci/test_deploy.sh` gains cases with the fake `docker`/`curl` (smoke fails → `rolled_back`, smoke passes → `succeeded`, rollback whose smoke also fails → `failed`), and the script itself is tested against a fake HTTPS server.
  - **Verification:** each check fails the script when its condition is broken (one mutation per check); `shellcheck` clean; `deploy-guards` stays green.

- [ ] **AC-3: End-to-End Continuous Delivery**
  - A real merge to `main` triggers CI, `publish`, `deploy.yml`, the request to the host and the smoke test without any manual command, and the host ends on the new SHA. Evidence: the GitHub run URLs, the `status` (`state=succeeded`), `docker ps` showing the new tag and the `history` line.
  - **Verification:** a docs-only merge is enough; the time from merge to `succeeded` is recorded.

- [ ] **AC-4: Rollback Evidence**
  - A published commit on `main` that fails the smoke test only for itself is deployed by the workflow and ends `rolled_back` with `rollback=ok` (the previous release running and healthy), the job red with the reason in its summary; the commit is then reverted and the revert deploys cleanly. If the drill cannot be run safely, the limit is stated in the documentation and the case stays covered by `test_deploy.sh`.
  - **Verification:** `status`, journal, GitHub run and `docker ps` before/after are recorded; the real endpoint answers 200 at the end.

- [ ] **AC-5: Documentation, Verification and Phase Closing**
  - `infra/deploy/README.md` (the CD section: triggers, gate, exit codes, summary, smoke test, what to do on each red), `infra/ci/README.md`, `infra/runner/README.md`, `infra/README.md`, `.claude/CLAUDE.md` and `README.md` updated; the GitHub settings (environment, reviewers, branch protection) documented. `sudo ./scripts/provision/verify.sh` run on the VM and its result recorded. Phase summary in `.claude/context/summaries/phase-5-resume.md` (changes, files, rationale, next steps); plan updated (Epic 14 at 100%, Phase 5 at 8/8).
  - **Verification:** a reader can follow the documents to find why a deploy went red and to act on it; the summary lets a new session understand Phase 5 without rereading the code.

---

## Technical Notes

- **Gate details:** the gate polls `GET /repos/{repo}/actions/runs?head_sha={sha}&event=push` for the `CI` workflow and then its jobs, and requires `ci` and `publish` to be `success`. The `ci` job already fails when any job it needs fails, and `publish` only runs on `main`, so both together mean "tested and published".
- **Why `request_deploy.sh` and not an inline script:** it is already tested (35 assertions in `deploy-guards`) and keeps the workflow free of logic and of anything derived from untrusted text.
- **Open question for validation:** whether `production` should require a reviewer (manual approval per deploy) or deploy automatically. The design works with both; the default proposed is automatic, with the reviewer documented as a switch.
