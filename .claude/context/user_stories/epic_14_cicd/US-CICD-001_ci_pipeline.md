# US-CICD-001: CI Pipeline

**Epic:** 14 — CI/CD
**Priority:** HIGH
**Estimate:** 5 pts
**Dependencies:** Phase 4 (independent of Epic 13)
**Status:** Pending

---

## User Story

**As** a DevOps engineer,
**I need** every push and pull request to run the backend tests, the frontend lint/typecheck/build, the Compose validation and shellcheck on GitHub-hosted runners,
**so that** nothing reaches `develop` or `main` (and, later, the image build and the deploy) without proof that the code, the configuration and the provisioning scripts still work.

---

## Decisions

- **GitHub-hosted runners, no secrets.** The CI needs no credential: tests must pass without `.env`, without network access to LLM providers and without a database. A job that needs a secret belongs to a later story (CICD-002+).
- **Least privilege.** The workflow declares `permissions: contents: read` at the top level; no job raises it. No `pull_request_target`, so pull requests from forks run with a read-only token and no secrets.
- **Triggers:** `pull_request` targeting `develop` or `main`, and `push` to `develop` and `main`. `develop` does not exist yet in the repository (only `main`): the trigger is harmless until it is created, and creating it is out of scope.
- **Third-party actions are pinned by full commit SHA**, with the version in a trailing comment, so a moved tag cannot change what runs. SHAs are resolved at implementation time (`gh api repos/<owner>/<repo>/git/ref/tags/<tag>`), never written from memory.
- **Versions match what ships:** Python 3.11 (the version of the Dockerfiles), Node from a single file in the repository (`.nvmrc`), so CI and local development cannot drift.
- **One required check.** A final aggregate job (`ci`) depends on all the others and is the only status that branch protection will require; adding or renaming a job never breaks the protection rule.
- **CI validates; it never builds or publishes images** (US-CICD-002) and never deploys (US-CICD-004/005).

---

## Acceptance Criteria

> Work ONE AT A TIME, in order. Mark `[x]` when each one is done and pause at the final checkpoint before closing the US.

- [x] **AC-1: Workflow Skeleton, Triggers, Permissions and Aggregate Gate**
  - `.github/workflows/ci.yml` with the triggers and `permissions: contents: read` above, `concurrency` per ref with `cancel-in-progress` for pull requests only (a push to `main` is never cancelled), a `timeout-minutes` on every job, and `actions/checkout` pinned by SHA with `persist-credentials: false`.
  - A first placeholder job plus the aggregate job `ci` (`needs:` every job, `if: always()`) that fails when any needed job failed, was cancelled or was skipped unexpectedly.
  - **Verification:** `actionlint` (or `gh workflow` lint) is clean locally; a draft pull request shows the `ci` check; a deliberately failing placeholder turns `ci` red.

- [x] **AC-2: Backend Tests**
  - Job `backend`: Python 3.11, pip cache keyed on the three requirements files (`apps/api_gateway/requirements-dev.txt`, `services/ai-engine/requirements.txt`, `services/mcp-servers/logs_server/requirements.txt`), install, `pytest tests/ -v`. Test configuration stays in `pytest.ini`.
  - The suite must pass from a clean checkout: no `.env`, no network, no LLM key. The job enforces it: the workflow sets no secret, a clean checkout has no `.env` (git-ignored), and `.github/ci/nonet/sitecustomize.py` (on `PYTHONPATH` only in this step) makes any non-loopback socket connection raise. Anything that depended on the developer's `.env` is fixed in the test (fixture or environment override), not by adding a secret to CI.
  - **Verification:** locally, `env -i` with only `PATH` (plus the guard on `PYTHONPATH`) over a `git archive` export and a fresh virtualenv built from those requirements files runs the whole suite green; the job is green on a pull request and red when a test is broken on purpose.

- [x] **AC-3: Frontend Lint, Typecheck and Build**
  - `apps/frontend/.nvmrc` pins Node `22` (what development uses; satisfies the `^20.19.0 || >=22.12.0` engines of Vite and oxlint). The job `frontend` reads it with `actions/setup-node` (`node-version-file`) and caches npm over `apps/frontend/package-lock.json`.
  - Steps in `apps/frontend`: `npm ci`, `npm run lint`, `npm run typecheck`, `npm run build`. A `typecheck` script (`tsc -b`) is added to `package.json` so the type error and the bundling error are reported as separate steps; `build` is unchanged (`tsc -b && vite build`, the one the Dockerfile runs).
  - The build uses the same-origin values the Compose build passes as build-args (`VITE_API_BASE_URL=/`, `VITE_WS_BASE_URL=/ws`; public, no secret); `dist/` is not uploaded.
  - **Verification:** green locally from a `git ls-files` export (no `node_modules`, `dist` or `.env`); a type error fails `typecheck` only and a conditional hook fails `lint` only; both are red on a pull request when introduced on purpose.
  - **Known drift (not changed here):** `apps/frontend/Dockerfile` builds with `node:20-alpine` while CI and development use Node 22. Aligning the image is proposed for US-CICD-002, where the images are rebuilt anyway.

- [ ] **AC-4: Compose Validation and Shellcheck**
  - Job `compose` (matrix): `cp .env.example .env`, then `docker compose config -q` for `TLS_MODE` ∈ {`selfsigned`, `acme` (with `ACME_EMAIL` and `PUBLIC_SCHEME=https`)} × {base file, base + `docker-compose.dev-db.yml`}. A separate job `compose-guard` proves the guard still bites: with `TLS_MODE` removed from `.env` the validation must fail **and** the error must name `TLS_MODE` (a failure for any other reason does not count).
  - Job `shellcheck`: every tracked shell script (`git ls-files '*.sh'`, which includes `scripts/`, `infra/` and `.claude/hooks/`), `--severity=warning`, using the shellcheck preinstalled on `ubuntu-24.04` (0.9.0; its version is printed in the log). `.shellcheckrc` (`external-sources=true`, `source-path=SCRIPTDIR`) makes it follow the `source` of `lib/*.sh`. Existing findings are fixed; a `# shellcheck disable=` is allowed only with a reason on the same line.
  - **Findings at the start (0.9.0): 4**, all in provisioning: a literal `~/.ssh` inside a check description (SC2088, disabled with reason), an unused `REPO_ROOT` in `checks/80_backup.sh` (removed), and two variables that are consumed by the scripts sourcing the library, `FILE_CHANGED` and `AFTER_RULES` (SC2034, disabled with reason).
  - **Verification:** the five Compose combinations and the guard behave as described on a clean export; shellcheck 0.9.0 is clean; all jobs are green on a pull request, and breaking a variable name in the compose or adding an unquoted expansion to a script turns the matching job red.

- [ ] **AC-5: Branch Protection, Documentation and Evidence**
  - Document in `infra/ci/README.md`: what each job checks, how to reproduce each job locally (one command per job), how to add a job to the aggregate gate, and the branch-protection settings to apply on GitHub (require pull request, require the `ci` status, up-to-date branch, no force-push). `.claude/CLAUDE.md` and `README.md` point to it.
  - Applying the branch protection is a manual step on GitHub (settings are not in the repository); the document lists the exact rule and its result is checked with `gh api repos/<owner>/<repo>/branches/main/protection`.
  - **Verification:** evidence of one green run and one deliberately red run (links or run ids) recorded in `infra/ci/README.md`; a pull request with a red `ci` cannot be merged once the protection is on.

---

## Technical Notes

- **`.env` in CI:** only the `compose` job creates one, from `.env.example`, and it contains placeholders that `validate_env.sh` would reject in production; that is intended, CI never runs a production configuration.
- **Python version:** the machine used for development may run a newer Python than 3.11; the CI is the place that proves 3.11 compatibility, which is what the images run.
- **Cost and speed:** jobs run in parallel; caches (pip, npm) keep the pipeline in the order of a few minutes. Docker image builds are deliberately excluded here (CICD-002).
- **Out of scope:** image build and publication (US-CICD-002); the self-hosted runner (US-CICD-003); deployment (US-CICD-004/005); code coverage thresholds; dependency or container vulnerability scanning (candidates for a later story).
