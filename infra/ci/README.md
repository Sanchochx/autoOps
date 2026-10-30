# Continuous integration and images (US-CICD-001, US-CICD-002, US-CICD-003)

`.github/workflows/ci.yml` runs on every pull request to `develop` or `main` and on every push to those branches,
on GitHub-hosted runners. It **validates and builds**: pull requests build the images without pushing; only a push to
`main` with a green `ci` publishes them to GHCR (job `publish`, see [Images](#images-us-cicd-002)). It never deploys
(US-CICD-004/005) and needs **no secrets of its own**: the default is `permissions: contents: read`, no
`pull_request_target`, and `publish` authenticates with the built-in `GITHUB_TOKEN`.

## Jobs

| Job | What it checks | Reproduce locally |
|---|---|---|
| `backend` | `pytest tests/ -v` on Python 3.11, from a clean checkout: no `.env`, no LLM key, and `.github/ci/nonet/sitecustomize.py` makes any non-loopback connection fail | `python3.11 -m venv v && v/bin/pip install -r apps/api_gateway/requirements-dev.txt -r services/ai-engine/requirements.txt -r services/mcp-servers/logs_server/requirements.txt && PYTHONPATH=.github/ci/nonet v/bin/pytest tests/ -v` (run it from an export without `.env`: `git archive HEAD \| tar -x -C /tmp/x`) |
| `frontend` | `npm ci`, `lint`, `typecheck` (`tsc -b`), `build`, with the Node version in `apps/frontend/.nvmrc` | `cd apps/frontend && npm ci && npm run lint && npm run typecheck && VITE_API_BASE_URL=/ VITE_WS_BASE_URL=/ws npm run build` |
| `compose` (4 cells) | `docker compose config -q` for `TLS_MODE` ∈ {`selfsigned`, `acme`} × {base, base + `docker-compose.dev-db.yml`} using `.env.example` | `cp .env.example .env && docker compose config -q` (for `acme` also set `ACME_EMAIL` and `PUBLIC_SCHEME=https`) |
| `compose-guard` | Without `TLS_MODE` the Compose must be rejected, and the error must name `TLS_MODE` | `sed '/^TLS_MODE=/d' .env.example > .env && docker compose config -q` (must fail) |
| `shellcheck` | Every tracked `*.sh`, severity `warning`, config in `.shellcheckrc` | `git ls-files -z '*.sh' \| xargs -0 shellcheck --severity=warning` |
| `images` | The four images build with `docker buildx bake` from `docker-compose.yml` (no push), and the `NODE_VERSION` of `apps/frontend/Dockerfile` equals `.nvmrc`. It also builds the self-hosted runner image (from `infra/runner`: `bake` resolves the build context against the working directory) | `cp .env.example .env && TLS_MODE=selfsigned docker buildx bake api-gateway frontend mcp-logs traefik` |
| `runner-compose` | `infra/runner/docker-compose.yml` keeps the runner locked down, checked on the **resolved** model: no `docker.sock`, ports, privileged mode, `network_mode`, `cap_add` or host bind mounts; `cap_drop: [ALL]`, `no-new-privileges`, read-only root, one dedicated network, limits | `RUNNER_REPO_URL=https://github.com/o/r scripts/ci/check_runner_compose.sh` |
| `runner-workflows` | A workflow that targets the self-hosted runner (`autoops-prod`) is triggered only by `workflow_dispatch` or `push` to `main`, and its jobs declare `environment: production` | `scripts/ci/check_runner_workflows.sh` (needs PyYAML) |
| `publish` | Only on `push` to `main`, after `ci` is green: pushes the four images tagged with the commit SHA (the only job with `packages: write`) | — |
| `ci` | Aggregate gate: passes only if every job above succeeded (also when one failed, was cancelled or skipped) | — |

## Design rules

- **Third-party actions are pinned by full commit SHA**, with the version in a comment. To update one, resolve the tag
  again (`git ls-remote --tags https://github.com/<owner>/<action> 'refs/tags/v*'`; for an annotated tag use the
  `^{}` line) and change SHA and comment together. Never use a moving tag.
- **`ci` is the only status branch protection requires.** To add a job, add it to `needs:` of `ci`; renaming or
  adding jobs then never breaks the protection rule.
- **Concurrency:** a new push to a pull request cancels its running workflow; runs on `develop` and `main` are never
  cancelled.
- **Versions match what ships:** Python 3.11 (the Dockerfiles), Node from `.nvmrc`; the `images` job fails if the
  frontend Dockerfile drifts from `.nvmrc`.
- The `.env` that the `compose` jobs create comes from `.env.example`; its placeholders would be rejected by
  `scripts/ops/validate_env.sh` in production, which is intended: CI never runs a production configuration.

## Branch protection (manual: GitHub settings are not in the repository)

GitHub → Settings → Branches → add a rule for `main` (and for `develop` once it exists):

- Require a pull request before merging. Required approvals: 0 while there is a single maintainer; raise it with the team.
- Require status checks to pass before merging → select **`ci`** only. Require branches to be up to date before merging.
- Block force pushes and deletions. Optionally apply the rules to administrators.

Check the result:

```bash
gh api repos/Sanchochx/autoOps/branches/main/protection \
  --jq '{checks: .required_status_checks.contexts, strict: .required_status_checks.strict, force_push: .allow_force_pushes.enabled}'
# expected: {"checks":["ci"],"strict":true,"force_push":false}
```

A pull request whose `ci` is red cannot be merged once the rule is on.

## Evidence

Rows marked _pending_ were not supplied when the story was closed; fill them in from the Actions tab (no URL has been
invented here).

| Case | Run |
|---|---|
| Green run (all jobs, `ci` green) | _pending: add the run URL_ |
| Red run on purpose (e.g. a broken test; `backend` and `ci` red) | _pending: add the run URL_ |
| Merge blocked by a red `ci` | _pending: add the pull request URL_ |
| Branch protection on `main` (`gh api …/protection`) | Reported by the maintainer: required status checks = `["ci"]`. `strict` and `allow_force_pushes` values were not reported |

## Images (US-CICD-002)

Four images are built from `docker-compose.yml` and published to GitHub Container Registry on every push to `main`
whose CI is green:

| Image | Built from |
|---|---|
| `ghcr.io/<owner>/autoops/api-gateway` | `apps/api_gateway/Dockerfile` (also the `migrate` service) |
| `ghcr.io/<owner>/autoops/frontend` | `apps/frontend/Dockerfile` |
| `ghcr.io/<owner>/autoops/mcp-logs` | `services/mcp-servers/logs_server/Dockerfile` |
| `ghcr.io/<owner>/autoops/traefik` | `infra/traefik/Dockerfile` |

`<owner>` is the repository owner in lowercase (GHCR requires it). `postgres` is the upstream image and is not published.

- **Tags are the full commit SHA, only.** There is no `latest` and no moving tag: a deploy names the exact commit it
  runs and a rollback is another SHA. Each image carries `org.opencontainers.image.revision` (the SHA), `.source` and
  `.created`.
- **One Compose file for both worlds.** Every built service has `build:` and
  `image: ${IMAGE_REPOSITORY:-autoops}/<service>:${IMAGE_TAG:-dev}`. Development (`docker compose up -d --build`)
  builds and tags `autoops/<service>:dev`; a host sets the two variables and pulls.
- **Production never runs `dev`:** `scripts/ops/validate_env.sh` rejects an empty or `dev` `IMAGE_TAG` when
  `ENVIRONMENT=production`.

### Run a published commit

```bash
export IMAGE_REPOSITORY=ghcr.io/<owner>/autoops     # owner in lowercase
export IMAGE_TAG=<full 40-character commit SHA>
docker compose pull                                  # nothing is built
docker compose up -d --no-build
docker compose --profile tools run --rm migrate      # a new database needs its migrations; `up` never runs them
```

Put the two variables in `.env` instead when the stack is managed by systemd (`autoops.service` reads it). With
`sudo`, pass them with `sudo env IMAGE_REPOSITORY=… IMAGE_TAG=… docker compose …`.

**Which commit is running?** `docker compose images` lists repository and tag per service; the tag is the SHA. For one
image: `docker image inspect <image> --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'`.

### Package visibility and pull credentials

The packages inherit the visibility of the repository: while it is public, anyone can `docker pull` them without
credentials. If the repository becomes private the packages are private too, and the host needs
`docker login ghcr.io` with a token that only has `read:packages`. How that credential is provisioned and stored is
decided in US-CICD-003/004; do not reuse a personal token with wider scopes.

### Updating the pinned actions

`publish` and `images` add `docker/setup-buildx-action` and `docker/login-action`. Update them like the others (see
Design rules): resolve the new tag to its commit SHA and change SHA and version comment together.

### Evidence (AC-1, AC-3, AC-4)

| Case | Evidence |
|---|---|
| `images` red on a broken `COPY` (pull request, `images` and `ci` red) | https://github.com/Sanchochx/autoOps/actions/runs/40793389105 |
| `images` green again after the revert | https://github.com/Sanchochx/autoOps/actions/runs/40793775201 |
| Publication on `main` (all jobs green, `publish` pushed four images) | https://github.com/Sanchochx/autoOps/actions/runs/40796026748 |
| `publish` skipped on a pull request | https://github.com/Sanchochx/autoOps/pull/2 |

Merge commit `6117b7aac20113f25ad4e8ba8dd8f586e2f787ce`, published as that exact tag (index digests):

| Package | Digest |
|---|---|
| https://github.com/users/Sanchochx/packages/container/package/autoops%2Fapi-gateway | `sha256:0b75ba6b4721805ac1e33b2713d91ab259f8bb8bf38307452fd2348f3db620cf` |
| https://github.com/users/Sanchochx/packages/container/package/autoops%2Ffrontend | `sha256:66387f878305848848e6e9c51eac458d1a3f576501574a74c922d3874599dd5d` |
| https://github.com/users/Sanchochx/packages/container/package/autoops%2Fmcp-logs | `sha256:71f114dbde03c8091e688afbcbd674c7018278a8f84609249b35fab9afb8e1d6` |
| https://github.com/users/Sanchochx/packages/container/package/autoops%2Ftraefik | `sha256:bdeff3714e99f1ccd4264f0a7777f011ac2bf43505d2c158869c2a9c5f897c38` |

### Evidence: run from the registry (AC-4)

On the maintainer's machine, with the stack down, the four images were pulled by tag (`docker compose pull`, nothing
built) and started with `docker compose up -d --no-build`; `migrate` then ran from the same GHCR image on an empty
database. Reported by the maintainer; the `docker compose images` output was supplied verbatim:

| Check | Result |
|---|---|
| `docker compose ps` | every service `healthy` |
| `org.opencontainers.image.revision` of each image | equals `6117b7aac20113f25ad4e8ba8dd8f586e2f787ce` |
| `RepoDigests` of each pulled image vs. the table above | identical |
| `scripts/ops/e2e_https.py` | exit 0: `POST /api/v1/tickets over https -> 201` and `ai_event over wss://` |
| `docker compose images` | repository `ghcr.io/sanchochx/autoops/<service>` and tag = the SHA for the four built services (output below) |

```
CONTAINER               REPOSITORY                              TAG                                       IMAGE ID       SIZE
autoops-api-gateway-1   ghcr.io/sanchochx/autoops/api-gateway   6117b7aac20113f25ad4e8ba8dd8f586e2f787ce  0b75ba6b4721   494MB
autoops-frontend-1      ghcr.io/sanchochx/autoops/frontend      6117b7aac20113f25ad4e8ba8dd8f586e2f787ce  66387f878305   94MB
autoops-mcp-logs-1      ghcr.io/sanchochx/autoops/mcp-logs      6117b7aac20113f25ad4e8ba8dd8f586e2f787ce  71f114dbde03   282MB
autoops-postgres-1      postgres                                15-alpine                                 54e0dd8e8cdd   416MB
autoops-traefik-1       ghcr.io/sanchochx/autoops/traefik       6117b7aac20113f25ad4e8ba8dd8f586e2f787ce  bdeff3714e99   252MB
```

(The image IDs equal the first 12 characters of the index digests listed above; platform `linux/amd64`.)

The first e2e attempt returned HTTP 500 because the local `.env` still had the default `DB_PASSWORD` while the existing
Postgres volume had been initialised with another one; recreating the volume (`down -v`) with real credentials fixed
it. It was a local configuration problem, not an image problem.

The digests above are the ones in the `publish` log; the registry reports the same ones for the tagged versions. All four
packages are `public` (they inherit the visibility of the repository) and carry, in the image config read from the
registry, `org.opencontainers.image.revision` = the commit above, `.source` = https://github.com/Sanchochx/autoOps and
`.created` = `2026-10-29T00:45:45Z` (`traefik` also keeps the upstream labels).

## Self-hosted runner (US-CICD-003)

The deploy job (US-CICD-004/005) runs on a runner that lives on the AutoOps host, in a container with no Docker socket
and no network shared with the stack, so GitHub never needs to reach the host. This pipeline only guards it: the two
jobs above run on GitHub-hosted runners and fail the build if the runner Compose loses a control or a workflow that
targets the runner could be triggered from a pull request. Threat model, provisioning, GitHub settings and evidence:
[`../runner/README.md`](../runner/README.md).

## Out of scope

Deployment (US-CICD-004/005), image signing, SBOM, coverage thresholds, dependency
and image vulnerability scanning, retention of old image versions, multi-arch images.
